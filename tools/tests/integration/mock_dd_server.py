#!/usr/bin/env python3
"""Mock Datadog API server used by integration harnesses.

This server provides deterministic fixture-based responses for sync endpoints
and lightweight validation for uploader requests. It also records all incoming
requests (headers + body) to a JSONL log so integration tests can assert exact
behavior without relying on fragile stdout parsing.

Key behavior toggles:
- Service names can trigger malformed/empty sync responses.
- Commit message can trigger malformed test-management response.
- EVP proxy paths enforce EVP-specific headers and forbid DD-API-KEY usage.
- Request headers can force delay/rate-limit/status overrides for retry tests.
"""

import argparse
import base64
import gzip
import json
import os
import sys
import threading
import time
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List, Mapping, Optional
from urllib.parse import urlsplit


MAX_BODY_SIZE = 10 * 1024 * 1024


def _read_json(path: str) -> Any:
    """Load fixture JSON used to respond to sync endpoints."""
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _json_error(message: str) -> Dict[str, str]:
    """Return a standard error payload for mock endpoint failures."""
    return {"error": message}

MALFORMED_SETTINGS_SERVICE = "malformed-settings-service"
EMPTY_SETTINGS_SERVICE = "empty-settings-service"
DELAY_SETTINGS_SERVICE = "delay-settings-service"
RETRY_SETTINGS_SERVICE = "retry-settings-service"
MALFORMED_KNOWN_TESTS_SERVICE = "malformed-known-tests-service"
RETRY_KNOWN_TESTS_SERVICE = "retry-known-tests-service"
MALFORMED_KNOWN_TESTS_BODY = b"NOT_JSON_KNOWN_TESTS_RESPONSE"
MALFORMED_TEST_MANAGEMENT_COMMIT_MESSAGE = "malformed-test-management-commit-message"
RETRY_TEST_MANAGEMENT_COMMIT_MESSAGE = "retry-test-management-commit-message"
MALFORMED_TEST_MANAGEMENT_BODY = b"NOT_JSON_TEST_MANAGEMENT_RESPONSE"
RETRY_AGENTLESS_RESOURCE = "Manual.RetryAgentless"
FAIL_AGENTLESS_RESOURCE = "Manual.AlwaysFailAgentless"
BAD_REQUEST_AGENTLESS_RESOURCE = "Manual.BadRequestAgentless"
COVERAGE_RETRY_MARKER = "retry_once"
COVERAGE_ALWAYS_FAIL_MARKER = "always_fail"


