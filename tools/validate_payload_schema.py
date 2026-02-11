#!/usr/bin/env python3
import json
import os
import re
import sys
from typing import Any, Dict, List

MAX_ERRORS = 20
_DEBUG_TRUTHY = {"1", "true", "yes", "on"}
_STATS = {
    "nodes": 0,
    "refs": 0,
    "anyof": 0,
    "anyof_matched": 0,
    "anyof_failed": 0,
    "if": 0,
    "then": 0,
    "else": 0,
    "type_checks": 0,
}


def _debug_enabled() -> bool:
    val = os.getenv("DD_TOPT_SCHEMA_DEBUG")
    if val is None:
        val = os.getenv("DD_TOPT_DEBUG")
    if val is None:
        return False
    return str(val).strip().lower() in _DEBUG_TRUTHY


_DEBUG = _debug_enabled()


def _debug(msg: str) -> None:
    if _DEBUG:
        print(f"[schema-validator][dbg] {msg}", file=sys.stderr)


def _stat_inc(key: str, n: int = 1) -> None:
    if _DEBUG:
        _STATS[key] = _STATS.get(key, 0) + n


def _safe_size(path: str) -> str:
    try:
        return str(os.path.getsize(path))
    except Exception as exc:
        return f"unknown ({exc})"


def _sample_keys(value: Any, limit: int = 12) -> str:
    if not isinstance(value, dict):
        return ""
    keys = list(value.keys())
    if len(keys) <= limit:
        return ", ".join(map(str, keys))
    return ", ".join(map(str, keys[:limit])) + ", ..."


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _is_type(value: Any, type_name: str) -> bool:
    if type_name == "object":
        return isinstance(value, dict)
    if type_name == "array":
        return isinstance(value, list)
    if type_name == "string":
        return isinstance(value, str)
    if type_name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if type_name == "number":
        return _is_number(value)
    if type_name == "boolean":
        return isinstance(value, bool)
    if type_name == "null":
        return value is None
    return False


def _resolve_ref(root: Dict[str, Any], ref: str) -> Dict[str, Any]:
    _stat_inc("refs")
    if not ref.startswith("#/"):
        raise ValueError(f"unsupported ref: {ref}")
    parts = ref[2:].split("/")
    cur: Any = root
    for part in parts:
        part = part.replace("~1", "/").replace("~0", "~")
        if isinstance(cur, dict):
            if part not in cur:
                raise ValueError(f"ref segment not found: {part!r} in {ref}")
            cur = cur[part]
            continue
        if isinstance(cur, list):
            if not part.isdigit():
                raise ValueError(f"ref segment is not a list index: {part!r} in {ref}")
            idx = int(part)
            if idx < 0 or idx >= len(cur):
                raise ValueError(f"ref index out of bounds: {part!r} in {ref}")
            cur = cur[idx]
            continue
        raise ValueError(f"ref traversal hit non-container at segment {part!r} in {ref}")
    if not isinstance(cur, dict):
        raise ValueError(f"ref did not resolve to an object: {ref}")
    return cur


def _path_key(path: str, key: str) -> str:
    safe = key.replace("'", "\\'")
    return f"{path}['{safe}']"


