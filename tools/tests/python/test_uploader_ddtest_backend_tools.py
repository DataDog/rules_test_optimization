# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Exercise the ddtest backend with the pinned ddtest executable.

The Python uploader selects sources and hands test and coverage payloads to
`ddtest instrument bazel upload`; telemetry stays with the Python workers.
"""

from __future__ import annotations

from contextlib import contextmanager
import collections
from io import StringIO
import gzip
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from uploader_test_support import add_uploader_runtime_to_path, resolve_runfile

add_uploader_runtime_to_path()

from uploader_py.coordinator import CoordinatorSettings, run_discovered_tasks  # noqa: E402
from uploader_py.ddtest_backend import (  # noqa: E402
    NativeUploadSettings,
    _command,
    _environment,
    _plan_sources,
)
from uploader_py.discovery import ScanRoot, discover_file_tasks, discover_file_tasks_with_ddtest  # noqa: E402
from uploader_py.endpoints import EndpointSet  # noqa: E402
from uploader_py.enrichment import ContextPlan, ContextRecord  # noqa: E402
from uploader_py.logging_utils import configure_logging  # noqa: E402
from uploader_py.models import FileStatus, FileTask, PayloadType  # noqa: E402
from uploader_py.resources import LoadedResources  # noqa: E402


def _ddtest_executable() -> Path:
    """The pinned executable that the test's runfiles carry."""
    logical = os.environ.get("DDTEST_EXECUTABLE", "")
    if not logical:
        raise unittest.SkipTest("DDTEST_EXECUTABLE is set only under Bazel")
    return resolve_runfile(logical)


_TEST_PAYLOAD = {
    "version": 1,
    "metadata": {"*": {"runtime-id": "process-a", "language": "go", "library_version": "fixture"}},
    "events": [
        {
            "type": "test",
            "version": 2,
            "content": {
                "trace_id": 18446744073709551615,
                "span_id": 9007199254740993,
                "test_session_id": 3,
                "test_module_id": 4,
                "test_suite_id": 5,
                "name": "go.test",
                "service": "original",
                "resource": "fixture",
                "type": "test",
                "start": 1000000000000000000,
                "duration": 1,
                "error": 0,
                "meta": {"test.name": "fixture", "test.status": "pass", "test.source.file": "pkg/thing_test.go"},
            },
        }
    ],
}
_TELEMETRY_PAYLOAD = {
    "api_version": "v2",
    "request_type": "generate-metrics",
    "runtime_id": "process-a",
    "seq_id": 1,
    "application": {"service_name": "original", "language_name": "go", "tracer_version": "1"},
    "payload": {"series": [{"tags": ["provider:bazel"]}]},
}
_CONTEXT = {
    "git.repository_url": "https://example.org/repo",
    "git.commit.sha": "abcdef",
    "ci.workspace_path": "/workspace",
}


def _write(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def _corpus(root: Path) -> Path:
    outputs = root / "bazel-testlogs" / "pkg" / "fixture.topt" / "test.outputs"
    _write(outputs / "payloads" / "tests" / "tests-1.json", _TEST_PAYLOAD)
    _write(outputs / "payloads" / "coverage" / "coverage-1.json", [{"covered": "pkg/thing.go"}])
    _write(outputs / "payloads" / "telemetry" / "telemetry-1.json", _TELEMETRY_PAYLOAD)
    _write(outputs / "bazel_target_metadata.json", {"bazel.target": "//pkg:fixture.topt", "bazel.package": "pkg"})
    (root / "CODEOWNERS").write_text("*.go @team\n", encoding="utf-8")
    return root / "bazel-testlogs"


class _Intake(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), _Handler)
        self.lock = threading.Lock()
        self.requests: list[tuple[str, dict[str, str], bytes]] = []
        self.test_status = 202


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        pass

    def do_POST(self) -> None:
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
        with self.server.lock:
            self.server.requests.append((self.path, dict(self.headers), body))
        self.send_response(self.server.test_status if self.path.endswith("/citestcycle") else 202)
        self.send_header("Content-Length", "0")
        self.end_headers()