class _ServerState:
    """Shared server state: fixtures and a thread-safe request log."""
    def __init__(self, fixtures: Dict[str, Any], log_path: str) -> None:
        self.fixtures = fixtures
        self.log_path = log_path
        self.log_lock = threading.Lock()
        self.retry_lock = threading.Lock()
        self.retry_counters: Dict[str, int] = {}

    def log_request(self, path: str, method: str, headers: Dict[str, str], body: bytes) -> None:
        # Persist request bodies in base64 so multipart uploads can be snapshotted.
        record = {
            "path": path,
            "method": method,
            "headers": headers,
            "body_len": len(body or b""),
            "body_b64": base64.b64encode(body or b"").decode("ascii"),
        }
        line = json.dumps(record, sort_keys=True)
        with self.log_lock:
            with open(self.log_path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
                handle.flush()

    def should_fail_n_times(self, key: str, failures: int) -> bool:
        """Return True until `failures` attempts have been observed for key."""
        if failures <= 0:
            return False
        with self.retry_lock:
            count = self.retry_counters.get(key, 0)
            if count < failures:
                self.retry_counters[key] = count + 1
                return True
        return False

    def reset_retry_counters(self) -> None:
        """Reset all retry counters to keep scenarios isolated."""
        with self.retry_lock:
            self.retry_counters = {}


def _normalize_headers(headers: Mapping[str, str]) -> Dict[str, str]:
    """Normalize request headers for logging while redacting secrets."""
    out: Dict[str, str] = {}
    for key, value in headers.items():
        if key.lower() == "dd-api-key":
            # Never log API keys in plaintext.
            out[key] = "<redacted>"
        else:
            out[key] = value
    return out


def _require_header(headers: Mapping[str, str], name: str) -> Optional[str]:
    """Return header value case-insensitively, or None when missing."""
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return None


def _require_type(data: Any, expected: str) -> Optional[str]:
    """Validate top-level Datadog request envelope type."""
    if not isinstance(data, dict):
        return "body is not a JSON object"
    data_obj = data.get("data")
    if not isinstance(data_obj, dict):
        return "missing data object"
    if data_obj.get("type") != expected:
        return "unexpected data.type: %s" % data_obj.get("type")
    return None


def _require_attrs(data: Any, keys: List[str]) -> Optional[str]:
    """Validate required attribute keys in request envelope."""
    data_obj = data.get("data") or {}
    attrs = data_obj.get("attributes")
    if not isinstance(attrs, dict):
        return "missing attributes"
    for key in keys:
        if key not in attrs:
            return "missing attribute: %s" % key
    return None


class _Handler(BaseHTTPRequestHandler):
    server_version = "MockDD/1.0"

    def _send_json(self, code: int, payload: Any, extra_headers: Optional[Dict[str, str]] = None) -> None:
        """Write JSON response payload with explicit content headers."""
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, code: int, payload: str) -> None:
        """Write plain-text response payload."""
        body = payload.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, code: int, payload: bytes) -> None:
        """Write binary/plain response payload."""
        body = payload
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self) -> bytes:
        """Read request body using Content-Length; return empty bytes on miss."""
        raw_len = self.headers.get("Content-Length")
        if not raw_len:
            return b""
        try:
            length = int(raw_len)
        except ValueError:
            return b""
        if length <= 0:
            return b""
        if length > MAX_BODY_SIZE:
            return b""
        return self.rfile.read(length)

    def _log_and_validate(self, path, body):
        """Persist request details to shared JSONL log."""
        # Capture requests for snapshot tests and assertions.
        headers = _normalize_headers(self.headers)
        self.server.state.log_request(path, self.command, headers, body)

    def _maybe_apply_response_overrides(self):
        """Apply optional mock behavior overrides from request headers."""
        delay_ms_raw = _require_header(self.headers, "X-Mock-Delay-Ms")
        if delay_ms_raw:
            try:
                delay_ms = int(delay_ms_raw)
            except ValueError:
                self._send_json(400, _json_error("invalid X-Mock-Delay-Ms header"))
                return True
            if delay_ms < 0:
                self._send_json(400, _json_error("X-Mock-Delay-Ms must be >= 0"))
                return True
            if delay_ms > 0:
                time.sleep(delay_ms / 1000.0)

        if _require_header(self.headers, "X-Mock-Rate-Limit") == "1":
            self._send_json(
                429,
                {"errors": [{"status": "429", "title": "mock rate limit"}]},
                extra_headers = {"Retry-After": "1"},
            )
            return True

        status_override = _require_header(self.headers, "X-Mock-Status-Code")
        if status_override:
            try:
                status_code = int(status_override)
            except ValueError:
                self._send_json(400, _json_error("invalid X-Mock-Status-Code header"))
                return True
            if status_code < 100 or status_code > 599:
                self._send_json(400, _json_error("X-Mock-Status-Code must be between 100 and 599"))
                return True
            payload = {} if status_code < 400 else {"errors": [{"status": str(status_code), "title": "mock status override"}]}
            self._send_json(status_code, payload)
            return True
        return False

    def _validate_settings(self, body):
        """Validate sync settings request payload and required headers."""
        # Validate the sync "settings" request payload and required headers.
        if not _require_header(self.headers, "DD-API-KEY"):
            return "missing DD-API-KEY"
        try:
            data = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return "invalid JSON body"
        err = _require_type(data, "ci_app_test_service_libraries_settings")
        if err:
            return err
        err = _require_attrs(data, ["service", "env", "repository_url", "branch", "sha"])
        if err:
            return err
        return None

    def _validate_known_tests(self, body):
        """Validate known-tests request payload and required headers."""
        # Validate the "known tests" request payload and required headers.
        if not _require_header(self.headers, "DD-API-KEY"):
            return "missing DD-API-KEY"
        try:
            data = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return "invalid JSON body"
        err = _require_type(data, "ci_app_libraries_tests_request")
        if err:
            return err
        err = _require_attrs(data, ["service", "env", "repository_url", "configurations"])
        if err:
            return err
        attrs = data.get("data", {}).get("attributes", {})
        if not isinstance(attrs.get("configurations"), dict):
            return "configurations must be an object"
        return None

    def _extract_attribute(self, body, key):
        """Extract a string attribute from request body; return empty on miss."""
        try:
            data = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return ""
        attrs = data.get("data", {}).get("attributes", {})
        service = attrs.get(key)
        return service if isinstance(service, str) else ""

    def _extract_service(self, body):
        """Extract `service` attribute from request body."""
        return self._extract_attribute(body, "service")

    def _extract_commit_message(self, body):
        """Extract `commit_message` attribute from request body."""
        return self._extract_attribute(body, "commit_message")

    def _validate_test_management(self, body):
        """Validate test-management request payload and required headers."""
        # Validate the test management request payload and required headers.
        if not _require_header(self.headers, "DD-API-KEY"):
            return "missing DD-API-KEY"
        try:
            data = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return "invalid JSON body"
        err = _require_type(data, "ci_app_libraries_tests_request")
        if err:
            return err
        err = _require_attrs(data, ["repository_url", "sha", "commit_message"])
        if err:
            return err
        return None

    def _validate_uploader_test(self, body, evp_subdomain = None):
        """Validate uploader test payload request (agentless or EVP mode)."""
        lang_hdr = _require_header(self.headers, "Datadog-Meta-Lang")
        tracer_hdr = _require_header(self.headers, "Datadog-Meta-Tracer-Version")
        if evp_subdomain:
            got_subdomain = _require_header(self.headers, "X-Datadog-EVP-Subdomain")
            if got_subdomain != evp_subdomain:
                return "missing or invalid X-Datadog-EVP-Subdomain"
        elif not _require_header(self.headers, "DD-API-KEY"):
            return "missing DD-API-KEY"
        if not lang_hdr:
            return "missing Datadog-Meta-Lang"
        if not tracer_hdr:
            return "missing Datadog-Meta-Tracer-Version"
        content_type = _require_header(self.headers, "Content-Type") or ""
        if "application/json" not in content_type:
            return "expected Content-Type application/json"
        body_for_json = body
        content_encoding = (_require_header(self.headers, "Content-Encoding") or "").lower()
        if "gzip" in content_encoding:
            try:
                body_for_json = gzip.decompress(body)
            except (OSError, gzip.BadGzipFile):
                return "invalid gzip body"
        try:
            payload = json.loads(body_for_json.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return "invalid JSON body"
        metadata = payload.get("metadata") if isinstance(payload, dict) else None
        star = metadata.get("*") if isinstance(metadata, dict) else None
        if isinstance(star, dict):
            expected_lang = star.get("language")
            if expected_lang and lang_hdr != expected_lang:
                return "Datadog-Meta-Lang does not match metadata.*.language"
            expected_tracer = star.get("library_version")
            if expected_tracer and tracer_hdr != expected_tracer:
                return "Datadog-Meta-Tracer-Version does not match metadata.*.library_version"
        return None

    def _decode_uploader_test_payload(self, body):
        """Decode uploader test payload JSON, handling optional gzip."""
        body_for_json = body
        content_encoding = (_require_header(self.headers, "Content-Encoding") or "").lower()
        if "gzip" in content_encoding:
            try:
                body_for_json = gzip.decompress(body)
            except (OSError, gzip.BadGzipFile):
                return None
        try:
            payload = json.loads(body_for_json.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        return payload if isinstance(payload, dict) else None

    def _decode_uploader_coverage_payload(self, body):
        """Decode coveragex multipart JSON payload when present."""
        content_type = _require_header(self.headers, "Content-Type") or ""
        if "boundary=" not in content_type:
            return None
        try:
            header = ("Content-Type: %s\r\n\r\n" % content_type).encode("utf-8")
            msg = BytesParser(policy = default).parsebytes(header + body)
        except (TypeError, ValueError):
            return None
        for part in msg.iter_parts():
            name = part.get_param("name", header = "Content-Disposition")
            if name != "coveragex":
                continue
            raw = part.get_payload(decode = True) or b""
            try:
                data = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return None
            return data if isinstance(data, dict) else None
        return None

    def _payload_contains_resource(self, payload, resource):
        """Return True when payload events contain a specific resource."""
        events = payload.get("events") if isinstance(payload, dict) else None
        if not isinstance(events, list):
            return False
        for evt in events:
            if not isinstance(evt, dict):
                continue
            content = evt.get("content") or {}
            if isinstance(content, dict) and content.get("resource") == resource:
                return True
        return False

    def _validate_uploader_cov(self, evp_subdomain = None):
        """Validate uploader coverage payload request (agentless or EVP mode)."""
        if evp_subdomain:
            got_subdomain = _require_header(self.headers, "X-Datadog-EVP-Subdomain")
            if got_subdomain != evp_subdomain:
                return "missing or invalid X-Datadog-EVP-Subdomain"
        elif not _require_header(self.headers, "DD-API-KEY"):
            return "missing DD-API-KEY"
        if not _require_header(self.headers, "Datadog-Meta-Lang"):
            return "missing Datadog-Meta-Lang"
        if not _require_header(self.headers, "Datadog-Meta-Tracer-Version"):
            return "missing Datadog-Meta-Tracer-Version"
        content_type = _require_header(self.headers, "Content-Type") or ""
        if not content_type.startswith("multipart/form-data"):
            return "expected multipart/form-data content type"
        return None

    def do_POST(self):  # noqa: N802 (Bazel style)
        """Handle POST routes for sync + uploader integration scenarios."""
        path = urlsplit(self.path).path
        body = self._read_body()
        self._log_and_validate(path, body)
        if path == "/__mock/reset_retries":
            self.server.state.reset_retry_counters()
            self._send_json(200, {"ok": True})
            return
        if self._maybe_apply_response_overrides():
            return

        # Sync settings endpoint.
        # Supports malformed/empty body toggles keyed by service name so
        # integration tests can assert failure diagnostics in repository rules.
        if path == "/api/v2/libraries/tests/services/setting":
            err = self._validate_settings(body)
            if err:
                self._send_json(400, _json_error(err))
                return
            service = self._extract_service(body)
            if service == MALFORMED_SETTINGS_SERVICE:
                self._send_bytes(200, b"NOT_JSON_SETTINGS_RESPONSE")
                return
            if service == EMPTY_SETTINGS_SERVICE:
                self._send_bytes(200, b"")
                return
            if service == DELAY_SETTINGS_SERVICE:
                time.sleep(0.2)
            if service == RETRY_SETTINGS_SERVICE and self.server.state.should_fail_n_times("sync_settings_retry", 1):
                self._send_json(
                    503,
                    {"errors": [{"status": "503", "title": "mock transient settings failure"}]},
                    extra_headers = {"Retry-After": "1"},
                )
                return
            self._send_json(200, self.server.state.fixtures["settings"])
            return

        # Sync known-tests endpoint.
        # Supports malformed response toggle keyed by service name.
        if path == "/api/v2/ci/libraries/tests":
            err = self._validate_known_tests(body)
            if err:
                self._send_json(400, _json_error(err))
                return
            if self._extract_service(body) == MALFORMED_KNOWN_TESTS_SERVICE:
                self._send_bytes(200, MALFORMED_KNOWN_TESTS_BODY)
                return
            if self._extract_service(body) == RETRY_KNOWN_TESTS_SERVICE and self.server.state.should_fail_n_times("sync_known_tests_retry", 1):
                self._send_json(
                    429,
                    {"errors": [{"status": "429", "title": "mock transient known-tests rate limit"}]},
                    extra_headers = {"Retry-After": "1"},
                )
                return
            self._send_json(200, self.server.state.fixtures["known_tests"])
            return

        # Sync test-management endpoint.
        # Supports malformed response toggle keyed by commit_message.
        if path == "/api/v2/test/libraries/test-management/tests":
            err = self._validate_test_management(body)
            if err:
                self._send_json(400, _json_error(err))
                return
            if self._extract_commit_message(body) == MALFORMED_TEST_MANAGEMENT_COMMIT_MESSAGE:
                self._send_bytes(200, MALFORMED_TEST_MANAGEMENT_BODY)
                return
            if self._extract_commit_message(body) == RETRY_TEST_MANAGEMENT_COMMIT_MESSAGE and self.server.state.should_fail_n_times("sync_test_management_retry", 1):
                self._send_json(
                    503,
                    {"errors": [{"status": "503", "title": "mock transient test-management failure"}]},
                    extra_headers = {"Retry-After": "1"},
                )
                return
            self._send_json(200, self.server.state.fixtures["test_management"])
            return

        # Uploader test-events endpoint.
        # Accept both agentless and EVP-proxy path forms so the same harness can
        # validate both execution modes against one mock server.
        if path in ("/api/v2/citestcycle", "/evp_proxy/v2/api/v2/citestcycle"):
            evp_subdomain = "citestcycle-intake" if path.startswith("/evp_proxy/") else None
            err = self._validate_uploader_test(body, evp_subdomain = evp_subdomain)
            if err:
                self._send_json(400, _json_error(err))
                return
            payload = self._decode_uploader_test_payload(body)
            if payload and self._payload_contains_resource(payload, BAD_REQUEST_AGENTLESS_RESOURCE):
                self._send_json(
                    400,
                    {"errors": [{"status": "400", "title": "mock uploader test bad request"}]},
                )
                return
            if payload and self._payload_contains_resource(payload, FAIL_AGENTLESS_RESOURCE):
                self._send_json(
                    503,
                    {"errors": [{"status": "503", "title": "mock uploader test sustained failure"}]},
                    extra_headers = {"Retry-After": "1"},
                )
                return
            if payload and self._payload_contains_resource(payload, RETRY_AGENTLESS_RESOURCE) and self.server.state.should_fail_n_times("uploader_cycle_retry", 1):
                self._send_json(
                    503,
                    {"errors": [{"status": "503", "title": "mock transient uploader test failure"}]},
                    extra_headers = {"Retry-After": "1"},
                )
                return
            self._send_json(200, {})
            return

        # Uploader coverage endpoint (agentless + EVP forms).
        if path in ("/api/v2/citestcov", "/evp_proxy/v2/api/v2/citestcov"):
            evp_subdomain = "citestcov-intake" if path.startswith("/evp_proxy/") else None
            err = self._validate_uploader_cov(evp_subdomain = evp_subdomain)
            if err:
                self._send_json(400, _json_error(err))
                return
            coverage_payload = self._decode_uploader_coverage_payload(body)
            marker = ""
            if isinstance(coverage_payload, dict):
                val = coverage_payload.get("mock_mode")
                marker = val if isinstance(val, str) else ""
            if marker == COVERAGE_ALWAYS_FAIL_MARKER:
                self._send_json(
                    503,
                    {"errors": [{"status": "503", "title": "mock uploader coverage sustained failure"}]},
                    extra_headers = {"Retry-After": "1"},
                )
                return
            if marker == COVERAGE_RETRY_MARKER and self.server.state.should_fail_n_times("uploader_cov_retry", 1):
                self._send_json(
                    503,
                    {"errors": [{"status": "503", "title": "mock uploader coverage transient failure"}]},
                    extra_headers = {"Retry-After": "1"},
                )
                return
            self._send_json(200, {})
            return

        # Keep unknown routes explicit to surface fixture drift quickly.
        self._send_json(404, _json_error("unknown path"))

    def log_message(self, fmt, *args):
        """Suppress default HTTP request logging to keep test output clean."""
        return


class _ReusableHTTPServer(HTTPServer):
    """HTTPServer variant with reusable address for fast reruns."""
    allow_reuse_address = True


def _load_fixture_or_exit(fixtures_dir: str, filename: str) -> Any:
    path = os.path.join(fixtures_dir, filename)
    if not os.path.exists(path):
        print("error: fixture not found: %s" % path, file = sys.stderr)
        raise SystemExit(2)
    try:
        return _read_json(path)
    except (OSError, json.JSONDecodeError) as exc:
        print("error: failed to parse fixture %s: %s" % (path, exc), file = sys.stderr)
        raise SystemExit(2)


def main() -> int:
    """Start server, print bound port for harness discovery, and serve forever."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--fixtures", required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()

    fixtures = {
        "settings": _load_fixture_or_exit(args.fixtures, "settings.json"),
        "known_tests": _load_fixture_or_exit(args.fixtures, "known_tests.json"),
        "test_management": _load_fixture_or_exit(args.fixtures, "test_management.json"),
    }

    state = _ServerState(fixtures, args.log)

    server = _ReusableHTTPServer((args.host, args.port), _Handler)
    server.state = state

    port = server.server_address[1]
    print("PORT=%s" % port, flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("mock server stopped", file = sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
