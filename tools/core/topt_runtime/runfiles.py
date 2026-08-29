# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Resolve Bazel runfiles into one immutable lookup snapshot.

Centralizing lookup keeps launchers portable and workers isolated from env changes.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import re
from types import MappingProxyType
from typing import Iterable, Mapping


_WINDOWS_ABSOLUTE_RE = re.compile(r"^[A-Za-z]:/")


class RunfileResolutionError(RuntimeError):
    """A requested runfile label is unsafe or cannot be resolved."""


def runfile_candidates(raw: str) -> tuple[str, ...]:
    """Return the legacy Bazel path variants for one safe logical runfile.

    Bazel may expose an external repository as ``external/<repo>/...`` or
    ``<repo>/...`` and Bzlmod may prefix main-repository entries with
    ``_main/``. Leading ``../`` segments are a Bazel ``short_path`` convention;
    parent traversal anywhere else is rejected.
    """
    logical_path = raw.replace("\\", "/")
    if logical_path.startswith("./"):
        logical_path = logical_path[2:]
    while logical_path.startswith("../"):
        logical_path = logical_path[3:]

    parts = logical_path.split("/")
    if (
        not logical_path
        or logical_path.startswith("/")
        or _WINDOWS_ABSOLUTE_RE.match(logical_path)
        or ".." in parts
    ):
        raise RunfileResolutionError(
            f"rejected suspicious runfile label: {raw!r}"
        )

    candidates = [logical_path]
    if logical_path.startswith("external/"):
        candidates.append(logical_path[len("external/") :])
    else:
        candidates.append(f"external/{logical_path}")
    if not logical_path.startswith("_main/"):
        candidates.append(f"_main/{logical_path}")
    return tuple(dict.fromkeys(candidates))


def _manifest_line(line: str, *, first_line: bool) -> tuple[str, str] | None:
    """Parse one Bazel manifest entry without splitting paths at spaces."""
    normalized = line.rstrip("\r\n")
    if first_line:
        normalized = normalized.lstrip("\ufeff")
    if normalized.startswith(" "):
        encoded = normalized[1:]
        separator_index = encoded.find(" ")
        if separator_index <= 0:
            return None
        key = _decode_manifest_field(encoded[:separator_index])
        value = _decode_manifest_field(encoded[separator_index + 1 :])
        if not value:
            return None
        return key.replace("\\", "/"), value
    space_index = normalized.find(" ")
    tab_index = normalized.find("\t")
    indexes = [index for index in (space_index, tab_index) if index >= 0]
    if not indexes:
        return None
    separator_index = min(indexes)
    if separator_index <= 0:
        return None
    key = normalized[:separator_index]
    value = normalized[separator_index + 1 :].strip()
    if not value:
        return None
    return key.replace("\\", "/"), value


def _decode_manifest_field(value: str) -> str:
    """Decode Bazel's escaped runfiles manifest field representation."""
    return value.replace(r"\s", " ").replace(r"\n", "\n").replace(r"\b", "\\")


def _load_manifest(path: Path | None) -> Mapping[str, Path]:
    if path is None or not path.is_file():
        return MappingProxyType({})

    entries: dict[str, Path] = {}
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line_number, line in enumerate(handle):
                entry = _manifest_line(line, first_line=line_number == 0)
                if entry is None:
                    continue
                key, raw_value = entry
                value = Path(raw_value)
                if not value.is_absolute():
                    value = path.parent / value
                entries.setdefault(key, value)
    except OSError as exc:
        raise RunfileResolutionError(
            f"failed to read runfiles manifest {path}: {type(exc).__name__}"
        ) from exc
    return MappingProxyType(entries)


def _unique_existing_directories(paths: Iterable[Path]) -> tuple[Path, ...]:
    result: list[Path] = []
    seen: set[Path] = set()
    for raw_path in paths:
        path = raw_path.resolve()
        if path in seen or not path.is_dir():
            continue
        seen.add(path)
        result.append(path)
    return tuple(result)


def _safe_workspace_name(raw: str) -> str | None:
    normalized = raw.replace("\\", "/").strip("/")
    if not normalized or _WINDOWS_ABSOLUTE_RE.match(normalized):
        return None
    if any(part in {"", ".", ".."} for part in normalized.split("/")):
        return None
    return normalized


