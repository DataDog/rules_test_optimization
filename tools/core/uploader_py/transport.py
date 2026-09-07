# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Send exact reusable request bodies through one worker-local HTTP client.

Per-worker transports provide concurrency without shared connection or retry state.
"""

from __future__ import annotations

import base64
from contextlib import closing
from dataclasses import dataclass
from email.utils import parsedate_to_datetime
from functools import partial
import gzip
import http.client
import io
import logging
import math
from pathlib import Path
import secrets
import shutil
import ssl
import time
from typing import BinaryIO, Callable, Iterable, Mapping
from urllib.error import HTTPError, URLError
from urllib.parse import SplitResult, unquote
from urllib.request import (
    HTTPHandler,
    HTTPRedirectHandler,
    HTTPSHandler,
    ProxyHandler,
    Request,
    build_opener,
    proxy_bypass_environment,
)

from .endpoints import parse_http_url
from .logging_utils import redact_url


DEFAULT_CONNECT_TIMEOUT_SECONDS = 10.0
DEFAULT_REQUEST_TIMEOUT_SECONDS = 60.0
DEFAULT_MAX_ATTEMPTS = 4
DEFAULT_RETRY_DELAY_SECONDS = 2.0
DEFAULT_MAX_RETRY_DELAY_SECONDS = 60.0
DEFAULT_RESPONSE_LIMIT_BYTES = 2_000
RETRYABLE_HTTP_STATUSES = frozenset({408, 429})


class HttpTransportError(ValueError):
    """The caller supplied an invalid URL, header, or request body."""


@dataclass(frozen=True)
class HttpResult:
    """Terminal outcome of one logical request, including all retry attempts."""

    status_code: int | None
    attempts: int
    body_excerpt: bytes = b""
    body_truncated: bool = False
    transport_error: str | None = None
    retry_delays: tuple[float, ...] = ()

    @property
    def succeeded(self) -> bool:
        return (
            self.transport_error is None
            and self.status_code is not None
            and 200 <= self.status_code < 300
        )

    @property
    def retries(self) -> int:
        return max(0, self.attempts - 1)


@dataclass(frozen=True)
class PreparedMultipartBody:
    """Exact task-local multipart body reusable across request attempts."""

    path: Path
    content_type: str
    content_length: int


@dataclass(frozen=True)
class PreparedHttpRequest:
    """A fully validated request that has not opened a network connection."""

    url: str
    headers: Mapping[str, str]
    body_factory: Callable[[], BinaryIO]


class _RequestTimeoutHTTPConnection(http.client.HTTPConnection):
    """Use a short connect timeout, then a separate socket I/O timeout."""

    def __init__(
        self,
        host: str,
        *,
        timeout: float,
        connect_timeout: float,
        **kwargs: object,
    ) -> None:
        self._request_timeout = timeout
        super().__init__(host, timeout=connect_timeout, **kwargs)

    def connect(self) -> None:
        super().connect()
        if self.sock is not None:
            self.sock.settimeout(self._request_timeout)


class _RequestTimeoutHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS equivalent of :class:`_RequestTimeoutHTTPConnection`."""

    def __init__(
        self,
        host: str,
        *,
        timeout: float,
        connect_timeout: float,
        **kwargs: object,
    ) -> None:
        self._request_timeout = timeout
        super().__init__(host, timeout=connect_timeout, **kwargs)

    def connect(self) -> None:
        super().connect()
        if self.sock is not None:
            self.sock.settimeout(self._request_timeout)


class _RequestTimeoutHTTPHandler(HTTPHandler):
    def __init__(self, connect_timeout: float) -> None:
        super().__init__()
        self._connection = partial(
            _RequestTimeoutHTTPConnection,
            connect_timeout=connect_timeout,
        )

    def http_open(self, request: Request):
        return self.do_open(self._connection, request)


class _RequestTimeoutHTTPSHandler(HTTPSHandler):
    def __init__(self, connect_timeout: float, context: ssl.SSLContext) -> None:
        super().__init__(context=context)
        self._connection = partial(
            _RequestTimeoutHTTPSConnection,
            connect_timeout=connect_timeout,
        )

    def https_open(self, request: Request):
        return self.do_open(self._connection, request, context=self._context)


