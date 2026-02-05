#!/usr/bin/env python3
import argparse
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit


def _read_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _json_error(message):
    return {"error": message}


class _ServerState:
    def __init__(self, fixtures, log_path):
        self.fixtures = fixtures
        self.log_path = log_path
        self.log_lock = threading.Lock()

    def log_request(self, path, method, headers, body_len):
        record = {
            "path": path,
            "method": method,
            "headers": headers,
            "body_len": body_len,
        }
        line = json.dumps(record, sort_keys=True)
        with self.log_lock:
            with open(self.log_path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
                handle.flush()


def _normalize_headers(headers):
    out = {}
    for key, value in headers.items():
        if key.lower() == "dd-api-key":
            out[key] = "<redacted>"
        else:
            out[key] = value
    return out


def _require_header(headers, name):
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return None


def _require_type(data, expected):
    if not isinstance(data, dict):
        return "body is not a JSON object"
    data_obj = data.get("data")
    if not isinstance(data_obj, dict):
        return "missing data object"
    if data_obj.get("type") != expected:
        return "unexpected data.type: %s" % data_obj.get("type")
    return None


def _require_attrs(data, keys):
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

    def _send_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        raw_len = self.headers.get("Content-Length")
        if not raw_len:
            return b""
        try:
            length = int(raw_len)
        except ValueError:
            return b""
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _log_and_validate(self, path, body):
        headers = _normalize_headers(self.headers)
        self.server.state.log_request(path, self.command, headers, len(body))

    def _validate_settings(self, body):
        if not _require_header(self.headers, "DD-API-KEY"):
            return "missing DD-API-KEY"
        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            return "invalid JSON body"
        err = _require_type(data, "ci_app_test_service_libraries_settings")
        if err:
            return err
        err = _require_attrs(data, ["service", "env", "repository_url", "branch", "sha"])
        if err:
            return err
        return None

    def _validate_known_tests(self, body):
        if not _require_header(self.headers, "DD-API-KEY"):
            return "missing DD-API-KEY"
        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
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

    def _validate_test_management(self, body):
        if not _require_header(self.headers, "DD-API-KEY"):
            return "missing DD-API-KEY"
        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            return "invalid JSON body"
        err = _require_type(data, "ci_app_libraries_tests_request")
        if err:
            return err
        err = _require_attrs(data, ["repository_url", "sha", "commit_message"])
        if err:
            return err
        return None

    def _validate_uploader_test(self, body):
        if not _require_header(self.headers, "DD-API-KEY"):
            return "missing DD-API-KEY"
        if not _require_header(self.headers, "Datadog-Meta-Lang"):
            return "missing Datadog-Meta-Lang"
        if not _require_header(self.headers, "Datadog-Meta-Tracer-Version"):
            return "missing Datadog-Meta-Tracer-Version"
        content_type = _require_header(self.headers, "Content-Type") or ""
        if "application/json" not in content_type:
            return "expected Content-Type application/json"
        try:
            json.loads(body.decode("utf-8"))
        except Exception:
            return "invalid JSON body"
        return None

    def _validate_uploader_cov(self):
        if not _require_header(self.headers, "DD-API-KEY"):
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
        path = urlsplit(self.path).path
        body = self._read_body()
        self._log_and_validate(path, body)

        if path == "/api/v2/libraries/tests/services/setting":
            err = self._validate_settings(body)
            if err:
                self._send_json(400, _json_error(err))
                return
            self._send_json(200, self.server.state.fixtures["settings"])
            return
        if path == "/api/v2/ci/libraries/tests":
            err = self._validate_known_tests(body)
            if err:
                self._send_json(400, _json_error(err))
                return
            self._send_json(200, self.server.state.fixtures["known_tests"])
            return
        if path == "/api/v2/test/libraries/test-management/tests":
            err = self._validate_test_management(body)
            if err:
                self._send_json(400, _json_error(err))
                return
            self._send_json(200, self.server.state.fixtures["test_management"])
            return
        if path == "/api/v2/citestcycle":
            err = self._validate_uploader_test(body)
            if err:
                self._send_json(400, _json_error(err))
                return
            self._send_json(200, {})
            return
        if path == "/api/v2/citestcov":
            err = self._validate_uploader_cov()
            if err:
                self._send_json(400, _json_error(err))
                return
            self._send_json(200, {})
            return

        self._send_json(404, _json_error("unknown path"))

    def log_message(self, fmt, *args):
        return


class _ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--fixtures", required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()

    fixtures = {
        "settings": _read_json(os.path.join(args.fixtures, "settings.json")),
        "known_tests": _read_json(os.path.join(args.fixtures, "known_tests.json")),
        "test_management": _read_json(os.path.join(args.fixtures, "test_management.json")),
    }

    state = _ServerState(fixtures, args.log)

    server = _ReusableHTTPServer((args.host, args.port), _Handler)
    server.state = state

    port = server.server_address[1]
    print("PORT=%s" % port, flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
