# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Prepare compatible test envelopes without sharing process identity.

Only an owned, enriched source is mutated. Source files remain unchanged until
their complete request is acknowledged. Runtime IDs belong to individual events;
all other envelope fields remain part of the compatibility key.
"""

from __future__ import annotations

from copy import deepcopy
from typing import Any

from .json_utils import strict_json_dumps


class BatchCompatibilityError(ValueError):
    """A source must retain the ordinary per-file upload path."""


def localize_runtime_ids(payload: dict[str, Any], *, max_additional_bytes: int | None = None) -> bytes:
    """Move envelope runtime defaults to events and return the exact envelope key.

    Existing event values win, then event-type defaults, then global defaults.
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
        type_meta = metadata.get(event["type"], {})
        # An explicitly malformed value is not a missing default.
        runtime_id = event_meta.get("runtime-id", type_meta.get("runtime-id", global_meta.get("runtime-id")))
        if not isinstance(runtime_id, str) or not runtime_id:
            raise BatchCompatibilityError("each event must have a nonempty runtime-id")
        if max_additional_bytes is not None and "runtime-id" not in event_meta:
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
    for values in metadata.values():
        values.pop("runtime-id", None)
    envelope = {key: value for key, value in payload.items() if key != "events"}
    return strict_json_dumps(envelope, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def schema_for_event_runtime_ids(schema: dict[str, Any] | None) -> dict[str, Any] | None:
    """Adapt the outbound-only schema to require a runtime ID on every event.

    Ordinary source validation keeps its existing schema and warning policy.
    This representation still needs a real intake compatibility check before
    rollout; changing a local schema is not evidence of backend acceptance.
    """
    if schema is None:
        return None
    result = deepcopy(schema)
    try:
        global_meta = result["properties"]["metadata"]["properties"]["*"]
        global_meta["required"] = [field for field in global_meta.get("required", []) if field != "runtime-id"]
        item = result["properties"]["events"]["items"]
        item.setdefault("allOf", []).append({"properties": {"content": {"properties": {"meta": {
            "type": "object", "properties": {"runtime-id": {"type": "string", "minLength": 1}}, "required": ["runtime-id"]}}, "required": ["meta"]}}})
    except (AttributeError, KeyError, TypeError) as exc:
        raise BatchCompatibilityError("batching requires the CITESTCYCLE schema with metadata and events definitions") from exc
    return result
