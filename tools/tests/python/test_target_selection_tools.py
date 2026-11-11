#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Check indexed output authorization and invocation-scoped target files."""

from __future__ import annotations

from io import StringIO
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from uploader_test_support import add_uploader_runtime_to_path

add_uploader_runtime_to_path()

import test_optimization_doctor as doctor
from topt_runtime.runfiles import RunfilesResolver
from uploader_py import expected_targets
from uploader_py.application import run_uploader
from uploader_py.config import ConfigError, parse_uploader_config
from uploader_py.discovery import DiscoveryResult, DiscoveredOutput
from uploader_py.endpoints import build_endpoints
from uploader_py.logging_utils import configure_logging


class _CountedPairs(set):
    visits = 0

    def __iter__(self):
        for pair in super().__iter__():
            self.visits += 1
            yield pair


class TargetSelectionTests(unittest.TestCase):
    def test_target_matching_does_not_rescan_the_target_catalog(self) -> None:
        for count in (100, 1000, 10000):
            targets = tuple(f"//pkg:t{i}" for i in range(count))
            outputs = tuple(
                DiscoveredOutput(Path(f"/logs/pkg/t{i}/test.outputs"), f"pkg/t{i}/test.outputs", Path("/logs"), False)
                for i in range(count)
            )
            discovery = DiscoveryResult(outputs=outputs, tasks=(), discovered_by_type=())
            with mock.patch.object(expected_targets, "_target_output_parts", wraps=expected_targets._target_output_parts) as parse:
                selected = expected_targets.select_expected_outputs(
                    discovery, expected_targets.ExpectedTargetsPlan(targets)
                )
            self.assertEqual(outputs, selected.outputs)
            self.assertLessEqual(parse.call_count, count)

    def test_doctor_bep_matching_does_not_rescan_all_results_per_output(self) -> None:
        for count in (100, 1000, 10000):
            pairs = _CountedPairs((f"//pkg:t{i}", f"pkg/t{i}/test.outputs") for i in range(count))
            outputs = [Path(f"/logs/pkg/t{i}/test.outputs") for i in range(count)]
            labels = {path.resolve(): f"//pkg:t{i}" for i, path in enumerate(outputs)}
            freshness = doctor.BepFreshness(pairs, set(), [], set())
            # Metadata I/O is unrelated to the matching cost being measured.
            with mock.patch.object(doctor, "_metadata_files", return_value=[Path("metadata")]), mock.patch.object(doctor, "_load_json", return_value={}), mock.patch.object(doctor, "_payload_files", return_value=[Path("payload.json")]):
                selected = doctor._validate_expected_target_bep_freshness(
                    outputs, set(labels.values()), freshness, required=True,
                    label_by_output_dir=labels,
                )
            self.assertEqual(outputs, selected)
            self.assertLessEqual(pairs.visits, 3 * count)

    def test_bep_index_preserves_suffix_boundaries_and_staged_keys(self) -> None:
        pairs = {("//pkg:a", "pkg/a/test.outputs"), ("//other:a", "other/a/test.outputs")}
        outputs = [Path("/logs/pkg/a/test.outputs"), Path("/logs/notpkg/a/test.outputs"), Path("/staged/opaque/test.outputs")]
        labels = {outputs[0].resolve(): "//pkg:a", outputs[1].resolve(): "//pkg:a", outputs[2].resolve(): "//other:a"}
        freshness = doctor.BepFreshness(pairs, set(), [], set())
        with mock.patch.object(doctor, "_metadata_files", return_value=[Path("metadata")]), mock.patch.object(doctor, "_load_json", return_value={}), mock.patch.object(doctor, "_payload_files", return_value=[Path("payload.json")]):
            selected = doctor._validate_expected_target_bep_freshness(
                outputs, set(labels.values()), freshness, required=True,
                label_by_output_dir=labels,
                output_key_by_output_dir={outputs[2].resolve(): "other/a/test.outputs"},
            )
        self.assertEqual([outputs[0], outputs[2]], selected)

    def test_bep_index_matches_physical_retry_roots(self) -> None:
        index = doctor._BepOutputIndex({("//pkg:test", "pkg/test/test_attempts/attempt_1.outputs/test.outputs")})
        self.assertEqual({"//pkg:test"}, index.labels_for(Path("/logs/pkg/test/test_attempts/attempt_1.outputs"), None))
        self.assertEqual(set(), index.labels_for(Path("/logs/notpkg/test/test_attempts/attempt_1.outputs"), None))

    def test_literal_retry_like_target_is_not_selected_as_its_parent(self) -> None:
        key = "pkg/foo/test_attempts/attempt_1.outputs/test.outputs"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / key
            output.mkdir(parents=True)
            (output / "bazel_target_metadata.json").write_text('{"bazel.target":"//pkg/foo/test_attempts:attempt_1.outputs"}')
            discovery = DiscoveryResult((DiscoveredOutput(output, key, root, False),), (), ())
            with self.assertRaises(expected_targets.ExpectedTargetsError):
                expected_targets.select_expected_outputs(discovery, expected_targets.ExpectedTargetsPlan(("//pkg:foo",)))
            literal = "//pkg/foo/test_attempts:attempt_1.outputs"
            self.assertEqual(discovery.outputs, expected_targets.select_expected_outputs(
                discovery, expected_targets.ExpectedTargetsPlan((literal,))).outputs)

    def test_retry_ancestry_requires_physical_or_bep_provenance(self) -> None:
        key = "pkg/foo/test_attempts/attempt_1.outputs/test.outputs"
        plan = expected_targets.ExpectedTargetsPlan(("//pkg:foo",))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            physical = DiscoveredOutput(root / key.removesuffix("/test.outputs"), key, root, False)
            discovered = DiscoveryResult((physical,), (), ())
            self.assertEqual((physical,), expected_targets.select_expected_outputs(discovered, plan).outputs)
            staged = DiscoveredOutput(root / "opaque/test.outputs", key, root, True)
            discovered = DiscoveryResult((staged,), (), ())
            with self.assertRaises(expected_targets.ExpectedTargetsError):
                expected_targets.select_expected_outputs(discovered, plan)
            self.assertEqual((staged,), expected_targets.select_expected_outputs(
                discovered, plan, bep_outputs=(("//pkg:foo", key),)).outputs)
            with self.assertRaisesRegex(expected_targets.ExpectedTargetsError, "BEP output target conflicts"):
                expected_targets.select_expected_outputs(discovered, plan, bep_outputs=(("//other:test", key),))

    def test_conflicting_physical_retry_sidecar_cannot_be_relabelled(self) -> None:
        key = "pkg/foo/test_attempts/attempt_1.outputs/test.outputs"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / key.removesuffix("/test.outputs")
            output.mkdir(parents=True)
            metadata = output / "bazel_target_metadata.json"
            metadata.write_text('{"bazel.target":"//other:test"}')
            discovery = DiscoveryResult((DiscoveredOutput(output, key, root, False),), (), ())
            with self.assertRaisesRegex(expected_targets.ExpectedTargetsError, "bazel.target metadata conflicts"):
                expected_targets.select_expected_outputs(discovery, expected_targets.ExpectedTargetsPlan(("//pkg:foo",)))
            self.assertEqual('{"bazel.target":"//other:test"}', metadata.read_text())

    def test_target_index_preserves_paths_attempts_and_ambiguity(self) -> None:
        index = expected_targets._TargetOutputIndex((
            "//pkg:foo", "//pkg/foo:shard_1_of_2", "//pkg:other/nested",
        ))
        for key, labels in (
            ("pkg/foo/test.outputs", ["//pkg:foo"]),
            (r"pkg\foo\run_1_of_2\attempt_1\test.outputs", ["//pkg:foo"]),
            ("pkg/foo/test_attempts/attempt_1.outputs/test.outputs", []),
            ("pkg/foo/test_attempts/test.outputs", []),
            ("pkg/foo/attempt_1.outputs/test.outputs", []),
            ("pkg/foo/shard_1_of_2/test.outputs", ["//pkg/foo:shard_1_of_2"]),
            ("pkg/other/nested/test.outputs", ["//pkg:other/nested"]),
            ("pkg/foobar/test.outputs", []),
            ("pkg/foo/unknown/test.outputs", []),
            ("pkg/foo/test.outputs/extra", []),
        ):
            with self.subTest(key=key):
                self.assertEqual(labels, index.matches(key))
        # Different local labels can map to the same physical target root.
        ambiguous = expected_targets.ExpectedTargetsPlan(("//pkg:other/nested", "//pkg/other:nested"))
        output = DiscoveredOutput(Path("/logs/pkg/other/nested/test.outputs"),
                                  "pkg/other/nested/test.outputs", Path("/logs"), False)
        with self.assertRaisesRegex(expected_targets.ExpectedTargetsError, "multiple expected"):
            expected_targets.select_expected_outputs(
                DiscoveryResult((output,), (), ()), ambiguous, allow_missing=True)

    def test_empty_file_and_configuration_conflicts_keep_runtime_gates(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "targets.json"
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)
            path.write_text('{"schema_version":1,"targets":[]}')
            with self.assertRaisesRegex(expected_targets.ExpectedTargetsError, "at least one"):
                expected_targets.load_expected_targets(static_targets=(), expected_targets_file_paths=(),
                    resolver=resolver, runtime_targets_file=path, runtime_selection=True)
            with mock.patch("sys.stderr", StringIO()), self.assertRaises(SystemExit):
                doctor._resolve_expected_targets({"expected_targets": []}, root / "config.json",
                    runtime_selection=True, runtime_targets_file=path)
            path.write_text('{"schema_version":1,"targets":["//pkg:b"]}')
            with self.assertRaisesRegex(expected_targets.ExpectedTargetsError, "different target sets"):
                expected_targets.load_expected_targets(static_targets=("//pkg:a",), expected_targets_file_paths=(),
                    resolver=resolver, runtime_targets_file=path)
            with mock.patch("sys.stderr", StringIO()), self.assertRaises(SystemExit):
                doctor._resolve_expected_targets({"expected_targets": ["//pkg:a"]}, root / "config.json",
                    runtime_targets_file=path)
            with mock.patch.object(Path, "read_bytes", side_effect=PermissionError("denied")):
                with self.assertRaises(expected_targets.ExpectedTargetsError):
                    expected_targets.load_expected_targets(static_targets=(), expected_targets_file_paths=(),
                        resolver=resolver, runtime_targets_file=path)
            with mock.patch.object(doctor, "_load_json", side_effect=PermissionError("denied")):
                with mock.patch("sys.stderr", StringIO()), self.assertRaises(SystemExit):
                    doctor._resolve_expected_targets({"expected_targets": []}, root / "config.json",
                        runtime_targets_file=path)

    def test_runtime_file_and_arguments_form_the_same_union_in_both_tools(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "targets space λ.json"
            path.write_text(json.dumps({"schema_version": 1, "targets": ["//pkg:a", "//pkg:b"]}), encoding="utf-8-sig")
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)
            plan = expected_targets.load_expected_targets(
                static_targets=("//pkg:a", "//pkg:b", "//pkg:c"),
                expected_targets_file_paths=(), resolver=resolver,
                runtime_targets=("//pkg:c", "//pkg:a"), runtime_targets_file=path,
                runtime_selection=True,
            )
            targets, source = doctor._resolve_expected_targets(
                {"expected_targets": ["//pkg:a", "//pkg:b", "//pkg:c"]},
                root / "config.json", ["//pkg:c", "//pkg:a"], True,
                runtime_targets_file=path,
            )
            self.assertEqual(("//pkg:a", "//pkg:b", "//pkg:c"), plan.targets)
            self.assertEqual(list(plan.targets), targets)
            self.assertEqual(plan.source, source)
            self.assertEqual("runtime_and_configured", source)
            args = doctor._parse_args(["--config=x", f"--expected-targets-file={path}"])
            self.assertEqual(str(path), args.expected_targets_file)

    def test_invalid_runtime_files_are_rejected_by_both_loaders(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "targets.json"
            resolver = RunfilesResolver.from_environment(environ={}, cwd=root)
            cases = [
                b'{', b'\xff', b'{"schema_version":2,"targets":[]}',
                b'{"schema_version":1,"targets":["//pkg:b","//pkg:a"]}',
                b'{"schema_version":1,"targets":["//pkg:a","//pkg:a"]}',
                b'{"schema_version":1,"targets":["@repo//pkg:a"]}',
                b'{"schema_version":1,"targets":["//pkg/..:a"]}',
                b'{"schema_version":1,"targets":"//pkg:a"}',
                b'{"schema_version":1,"targets":[],"extra":true}',
            ]
            for content in cases + [None]:
                with self.subTest(content=content):
                    if content is None:
                        path.unlink(missing_ok=True)
                    else:
                        path.write_bytes(content)
                    with self.assertRaises(expected_targets.ExpectedTargetsError):
                        expected_targets.load_expected_targets(static_targets=(), expected_targets_file_paths=(), resolver=resolver, runtime_targets_file=path)
                    with mock.patch("sys.stderr", StringIO()), self.assertRaises(SystemExit):
                        doctor._resolve_expected_targets({"expected_targets": []}, root / "config.json", runtime_targets_file=path)

    def test_relative_runtime_file_uses_the_bazel_callers_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "targets space λ.json"
            path.write_text('{"schema_version":1,"targets":["//pkg:a"]}')
            config = root / "config.json"
            config.write_text('{"schema_version":1}')
            parsed = parse_uploader_config(["--config", str(config), "--expected-targets-file", path.name],
                environ={"BUILD_WORKING_DIRECTORY": str(root)}, cwd=root / "unrelated-runfiles")
            self.assertEqual(path, parsed.runtime_expected_targets_file)
            with mock.patch.dict(os.environ, {"BUILD_WORKING_DIRECTORY": str(root)}):
                args = doctor._parse_args(["--config", str(config), "--expected-targets-file", path.name])
            self.assertEqual(str(path), args.expected_targets_file)

    def test_empty_path_is_not_an_absent_option(self) -> None:
        with mock.patch("sys.stderr", StringIO()), self.assertRaises(SystemExit):
            doctor._parse_args(["--config=unused", "--expected-targets-file="])
        with self.assertRaisesRegex(ConfigError, "nonempty path"):
            parse_uploader_config(["--config=unused", "--expected-targets-file="], environ={})

    def test_doctor_stat_permission_error_is_controlled(self) -> None:
        with mock.patch.object(Path, "is_file", side_effect=PermissionError("denied")):
            with mock.patch("sys.stderr", StringIO()), self.assertRaises(SystemExit) as failure:
                doctor._load_expected_targets_file(Path("inaccessible/targets.json"))
        self.assertEqual(1, failure.exception.code)

    def test_uploader_rejects_invalid_runtime_file_before_creating_transport(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_path = root / "config.json"
            config_path.write_text(json.dumps({"schema_version": 1, "quiescent_sec": 0, "max_wait_sec": 0}))
            path = root / "bad.json"
            path.write_text('{')
            config = parse_uploader_config(
                ["--config", str(config_path), "--expected-targets-file", str(path)],
                environ={"BUILD_WORKSPACE_DIRECTORY": str(root)}, cwd=root,
            )
            transport = mock.Mock(side_effect=AssertionError("HTTP must not start"))
            rc = run_uploader(config, resolver=RunfilesResolver.from_environment(environ={}, cwd=root),
                              endpoints=build_endpoints(config), logger=configure_logging(debug=False, stream=StringIO()),
                              stream=StringIO(), transport_factory=transport)
            self.assertEqual(2, rc)
            transport.assert_not_called()


if __name__ == "__main__":
    unittest.main()