@contextmanager
def _intake():
    server = _Intake()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()


def _settings(root: Path, backend: str, executable: Path | None, **overrides) -> CoordinatorSettings:
    values = dict(
        workspace=root,
        workers=2,
        dry_run=False,
        validate_enrichment=True,
        expected_enriched_tags=("git.commit.sha", "bazel.target"),
        gzip_payloads=True,
        keep_payloads=False,
        filter_prefix=False,
        rules_version="rules-1",
        uploader_version="uploader-1",
        api_key="local-test",
        codeowners_file=root / "CODEOWNERS",
        uploader_backend=backend,
        ddtest_executable=executable,
    )
    values.update(overrides)
    return CoordinatorSettings(**values)


def _endpoints(port: int) -> EndpointSet:
    base = f"http://127.0.0.1:{port}"
    return EndpointSet(True, "datadoghq.com", f"{base}/api/v2/citestcycle",
                       f"{base}/api/v2/citestcov", f"{base}/api/v2/apmtelemetry")


def _resources() -> LoadedResources:
    context = ContextRecord.create("repo", _CONTEXT)
    return LoadedResources(ContextPlan(context, (context,)), dict(_CONTEXT), None, (), None)


def _test_events(requests) -> collections.Counter:
    """Each received test event with the envelope metadata it inherits."""
    events: collections.Counter = collections.Counter()
    for path, _headers, body in requests:
        if not path.endswith("/citestcycle"):
            continue
        document = json.loads(body)
        scopes = document["metadata"]
        for event in document["events"]:
            content = event["content"]
            content["meta"] = scopes.get("*", {}) | content.get("meta", {}) | scopes.get(event["type"], {})
            events[hashlib.sha256(json.dumps(event, sort_keys=True).encode()).hexdigest()] += 1
    return events