@dataclass(frozen=True)
class RunfilesResolver:
    """Read-only resolver safe to share with every uploader worker."""

    cwd: Path
    roots: tuple[Path, ...]
    workspace_names: tuple[str, ...]
    manifest_path: Path | None
    manifest_entries: Mapping[str, Path]

    @classmethod
    def from_environment(
        cls,
        *,
        argv0: str | Path | None = None,
        environ: Mapping[str, str] | None = None,
        cwd: Path | None = None,
    ) -> "RunfilesResolver":
        """Snapshot all process-dependent lookup state once.

        ``environ`` is copied conceptually into immutable paths and strings;
        later environment mutations therefore cannot affect worker lookups.
        """
        environment = dict(os.environ if environ is None else environ)
        working_directory = (cwd or Path.cwd()).resolve()

        root_candidates: list[Path] = []
        for variable in ("RUNFILES_DIR", "TEST_SRCDIR"):
            raw_root = environment.get(variable, "")
            if raw_root:
                root = Path(raw_root)
                root_candidates.append(
                    root if root.is_absolute() else working_directory / root
                )

        if argv0:
            launcher = Path(argv0)
            if not launcher.is_absolute():
                launcher = working_directory / launcher
            root_candidates.extend(
                (
                    Path(f"{launcher}.runfiles"),
                    launcher.parent / f"{launcher.stem}.runfiles",
                    launcher.parent / f"{launcher.name}.runfiles",
                )
            )
            for parent in (launcher.parent, *launcher.parents):
                if parent.name.endswith(".runfiles"):
                    root_candidates.append(parent)
                    break

        workspace_candidates: list[str] = []
        for raw_name in (
            environment.get("TEST_WORKSPACE", ""),
            environment.get("DD_TEST_OPTIMIZATION_RUNFILES_WORKSPACE", ""),
        ):
            safe_name = _safe_workspace_name(raw_name)
            if safe_name is not None:
                workspace_candidates.append(safe_name)
        workspace_names = tuple(dict.fromkeys(workspace_candidates))
        raw_manifest = environment.get("RUNFILES_MANIFEST_FILE", "")
        raw_manifest_path = Path(raw_manifest) if raw_manifest else None
        manifest_path = (
            (
                raw_manifest_path
                if raw_manifest_path.is_absolute()
                else working_directory / raw_manifest_path
            ).resolve()
            if raw_manifest_path is not None
            else None
        )
        return cls(
            cwd=working_directory,
            roots=_unique_existing_directories(root_candidates),
            workspace_names=workspace_names,
            manifest_path=manifest_path,
            manifest_entries=_load_manifest(manifest_path),
        )

    def resolve_file(self, raw_paths: str | Iterable[str]) -> Path:
        """Resolve the first existing direct path or logical runfile.

        Direct filesystem paths are checked first for compatibility with rule
        configuration values that point into Bazel's execroot. Missing absolute
        paths are never reinterpreted as logical runfile labels.
        """
        if isinstance(raw_paths, str):
            requested = (raw_paths,)
        else:
            requested = tuple(raw_paths)
        requested = tuple(raw for raw in requested if raw)
        if not requested:
            raise RunfileResolutionError("no runfile path was provided")

        logical_candidates: list[str] = []
        errors: list[RunfileResolutionError] = []
        for raw in requested:
            direct = Path(raw)
            direct_candidate = direct if direct.is_absolute() else self.cwd / direct
            if direct_candidate.is_file():
                return direct_candidate.resolve()
            if direct.is_absolute() or _WINDOWS_ABSOLUTE_RE.match(raw.replace("\\", "/")):
                continue
            try:
                logical_candidates.extend(runfile_candidates(raw))
            except RunfileResolutionError as exc:
                errors.append(exc)

        candidates = tuple(dict.fromkeys(logical_candidates))
        for root in self.roots:
            for candidate in self._root_candidates(candidates):
                resolved = root.joinpath(*candidate.split("/"))
                if resolved.is_file():
                    return resolved.resolve()

        manifest_match = self._resolve_manifest(candidates)
        if manifest_match is not None:
            return manifest_match

        if not candidates and errors:
            raise errors[0]
        rendered = ", ".join(repr(raw) for raw in requested)
        raise RunfileResolutionError(f"runfile not found for: {rendered}")

    def _root_candidates(self, candidates: tuple[str, ...]) -> tuple[str, ...]:
        expanded = list(candidates)
        for workspace in self.workspace_names:
            expanded.extend(
                f"{workspace}/{candidate}"
                for candidate in candidates
                if not candidate.startswith(f"{workspace}/")
            )
        return tuple(dict.fromkeys(expanded))

    def _resolve_manifest(self, candidates: tuple[str, ...]) -> Path | None:
        lookup_candidates = self._root_candidates(candidates)
        for candidate in lookup_candidates:
            match = self.manifest_entries.get(candidate)
            if match is not None and match.is_file():
                return match.resolve()

        # Preserve the legacy fallback for manifests that add an unknown main
        # repository prefix to otherwise valid keys.
        for candidate in lookup_candidates:
            suffix = f"/{candidate}"
            for key, match in self.manifest_entries.items():
                if key.endswith(suffix) and match.is_file():
                    return match.resolve()
        return None
