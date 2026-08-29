#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Verify expected-target loading and discovered-output selection.

These tests keep unrelated or malformed target data out of worker scheduling.
"""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from uploader_test_support import add_uploader_runtime_to_path

add_uploader_runtime_to_path()

from topt_runtime.runfiles import RunfilesResolver  # noqa: E402
from uploader_py.discovery import ScanRoot, discover_file_tasks  # noqa: E402
from uploader_py.expected_targets import (  # noqa: E402
    ExpectedTargetsError,
    load_expected_targets,
    select_expected_outputs,
)


def _payload(root: Path, target_path: str) -> None:
    destination = root / target_path / "payloads" / "tests" / "events.json"
    destination.parent.mkdir(parents=True)
    destination.write_text('{"events":[{}]}', encoding="utf-8")


class ExpectedTargetsTests(unittest.TestCase):
    def test_schema_v1_file_selects_outputs_and_stamps_tasks(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            testlogs = root / "bazel-testlogs"
            _payload(testlogs, "pkg/a/test.outputs")
            _payload(testlogs, "pkg/b/shard_1_of_2/test.outputs")
            _payload(testlogs, "pkg/unselected/test.outputs")
            target_file = root / "targets.json"
            target_file.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "targets": ["//pkg:a", "//pkg:b"],
                    }
                ),
                encoding="utf-8",
            )
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)
            plan = load_expected_targets(
                static_targets=(),
                expected_targets_file_paths=(str(target_file),),
                resolver=resolver,
            )

            selected = select_expected_outputs(
                discover_file_tasks((ScanRoot(testlogs),)),
                plan,
            )

            self.assertEqual("file", plan.source)
            self.assertEqual(2, len(selected.tasks))
            self.assertEqual(
                {"//pkg:a", "//pkg:b"},
                {task.target_label for task in selected.tasks},
            )

    def test_static_and_dynamic_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            target_file = root / "targets.json"
            target_file.write_text(
                '{"schema_version":1,"targets":["//pkg:b"]}',
                encoding="utf-8",
            )
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)

            with self.assertRaisesRegex(ExpectedTargetsError, "different target sets"):
                load_expected_targets(
                    static_targets=("//pkg:a",),
                    expected_targets_file_paths=(str(target_file),),
                    resolver=resolver,
                )

    def test_output_matching_is_exact_except_for_bazel_attempt_directories(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            testlogs = root / "bazel-testlogs"
            _payload(testlogs, "pkg/foo/test.outputs")
            _payload(testlogs, "pkg/foo/shard_1_of_2/attempt_1/test.outputs")
            _payload(testlogs, "pkg/foo/run_1_of_2/test.outputs")
            _payload(testlogs, "pkg/foo/bar/test.outputs")
            _payload(testlogs, "pkg/foo/not_a_bazel_attempt/test.outputs")
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)
            plan = load_expected_targets(
                static_targets=("//pkg:foo", "//pkg/foo:bar"),
                expected_targets_file_paths=(),
                resolver=resolver,
            )

            selected = select_expected_outputs(
                discover_file_tasks((ScanRoot(testlogs),)),
                plan,
            )

            self.assertEqual(
                {
                    "pkg/foo/test.outputs",
                    "pkg/foo/shard_1_of_2/attempt_1/test.outputs",
                    "pkg/foo/run_1_of_2/test.outputs",
                    "pkg/foo/bar/test.outputs",
                },
                {output.output_key for output in selected.outputs},
            )
            labels_by_output = {
                task.output_key: task.target_label for task in selected.tasks
            }
            self.assertEqual("//pkg:foo", labels_by_output["pkg/foo/test.outputs"])
            self.assertEqual(
                "//pkg:foo",
                labels_by_output["pkg/foo/shard_1_of_2/attempt_1/test.outputs"],
            )
            self.assertEqual(
                "//pkg:foo",
                labels_by_output["pkg/foo/run_1_of_2/test.outputs"],
            )
            self.assertEqual(
                "//pkg/foo:bar",
                labels_by_output["pkg/foo/bar/test.outputs"],
            )
            self.assertNotIn(
                "pkg/foo/not_a_bazel_attempt/test.outputs",
                labels_by_output,
            )

    def test_exact_nested_target_wins_over_attempt_suffix_interpretation(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            testlogs = root / "bazel-testlogs"
            output_key = "pkg/foo/shard_1_of_2/test.outputs"
            _payload(testlogs, output_key)
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)
            plan = load_expected_targets(
                static_targets=("//pkg:foo", "//pkg/foo:shard_1_of_2"),
                expected_targets_file_paths=(),
                resolver=resolver,
            )

            selected = select_expected_outputs(
                discover_file_tasks((ScanRoot(testlogs),)),
                plan,
                allow_missing=True,
            )

            self.assertEqual(1, len(selected.tasks))
            self.assertEqual(output_key, selected.tasks[0].output_key)
            self.assertEqual("//pkg/foo:shard_1_of_2", selected.tasks[0].target_label)

    def test_missing_expected_output_fails_unless_staging_can_supply_it(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            discovery = discover_file_tasks((ScanRoot(root),))
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)
            plan = load_expected_targets(
                static_targets=("//pkg:missing",),
                expected_targets_file_paths=(),
                resolver=resolver,
            )

            with self.assertRaisesRegex(ExpectedTargetsError, "no local test.outputs"):
                select_expected_outputs(discovery, plan)
            allowed = select_expected_outputs(discovery, plan, allow_missing=True)
            self.assertEqual((), allowed.tasks)

    def test_rejects_unexpanded_external_and_unsorted_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)
            for label in ("@repo//pkg:test", "//pkg/...:all", "//pkg"):
                with self.subTest(label=label), self.assertRaises(ExpectedTargetsError):
                    load_expected_targets(
                        static_targets=(label,),
                        expected_targets_file_paths=(),
                        resolver=resolver,
                    )
            target_file = root / "targets.json"
            target_file.write_text(
                '{"schema_version":1,"targets":["//pkg:b","//pkg:a"]}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ExpectedTargetsError, "sorted"):
                load_expected_targets(
                    static_targets=(),
                    expected_targets_file_paths=(str(target_file),),
                    resolver=resolver,
                )


if __name__ == "__main__":
    unittest.main()
