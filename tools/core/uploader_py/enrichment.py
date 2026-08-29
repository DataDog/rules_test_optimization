# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Apply context, Bazel metadata, and CODEOWNERS to one test payload.

Keeping enrichment pure and isolated makes concurrent transformations testable.
"""

from __future__ import annotations

from dataclasses import dataclass
from types import MappingProxyType
from typing import Any, Mapping

from .codeowners import (
    CodeOwnersEnrichmentStats,
    CodeOwnersMatch,
    CodeOwnersMatcher,
    enrich_payload_codeowners,
)
from .json_utils import strict_json_dumps


TOP_LEVEL_EVENT_METADATA_KEYS = (
    "test",
    "test_suite_end",
    "test_module_end",
    "test_session_end",
)
CONTEXT_EXCLUDED_EVENT_KEYS = frozenset({"topt.api_key_fingerprint"})


@dataclass(frozen=True)
class ContextRecord:
    repo_key: str
    values: Mapping[str, Any]

    @classmethod
    def create(cls, repo_key: str, values: Mapping[str, Any]) -> "ContextRecord":
        return cls(repo_key, MappingProxyType(dict(values)))


@dataclass(frozen=True)
class ContextSelection:
    values: Mapping[str, Any] | None
    warning_code: str | None = None


@dataclass(frozen=True)
class ContextPlan:
    """Invocation-wide contexts loaded once and selected per source file."""

    primary: ContextRecord | None
    by_repo: tuple[ContextRecord, ...] = ()
    override: bool = False

    def select(self, repo_key: str | None) -> ContextSelection:
        if self.override or len(self.by_repo) <= 1:
            return ContextSelection(self.primary.values if self.primary else None)
        if not repo_key:
            return ContextSelection(None, "context_repo_metadata_missing")
        for record in self.by_repo:
            if record.repo_key == repo_key:
                return ContextSelection(record.values)
        return ContextSelection(None, "context_repo_not_found")


@dataclass(frozen=True)
class EnrichmentResult:
    codeowners: CodeOwnersEnrichmentStats
    warning_codes: tuple[str, ...] = ()


def payload_repo_key(bazel_metadata: Mapping[str, Any] | None) -> str | None:
    if bazel_metadata is None:
        return None
    value = bazel_metadata.get("bazel.test_optimization.repo_name")
    return value if isinstance(value, str) and value else None


def enrich_test_payload(
    payload: dict[str, Any],
    *,
    context_selection: ContextSelection,
    bazel_metadata: Mapping[str, Any] | None,
    runtime_id: str,
    rules_version: str,
    codeowners_matcher: CodeOwnersMatcher,
    codeowners_cache: dict[str, CodeOwnersMatch] | None = None,
) -> EnrichmentResult:
    """Apply the complete non-I/O enrichment sequence to one worker payload."""
    context = context_selection.values or {}
    metadata = payload.get("metadata")
    if not isinstance(metadata, dict):
        metadata = {}
    global_metadata = metadata.get("*")
    if not isinstance(global_metadata, dict):
        global_metadata = {}

    normalized_global_metadata = {
        "runtime-id": _first_nonempty_string(
            global_metadata.get("runtime-id"),
            context.get("runtime-id"),
            context.get("runtime.id"),
            context.get("runtime_id"),
            runtime_id,
        ),
        "language": _first_nonempty_string(
            global_metadata.get("language"),
            context.get("language"),
            context.get("runtime.name"),
            context.get("runtime_name"),
            "bazel",
        ),
        "library_version": _first_nonempty_string(
            global_metadata.get("library_version"),
            rules_version,
        ),
    }
    environment = _first_nonempty_string(
        global_metadata.get("env"),
        context.get("env"),
    )
    if environment:
        normalized_global_metadata["env"] = environment

    normalized_metadata: dict[str, Any] = {"*": normalized_global_metadata}
    for key in TOP_LEVEL_EVENT_METADATA_KEYS:
        if key in metadata and metadata[key] is not None:
            normalized_metadata[key] = metadata[key]
    payload["metadata"] = normalized_metadata

    events = payload.get("events")
    if isinstance(events, list):
        context_values = {
            key: value
            for key, value in context.items()
            if key not in CONTEXT_EXCLUDED_EVENT_KEYS
        }
        for event in events:
            if not isinstance(event, dict):
                continue
            content = event.get("content")
            if not isinstance(content, dict):
                content = {}
                event["content"] = content
            meta = content.get("meta")
            if not isinstance(meta, dict):
                meta = {}
                content["meta"] = meta
            metrics = content.get("metrics")
            if not isinstance(metrics, dict):
                metrics = {}
                content["metrics"] = metrics
            _merge_flat_metadata(meta, metrics, context_values)
            if bazel_metadata is not None:
                _merge_flat_metadata(meta, metrics, bazel_metadata)

    codeowners_stats = enrich_payload_codeowners(
        payload,
        codeowners_matcher,
        cache=codeowners_cache,
    )
    warnings = (
        (context_selection.warning_code,)
        if context_selection.warning_code is not None
        else ()
    )
    return EnrichmentResult(codeowners_stats, warnings)


def _first_nonempty_string(*values: Any) -> str:
    for value in values:
        if isinstance(value, str) and value:
            return value
    return ""


def _merge_flat_metadata(
    meta: dict[str, Any],
    metrics: dict[str, Any],
    values: Mapping[str, Any],
) -> None:
    for key, value in values.items():
        if isinstance(value, bool):
            meta[key] = "true" if value else "false"
        elif isinstance(value, (int, float)):
            metrics[key] = value
        elif isinstance(value, str):
            meta[key] = value
        else:
            meta[key] = strict_json_dumps(
                value,
                ensure_ascii=False,
                separators=(",", ":"),
            )
