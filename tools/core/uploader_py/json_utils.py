# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Encode and decode strict, interoperable JSON for uploader contracts.

Central validation rejects non-standard values before they reach split or HTTP code.
"""

from __future__ import annotations

import json
from typing import Any


def _reject_non_finite_constant(value: str) -> None:
    raise json.JSONDecodeError(
        f"non-finite numeric constant {value!r} is not valid JSON",
        value,
        0,
    )


def strict_json_loads(document: str | bytes | bytearray) -> Any:
    """Parse RFC-compatible JSON and reject NaN/Infinity extensions."""
    return json.loads(document, parse_constant=_reject_non_finite_constant)


def strict_json_dumps(value: Any, **kwargs: Any) -> str:
    """Serialize JSON while refusing non-finite floating-point values."""
    return json.dumps(value, allow_nan=False, **kwargs)
