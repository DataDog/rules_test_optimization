# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Prepare compatible test envelopes without sharing process identity.

Only an owned, enriched source is mutated. Source files remain unchanged until
their complete request is acknowledged. Each event keeps its effective runtime
ID; the envelope retains one required global fallback. Other envelope fields
remain part of the compatibility key.
"""

from __future__ import annotations

from copy import deepcopy
from typing import Any

from .json_utils import strict_json_dumps


class BatchCompatibilityError(ValueError):
    """A source must retain the ordinary per-file upload path."""


_TEST_LEVEL_TYPES = frozenset(("test", "test_suite_end", "test_module_end", "test_session_end"))
_FIXED_TYPES = _TEST_LEVEL_TYPES | {"span"}
_SHARED_METADATA_PREFIXES = ("bazel.", "git.", "ci.", "os.", "runtime.")


def compact_shared_metadata(payload: dict[str, Any]) -> int:
    """Move common enrichment tags in an owned request to its global defaults.

    Only string tags present with the same value in every supported event can
    move. Leave keys mentioned in another metadata scope alone: fixed-type
    overrides have different precedence. Protocol fields and process IDs stay
    in their existing locations. No caller-owned source file is changed.
    """
    metadata, events = payload.get("metadata"), payload.get("events")
    if type(payload.get("version")) is not int or payload["version"] != 1 or not isinstance(metadata, dict):
        return 0
    if not isinstance(events, list) or len(events) < 2:
        return 0
    if any(not isinstance(scope, dict) for scope in metadata.values()):
        return 0
    global_meta = metadata.get("*")
    if not isinstance(global_meta, dict):
        return 0
    event_metadata = []
    for event in events:
        if not isinstance(event, dict) or not isinstance(event.get("type"), str) or event["type"] not in _FIXED_TYPES:
            return 0
        content = event.get("content")
        if not isinstance(content, dict) or not isinstance(content.get("meta"), dict):
            return 0
        event_metadata.append(content["meta"])
    overrides = {key for name, scope in metadata.items() if name != "*" for key in scope}
    common = {
        key: value for key, value in event_metadata[0].items()
        if isinstance(key, str) and key.startswith(_SHARED_METADATA_PREFIXES)
        and isinstance(value, str) and key not in overrides
    }
    for event_meta in event_metadata[1:]:
        different = [key for key, value in common.items() if event_meta.get(key) != value]
        for key in different:
            del common[key]
        if not common:
            return 0
    global_meta.update(common)
    for event_meta in event_metadata:
        for key in common:
            del event_meta[key]
    return len(common) * len(events)


def localize_runtime_ids(payload: dict[str, Any], *, max_additional_bytes: int | None = None) -> bytes:
    """Materialize effective event IDs and return the normalized envelope key.

    Fixed-type defaults win over event values, then test-level and global
    defaults. The canonical global fallback stays in the payload; only the
    compatibility key omits it so different processes can share a request.
    Validate the complete source before mutation so an unsupported source can
    safely use the existing per-file path. No other metadata is moved or dropped.
    """
    metadata = payload.get("metadata")
    events = payload.get("events")
    if not isinstance(metadata, dict) or not isinstance(events, list) or not events:
        raise BatchCompatibilityError("expected metadata and a nonempty events array")
    if any(not isinstance(values, dict) for values in metadata.values()):
        raise BatchCompatibilityError("metadata scopes must be objects")
    global_meta = metadata.get("*", {})
    if not isinstance(global_meta.get("runtime-id"), str) or not global_meta["runtime-id"]:
        raise BatchCompatibilityError("expected a nonempty global runtime-id")
    runtime_ids = []
    additional_bytes = 0
    runtime_sizes: dict[str, int] = {}
    for event in events:
        if not isinstance(event, dict) or not isinstance(event.get("type"), str):
            raise BatchCompatibilityError("expected a typed event")
        content = event.get("content")
        if not isinstance(content, dict) or not isinstance(content.get("meta", {}), dict):
            raise BatchCompatibilityError("expected event content and metadata objects")
        event_meta = content.get("meta", {})
        event_type = event["type"]
        type_meta = metadata.get(event_type, {}) if event_type in _FIXED_TYPES else {}
        level_meta = metadata.get("test_levels", {}) if event_type in _TEST_LEVEL_TYPES else {}
        # An explicitly malformed value is not a missing default.
        runtime_id = type_meta.get("runtime-id", event_meta.get("runtime-id",
            level_meta.get("runtime-id", global_meta["runtime-id"])))
        if not isinstance(runtime_id, str) or not runtime_id:
            raise BatchCompatibilityError("each event must have a nonempty runtime-id")
        if max_additional_bytes is not None and event_meta.get("runtime-id") != runtime_id:
            if runtime_id not in runtime_sizes:
                runtime_sizes[runtime_id] = len(strict_json_dumps(runtime_id, ensure_ascii=False).encode("utf-8"))
            # Conservatively include commas and a new meta object if needed.
            # Check before mutation/serialization: one large default must not
            # expand into an unbounded repeated string across the events.
            additional_bytes += runtime_sizes[runtime_id] + len('"runtime-id":') + 1
            if "meta" not in content:
                additional_bytes += len('"meta":{}') + 1
            if additional_bytes > max_additional_bytes:
                raise BatchCompatibilityError("event-local runtime IDs exceed the request budget")
        runtime_ids.append(runtime_id)

    for event, runtime_id in zip(events, runtime_ids):
        event["content"].setdefault("meta", {})["runtime-id"] = runtime_id
    for scope in (*_FIXED_TYPES, "test_levels"):
        if scope in metadata:
            metadata[scope].pop("runtime-id", None)
    envelope = {key: value for key, value in payload.items() if key != "events"}
    envelope["metadata"] = dict(metadata)
    envelope["metadata"]["*"] = {key: value for key, value in global_meta.items() if key != "runtime-id"}
    return strict_json_dumps(envelope, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def schema_for_event_runtime_ids(schema: dict[str, Any] | None) -> dict[str, Any] | None:
    """Add per-event IDs while retaining the canonical global requirement.

    Ordinary source validation keeps its existing schema and warning policy.
    This representation still needs a real intake compatibility check before
    rollout; changing a local schema is not evidence of backend acceptance.
    """
    if schema is None:
        return None
    result = deepcopy(schema)
    try:
        global_meta = result["properties"]["metadata"]["properties"]["*"]
        if "runtime-id" not in global_meta.get("required", []):
            raise BatchCompatibilityError("batching requires the canonical global runtime-id requirement")
        item = result["properties"]["events"]["items"]
        item.setdefault("allOf", []).append({"properties": {"content": {"properties": {"meta": {
            "type": "object", "properties": {"runtime-id": {"type": "string", "minLength": 1}}, "required": ["runtime-id"]}}, "required": ["meta"]}}})
    except (AttributeError, KeyError, TypeError) as exc:
        raise BatchCompatibilityError("batching requires the CITESTCYCLE schema with metadata and events definitions") from exc
    return result
