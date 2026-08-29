#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Verify deterministic testlogs discovery and task creation.

Stable snapshots prevent duplicate ownership and nondeterministic reports.
"""

from __future__ import annotations

import os
from pathlib import Path
import tempfile
import unittest

from uploader_test_support import add_uploader_runtime_to_path

add_uploader_runtime_to_path()

from uploader_py.discovery import (  # noqa: E402
    DiscoveryError,
    ScanRoot,
    discover_file_tasks,
    payload_latest_mtime,
    resolve_local_testlogs_root,
    tests_executed,
    wait_for_quiescence,
)
from uploader_py.models import PayloadType  # noqa: E402


def _payload(output: Path, kind: str, name: str, body: bytes = b"{}") -> Path:
    destination = output / "payloads" / kind / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(body)
    return destination


class DiscoveryTests(unittest.TestCase):
    def test_builds_one_stable_task_per_direct_payload_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root) / "bazel-testlogs"
            output = root / "pkg" / "target" / "test.outputs"
            _payload(output, "tests", "b.json")
            _payload(output, "tests", "a.msgpack")
            _payload(output, "coverage", "coverage.json")
            _payload(output, "telemetry", "telemetry.json")
            nested = output / "payloads" / "tests" / "nested" / "ignored.json"
            nested.parent.mkdir()
            nested.write_text("{}", encoding="utf-8")
            (output / "payloads" / "tests" / "ignored.txt").write_text(
                "ignored", encoding="utf-8"
            )

            discovery = discover_file_tasks((ScanRoot(root),))

            self.assertEqual(1, len(discovery.outputs))
            self.assertEqual(
                ["file-000001", "file-000002", "file-000003", "file-000004"],
                [task.task_id for task in discovery.tasks],
            )
            self.assertEqual(
                [
                    PayloadType.TEST,
                    PayloadType.TEST,
                    PayloadType.COVERAGE,
                    PayloadType.TELEMETRY,
                ],
                [task.payload_type for task in discovery.tasks],
            )
            self.assertEqual(
                "pkg/target/test.outputs/payloads/tests/a.msgpack",
                discovery.tasks[0].display_path,
            )
            self.assertEqual(
                {PayloadType.TEST: 2, PayloadType.COVERAGE: 1, PayloadType.TELEMETRY: 1},
                discovery.counts(),
            )

    def test_staged_selected_output_suppresses_same_key_from_local_root(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            base = Path(raw_root)
            local = base / "local"
            staged = base / "staged"
            key = "pkg/target/test.outputs"
            local_source = _payload(local / key, "tests", "events.json", b"local")
            staged_source = _payload(staged / key, "tests", "events.json", b"staged")

            discovery = discover_file_tasks(
                (ScanRoot(local), ScanRoot(staged, staged=True)),
                staged_output_keys=(key,),
            )

            self.assertEqual(1, len(discovery.tasks))
            self.assertEqual(staged_source.resolve(), discovery.tasks[0].source_path.resolve())
            self.assertNotEqual(local_source.resolve(), discovery.tasks[0].source_path.resolve())

    def test_payload_symlink_is_never_scheduled(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "pkg" / "target" / "test.outputs"
            outside = root / "outside.json"
            outside.write_text('{"events":[]}', encoding="utf-8")
            link = output / "payloads" / "tests" / "linked.json"
            link.parent.mkdir(parents=True)
            try:
                link.symlink_to(outside)
            except OSError as exc:
                self.skipTest(f"symlink creation unavailable: {exc}")

            discovery = discover_file_tasks((ScanRoot(root),))

            self.assertEqual((), discovery.tasks)
            self.assertIn("payload_symlink_skipped", discovery.warning_codes)

    def test_payload_directory_symlink_is_never_scheduled(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "pkg" / "target" / "test.outputs"
            outside = root / "outside" / "tests"
            outside.mkdir(parents=True)
            (outside / "events.json").write_text("{}", encoding="utf-8")
            link = output / "payloads" / "tests"
            link.parent.mkdir(parents=True)
            try:
                link.symlink_to(outside, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"directory symlink creation unavailable: {exc}")

            discovery = discover_file_tasks((ScanRoot(root),))

            self.assertEqual((), discovery.tasks)
            self.assertIn("payload_symlink_skipped", discovery.warning_codes)

    def test_intermediate_payload_symlink_cannot_escape_test_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "pkg" / "target" / "test.outputs"
            outside = root / "outside" / "payloads"
            (outside / "tests").mkdir(parents=True)
            (outside / "tests" / "events.json").write_text("{}", encoding="utf-8")
            output.mkdir(parents=True)
            try:
                (output / "payloads").symlink_to(outside, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"directory symlink creation unavailable: {exc}")

            discovery = discover_file_tasks((ScanRoot(root),))

            self.assertEqual((), discovery.tasks)
            self.assertIn("payload_symlink_skipped", discovery.warning_codes)

    def test_selected_output_never_falls_back_to_stale_local_when_staging_failed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            key = "pkg/target/test.outputs"
            _payload(root / key, "tests", "events.json", b"stale")

            discovery = discover_file_tasks(
                (ScanRoot(root),),
                staged_output_keys=(key,),
            )

            self.assertEqual((), discovery.tasks)
            self.assertIn(
                "selected_staged_output_missing",
                discovery.warning_codes,
            )

    def test_max_depth_matches_find_style_root_relative_depth(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "one" / "two" / "test.outputs"
            _payload(output, "tests", "events.json")

            shallow = discover_file_tasks((ScanRoot(root),), max_depth=2)
            sufficient = discover_file_tasks((ScanRoot(root),), max_depth=3)

            self.assertEqual((), shallow.tasks)
            self.assertIn("max_depth_may_be_too_shallow", shallow.warning_codes)
            self.assertEqual(1, len(sufficient.tasks))

    def test_explicit_testlogs_precedence_and_invalid_override(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            explicit = root / "explicit"
            workspace = root / "workspace"
            cwd = root / "cwd"
            explicit.mkdir()
            (workspace / "bazel-testlogs").mkdir(parents=True)
            (cwd / "bazel-testlogs").mkdir(parents=True)

            self.assertEqual(
                explicit.resolve(),
                resolve_local_testlogs_root(
                    explicit=explicit,
                    workspace=workspace,
                    cwd=cwd,
                ),
            )
            with self.assertRaisesRegex(DiscoveryError, "TESTLOGS_DIR"):
                resolve_local_testlogs_root(
                    explicit=root / "missing",
                    workspace=workspace,
                    cwd=cwd,
                )

    def test_mtime_and_test_execution_markers_are_read_only_observations(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "pkg" / "test.outputs"
            source = _payload(output, "tests", "events.json")
            os.utime(source, (123, 123))
            (output.parent / "test.log").write_text("ran", encoding="utf-8")
            discovery = discover_file_tasks((ScanRoot(root),))

            self.assertEqual(123, payload_latest_mtime(discovery))
            self.assertTrue(tests_executed((ScanRoot(root),)))

    def test_quiescence_refreshes_discovery_and_respects_wait_budget(self) -> None:
        empty = discover_file_tasks(())
        calls = 0
        now = 100.0

        def clock() -> float:
            return now

        def sleep(delay: float) -> None:
            nonlocal now
            now += delay

        def discover():
            nonlocal calls
            calls += 1
            return empty

        result = wait_for_quiescence(
            discover,
            quiescent_seconds=10,
            max_wait_seconds=5,
            poll_seconds=2,
            clock=clock,
            sleeper=sleep,
        )

        self.assertEqual("max_wait", result.reason)
        self.assertEqual(5, result.elapsed_seconds)
        self.assertGreaterEqual(calls, 3)

    def test_quiescence_can_proceed_immediately_for_old_payloads(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "pkg" / "test.outputs"
            source = _payload(output, "tests", "events.json")
            os.utime(source, (10, 10))

            result = wait_for_quiescence(
                lambda: discover_file_tasks((ScanRoot(root),)),
                quiescent_seconds=5,
                max_wait_seconds=30,
                clock=lambda: 100,
                sleeper=lambda _delay: self.fail("old payload should be quiescent"),
            )

            self.assertEqual("quiescent", result.reason)
            self.assertEqual(1, len(result.discovery.tasks))


if __name__ == "__main__":
    unittest.main()
