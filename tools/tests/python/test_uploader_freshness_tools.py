#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Uploader freshness and doctor-runtime reuse tests."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile


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
            return candidate.resolve()
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
    filter_discovery_for_freshness,
    prepare_freshness,
    validate_fresh_outputs_accounted,
)
from uploader_py.models import PayloadType  # noqa: E402


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
if __name__ == "__main__":
    unittest.main()
