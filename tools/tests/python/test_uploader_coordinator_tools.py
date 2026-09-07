#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Exercise mixed-protocol coordination over the real worker pool.

These tests prove shared inputs and aggregation work across every payload type.
"""

from __future__ import annotations

from contextlib import contextmanager
from io import StringIO
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

from uploader_test_support import add_uploader_runtime_to_path

add_uploader_runtime_to_path()

from uploader_py.codeowners import load_codeowners_matcher  # noqa: E402
from uploader_py.coordinator import (  # noqa: E402
    CoordinatorSettings,
    run_discovered_tasks,
)
from uploader_py.credentials import (  # noqa: E402
    api_key_fingerprint,
    check_api_key_fingerprint,
)
from uploader_py.discovery import ScanRoot, discover_file_tasks  # noqa: E402
from uploader_py.endpoints import EndpointSet  # noqa: E402
from uploader_py.enrichment import ContextPlan, ContextRecord  # noqa: E402
from uploader_py.logging_utils import configure_logging  # noqa: E402
from uploader_py.models import FileResult, FileStatus  # noqa: E402
from uploader_py.reporting import emit_report  # noqa: E402
from uploader_py.resources import LoadedResources  # noqa: E402
from uploader_py.transport import (  # noqa: E402
    HttpResult,
    HttpTransport,
    HttpTransportError,
)
from uploader_py.worker_pool import WorkerPoolInterrupted, WorkerPoolRun  # noqa: E402


class _MixedTransport:
    def __init__(
        self,
        barrier: threading.Barrier | None,
        records: list[dict[str, object]],
        lock: threading.Lock,
    ) -> None:
        self.barrier = barrier
        self.records = records
        self.lock = lock

    def _record(self, kind: str, body: bytes) -> HttpResult:
        if self.barrier is not None:
            self.barrier.wait(timeout=2)
        with self.lock:
            self.records.append({"kind": kind, "body": body})
        return HttpResult(200, 1)

    def post_json(self, _url, _headers, body, *, gzip_body=False, content_encoding=None):
        raw = Path(body).read_bytes()
        return self._record("json", raw)

    def post_prepared_multipart(self, _url, _headers, prepared):
        return self._record("multipart", prepared.path.read_bytes())


def _write_payload(output: Path, kind: str, name: str, value: object) -> Path:
    path = output / "payloads" / kind / name
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(value, bytes):
        path.write_bytes(value)
    else:
        path.write_text(json.dumps(value), encoding="utf-8")
    return path


class CoordinatorTests(unittest.TestCase):
    def test_invalid_proxy_is_rejected_before_dry_run_workers_start(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            with self.assertRaisesRegex(
                HttpTransportError,
                "invalid HTTP proxy configuration",
            ):
                run_discovered_tasks(
                    discover_file_tasks(()),
                    settings=CoordinatorSettings(
                        workspace=root,
                        workers=1,
                        dry_run=True,
                        validate_enrichment=False,
                        expected_enriched_tags=(),
                        gzip_payloads=False,
                        keep_payloads=False,
                        filter_prefix=False,
                        rules_version="rules-1",
                        uploader_version="uploader-1",
                        api_key="",
                        proxy_environment=(
                            ("http_proxy", "http://localhost:notaport"),
                        ),
                    ),
                    endpoints=EndpointSet(
                        True,
                        "datadoghq.com",
                        "https://test.invalid",
                        "https://coverage.invalid",
                        "https://telemetry.invalid",
                    ),
                    resources=LoadedResources(
                        ContextPlan(None),
                        {},
                        None,
                        (),
                        None,
                    ),
                )

    def test_coordinator_passes_cwd_and_launcher_codeowners_fallbacks(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            workspace = root / "workspace"
            invocation_cwd = root / "cwd"
            launcher_directory = root / "launcher"
            for directory in (workspace, invocation_cwd, launcher_directory):
                directory.mkdir()
            launcher_codeowners = launcher_directory / "CODEOWNERS"
            launcher_codeowners.write_text("* @launcher\n", encoding="utf-8")
            captured = []

            def capture_matcher(**kwargs):
                matcher = load_codeowners_matcher(**kwargs)
                captured.append(matcher)
                return matcher

            with mock.patch(
                "uploader_py.coordinator.load_codeowners_matcher",
                side_effect=capture_matcher,
            ):
                report = run_discovered_tasks(
                    discover_file_tasks(()),
                    settings=CoordinatorSettings(
                        workspace=workspace,
                        workers=1,
                        dry_run=True,
                        validate_enrichment=False,
                        expected_enriched_tags=(),
                        gzip_payloads=False,
                        keep_payloads=False,
                        filter_prefix=False,
                        rules_version="rules-1",
                        uploader_version="uploader-1",
                        api_key="",
                        invocation_cwd=invocation_cwd,
                        launcher_directory=launcher_directory,
                    ),
                    endpoints=EndpointSet(
                        True,
                        "datadoghq.com",
                        "https://test",
                        "https://coverage",
                        "https://telemetry",
                    ),
                    resources=LoadedResources(
                        ContextPlan(None),
                        {},
                        None,
                        (),
                        None,
                    ),
                    identifier_factory=lambda: "stable-id",
                )

            self.assertEqual(0, report.exit_code)
            self.assertEqual(1, len(captured))
            self.assertEqual(launcher_codeowners.resolve(), captured[0].source_path)

    def test_api_key_fingerprint_matches_sync_contract_and_warns_once(self) -> None:
        self.assertEqual("c1a2b2aa", api_key_fingerprint("abc"))
        self.assertEqual("43d28057", api_key_fingerprint("a&b"))
        self.assertEqual(
            "match",
            check_api_key_fingerprint(
                {"topt.api_key_fingerprint": api_key_fingerprint("secret")},
                api_key="secret",
                agentless=True,
            ).status,
        )
        self.assertEqual(
            "api_key_fingerprint_mismatch",
            check_api_key_fingerprint(
                {"topt.api_key_fingerprint": api_key_fingerprint("other")},
                api_key="secret",
                agentless=True,
            ).warning_code,
        )
        self.assertEqual(
            "api_key_fingerprint_evp_skipped",
            check_api_key_fingerprint(
                {"topt.api_key_fingerprint": api_key_fingerprint("other")},
                api_key="",
                agentless=False,
            ).warning_code,
        )

    def test_pre_worker_fingerprint_mismatch_is_warning_only_and_redacted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            context = ContextRecord.create(
                "repo",
                {"topt.api_key_fingerprint": api_key_fingerprint("different-key")},
            )
            resources = LoadedResources(
                ContextPlan(context, (context,)),
                dict(context.values),
                None,
                (),
                None,
            )
            stream = StringIO()
            secret = "upload-secret"
            report = run_discovered_tasks(
                discover_file_tasks(()),
                settings=CoordinatorSettings(
                    workspace=root,
                    workers=2,
                    dry_run=True,
                    validate_enrichment=False,
                    expected_enriched_tags=(),
                    gzip_payloads=False,
                    keep_payloads=False,
                    filter_prefix=False,
                    rules_version="rules-1",
                    uploader_version="uploader-1",
                    api_key=secret,
                ),
                endpoints=EndpointSet(
                    True,
                    "datadoghq.com",
                    "https://test",
                    "https://coverage",
                    "https://telemetry",
                ),
                resources=resources,
                logger=configure_logging(debug=True, secrets=(secret,), stream=stream),
                identifier_factory=lambda: "stable-id",
            )

            self.assertEqual(0, report.exit_code)
            self.assertIn(
                "api_key_fingerprint_mismatch",
                report.initialization_warning_codes,
            )
            self.assertIn("DD_API_KEY mismatch", stream.getvalue())
            self.assertNotIn(secret, stream.getvalue())
            self.assertNotIn("different-key", stream.getvalue())

    def test_interrupt_aggregates_completed_results_and_cancelled_files(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "bazel-testlogs" / "pkg" / "test.outputs"
            _write_payload(output, "tests", "one.json", {"events": [{"content": {}}]})
            _write_payload(output, "tests", "two.json", {"events": [{"content": {}}]})
            discovery = discover_file_tasks((ScanRoot(root / "bazel-testlogs"),))
            completed = FileResult(
                task_id=discovery.tasks[0].task_id,
                source_path=discovery.tasks[0].display_path,
                payload_type=discovery.tasks[0].payload_type,
                status=FileStatus.SUCCEEDED,
                requests_planned=1,
            )
            interrupted = WorkerPoolInterrupted(
                WorkerPoolRun((completed,), 2, 1),
                cancelled=1,
            )

            with mock.patch(
                "uploader_py.coordinator.run_file_workers",
                side_effect=interrupted,
            ):
                report = run_discovered_tasks(
                    discovery,
                    settings=CoordinatorSettings(
                        workspace=root,
                        workers=2,
                        dry_run=True,
                        validate_enrichment=False,
                        expected_enriched_tags=(),
                        gzip_payloads=False,
                        keep_payloads=False,
                        filter_prefix=False,
                        rules_version="rules-1",
                        uploader_version="uploader-1",
                        api_key="",
                    ),
                    endpoints=EndpointSet(
                        True,
                        "datadoghq.com",
                        "https://test",
                        "https://coverage",
                        "https://telemetry",
                    ),
                    resources=LoadedResources(ContextPlan(None), None, None, (), None),
                    identifier_factory=lambda: "stable-id",
                )

            stats = report.statistics()
            self.assertEqual(130, report.exit_code)
            self.assertEqual(1, stats["files"]["processed"])
            self.assertEqual(1, stats["files"]["cancelled"])
            self.assertEqual(2, stats["files"]["eligible"])
            self.assertIn(
                "invocation_interrupted",
                report.initialization_warning_codes,
            )
            stream = StringIO()
            emit_report(report, stream=stream)
            self.assertIn("exit_code=130", stream.getvalue())
            self.assertIn("cancelled=1", stream.getvalue())

    def test_invocation_temporary_cleanup_failure_is_warning_only(self) -> None:
        @contextmanager
        def cleanup_failure(*, on_cleanup_error):
            with tempfile.TemporaryDirectory() as raw_root:
                yield Path(raw_root)
                on_cleanup_error("PermissionError")

        with tempfile.TemporaryDirectory() as raw_root, mock.patch(
            "uploader_py.coordinator.invocation_temporary_directory",
            cleanup_failure,
        ):
            root = Path(raw_root)
            report = run_discovered_tasks(
                discover_file_tasks(()),
                settings=CoordinatorSettings(
                    workspace=root,
                    workers=2,
                    dry_run=True,
                    validate_enrichment=False,
                    expected_enriched_tags=(),
                    gzip_payloads=False,
                    keep_payloads=False,
                    filter_prefix=False,
                    rules_version="rules-1",
                    uploader_version="uploader-1",
                    api_key="",
                ),
                endpoints=EndpointSet(
                    True,
                    "datadoghq.com",
                    "https://test",
                    "https://coverage",
                    "https://telemetry",
                ),
                resources=LoadedResources(ContextPlan(None), None, None, (), None),
            )

            self.assertEqual(0, report.exit_code)
            self.assertIn(
                "invocation_temp_cleanup_failed",
                report.initialization_warning_codes,
            )

    def test_workers_one_uploads_all_protocols_through_real_http(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            records: list[dict[str, object]] = []

            def do_POST(self):  # noqa: N802
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                type(self).records.append(
                    {
                        "path": self.path,
                        "content_type": self.headers.get("Content-Type", ""),
                        "body": body,
                    }
                )
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, _format, *_args):
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        try:
            with tempfile.TemporaryDirectory() as raw_root:
                root = Path(raw_root)
                output = root / "bazel-testlogs" / "pkg" / "target" / "test.outputs"
                sources = (
                    _write_payload(
                        output,
                        "tests",
                        "events.json",
                        {"events": [{"content": {"name": "test"}}]},
                    ),
                    _write_payload(
                        output,
                        "coverage",
                        "coverage.json",
                        {"files": []},
                    ),
                    _write_payload(
                        output,
                        "telemetry",
                        "telemetry.json",
                        {
                            "api_version": "v2",
                            "request_type": "app-started",
                            "runtime_id": "runtime-a",
                            "application": {
                                "service_name": "service-a",
                                "language_name": "python",
                            },
                        },
                    ),
                )
                discovery = discover_file_tasks((ScanRoot(root / "bazel-testlogs"),))
                resources = LoadedResources(ContextPlan(None), None, None, (), None)
                base = f"http://127.0.0.1:{server.server_port}"
                settings = CoordinatorSettings(
                    workspace=root,
                    workers=1,
                    dry_run=False,
                    validate_enrichment=False,
                    expected_enriched_tags=(),
                    gzip_payloads=False,
                    keep_payloads=False,
                    filter_prefix=False,
                    rules_version="rules-1",
                    uploader_version="uploader-1",
                    api_key="secret",
                )

                report = run_discovered_tasks(
                    discovery,
                    settings=settings,
                    endpoints=EndpointSet(
                        True,
                        "datadoghq.com",
                        f"{base}/tests",
                        f"{base}/coverage",
                        f"{base}/telemetry",
                    ),
                    resources=resources,
                    transport_factory=lambda: HttpTransport(max_attempts=1),
                    identifier_factory=lambda: "stable-id",
                )

                stats = report.statistics()
                self.assertEqual(0, report.exit_code)
                self.assertEqual(1, stats["concurrency"]["worker_threads"])
                self.assertEqual(1, stats["concurrency"]["peak_active_workers"])
                self.assertEqual(3, stats["files"]["succeeded"])
                self.assertEqual(3, stats["requests"]["attempted"])
                self.assertEqual(
                    ["/coverage", "/telemetry", "/tests"],
                    sorted(record["path"] for record in Handler.records),
                )
                self.assertTrue(
                    any(
                        str(record["content_type"]).startswith("multipart/form-data")
                        for record in Handler.records
                    )
                )
                self.assertTrue(all(not source.exists() for source in sources))
        finally:
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=2)

    def test_real_http_requests_overlap_without_exceeding_worker_bound(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            active = 0
            peak = 0
            calls = 0
            lock = threading.Lock()

            def do_POST(self):  # noqa: N802
                length = int(self.headers.get("Content-Length", "0"))
                self.rfile.read(length)
                with self.lock:
                    type(self).active += 1
                    type(self).peak = max(type(self).peak, type(self).active)
                time.sleep(0.05)
                with self.lock:
                    type(self).active -= 1
                    type(self).calls += 1
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, _format, *_args):
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        try:
            with tempfile.TemporaryDirectory() as raw_root:
                root = Path(raw_root)
                output = root / "bazel-testlogs" / "pkg" / "target" / "test.outputs"
                sources = tuple(
                    _write_payload(
                        output,
                        "tests",
                        f"events-{index}.json",
                        {"events": [{"content": {"id": index}}]},
                    )
                    for index in range(8)
                )
                discovery = discover_file_tasks((ScanRoot(root / "bazel-testlogs"),))
                resources = LoadedResources(ContextPlan(None), None, None, (), None)
                url = f"http://127.0.0.1:{server.server_port}/upload"
                settings = CoordinatorSettings(
                    workspace=root,
                    workers=4,
                    dry_run=False,
                    validate_enrichment=False,
                    expected_enriched_tags=(),
                    gzip_payloads=False,
                    keep_payloads=False,
                    filter_prefix=False,
                    rules_version="rules-1",
                    uploader_version="uploader-1",
                    api_key="secret",
                )

                report = run_discovered_tasks(
                    discovery,
                    settings=settings,
                    endpoints=EndpointSet(True, "datadoghq.com", url, url, url),
                    resources=resources,
                    transport_factory=HttpTransport,
                )

                self.assertEqual(0, report.exit_code)
                self.assertEqual(8, Handler.calls)
                self.assertGreater(Handler.peak, 1)
                self.assertLessEqual(Handler.peak, 4)
                self.assertEqual(4, report.peak_active_workers)
                self.assertTrue(all(not source.exists() for source in sources))
        finally:
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=2)

    def test_three_protocols_run_concurrently_and_share_prebuilt_resources(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "bazel-testlogs" / "pkg" / "target" / "test.outputs"
            test_source = _write_payload(
                output,
                "tests",
                "events.json",
                {
                    "events": [
                        {"content": {"meta": {"test.source.file": "src/a.py"}}}
                    ]
                },
            )
            coverage_source = _write_payload(
                output,
                "coverage",
                "coverage.json",
                {"files": []},
            )
            telemetry_source = _write_payload(
                output,
                "telemetry",
                "telemetry.json",
                {
                    "api_version": "v2",
                    "request_type": "app-started",
                    "runtime_id": "runtime-a",
                    "application": {
                        "service_name": "service-a",
                        "language_name": "python",
                    },
                },
            )
            (root / "CODEOWNERS").write_text("src/*.py @team\n", encoding="utf-8")
            discovery = discover_file_tasks((ScanRoot(root / "bazel-testlogs"),))
            context = ContextRecord.create("repo", {"git.commit.sha": "abc"})
            resources = LoadedResources(
                context_plan=ContextPlan(context, (context,)),
                primary_context=dict(context.values),
                primary_context_path=None,
                telemetry_facts_paths=(),
                schema=None,
            )
            records: list[dict[str, object]] = []
            record_lock = threading.Lock()
            barrier = threading.Barrier(3)
            settings = CoordinatorSettings(
                workspace=root,
                workers=3,
                dry_run=False,
                validate_enrichment=False,
                expected_enriched_tags=(),
                gzip_payloads=False,
                keep_payloads=False,
                filter_prefix=False,
                rules_version="rules-1",
                uploader_version="uploader-1",
                api_key="secret",
            )

            report = run_discovered_tasks(
                discovery,
                settings=settings,
                endpoints=EndpointSet(
                    True,
                    "datadoghq.com",
                    "https://test",
                    "https://coverage",
                    "https://telemetry",
                ),
                resources=resources,
                transport_factory=lambda: _MixedTransport(barrier, records, record_lock),
                identifier_factory=lambda: "stable-id",
            )

            stats = report.statistics()
            self.assertEqual(0, report.exit_code)
            self.assertEqual(3, stats["files"]["succeeded"])
            self.assertEqual(3, stats["concurrency"]["peak_active_workers"])
            self.assertEqual(3, stats["requests"]["attempted"])
            self.assertEqual({"json", "multipart"}, {record["kind"] for record in records})
            enriched_test = next(
                json.loads(record["body"])
                for record in records
                if record["kind"] == "json" and b'"events"' in record["body"]
            )
            self.assertEqual(
                '["@team"]',
                enriched_test["events"][0]["content"]["meta"]["test.codeowners"],
            )
            self.assertFalse(test_source.exists())
            self.assertFalse(coverage_source.exists())
            self.assertFalse(telemetry_source.exists())

            stream = StringIO()
            report_path = root / "report.json"
            emit_report(report, stream=stream, report_json=report_path)
            self.assertIn("[dd-uploader] summary: mode=upload", stream.getvalue())
            self.assertEqual(stats, json.loads(report_path.read_text(encoding="utf-8")))

    def test_dry_run_uses_workers_but_never_calls_transport_or_deletes(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "bazel-testlogs" / "pkg" / "test.outputs"
            source = _write_payload(
                output,
                "tests",
                "events.json",
                {"events": [{"content": {}}]},
            )
            discovery = discover_file_tasks((ScanRoot(root / "bazel-testlogs"),))
            resources = LoadedResources(ContextPlan(None), None, None, (), None)
            calls: list[dict[str, object]] = []
            settings = CoordinatorSettings(
                workspace=root,
                workers=4,
                dry_run=True,
                validate_enrichment=False,
                expected_enriched_tags=(),
                gzip_payloads=True,
                keep_payloads=False,
                filter_prefix=False,
                rules_version="rules-1",
                uploader_version="uploader-1",
                api_key="",
            )

            report = run_discovered_tasks(
                discovery,
                settings=settings,
                endpoints=EndpointSet(
                    True,
                    "datadoghq.com",
                    "https://test",
                    "https://coverage",
                    "https://telemetry",
                ),
                resources=resources,
                transport_factory=lambda: _MixedTransport(None, calls, threading.Lock()),
                identifier_factory=lambda: "stable-id",
            )

            stats = report.statistics()
            self.assertEqual(0, report.exit_code)
            self.assertEqual(1, stats["requests"]["planned"])
            self.assertEqual(0, stats["requests"]["attempted"])
            self.assertEqual([], calls)
            self.assertTrue(source.exists())

    def test_file_failures_are_logged_with_task_and_reason_code(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "bazel-testlogs" / "pkg" / "test.outputs"
            source = output / "payloads" / "tests" / "invalid.json"
            source.parent.mkdir(parents=True)
            source.write_text("[]", encoding="utf-8")
            discovery = discover_file_tasks((ScanRoot(root / "bazel-testlogs"),))
            resources = LoadedResources(ContextPlan(None), None, None, (), None)
            stream = StringIO()
            settings = CoordinatorSettings(
                workspace=root,
                workers=1,
                dry_run=True,
                validate_enrichment=False,
                expected_enriched_tags=(),
                gzip_payloads=False,
                keep_payloads=False,
                filter_prefix=False,
                rules_version="rules-1",
                uploader_version="uploader-1",
                api_key="",
            )

            report = run_discovered_tasks(
                discovery,
                settings=settings,
                endpoints=EndpointSet(
                    True,
                    "datadoghq.com",
                    "https://test",
                    "https://coverage",
                    "https://telemetry",
                ),
                resources=resources,
                logger=configure_logging(debug=True, stream=stream),
                transport_factory=lambda: _MixedTransport(
                    None,
                    [],
                    threading.Lock(),
                ),
                identifier_factory=lambda: "stable-id",
            )

            self.assertEqual(1, report.exit_code)
            logs = stream.getvalue()
            self.assertIn("task=file-000001", logs)
            self.assertIn("failure_code=invalid_test", logs)
            self.assertIn("terminal_status=failed", logs)


if __name__ == "__main__":
    unittest.main()