class DdtestBackendTests(unittest.TestCase):
    def run_corpus(self, root: Path, backend: str, executable: Path | None, server: _Intake, **overrides):
        with server.lock:
            server.requests.clear()
        report = run_discovered_tasks(
            discover_file_tasks((ScanRoot(_corpus(root)),)),
            settings=_settings(root, backend, executable, **overrides),
            endpoints=_endpoints(server.server_port),
            resources=_resources(),
            identifier_factory=lambda: "stable-runtime",
        )
        with server.lock:
            return report, list(server.requests)

    def test_ddtest_sends_tests_and_coverage_and_python_sends_telemetry(self) -> None:
        executable = _ddtest_executable()
        with tempfile.TemporaryDirectory() as raw, _intake() as server:
            root = Path(raw)
            report, requests = self.run_corpus(root, "ddtest", executable, server)

            self.assertEqual(0, report.exit_code, report.results)
            self.assertNotIn("ddtest_backend_unavailable", report.initialization_warning_codes)
            native_workers = report.statistics()["concurrency"]["native_workers"]
            self.assertGreaterEqual(native_workers, 1)
            self.assertIn(f" native_workers={native_workers} ", report.human_lines()[0])
            by_type = {result.payload_type: result for result in report.results}
            self.assertEqual({PayloadType.TEST, PayloadType.COVERAGE, PayloadType.TELEMETRY}, set(by_type))
            for result in report.results:
                self.assertEqual(FileStatus.SUCCEEDED, result.status, result)
                self.assertTrue(result.source_deleted, result)
            self.assertEqual(1, by_type[PayloadType.TEST].events)
            self.assertEqual(1, by_type[PayloadType.TEST].test_events)
            paths = sorted(path for path, _headers, _body in requests)
            self.assertEqual(["/api/v2/apmtelemetry", "/api/v2/citestcov", "/api/v2/citestcycle"], paths)
            test_body = json.loads(next(body for path, _h, body in requests if path.endswith("/citestcycle")))
            meta = test_body["metadata"]["*"] | test_body["events"][0]["content"]["meta"]
            self.assertEqual("abcdef", meta["git.commit.sha"])
            self.assertEqual("//pkg:fixture.topt", meta["bazel.target"])
            self.assertEqual("@team", meta["test.codeowners"].strip('[]"'))

    def test_a_failed_ddtest_batch_records_every_source_as_attempted(self) -> None:
        # Freshness accepts a failed test payload as delivery evidence only if
        # a request carried it; every source of a failed batch must show one.
        executable = _ddtest_executable()
        with tempfile.TemporaryDirectory() as raw, _intake() as server:
            root = Path(raw)
            testlogs = _corpus(root)
            for name in ("second", "third"):
                outputs = testlogs / "pkg" / f"{name}.topt" / "test.outputs"
                _write(outputs / "payloads" / "tests" / "tests-1.json", _TEST_PAYLOAD)
                _write(outputs / "bazel_target_metadata.json", {"bazel.target": f"//pkg:{name}.topt", "bazel.package": "pkg"})
            server.test_status = 403
            report = run_discovered_tasks(
                discover_file_tasks((ScanRoot(testlogs),)),
                settings=_settings(root, "ddtest", executable, batch_test_payloads=True),
                endpoints=_endpoints(server.server_port),
                resources=_resources(),
                identifier_factory=lambda: "stable-runtime",
            )
            with server.lock:
                test_posts = sum(path.endswith("/citestcycle") for path, _headers, _body in server.requests)

            tests = [result for result in report.results if result.payload_type is PayloadType.TEST]
            self.assertEqual(3, len(tests))
            self.assertEqual(1, test_posts)
            for result in tests:
                self.assertEqual(FileStatus.FAILED, result.status, result)
                self.assertEqual(1, result.requests_attempted, result)
                self.assertEqual(1, len(result.request_ids), result)
            batch = report.statistics()["batching"]
            self.assertEqual(1, batch["shared_requests"])
            self.assertEqual({result.task_id for result in tests},
                             set(next(iter(batch["request_sources"].values()))))
            # The shared request counts once, beside the coverage and telemetry requests.
            self.assertEqual(3, report.statistics()["requests"]["attempted"])

    def test_ddtest_and_python_send_the_same_test_events(self) -> None:
        executable = _ddtest_executable()
        received = {}
        for backend in ("python", "ddtest"):
            with tempfile.TemporaryDirectory() as raw, _intake() as server:
                report, requests = self.run_corpus(Path(raw), backend, executable, server)
                self.assertEqual(0, report.exit_code, report.results)
                received[backend] = _test_events(requests)
        self.assertEqual(1, sum(received["python"].values()))
        self.assertEqual(received["python"], received["ddtest"])

    def test_ddtest_reads_sidecars_and_selects_contexts_as_python_does(self) -> None:
        # ddtest reads each target's sidecar and selects its context itself;
        # its warnings, results and events must match Python's enrichment.
        executable = _ddtest_executable()
        one = ContextRecord.create("one", _CONTEXT)
        two = ContextRecord.create("two", _CONTEXT | {"git.commit.sha": "fedcba"})
        resources = LoadedResources(ContextPlan(one, (one, two)), dict(_CONTEXT), None, (), None)
        sidecars = {
            "one": '{"bazel.target": "//pkg:one", "bazel.package": "pkg", '
                   '"bazel.test_optimization.repo_name": "one", "shard": 1.50, "big": 1e16}',
            "two": '﻿{"bazel.target": "//pkg:two", "bazel.package": "pkg", '
                   '"bazel.test_optimization.repo_name": "two"}',
            "unknown": '{"bazel.target": "//pkg:unknown", "bazel.test_optimization.repo_name": "three"}',
            "unnamed": '{"bazel.target": "//pkg:unnamed", "bazel.package": "pkg"}',
            "invalid": '{"bazel.target": ',
            "array": '[]',
            "missing": None,
            "linked": None,
        }
        outcomes = {}
        events = {}
        for backend in ("python", "ddtest"):
            with tempfile.TemporaryDirectory() as raw, _intake() as server:
                root = Path(raw)
                testlogs = root / "bazel-testlogs"
                for name, sidecar in sidecars.items():
                    outputs = testlogs / "pkg" / f"{name}.topt" / "test.outputs"
                    _write(outputs / "payloads" / "tests" / "tests-1.json", _TEST_PAYLOAD)
                    if sidecar is not None:
                        (outputs / "bazel_target_metadata.json").write_text(sidecar, encoding="utf-8")
                linked = testlogs / "pkg" / "linked.topt" / "test.outputs" / "bazel_target_metadata.json"
                try:
                    linked.symlink_to(testlogs / "pkg" / "one.topt" / "test.outputs" / "bazel_target_metadata.json")
                except OSError as exc:
                    self.skipTest(f"symlinks unavailable: {exc}")
                (root / "CODEOWNERS").write_text("*.go @team\n", encoding="utf-8")
                report = run_discovered_tasks(
                    discover_file_tasks((ScanRoot(testlogs),)),
                    settings=_settings(root, backend, executable, expected_enriched_tags=("git.commit.sha",)),
                    endpoints=_endpoints(server.server_port),
                    resources=resources,
                    identifier_factory=lambda: "stable-runtime",
                )
                with server.lock:
                    events[backend] = _test_events(server.requests)
                outcomes[backend] = {result.source_path: (result.status, result.warning_codes, result.failure_code)
                                     for result in report.results}
        warnings = {path.split("/")[1]: outcome[1] for path, outcome in outcomes["python"].items()}
        self.assertEqual(("context_repo_not_found",), warnings["unknown.topt"][:1])
        self.assertEqual(("context_repo_metadata_missing",), warnings["unnamed.topt"][:1])
        self.assertEqual(("bazel_metadata_invalid", "context_repo_metadata_missing"), warnings["invalid.topt"][:2])
        self.assertEqual(("bazel_metadata_unsafe", "context_repo_metadata_missing"), warnings["linked.topt"][:2])
        self.assertEqual(outcomes["python"], outcomes["ddtest"])
        # Only the two targets whose repository has a context are sent.
        self.assertEqual(2, sum(events["python"].values()))
        self.assertEqual(events["python"], events["ddtest"])

    def test_dry_run_keeps_sources_and_sends_nothing(self) -> None:
        executable = _ddtest_executable()
        with tempfile.TemporaryDirectory() as raw, _intake() as server:
            root = Path(raw)
            report, requests = self.run_corpus(root, "ddtest", executable, server, dry_run=True)
            self.assertEqual(0, report.exit_code, report.results)
            self.assertEqual([], [path for path, _h, _b in requests if not path.endswith("/apmtelemetry")])
            self.assertTrue(all(not result.source_deleted for result in report.results))
            self.assertTrue((root / "bazel-testlogs/pkg/fixture.topt/test.outputs/payloads/tests/tests-1.json").exists())

    def test_a_missing_executable_falls_back_to_python_with_a_warning(self) -> None:
        with tempfile.TemporaryDirectory() as raw, _intake() as server:
            report, requests = self.run_corpus(Path(raw), "ddtest", None, server)
            self.assertEqual(0, report.exit_code, report.results)
            self.assertIn("ddtest_backend_unavailable", report.initialization_warning_codes)
            self.assertEqual(0, report.statistics()["concurrency"]["native_workers"])
            self.assertEqual(3, len(requests))

    def test_a_run_without_report_fails_its_sources_and_keeps_them(self) -> None:
        # The interpreter accepts none of ddtest's arguments and writes no report.
        with tempfile.TemporaryDirectory() as raw, _intake() as server:
            root = Path(raw)
            report, _requests = self.run_corpus(root, "ddtest", Path(sys.executable), server)
            self.assertEqual(1, report.exit_code)
            failed = [result for result in report.results if result.status is FileStatus.FAILED]
            self.assertEqual({PayloadType.TEST, PayloadType.COVERAGE}, {result.payload_type for result in failed})
            self.assertTrue(all(result.failure_code == "ddtest_upload_failed" for result in failed))
            self.assertTrue((root / "bazel-testlogs/pkg/fixture.topt/test.outputs/payloads/tests/tests-1.json").exists())

    def test_source_warnings_reach_the_log(self) -> None:
        # With two contexts, a sidecar that names no repository selects none.
        executable = _ddtest_executable()
        first, second = ContextRecord.create("one", _CONTEXT), ContextRecord.create("two", _CONTEXT)
        stream = StringIO()
        with tempfile.TemporaryDirectory() as raw, _intake() as server:
            root = Path(raw)
            report = run_discovered_tasks(
                discover_file_tasks((ScanRoot(_corpus(root)),)),
                settings=_settings(root, "ddtest", executable, validate_enrichment=False),
                endpoints=_endpoints(server.server_port),
                resources=LoadedResources(ContextPlan(first, (first, second)), dict(_CONTEXT), None, (), None),
                logger=configure_logging(debug=False, stream=stream),
                identifier_factory=lambda: "stable-runtime",
            )
        test = next(result for result in report.results if result.payload_type is PayloadType.TEST)
        self.assertIn("context_repo_metadata_missing", test.warning_codes)
        self.assertIn("warning_code=context_repo_metadata_missing", stream.getvalue())

    def test_prefix_filter_skips_before_ddtest(self) -> None:
        executable = _ddtest_executable()
        with tempfile.TemporaryDirectory() as raw, _intake() as server:
            report, requests = self.run_corpus(Path(raw), "ddtest", executable, server, filter_prefix=True)
            skipped = {result.payload_type for result in report.results if result.status is FileStatus.SKIPPED}
            self.assertEqual({PayloadType.TEST, PayloadType.COVERAGE}, skipped)
            self.assertTrue(all("prefix_filter" in result.warning_codes for result in report.results
                                if result.status is FileStatus.SKIPPED))
            self.assertEqual(["/api/v2/apmtelemetry"], [path for path, _h, _b in requests])


