# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Build a read-only, per-source telemetry augmentation plan before workers."""

from __future__ import annotations

from dataclasses import dataclass, replace
import json
from pathlib import Path
import time
from typing import Any, Callable, Iterable, Mapping

from .models import FileTask, PayloadType


@dataclass(frozen=True)
class TelemetryDirective:
    """Instructions that one telemetry file worker can execute independently."""

    env_override: str = ""
    messages_json: bytes = b""
    append_messages: bool = False
    create_synthetic: bool = False
    synthetic_seq_id: int = 0
    synthetic_timestamp: int = 0

    @property
    def request_count(self) -> int:
        return 1 + int(self.create_synthetic)


@dataclass(frozen=True)
class TelemetryPlan:
    """Immutable lookup prepared once before worker threads are started."""

    entries: tuple[tuple[str, TelemetryDirective], ...] = ()
    provider_suffix: str = ""
    warning_codes: tuple[str, ...] = ()

    def directive_for(self, source_path: Path) -> TelemetryDirective:
        key = _path_key(source_path)
        for planned_path, directive in self.entries:
            if planned_path == key:
                return directive
        return TelemetryDirective()


@dataclass(frozen=True)
class _Candidate:
    path_key: str
    service_name: str
    language_name: str
    runtime_id: str
    seq_id: int | None
    request_type: str


@dataclass(frozen=True)
class _Facts:
    path_key: str
    service_name: str
    runtime_name: str
    environment: str
    counts: tuple[Any, ...]
    distributions: tuple[Any, ...]


