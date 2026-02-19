#!/usr/bin/env python3
"""Validate payload JSON against a practical JSON Schema subset.

Supported keywords include: `$ref`, `allOf`, `anyOf`, `if`/`then`/`else`,
`type`, `const`, `enum`, `minimum`, `maximum`, `required`, `properties`,
`patternProperties`, `additionalProperties`, `items`, and `additionalItems`.

Unsupported keywords are ignored with a warning at validation time:
`oneOf`, `not`, `dependencies`, `dependentRequired`, `format`,
`uniqueItems`, and `contains`.
"""

import argparse
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional, Set

DEFAULT_MAX_ERRORS = 20
_DEBUG_TRUTHY = {"1", "true", "yes", "on"}
_UNSUPPORTED_KEYWORDS = {
    "oneOf",
    "not",
    "dependencies",
    "dependentRequired",
    "format",
    "uniqueItems",
    "contains",
}


def _new_stats() -> Dict[str, int]:
    return {
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


_STATS = _new_stats()


def _reset_stats() -> None:
    global _STATS
    _STATS = _new_stats()


def _debug_enabled() -> bool:
    val = os.getenv("DD_TEST_OPTIMIZATION_SCHEMA_DEBUG")
    if val is None:
        val = os.getenv("DD_TEST_OPTIMIZATION_DEBUG")
    if val is None:
        return False
    return str(val).strip().lower() in _DEBUG_TRUTHY


def _debug(msg: str, debug: bool = False) -> None:
    if debug or _debug_enabled():
        print(f"[schema-validator][dbg] {msg}", file=sys.stderr)


def _stat_inc(stats: Dict[str, int], key: str, n: int = 1) -> None:
    stats[key] = stats.get(key, 0) + n


def _safe_size(path: str) -> Optional[int]:
    try:
        return os.path.getsize(path)
    except OSError:
        return None


def _format_size(size: Optional[int]) -> str:
    if size is None:
        return "unknown"
    return str(size)


def _max_errors_from_env() -> int:
    raw = os.getenv("DD_TEST_OPTIMIZATION_SCHEMA_MAX_ERRORS")
    if raw is None or raw.strip() == "":
        return DEFAULT_MAX_ERRORS
    try:
        value = int(raw.strip())
    except ValueError as exc:
        raise ValueError("DD_TEST_OPTIMIZATION_SCHEMA_MAX_ERRORS must be an integer") from exc
    if value <= 0:
        raise ValueError("DD_TEST_OPTIMIZATION_SCHEMA_MAX_ERRORS must be > 0")
    return value


def _parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog = "validate_payload_schema.py",
        description = "Validate payload JSON against a schema JSON file.",
    )
    parser.add_argument("schema_path")
    parser.add_argument("payload_path")
    parser.add_argument(
        "--max-errors",
        type = int,
        default = None,
        help = "Maximum number of validation errors to record/print",
    )
    return parser.parse_args(argv)


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


def _resolve_ref(root: Dict[str, Any], ref: str, stats: Optional[Dict[str, int]] = None) -> Dict[str, Any]:
    if stats is not None:
        _stat_inc(stats, "refs")
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