class DdtestDiscoveryTests(unittest.TestCase):
    def test_ddtest_discovers_what_python_discovers(self) -> None:
        executable = _ddtest_executable()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw).resolve()
            local, staged, outside = root / "testlogs", root / "staged", root / "outside"
            outside.mkdir()
            (outside / "elsewhere.json").write_text("{}", encoding="utf-8")
            for name in ("a.json", "B.JSON", "c.json.gz", ".json", "x."):
                _write(local / "pkg" / "t" / "test.outputs" / "payloads" / "tests" / name, {})
            _write(local / "pkg" / "t" / "test.outputs" / "payloads" / "coverage" / "c.msgpack", {})
            _write(local / "pkg" / "t" / "test.outputs" / "bazel_target_metadata.json", {})
            _write(local / "pkg" / "t" / "test_attempts" / "attempt_1.outputs" / "payloads" / "tests" / "r.json", {})
            _write(local / "pkg" / "inner" / "test.outputs" / "pkg" / "test.outputs" / "payloads" / "tests" / "n.json", {})
            _write(local / "pkg" / "s" / "test.outputs" / "payloads" / "tests" / "local.json", {})
            _write(staged / "pkg" / "s" / "test.outputs" / "payloads" / "tests" / "staged.json", {})
            _write(local / "pkg" / "stale" / "test.outputs" / "payloads" / "tests" / "stale.json", {})
            (local / "pkg" / "l" / "test.outputs" / "payloads").mkdir(parents=True)
            try:
                (local / "pkg" / "l" / "test.outputs" / "payloads" / "tests").symlink_to(outside, target_is_directory=True)
                (local / "pkg" / "t" / "test.outputs" / "payloads" / "tests" / "link.json").symlink_to(outside / "elsewhere.json")
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            roots = (ScanRoot(staged, staged=True), ScanRoot(local))
            keys = ("pkg/s/test.outputs", "pkg/stale/test.outputs")

            expected = discover_file_tasks(roots, staged_output_keys=keys)
            actual = discover_file_tasks_with_ddtest(executable, roots, staged_output_keys=keys)

            self.assertEqual(expected, actual)
            self.assertIn("payload_symlink_skipped", actual.warning_codes)
            self.assertIn("selected_staged_output_missing", actual.warning_codes)


