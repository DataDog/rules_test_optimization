# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Resolve contexts, telemetry facts, and schema before workers start.

Loading once removes runfiles I/O and mutable resource selection from workers.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any, Iterable

from topt_runtime.runfiles import RunfileResolutionError, RunfilesResolver

from .enrichment import ContextPlan, ContextRecord
from .json_utils import strict_json_loads


class ResourceError(ValueError):
    """Runtime-selected resources are incomplete or inconsistent."""


@dataclass(frozen=True)
class ResourceInputs:
    """Runfile locations plus optional execution-time target context choices."""

    context_override: Path | None = None
    context_manifest_paths: tuple[str, ...] = ()
    telemetry_facts_manifest_paths: tuple[str, ...] = ()
    schema_paths: tuple[str, ...] = ()
    runtime_context_entries: tuple[str, ...] = ()
    runtime_selection: bool = False
    workspace: Path | None = None
    invocation_cwd: Path | None = None


@dataclass(frozen=True)
class LoadedResources:
    """Validated read-only resources safe to share with every worker."""

    context_plan: ContextPlan
    primary_context: dict[str, Any] | None
    primary_context_path: Path | None
    telemetry_facts_paths: tuple[Path, ...]
    schema: dict[str, Any] | None
    warning_codes: tuple[str, ...] = ()

    @property
    def context_workspace(self) -> str:
        if self.primary_context is None:
            return ""
        value = self.primary_context.get("ci.workspace_path")
        return value if isinstance(value, str) else ""


@dataclass(frozen=True)
class _RuntimeContext:
    """One validated context and its matching telemetry facts."""

    repo_key: str
    context_path: Path
    context: dict[str, Any]
    telemetry_path: Path


def load_resources(
    resolver: RunfilesResolver,
    inputs: ResourceInputs,
) -> LoadedResources:
    """Resolve contexts, telemetry facts, and schema once with warning fallback."""
    warnings: list[str] = []
    override_path = _existing_file(inputs.context_override)
    override_values = _load_json_object(override_path) if override_path else None
    if inputs.context_override is not None and override_values is None:
        warnings.append("context_override_invalid")

    runtime_contexts = _load_runtime_contexts(
        inputs.runtime_context_entries,
        workspace=inputs.workspace,
        invocation_cwd=inputs.invocation_cwd,
    )
    if inputs.runtime_selection and not runtime_contexts:
        raise ResourceError(
            "runtime selection requires at least one --context-entry argument"
        )

    context_records: list[ContextRecord] = []
    primary_context_path: Path | None = None
    runtime_override_enabled = override_values is not None
    if override_values is not None:
        context_records.append(
            ContextRecord.create("__runtime_override__", override_values)
        )
        primary_context_path = override_path
    elif runtime_contexts:
        for runtime_context in runtime_contexts:
            context_records.append(
                ContextRecord.create(
                    runtime_context.repo_key,
                    runtime_context.context,
                )
            )
            if primary_context_path is None:
                primary_context_path = runtime_context.context_path
    else:
        context_manifest = _resolve_optional(resolver, inputs.context_manifest_paths)
        if inputs.context_manifest_paths and context_manifest is None:
            warnings.append("context_manifest_unresolved")
        if context_manifest is not None:
            seen_repo_keys: set[str] = set()
            for repo_key, short_path, artifact_path in _context_manifest_entries(
                context_manifest,
                warnings,
            ):
                normalized_repo_key = repo_key.rsplit("+", 1)[-1]
                if normalized_repo_key in seen_repo_keys:
                    warnings.append("context_manifest_duplicate_repo")
                    continue
                context_path = _resolve_optional(
                    resolver,
                    (artifact_path, short_path),
                )
                context_values = _load_json_object(context_path) if context_path else None
                if context_values is None:
                    warnings.append("context_entry_invalid")
                    continue
                seen_repo_keys.add(normalized_repo_key)
                context_records.append(
                    ContextRecord.create(normalized_repo_key, context_values)
                )
                if primary_context_path is None:
                    primary_context_path = context_path

    primary_context_record = context_records[0] if context_records else None
    primary_context = (
        dict(primary_context_record.values) if primary_context_record else None
    )
    context_plan = ContextPlan(
        primary=primary_context_record,
        by_repo=tuple(context_records),
        override=runtime_override_enabled,
    )

    telemetry_facts_paths: list[Path] = []
    if runtime_contexts:
        telemetry_facts_paths.extend(item.telemetry_path for item in runtime_contexts)
    else:
        telemetry_manifest = _resolve_optional(
            resolver,
            inputs.telemetry_facts_manifest_paths,
        )
        if inputs.telemetry_facts_manifest_paths and telemetry_manifest is None:
            warnings.append("telemetry_facts_manifest_unresolved")
        if telemetry_manifest is not None:
            for short_path, artifact_path in _two_column_manifest_entries(
                telemetry_manifest,
                warnings,
                "telemetry_facts_manifest_invalid",
            ):
                facts_path = _resolve_optional(resolver, (artifact_path, short_path))
                if facts_path is None:
                    warnings.append("telemetry_facts_entry_unresolved")
                    continue
                telemetry_facts_paths.append(facts_path)
    if runtime_override_enabled and primary_context_path is not None:
        sibling = primary_context_path.parent / "telemetry_facts.json"
        if sibling.is_file():
            telemetry_facts_paths.append(sibling.resolve())
    telemetry_facts_paths = list(dict.fromkeys(sorted(telemetry_facts_paths)))

    schema_path = _resolve_optional(resolver, inputs.schema_paths)
    schema = _load_json_object(schema_path) if schema_path else None
    if inputs.schema_paths and schema is None:
        warnings.append("schema_invalid_or_unresolved")
    return LoadedResources(
        context_plan=context_plan,
        primary_context=primary_context,
        primary_context_path=primary_context_path,
        telemetry_facts_paths=tuple(telemetry_facts_paths),
        schema=schema,
        warning_codes=tuple(dict.fromkeys(warnings)),
    )