def _validate(
    value: Any,
    schema: Dict[str, Any],
    root: Dict[str, Any],
    path: str,
    errors: List[str],
    max_errors: int,
    stats: Optional[Dict[str, int]] = None,
    warned_unsupported: Optional[Set[str]] = None,
) -> None:
    if stats is None:
        stats = _new_stats()
    if warned_unsupported is None:
        warned_unsupported = set()

    _stat_inc(stats, "nodes")
    if len(errors) >= max_errors:
        return
    if not isinstance(schema, dict):
        return

    for keyword in _UNSUPPORTED_KEYWORDS:
        if keyword in schema and keyword not in warned_unsupported:
            print(
                f"warning: unsupported JSON Schema keyword '{keyword}' at {path} is ignored",
                file=sys.stderr,
            )
            warned_unsupported.add(keyword)

    if "$ref" in schema:
        try:
            ref_schema = _resolve_ref(root, schema["$ref"], stats)
        except ValueError as exc:
            errors.append(f"{path}: {exc}")
            return
        _validate(value, ref_schema, root, path, errors, max_errors, stats, warned_unsupported)
        return

    for subschema in schema.get("allOf", []):
        _validate(value, subschema, root, path, errors, max_errors, stats, warned_unsupported)
        if len(errors) >= max_errors:
            return

    if "anyOf" in schema:
        _stat_inc(stats, "anyof")
        for subschema in schema["anyOf"]:
            sub_errors: List[str] = []
            _validate(value, subschema, root, path, sub_errors, max_errors, stats, warned_unsupported)
            if not sub_errors:
                _stat_inc(stats, "anyof_matched")
                break
        else:
            _stat_inc(stats, "anyof_failed")
            errors.append(f"{path}: does not match anyOf")
            return

    if "if" in schema:
        _stat_inc(stats, "if")
        cond_errors: List[str] = []
        _validate(value, schema["if"], root, path, cond_errors, max_errors, stats, warned_unsupported)
        if not cond_errors:
            if "then" in schema:
                _stat_inc(stats, "then")
                _validate(value, schema["then"], root, path, errors, max_errors, stats, warned_unsupported)
        else:
            if "else" in schema:
                _stat_inc(stats, "else")
                _validate(value, schema["else"], root, path, errors, max_errors, stats, warned_unsupported)

    if "type" in schema:
        _stat_inc(stats, "type_checks")
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
            if len(errors) >= max_errors:
                return
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: value {value} > maximum {schema['maximum']}")
            if len(errors) >= max_errors:
                return

    # Scalar values have no object/array branches.
    if not isinstance(value, dict) and not isinstance(value, list):
        return

    if isinstance(value, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                errors.append(f"{path}: missing required property '{key}'")
                if len(errors) >= max_errors:
                    return

        props = schema.get("properties", {})
        pattern_props = schema.get("patternProperties", {})
        patterns = []
        for pattern, subschema in pattern_props.items():
            try:
                patterns.append((re.compile(pattern), subschema))
            except re.error as exc:
                errors.append(f"{path}: invalid patternProperties regex {pattern!r}: {exc}")
                return

        for key, val in value.items():
            matched = False
            if key in props:
                matched = True
                _validate(val, props[key], root, _path_key(path, key), errors, max_errors, stats, warned_unsupported)
            for regex, subschema in patterns:
                if regex.search(key):
                    matched = True
                    _validate(val, subschema, root, _path_key(path, key), errors, max_errors, stats, warned_unsupported)
            if not matched:
                addl = schema.get("additionalProperties", True)
                if addl is False:
                    errors.append(f"{path}: additional property '{key}' not allowed")
                elif isinstance(addl, dict):
                    _validate(val, addl, root, _path_key(path, key), errors, max_errors, stats, warned_unsupported)

    if isinstance(value, list):
        items = schema.get("items")
        if isinstance(items, dict):
            for idx, item in enumerate(value):
                _validate(item, items, root, f"{path}[{idx}]", errors, max_errors, stats, warned_unsupported)
        elif isinstance(items, list):
            for idx, item in enumerate(value):
                if idx < len(items):
                    _validate(item, items[idx], root, f"{path}[{idx}]", errors, max_errors, stats, warned_unsupported)
                else:
                    additional_items = schema.get("additionalItems", True)
                    if additional_items is False:
                        errors.append(f"{path}[{idx}]: additional item not allowed")
                    elif isinstance(additional_items, dict):
                        _validate(item, additional_items, root, f"{path}[{idx}]", errors, max_errors, stats, warned_unsupported)


def main() -> int:
    global _STATS
    debug = _debug_enabled()
    _reset_stats()
    try:
        args = _parse_args(sys.argv[1:])
    except SystemExit as exc:
        return int(exc.code) if isinstance(exc.code, int) else 2

    schema_path = args.schema_path
    payload_path = args.payload_path
    try:
        env_max_errors = _max_errors_from_env()
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    max_errors = args.max_errors if args.max_errors is not None else env_max_errors
    if max_errors <= 0:
        print("error: --max-errors must be > 0", file=sys.stderr)
        return 2

    _debug(f"schema path: {schema_path}", debug)
    _debug(f"payload path: {payload_path}", debug)
    _debug(f"max errors: {max_errors}", debug)

    try:
        with open(schema_path, "r", encoding="utf-8-sig") as f:
            schema = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: failed to read schema: {exc}", file=sys.stderr)
        return 2
    _debug(f"schema bytes: {_format_size(_safe_size(schema_path))}", debug)
    if isinstance(schema, dict):
        if "$id" in schema:
            _debug(f"schema $id: {schema.get('$id')}", debug)
        if "$schema" in schema:
            _debug(f"schema $schema: {schema.get('$schema')}", debug)
        if "type" in schema:
            _debug(f"schema root type: {schema.get('type')}", debug)
        if "required" in schema and isinstance(schema.get("required"), list):
            _debug(f"schema required count: {len(schema.get('required', []))}", debug)

    try:
        with open(payload_path, "r", encoding="utf-8-sig") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: failed to read payload JSON: {exc}", file=sys.stderr)
        return 2
    _debug(f"payload bytes: {_format_size(_safe_size(payload_path))}", debug)
    _debug(f"payload type: {type(payload).__name__}", debug)
    if isinstance(payload, dict):
        _debug(f"payload keys: {len(payload)}", debug)
        sample = _sample_keys(payload)
        if sample:
            _debug(f"payload key sample: {sample}", debug)

    errors: List[str] = []
    stats = _new_stats()
    warned_unsupported: Set[str] = set()
    _debug("validation start", debug)
    _validate(payload, schema, schema, "$", errors, max_errors, stats, warned_unsupported)
    _STATS = dict(stats)

    if errors:
        print("schema validation failed:", file=sys.stderr)
        for err in errors[:max_errors]:
            print(f"- {err}", file=sys.stderr)
        if len(errors) > max_errors:
            print(f"- ... and {len(errors) - max_errors} more", file=sys.stderr)
        _debug(f"validation result: failed ({len(errors)} error(s))", debug)
        if debug:
            _debug(
                "stats: nodes={nodes} refs={refs} anyof={anyof} anyof_matched={anyof_matched} "
                "anyof_failed={anyof_failed} if={if} then={then} else={else} type_checks={type_checks}".format(
                    **_STATS
                ),
                debug,
            )
        return 1

    _debug("validation result: ok", debug)
    if debug:
        _debug(
            "stats: nodes={nodes} refs={refs} anyof={anyof} anyof_matched={anyof_matched} "
            "anyof_failed={anyof_failed} if={if} then={then} else={else} type_checks={type_checks}".format(
                **_STATS
            ),
            debug,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
