#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Exercise the dependency-free HTTP transport against loopback servers.

Real requests protect retry, proxy, timeout, and exact-body behavior of stdlib HTTP.
"""

from __future__ import annotations

from contextlib import contextmanager
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
from pathlib import Path
import ssl
import tempfile
import threading
import time
from typing import Iterator
import unittest
from unittest import mock
from urllib.error import HTTPError, URLError

from uploader_test_support import add_uploader_runtime_to_path

add_uploader_runtime_to_path()

from uploader_py.transport import (  # noqa: E402
    DEFAULT_MAX_RETRY_DELAY_SECONDS,
    HttpTransport,
    HttpTransportError,
    _retry_after_seconds,
    prepare_coverage_multipart,
)
from uploader_py.logging_utils import configure_logging  # noqa: E402


class _RecordingHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:
        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length)
        self.server.records.append(  # type: ignore[attr-defined]
            {
                "path": self.path,
                "headers": {key.lower(): value for key, value in self.headers.items()},
                "body": body,
            }
        )
        response = self.server.responses.pop(0)  # type: ignore[attr-defined]
        delay = float(response.get("delay", 0))
        if delay:
            time.sleep(delay)
        response_body = response.get("body", b"ok")
        self.send_response(int(response.get("status", 200)))
        for name, value in response.get("headers", {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(response_body)))
        self.end_headers()
        try:
            self.wfile.write(response_body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format: str, *args: object) -> None:
        pass


class _Response(io.BytesIO):
    def __init__(self, body: bytes = b"ok", *, status: int = 200) -> None:
        super().__init__(body)
        self.status = status
        self.headers: dict[str, str] = {}


class _TlsReadFailure(_Response):
    def read(self, _size: int = -1) -> bytes:
        raise ssl.SSLEOFError(8, "TLS peer closed during response read")


@contextmanager
def _server(*responses: dict[str, object]) -> Iterator[tuple[ThreadingHTTPServer, str]]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _RecordingHandler)
    server.daemon_threads = True
    server.records = []  # type: ignore[attr-defined]
    server.responses = list(responses or ({"status": 200},))  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        yield server, f"http://{host}:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


class HttpTransportTests(unittest.TestCase):
    def test_custom_agentless_and_evp_json_requests_preserve_body_and_headers(self) -> None:
        with _server({"status": 202}, {"status": 204, "body": b""}) as (server, base):
            transport = HttpTransport(max_attempts=1)
            agentless_body = b'{"events":[{"ok":true}]}'
            agentless = transport.post_json(
                f"{base}/api/v2/citestcycle",
                {"DD-API-KEY": "secret", "X-Datadog-Trace-Id": "123"},
                agentless_body,
            )
            evp = transport.post_json(
                f"{base}/evp_proxy/v2/api/v2/citestcycle",
                {"X-Datadog-EVP-Subdomain": "citestcycle-intake"},
                b"{}",
            )

        self.assertTrue(agentless.succeeded)
        self.assertTrue(evp.succeeded)
        self.assertEqual(agentless_body, server.records[0]["body"])  # type: ignore[attr-defined]
        self.assertEqual(
            "secret",
            server.records[0]["headers"]["dd-api-key"],  # type: ignore[attr-defined]
        )
        self.assertEqual(
            "citestcycle-intake",
            server.records[1]["headers"]["x-datadog-evp-subdomain"],  # type: ignore[attr-defined]
        )

    def test_gzip_and_exact_content_length(self) -> None:
        original = b'{"events":[{"value":"payload"}]}'
        with _server({"status": 200}) as (server, base):
            result = HttpTransport(max_attempts=1).post_json(
                f"{base}/gzip",
                {},
                original,
                gzip_body=True,
            )
        record = server.records[0]  # type: ignore[attr-defined]
        self.assertTrue(result.succeeded)
        self.assertEqual("gzip", record["headers"]["content-encoding"])
        self.assertEqual(len(record["body"]), int(record["headers"]["content-length"]))
        self.assertEqual(original, gzip.decompress(record["body"]))

    def test_precompressed_json_body_preserves_exact_bytes_and_encoding(self) -> None:
        compressed = gzip.compress(b'{"events":[]}', mtime=0)
        with _server({"status": 200}) as (server, base):
            result = HttpTransport(max_attempts=1).post_json(
                f"{base}/gzip",
                {},
                compressed,
                content_encoding="gzip",
            )
        record = server.records[0]  # type: ignore[attr-defined]
        self.assertTrue(result.succeeded)
        self.assertEqual("gzip", record["headers"]["content-encoding"])
        self.assertEqual(compressed, record["body"])

    def test_retry_policy_honors_retry_after_and_caps_at_four_attempts(self) -> None:
        waits: list[float] = []
        with _server(
            {"status": 429, "headers": {"Retry-After": "3"}},
            {"status": 200},
        ) as (server, base):
            result = HttpTransport(sleeper=waits.append).post_json(base, {}, b"{}")
        self.assertTrue(result.succeeded)
        self.assertEqual(2, result.attempts)
        self.assertEqual((3.0,), result.retry_delays)
        self.assertEqual([3.0], waits)
        self.assertEqual(2, len(server.records))  # type: ignore[attr-defined]

        waits = []
        with _server(*({"status": 500} for _ in range(4))) as (server, base):
            exhausted = HttpTransport(sleeper=waits.append).post_json(base, {}, b"{}")
        self.assertFalse(exhausted.succeeded)
        self.assertEqual(4, exhausted.attempts)
        self.assertEqual(3, exhausted.retries)
        self.assertEqual([2.0, 2.0, 2.0], waits)
        self.assertEqual(4, len(server.records))  # type: ignore[attr-defined]

    def test_retry_after_delay_is_finite_and_capped(self) -> None:
        self.assertEqual(3.0, _retry_after_seconds("3", 0.0))

        excessive_values = (
            ("86400", 0.0),
            ("Wed, 02 Jan 2030 00:00:00 GMT", 1_893_456_000.0),
            ("9" * 400, 0.0),
        )
        for value, now in excessive_values:
            with self.subTest(value=value[:40]):
                self.assertEqual(
                    DEFAULT_MAX_RETRY_DELAY_SECONDS,
                    _retry_after_seconds(value, now),
                )

    def test_each_retryable_http_status_retries_then_succeeds(self) -> None:
        for status in (408, 500, 502, 503, 504):
            with self.subTest(status=status), _server(
                {"status": status},
                {"status": 200},
            ) as (server, base):
                waits: list[float] = []
                result = HttpTransport(sleeper=waits.append).post_json(
                    base,
                    {},
                    b"{}",
                )

                self.assertTrue(result.succeeded)
                self.assertEqual(2, result.attempts)
                self.assertEqual([2.0], waits)
                self.assertEqual(2, len(server.records))  # type: ignore[attr-defined]

    def test_transient_connection_and_timeout_retry_then_succeed(self) -> None:
        for first_error, error_name in (
            (URLError(ConnectionRefusedError("refused")), "ConnectionRefusedError"),
            (TimeoutError("timed out"), "TimeoutError"),
        ):
            with self.subTest(error=error_name):
                waits: list[float] = []
                transport = HttpTransport(sleeper=waits.append)
                opener = mock.Mock()
                opener.open.side_effect = [first_error, _Response()]
                transport._opener = opener

                result = transport.post_json(
                    "http://localhost:8126/upload",
                    {},
                    b"{}",
                )

                self.assertTrue(result.succeeded)
                self.assertEqual(2, result.attempts)
                self.assertEqual([2.0], waits)
                self.assertEqual(2, opener.open.call_count)

    def test_tls_response_read_failures_retry_then_succeed(self) -> None:
        failures = (
            _TlsReadFailure(),
            HTTPError(
                "https://localhost/upload",
                503,
                "unavailable",
                {},
                _TlsReadFailure(),
            ),
        )
        for failure in failures:
            with self.subTest(response=type(failure).__name__):
                waits: list[float] = []
                transport = HttpTransport(sleeper=waits.append)
                opener = mock.Mock()
                opener.open.side_effect = [failure, _Response()]
                transport._opener = opener

                result = transport.post_json(
                    "https://localhost/upload",
                    {},
                    b"{}",
                )

                self.assertTrue(result.succeeded)
                self.assertEqual(2, result.attempts)
                self.assertEqual([2.0], waits)
                self.assertEqual(2, opener.open.call_count)

    def test_certificate_verification_failure_is_terminal(self) -> None:
        waits: list[float] = []
        transport = HttpTransport(sleeper=waits.append)
        opener = mock.Mock()
        opener.open.side_effect = ssl.SSLCertVerificationError(
            1,
            "certificate verify failed",
        )
        transport._opener = opener

        result = transport.post_json(
            "https://localhost/upload",
            {},
            b"{}",
        )

        self.assertFalse(result.succeeded)
        self.assertEqual(1, result.attempts)
        self.assertEqual("SSLCertVerificationError", result.transport_error)
        self.assertEqual([], waits)

    def test_debug_logs_attempt_and_retry_without_url_secrets(self) -> None:
        stream = io.StringIO()
        logger = configure_logging(debug=True, secrets=("api-secret",), stream=stream)
        with _server({"status": 500}, {"status": 200}) as (_server_instance, base):
            transport = HttpTransport(
                sleeper=lambda _delay: None,
                logger=logger,
            )
            transport.set_log_context("task-1", "test", "payloads/tests/events.json")
            result = transport.post_json(
                f"{base}/upload?signature=url-secret",
                {"DD-API-KEY": "api-secret"},
                b"{}",
            )

        self.assertTrue(result.succeeded)
        output = stream.getvalue()
        self.assertIn("attempt=1/4", output)
        self.assertIn("retry scheduled", output)
        self.assertIn("task=task-1 type=test file=payloads/tests/events.json", output)
        self.assertIn("succeeded attempt=2 status=200", output)
        self.assertNotIn("url-secret", output)
        self.assertNotIn("api-secret", output)

    def test_413_and_other_permanent_4xx_are_never_retried(self) -> None:
        for status in (400, 401, 403, 404, 413):
            with self.subTest(status=status), _server({"status": status}) as (server, base):
                waits: list[float] = []
                result = HttpTransport(sleeper=waits.append).post_json(base, {}, b"{}")
                self.assertFalse(result.succeeded)
                self.assertEqual(status, result.status_code)
                self.assertEqual(1, result.attempts)
                self.assertEqual([], waits)
                self.assertEqual(1, len(server.records))  # type: ignore[attr-defined]

    def test_gzip_request_body_is_byte_identical_across_retry(self) -> None:
        original = b'{"events":[{"value":"payload"}]}'
        with _server({"status": 500}, {"status": 200}) as (server, base):
            result = HttpTransport(sleeper=lambda _delay: None).post_json(
                f"{base}/gzip-retry",
                {},
                original,
                gzip_body=True,
            )

        self.assertTrue(result.succeeded)
        self.assertEqual(2, result.attempts)
        first, second = server.records  # type: ignore[attr-defined]
        self.assertEqual(first["body"], second["body"])
        self.assertEqual(original, gzip.decompress(first["body"]))

    def test_prepared_multipart_is_exact_and_reopened_for_retry(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            coverage = root / "coverage.json"
            coverage.write_bytes(b'{"files":[]}')
            prepared = prepare_coverage_multipart(
                root / "multipart.body",
                event_body=b'{"dummy":true}',
                coverage_path=coverage,
                coverage_filename="filecoveragex.json",
                coverage_content_type="application/json",
            )
            with _server({"status": 500}, {"status": 200}) as (server, base):
                result = HttpTransport(sleeper=lambda _delay: None).post_prepared_multipart(
                    base,
                    {},
                    prepared,
                )

        self.assertTrue(result.succeeded)
        self.assertEqual(2, result.attempts)
        first, second = server.records  # type: ignore[attr-defined]
        self.assertEqual(first["body"], second["body"])
        self.assertEqual(prepared.content_length, len(first["body"]))
        self.assertEqual(prepared.content_type, first["headers"]["content-type"])
        self.assertIn(b'name="event"; filename="fileevent.json"', first["body"])
        self.assertIn(b'name="coveragex"; filename="filecoveragex.json"', first["body"])
        self.assertIn(b'{"files":[]}', first["body"])

    def test_response_diagnostics_are_bounded(self) -> None:
        with _server({"status": 400, "body": b"x" * 100}) as (_server_instance, base):
            result = HttpTransport(max_attempts=1, response_limit=16).post_json(
                base,
                {},
                b"{}",
            )
        self.assertEqual(b"x" * 16, result.body_excerpt)
        self.assertTrue(result.body_truncated)

    def test_request_timeout_is_reported_without_exposing_urls(self) -> None:
        with _server({"status": 200, "delay": 0.2}) as (_server_instance, base):
            result = HttpTransport(
                max_attempts=1,
                connect_timeout=0.05,
                request_timeout=0.05,
            ).post_json(f"{base}/slow?token=secret", {}, b"{}")
        self.assertFalse(result.succeeded)
        self.assertIsNone(result.status_code)
        self.assertIn(result.transport_error, {"TimeoutError", "timeout"})
        self.assertNotIn("secret", result.transport_error or "")

    def test_http_proxy_and_no_proxy_use_snapshotted_configuration(self) -> None:
        with _server({"status": 200}) as (proxy, proxy_base):
            transport = HttpTransport(
                max_attempts=1,
                proxy_environment=(
                    ("HTTP_PROXY", "http://upper.invalid:1"),
                    ("http_proxy", proxy_base),
                ),
            )
            result = transport.post_json("http://origin.invalid/upload", {}, b"{}")
        self.assertTrue(result.succeeded)
        self.assertEqual(
            "http://origin.invalid/upload",
            proxy.records[0]["path"],  # type: ignore[attr-defined]
        )

        with _server({"status": 200}) as (origin, origin_base):
            with _server({"status": 502}) as (proxy, proxy_base):
                bypassed = HttpTransport(
                    max_attempts=1,
                    proxy_environment=(
                        ("HTTP_PROXY", proxy_base),
                        ("NO_PROXY", "127.0.0.1"),
                    ),
                ).post_json(f"{origin_base}/direct", {}, b"{}")
        self.assertTrue(bypassed.succeeded)
        self.assertEqual(1, len(origin.records))  # type: ignore[attr-defined]
        self.assertEqual(0, len(proxy.records))  # type: ignore[attr-defined]

    def test_invalid_effective_proxy_is_rejected_before_any_request(self) -> None:
        for proxy in (
            "http://localhost:notaport",
            "http://localhost:65536",
            "socks5://localhost:1080",
            "http://localhost/proxy-path",
            "http://user:%FF@localhost:8080",
        ):
            with self.subTest(proxy=proxy), self.assertRaisesRegex(
                HttpTransportError,
                "invalid HTTP proxy configuration",
            ):
                HttpTransport(
                    max_attempts=1,
                    proxy_environment=(("http_proxy", proxy),),
                )

        # Lowercase proxy variables retain their existing precedence over an
        # ignored uppercase value, so only the effective proxy is validated.
        HttpTransport(
            max_attempts=1,
            proxy_environment=(
                ("HTTP_PROXY", "http://localhost:notaport"),
                ("http_proxy", "http://localhost:8080"),
            ),
        )

    def test_system_tls_verification_and_input_guards_are_enabled(self) -> None:
        self.assertTrue(HttpTransport(max_attempts=1).verifies_tls)
        with self.assertRaisesRegex(HttpTransportError, "must not contain credentials"):
            HttpTransport(max_attempts=1).post_json(
                "https://user:secret@example.test/upload",
                {},
                b"{}",
            )
        for url in (
            "http://localhost:notaport/upload",
            "http://localhost:65536/upload",
            "http://localhost/path with space",
            "http://localhost/%ZZ",
            "http://exa%mple.invalid/upload",
        ):
            with self.subTest(url=url), self.assertRaisesRegex(
                HttpTransportError,
                "absolute HTTP",
            ):
                HttpTransport(max_attempts=1).post_json(url, {}, b"{}")
        with self.assertRaisesRegex(HttpTransportError, "header value"):
            HttpTransport(max_attempts=1).post_json(
                "https://example.test/upload",
                {"X-Test": "ok\r\nInjected: yes"},
                b"{}",
            )


if __name__ == "__main__":
    unittest.main()
