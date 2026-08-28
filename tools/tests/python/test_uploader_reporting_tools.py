#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Final uploader aggregation and reporting tests."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest


def _runfile(rel_path: str) -> Path:
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY", "")
    test_srcdir = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "")
    candidates = []
    if test_srcdir and test_workspace:
        candidates.append(Path(test_srcdir) / test_workspace / rel_path)
    if test_srcdir:
        candidates.append(Path(test_srcdir) / rel_path)
    if workspace:
        candidates.append(Path(workspace) / rel_path)
    for parent in (Path(__file__).resolve().parent, *Path(__file__).resolve().parents):
        if (parent / "MODULE.bazel").exists() or (parent / ".git").exists():
            candidates.append(parent / rel_path)
            break
    for candidate in candidates:
        if candidate.exists():
            return candidate
    manifest_path = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_path and Path(manifest_path).is_file():
        keys = {rel_path, f"{test_workspace}/{rel_path}"}
        with Path(manifest_path).open("r", encoding="utf-8") as handle:
            for line in handle:
                key, separator, value = line.rstrip("\n").partition(" ")
                if separator and key in keys:
                    return Path(value)
    raise FileNotFoundError(f"runfile not found: {rel_path}")


CORE_DIR = _runfile("tools/core/uploader_main.py").parent
if str(CORE_DIR) not in sys.path:
    sys.path.insert(0, str(CORE_DIR))

from uploader_py.models import FileResult, FileStatus, PayloadType  # noqa: E402
from uploader_py.reporting import (  # noqa: E402
    AggregateReport,
    LegacyReportContext,
    write_schema_v1_report,
    write_statistics_json,
)


