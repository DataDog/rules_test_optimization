# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Warning-only fetch/upload credential parity without exposing credentials."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping


FINGERPRINT_ALPHABET = (
    "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "-_:/.+@=#%~!$^*()[]{}<>?,;|\\\"'` "
)


@dataclass(frozen=True)
class ApiKeyFingerprintCheck:
    """Safe pre-worker diagnostic derived from the primary context."""

    status: str
    warning_code: str | None = None


def api_key_fingerprint(api_key: str) -> str:
    """Match the non-cryptographic sync-side FNV-1a-style fingerprint."""
    if not api_key:
        return ""
    value = 2_166_136_261
    alphabet_length = len(FINGERPRINT_ALPHABET)
    for index, character in enumerate(api_key):
        alphabet_index = FINGERPRINT_ALPHABET.find(character)
        if alphabet_index < 0:
            alphabet_index = alphabet_length + (index % 7)
        value ^= alphabet_index
        value = (value * 16_777_619) & 0xFFFFFFFF
    return f"{value:08x}"


def check_api_key_fingerprint(
    primary_context: Mapping[str, Any] | None,
    *,
    api_key: str,
    agentless: bool,
) -> ApiKeyFingerprintCheck:
    """Compare once before workers; mismatches remain warning-only."""
    expected = (
        primary_context.get("topt.api_key_fingerprint")
        if primary_context is not None
        else None
    )
    if not isinstance(expected, str) or not expected:
        return ApiKeyFingerprintCheck("absent")
    if not agentless:
        return ApiKeyFingerprintCheck(
            "evp_skipped",
            "api_key_fingerprint_evp_skipped",
        )
    if not api_key:
        return ApiKeyFingerprintCheck("api_key_unset")
    if api_key_fingerprint(api_key) != expected:
        return ApiKeyFingerprintCheck(
            "mismatch",
            "api_key_fingerprint_mismatch",
        )
    return ApiKeyFingerprintCheck("match")
