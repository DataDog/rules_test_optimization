#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Verify freshness selection, BEP staging, and doctor-runtime reuse.

This boundary prevents stale outputs from being authorized or staging from leaking.
"""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile

from uploader_test_support import (
    add_uploader_runtime_to_path,
    resolve_runfile as _runfile,
)

add_uploader_runtime_to_path()

from topt_runtime.runfiles import RunfilesResolver  # noqa: E402
from uploader_py.config import parse_uploader_config  # noqa: E402
from uploader_py.discovery import (  # noqa: E402
    DiscoveryResult,
    ScanRoot,
    discover_file_tasks,
)
from uploader_py.expected_targets import (  # noqa: E402
    ExpectedTargetsPlan,
    select_expected_outputs,
)
from uploader_py.freshness import (  # noqa: E402
    FreshnessError,
    FreshnessPlan,
    RemoteOutput,
    filter_discovery_for_freshness,
    prepare_freshness,
    validate_fresh_outputs_accounted,
)
from uploader_py.models import FileResult, FileStatus, PayloadType  # noqa: E402


def _payload(output: Path) -> None:
    source = output / "payloads" / "tests" / "events.json"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_text('{"events":[{"content":{}}]}', encoding="utf-8")


def _metadata(output: Path, label: str) -> None:
    (output / "bazel_target_metadata.json").write_text(
        json.dumps({"bazel.target": label}),
        encoding="utf-8",
    )


class FreshnessTests(unittest.TestCase):
    def test_optional_missing_bep_falls_back_to_local_discovery(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            testlogs = root / "bazel-testlogs"
            testlogs.mkdir()
            config = self._config(
                root,
                "--freshness-source=bep",
                "--freshness-mode=optional",
                "--bep-json=missing.ndjson",
            )

            prepared = prepare_freshness(
                config,
                resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                local_testlogs_root=testlogs,
            )

            self.assertEqual("none", prepared.plan.selected_source)
            self.assertFalse(prepared.plan.eligibility_enabled)
            self.assertIn("bep_freshness_unavailable", prepared.plan.warning_codes)
            self.assertEqual((ScanRoot(testlogs),), prepared.scan_roots)

    def test_remote_only_expected_output_fails_after_other_results(self) -> None:
        plan = FreshnessPlan(
            selected_source="bep",
            eligibility_enabled=True,
            remote_only_outputs=(
                RemoteOutput("//pkg:remote", "pkg/remote/test.outputs", "remote"),
            ),
        )

        with self.assertRaisesRegex(FreshnessError, "remote-only"):
            validate_fresh_outputs_accounted(
                plan,
                DiscoveryResult(outputs=(), tasks=(), discovered_by_type={}),
                (),
                expected_targets=("//pkg:remote",),
                fail_on_error=True,
            )

    def _config(
        self,
        root: Path,
        *arguments: str,
        environment: dict[str, str] | None = None,
    ):
        config_path = root / "uploader-config.json"
        config_path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "workspace_name": "workspace",
                    "doctor_runtime_path": str(
                        _runfile("tools/core/test_optimization_doctor.py")
                    ),
                    "doctor_runtime_short_path": (
                        "tools/core/test_optimization_doctor.py"
                    ),
                }
            ),
            encoding="utf-8",
        )
        values = ["--config", str(config_path), "--dry-run", *arguments]
        return parse_uploader_config(
            values,
            environ={} if environment is None else environment,
            cwd=root,
        )

    def test_execution_log_selects_only_fresh_output_and_stamps_label(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            testlogs = root / "bazel-testlogs"
            fresh = testlogs / "pkg" / "fresh" / "test.outputs"
            cached = testlogs / "pkg" / "cached" / "test.outputs"
            for output, label in (
                (fresh, "//pkg:fresh"),
                (cached, "//pkg:cached"),
            ):
                _payload(output)
                _metadata(output, label)
            execution_log = root / "execution.ndjson"
            execution_log.write_text(
                json.dumps(
                    {
                        "mnemonic": "TestRunner",
                        "cacheHit": False,
                        "targetLabel": "//pkg:fresh",
                        "listedOutputs": [
                            "bazel-out/bin/testlogs/pkg/fresh/test.outputs/test.log"
                        ],
                    }
                )
                + "\n"
                + json.dumps(
                    {
                        "mnemonic": "TestRunner",
                        "cacheHit": True,
                        "targetLabel": "//pkg:cached",
                        "listedOutputs": [
                            "bazel-out/bin/testlogs/pkg/cached/test.outputs/test.log"
                        ],
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            config = self._config(
                root,
                "--freshness-source=execution_log",
                "--freshness-mode=required",
                f"--execution-log-json={execution_log}",
            )
            resolver = RunfilesResolver.from_environment(cwd=root, environ={})

            with mock.patch.object(
                Path,
                "read_text",
                side_effect=AssertionError("execution logs must be streamed"),
            ):
                prepared = prepare_freshness(
                    config,
                    resolver=resolver,
                    local_testlogs_root=testlogs,
                )
            discovery = discover_file_tasks(prepared.scan_roots)
            filtered = filter_discovery_for_freshness(
                discovery,
                prepared.plan,
                freshness_mode=config.freshness_mode,
            )

            self.assertEqual("execution_log", prepared.plan.selected_source)
            self.assertEqual(1, len(filtered.discovery.tasks))
            self.assertEqual("//pkg:fresh", filtered.discovery.tasks[0].target_label)
            self.assertEqual(("pkg/cached/test.outputs",), filtered.skipped_outputs)

    def test_reuses_doctor_bep_parser_and_all_cached_target_is_noop(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            testlogs = root / "bazel-testlogs"
            output = testlogs / "pkg" / "target" / "test.outputs"
            _payload(output)
            _metadata(output, "//pkg:target")
            bep = _runfile("tools/tests/python/fixtures/bep_cached_local.ndjson")
            config = self._config(
                root,
                "--freshness-source=bep",
                "--freshness-mode=required",
                f"--bep-json={bep}",
            )
            resolver = RunfilesResolver.from_environment(cwd=root, environ={})
            prepared = prepare_freshness(
                config,
                resolver=resolver,
                local_testlogs_root=testlogs,
                expected_targets=("//pkg:target",),
            )
            discovery = select_expected_outputs(
                discover_file_tasks(prepared.scan_roots),
                ExpectedTargetsPlan(("//pkg:target",), "static"),
                allow_missing=True,
            )
            filtered = filter_discovery_for_freshness(
                discovery,
                prepared.plan,
                freshness_mode=config.freshness_mode,
            )

            self.assertEqual(
                frozenset({("//pkg:target", "pkg/target/test.outputs")}),
                prepared.plan.cached_outputs,
            )
            self.assertEqual((), filtered.discovery.tasks)
            prepared.cleanup()

    def test_required_bep_rejects_output_without_target_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "pkg" / "target" / "test.outputs"
            _payload(output)
            discovery = discover_file_tasks((ScanRoot(root),))
            plan = FreshnessPlan(
                selected_source="bep",
                eligibility_enabled=True,
                eligible_outputs=frozenset(
                    {("//pkg:target", "pkg/target/test.outputs")}
                ),
            )

            with self.assertRaisesRegex(FreshnessError, "metadata is missing"):
                filter_discovery_for_freshness(
                    discovery,
                    plan,
                    freshness_mode="required",
                )

    def test_required_bep_ignores_empty_output_without_target_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            control_output = root / "pkg" / "control" / "test.outputs"
            control_output.mkdir(parents=True)
            payload_output = root / "pkg" / "target" / "test.outputs"
            _payload(payload_output)
            _metadata(payload_output, "//pkg:target")
            discovery = discover_file_tasks((ScanRoot(root),))
            plan = FreshnessPlan(
                selected_source="bep",
                eligibility_enabled=True,
                eligible_outputs=frozenset(
                    {("//pkg:target", "pkg/target/test.outputs")}
                ),
            )

            filtered = filter_discovery_for_freshness(
                discovery,
                plan,
                freshness_mode="required",
            )

            self.assertEqual(1, len(filtered.discovery.outputs))
            self.assertEqual(1, len(filtered.discovery.tasks))
            self.assertEqual("//pkg:target", filtered.discovery.tasks[0].target_label)
            self.assertEqual((), filtered.skipped_outputs)

    def test_freshness_does_not_follow_symlinked_target_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            output = root / "pkg" / "target" / "test.outputs"
            _payload(output)
            outside = root / "outside.json"
            outside.write_text('{"bazel.target":"//pkg:target"}', encoding="utf-8")
            try:
                (output / "bazel_target_metadata.json").symlink_to(outside)
            except OSError as exc:
                self.skipTest(f"symlinks are unavailable: {exc}")
            discovery = discover_file_tasks((ScanRoot(root),))
            plan = FreshnessPlan(
                selected_source="bep",
                eligibility_enabled=True,
                eligible_outputs=frozenset(
                    {("//pkg:target", "pkg/target/test.outputs")}
                ),
            )

            with self.assertRaisesRegex(FreshnessError, "metadata is missing"):
                filter_discovery_for_freshness(
                    discovery,
                    plan,
                    freshness_mode="required",
                )

    def test_local_outputs_zip_is_staged_discovered_and_cleaned(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            carrier = (
                root
                / "output-base"
                / "testlogs"
                / "pkg"
                / "target"
                / "test.outputs"
                / "outputs.zip"
            )
            carrier.parent.mkdir(parents=True)
            with zipfile.ZipFile(carrier, "w") as archive:
                archive.writestr(
                    "payloads/tests/events.json",
                    '{"events":[{"content":{}}]}',
                )
                archive.writestr(
                    "bazel_target_metadata.json",
                    '{"bazel.target":"//pkg:target"}',
                )
            bep = root / "bep.ndjson"
            bep.write_text(
                json.dumps(
                    {
                        "id": {
                            "testResult": {
                                "label": "//pkg:target",
                                "run": 1,
                                "shard": 1,
                                "attempt": 1,
                            }
                        },
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {"name": "outputs.zip", "uri": carrier.as_uri()}
                            ],
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            config = self._config(
                root,
                "--artifact-source=bep",
                "--freshness-source=bep",
                "--freshness-mode=required",
                f"--bep-json={bep}",
            )
            resolver = RunfilesResolver.from_environment(cwd=root, environ={})

            prepared = prepare_freshness(
                config,
                resolver=resolver,
                local_testlogs_root=None,
                expected_targets=("//pkg:target",),
            )
            staged_roots = prepared.staged_roots
            discovery = select_expected_outputs(
                discover_file_tasks(
                    prepared.scan_roots,
                    staged_output_keys=("pkg/target/test.outputs",),
                ),
                ExpectedTargetsPlan(("//pkg:target",), "static"),
                allow_missing=True,
            )
            filtered = filter_discovery_for_freshness(
                discovery,
                prepared.plan,
                freshness_mode="required",
            )

            self.assertEqual(1, len(filtered.discovery.tasks))
            self.assertEqual(
                frozenset({("//pkg:target", "pkg/target/test.outputs")}),
                prepared.plan.staged_outputs,
            )
            self.assertTrue(all(path.is_dir() for path in staged_roots))
            prepared.cleanup()
            self.assertTrue(all(not path.exists() for path in staged_roots))

    def test_fail_on_error_requires_a_non_skipped_result_for_fresh_output(self) -> None:
        plan = FreshnessPlan(
            selected_source="bep",
            eligibility_enabled=True,
            eligible_outputs=frozenset({("//pkg:target", "pkg/target/test.outputs")}),
        )
        empty = DiscoveryResult(
            outputs=(),
            tasks=(),
            discovered_by_type=tuple((kind, 0) for kind in PayloadType),
        )
        with self.assertRaisesRegex(FreshnessError, "none produced"):
            validate_fresh_outputs_accounted(
                plan,
                empty,
                (),
                expected_targets=(),
                fail_on_error=True,
            )

    def test_expected_target_accepts_payload_from_one_of_multiple_attempts(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            empty_output_key = (
                "pkg/target/test_attempts/attempt_1.outputs/test.outputs"
            )
            payload_output_key = "pkg/target/test.outputs"
            empty_attempt = root / empty_output_key
            empty_attempt.mkdir(parents=True)
            payload_attempt = root / payload_output_key
            _payload(payload_attempt)
            _metadata(payload_attempt, "//pkg:target")
            plan = FreshnessPlan(
                selected_source="bep",
                eligibility_enabled=True,
                eligible_outputs=frozenset(
                    {
                        ("//pkg:target", empty_output_key),
                        ("//pkg:target", payload_output_key),
                    }
                ),
            )

            filtered = filter_discovery_for_freshness(
                discover_file_tasks((ScanRoot(root),)),
                plan,
                freshness_mode="required",
            ).discovery
            task = filtered.tasks[0]
            result = FileResult(
                task_id=task.task_id,
                source_path=str(task.source_path),
                payload_type=task.payload_type,
                status=FileStatus.SUCCEEDED,
            )

            validate_fresh_outputs_accounted(
                plan,
                filtered,
                (result,),
                expected_targets=("//pkg:target",),
                fail_on_error=True,
            )

    def test_expected_target_rejects_when_all_attempts_are_empty(self) -> None:
        plan = FreshnessPlan(
            selected_source="bep",
            eligibility_enabled=True,
            eligible_outputs=frozenset(
                {
                    (
                        "//pkg:target",
                        "pkg/target/test_attempts/attempt_1.outputs/test.outputs",
                    ),
                    ("//pkg:target", "pkg/target/test.outputs"),
                }
            ),
        )
        empty = DiscoveryResult(
            outputs=(),
            tasks=(),
            discovered_by_type=tuple((kind, 0) for kind in PayloadType),
        )

        with self.assertRaisesRegex(FreshnessError, "produced no uploadable payloads"):
            validate_fresh_outputs_accounted(
                plan,
                empty,
                (),
                expected_targets=("//pkg:target",),
                fail_on_error=True,
            )

if __name__ == "__main__":
    unittest.main()