class DdtestInvocationTests(unittest.TestCase):
    def settings(self, **overrides) -> NativeUploadSettings:
        values = dict(
            executable=Path("ddtest"), rules_version="rules-1", api_key="key", dry_run=False,
            keep_payloads=False, gzip_payloads=True, batch_test_payloads=True, filter_prefix=False,
            validate_enrichment=True, expected_enriched_tags=("git.commit.sha",), workers=None,
            codeowners_file=None,
        )
        values.update(overrides)
        return NativeUploadSettings(**values)

    def test_delivery_comes_from_the_resolved_endpoints(self) -> None:
        base = {"DD_SITE": "stale", "DD_TEST_OPTIMIZATION_AGENT_URL": "http://stale", "PATH": "/bin"}
        cases = {
            "agentless": (EndpointSet(True, "datadoghq.eu", "https://citestcycle-intake.datadoghq.eu/api/v2/citestcycle", "", ""),
                          {"DD_SITE": "datadoghq.eu"}),
            "agentless override": (EndpointSet(True, "datadoghq.com", "http://127.0.0.1:1/api/v2/citestcycle", "", ""),
                                   {"DD_TEST_OPTIMIZATION_AGENTLESS_URL": "http://127.0.0.1:1"}),
            "EVP": (EndpointSet(False, "datadoghq.com", "http://agent:8126/evp_proxy/v2/api/v2/citestcycle", "", ""),
                    {"DD_TEST_OPTIMIZATION_AGENT_URL": "http://agent:8126"}),
        }
        for name, (endpoints, want) in cases.items():
            with self.subTest(name):
                environment = _environment(base, self.settings(), endpoints)
                delivery = {key: environment[key] for key in
                            ("DD_SITE", "DD_TEST_OPTIMIZATION_AGENT_URL", "DD_TEST_OPTIMIZATION_AGENTLESS_URL")
                            if key in environment}
                self.assertEqual(want, delivery)
                self.assertEqual("key", environment["DD_API_KEY"])
                self.assertEqual("/bin", environment["PATH"])

    def test_workers_pass_only_when_set(self) -> None:
        plan, root, report = Path("plan.json"), Path("root"), Path("report.json")
        self.assertNotIn("--workers", _command(self.settings(), plan, root, report))
        command = _command(self.settings(workers=3, dry_run=True), plan, root, report)
        self.assertEqual("3", command[command.index("--workers") + 1])
        self.assertIn("--dry-run", command)
        self.assertIn("--batch-test-payloads=true", command)
        self.assertEqual("git.commit.sha", command[command.index("--expected-enriched-tag") + 1])

    def test_plan_paths_are_real_below_a_linked_testlogs_root(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw).resolve()
            real = root / "execroot" / "testlogs"
            output = real / "pkg" / "fixture.topt" / "test.outputs"
            (output / "payloads" / "tests").mkdir(parents=True)
            (output / "payloads" / "coverage").mkdir(parents=True)
            linked = root / "bazel-testlogs"
            try:
                linked.symlink_to(real, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            linked_output = linked / "pkg" / "fixture.topt" / "test.outputs"
            tasks = (
                FileTask("file-1", linked_output / "payloads/tests/a.json", "a", PayloadType.TEST, linked_output),
                FileTask("file-2", linked_output / "payloads/coverage/b.json", "b", PayloadType.COVERAGE, linked_output),
                FileTask("file-3", linked_output / "payloads/coverage/c.json", "c", PayloadType.COVERAGE),
            )
            context = ContextRecord.create("repo", _CONTEXT)
            sources, _contexts, _selection, _warnings = _plan_sources(tasks, ContextPlan(context, (context,)))
            self.assertEqual(
                [str(output / "payloads/tests/a.json"), str(output / "payloads/coverage/b.json"),
                 str(output / "payloads/coverage/c.json")],
                [source["path"] for source in sources],
            )


if __name__ == "__main__":
    unittest.main()
