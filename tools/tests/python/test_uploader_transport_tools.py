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

from contextlib import closing, contextmanager
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import select
import socket
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
    _PersistentConnection,
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
                "peer": self.client_address,
            }
        )
        response = self.server.responses.pop(0)  # type: ignore[attr-defined]
        delay = float(response.get("delay", 0))
        if delay:
            time.sleep(delay)
        response_body = response.get("body", b"ok")
        if "raw_response" not in response:
            self.send_response(int(response.get("status", 200)))
            for name, value in response.get("headers", {}).items():
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
        try:
            self.wfile.write(response.get("raw_response", response_body))
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        if response.get("disconnect"):
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            self.server.disconnected.set()  # type: ignore[attr-defined]

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
def _server(*responses: dict[str, object], tls_context=None) -> Iterator[tuple[ThreadingHTTPServer, str]]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _RecordingHandler)
    if tls_context is not None:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    server.daemon_threads = True
    server.records = []  # type: ignore[attr-defined]
    server.responses = list(responses or ({"status": 200},))  # type: ignore[attr-defined]
    server.disconnected = threading.Event()  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        yield server, f"{'https' if tls_context is not None else 'http'}://{host}:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


class HttpTransportTests(unittest.TestCase):
    def test_persistent_redirect_does_not_forward_origin_credentials(self) -> None:
        with _server({}) as (other, other_url):
            with _server({"status": 302, "headers": {"Location": other_url}}) as (origin, base):
                with closing(HttpTransport(keep_alive=True, max_attempts=3)) as transport:
                    result = transport.post_json(base, {"dd-api-key": "fixture"}, b"{}")
                self.assertEqual(302, result.status_code)
                self.assertEqual(1, result.attempts)
                self.assertEqual(1, len(origin.records))
                self.assertEqual([], other.records)

    def test_persistent_chunked_success_and_http_errors_are_fully_consumed(self) -> None:
        for status in (200, 400):
            raw = f"HTTP/1.1 {status} response\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n".encode()
            with self.subTest(status=status), _server({"raw_response": raw}, {}) as (server, base):
                transport = HttpTransport(keep_alive=True, max_attempts=1)
                try:
                    result = transport.post_json(base, {}, b"{}")
                    self.assertEqual(status, result.status_code)
                    self.assertEqual(b"ok", result.body_excerpt)
                    self.assertTrue(transport.post_json(base, {}, b"{}").succeeded)
                finally:
                    transport.close()
                self.assertEqual(1, len({r["peer"] for r in server.records}))

    def test_persistent_https_reuses_an_authenticated_connect_tunnel(self) -> None:
        fixtures = Path(__file__).with_name("fixtures")
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(fixtures / "http-test-cert.pem", fixtures / "http-test-key.pem")
        trusted = ssl.create_default_context(cafile=str(fixtures / "http-test-cert.pem"))
        connects = []
        tunnel_closed = threading.Event()
        with _server({}, {}, tls_context=server_context) as (origin, base):
            class Tunnel(BaseHTTPRequestHandler):
                def log_message(self, *_args):
                    pass

                def do_CONNECT(self):
                    connects.append((self.path, {k.lower(): v for k, v in self.headers.items()}))
                    try:
                        with socket.create_connection(origin.server_address, timeout=2) as upstream:
                            upstream.settimeout(None)
                            self.send_response(200, "Connection Established")
                            self.end_headers()
                            self.wfile.flush()
                            while True:
                                ready, _, _ = select.select([self.connection, upstream], [], [])
                                for source in ready:
                                    body = source.recv(65536)
                                    if not body:
                                        return
                                    target = upstream if source is self.connection else self.connection
                                    target.sendall(body)
                    finally:
                        self.close_connection = True
                        tunnel_closed.set()

            proxy = ThreadingHTTPServer(("127.0.0.1", 0), Tunnel)
            proxy.daemon_threads = True
            thread = threading.Thread(target=proxy.serve_forever, daemon=True)
            thread.start()
            transport = HttpTransport(keep_alive=True, max_attempts=1, ssl_context=trusted,
                proxy_environment=(("https_proxy", f"http://fixture:password@127.0.0.1:{proxy.server_port}"),))
            try:
                for _ in range(2):
                    self.assertTrue(transport.post_json(base + "/events", {"dd-api-key": "fixture"}, b"{}").succeeded)
            finally:
                transport.close()
                proxy.shutdown()
                proxy.server_close()
                thread.join(timeout=2)
            self.assertTrue(tunnel_closed.wait(timeout=2))
            self.assertEqual(1, len(connects))
            self.assertEqual("Basic Zml4dHVyZTpwYXNzd29yZA==", connects[0][1]["proxy-authorization"])
            self.assertNotIn("dd-api-key", connects[0][1])
            self.assertEqual(2, len(origin.records))
            self.assertEqual(1, len({r["peer"] for r in origin.records}))
            self.assertTrue(all("proxy-authorization" not in r["headers"] and r["headers"]["dd-api-key"] == "fixture" for r in origin.records))

    def test_persistent_connection_is_discarded_after_malformed_chunks(self) -> None:
        for status in (200, 400):
            raw = f"HTTP/1.1 {status} response\r\nTransfer-Encoding: chunked\r\n\r\nnot-hex\r\n".encode()
            with self.subTest(status=status), _server({"raw_response": raw}, {}) as (server, base):
                transport = HttpTransport(keep_alive=True, max_attempts=2, retry_delay=0)
                try:
                    result = transport.post_json(base, {}, b"{}")
                finally:
                    transport.close()
                self.assertTrue(result.succeeded)
                self.assertEqual(2, result.attempts)
                self.assertEqual(2, len({r["peer"] for r in server.records}))

    def test_persistent_connection_is_discarded_after_empty_premature_eof(self) -> None:
        raw = b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n"
        with _server({"raw_response": raw, "disconnect": True}, {}) as (server, base):
            transport = HttpTransport(keep_alive=True, max_attempts=1)
            try:
                self.assertTrue(transport.post_json(base, {}, b"{}").succeeded)
                self.assertTrue(server.disconnected.wait(timeout=2))
                self.assertTrue(transport.post_json(base, {}, b"{}").succeeded)
            finally:
                transport.close()
            self.assertEqual(2, len({r["peer"] for r in server.records}))

    def test_persistent_connection_is_discarded_after_eof_in_chunk_trailers(self) -> None:
        raw = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n"
        with _server({"raw_response": raw, "disconnect": True}, {}) as (server, base):
            transport = HttpTransport(keep_alive=True, max_attempts=1)
            try:
                self.assertTrue(transport.post_json(base, {}, b"{}").succeeded)
                self.assertTrue(server.disconnected.wait(timeout=2))
                self.assertTrue(transport.post_json(base, {}, b"{}").succeeded)
            finally:
                transport.close()
            self.assertEqual(2, len({r["peer"] for r in server.records}))

    def test_persistent_https_reuses_verified_tls_and_rejects_untrusted_certificates(self) -> None:
        fixtures = Path(__file__).with_name("fixtures")
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(fixtures / "http-test-cert.pem", fixtures / "http-test-key.pem")
        trusted = ssl.create_default_context(cafile=str(fixtures / "http-test-cert.pem"))
        with _server({}, {}, tls_context=server_context) as (server, base):
            rejected = HttpTransport(keep_alive=True, max_attempts=2)
            try:
                result = rejected.post_json(base, {}, b"{}")
                self.assertFalse(result.succeeded)
                self.assertEqual(1, result.attempts)
                self.assertEqual("SSLCertVerificationError", result.transport_error)
            finally:
                rejected.close()
            transport = HttpTransport(keep_alive=True, ssl_context=trusted, max_attempts=1)
            try:
                for _ in range(2):
                    self.assertTrue(transport.post_json(base, {}, b"{}").succeeded)
            finally:
                transport.close()
            self.assertEqual(1, len({r["peer"] for r in server.records}))

    def test_persistent_connect_authentication_never_reaches_the_origin(self) -> None:
        from urllib.request import Request

        pool = _PersistentConnection()
        factory = mock.Mock()
        try:
            for _ in range(2):
                request = Request("https://origin.invalid/events", data=b"{}", method="POST")
                request.timeout = 1
                request.set_proxy("proxy.invalid:8080", "http")
                request.add_header("Proxy-authorization", "Basic fixture")
                pool.open(factory, request, context="same-context")
            factory.assert_called_once_with("proxy.invalid:8080", timeout=1, context="same-context")
            factory.return_value.set_tunnel.assert_called_once_with("origin.invalid", headers={"Proxy-Authorization": "Basic fixture"})
            for call in factory.return_value.request.call_args_list:
                self.assertNotIn("Proxy-Authorization", call.args[3])
        finally:
            pool.close()
        factory.return_value.close.assert_called_once_with()

    def test_persistent_idle_disconnect_uses_only_the_existing_retry_budget(self) -> None:
        with _server({"disconnect": True}, {}) as (server, base):
            transport = HttpTransport(keep_alive=True, max_attempts=2, retry_delay=0)
            try:
                self.assertTrue(transport.post_json(base, {}, b"first").succeeded)
                self.assertTrue(server.disconnected.wait(timeout=2))
                result = transport.post_json(base, {}, b"second")
            finally:
                transport.close()
            self.assertTrue(result.succeeded)
            self.assertEqual(2, result.attempts)
            self.assertEqual([b"first", b"second"], [r["body"] for r in server.records])

    def test_persistent_retry_responses_reuse_the_socket_without_replaying_bytes(self) -> None:
        with _server({"status": 429, "headers": {"Retry-After": "0"}}, {}) as (server, base):
            transport = HttpTransport(keep_alive=True, max_attempts=2)
            try:
                result = transport.post_json(base, {"dd-api-key": "fixture"}, b"exact")
            finally:
                transport.close()
            self.assertTrue(result.succeeded)
            self.assertEqual(2, result.attempts)
            self.assertEqual(1, len({r["peer"] for r in server.records}))
            self.assertEqual([b"exact", b"exact"], [r["body"] for r in server.records])

    def test_persistent_connections_do_not_cross_origins(self) -> None:
        with _server({}, {}) as (first, first_url), _server({}) as (second, second_url):
            transport = HttpTransport(keep_alive=True, max_attempts=1)
            try:
                for url in (first_url, second_url, first_url):
                    self.assertTrue(transport.post_json(url, {}, b"{}").succeeded)
            finally:
                transport.close()
            self.assertEqual(2, len({r["peer"] for r in first.records}))
            self.assertEqual(1, len(second.records))

    def test_persistent_proxy_and_no_proxy_keep_the_same_routing(self) -> None:
        with _server({}, {}) as (proxy, proxy_url), _server({}) as (origin, origin_url):
            transport = HttpTransport(keep_alive=True, max_attempts=1,
                proxy_environment=(("http_proxy", proxy_url), ("no_proxy", "127.0.0.1")))
            try:
                for url in ("http://example.invalid/events", "http://example.invalid/events", origin_url):
                    self.assertTrue(transport.post_json(url, {}, b"{}").succeeded)
            finally:
                transport.close()
            self.assertEqual(["http://example.invalid/events"] * 2, [r["path"] for r in proxy.records])
            self.assertEqual(1, len({r["peer"] for r in proxy.records}))
            self.assertEqual(1, len(origin.records))

    def test_persistent_http_is_opt_in_and_reuses_one_connection(self) -> None:
        for enabled in (False, True):
            with self.subTest(enabled=enabled), _server({}, {}) as (server, base):
                transport = HttpTransport(keep_alive=enabled, max_attempts=1)
                try:
                    for _ in range(2):
                        self.assertTrue(transport.post_json(base + "/events", {}, b"{}").succeeded)
                finally:
                    transport.close()
                self.assertEqual(1 if enabled else 2, len({record["peer"] for record in server.records}))

    def test_persistent_http_discards_closed_or_unconsumed_responses(self) -> None:
        for response in ({"headers": {"Connection": "close"}}, {"body": b"too long"}):
            with self.subTest(response=response), _server(response, {}) as (server, base):
                transport = HttpTransport(keep_alive=True, max_attempts=1, response_limit=2)
                try:
                    for _ in range(2):
                        self.assertTrue(transport.post_json(base, {}, b"{}").succeeded)
                finally:
                    transport.close()
                self.assertEqual(2, len({record["peer"] for record in server.records}))

    def test_custom_agentless_and_evp_json_requests_preserve_body_and_headers(self) -> None:
        for keep_alive in (False, True):
            with _server({"status": 202}, {"status": 204, "body": b""}) as (server, base), closing(HttpTransport(max_attempts=1, keep_alive=keep_alive)) as transport:
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
            self.assertEqual(1 if keep_alive else 2, len({r["peer"] for r in server.records}))

    def test_measurements_record_prepared_bytes_and_http_without_extra_encoding(self) -> None:
        from uploader_py.metrics import PhaseRecorder

        wall = iter((0.0, 1.0, 1.0, 6.0))
        cpu = iter((0.0, 0.5, 0.5, 0.75))
        recorder = PhaseRecorder(lambda: next(wall), lambda: next(cpu))
        transport = HttpTransport(max_attempts=1)
        transport.set_measurements(recorder)
        bodies = []

        def opened(request, **_kwargs):
            bodies.append(request.data.read())
            return _Response()

        with mock.patch.object(transport._opener, "open", side_effect=opened):
            result = transport.post_json("https://example.invalid/events", {}, b'{"events":[]}', gzip_body=True)
        self.assertTrue(result.succeeded)
        self.assertEqual(b'{"events":[]}', gzip.decompress(bodies[0]))
        self.assertEqual({"prepared_body_bytes": len(bodies[0])}, dict(recorder.byte_counts()))
        phases = {name: (wall, cpu) for name, wall, cpu in recorder.snapshot()}
        self.assertEqual((1.0, 0.5), phases["request_encoding_transport"])
        self.assertEqual((5.0, 0.25), phases["http"])
        transport.set_measurements(None)
        self.assertIsNone(transport._measurements)

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
        with _server(
            {"status": 500, "body": b"backend api-secret\nretry"},
            {"status": 200},
        ) as (_server_instance, base):
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
        self.assertIn("body_excerpt='backend <redacted>\\nretry'", output)
        self.assertIn("body_truncated=False", output)
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
        for keep_alive in (False, True):
            original = b'{"events":[{"value":"payload"}]}'
            with _server({"status": 500}, {"status": 200}) as (server, base), closing(HttpTransport(sleeper=lambda _delay: None, keep_alive=keep_alive)) as transport:
                result = transport.post_json(
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
            self.assertEqual(1 if keep_alive else 2, len({r["peer"] for r in server.records}))

    def test_prepared_multipart_is_exact_and_reopened_for_retry(self) -> None:
        for keep_alive in (False, True):
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
                with _server({"status": 500}, {"status": 200}) as (server, base), closing(HttpTransport(sleeper=lambda _delay: None, keep_alive=keep_alive)) as transport:
                    result = transport.post_prepared_multipart(
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
            self.assertEqual(1 if keep_alive else 2, len({r["peer"] for r in server.records}))

    def test_response_diagnostics_are_bounded(self) -> None:
        stream = io.StringIO()
        logger = configure_logging(debug=True, stream=stream)
        with _server({"status": 400, "body": b"x" * 100}) as (_server_instance, base):
            result = HttpTransport(
                max_attempts=1,
                response_limit=16,
                logger=logger,
            ).post_json(
                base,
                {},
                b"{}",
            )
        self.assertEqual(b"x" * 16, result.body_excerpt)
        self.assertTrue(result.body_truncated)
        self.assertIn("body_excerpt='xxxxxxxxxxxxxxxx'", stream.getvalue())
        self.assertIn("body_truncated=True", stream.getvalue())

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