class _NoRedirectHandler(HTTPRedirectHandler):
    """Keep POST semantics and credentials on the configured intake host."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class _SnapshotProxyHandler(ProxyHandler):
    """Proxy handler whose bypass rules do not reread process environment."""

    def __init__(self, proxies: Mapping[str, str], no_proxy: str) -> None:
        self._no_proxy = no_proxy
        super().__init__(dict(proxies))

    def proxy_open(self, request: Request, proxy: str, proxy_type: str):
        if request.host and self._bypass(request.host):
            return None

        original_type = request.type
        raw_proxy = proxy if "://" in proxy else f"{original_type}://{proxy}"
        try:
            parsed = _parsed_proxy_url(raw_proxy, original_type)
            proxy_port = parsed.port
        except (TypeError, ValueError):
            raise URLError("invalid proxy configuration")
        resolved_type = parsed.scheme or original_type

        host_port = parsed.hostname
        if ":" in host_port and not host_port.startswith("["):
            host_port = f"[{host_port}]"
        if proxy_port is not None:
            host_port = f"{host_port}:{proxy_port}"
        if parsed.username is not None:
            credentials = f"{unquote(parsed.username)}:{unquote(parsed.password or '')}"
            encoded = base64.b64encode(credentials.encode("utf-8")).decode("ascii")
            request.add_header("Proxy-authorization", f"Basic {encoded}")

        request.set_proxy(host_port, resolved_type)
        if original_type == resolved_type or original_type == "https":
            return None
        return self.parent.open(request, timeout=request.timeout)

    def _bypass(self, host: str) -> bool:
        if not self._no_proxy:
            return False
        return proxy_bypass_environment(host, {"no": self._no_proxy})


def _proxy_configuration(
    environment: Iterable[tuple[str, str]],
) -> tuple[dict[str, str], str]:
    effective_values: dict[str, str] = {}
    # Uppercase variants are supported, while lowercase variants take
    # precedence when both are explicitly present.
    items = tuple(environment)
    for name, value in items:
        if name in {"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"} and value:
            effective_values[name.lower()] = value
    for name, value in items:
        if name in {"http_proxy", "https_proxy", "no_proxy"} and value:
            effective_values[name] = value
    proxies = {
        scheme: effective_values[f"{scheme}_proxy"]
        for scheme in ("http", "https")
        if effective_values.get(f"{scheme}_proxy")
    }
    for scheme, proxy in proxies.items():
        try:
            _parsed_proxy_url(proxy, scheme)
        except (TypeError, ValueError) as exc:
            raise HttpTransportError(
                f"invalid {scheme.upper()} proxy configuration"
            ) from exc
    return proxies, effective_values.get("no_proxy", "")


def _parsed_proxy_url(raw_proxy: str, default_scheme: str) -> SplitResult:
    """Parse the proxy forms accepted by standard proxy environment variables."""
    candidate = raw_proxy if "://" in raw_proxy else f"{default_scheme}://{raw_proxy}"
    parsed = parse_http_url(candidate)
    if parsed.scheme.lower() not in {"http", "https"}:
        raise ValueError("proxy scheme must be HTTP(S)")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise ValueError("proxy URL must not contain a request path")
    for credential in (parsed.username, parsed.password):
        if credential is not None:
            unquote(credential, encoding="utf-8", errors="strict")
    return parsed


def validate_proxy_environment(environment: Iterable[tuple[str, str]]) -> None:
    """Reject a known-invalid effective proxy before workers start."""
    _proxy_configuration(environment)


def _retryable_status(status_code: int) -> bool:
    return status_code in RETRYABLE_HTTP_STATUSES or 500 <= status_code <= 599


def _retry_after_seconds(value: str | None, now: float) -> float | None:
    if not value:
        return None
    normalized = value.strip()
    if normalized.isdecimal():
        try:
            delay = float(normalized)
        except (OverflowError, ValueError):
            return None
        return _bounded_retry_after_seconds(delay)
    try:
        parsed = parsedate_to_datetime(normalized)
    except (TypeError, ValueError, OverflowError):
        return None
    if parsed.tzinfo is None:
        return None
    try:
        delay = parsed.timestamp() - now
    except (OSError, OverflowError, ValueError):
        return None
    return _bounded_retry_after_seconds(delay)


def _bounded_retry_after_seconds(delay: float) -> float | None:
    """Keep server-controlled retry waits finite and operationally bounded."""
    if math.isnan(delay):
        return None
    if not math.isfinite(delay):
        return DEFAULT_MAX_RETRY_DELAY_SECONDS if delay > 0 else 0.0
    return min(max(0.0, delay), DEFAULT_MAX_RETRY_DELAY_SECONDS)


def _bounded_response(stream, limit: int) -> tuple[bytes, bool]:
    body = stream.read(limit + 1)
    return body[:limit], len(body) > limit


def _validate_url(url: str) -> None:
    try:
        parsed = parse_http_url(url)
    except (TypeError, ValueError) as exc:
        raise HttpTransportError(
            "upload URL must be an absolute HTTP(S) URL"
        ) from exc
    if parsed.username is not None or parsed.password is not None:
        raise HttpTransportError("upload URL must not contain credentials/userinfo")


def _validated_headers(headers: Mapping[str, str]) -> dict[str, str]:
    validated: dict[str, str] = {}
    for name, value in headers.items():
        if not name or any(character in name for character in "\r\n:"):
            raise HttpTransportError(f"invalid HTTP header name: {name!r}")
        text_value = str(value)
        if "\r" in text_value or "\n" in text_value:
            raise HttpTransportError(f"invalid HTTP header value for {name!r}")
        validated[name] = text_value
    return validated


def _controlled_headers(
    headers: Mapping[str, str],
    *,
    content_type: str,
    content_length: int,
    content_encoding: str | None = None,
) -> dict[str, str]:
    controlled = _validated_headers(headers)
    for name in tuple(controlled):
        if name.lower() in {"content-type", "content-length", "content-encoding"}:
            del controlled[name]
    controlled["Content-Type"] = content_type
    controlled["Content-Length"] = str(content_length)
    if content_encoding:
        controlled["Content-Encoding"] = content_encoding
    return controlled


def prepare_json_request(
    url: str,
    headers: Mapping[str, str],
    body: bytes | Path,
    *,
    gzip_body: bool = False,
    content_encoding: str | None = None,
) -> PreparedHttpRequest:
    """Validate and materialize everything needed for one JSON request."""
    _validate_url(url)
    if gzip_body and content_encoding:
        raise HttpTransportError(
            "gzip_body and an existing content encoding cannot be combined"
        )
    if isinstance(body, Path):
        try:
            if gzip_body:
                compressed = gzip.compress(body.read_bytes(), mtime=0)
                body_factory: Callable[[], BinaryIO] = (
                    lambda: io.BytesIO(compressed)
                )
                body_length = len(compressed)
            else:
                body_length = body.stat().st_size
                with body.open("rb"):
                    pass
                body_factory = lambda: body.open("rb")
        except OSError as exc:
            raise HttpTransportError(
                f"failed to prepare JSON request body: {type(exc).__name__}"
            ) from exc
    else:
        body_bytes = gzip.compress(body, mtime=0) if gzip_body else body
        body_length = len(body_bytes)
        body_factory = lambda: io.BytesIO(body_bytes)

    request_headers = _controlled_headers(
        headers,
        content_type="application/json",
        content_length=body_length,
        content_encoding="gzip" if gzip_body else content_encoding,
    )
    return PreparedHttpRequest(url, request_headers, body_factory)


def prepare_spooled_multipart_request(
    url: str,
    headers: Mapping[str, str],
    prepared: PreparedMultipartBody,
) -> PreparedHttpRequest:
    """Validate a task-local multipart body without opening a connection."""
    _validate_url(url)
    try:
        actual_size = prepared.path.stat().st_size
        with prepared.path.open("rb"):
            pass
    except OSError as exc:
        raise HttpTransportError(
            f"failed to read prepared multipart body: {type(exc).__name__}"
        ) from exc
    if actual_size != prepared.content_length:
        raise HttpTransportError("prepared multipart body size changed")
    request_headers = _controlled_headers(
        headers,
        content_type=prepared.content_type,
        content_length=prepared.content_length,
    )
    return PreparedHttpRequest(
        url,
        request_headers,
        lambda: prepared.path.open("rb"),
    )


def _multipart_header(
    boundary: str,
    *,
    field_name: str,
    filename: str,
    content_type: str,
) -> bytes:
    for label, value in (
        ("field name", field_name),
        ("filename", filename),
        ("content type", content_type),
    ):
        if not value or any(character in value for character in '\r\n"'):
            raise HttpTransportError(f"invalid multipart {label}: {value!r}")
    return (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{field_name}"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n"
    ).encode("ascii")


def prepare_coverage_multipart(
    output_path: Path,
    *,
    event_body: bytes,
    coverage_path: Path,
    coverage_filename: str,
    coverage_content_type: str,
) -> PreparedMultipartBody:
    """Spool the exact coverage request body into worker-owned temporary space."""
    boundary = f"dd-topt-{secrets.token_hex(16)}"
    event_header = _multipart_header(
        boundary,
        field_name="event",
        filename="fileevent.json",
        content_type="application/json",
    )
    coverage_header = _multipart_header(
        boundary,
        field_name="coveragex",
        filename=coverage_filename,
        content_type=coverage_content_type,
    )
    closing_boundary = f"\r\n--{boundary}--\r\n".encode("ascii")
    try:
        with output_path.open("wb") as handle:
            handle.write(event_header)
            handle.write(event_body)
            handle.write(b"\r\n")
            handle.write(coverage_header)
            with coverage_path.open("rb") as coverage:
                shutil.copyfileobj(coverage, handle, length=64 * 1024)
            handle.write(closing_boundary)
            content_length = handle.tell()
    except OSError as exc:
        raise HttpTransportError(
            f"failed to prepare coverage request body: {type(exc).__name__}"
        ) from exc
    return PreparedMultipartBody(
        path=output_path,
        content_type=f"multipart/form-data; boundary={boundary}",
        content_length=content_length,
    )


class HttpTransport:
    """One worker-local HTTP client with one explicit retry policy."""

    def __init__(
        self,
        *,
        proxy_environment: Iterable[tuple[str, str]] = (),
        connect_timeout: float = DEFAULT_CONNECT_TIMEOUT_SECONDS,
        request_timeout: float = DEFAULT_REQUEST_TIMEOUT_SECONDS,
        max_attempts: int = DEFAULT_MAX_ATTEMPTS,
        retry_delay: float = DEFAULT_RETRY_DELAY_SECONDS,
        response_limit: int = DEFAULT_RESPONSE_LIMIT_BYTES,
        sleeper: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.time,
        ssl_context: ssl.SSLContext | None = None,
        logger: logging.Logger | None = None,
    ) -> None:
        if connect_timeout <= 0 or request_timeout <= 0:
            raise ValueError("HTTP timeouts must be positive")
        if max_attempts <= 0:
            raise ValueError("HTTP max_attempts must be positive")
        if retry_delay < 0 or response_limit <= 0:
            raise ValueError("HTTP retry delay and response limit are invalid")

        self.connect_timeout = connect_timeout
        self.request_timeout = request_timeout
        self.max_attempts = max_attempts
        self.retry_delay = retry_delay
        self.response_limit = response_limit
        self._sleeper = sleeper
        self._clock = clock
        self._ssl_context = ssl_context or ssl.create_default_context()
        self._logger = logger
        self._log_context = ""
        proxies, no_proxy = _proxy_configuration(proxy_environment)
        handlers = (
            _SnapshotProxyHandler(proxies, no_proxy),
            _RequestTimeoutHTTPHandler(connect_timeout),
            _RequestTimeoutHTTPSHandler(connect_timeout, self._ssl_context),
            _NoRedirectHandler(),
        )
        self._opener = build_opener(*handlers)

    def set_log_context(
        self,
        task_id: str,
        payload_type: str,
        source_path: str,
    ) -> None:
        """Set diagnostics for this worker-local transport's current file."""
        self._log_context = f"task={task_id} type={payload_type} file={source_path}"

    def clear_log_context(self) -> None:
        """Clear task diagnostics before the worker dequeues another file."""
        self._log_context = ""

    def _debug(self, message: str, *args: object) -> None:
        if self._logger is None:
            return
        if self._log_context:
            self._logger.debug("%s " + message, self._log_context, *args)
        else:
            self._logger.debug(message, *args)

    @property
    def verifies_tls(self) -> bool:
        return (
            self._ssl_context.verify_mode == ssl.CERT_REQUIRED
            and self._ssl_context.check_hostname
        )

    def post_json(
        self,
        url: str,
        headers: Mapping[str, str],
        body: bytes | Path,
        *,
        gzip_body: bool = False,
        content_encoding: str | None = None,
    ) -> HttpResult:
        """POST an exact JSON body, optionally compressed with stdlib gzip."""
        prepared_request = prepare_json_request(
            url,
            headers,
            body,
            gzip_body=gzip_body,
            content_encoding=content_encoding,
        )
        return self._post(prepared_request)

    def post_prepared_multipart(
        self,
        url: str,
        headers: Mapping[str, str],
        prepared: PreparedMultipartBody,
    ) -> HttpResult:
        """POST a task-local multipart body, reopening it for every retry."""
        prepared_request = prepare_spooled_multipart_request(
            url,
            headers,
            prepared,
        )
        return self._post(prepared_request)

    def _post(
        self,
        prepared_request: PreparedHttpRequest,
    ) -> HttpResult:
        retry_delays: list[float] = []
        status_code: int | None = None
        response_excerpt = b""
        excerpt_truncated = False
        transport_error: str | None = None

        for attempt in range(1, self.max_attempts + 1):
            retry_after: str | None = None
            retryable = False
            body_stream = prepared_request.body_factory()
            self._debug(
                "HTTP POST attempt=%d/%d url=%s",
                attempt,
                self.max_attempts,
                redact_url(prepared_request.url),
            )
            try:
                http_request = Request(
                    prepared_request.url,
                    data=body_stream,
                    headers=dict(prepared_request.headers),
                    method="POST",
                )
                try:
                    response = self._opener.open(
                        http_request,
                        timeout=self.request_timeout,
                    )
                except HTTPError as exc:
                    response = exc
                with closing(response):
                    status_code = int(response.status)
                    response_excerpt, excerpt_truncated = _bounded_response(
                        response,
                        self.response_limit,
                    )
                    transport_error = None
                    if 200 <= status_code < 300:
                        self._debug(
                            "HTTP POST succeeded attempt=%d status=%d",
                            attempt,
                            status_code,
                        )
                        return HttpResult(
                            status_code=status_code,
                            attempts=attempt,
                            body_excerpt=response_excerpt,
                            body_truncated=excerpt_truncated,
                            retry_delays=tuple(retry_delays),
                        )
                    self._debug(
                        "HTTP POST failed attempt=%d status=%d "
                        "body_excerpt=%r body_truncated=%s",
                        attempt,
                        status_code,
                        response_excerpt.decode("utf-8", errors="backslashreplace"),
                        excerpt_truncated,
                    )
                    retryable = _retryable_status(status_code)
                    retry_after = response.headers.get("Retry-After")
            except (
                URLError,
                TimeoutError,
                ConnectionError,
                http.client.HTTPException,
                ssl.SSLError,
            ) as exc:
                status_code = None
                response_excerpt = b""
                excerpt_truncated = False
                transport_cause = exc.reason if isinstance(exc, URLError) else exc
                transport_error = type(transport_cause).__name__
                retryable = not isinstance(
                    transport_cause, ssl.SSLCertVerificationError
                )
            finally:
                body_stream.close()

            if not retryable or attempt >= self.max_attempts:
                self._debug(
                    "HTTP POST terminal attempt=%d status=%s transport_error=%s",
                    attempt,
                    status_code,
                    transport_error or "none",
                )
                return HttpResult(
                    status_code=status_code,
                    attempts=attempt,
                    body_excerpt=response_excerpt,
                    body_truncated=excerpt_truncated,
                    transport_error=transport_error,
                    retry_delays=tuple(retry_delays),
                )

            delay = _retry_after_seconds(retry_after, self._clock())
            if delay is None:
                delay = self.retry_delay
            retry_delays.append(delay)
            self._debug(
                "HTTP POST retry scheduled attempt=%d status=%s delay_seconds=%.3f",
                attempt,
                status_code,
                delay,
            )
            self._sleeper(delay)

        raise AssertionError("HTTP retry loop terminated without a result")
