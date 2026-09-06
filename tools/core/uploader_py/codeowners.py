# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Discover and compile one immutable CODEOWNERS matcher per invocation.

Parsing once avoids repeated I/O and makes concurrent worker lookups read-only.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re
from typing import Any, MutableMapping
from urllib.parse import unquote

from .json_utils import strict_json_dumps

CODEOWNERS_LOCATIONS = (
    "CODEOWNERS",
    ".github/CODEOWNERS",
    ".gitlab/CODEOWNERS",
    "docs/CODEOWNERS",
    ".docs/CODEOWNERS",
)
_VALID_PERCENT_ESCAPE_RE = re.compile(r"%[0-9A-Fa-f]{2}")
_DRIVE_PATH_RE = re.compile(r"^[A-Za-z]:/")


@dataclass(frozen=True)
class CodeOwnersRule:
    """One compiled rule; tuple order preserves last-match-wins behavior."""

    pattern: str
    regex_text: str
    regex: re.Pattern[str]
    owners: tuple[str, ...]


@dataclass(frozen=True)
class CodeOwnersMatch:
    """Result for one source, including explicit empty-owner matches."""

    matched: bool
    owners: tuple[str, ...] = ()
    candidate: str | None = None

    @property
    def json_value(self) -> str | None:
        if not self.owners:
            return None
        return strict_json_dumps(
            self.owners,
            ensure_ascii=False,
            separators=(",", ":"),
        )


@dataclass(frozen=True)
class CodeOwnersMatcher:
    """Read-only rules and repository roots shared by every worker."""

    source_path: Path | None
    workspace_root: str
    context_workspace: str
    rules: tuple[CodeOwnersRule, ...] = ()
    warnings: tuple[str, ...] = ()
    windows_paths: bool = os.name == "nt"

    @property
    def enabled(self) -> bool:
        return bool(self.rules)

    def match_source(self, source_path: str) -> CodeOwnersMatch:
        """Return the first candidate hit; rules use last-match-wins."""
        for candidate in source_candidates(
            source_path,
            workspace_root=self.workspace_root,
            context_workspace=self.context_workspace,
            windows_paths=self.windows_paths,
        ):
            match = self._match_candidate(candidate)
            if match.matched:
                return CodeOwnersMatch(True, match.owners, candidate)
        return CodeOwnersMatch(False)

    def _match_candidate(self, candidate: str) -> CodeOwnersMatch:
        matched_rule: CodeOwnersRule | None = None
        for rule in self.rules:
            if rule.regex.search(candidate):
                matched_rule = rule
        if matched_rule is None:
            return CodeOwnersMatch(False)
        return CodeOwnersMatch(True, _dedupe(matched_rule.owners), candidate)


@dataclass(frozen=True)
class CodeOwnersEnrichmentStats:
    scanned: int = 0
    enriched: int = 0
    skipped_existing: int = 0
    skipped_missing_source: int = 0
    skipped_unmatched: int = 0
    skipped_errors: int = 0


def _decode_percent_path(value: str) -> str:
    if "%" not in value or re.search(r"(?i)%00", value):
        return value
    if "%" in _VALID_PERCENT_ESCAPE_RE.sub("", value):
        return value
    try:
        return unquote(value, encoding="utf-8", errors="strict")
    except UnicodeError:
        return value


def normalize_path_like(raw: str) -> str | None:
    """Normalize producer, URI, runfiles, Unix, and Windows source paths."""
    value = raw
    if value.startswith("file://"):
        value = value[len("file://") :]
    value = _decode_percent_path(value).replace("\\", "/")
    value = re.sub(r"/{2,}", "/", value)
    while value.startswith("./"):
        value = value[2:]
    if re.match(r"^/[A-Za-z]:/", value):
        value = value[1:]

    absolute = value.startswith("/")
    if absolute:
        value = value[1:]
    stack: list[str] = []
    for part in value.split("/"):
        if part in {"", "."}:
            continue
        if part == "..":
            if not stack:
                return None
            stack.pop()
            continue
        stack.append(part)
    joined = "/".join(stack)
    return f"/{joined}" if absolute else joined


def _strip_workspace_prefix(
    path_value: str,
    root_value: str,
    *,
    windows_paths: bool,
) -> str | None:
    if not path_value or not root_value:
        return None
    path_normalized = normalize_path_like(path_value)
    root_normalized = normalize_path_like(root_value)
    if not path_normalized or not root_normalized:
        return None
    comparison_path = path_normalized.casefold() if windows_paths else path_normalized
    comparison_root = root_normalized.casefold() if windows_paths else root_normalized
    if comparison_path == comparison_root:
        return ""
    prefix = f"{comparison_root}/"
    if comparison_path.startswith(prefix):
        return path_normalized[len(root_normalized) + 1 :]
    return None


