#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Keep retry, shard and invocation evidence separate without directory guesses."""

from dataclasses import replace
import json
import os
from contextlib import redirect_stderr
from io import StringIO
from unittest import mock
from pathlib import Path
import tempfile
import unittest
from uploader_test_support import add_uploader_runtime_to_path

add_uploader_runtime_to_path()

from topt_runtime.bep_execution import BepTestExecution, ambiguous_execution_outputs, missing_test_shards
from test_python_tools import _load_module


def execution(*, invocation="one", configuration="config", run=1, shard=0, attempt=1, cached=False, output="shard0/test.outputs"):
    return BepTestExecution((invocation, "//pkg:test", configuration, run, shard, attempt), cached, "PASSED", frozenset({output}))


class BepExecutionTests(unittest.TestCase):
    def test_named_target_log_references_keep_each_shards_output_root(self):
        from test_python_tools import TestOptimizationDoctorTests
        from test_uploader_application_tools import _bep_test_result, _write_payload
        doctor = _load_module("doctor_named_target_logs", "tools/core/test_optimization_doctor.py")
        for filename, retry in (("test.log", False), ("test.xml", False),
                ("attempt_1.log", True), ("attempt_1.xml", True)):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                testlogs = root / "bazel-testlogs"
                records, keys = [], []
                for shard in (1, 2):
                    parent = testlogs / f"pkg/test.outputs/shard_{shard}_of_2"
                    output = parent / ("test_attempts/attempt_1.outputs" if retry else "test.outputs")
                    log = (parent / "test_attempts" if retry else parent) / filename
                    _write_payload(output, "tests", "events.json", {"events": [{"type": "test", "content": {}}]})
                    (output / "bazel_target_metadata.json").write_text(json.dumps({
                        "bazel.target": "//pkg:test.outputs", "bazel.go.payload_selection": "module"}))
                    key = output.relative_to(testlogs).as_posix() + ("/test.outputs" if retry else "")
                    keys.append(key)
                    self.assertEqual(key, doctor._bep_test_output_key(log.as_uri(), artifact_name="test.log" if filename.endswith(".log") else "test.xml"))
                    record = _bep_test_result("//pkg:test.outputs", output=output)
                    record["id"]["testResult"]["shard"] = shard
                    record["testResult"]["testActionOutput"].append({"name": "test.log" if filename.endswith(".log") else "test.xml", "uri": log.as_uri()})
                    records.append(record)
                bep = root / "bep.json"
                bep.write_text("\n".join(json.dumps(record) for record in records))
                parsed = doctor._parse_bep_freshness([bep])
                self.assertFalse(parsed.ambiguous_outputs)
                self.assertEqual(set(keys), {key for _, key in parsed.eligible_outputs})
                config = TestOptimizationDoctorTests._write_doctor_config(root, ["//pkg:test.outputs"])
                with mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(testlogs), "BUILD_WORKSPACE_DIRECTORY": str(root)}):
                    self.assertEqual(0, doctor.main(["--config", str(config), "--bep-json", str(bep), "--freshness-mode=required"]))

    def test_optional_doctor_rejects_ambiguous_bep_without_requiring_all_shards(self):
        from test_python_tools import TestOptimizationDoctorTests
        from test_uploader_application_tools import _bep_test_result, _write_payload
        doctor = _load_module("doctor_optional_ambiguous", "tools/core/test_optimization_doctor.py")
        for catalog in (False, True):
            with self.subTest(catalog=catalog), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                output = root / "bazel-testlogs/pkg/test/shard_1_of_2/test.outputs"
                _write_payload(output, "tests", "events.json", {"events": [{"type": "test", "content": {}}]})
                (output / "bazel_target_metadata.json").write_text(json.dumps({
                    "bazel.target": "//pkg:test", "bazel.go.payload_selection": "module"}))
                bep = root / "bep.json"
                fresh = _bep_test_result("//pkg:test", output=output)
                cached = _bep_test_result("//pkg:test", output=output, cached_locally=True)
                bep.write_text(json.dumps(fresh) + "\n" + json.dumps(cached))
                config = TestOptimizationDoctorTests._write_doctor_config(root, ["//pkg:test"] if catalog else [])
                stderr = StringIO()
                with mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root / "bazel-testlogs"), "BUILD_WORKSPACE_DIRECTORY": str(root)}), redirect_stderr(stderr):
                    with self.assertRaises(SystemExit):
                        doctor.main(["--config", str(config), "--bep-json", str(bep), "--freshness-mode=optional"])
                    self.assertIn("ambiguous", stderr.getvalue())
                    missing = _bep_test_result("//pkg:test")
                    missing["id"]["testResult"]["shard"] = 2
                    bep.write_text(json.dumps(fresh) + "\n" + json.dumps(missing))
                    self.assertEqual(0, doctor.main(["--config", str(config), "--bep-json", str(bep), "--freshness-mode=optional"]))

    def test_global_discovery_ignores_named_ancestors_with_real_sidecars(self):
        from test_python_tools import TestOptimizationDoctorTests
        from test_uploader_application_tools import _write_payload
        from uploader_py.discovery import ScanRoot, discover_file_tasks
        from topt_runtime.bep_execution import find_test_output_directories
        doctor = _load_module("doctor_global_named_ancestors", "tools/core/test_optimization_doctor.py")
        for target, relative in (("//test.outputs/pkg:target", "test.outputs/pkg/target/test.outputs"),
                ("//test.outputs:payloads", "test.outputs/payloads/test.outputs")):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                testlogs = root / "bazel-testlogs"
                output = testlogs / relative
                _write_payload(output, "tests", "events.json", {"events": [{"type": "test", "content": {}}]})
                (output / "bazel_target_metadata.json").write_text(json.dumps({
                    "bazel.target": target, "bazel.go.payload_selection": "module"}))
                self.assertEqual((output,), find_test_output_directories(testlogs))
                self.assertEqual([output], doctor._discover_candidate_output_dirs(testlogs))
                self.assertEqual(1, len(discover_file_tasks((ScanRoot(testlogs),)).tasks))
                config = TestOptimizationDoctorTests._write_doctor_config(root, [])
                with mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(testlogs), "BUILD_WORKSPACE_DIRECTORY": str(root)}):
                    self.assertEqual(0, doctor.main(["--config", str(config), "--freshness-mode=disabled"]))

    def test_core_only_outputs_win_over_names_inside_payloads(self):
        from topt_runtime.bep_execution import find_test_output_directories
        from test_uploader_application_tools import _write_payload
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / "test.outputs/payloads/tests/test.outputs"
            _write_payload(output, "tests", "nested/test.outputs/events.json", {"events": []})
            self.assertEqual((output,), find_test_output_directories(root))

    def test_target_named_test_outputs_keeps_its_real_output_directory(self):
        from test_python_tools import TestOptimizationDoctorTests
        from test_uploader_application_tools import _write_payload
        from uploader_py.discovery import ScanRoot, discover_file_tasks
        doctor = _load_module("doctor_literal_test_outputs_target", "tools/core/test_optimization_doctor.py")
        for suffix in ("test.outputs", "shard_1_of_2/test.outputs"):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                testlogs = root / "bazel-testlogs"
                output = testlogs / "pkg/test.outputs" / suffix
                _write_payload(output, "tests", "events.json", {"events": [{"type": "test", "content": {}}]})
                (output / "bazel_target_metadata.json").write_text(json.dumps({
                    "bazel.target": "//pkg:test.outputs", "bazel.go.payload_selection": "module"}))
                config = TestOptimizationDoctorTests._write_doctor_config(root, ["//pkg:test.outputs"])
                with mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(testlogs), "BUILD_WORKSPACE_DIRECTORY": str(root)}):
                    self.assertEqual(0, doctor.main(["--config", str(config), "--freshness-mode=disabled"]))
                self.assertEqual([output], doctor._expected_target_outputs(testlogs, "//pkg:test.outputs"))
                self.assertEqual(1, len(discover_file_tasks((ScanRoot(testlogs),)).tasks))

    def test_named_packages_and_empty_output_root_remain_discoverable(self):
        from topt_runtime.bep_execution import find_test_output_directories
        doctor = _load_module("doctor_literal_test_outputs_package", "tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / "test.outputs/pkg/target/test.outputs"
            (output / "payloads/tests").mkdir(parents=True)
            (output / "payloads/tests/events.json").write_text('{"events":[]}')
            self.assertEqual([output], doctor._discover_candidate_output_dirs(root))
            self.assertEqual((output,), find_test_output_directories(output))
            empty = root / "empty/test.outputs"
            empty.mkdir(parents=True)
            self.assertEqual((empty,), find_test_output_directories(empty))

    def test_retry_cannot_satisfy_other_shards_runs_configurations_or_invocations(self):
        first = execution()
        for variation in ({"shard": 1}, {"run": 2}, {"configuration": "another"}, {"invocation": "two"}):
            with self.subTest(variation=variation):
                other = execution(output="other/test.outputs", **variation)
                self.assertEqual([other.identity[:-1]], missing_test_shards((first, other), {("//pkg:test", "shard0/test.outputs")}, {"//pkg:test"}))
        retry = execution(attempt=2, output="retry/test.outputs")
        self.assertEqual([], missing_test_shards((replace(first, status="FAILED"), retry), {("//pkg:test", "retry/test.outputs")}, {"//pkg:test"}))
        self.assertEqual([first.identity[:-1]], missing_test_shards((first, retry), {("//pkg:test", "retry/test.outputs")}, {"//pkg:test"}))
        self.assertEqual([first.identity[:-1]], missing_test_shards((first, replace(retry, status="FAILED")), {("//pkg:test", "shard0/test.outputs")}, {"//pkg:test"}))

    def test_cached_attempt_cannot_hide_fresh_shard(self):
        fresh = execution()
        cached = execution(attempt=2, cached=True, output="cached/test.outputs")
        self.assertEqual([fresh.identity[:-1]], missing_test_shards((fresh, cached), {("//pkg:test", "cached/test.outputs")}, {"//pkg:test"}))
        self.assertEqual([], missing_test_shards((cached,), set(), {"//pkg:test"}))
        self.assertEqual([], missing_test_shards((fresh,), set(), {"//pkg:ordinary"}))

    def test_key_collision_is_not_arbitrarily_assigned(self):
        first = execution()
        for other in (execution(shard=1), execution(run=2), execution(configuration="another"), execution(invocation="two"), replace(first, cached=True)):
            with self.subTest(identity=other.identity, cached=other.cached):
                self.assertEqual(frozenset({"shard0/test.outputs"}), ambiguous_execution_outputs((first, other)))
        self.assertEqual(frozenset(), ambiguous_execution_outputs((first, first)))
        conflicting_carrier = replace(first, carriers=(("shard0/test.outputs", "another-carrier"),))
        self.assertEqual(frozenset({"shard0/test.outputs"}), ambiguous_execution_outputs((first, conflicting_carrier)))

    def test_integration_cached_outputs_have_distinct_execution_coordinates(self):
        from uploader_test_support import resolve_runfile
        doctor = _load_module("doctor_integration_execution_scope", "tools/core/test_optimization_doctor.py")
        for name in ("run_mock_server_tests.sh", "run_mock_server_tests.ps1"):
            source = resolve_runfile("tools/tests/integration/" + name).read_text()
            cached = [json.loads(line) for line in source.splitlines()
                if line.startswith('{"id":{"testResult"')
                and '"label":"//same_label:bep_payload_test"' in line
                and any(key in line for key in ("cached_local_attempt", "cached_remote_attempt"))]
            self.assertGreaterEqual(len(cached), 2)
            for event in cached:
                with self.subTest(script=name, event=event):
                    fresh = {"id": {"testResult": {"label": "//same_label:bep_payload_test", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {"status": "PASSED", "testActionOutput": [{"name": "test.outputs",
                            "uri": "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/fresh_attempt/payload_test/test.outputs"}]}}
                    with tempfile.TemporaryDirectory() as tmp:
                        bep = Path(tmp) / "events.json"
                        bep.write_text(json.dumps(fresh) + "\n" + json.dumps(event) + "\n")
                        parsed = doctor._parse_bep_freshness([bep], workspace=Path(tmp))
                    self.assertFalse(parsed.ambiguous_outputs)
                    self.assertEqual(1, len(parsed.eligible_outputs))
                    self.assertEqual(1, len(parsed.cached_outputs))

    def test_parser_deduplicates_same_file_and_uuid_copy_but_preserves_other_documents(self):
        doctor = _load_module("doctor_execution_scope", "tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload = {"id": {"testResult": {"label": "//pkg:test", "configuration": {"id": "cfg"}, "run": 1, "shard": 0, "attempt": 1}}, "testResult": {"status": "PASSED", "testActionOutput": [{"name": "test.outputs", "uri": "file:///tmp/bazel-testlogs/pkg/test/test.outputs"}]}}
            first, copy = root / "one.json", root / "copy.json"
            body = json.dumps({"started": {"uuid": "build-id"}}) + "\n" + json.dumps(payload)
            first.write_text(body)
            copy.write_text(body)
            parsed = doctor._parse_bep_freshness([first, first, copy])
            self.assertEqual(1, len(parsed.executions))
            self.assertEqual(("uuid:build-id", "//pkg:test", "cfg", 1, 0, 1), parsed.executions[0].identity)
            first.write_text(json.dumps(payload))
            copy.write_text(json.dumps(payload))
            parsed = doctor._parse_bep_freshness([first, copy])
            self.assertEqual(2, len(parsed.executions))
            self.assertNotEqual(parsed.executions[0].identity[0], parsed.executions[1].identity[0])
            self.assertEqual(frozenset({"pkg/test/test.outputs"}), parsed.ambiguous_outputs)

    def test_doctor_requires_test_evidence_in_each_shard(self):
        from test_python_tools import TestOptimizationDoctorTests
        from test_uploader_application_tools import _bep_test_result, _write_payload
        doctor = _load_module("doctor_shards_main", "tools/core/test_optimization_doctor.py")
        for explicit_targets in (False, True):
            with self.subTest(explicit_targets=explicit_targets), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                outputs = [root / "bazel-testlogs/pkg/target" / f"shard_{n}_of_2/test.outputs" for n in (1, 2)]
                _write_payload(outputs[0], "tests", "events.json", {"events": [{"type": "test", "content": {}}]})
                second = _write_payload(outputs[1], "coverage", "coverage.json", {"files": []})
                records = []
                for shard, output in enumerate(outputs):
                    (output / "bazel_target_metadata.json").write_text(json.dumps({"bazel.target": "//pkg:target", "bazel.go.payload_selection": "module"}))
                    record = _bep_test_result("//pkg:target", output=output)
                    record["id"]["testResult"]["shard"] = shard
                    records.append(record)
                bep = root / "bep.json"
                bep.write_text("\n".join(json.dumps(record) for record in records))
                cfg = TestOptimizationDoctorTests._write_doctor_config(root, ["//pkg:target"] if explicit_targets else [])
                argv = ["--config", str(cfg), "--bep-json", str(bep), "--freshness-mode=required"]
                stderr = StringIO()
                with mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root / "bazel-testlogs"), "BUILD_WORKSPACE_DIRECTORY": str(root)}), redirect_stderr(stderr):
                    with self.assertRaises(SystemExit) as failed:
                        doctor.main(argv)
                    self.assertEqual(1, failed.exception.code)
                    self.assertIn("shard=1", stderr.getvalue())
                    # With actual test events in both shards, the same command passes.
                    second.unlink()
                    _write_payload(outputs[1], "tests", "events.json", {"events": [{"type": "test", "content": {}}]})
                    self.assertEqual(0, doctor.main(argv))

    def test_real_bazel_retry_root_is_discovered_and_mapped_to_its_own_key(self):
        from uploader_py.discovery import discover_file_tasks, ScanRoot
        from uploader_py.expected_targets import ExpectedTargetsPlan, select_expected_outputs
        from topt_runtime.bep_execution import find_test_output_directories
        from test_uploader_application_tools import _bep_test_result, _write_payload
        doctor = _load_module("doctor_real_retry_root", "tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "bazel-testlogs"
            previous = root / "pkg/target/shard_2_of_2/test_attempts/attempt_1.outputs"
            final = root / "pkg/target/shard_2_of_2/test.outputs"
            records = []
            for attempt, output in enumerate((previous, final), start=1):
                _write_payload(output, "tests", "events.json", {"events": [{"content": {}}]})
                metadata = output / "bazel_target_metadata.json"
                metadata.write_text(json.dumps({"bazel.target": "//pkg:target"}))
                record = _bep_test_result("//pkg:target", attempt=attempt, output=None)
                record["testResult"]["testActionOutput"] = [{"name": "test.outputs/bazel_target_metadata.json", "uri": metadata.as_uri()}]
                records.append(record)
            bep = root.parent / "bep.json"
            bep.write_text("\n".join(json.dumps(record) for record in records))
            parsed = doctor._parse_bep_freshness([bep])
            keys = {"pkg/target/shard_2_of_2/test_attempts/attempt_1.outputs/test.outputs", "pkg/target/shard_2_of_2/test.outputs"}
            self.assertEqual(keys, {key for _, key in parsed.eligible_outputs})
            discovery = select_expected_outputs(discover_file_tasks((ScanRoot(root),)), ExpectedTargetsPlan(("//pkg:target",)))
            self.assertEqual(keys, {task.output_key for task in discovery.tasks})
            self.assertEqual(set((previous, final)), set(find_test_output_directories(root)))
            # A target can itself contain retry-like components; its nested
            # test.outputs remains the root and must not be discovered twice.
            nested = root / "pkg/test_attempts/attempt_9.outputs/test.outputs"
            nested.mkdir(parents=True)
            roots = find_test_output_directories(root)
            self.assertIn(nested, roots)
            self.assertNotIn(nested.parent, roots)

    def test_one_result_with_distinct_complete_carriers_is_ambiguous(self):
        first = execution()
        conflicting = replace(first, carriers=(("shard0/test.outputs", "local:/one"), ("shard0/test.outputs", "local:/two")))
        self.assertEqual(frozenset({"shard0/test.outputs"}), ambiguous_execution_outputs((conflicting,)))
        duplicate = replace(first, carriers=(("shard0/test.outputs", "local:/one"), ("shard0/test.outputs", "local:/one")))
        self.assertEqual(frozenset(), ambiguous_execution_outputs((duplicate,)))

    def test_retry_shaped_sharded_target_and_payload_components_keep_their_root(self):
        from topt_runtime.bep_execution import find_test_output_directories
        doctor = _load_module("doctor_retry_shaped_target", "tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "bazel-testlogs"
            output = root / "pkg/test_attempts/attempt_9.outputs/shard_1_of_2/test.outputs"
            output.mkdir(parents=True)
            self.assertEqual((output,), find_test_output_directories(root))
            name = "test.outputs/payloads/tests/test_attempts/attempt_8.outputs/events.json"
            value = output.as_posix() + "/" + name[len("test.outputs/"):]
            self.assertEqual("pkg/test_attempts/attempt_9.outputs/shard_1_of_2/test.outputs", doctor._bep_test_output_key(value, artifact_name=name))
            log = output.parent / "test.log"
            self.assertEqual("pkg/test_attempts/attempt_9.outputs/shard_1_of_2/test.outputs", doctor._bep_test_output_key(log.as_posix(), artifact_name="test.log"))

    def test_doctor_cached_shard_cannot_hide_unmapped_fresh_shard(self):
        from test_python_tools import TestOptimizationDoctorTests
        from test_uploader_application_tools import _bep_test_result
        doctor = _load_module("doctor_mixed_cached_missing", "tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bazel-testlogs").mkdir()
            first = _bep_test_result("//pkg:target", output=root / "bazel-testlogs/pkg/target/shard_1_of_2/test.outputs", cached_locally=True)
            second = _bep_test_result("//pkg:target", output=None)
            second["id"]["testResult"]["shard"] = 2
            bep = root / "bep.json"
            bep.write_text(json.dumps(first) + "\n" + json.dumps(second))
            cfg = TestOptimizationDoctorTests._write_doctor_config(root, ["//pkg:target"])
            stderr = StringIO()
            with mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root / "bazel-testlogs"), "BUILD_WORKSPACE_DIRECTORY": str(root)}), redirect_stderr(stderr):
                with self.assertRaises(SystemExit):
                    doctor.main(["--config", str(cfg), "--bep-json", str(bep), "--freshness-mode=required"])
            self.assertIn("fresh", stderr.getvalue())
            self.assertNotIn("OK:", stderr.getvalue())

    def test_test_result_counter_excludes_hierarchy_and_handles_malformed_types(self):
        from topt_runtime.bep_execution import test_result_event_count
        payload = {"events": [
            {"type": "test", "content": {}},
            {"type": "span", "content": {"type": "test"}},
            {"content": {"type": "test"}},
            {"type": "test_session_end", "content": {"type": "test"}},
            {"type": {}, "content": {}},
            {"type": "test", "content": []},
            {"type": "test"},
        ]}
        self.assertEqual(3, test_result_event_count(payload))
        self.assertEqual(0, test_result_event_count({"events": []}))

    def test_doctor_core_only_payload_uses_bep_binding_when_metadata_is_optional(self):
        from test_python_tools import TestOptimizationDoctorTests
        from test_uploader_application_tools import _bep_test_result, _write_payload
        doctor = _load_module("doctor_core_only_payload", "tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / "bazel-testlogs/pkg/core/test.outputs"
            _write_payload(output, "tests", "events.json", {"events": [{"type": "test", "content": {}}]})
            bep = root / "bep.json"
            bep.write_text(json.dumps(_bep_test_result("//pkg:core", output=output)))
            cfg = TestOptimizationDoctorTests._write_doctor_config(root, [])
            config = json.loads(cfg.read_text())
            config["require_bazel_metadata"] = False
            cfg.write_text(json.dumps(config))
            with mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root / "bazel-testlogs"), "BUILD_WORKSPACE_DIRECTORY": str(root)}):
                self.assertEqual(0, doctor.main(["--config", str(cfg), "--bep-json", str(bep), "--freshness-mode=required"]))

    def test_conflicting_copied_uuid_fails_instead_of_reusing_prior_proof(self):
        doctor = _load_module("doctor_execution_conflict", "tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            first, second = Path(tmp) / "one.json", Path(tmp) / "two.json"
            first.write_text('{"started":{"uuid":"same"}}')
            second.write_text('{"started":{"uuid":"same"}}\n{"finished":{}}')
            with self.assertRaises(SystemExit):
                doctor._parse_bep_freshness([first, second])


if __name__ == "__main__":
    unittest.main()