def _context_manifest_entries(
    path: Path,
    warnings: list[str],
) -> tuple[tuple[str, str, str], ...]:
    entries: list[tuple[str, str, str]] = []
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except (OSError, UnicodeError):
        warnings.append("context_manifest_invalid")
        return ()
    for line in lines:
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 3 or not fields[0] or not (fields[1] or fields[2]):
            warnings.append("context_manifest_invalid")
            continue
        entries.append((fields[0], fields[1], fields[2]))
    return tuple(entries)


def _two_column_manifest_entries(
    path: Path,
    warnings: list[str],
    warning_code: str,
) -> tuple[tuple[str, str], ...]:
    entries: list[tuple[str, str]] = []
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except (OSError, UnicodeError):
        warnings.append(warning_code)
        return ()
    for line in lines:
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 2 or not (fields[0] or fields[1]):
            warnings.append(warning_code)
            continue
        entries.append((fields[0], fields[1]))
    return tuple(entries)


def _resolve_optional(
    resolver: RunfilesResolver,
    candidates: Iterable[str],
) -> Path | None:
    values = tuple(candidate for candidate in candidates if candidate)
    if not values:
        return None
    try:
        return resolver.resolve_file(values)
    except RunfileResolutionError:
        return None


def _existing_file(path: Path | None) -> Path | None:
    return path.resolve() if path is not None and path.is_file() else None


def _load_json_object(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    try:
        value = strict_json_loads(path.read_bytes().decode("utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


_APPARENT_REPO_NAME_CHARS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-"
)


def _load_runtime_contexts(
    entries: Iterable[str],
    *,
    workspace: Path | None,
    invocation_cwd: Path | None,
) -> tuple[_RuntimeContext, ...]:
    """Validate keyed contexts before discovery or worker startup."""
    contexts: list[_RuntimeContext] = []
    seen_repos: set[str] = set()
    seen_paths: set[Path] = set()
    for entry in entries:
        repo_key, separator, raw_path = entry.partition("=")
        if (
            not separator
            or not raw_path
            or not repo_key
            or any(character not in _APPARENT_REPO_NAME_CHARS for character in repo_key)
        ):
            raise ResourceError(
                "--context-entry must use <apparent-repo-name>=<context-json-path>"
            )
        if repo_key in seen_repos:
            raise ResourceError(
                f"duplicate --context-entry repository name: {repo_key!r}"
            )
        context_path = _resolve_runtime_path(
            raw_path,
            workspace=workspace,
            invocation_cwd=invocation_cwd,
        )
        if context_path is None or context_path.name != "context.json":
            raise ResourceError(
                f"context entry for {repo_key!r} must reference an existing "
                "regular context.json file"
            )
        if context_path in seen_paths:
            raise ResourceError(
                f"duplicate --context-entry path for repository {repo_key!r}"
            )
        telemetry_path = context_path.with_name("telemetry_facts.json")
        if not telemetry_path.is_file():
            raise ResourceError(
                f"context entry for {repo_key!r} is missing sibling telemetry_facts.json"
            )
        telemetry_path = telemetry_path.resolve()

        context = _load_json_object(context_path)
        telemetry = _load_json_object(telemetry_path)
        service_name = context.get("service.name") if context is not None else None
        runtime_name = context.get("runtime.name") if context is not None else None
        valid = (
            context is not None
            and context.get("topt.sync.repository_name") == repo_key
            and isinstance(service_name, str)
            and bool(service_name)
            and isinstance(runtime_name, str)
            and bool(runtime_name)
            and telemetry is not None
            and telemetry.get("schema_version") == 1
            and telemetry.get("service_name") == service_name
            and telemetry.get("runtime_name") == runtime_name
            and isinstance(telemetry.get("counts"), list)
            and isinstance(telemetry.get("distributions"), list)
        )
        if not valid:
            raise ResourceError(
                "runtime context/telemetry identity or schema mismatch for "
                f"repository {repo_key!r}"
            )
        seen_repos.add(repo_key)
        seen_paths.add(context_path)
        contexts.append(
            _RuntimeContext(repo_key, context_path, context, telemetry_path)
        )
    return tuple(sorted(contexts, key=lambda item: item.repo_key))


def _resolve_runtime_path(
    raw_path: str,
    *,
    workspace: Path | None,
    invocation_cwd: Path | None,
) -> Path | None:
    path = Path(raw_path).expanduser()
    candidates = (path,) if path.is_absolute() else tuple(
        root / path
        for root in (invocation_cwd, workspace)
        if root is not None
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    return None