def source_candidates(
    source_path: str,
    *,
    workspace_root: str = "",
    context_workspace: str = "",
    windows_paths: bool = os.name == "nt",
) -> tuple[str, ...]:
    """Return priority-ordered, repository-relative ownership candidates."""
    normalized = normalize_path_like(source_path)
    if not normalized:
        return ()
    candidates: list[str] = []

    def add(candidate: str | None, *, derived: bool = False) -> None:
        if not candidate:
            return
        if derived and (
            candidate.startswith("external/")
            or candidate.startswith("_main/external/")
        ):
            return
        normalized_candidate = normalize_path_like(candidate)
        if not normalized_candidate:
            return
        normalized_candidate = normalized_candidate.lstrip("/")
        if not normalized_candidate or normalized_candidate.startswith("bazel-out/"):
            return
        if normalized_candidate not in candidates:
            candidates.append(normalized_candidate)

    add(
        _strip_workspace_prefix(
            normalized,
            context_workspace,
            windows_paths=windows_paths,
        )
    )
    add(
        _strip_workspace_prefix(
            normalized,
            workspace_root,
            windows_paths=windows_paths,
        )
    )

    for expression in (
        r"/execroot/[^/]+/_main/(.+)$",
        r"/execroot/[^/]+/(.+)$",
        r"\.runfiles/_main/(.+)$",
        r"\.runfiles/[^/]+/(.+)$",
    ):
        match = re.search(expression, normalized)
        if match:
            add(match.group(1), derived=True)

    if not normalized.startswith("/") and not _DRIVE_PATH_RE.match(normalized):
        add(normalized)
    return tuple(candidates)


def _glob_to_regex(pattern: str) -> str:
    output: list[str] = []
    index = 0
    while index < len(pattern):
        character = pattern[index]
        if character == "\\":
            if index + 1 < len(pattern):
                output.append(re.escape(pattern[index + 1]))
                index += 2
            else:
                output.append(r"\\")
                index += 1
            continue
        if character == "*" and index + 1 < len(pattern) and pattern[index + 1] == "*":
            if index + 2 < len(pattern) and pattern[index + 2] == "/":
                output.append("(.*/)?")
                index += 3
            else:
                output.append(".*")
                index += 2
            continue
        if character == "*":
            output.append("[^/]*")
            index += 1
            continue
        if character == "?":
            output.append("[^/]")
            index += 1
            continue
        if character == "[":
            class_regex, next_index = _character_class(pattern, index)
            output.append(class_regex)
            index = next_index
            continue
        output.append(re.escape(character))
        index += 1
    return "".join(output)


def _character_class(pattern: str, start: int) -> tuple[str, int]:
    index = start + 1
    body: list[str] = []
    if index < len(pattern) and pattern[index] == "!":
        body.append("^")
        index += 1
    elif index < len(pattern) and pattern[index] == "^":
        body.append(r"\^")
        index += 1
    if index < len(pattern) and pattern[index] == "]":
        body.append(r"\]")
        index += 1

    while index < len(pattern):
        character = pattern[index]
        if character == "]":
            return f"[{''.join(body)}]", index + 1
        if character in {"\\", "^", "["}:
            body.append(f"\\{character}")
        else:
            body.append(character)
        index += 1
    return r"\[", start + 1


def compile_pattern(pattern: str) -> tuple[str, re.Pattern[str]]:
    """Compile one legacy-compatible CODEOWNERS glob."""
    anchored = pattern.startswith("/")
    directory_only = pattern.endswith("/")
    raw = pattern[1:] if anchored else pattern
    raw = raw[:-1] if directory_only else raw
    if not raw:
        raise ValueError("empty CODEOWNERS pattern")
    prefix = "^" if anchored or "/" in raw else "(^|.*/)"
    suffix = "/.*$" if directory_only else "($|/.*)"
    regex_text = f"{prefix}{_glob_to_regex(raw)}{suffix}"
    return regex_text, re.compile(regex_text)


def _split_pattern_and_owners(line: str) -> tuple[str, str]:
    pattern: list[str] = []
    escaped = False
    for index, character in enumerate(line):
        if escaped:
            pattern.append(character)
            escaped = False
            continue
        if character == "\\":
            pattern.append(character)
            escaped = True
            continue
        if character.isspace():
            return "".join(pattern), line[index:].lstrip()
        pattern.append(character)
    return "".join(pattern), ""


def _is_gitlab_section_header_pattern(pattern: str) -> bool:
    if not re.fullmatch(r"\[[^][]+\]", pattern):
        return False
    inner = pattern[1:-1]
    if any(character.isspace() for character in inner):
        return True
    if any(character in inner for character in "-!^\\"):
        return False
    if re.fullmatch(r"[A-Z0-9]+", inner):
        return False
    if len(inner) <= 3 and re.fullmatch(r"[A-Za-z0-9]+", inner):
        return False
    if re.fullmatch(r"[a-z0-9]+", inner):
        return False
    return True


def _is_gitlab_section_header_line(line: str) -> bool:
    match = re.fullmatch(r"(\[[^][]+\])(?:\s+.*)?", line)
    return bool(match and _is_gitlab_section_header_pattern(match.group(1)))