class ReportingTests(unittest.TestCase):
    def test_one_aggregate_drives_all_source_request_and_split_counters(self) -> None:
        results = (
            FileResult(
                task_id="test-1",
                source_path="test.json",
                payload_type=PayloadType.TEST,
                status=FileStatus.SUCCEEDED,
                events=5,
                chunks_created=2,
                chunks_uploaded=2,
                requests_planned=2,
                requests_attempted=3,
                requests_succeeded=2,
                retries=1,
                source_deleted=True,
                warning_codes=("schema_validation_failed",),
            ),
            FileResult(
                task_id="coverage-1",
                source_path="coverage.json",
                payload_type=PayloadType.COVERAGE,
                status=FileStatus.FAILED,
                requests_planned=1,
                requests_attempted=4,
                requests_failed=1,
                retries=3,
                failure_code="upload_http_error",
            ),
            FileResult(
                task_id="telemetry-1",
                source_path="telemetry.json",
                payload_type=PayloadType.TELEMETRY,
                status=FileStatus.SKIPPED,
            ),
        )
        report = AggregateReport.create(
            dry_run=False,
            exit_code=1,
            configured_workers=4,
            worker_threads=3,
            peak_active_workers=3,
            elapsed_seconds=12.34567,
            discovered_by_type={
                PayloadType.TEST: 2,
                PayloadType.COVERAGE: 2,
                PayloadType.TELEMETRY: 2,
            },
            results=results,
        )

        stats = report.statistics()
        self.assertEqual("partial_failure", stats["result"])
        self.assertEqual(
            {
                "discovered": 6,
                "eligible": 3,
                "processed": 3,
                "succeeded": 1,
                "failed": 1,
                "skipped": 1,
                "cancelled": 0,
                "deleted": 1,
                "retained": 2,
            },
            stats["files"],
        )
        self.assertEqual(1, stats["splitting"]["source_files_split"])
        self.assertEqual(2, stats["splitting"]["chunks_created"])
        self.assertEqual(
            {"planned": 3, "attempted": 7, "succeeded": 2, "failed": 1, "retries": 4},
            stats["requests"],
        )
        self.assertEqual(
            {"succeeded": 1, "failed": 0, "skipped": 0},
            stats["payload_types"]["test"],
        )
        self.assertEqual({"upload_http_error": 1}, stats["failures"])
        self.assertEqual(
            {"schema_validation_failed": 1},
            stats["warnings"],
        )
        lines = report.human_lines()
        self.assertIn("mode=upload result=partial_failure", lines[0])
        self.assertIn("tests=1/0/0", lines[2])
        self.assertIn("planned=3 attempted=7", lines[4])

    def test_dry_run_summary_makes_zero_network_activity_explicit(self) -> None:
        report = AggregateReport.create(
            dry_run=True,
            exit_code=0,
            configured_workers=4,
            worker_threads=1,
            peak_active_workers=1,
            elapsed_seconds=0.5,
            discovered_by_type={PayloadType.TEST: 1},
            results=(
                FileResult(
                    task_id="test-1",
                    source_path="test.json",
                    payload_type=PayloadType.TEST,
                    status=FileStatus.SUCCEEDED,
                    chunks_created=2,
                    requests_planned=2,
                ),
            ),
        )

        stats = report.statistics()
        self.assertEqual("dry-run", stats["mode"])
        self.assertEqual(2, stats["requests"]["planned"])
        self.assertEqual(0, stats["requests"]["attempted"])
        self.assertIn("planned=2 attempted=0", report.human_lines()[4])

    def test_json_writer_uses_the_same_statistics_model(self) -> None:
        report = AggregateReport.create(
            dry_run=False,
            exit_code=0,
            configured_workers=2,
            worker_threads=0,
            peak_active_workers=0,
            elapsed_seconds=0,
            discovered_by_type={},
            results=(),
        )
        with tempfile.TemporaryDirectory() as raw_root:
            output = Path(raw_root) / "nested" / "report.json"
            write_statistics_json(output, report)
            written = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(report.statistics(), written)
        self.assertEqual(0, written["files"]["processed"])
        self.assertEqual("success", written["result"])

    def test_invalid_coordinator_counters_fail_before_rendering(self) -> None:
        with self.assertRaisesRegex(ValueError, "peak_active_workers"):
            AggregateReport.create(
                dry_run=False,
                exit_code=0,
                configured_workers=2,
                worker_threads=1,
                peak_active_workers=2,
                elapsed_seconds=0,
                discovered_by_type={},
                results=(),
            )

    def test_schema_v1_keeps_legacy_telemetry_request_semantics(self) -> None:
        report = AggregateReport.create(
            dry_run=False,
            exit_code=1,
            configured_workers=2,
            worker_threads=1,
            peak_active_workers=1,
            elapsed_seconds=1,
            discovered_by_type={PayloadType.TELEMETRY: 1},
            results=(
                FileResult(
                    task_id="telemetry-1",
                    source_path="telemetry.json",
                    payload_type=PayloadType.TELEMETRY,
                    status=FileStatus.FAILED,
                    requests_planned=2,
                    requests_attempted=5,
                    requests_succeeded=1,
                    requests_failed=1,
                    retries=3,
                    failure_code="upload_http_error",
                ),
            ),
        )
        context = LegacyReportContext(test_outputs_dirs=1)
        public = report.schema_v1_report(context)

        self.assertEqual(1, public["schema_version"])
        self.assertEqual("dd-test-optimization-uploader", public["tool"])
        self.assertEqual(
            {"processed": 1, "failed": 1, "skipped": 0},
            public["payloads"]["telemetry"],
        )
        self.assertEqual(2, public["upload"]["payloads_attempted"])
        self.assertEqual(1, public["upload"]["payloads_uploaded"])
        self.assertEqual(report.statistics()["requests"], public["requests"])

        with tempfile.TemporaryDirectory() as raw_root:
            output = Path(raw_root) / "report.json"
            write_schema_v1_report(output, report, context)
            written = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(public, written)


if __name__ == "__main__":
    unittest.main()
