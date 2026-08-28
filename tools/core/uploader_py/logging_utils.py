# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Thread-safe uploader logging with bounded, explicit redaction."""

from __future__ import annotations

import logging
import sys
from typing import Iterable, TextIO
from urllib.parse import urlsplit, urlunsplit


LOGGER_NAME = "dd-uploader"
_SENSITIVE_HEADER_NAMES = frozenset(
    {
        "authorization",
        "cookie",
        "dd-api-key",
        "proxy-authorization",
        "set-cookie",
    }
)


class SecretRedactionFilter(logging.Filter):
    """Replace known non-empty secrets after record interpolation."""

    def __init__(self, secrets: Iterable[str]) -> None:
        super().__init__()
        self._secrets = tuple(sorted({value for value in secrets if value}, key=len, reverse=True))

    def filter(self, record: logging.LogRecord) -> bool:
        message = record.getMessage()
        for secret in self._secrets:
            message = message.replace(secret, "<redacted>")
        record.msg = message
        record.args = ()
        return True


def configure_logging(
    *,
    debug: bool,
    secrets: Iterable[str] = (),
    stream: TextIO | None = None,
) -> logging.Logger:
    """Configure the one process-wide uploader logger."""
    logger = logging.getLogger(LOGGER_NAME)
    logger.handlers.clear()
    logger.propagate = False
    logger.setLevel(logging.DEBUG if debug else logging.INFO)
    handler = logging.StreamHandler(stream if stream is not None else sys.stderr)
    handler.setLevel(logging.DEBUG if debug else logging.INFO)
    handler.setFormatter(logging.Formatter("[dd-uploader] %(levelname)s: %(message)s"))
    handler.addFilter(SecretRedactionFilter(secrets))
    logger.addHandler(handler)
    return logger


def redact_header_value(name: str, value: str) -> str:
    """Hide authentication-bearing header values completely."""
    if name.lower() in _SENSITIVE_HEADER_NAMES:
        return "<redacted>"
    return value


def redact_url(raw_url: str) -> str:
    """Remove URL userinfo, query, and fragment while retaining routing context."""
    try:
        parsed = urlsplit(raw_url)
        if not parsed.scheme or not parsed.netloc:
            return "<redacted-invalid-url>"
        host = parsed.hostname or ""
        if not host:
            return f"{parsed.scheme.lower()}://<redacted-invalid-url>"
        if ":" in host and not host.startswith("["):
            host = f"[{host}]"
        netloc = host
        if parsed.port is not None:
            netloc = f"{netloc}:{parsed.port}"
        return urlunsplit((parsed.scheme.lower(), netloc, parsed.path, "", ""))
    except (TypeError, ValueError):
        return "<redacted-invalid-url>"