def parse_codeowners(text: str) -> tuple[tuple[CodeOwnersRule, ...], tuple[str, ...]]:
    """Parse and compile once, skipping malformed rules with diagnostics."""
    rules: list[CodeOwnersRule] = []
    warnings: list[str] = []
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.lstrip().rstrip("\r")
        if not line or line.startswith("#") or _is_gitlab_section_header_line(line):
            continue
        pattern, owners_raw = _split_pattern_and_owners(line)
        if not pattern or _is_gitlab_section_header_pattern(pattern):
            continue
        owners_raw = owners_raw.rstrip()
        if owners_raw.startswith("#"):
            owners_raw = ""
        else:
            owners_raw = re.sub(r"\s#.*$", "", owners_raw).rstrip()
        owners = tuple(token for token in owners_raw.split() if token)
        try:
            regex_text, compiled = compile_pattern(pattern)
        except (ValueError, re.error) as exc:
            warnings.append(
                f"ignored invalid CODEOWNERS rule at line {line_number}: {type(exc).__name__}"
            )
            continue
        rules.append(CodeOwnersRule(pattern, regex_text, compiled, owners))
    return tuple(rules), tuple(warnings)


def load_codeowners_matcher(
    *,
    explicit_path: Path | None,
    workspace_root: Path,
    context_workspace: str = "",
    cwd: Path | None = None,
    launcher_directory: Path | None = None,
    windows_paths: bool = os.name == "nt",
) -> CodeOwnersMatcher:
    """Discover, read, and compile the invocation-wide matcher exactly once."""
    candidates: list[Path] = []
    if explicit_path is not None and explicit_path.is_file():
        candidates.append(explicit_path)
    else:
        for root in (Path(context_workspace) if context_workspace else None, workspace_root):
            if root is not None:
                candidates.extend(root / location for location in CODEOWNERS_LOCATIONS)
        candidates.append((cwd or Path.cwd()) / "CODEOWNERS")
        if launcher_directory is not None:
            candidates.append(launcher_directory / "CODEOWNERS")

    source_path = next((path for path in candidates if path.is_file()), None)
    if source_path is None:
        return CodeOwnersMatcher(
            source_path=None,
            workspace_root=str(workspace_root),
            context_workspace=context_workspace,
            windows_paths=windows_paths,
        )
    try:
        text = source_path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError) as exc:
        return CodeOwnersMatcher(
            source_path=source_path,
            workspace_root=str(workspace_root),
            context_workspace=context_workspace,
            warnings=(f"failed to read CODEOWNERS: {type(exc).__name__}",),
            windows_paths=windows_paths,
        )
    rules, warnings = parse_codeowners(text)
    return CodeOwnersMatcher(
        source_path=source_path.resolve(),
        workspace_root=str(workspace_root),
        context_workspace=context_workspace,
        rules=rules,
        warnings=warnings,
        windows_paths=windows_paths,
    )


def _dedupe(owners: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(dict.fromkeys(owner for owner in owners if owner))


def _event_source_path(event: dict[str, Any]) -> str | None:
    content = event.get("content")
    if not isinstance(content, dict):
        return None
    meta = content.get("meta")
    if isinstance(meta, dict):
        for key in (
            "test.source.file",
            "test.source.path",
            "source.file",
            "source.path",
        ):
            value = meta.get(key)
            if isinstance(value, str) and value:
                return value
    source = content.get("source")
    if isinstance(source, dict):
        for key in ("file", "path"):
            value = source.get(key)
            if isinstance(value, str) and value:
                return value
    return None


def enrich_payload_codeowners(
    payload: dict[str, Any],
    matcher: CodeOwnersMatcher,
    *,
    cache: MutableMapping[str, CodeOwnersMatch] | None = None,
) -> CodeOwnersEnrichmentStats:
    """Mutate one worker-owned payload while preserving producer owners."""
    if not matcher.enabled:
        return CodeOwnersEnrichmentStats()
    events = payload.get("events")
    if not isinstance(events, list):
        return CodeOwnersEnrichmentStats()
    local_cache = cache if cache is not None else {}
    counters = {
        "scanned": 0,
        "enriched": 0,
        "skipped_existing": 0,
        "skipped_missing_source": 0,
        "skipped_unmatched": 0,
        "skipped_errors": 0,
    }

    for event in events:
        if not isinstance(event, dict) or event.get("type") == "span":
            continue
        counters["scanned"] += 1
        try:
            content = event.get("content")
            meta = content.get("meta") if isinstance(content, dict) else None
            if isinstance(meta, dict) and "test.codeowners" in meta:
                counters["skipped_existing"] += 1
                continue
            source_path = _event_source_path(event)
            if not source_path:
                counters["skipped_missing_source"] += 1
                continue
            match = local_cache.get(source_path)
            if match is None:
                match = matcher.match_source(source_path)
                local_cache[source_path] = match
            if not match.owners:
                counters["skipped_unmatched"] += 1
                continue
            if not isinstance(content, dict):
                counters["skipped_errors"] += 1
                continue
            if not isinstance(meta, dict):
                meta = {}
                content["meta"] = meta
            meta["test.codeowners"] = match.json_value
            counters["enriched"] += 1
        except (AttributeError, TypeError, ValueError):
            counters["skipped_errors"] += 1

    return CodeOwnersEnrichmentStats(**counters)