def _validate(value: Any, schema: Dict[str, Any], root: Dict[str, Any], path: str, errors: List[str]) -> None:
    _stat_inc("nodes")
    if len(errors) >= MAX_ERRORS:
        return
    if not isinstance(schema, dict):
        return

    if "$ref" in schema:
        try:
            ref_schema = _resolve_ref(root, schema["$ref"])
        except ValueError as exc:
            errors.append(f"{path}: {exc}")
            return
        _validate(value, ref_schema, root, path, errors)
        return

    for subschema in schema.get("allOf", []):
        _validate(value, subschema, root, path, errors)
        if len(errors) >= MAX_ERRORS:
            return

    if "anyOf" in schema:
        _stat_inc("anyof")
        for subschema in schema["anyOf"]:
            sub_errors: List[str] = []
            _validate(value, subschema, root, path, sub_errors)
            if not sub_errors:
                _stat_inc("anyof_matched")
                break
        else:
            _stat_inc("anyof_failed")
            errors.append(f"{path}: does not match anyOf")
            return

    if "if" in schema:
        _stat_inc("if")
        cond_errors: List[str] = []
        _validate(value, schema["if"], root, path, cond_errors)
        if not cond_errors:
            if "then" in schema:
                _stat_inc("then")
                _validate(value, schema["then"], root, path, errors)
        else:
            if "else" in schema:
                _stat_inc("else")
                _validate(value, schema["else"], root, path, errors)

    if "type" in schema:
        _stat_inc("type_checks")
        type_spec = schema["type"]
        if isinstance(type_spec, list):
            ok = any(_is_type(value, t) for t in type_spec)
        else:
            ok = _is_type(value, type_spec)
        if not ok:
            errors.append(f"{path}: expected type {type_spec}")
            return

    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: value does not match const")
        return

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: value not in enum")
        return

    if _is_number(value):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: value {value} < minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: value {value} > maximum {schema['maximum']}")

    if isinstance(value, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                errors.append(f"{path}: missing required property '{key}'")
                if len(errors) >= MAX_ERRORS:
                    return

        props = schema.get("properties", {})
        pattern_props = schema.get("patternProperties", {})
        patterns = [(re.compile(p), s) for p, s in pattern_props.items()]

        for key, val in value.items():
            matched = False
            if key in props:
                matched = True
                _validate(val, props[key], root, _path_key(path, key), errors)
            for regex, subschema in patterns:
                if regex.search(key):
                    matched = True
                    _validate(val, subschema, root, _path_key(path, key), errors)
            if not matched:
                addl = schema.get("additionalProperties", True)
                if addl is False:
                    errors.append(f"{path}: additional property '{key}' not allowed")
                elif isinstance(addl, dict):
                    _validate(val, addl, root, _path_key(path, key), errors)

    if isinstance(value, list):
        items = schema.get("items")
        if isinstance(items, dict):
            for idx, item in enumerate(value):
                _validate(item, items, root, f"{path}[{idx}]", errors)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: validate_payload_schema.py <schema.json> <payload.json>", file=sys.stderr)
        return 2

    schema_path = sys.argv[1]
    payload_path = sys.argv[2]
    _debug(f"schema path: {schema_path}")
    _debug(f"payload path: {payload_path}")
    _debug(f"max errors: {MAX_ERRORS}")

    try:
        with open(schema_path, "r", encoding="utf-8") as f:
            schema = json.load(f)
    except Exception as exc:
        print(f"error: failed to read schema: {exc}", file=sys.stderr)
        return 2
    _debug(f"schema bytes: {_safe_size(schema_path)}")
    if isinstance(schema, dict):
        if "$id" in schema:
            _debug(f"schema $id: {schema.get('$id')}")
        if "$schema" in schema:
            _debug(f"schema $schema: {schema.get('$schema')}")
        if "type" in schema:
            _debug(f"schema root type: {schema.get('type')}")
        if "required" in schema and isinstance(schema.get("required"), list):
            _debug(f"schema required count: {len(schema.get('required', []))}")

    try:
        with open(payload_path, "r", encoding="utf-8") as f:
            payload = json.load(f)
    except Exception as exc:
        print(f"error: failed to read payload JSON: {exc}", file=sys.stderr)
        return 2
    _debug(f"payload bytes: {_safe_size(payload_path)}")
    _debug(f"payload type: {type(payload).__name__}")
    if isinstance(payload, dict):
        _debug(f"payload keys: {len(payload)}")
        sample = _sample_keys(payload)
        if sample:
            _debug(f"payload key sample: {sample}")

    errors: List[str] = []
    _debug("validation start")
    _validate(payload, schema, schema, "$", errors)

    if errors:
        print("schema validation failed:", file=sys.stderr)
        for err in errors[:MAX_ERRORS]:
            print(f"- {err}", file=sys.stderr)
        if len(errors) > MAX_ERRORS:
            print(f"- ... and {len(errors) - MAX_ERRORS} more", file=sys.stderr)
        _debug(f"validation result: failed ({len(errors)} error(s))")
        if _DEBUG:
            _debug(
                "stats: nodes={nodes} refs={refs} anyof={anyof} anyof_matched={anyof_matched} "
                "anyof_failed={anyof_failed} if={if} then={then} else={else} type_checks={type_checks}".format(
                    **_STATS
                )
            )
        return 1

    _debug("validation result: ok")
    if _DEBUG:
        _debug(
            "stats: nodes={nodes} refs={refs} anyof={anyof} anyof_matched={anyof_matched} "
            "anyof_failed={anyof_failed} if={if} then={then} else={else} type_checks={type_checks}".format(
                **_STATS
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
