#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Independent announcements and completion prove what result-only scans miss."""
from copy import deepcopy
from dataclasses import replace
from io import StringIO
from contextlib import redirect_stderr
from unittest import mock
import os
from itertools import product
import json
from pathlib import Path
import tempfile
import unittest

from uploader_test_support import add_uploader_runtime_to_path, complete_bep_json
add_uploader_runtime_to_path()
from topt_runtime.bep_execution import (BepTestExecution, completed_empty_test_session,
    missing_test_shards, resolve_freshness_policy, first_bep_completeness_error)
from topt_runtime.runfiles import RunfilesResolver
from uploader_py.application import run_uploader
from uploader_py.endpoints import build_endpoints
from uploader_py.logging_utils import configure_logging
from test_python_tools import _load_module
import test_uploader_application_tools as application_tests
from test_uploader_application_tools import _bep_test_result, _write_payload


def empty_session():
    return {"events": [{"type": "test_session_end", "content": {"test_session_id": 1, "error": 0,
        "meta": {"test.session.empty_reason": "zero_tests", "test.status": "skip"},
        "metrics": {"test.exit_code": 0}}}]}


class BepTopologyTests(unittest.TestCase):
    def setUp(self):
        self.doctor = _load_module("doctor_topology", "tools/core/test_optimization_doctor.py")

    def stream(self):
        result = _bep_test_result("//pkg:test")
        return [json.loads(line) for line in complete_bep_json(json.dumps(result)).splitlines()]

    def parse(self, events, tail=""):
        with tempfile.TemporaryDirectory() as tmp:
            bep = Path(tmp) / "bep.json"
            bep.write_text("\n".join(json.dumps(e) for e in events) + tail, encoding="utf-8")
            return self.doctor._parse_bep_freshness([bep])

    def test_complete_failed_build_is_valid(self):
        events = self.stream()
        events[-1]["finished"] = {"overallSuccess": False, "exitCode": {"code": 3}}
        self.assertFalse(self.parse(events).completeness_errors)

    def test_missing_announced_result_or_summary_is_not_ignored(self):
        for field in ("testResult", "testSummary"):
            events = [e for e in self.stream() if field not in e["id"]]
            error = first_bep_completeness_error(self.parse(events).completeness_errors, {"//pkg:test"})
            self.assertIn("missing", error)

    def test_missing_result_still_detected_from_summary_without_announcement(self):
        events = self.stream()
        for e in events:
            e["children"] = [child for child in e.get("children", []) if "testResult" not in child]
        events = [e for e in events if "testResult" not in e["id"]]
        self.assertIn("topology", first_bep_completeness_error(self.parse(events).completeness_errors, {"//pkg:test"}))

    def test_stream_must_have_both_finished_and_final_message(self):
        for field in ("started", "buildFinished", "lastMessage"):
            events = self.stream()
            if field == "lastMessage":
                events[-1].pop(field)
            else:
                events = [e for e in events if field not in e["id"]]
            self.assertIn("incomplete", first_bep_completeness_error(self.parse(events).completeness_errors, set()))

    def test_malformed_tail_keeps_independent_usable_results(self):
        parsed = self.parse(self.stream(), '\n{"id":')
        self.assertEqual(1, len(parsed.executions))
        self.assertIn("invalid BEP JSON", parsed.completeness_errors[0][1])

    def test_summary_counts_and_announced_attempts_are_independent(self):
        for field, value in (("runCount", 2), ("shardCount", 2), ("totalRunCount", 2), ("attemptCount", 2), ("runCount", True)):
            with self.subTest(field=field):
                events = self.stream()
                next(e["testSummary"] for e in events if "testSummary" in e)[field] = value
                self.assertTrue(self.parse(events).completeness_errors)

    def test_unrelated_ordinary_target_topology_is_not_required(self):
        parsed = self.parse([e for e in self.stream() if "testResult" not in e["id"]])
        self.assertIsNone(first_bep_completeness_error(parsed.completeness_errors, {"//other:instrumented"}))

    def test_zero_test_marker_requires_success_and_exact_execution_binding(self):
        doc = empty_session()
        self.assertTrue(completed_empty_test_session(doc))
        identity = ("invocation", "//pkg:test", "config", 1, 1, 1)
        execution = BepTestExecution(identity, False, "PASSED", frozenset({"one/test.outputs"}))
        empty = {("//pkg:test", "one/test.outputs")}
        self.assertFalse(missing_test_shards([execution], set(), {"//pkg:test"}, empty))
        for wrong in (replace(execution, status="FAILED"), replace(execution, output_keys=frozenset({"two/test.outputs"}))):
            self.assertTrue(missing_test_shards([wrong], set(), {"//pkg:test"}, empty))
        for mutate in (lambda c: c["meta"].pop("test.session.empty_reason"),
                lambda c: c["metrics"].update({"test.exit_code": 1}), lambda c: c.update(error=1),
                lambda c: c.update(test_session_id=0), lambda c: c["meta"].update({"test.status": "pass"})):
            bad = deepcopy(doc)
            mutate(bad["events"][0]["content"])
            self.assertFalse(completed_empty_test_session(bad))
        self.assertFalse(completed_empty_test_session({"events": [{"type": "test_session_end", "content": {}}]}))

    def test_auto_policy_and_fail_on_error_matrix_processes_usable_files(self):
        for mode, fail_on_error, ci in product(("auto", "required", "optional", "disabled"), (False, True), (False, True)):
            with self.subTest(mode=mode, fail_on_error=fail_on_error, ci=ci), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                output = root / "bazel-testlogs/pkg/test/test.outputs"
                _write_payload(output, "tests", "events.json", {"events": [{"type": "test", "content": {}}]})
                (output / "bazel_target_metadata.json").write_text(json.dumps({"bazel.target": "//pkg:test"}))
                event = _bep_test_result("//pkg:test", output=output)
                records = [json.loads(line) for line in complete_bep_json(json.dumps(event)).splitlines()]
                # A result was announced but never received, independently of the usable one.
                parent = next(e for e in records if "targetCompleted" in e["id"])
                missing = deepcopy(event["id"])
                missing["testResult"]["shard"] = 2
                parent["children"].append(missing)
                bep = root / "bep.json"
                bep.write_text("\n".join(json.dumps(e) for e in records))
                report = root / "report.json"
                config = application_tests.ApplicationTests()._config(root, fail_on_error=fail_on_error,
                    allow_cached_payload_uploads=mode == "disabled", extra_environment={"CI": "1" if ci else ""},
                    extra_arguments=(f"--freshness-mode={mode}", f"--bep-json={bep}", f"--report-json={report}"))
                rc = run_uploader(config, resolver=RunfilesResolver.from_environment(cwd=root, environ={}),
                    endpoints=build_endpoints(config), logger=configure_logging(debug=False, stream=StringIO()), stream=StringIO())
                self.assertEqual(1 if mode in {"required", "auto"} else 0, rc)
                state = json.loads(report.read_text())
                self.assertEqual(1, state["files"]["succeeded"])
                self.assertEqual(mode in {"required", "auto"}, state["bep"]["strict_completeness"])

    def test_doctor_accepts_only_proven_boundary_and_respects_explicit_allowlist(self):
        for ip, module, accepted in (("example.com/app/new", "example.com/app", True),
                ("example.com/application/new", "example.com/app", False), ("example.com/app", "", False)):
            with self.subTest(ip=ip, module=module), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "test.outputs"
                _write_payload(output, "tests", "events.json", {"events": []})
                (output / "bazel_target_metadata.json").write_text(json.dumps({
                    "bazel.go.payload_selection": "full_bundle_importpath_miss", "bazel.go.importpath": ip,
                    "bazel.go.runtime_module_path": module}))
                if accepted:
                    self.doctor._validate_outputs([output], True, True, True, True)
                    with self.assertRaises(SystemExit):
                        self.doctor._validate_outputs([output], True, True, True, True, allowed_payload_selections={"module"})
                else:
                    with self.assertRaises(SystemExit):
                        self.doctor._validate_outputs([output], True, True, True, True)

    def test_crossed_retries_across_runs_match_bazel_attempt_count(self):
        results = []
        for run in (1, 2):
            for shard in (1, 2):
                for attempt in range(1, 3 if run == shard else 2):
                    event = _bep_test_result("//pkg:test", attempt=attempt)
                    event["id"]["testResult"].update(run=run, shard=shard)
                    results.append(event)
        events = [json.loads(line) for line in complete_bep_json("\n".join(json.dumps(e) for e in results)).splitlines()]
        next(e["testSummary"] for e in events if "testSummary" in e)["attemptCount"] = 3
        self.assertFalse(self.parse(events).completeness_errors)

    def test_malformed_result_payload_cannot_satisfy_topology(self):
        for bad in (None, [], "invalid"):
            with self.subTest(bad=bad):
                events = self.stream()
                next(e for e in events if "testResult" in e["id"])["testResult"] = bad
                self.assertTrue(self.parse(events).completeness_errors)

    def test_invalid_utf8_tail_preserves_valid_results_and_reports_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            bep = Path(tmp) / "bep.json"
            bep.write_bytes(("\n".join(json.dumps(e) for e in self.stream()) + "\n").encode() + b"\xff")
            parsed = self.doctor._parse_bep_freshness([bep])
            self.assertEqual(1, len(parsed.executions))
            self.assertIn("UTF-8", parsed.completeness_errors[0][1])

    def test_discovered_core_only_target_cannot_hide_missing_announced_result(self):
        from test_python_tools import TestOptimizationDoctorTests
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / "bazel-testlogs/pkg/test/shard_1_of_2/test.outputs"
            _write_payload(output, "tests", "events.json", {"events": [{"type": "test", "content": {}}]})
            good = _bep_test_result("//pkg:test", output=output)
            lost = _bep_test_result("//pkg:test")
            lost["id"]["testResult"]["shard"] = 2
            events = [json.loads(line) for line in complete_bep_json(json.dumps(good) + "\n" + json.dumps(lost)).splitlines()]
            events = [e for e in events if e.get("id", {}).get("testResult", {}).get("shard") != 2]
            bep = root / "bep.json"
            bep.write_text("\n".join(json.dumps(e) for e in events))
            cfg = TestOptimizationDoctorTests._write_doctor_config(root, [])
            data = json.loads(cfg.read_text()); data["require_bazel_metadata"] = False; cfg.write_text(json.dumps(data))
            with mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root / "bazel-testlogs"), "BUILD_WORKSPACE_DIRECTORY": str(root)}), redirect_stderr(StringIO()):
                with self.assertRaises(SystemExit):
                    self.doctor.main(["--config", str(cfg), "--bep-json", str(bep), "--freshness-mode=auto"])

    def test_invalid_configuration_identity_fails_closed(self):
        for configuration in ("config", {"id": []}, {"id": True}):
            with self.subTest(configuration=configuration), redirect_stderr(StringIO()):
                events = self.stream()
                next(e for e in events if "testResult" in e["id"])["id"]["testResult"]["configuration"] = configuration
                with self.assertRaises(SystemExit):
                    self.parse(events)

    def test_cached_retry_may_collapse_historical_attempts(self):
        events = self.stream()
        result = next(e["testResult"] for e in events if "testResult" in e["id"])
        result.update(cachedLocally=True, status="FLAKY")
        summary = next(e["testSummary"] for e in events if "testSummary" in e)
        summary.update(totalRunCount=2, attemptCount=2)
        self.assertFalse(self.parse(events).completeness_errors)

    def test_literal_nul_tail_is_not_an_internal_decode_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            bep = Path(tmp) / "bep.json"
            bep.write_bytes(("\n".join(json.dumps(e) for e in self.stream()) + "\n").encode() + b"\x00garbage\n")
            parsed = self.doctor._parse_bep_freshness([bep])
            self.assertEqual(1, len(parsed.executions))
            self.assertTrue(parsed.completeness_errors)

    def test_cached_history_cannot_hide_a_missing_fresh_shard(self):
        for remote in (False, True):
            good = _bep_test_result("//pkg:test", cached_locally=not remote, cached_remotely=remote)
            fresh = _bep_test_result("//pkg:test")
            fresh["id"]["testResult"]["shard"] = 2
            events = [json.loads(line) for line in complete_bep_json(json.dumps(good) + "\n" + json.dumps(fresh)).splitlines()]
            summary = next(e["testSummary"] for e in events if "testSummary" in e)
            summary.update(totalRunCount=4, attemptCount=3)
            self.assertFalse(self.parse(events).completeness_errors)
            missing = [e for e in events if e.get("id", {}).get("testResult", {}).get("shard") != 2]
            self.assertTrue(self.parse(missing).completeness_errors)
            summary.update(totalRunCount=1)
            self.assertTrue(self.parse(events).completeness_errors)

    def test_policy_sources_keep_their_documented_limits(self):
        for mode, source, ci in product(("auto", "required", "optional", "disabled"), ("bep", "execution_log", "none"), (False, True)):
            policy = resolve_freshness_policy(mode, source, ci=ci)
            self.assertEqual(mode == "required" or (mode == "auto" and ci), policy.source_required)
            self.assertEqual(source == "bep" and mode in {"required", "auto"}, policy.strict_bep)
