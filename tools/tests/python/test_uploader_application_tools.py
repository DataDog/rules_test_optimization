#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Exercise the whole uploader lifecycle without backend access.

These tests isolate preflight, cleanup, and reporting regressions from HTTP behavior.
"""

from __future__ import annotations

from io import StringIO
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from uploader_test_support import (
    add_uploader_runtime_to_path,
    resolve_runfile as _runfile,
)

add_uploader_runtime_to_path()

from topt_runtime.runfiles import RunfilesResolver  # noqa: E402
from uploader_py.application import run_uploader  # noqa: E402
from uploader_py.config import parse_uploader_config  # noqa: E402
from uploader_py.endpoints import build_endpoints  # noqa: E402
from uploader_py.freshness import FreshnessError  # noqa: E402
from uploader_py.logging_utils import configure_logging  # noqa: E402
from uploader_py.reporting import AggregateReport  # noqa: E402


def _write_payload(output: Path, kind: str, name: str, body: object) -> Path:
    path = output / "payloads" / kind / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(body), encoding="utf-8")
    return path


def _bep_test_result(
    label: str,
    *,
    attempt: int = 1,
    status: str = "PASSED",
    output: Path | None = None,
) -> dict[str, object]:
    test_action_output = (
        []
        if output is None
        else [{"name": "test.outputs", "uri": output.as_uri()}]
    )
    return {
        "id": {
            "testResult": {
                "label": label,
                "run": 1,
                "shard": 1,
                "attempt": attempt,
            }
        },
        "testResult": {
            "status": status,
            "testActionOutput": test_action_output,
        },
    }


class ApplicationTests(unittest.TestCase):
    def _config(
        self,
        root: Path,
        *,
        dry_run: bool = True,
        fail_on_error: bool = False,
        expected_targets: tuple[str, ...] = (),
        runtime_selection: bool = False,
        allow_cached_payload_uploads: bool = True,
        extra_arguments: tuple[str, ...] = (),
        extra_environment: dict[str, str] | None = None,
    ):
        config_path = root / "uploader-config.json"
        config_path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "quiescent_sec": 0,
                    "max_wait_sec": 0,
                    "fail_on_error": fail_on_error,
                    "expected_targets": expected_targets,
                    "runtime_selection": runtime_selection,
                    "workers": 3,
                    "rules_version": "rules-test",
                    "uploader_version": "uploader-test",
                    "workspace_name": "workspace",
                    "doctor_runtime_path": str(
                        _runfile("tools/core/test_optimization_doctor.py")
                    ),
                }
            ),
            encoding="utf-8",
        )
        environment = {
            "BUILD_WORKSPACE_DIRECTORY": str(root),
            "TESTLOGS_DIR": str(root / "bazel-testlogs"),
        }
        environment.update(extra_environment or {})
        arguments = ["--config", str(config_path)]
        if dry_run:
            arguments.append("--dry-run")
        if allow_cached_payload_uploads:
            arguments.append("--allow-cached-payload-uploads")
        arguments.extend(extra_arguments)
        return parse_uploader_config(
            arguments,
            environ=environment,
            cwd=root,
        )

    def test_dry_run_prepares_all_types_prints_stats_and_writes_schema_v1(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "bazel-testlogs" / "pkg" / "target" / "test.outputs"
            sources = (
                _write_payload(
                    output,
                    "tests",
                    "events.json",
                    {"events": [{"content": {"meta": {"event.id": "1"}}}]},
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
                        "runtime_id": "runtime",
                        "application": {
                            "service_name": "service",
                            "language_name": "python",
                        },
                    },
                ),
            )
            report_path = root / "report.json"
            config = self._config(
                root,
                extra_arguments=(
                    f"--report-json={report_path}",
                    "--validate-enrichment",
                    "--expected-enriched-tag=event.id",
                ),
            )
            stream = StringIO()
            log_stream = StringIO()

            exit_code = run_uploader(
                config,
                resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                endpoints=build_endpoints(config),
                logger=configure_logging(debug=True, stream=log_stream),
                stream=stream,
            )

            self.assertEqual(0, exit_code)
            self.assertTrue(all(source.is_file() for source in sources))
            self.assertIn("files: discovered=3", stream.getvalue())
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(1, report["schema_version"])
            self.assertEqual(3, report["files"]["succeeded"])
            self.assertEqual(3, report["requests"]["planned"])
            self.assertEqual(0, report["requests"]["attempted"])
            self.assertEqual("upload_skipped_dry_run", report["result"]["reason_code"])
            self.assertEqual(
                str(config.artifact_staging_dir),
                report["artifacts"]["staging_dir"],
            )
            self.assertIn("task=file-000001", log_stream.getvalue())
            self.assertIn("freshness filtering disabled", log_stream.getvalue())
            self.assertIn(
                "dry-run validated enriched test payload",
                log_stream.getvalue(),
            )
            self.assertIn("dry-run validated 1 test payloads", log_stream.getvalue())

            normal_log_stream = StringIO()
            exit_code = run_uploader(
                config,
                resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                endpoints=build_endpoints(config),
                logger=configure_logging(debug=False, stream=normal_log_stream),
                stream=StringIO(),
            )

            self.assertEqual(0, exit_code)
            self.assertNotIn(
                "dry-run validated enriched test payload",
                normal_log_stream.getvalue(),
            )
            self.assertIn(
                "dry-run validated 1 test payloads",
                normal_log_stream.getvalue(),
            )

    def test_success_statistics_report_full_invocation_elapsed_time(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "bazel-testlogs" / "pkg" / "target" / "test.outputs"
            _write_payload(
                output,
                "tests",
                "events.json",
                {"events": [{"content": {}}]},
            )
            config = self._config(root)
            stream = StringIO()
            clock = mock.Mock(side_effect=(100.0, 108.0, 110.0, 125.0))

            exit_code = run_uploader(
                config,
                resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                endpoints=build_endpoints(config),
                logger=configure_logging(debug=False, stream=StringIO()),
                stream=stream,
                clock=clock,
            )

            self.assertEqual(0, exit_code)
            self.assertIn("elapsed=25.00s", stream.getvalue())
            self.assertEqual(4, clock.call_count)

    def test_agentless_upload_without_payloads_does_not_require_api_key(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            (root / "bazel-testlogs").mkdir()
            report_path = root / "report.json"
            config = self._config(
                root,
                dry_run=False,
                extra_arguments=(f"--report-json={report_path}",),
            )
            transport_factory = mock.Mock(
                side_effect=AssertionError("transport must not be created")
            )

            exit_code = run_uploader(
                config,
                resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                endpoints=build_endpoints(config),
                logger=configure_logging(debug=False, stream=StringIO()),
                stream=StringIO(),
                transport_factory=transport_factory,
            )

            self.assertEqual(0, exit_code)
            transport_factory.assert_not_called()
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(0, report["files"]["discovered"])
            self.assertEqual(0, report["requests"]["attempted"])

    def test_agentless_upload_with_payload_requires_api_key_before_workers(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "bazel-testlogs" / "pkg" / "target" / "test.outputs"
            _write_payload(
                output,
                "tests",
                "events.json",
                {"events": [{"content": {}}]},
            )
            report_path = root / "report.json"
            config = self._config(
                root,
                dry_run=False,
                extra_arguments=(f"--report-json={report_path}",),
            )
            transport_factory = mock.Mock(
                side_effect=AssertionError("transport must not be created")
            )

            exit_code = run_uploader(
                config,
                resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                endpoints=build_endpoints(config),
                logger=configure_logging(debug=False, stream=StringIO()),
                stream=StringIO(),
                transport_factory=transport_factory,
            )

            self.assertEqual(2, exit_code)
            transport_factory.assert_not_called()
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(1, report["files"]["discovered"])
            self.assertEqual(0, report["files"]["processed"])
            self.assertEqual(0, report["requests"]["attempted"])

    def test_fail_on_error_reports_tests_without_payloads(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            testlogs = root / "bazel-testlogs"
            marker = testlogs / "pkg" / "target" / "test.log"
            marker.parent.mkdir(parents=True)
            marker.write_text("ran", encoding="utf-8")
            report_path = root / "report.json"
            config = self._config(
                root,
                fail_on_error=True,
                extra_arguments=(f"--report-json={report_path}",),
            )

            exit_code = run_uploader(
                config,
                resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                endpoints=build_endpoints(config),
                logger=configure_logging(debug=False, stream=StringIO()),
                stream=StringIO(),
            )

            self.assertEqual(1, exit_code)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual("tests_ran_without_payloads", report["result"]["reason_code"])
            self.assertEqual(0, report["files"]["processed"])

    def test_expected_target_accepts_payload_from_one_of_multiple_attempts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            testlogs = root / "bazel-testlogs"
            attempts = (
                testlogs
                / "pkg"
                / "target"
                / "test_attempts"
                / "attempt_1.outputs"
                / "test.outputs",
                testlogs / "pkg" / "target" / "test.outputs",
            )
            attempts[0].mkdir(parents=True)
            _write_payload(
                attempts[1],
                "tests",
                "events.json",
                {"events": [{"content": {}}]},
            )
            (attempts[1] / "bazel_target_metadata.json").write_text(
                json.dumps({"bazel.target": "//pkg:target"}),
                encoding="utf-8",
            )
            bep = root / "bep.ndjson"
            bep.write_text(
                "\n".join(
                    json.dumps(
                        _bep_test_result(
                            "//pkg:target",
                            attempt=attempt,
                            status="FAILED",
                            output=output,
                        )
                    )
                    for attempt, output in enumerate(attempts, start=1)
                )
                + "\n",
                encoding="utf-8",
            )
            report_path = root / "report.json"
            config = self._config(
                root,
                fail_on_error=True,
                expected_targets=("//pkg:target",),
                allow_cached_payload_uploads=False,
                extra_arguments=(
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    f"--bep-json={bep}",
                    f"--report-json={report_path}",
                ),
            )

            exit_code = run_uploader(
                config,
                resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                endpoints=build_endpoints(config),
                logger=configure_logging(debug=False, stream=StringIO()),
                stream=StringIO(),
            )

            self.assertEqual(0, exit_code)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual("upload_skipped_dry_run", report["result"]["reason_code"])
            self.assertEqual(2, report["bep"]["eligible_outputs"])
            self.assertEqual(1, report["files"]["processed"])

    def test_missing_expected_output_fails_after_valid_payload_is_processed(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "bazel-testlogs" / "pkg" / "valid" / "test.outputs"
            _write_payload(
                output,
                "tests",
                "events.json",
                {"events": [{"content": {}}]},
            )
            (output / "bazel_target_metadata.json").write_text(
                json.dumps({"bazel.target": "//pkg:valid"}),
                encoding="utf-8",
            )
            bep = root / "bep.ndjson"
            events = (
                _bep_test_result("//pkg:valid", output=output),
                _bep_test_result("//pkg:missing", status="TIMEOUT"),
            )
            bep.write_text(
                "\n".join(json.dumps(event) for event in events) + "\n",
                encoding="utf-8",
            )
            report_path = root / "report.json"
            config = self._config(
                root,
                fail_on_error=True,
                expected_targets=("//pkg:valid", "//pkg:missing"),
                allow_cached_payload_uploads=False,
                extra_arguments=(
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    f"--bep-json={bep}",
                    f"--report-json={report_path}",
                ),
            )
            log_stream = StringIO()

            exit_code = run_uploader(
                config,
                resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                endpoints=build_endpoints(config),
                logger=configure_logging(debug=False, stream=log_stream),
                stream=StringIO(),
            )

            self.assertEqual(1, exit_code, log_stream.getvalue())
            self.assertIn(
                "the fresh TestResult did not contain a mappable test.outputs reference",
                log_stream.getvalue(),
            )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(
                "fresh_output_without_payloads",
                report["result"]["reason_code"],
            )
            self.assertEqual(1, report["bep"]["eligible_outputs"])
            self.assertEqual(1, report["bep"]["missing_output_labels"])
            self.assertEqual(1, report["files"]["processed"])
            self.assertEqual(1, report["files"]["succeeded"])
            self.assertEqual(1, report["requests"]["planned"])
            self.assertEqual(0, report["requests"]["attempted"])

    def test_fail_on_error_all_cached_bep_without_testlogs_is_noop(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            bep = _runfile("tools/tests/python/fixtures/bep_cached_local.ndjson")
            report_path = root / "report.json"
            config = self._config(
                root,
                dry_run=False,
                fail_on_error=True,
                expected_targets=("//pkg:target",),
                allow_cached_payload_uploads=False,
                extra_arguments=(
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    f"--bep-json={bep}",
                    f"--report-json={report_path}",
                ),
            )
            transport_factory = mock.Mock(
                side_effect=AssertionError("transport must not be created")
            )
            log_stream = StringIO()

            with mock.patch(
                "uploader_py.application.resolve_local_testlogs_root",
                return_value=None,
            ):
                exit_code = run_uploader(
                    config,
                    resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                    endpoints=build_endpoints(config),
                    logger=configure_logging(debug=False, stream=log_stream),
                    stream=StringIO(),
                    transport_factory=transport_factory,
                )

            self.assertEqual(0, exit_code, log_stream.getvalue())
            transport_factory.assert_not_called()
            self.assertIn(
                "freshness filtering enabled: source=bep",
                log_stream.getvalue(),
            )
            self.assertIn(
                "skipping cached or non-current test output",
                log_stream.getvalue(),
            )
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual("ok", report["result"]["reason_code"])
            self.assertEqual(1, report["bep"]["cached_outputs"])
            self.assertEqual(0, report["files"]["discovered"])
            self.assertEqual(0, report["requests"]["attempted"])

    def test_platform_skipped_target_without_testlogs_is_noop(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            bep = root / "skipped.ndjson"
            bep.write_text(
                json.dumps(
                    {
                        "id": {
                            "targetCompleted": {
                                "label": "//pkg:target",
                                "configuration": {"id": "config"},
                            }
                        },
                        "aborted": {
                            "reason": "SKIPPED",
                            "description": "Target //pkg:target build was skipped.",
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            report_path = root / "report.json"
            config = self._config(
                root,
                dry_run=False,
                fail_on_error=True,
                expected_targets=("//pkg:target",),
                allow_cached_payload_uploads=False,
                extra_arguments=(
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    f"--bep-json={bep}",
                    f"--report-json={report_path}",
                ),
            )
            transport_factory = mock.Mock(
                side_effect=AssertionError("transport must not be created")
            )

            with mock.patch(
                "uploader_py.application.resolve_local_testlogs_root",
                return_value=None,
            ):
                exit_code = run_uploader(
                    config,
                    resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                    endpoints=build_endpoints(config),
                    logger=configure_logging(debug=False, stream=StringIO()),
                    stream=StringIO(),
                    transport_factory=transport_factory,
                )

            self.assertEqual(0, exit_code)
            transport_factory.assert_not_called()
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual("ok", report["result"]["reason_code"])
            self.assertEqual(1, report["bep"]["skipped_targets"])
            self.assertEqual(0, report["files"]["discovered"])
            self.assertEqual(0, report["requests"]["attempted"])

    def test_all_cached_bep_skips_wait_and_stale_test_markers(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            stale_marker = root / "bazel-testlogs" / "pkg" / "old" / "test.log"
            stale_marker.parent.mkdir(parents=True)
            stale_marker.write_text("stale prior invocation", encoding="utf-8")
            bep = _runfile("tools/tests/python/fixtures/bep_cached_local.ndjson")
            report_path = root / "report.json"
            config = self._config(
                root,
                dry_run=False,
                fail_on_error=True,
                expected_targets=("//pkg:target",),
                allow_cached_payload_uploads=False,
                extra_arguments=(
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    f"--bep-json={bep}",
                    f"--report-json={report_path}",
                ),
            )

            with mock.patch(
                "uploader_py.application.wait_for_quiescence",
                side_effect=AssertionError("cached-only plan must not wait"),
            ):
                exit_code = run_uploader(
                    config,
                    resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                    endpoints=build_endpoints(config),
                    logger=configure_logging(debug=False, stream=StringIO()),
                    stream=StringIO(),
                    transport_factory=mock.Mock(
                        side_effect=AssertionError("transport must not be created")
                    ),
                )

            self.assertEqual(0, exit_code)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual("ok", report["result"]["reason_code"])
            self.assertEqual(1, report["bep"]["cached_outputs"])
            self.assertEqual(0, report["files"]["discovered"])
            self.assertEqual(0, report["requests"]["attempted"])

    def test_partial_cached_coverage_does_not_short_circuit_remote_output(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            bep = _runfile(
                "tools/tests/python/fixtures/bep_snake_case_remote_cached.ndjson"
            )
            report_path = root / "report.json"
            config = self._config(
                root,
                dry_run=False,
                fail_on_error=True,
                expected_targets=("//pkg:target", "//pkg:remote_only"),
                allow_cached_payload_uploads=False,
                extra_arguments=(
                    "--freshness-source=bep",
                    "--freshness-mode=optional",
                    f"--bep-json={bep}",
                    f"--report-json={report_path}",
                ),
            )

            with mock.patch(
                "uploader_py.application.resolve_local_testlogs_root",
                return_value=None,
            ):
                exit_code = run_uploader(
                    config,
                    resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                    endpoints=build_endpoints(config),
                    logger=configure_logging(debug=False, stream=StringIO()),
                    stream=StringIO(),
                )

            self.assertEqual(2, exit_code)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(
                "bep_output_remote_only_without_downloader",
                report["result"]["reason_code"],
            )
            self.assertEqual(1, report["bep"]["cached_outputs"])
            self.assertEqual(1, report["bep"]["remote_only_outputs"])
            self.assertEqual(0, report["requests"]["attempted"])

    def test_remote_only_expected_output_fails_with_existing_empty_testlogs(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            (root / "bazel-testlogs").mkdir()
            bep = _runfile(
                "tools/tests/python/fixtures/bep_snake_case_remote_cached.ndjson"
            )
            report_path = root / "report.json"
            config = self._config(
                root,
                dry_run=False,
                fail_on_error=True,
                expected_targets=("//pkg:target", "//pkg:remote_only"),
                allow_cached_payload_uploads=False,
                extra_arguments=(
                    "--freshness-source=bep",
                    "--freshness-mode=optional",
                    f"--bep-json={bep}",
                    f"--report-json={report_path}",
                ),
            )

            exit_code = run_uploader(
                config,
                resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                endpoints=build_endpoints(config),
                logger=configure_logging(debug=False, stream=StringIO()),
                stream=StringIO(),
                transport_factory=mock.Mock(
                    side_effect=AssertionError("transport must not be created")
                ),
            )

            self.assertEqual(2, exit_code)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(
                "bep_output_remote_only_without_downloader",
                report["result"]["reason_code"],
            )
            self.assertEqual(1, report["bep"]["remote_only_outputs"])
            self.assertEqual(0, report["requests"]["attempted"])

    def test_runtime_selection_is_validated_before_discovery(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            config = self._config(root, runtime_selection=True)

            with mock.patch(
                "uploader_py.application.resolve_local_testlogs_root",
                side_effect=AssertionError("discovery must not start"),
            ):
                exit_code = run_uploader(
                    config,
                    resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                    endpoints=build_endpoints(config),
                    logger=configure_logging(debug=False, stream=StringIO()),
                    stream=StringIO(),
                )

            self.assertEqual(2, exit_code)

    def test_interrupted_worker_report_is_printed_and_written(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "bazel-testlogs" / "pkg" / "target" / "test.outputs"
            source = _write_payload(
                output,
                "tests",
                "events.json",
                {"events": [{"content": {}}]},
            )
            report_path = root / "report.json"
            config = self._config(
                root,
                extra_arguments=(f"--report-json={report_path}",),
            )
            stream = StringIO()

            def interrupted_report(discovery, *, settings, **_kwargs):
                report = AggregateReport.create(
                    dry_run=settings.dry_run,
                    exit_code=130,
                    configured_workers=settings.workers,
                    worker_threads=1,
                    peak_active_workers=1,
                    elapsed_seconds=0.1,
                    discovered_by_type=discovery.counts(),
                    results=(),
                    cancelled=len(discovery.tasks),
                    initialization_warning_codes=("invocation_interrupted",),
                )
                return report

            with mock.patch(
                "uploader_py.application.run_discovered_tasks",
                side_effect=interrupted_report,
            ):
                exit_code = run_uploader(
                    config,
                    resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                    endpoints=build_endpoints(config),
                    logger=configure_logging(debug=False, stream=StringIO()),
                    stream=stream,
                )

            self.assertEqual(130, exit_code)
            self.assertTrue(source.exists())
            self.assertIn("exit_code=130", stream.getvalue())
            self.assertIn("cancelled=1", stream.getvalue())
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual("interrupted", report["result"]["reason_code"])
            self.assertEqual(1, report["files"]["cancelled"])

    def test_staging_cleanup_failure_preserves_completed_worker_statistics(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "bazel-testlogs" / "pkg" / "target" / "test.outputs"
            _write_payload(
                output,
                "tests",
                "events.json",
                {"events": [{"content": {}}]},
            )
            report_path = root / "report.json"
            config = self._config(
                root,
                extra_arguments=(f"--report-json={report_path}",),
            )
            from uploader_py import application

            real_prepare = application.prepare_freshness

            def preparation_with_failed_cleanup(*args, **kwargs):
                prepared = real_prepare(*args, **kwargs)
                return mock.Mock(
                    plan=prepared.plan,
                    scan_roots=prepared.scan_roots,
                    staged_roots=prepared.staged_roots,
                    cleanup=mock.Mock(
                        side_effect=FreshnessError("simulated staging cleanup failure")
                    ),
                )

            with mock.patch(
                "uploader_py.application.prepare_freshness",
                side_effect=preparation_with_failed_cleanup,
            ):
                exit_code = run_uploader(
                    config,
                    resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                    endpoints=build_endpoints(config),
                    logger=configure_logging(debug=False, stream=StringIO()),
                    stream=StringIO(),
                )

            self.assertEqual(2, exit_code)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(1, report["files"]["processed"])
            self.assertEqual(1, report["files"]["succeeded"])
            self.assertEqual(1, report["requests"]["planned"])
            self.assertEqual("staging_cleanup_failed", report["result"]["reason_code"])
            self.assertEqual(1, report["warnings"]["staging_cleanup_failed"])

    def test_workspace_lock_is_held_until_final_report_is_emitted(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            (root / "bazel-testlogs").mkdir()
            config = self._config(root)
            events: list[str] = []
            locks = []

            class RecordingLock:
                def __init__(self, workspace: str) -> None:
                    self.workspace = workspace
                    self.acquired = False
                    locks.append(self)

                def acquire(self):
                    self.acquired = True
                    events.append("acquire")
                    return self

                def release(self) -> None:
                    events.append("release")
                    self.acquired = False

            def record_report(*_args, **_kwargs) -> None:
                self.assertTrue(locks[0].acquired)
                events.append("report")

            with mock.patch(
                "uploader_py.application.WorkspaceLock",
                RecordingLock,
            ), mock.patch(
                "uploader_py.application.emit_report",
                side_effect=record_report,
            ):
                exit_code = run_uploader(
                    config,
                    resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                    endpoints=build_endpoints(config),
                    logger=configure_logging(debug=False, stream=StringIO()),
                    stream=StringIO(),
                )

            self.assertEqual(0, exit_code)
            self.assertEqual(config.lock_workspace, locks[0].workspace)
            self.assertEqual(["acquire", "report", "release"], events)

            events.clear()

            def fail_report(*_args, **_kwargs) -> None:
                self.assertTrue(locks[-1].acquired)
                events.append("report")
                raise RuntimeError("report stream failed")

            with mock.patch(
                "uploader_py.application.WorkspaceLock",
                RecordingLock,
            ), mock.patch(
                "uploader_py.application.emit_report",
                side_effect=fail_report,
            ), self.assertRaisesRegex(RuntimeError, "report stream failed"):
                run_uploader(
                    config,
                    resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                    endpoints=build_endpoints(config),
                    logger=configure_logging(debug=False, stream=StringIO()),
                    stream=StringIO(),
                )

            self.assertFalse(locks[-1].acquired)
            self.assertEqual(["acquire", "report", "release"], events)


if __name__ == "__main__":
    unittest.main()
