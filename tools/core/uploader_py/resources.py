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


@dataclass(frozen=True)
class ResourceInputs:
    """Runfile locations from the rule plus an optional runtime override."""

    context_override: Path | None = None
    context_manifest_paths: tuple[str, ...] = ()
    telemetry_facts_manifest_paths: tuple[str, ...] = ()
    schema_paths: tuple[str, ...] = ()


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


def load_resources(
    resolver: RunfilesResolver,
    inputs: ResourceInputs,
) -> LoadedResources:
    """Resolve contexts, telemetry facts, and schema once with warning fallback."""
    warnings: list[str] = []
    override_path = _existing_file(inputs.context_override)
    override_context = _load_json_object(override_path) if override_path else None
    if inputs.context_override is not None and override_context is None:
        warnings.append("context_override_invalid")

    context_records: list[ContextRecord] = []
    primary_path: Path | None = None
    runtime_override_enabled = override_context is not None
    if override_context is not None:
        context_records.append(ContextRecord.create("__runtime_override__", override_context))
        primary_path = override_path
    else:
        manifest = _resolve_optional(resolver, inputs.context_manifest_paths)
        if inputs.context_manifest_paths and manifest is None:
            warnings.append("context_manifest_unresolved")
        if manifest is not None:
            seen_repo_keys: set[str] = set()
            for repo_key, short_path, artifact_path in _context_manifest_entries(
                manifest,
                warnings,
            ):
                normalized_repo_key = repo_key.rsplit("+", 1)[-1]
                if normalized_repo_key in seen_repo_keys:
                    warnings.append("context_manifest_duplicate_repo")
                    continue
                resolved = _resolve_optional(
                    resolver,
                    (artifact_path, short_path),
                )
                context = _load_json_object(resolved) if resolved else None
                if context is None:
                    warnings.append("context_entry_invalid")
                    continue
                seen_repo_keys.add(normalized_repo_key)
                context_records.append(
                    ContextRecord.create(normalized_repo_key, context)
                )
                if primary_path is None:
                    primary_path = resolved

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
            resolved = _resolve_optional(resolver, (artifact_path, short_path))
            if resolved is None:
                warnings.append("telemetry_facts_entry_unresolved")
                continue
            telemetry_facts_paths.append(resolved)
    if runtime_override_enabled and primary_path is not None:
        sibling = primary_path.parent / "telemetry_facts.json"
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
        primary_context_path=primary_path,
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
