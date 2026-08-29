# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Deterministic preventive splitting for enriched test JSON payloads."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .json_utils import strict_json_dumps
from .models import MAX_TEST_PAYLOAD_BYTES


class TestPayloadSplitError(ValueError):
    """A test payload cannot be safely represented as bounded chunks."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class PreparedTestChunk:
    """One exact compact JSON request body stored in task-local space."""

    index: int
    path: Path
    size_bytes: int
    event_start: int
    event_end: int

    @property
    def event_count(self) -> int:
        return self.event_end - self.event_start


def compact_json_bytes(value: Any) -> bytes:
    """Serialize using the one canonical uploader JSON representation."""
    try:
        return strict_json_dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise TestPayloadSplitError(
            "test_payload_not_json_serializable",
            f"test payload is not JSON serializable: {exc}",
        ) from exc


def prepare_test_chunks(
    payload: Mapping[str, Any],
    task_directory: Path,
    *,
    limit_bytes: int = MAX_TEST_PAYLOAD_BYTES,
) -> tuple[PreparedTestChunk, ...]:
    """Write exact bounded bodies before any caller may perform HTTP."""
    if isinstance(payload, dict):
        payload_object = payload
    else:
        raise TestPayloadSplitError(
            "invalid_test_payload",
            "test payload must be a JSON object",
        )
    if any(not isinstance(key, str) for key in payload_object):
        raise TestPayloadSplitError(
            "invalid_test_payload",
            "test payload object keys must be strings",
        )
    if isinstance(limit_bytes, bool) or not isinstance(limit_bytes, int) or limit_bytes <= 0:
        raise ValueError("limit_bytes must be a positive integer")
    events = payload_object.get("events")
    if not isinstance(events, list) or not events:
        raise TestPayloadSplitError(
            "test_payload_without_events",
            "test payload must contain a non-empty events array",
        )
    if not task_directory.is_dir():
        raise TestPayloadSplitError(
            "test_chunk_directory_unavailable",
            f"test chunk directory does not exist: {task_directory}",
        )

    full_body = compact_json_bytes(payload_object)
    if len(full_body) <= limit_bytes:
        return (_write_chunk(task_directory, 1, full_body, 0, len(events)),)

    prefix, suffix = _event_array_frame(payload_object)
    base_size = len(prefix) + len(suffix)
    if base_size > limit_bytes:
        raise TestPayloadSplitError(
            "test_payload_envelope_exceeds_payload_limit",
            f"test payload envelope is {base_size} bytes; limit is {limit_bytes}",
        )

    serialized_events = tuple(compact_json_bytes(event) for event in events)
    for event_index, event_body in enumerate(serialized_events):
        event_size = base_size + len(event_body)
        if event_size > limit_bytes:
            raise TestPayloadSplitError(
                "single_event_exceeds_payload_limit",
                (
                    f"event index {event_index} requires {event_size} bytes with the "
                    f"payload envelope; limit is {limit_bytes}"
                ),
            )

    ranges: list[tuple[int, int]] = []
    range_start = 0
    current_size = base_size
    for event_index, event_body in enumerate(serialized_events):
        separator_size = 0 if event_index == range_start else 1
        candidate_size = current_size + separator_size + len(event_body)
        if candidate_size <= limit_bytes:
            current_size = candidate_size
            continue
        ranges.append((range_start, event_index))
        range_start = event_index
        current_size = base_size + len(event_body)
    ranges.append((range_start, len(serialized_events)))

    prepared: list[PreparedTestChunk] = []
    for chunk_index, (event_start, event_end) in enumerate(ranges, start=1):
        body = prefix + b",".join(serialized_events[event_start:event_end]) + suffix
        if len(body) > limit_bytes:
            raise AssertionError("internal split invariant violated: chunk exceeds byte limit")
        prepared.append(
            _write_chunk(
                task_directory,
                chunk_index,
                body,
                event_start,
                event_end,
            )
        )
    return tuple(prepared)


def _event_array_frame(payload: Mapping[str, Any]) -> tuple[bytes, bytes]:
    before: list[bytes] = []
    after: list[bytes] = []
    destination = before
    found_events = False
    for key, value in payload.items():
        encoded_key = compact_json_bytes(key)
        if key == "events":
            found_events = True
            destination = after
            continue
        encoded_entry = encoded_key + b":" + compact_json_bytes(value)
        destination.append(encoded_entry)
    if not found_events:
        raise TestPayloadSplitError(
            "test_payload_without_events",
            "test payload must contain a non-empty events array",
        )

    prefix = b"{"
    if before:
        prefix += b",".join(before) + b","
    prefix += compact_json_bytes("events") + b":["
    suffix = b"]"
    if after:
        suffix += b"," + b",".join(after)
    suffix += b"}"
    return prefix, suffix


def _write_chunk(
    task_directory: Path,
    index: int,
    body: bytes,
    event_start: int,
    event_end: int,
) -> PreparedTestChunk:
    path = task_directory / f"test_chunk_{index:04d}.json"
    try:
        path.write_bytes(body)
    except OSError as exc:
        raise TestPayloadSplitError(
            "test_chunk_write_failed",
            f"failed to write test chunk {index}: {exc}",
        ) from exc
    return PreparedTestChunk(
        index=index,
        path=path,
        size_bytes=len(body),
        event_start=event_start,
        event_end=event_end,
    )