def build_telemetry_plan(
    tasks: Iterable[FileTask],
    facts_paths: Iterable[Path],
    *,
    primary_context: Mapping[str, Any] | None = None,
    clock: Callable[[], float] = time.time,
) -> TelemetryPlan:
    """Match rule facts to tracer streams without materializing outbound files."""
    warnings: list[str] = []
    candidates = _load_candidates(tasks, warnings)
    provider_suffix = _provider_suffix(primary_context)
    if not candidates:
        return TelemetryPlan(
            provider_suffix=provider_suffix,
            warning_codes=_unique_codes(warnings),
        )

    grouped_candidates: dict[tuple[str, str], list[_Candidate]] = {}
    for candidate in candidates:
        grouped_candidates.setdefault(
            (candidate.service_name, candidate.language_name), []
        ).append(candidate)

    grouped_facts: dict[tuple[str, str], list[_Facts]] = {}
    for facts_path in sorted(facts_paths, key=lambda item: str(item)):
        facts = _load_facts(facts_path, warnings)
        if facts is None:
            continue
        matching = [
            candidate
            for candidate in candidates
            if candidate.service_name == facts.service_name
        ]
        if not matching:
            warnings.append("telemetry_facts_anchor_missing")
            continue
        languages = sorted({candidate.language_name for candidate in matching})
        if len(languages) == 1:
            language_name = languages[0]
        else:
            selected_languages = sorted(
                {
                    candidate.language_name
                    for candidate in matching
                    if candidate.language_name == facts.runtime_name
                }
            )
            if len(selected_languages) != 1:
                warnings.append("telemetry_facts_language_ambiguous")
                continue
            language_name = selected_languages[0]
        grouped_facts.setdefault((facts.service_name, language_name), []).append(facts)

    directives: dict[str, TelemetryDirective] = {}
    for group_key in sorted(grouped_facts):
        group_candidates = sorted(
            grouped_candidates.get(group_key, ()),
            key=lambda item: item.path_key,
        )
        if not group_candidates:
            continue
        facts_entries = sorted(
            grouped_facts[group_key],
            key=lambda item: item.path_key,
        )
        environments = sorted(
            {facts.environment for facts in facts_entries if facts.environment}
        )
        if len(environments) > 1:
            warnings.append("telemetry_facts_env_conflict")
            continue
        env_override = environments[0] if environments else ""
        if env_override:
            for candidate in group_candidates:
                directives[candidate.path_key] = TelemetryDirective(
                    env_override=env_override
                )

        counts: list[Any] = []
        distributions: list[Any] = []
        for facts in facts_entries:
            counts.extend(facts.counts)
            distributions.extend(facts.distributions)
        timestamp = int(clock())
        messages = _build_inner_messages(counts, distributions, timestamp)
        if not messages:
            continue

        streams: dict[str, list[_Candidate]] = {}
        for candidate in group_candidates:
            streams.setdefault(candidate.runtime_id, []).append(candidate)
        chosen_stream = max(
            streams.values(),
            key=lambda items: (
                any(item.request_type == "message-batch" for item in items),
                _stream_best_path(items),
            ),
        )
        batch_candidates = [
            candidate
            for candidate in chosen_stream
            if candidate.request_type == "message-batch"
        ]
        anchor = max(batch_candidates or chosen_stream, key=lambda item: item.path_key)
        current = directives.get(anchor.path_key, TelemetryDirective())
        encoded_messages = json.dumps(
            messages,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        if anchor.request_type == "message-batch":
            directives[anchor.path_key] = replace(
                current,
                messages_json=encoded_messages,
                append_messages=True,
            )
        else:
            max_seq_id = max(
                (
                    candidate.seq_id
                    for candidate in chosen_stream
                    if candidate.seq_id is not None
                ),
                default=0,
            )
            directives[anchor.path_key] = replace(
                current,
                messages_json=encoded_messages,
                create_synthetic=True,
                synthetic_seq_id=max_seq_id + 1,
                synthetic_timestamp=timestamp,
            )

    return TelemetryPlan(
        entries=tuple(sorted(directives.items())),
        provider_suffix=provider_suffix,
        warning_codes=_unique_codes(warnings),
    )


def _load_candidates(
    tasks: Iterable[FileTask], warnings: list[str]
) -> tuple[_Candidate, ...]:
    candidates: list[_Candidate] = []
    telemetry_tasks = sorted(
        (task for task in tasks if task.payload_type is PayloadType.TELEMETRY),
        key=lambda task: str(task.source_path),
    )
    for task in telemetry_tasks:
        payload = _read_json_object(task.source_path)
        if payload is None:
            warnings.append("telemetry_plan_input_invalid")
            continue
        application = payload.get("application")
        if not isinstance(application, dict):
            continue
        service_name = _string(application.get("service_name"))
        language_name = _string(application.get("language_name"))
        api_version = _string(payload.get("api_version"))
        request_type = _string(payload.get("request_type"))
        if not service_name or not language_name or not api_version or not request_type:
            continue
        seq_id = payload.get("seq_id")
        candidates.append(
            _Candidate(
                path_key=_path_key(task.source_path),
                service_name=service_name,
                language_name=language_name,
                runtime_id=_string(payload.get("runtime_id")),
                seq_id=(
                    seq_id
                    if isinstance(seq_id, int) and not isinstance(seq_id, bool)
                    else None
                ),
                request_type=request_type,
            )
        )
    return tuple(candidates)


def _load_facts(path: Path, warnings: list[str]) -> _Facts | None:
    payload = _read_json_object(path)
    if payload is None:
        warnings.append("telemetry_facts_invalid")
        return None
    if not _string(payload.get("service_name")):
        warnings.append("telemetry_facts_service_missing")
        return None
    counts = payload.get("counts")
    distributions = payload.get("distributions")
    return _Facts(
        path_key=_path_key(path),
        service_name=_string(payload.get("service_name")),
        runtime_name=_string(payload.get("runtime_name")),
        environment=_string(payload.get("env")),
        counts=tuple(counts) if isinstance(counts, list) else (),
        distributions=(
            tuple(distributions) if isinstance(distributions, list) else ()
        ),
    )


def _read_json_object(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_bytes().decode("utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _build_inner_messages(
    counts: Iterable[Any], distributions: Iterable[Any], timestamp: int
) -> list[dict[str, Any]]:
    count_series = []
    for fact in counts:
        if not isinstance(fact, dict):
            continue
        name = _string(fact.get("name"))
        if not name:
            continue
        tags = fact.get("tags")
        count_series.append(
            {
                "metric": name,
                "points": [[timestamp, fact.get("value")]],
                "type": "count",
                "tags": tags if isinstance(tags, list) else [],
                "common": True,
                "namespace": "civisibility",
            }
        )

    distribution_series = []
    for fact in distributions:
        if not isinstance(fact, dict):
            continue
        name = _string(fact.get("name"))
        if not name:
            continue
        tags = fact.get("tags")
        distribution_series.append(
            {
                "metric": name,
                "points": [fact.get("value")],
                "tags": tags if isinstance(tags, list) else [],
                "common": True,
                "namespace": "civisibility",
            }
        )

    messages: list[dict[str, Any]] = []
    if count_series:
        messages.append(
            {
                "request_type": "generate-metrics",
                "payload": {"namespace": "civisibility", "series": count_series},
            }
        )
    if distribution_series:
        messages.append(
            {
                "request_type": "distributions",
                "payload": {"namespace": "", "series": distribution_series},
            }
        )
    return messages


def _stream_best_path(items: Iterable[_Candidate]) -> str:
    candidates = tuple(items)
    batches = sorted(
        item.path_key for item in candidates if item.request_type == "message-batch"
    )
    return batches[-1] if batches else max(item.path_key for item in candidates)


def _provider_suffix(context: Mapping[str, Any] | None) -> str:
    if context is None:
        return ""
    return (
        _string(context.get("ci.provider.name"))
        or _string(context.get("ci_provider_name"))
    ).strip()


def _path_key(path: Path) -> str:
    return str(path.resolve(strict=False))


def _string(value: Any) -> str:
    return value if isinstance(value, str) else ""


def _unique_codes(codes: Iterable[str]) -> tuple[str, ...]:
    return tuple(dict.fromkeys(code for code in codes if code))
