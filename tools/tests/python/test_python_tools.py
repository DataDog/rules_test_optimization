#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for repository Python tooling scripts."""

from __future__ import annotations

import ast
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import tempfile
import types
from typing import Optional
import unittest
from unittest import mock


def _runfile(rel_path: str) -> Path:
    """Internal helper for runfile behavior."""
    test_srcdir = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "")
    workspace_dir = os.environ.get("BUILD_WORKSPACE_DIRECTORY", "")
    candidates = []
    if test_srcdir and test_workspace:
        candidates.append(Path(test_srcdir) / test_workspace / rel_path)
    if test_srcdir:
        candidates.append(Path(test_srcdir) / rel_path)
    if workspace_dir:
        candidates.append(Path(workspace_dir) / rel_path)

    # Non-Bazel fallback: allow direct execution from a checked-out repository.
    # This keeps the tests usable by lightweight CI coverage probes.
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            candidates.append(candidate / rel_path)
            break

    for cand in candidates:
        if cand.exists():
            return cand

    # Manifest-mode fallback (common on Windows).
    manifest_path = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_path:
        manifest = Path(manifest_path)
        if manifest.exists():
            keys = [rel_path]
            if test_workspace:
                keys.insert(0, f"{test_workspace}/{rel_path}")
            with manifest.open("r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    key, sep, value = line.partition(" ")
                    if not sep:
                        continue
                    if key in keys and value:
                        return Path(value)

    raise FileNotFoundError(f"runfile not found: {rel_path} (checked: {candidates})")


def _load_module(name: str, rel_path: str) -> types.ModuleType:
    """Internal helper for load module behavior."""
    path = _runfile(rel_path)
    spec = importlib.util.spec_from_file_location(name, str(path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module spec for {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ValidatePayloadSchemaTests(unittest.TestCase):
    """Test case group covering ValidatePayloadSchemaTests behaviors."""
    @classmethod
    def setUpClass(cls) -> None:
        """Execute setUpClass lifecycle behavior."""
        cls.mod = _load_module(
            "validate_payload_schema_mod",
            "tools/core/validate_payload_schema.py",
        )

    def _run_main(
        self,
        schema_path: str,
        payload_path: str,
        extra_args: Optional[list[str]] = None,
    ) -> int:
        """Internal helper for run main behavior."""
        old_argv = list(self.mod.sys.argv)
        self.mod.sys.argv = [
            "validate_payload_schema.py",
            schema_path,
            payload_path,
            *(extra_args or []),
        ]
        try:
            return self.mod.main()
        finally:
            self.mod.sys.argv = old_argv

    def test_valid_and_invalid_payload(self) -> None:
        """Validate valid and invalid payload behavior."""
        schema = {
            "type": "object",
            "required": ["ok"],
            "properties": {"ok": {"type": "boolean"}},
            "additionalProperties": False,
        }
        with tempfile.TemporaryDirectory() as tmp:
            schema_path = Path(tmp) / "schema.json"
            payload_path = Path(tmp) / "payload.json"
            schema_path.write_text(json.dumps(schema), encoding="utf-8")

            payload_path.write_text(json.dumps({"ok": True}), encoding="utf-8")
            rc_valid = self._run_main(str(schema_path), str(payload_path))
            self.assertEqual(0, rc_valid)

            payload_path.write_text(json.dumps({"bad": 1}), encoding="utf-8")
            rc_invalid = self._run_main(str(schema_path), str(payload_path))
            self.assertEqual(1, rc_invalid)

    def test_safe_size_handles_missing(self) -> None:
        """Validate safe size handles missing behavior."""
        missing_path = os.path.join(
            tempfile.gettempdir(),
            "does-not-exist-validate-payload-schema",
        )
        value = self.mod._safe_size(missing_path)
        self.assertIsNone(value)

    def test_max_errors_flag_is_supported(self) -> None:
        """Validate max errors flag is supported behavior."""
        schema = {"type": "object"}
        with tempfile.TemporaryDirectory() as tmp:
            schema_path = Path(tmp) / "schema.json"
            payload_path = Path(tmp) / "payload.json"
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            payload_path.write_text(json.dumps({"ok": True}), encoding="utf-8")
            rc = self._run_main(
                str(schema_path),
                str(payload_path),
                extra_args = ["--max-errors", "3"],
            )
            self.assertEqual(0, rc)

    def test_invalid_max_errors_env_returns_usage_error(self) -> None:
        """Validate invalid max errors env returns usage error behavior."""
        schema = {"type": "object"}
        with tempfile.TemporaryDirectory() as tmp:
            schema_path = Path(tmp) / "schema.json"
            payload_path = Path(tmp) / "payload.json"
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            payload_path.write_text(json.dumps({"ok": True}), encoding="utf-8")
            with mock.patch.dict(
                os.environ,
                {"DD_TEST_OPTIMIZATION_SCHEMA_MAX_ERRORS": "not-a-number"},
            ):
                rc = self._run_main(str(schema_path), str(payload_path))
            self.assertEqual(2, rc)

    def test_missing_input_paths_return_usage_error(self) -> None:
        """Validate missing input paths return usage error behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            missing_schema = str(Path(tmp) / "missing-schema.json")
            missing_payload = str(Path(tmp) / "missing-payload.json")
            rc = self._run_main(missing_schema, missing_payload)
            self.assertEqual(2, rc)

    def test_unsupported_keywords_default_to_error(self) -> None:
        """Validate unsupported keywords default to error behavior."""
        schema = {"oneOf": [{"const": "ok"}]}
        errors: list[str] = []
        self.mod._validate("ok", schema, schema, "$", errors, 10)
        self.assertEqual(1, len(errors))
        self.assertIn("unsupported JSON Schema keyword 'oneOf'", errors[0])

    def test_unsupported_keywords_warn_mode(self) -> None:
        """Validate unsupported keywords warn mode behavior."""
        schema = {"oneOf": [{"const": "ok"}]}
        errors: list[str] = []
        stderr = io.StringIO()
        with mock.patch.object(self.mod.sys, "stderr", stderr):
            self.mod._validate(
                "ok",
                schema,
                schema,
                "$",
                errors,
                10,
                unsupported_policy = "warn",
            )
        self.assertEqual([], errors)
        self.assertIn("unsupported JSON Schema keyword 'oneOf'", stderr.getvalue())

    def test_internal_predicates_and_helpers(self) -> None:
        """Validate internal predicates and helpers behavior."""
        self.assertTrue(self.mod._is_number(3))
        self.assertTrue(self.mod._is_number(3.14))
        self.assertFalse(self.mod._is_number(True))
        self.assertFalse(self.mod._is_number("3"))

        self.assertTrue(self.mod._is_type({"a": 1}, "object"))
        self.assertTrue(self.mod._is_type([1], "array"))
        self.assertTrue(self.mod._is_type("x", "string"))
        self.assertTrue(self.mod._is_type(7, "integer"))
        self.assertFalse(self.mod._is_type(True, "integer"))
        self.assertTrue(self.mod._is_type(None, "null"))
        self.assertFalse(self.mod._is_type({}, "unknown"))

        self.assertEqual("unknown", self.mod._format_size(None))
        self.assertEqual("42", self.mod._format_size(42))
        self.assertEqual("a, b", self.mod._sample_keys({"a": 1, "b": 2}))

    def test_resolve_ref_supports_list_indices(self) -> None:
        """Validate resolve ref supports list indices behavior."""
        root = {
            "$defs": {
                "variants": [
                    {"type": "object", "required": ["ok"]},
                ],
            },
        }
        resolved = self.mod._resolve_ref(root, "#/$defs/variants/0")
        self.assertEqual({"type": "object", "required": ["ok"]}, resolved)
        with self.assertRaises(ValueError):
            self.mod._resolve_ref(root, "#/$defs/variants/2")

    def test_validate_direct_number_bounds(self) -> None:
        """Validate validate direct number bounds behavior."""
        schema = {"type": "number", "minimum": 10, "maximum": 20}
        errors: list[str] = []
        self.mod._validate(7, schema, schema, "$", errors, 10)
        self.assertIn("value 7 < minimum 10", errors[0])

        errors = []
        self.mod._validate(42, schema, schema, "$", errors, 10)
        self.assertIn("value 42 > maximum 20", errors[0])

    def test_validate_number_bounds_stops_at_max_errors(self) -> None:
        # Deliberately inconsistent schema to force both bounds to fail.
        """Validate validate number bounds stops at max errors behavior."""
        schema = {"type": "number", "minimum": 10, "maximum": 5}
        errors: list[str] = []
        self.mod._validate(7, schema, schema, "$", errors, 1)
        self.assertEqual(1, len(errors))

    def test_validate_invalid_pattern_properties_regex(self) -> None:
        """Validate validate invalid pattern properties regex behavior."""
        schema = {
            "type": "object",
            "patternProperties": {
                "[": {"type": "string"},
            },
        }
        errors: list[str] = []
        self.mod._validate({"key": "value"}, schema, schema, "$", errors, 10)
        self.assertEqual(1, len(errors))
        self.assertIn("invalid patternProperties regex", errors[0])

    def test_main_resets_stats_between_runs(self) -> None:
        """Validate main resets stats between runs behavior."""
        schema = {
            "type": "object",
            "properties": {"ok": {"type": "boolean"}},
            "required": ["ok"],
            "additionalProperties": False,
        }
        payload = {"ok": True}
        with tempfile.TemporaryDirectory() as tmp:
            schema_path = Path(tmp) / "schema.json"
            payload_path = Path(tmp) / "payload.json"
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            payload_path.write_text(json.dumps(payload), encoding="utf-8")

            rc_first = self._run_main(str(schema_path), str(payload_path))
            self.assertEqual(0, rc_first)
            nodes_first = self.mod._STATS["nodes"]
            self.assertGreater(nodes_first, 0)

            rc_second = self._run_main(str(schema_path), str(payload_path))
            self.assertEqual(0, rc_second)
            nodes_second = self.mod._STATS["nodes"]
            self.assertEqual(nodes_first, nodes_second)

    def test_parse_args_supports_max_errors(self) -> None:
        """Validate parse args supports max errors behavior."""
        parsed = self.mod._parse_args(["schema.json", "payload.json", "--max-errors", "5"])
        self.assertEqual("schema.json", parsed.schema_path)
        self.assertEqual("payload.json", parsed.payload_path)
        self.assertEqual(5, parsed.max_errors)

    def test_help_exit_returns_zero(self) -> None:
        """Validate help exit returns zero behavior."""
        with mock.patch.object(self.mod, "_parse_args", side_effect=SystemExit(0)):
            rc = self.mod.main()
        self.assertEqual(0, rc)


class TestOptimizationDoctorTests(unittest.TestCase):
    """Test case group covering TestOptimizationDoctor behaviors."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the doctor module once for focused unit tests."""
        cls.mod = _load_module(
            "test_optimization_doctor_mod",
            "tools/core/test_optimization_doctor.py",
        )

    @staticmethod
    def _write_doctor_output(root: Path, selection: str, target: str = "//pkg:target") -> Path:
        """Create a minimal Test Optimization output tree for doctor tests."""
        output = root / "pkg" / "target" / "test.outputs"
        payload_dir = output / "payloads" / "tests"
        payload_dir.mkdir(parents=True)
        (payload_dir / "span_events_1.json").write_text("{}", encoding="utf-8")
        (output / "bazel_target_metadata.json").write_text(
            json.dumps({
                "bazel.target": target,
                "bazel.go.payload_selection": selection,
            }),
            encoding="utf-8",
        )
        return output

    @staticmethod
    def _write_doctor_config(root: Path, expected_targets: list[str]) -> Path:
        """Create a minimal doctor config for runtime main() tests."""
        config = {
            "context_manifest_path": "",
            "context_manifest_short_path": "",
            "forbid_dd_git_test_env": False,
            "require_git_metadata": False,
            "expected_targets": expected_targets,
            "require_json_payloads": True,
            "require_bazel_metadata": True,
            "forbid_full_bundle_no_match": True,
            "forbid_msgpack_payloads": True,
            "allowed_payload_selections": ["module"],
            "expected_payload_selection_by_target": {},
        }
        config_path = root / "doctor.config.json"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        return config_path

    @staticmethod
    def _write_bep(path: Path, events: list[dict[str, object]]) -> None:
        """Write newline-delimited BEP JSON events."""
        path.write_text(
            "".join(json.dumps(event) + "\n" for event in events),
            encoding="utf-8",
        )

    @staticmethod
    def _bep_test_result(
        label: str,
        output: str,
        *,
        cached_locally: bool = False,
        cached_remotely: bool = False,
    ) -> dict[str, object]:
        """Return a minimal BEP TestResult event for doctor freshness tests."""
        event: dict[str, object] = {
            "id": {
                "testResult": {
                    "label": label,
                    "run": 1,
                    "shard": 1,
                    "attempt": 1,
                },
            },
            "testResult": {
                "testActionOutput": [
                    {
                        "name": "test.outputs",
                        "uri": output,
                    },
                ],
                "status": "PASSED",
            },
        }
        result = event["testResult"]
        assert isinstance(result, dict)
        if cached_locally:
            result["cachedLocally"] = True
        if cached_remotely:
            result["executionInfo"] = {"cachedRemotely": True}
        return event

    def test_parse_args_accepts_bep_freshness_flags(self) -> None:
        """Validate doctor accepts BEP freshness CLI flags passed through Bazel launchers."""
        args = self.mod._parse_args([
            "--config",
            "doctor.config.json",
            "--bep-json",
            ".topt/fresh.bep.json",
            "--freshness-source=bep",
            "--freshness-mode=required",
        ])

        self.assertEqual("doctor.config.json", args.config)
        self.assertEqual([".topt/fresh.bep.json"], args.bep_json)
        self.assertEqual("bep", args.freshness_source)
        self.assertEqual("required", args.freshness_mode)

    def test_doctor_optional_bep_without_configured_file_warns_and_continues(self) -> None:
        """Validate optional BEP source without a file preserves local doctor validation."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_doctor_output(root, "module", "//pkg:target")
            config_path = self._write_doctor_config(root, ["//pkg:target"])
            stderr = io.StringIO()
            with (
                mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root), "BUILD_WORKSPACE_DIRECTORY": str(root)}),
                mock.patch("sys.stderr", stderr),
            ):
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--freshness-source=bep",
                    "--freshness-mode=optional",
                ])

        self.assertEqual(0, rc)
        self.assertIn("BEP freshness source was selected but no BEP JSON file was configured", stderr.getvalue())

    def test_doctor_optional_missing_bep_file_warns_and_continues(self) -> None:
        """Validate optional configured missing BEP keeps historical local doctor behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_doctor_output(root, "module", "//pkg:target")
            config_path = self._write_doctor_config(root, ["//pkg:target"])
            stderr = io.StringIO()
            with (
                mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root), "BUILD_WORKSPACE_DIRECTORY": str(root)}),
                mock.patch("sys.stderr", stderr),
            ):
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--bep-json",
                    str(root / "missing.bep.json"),
                    "--freshness-source=bep",
                    "--freshness-mode=optional",
                ])

        self.assertEqual(0, rc)
        self.assertIn("warning: BEP JSON file not found", stderr.getvalue())

    def test_doctor_optional_malformed_bep_file_warns_and_continues(self) -> None:
        """Validate optional configured malformed BEP keeps historical local doctor behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_doctor_output(root, "module", "//pkg:target")
            config_path = self._write_doctor_config(root, ["//pkg:target"])
            malformed_bep = root / "malformed.bep.json"
            malformed_bep.write_text("{not-json\n", encoding="utf-8")
            stderr = io.StringIO()
            with (
                mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root), "BUILD_WORKSPACE_DIRECTORY": str(root)}),
                mock.patch("sys.stderr", stderr),
            ):
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--bep-json",
                    str(malformed_bep),
                    "--freshness-source=bep",
                    "--freshness-mode=optional",
                ])

        self.assertEqual(0, rc)
        self.assertIn("warning: invalid BEP JSON", stderr.getvalue())

    def test_bep_output_key_normalizes_file_uri_and_nested_outputs(self) -> None:
        """Validate BEP paths map to concrete bazel-testlogs test.outputs directories."""
        key = self.mod._bep_test_output_key(
            "file:///tmp/execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/"
            "shard_1_of_2/attempt_1/test.outputs/payloads/tests/span_events_1.json"
        )

        self.assertEqual("pkg/target/shard_1_of_2/attempt_1/test.outputs", key)

    def test_bep_output_key_maps_outputs_zip_to_containing_test_outputs(self) -> None:
        """Validate BEP outputs.zip references map to the containing test.outputs directory."""
        key = self.mod._bep_test_output_key(
            r"C:\tmp\execroot\main\bazel-out\x64_windows-fastbuild\testlogs\pkg\target\test.outputs\outputs.zip"
        )
        sibling_key = self.mod._bep_test_output_key(
            "file:///tmp/execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/outputs.zip"
        )
        windows_sibling_key = self.mod._bep_test_output_key(
            r"C:\tmp\execroot\main\bazel-out\x64_windows-fastbuild\testlogs\pkg\target\outputs.zip"
        )

        self.assertEqual("pkg/target/test.outputs", key)
        self.assertEqual("pkg/target/test.outputs", sibling_key)
        self.assertEqual("pkg/target/test.outputs", windows_sibling_key)

    def test_bep_output_key_maps_test_log_and_xml_to_sibling_outputs(self) -> None:
        """Validate real Bazel BEP test.log/test.xml references map to sibling test.outputs."""
        log_key = self.mod._bep_test_output_key(
            "file:///tmp/workspace/bazel-testlogs/pkg/target/test.log"
        )
        xml_key = self.mod._bep_test_output_key(
            "file:///tmp/execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.xml"
        )

        self.assertEqual("pkg/target/test.outputs", log_key)
        self.assertEqual("pkg/target/test.outputs", xml_key)

    def test_bep_file_reference_candidates_support_path_prefix(self) -> None:
        """Validate direct BEP File pathPrefix/name objects reconstruct a local path."""
        candidates = self.mod._bep_file_reference_candidates({
            "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
            "name": "test.log",
        })

        self.assertIn("bazel-out/k8-fastbuild/testlogs/pkg/target/test.log", candidates)
        self.assertEqual(
            "pkg/target/test.outputs",
            self.mod._bep_test_output_key(candidates[-1]),
        )

    def test_parse_bep_eligible_outputs_skips_cached_results(self) -> None:
        """Validate BEP freshness keeps only non-cached concrete output mappings."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bep = tmp_path / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    self._bep_test_result(
                        "//pkg:target",
                        "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.outputs",
                    ),
                    self._bep_test_result(
                        "//pkg:target",
                        "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/cached_local/test.outputs",
                        cached_locally=True,
                    ),
                    self._bep_test_result(
                        "//pkg:target",
                        "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/cached_remote/test.outputs",
                        cached_remotely=True,
                    ),
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//pkg:target", "pkg/target/test.outputs")}, freshness.eligible_outputs)
        self.assertIn(("//pkg:target", "pkg/cached_local/test.outputs"), freshness.cached_outputs)
        self.assertIn(("//pkg:target", "pkg/cached_remote/test.outputs"), freshness.cached_outputs)

    def test_parse_bep_eligible_outputs_accepts_real_test_log_outputs(self) -> None:
        """Validate real Bazel TestResult log outputs authorize their sibling payload directory."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            bep = tmp_path / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "testActionOutput": [
                                {
                                    "name": "test.log",
                                    "uri": "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.log",
                                },
                                {
                                    "name": "test.xml",
                                    "uri": "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.xml",
                                },
                            ],
                            "status": "PASSED",
                        },
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//pkg:target", "pkg/target/test.outputs")}, freshness.eligible_outputs)
        self.assertEqual(set(), freshness.cached_outputs)

    def test_parse_bep_freshness_accepts_checked_in_real_log_xml_fixture(self) -> None:
        """Validate checked-in real-shaped BEP log/XML outputs stay parser-compatible."""
        bep = _runfile("tools/tests/python/fixtures/bep_fresh_log_xml.ndjson")

        freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//pkg:target", "pkg/target/test.outputs")}, freshness.eligible_outputs)
        self.assertEqual(set(), freshness.cached_outputs)
        self.assertEqual([], freshness.remote_only_outputs)

    def test_parse_bep_freshness_accepts_checked_in_cached_and_snake_case_fixtures(self) -> None:
        """Validate checked-in cached and snake_case BEP variants stay parser-compatible."""
        cached = _runfile("tools/tests/python/fixtures/bep_cached_local.ndjson")
        snake_case = _runfile("tools/tests/python/fixtures/bep_snake_case_remote_cached.ndjson")

        freshness = self.mod._parse_bep_freshness([cached, snake_case])

        self.assertEqual(set(), freshness.eligible_outputs)
        self.assertIn(("//pkg:target", "pkg/target/test.outputs"), freshness.cached_outputs)
        self.assertIn(("//pkg:target", "pkg/remote_cached/test.outputs"), freshness.cached_outputs)
        self.assertEqual(1, len(freshness.remote_only_outputs))
        self.assertEqual("//pkg:remote_only", freshness.remote_only_outputs[0].label)

    def test_parse_bep_freshness_accepts_sanitized_captured_bazel_fixtures(self) -> None:
        """Validate sanitized real Bazel BEP fixtures keep fresh and cached semantics."""
        fresh = _runfile("tools/tests/python/fixtures/bep_captured_bazelw_wrapper_fresh.ndjson")
        cached = _runfile("tools/tests/python/fixtures/bep_captured_bazelw_wrapper_cached.ndjson")

        fresh_state = self.mod._parse_bep_freshness([fresh])
        cached_state = self.mod._parse_bep_freshness([cached])

        output_key = "tools/tests/python/bazelw_wrapper_test/test.outputs"
        self.assertEqual(
            {("//tools/tests/python:bazelw_wrapper_test", output_key)},
            fresh_state.eligible_outputs,
        )
        self.assertEqual(set(), fresh_state.cached_outputs)
        self.assertEqual(set(), cached_state.eligible_outputs)
        self.assertEqual(
            {("//tools/tests/python:bazelw_wrapper_test", output_key)},
            cached_state.cached_outputs,
        )

    def test_checked_in_bep_fixtures_are_sanitized(self) -> None:
        """Validate checked-in BEP fixtures do not contain local secrets or raw host paths."""
        fixture_root = _runfile("tools/tests/python/fixtures")
        denied_patterns = [
            r"DD_API_KEY",
            r"OPENAI_API_KEY",
            r"(?i)api[_-]?key",
            r"(?i)secret",
            r"(?i)token",
            r"/Users/",
            r"/private/",
            r"/var/folders/",
            r"dd-source",
        ]

        for fixture in sorted(fixture_root.glob("bep_*.ndjson")):
            text = fixture.read_text(encoding="utf-8")
            for pattern in denied_patterns:
                self.assertIsNone(
                    re.search(pattern, text),
                    f"{fixture} contains unsanitized BEP content matching {pattern!r}",
                )

    def test_parse_bep_freshness_rejects_conflicting_output_state(self) -> None:
        """Validate overlapping BEP files cannot report the same output as fresh and cached."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fresh_bep = tmp_path / "fresh.bep.json"
            cached_bep = tmp_path / "cached.bep.json"
            output = "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.log"
            self._write_bep(fresh_bep, [self._bep_test_result("//pkg:target", output)])
            self._write_bep(cached_bep, [self._bep_test_result("//pkg:target", output, cached_locally=True)])

            with self.assertRaises(SystemExit):
                self.mod._parse_bep_freshness([fresh_bep, cached_bep])

    def test_parse_bep_freshness_records_remote_only_outputs(self) -> None:
        """Validate required mode can fail before local scanning for remote-only outputs."""
        with tempfile.TemporaryDirectory() as tmp:
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    self._bep_test_result(
                        "//pkg:target",
                        "bytestream://remote-cas/blobs/deadbeef/123",
                    ),
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual([], sorted(freshness.eligible_outputs))
        self.assertEqual(1, len(freshness.remote_only_outputs))
        self.assertEqual("//pkg:target", freshness.remote_only_outputs[0].label)

    def test_parse_bep_freshness_records_remote_only_outputs_with_local_log(self) -> None:
        """Validate local logs do not hide remote-only undeclared outputs."""
        with tempfile.TemporaryDirectory() as tmp:
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.log",
                                    "uri": "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.log",
                                },
                                {
                                    "name": "test.outputs",
                                    "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                                },
                            ],
                        },
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual(set(), freshness.eligible_outputs)
        self.assertEqual(1, len(freshness.remote_only_outputs))
        self.assertEqual("//pkg:target", freshness.remote_only_outputs[0].label)

    def test_parse_bep_freshness_ignores_diagnostic_remote_uri_with_local_output(self) -> None:
        """Validate unrelated remote diagnostic artifacts do not block a mapped local output."""
        with tempfile.TemporaryDirectory() as tmp:
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.log",
                                    "uri": "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.log",
                                },
                                {
                                    "name": "diagnostic.remote",
                                    "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                                },
                            ],
                        },
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//pkg:target", "pkg/target/test.outputs")}, freshness.eligible_outputs)
        self.assertEqual([], freshness.remote_only_outputs)

    def test_parse_bep_freshness_records_remote_outputs_zip_with_local_log(self) -> None:
        """Validate remote outputs.zip overrides a local log/xml sibling mapping."""
        with tempfile.TemporaryDirectory() as tmp:
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.log",
                                    "uri": "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.log",
                                },
                                {
                                    "name": "outputs.zip",
                                    "uri": "bytestream://remote-cas/blobs/feedface/456",
                                },
                            ],
                        },
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual(set(), freshness.eligible_outputs)
        self.assertEqual(1, len(freshness.remote_only_outputs))
        self.assertEqual("//pkg:target", freshness.remote_only_outputs[0].label)

    def test_parse_bep_freshness_records_missing_output_mappings(self) -> None:
        """Validate strict freshness can reject fresh BEP results without output paths."""
        with tempfile.TemporaryDirectory() as tmp:
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {"status": "PASSED", "testActionOutput": []},
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual(set(), freshness.eligible_outputs)
        self.assertEqual({"//pkg:target"}, freshness.missing_output_mappings)

    def test_expected_target_requires_fresh_bep_match(self) -> None:
        """Validate strict doctor freshness rejects expected targets missing from BEP."""
        with tempfile.TemporaryDirectory() as tmp:
            output = self._write_doctor_output(Path(tmp), "module", "//pkg:target")
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    self._bep_test_result(
                        "//pkg:target",
                        "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/other/test.outputs",
                    ),
                ],
            )
            freshness = self.mod._parse_bep_freshness([bep])

            with self.assertRaises(SystemExit):
                self.mod._validate_expected_target_bep_freshness(
                    [output],
                    {"//pkg:target"},
                    freshness,
                    required=True,
                )

    def test_expected_target_rejects_cached_bep_match(self) -> None:
        """Validate strict doctor freshness rejects expected targets served from cache."""
        with tempfile.TemporaryDirectory() as tmp:
            output = self._write_doctor_output(Path(tmp), "module", "//pkg:target")
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    self._bep_test_result(
                        "//pkg:target",
                        "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.outputs",
                        cached_locally=True,
                    ),
                ],
            )
            freshness = self.mod._parse_bep_freshness([bep])

            with self.assertRaises(SystemExit):
                self.mod._validate_expected_target_bep_freshness(
                    [output],
                    {"//pkg:target"},
                    freshness,
                    required=True,
                )

    def test_expected_target_accepts_fresh_bep_match(self) -> None:
        """Validate strict doctor freshness accepts expected targets with fresh BEP outputs."""
        with tempfile.TemporaryDirectory() as tmp:
            output = self._write_doctor_output(Path(tmp), "module", "//pkg:target")
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    self._bep_test_result(
                        "//pkg:target",
                        "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.outputs",
                    ),
                ],
            )
            freshness = self.mod._parse_bep_freshness([bep])

            self.mod._validate_expected_target_bep_freshness(
                [output],
                {"//pkg:target"},
                freshness,
                required=True,
            )

    def test_expected_target_rejects_missing_metadata_in_bep_required_mode(self) -> None:
        """Validate BEP required mode does not authorize outputs without metadata."""
        with tempfile.TemporaryDirectory() as tmp:
            output = self._write_doctor_output(Path(tmp), "module", "//pkg:target")
            (output / "bazel_target_metadata.json").unlink()
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    self._bep_test_result(
                        "//pkg:target",
                        "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.outputs",
                    ),
                ],
            )
            freshness = self.mod._parse_bep_freshness([bep])

            with self.assertRaises(SystemExit):
                self.mod._validate_expected_target_bep_freshness(
                    [output],
                    {"//pkg:target"},
                    freshness,
                    required=True,
                )

    def test_expected_target_filters_stale_extra_outputs_before_payload_validation(self) -> None:
        """Validate strict BEP doctor checks only outputs from the current invocation."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fresh_output = self._write_doctor_output(root, "module", "//pkg:target")
            stale_output = root / "pkg" / "target" / "attempt_2" / "test.outputs"
            stale_output.mkdir(parents=True)
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    self._bep_test_result(
                        "//pkg:target",
                        "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.outputs",
                    ),
                ],
            )
            freshness = self.mod._parse_bep_freshness([bep])

            selected_outputs = self.mod._validate_expected_target_bep_freshness(
                [fresh_output, stale_output],
                {"//pkg:target"},
                freshness,
                required=True,
            )

            self.assertEqual([fresh_output], selected_outputs)
            self.mod._validate_outputs(selected_outputs, True, True, True, True)

    def test_doctor_required_bep_discovery_rejects_cached_only_output(self) -> None:
        """Validate BEP required mode is strict even without configured expected targets."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_doctor_output(root, "module", "//pkg:target")
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    self._bep_test_result(
                        "//pkg:target",
                        "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.outputs",
                        cached_locally=True,
                    ),
                ],
            )
            stderr = io.StringIO()

            with (
                mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root), "BUILD_WORKSPACE_DIRECTORY": str(root)}),
                mock.patch("sys.stderr", stderr),
            ):
                with self.assertRaises(SystemExit) as raised:
                    self.mod.main([
                        "--config",
                        str(config_path),
                        "--bep-json",
                        str(bep),
                        "--freshness-source=bep",
                        "--freshness-mode=required",
                    ])

        self.assertEqual(1, raised.exception.code)
        self.assertIn("BEP required freshness did not authorize", stderr.getvalue())

    def test_doctor_required_bep_discovery_accepts_fresh_output(self) -> None:
        """Validate documented BEP required doctor flow works without expected targets."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_doctor_output(root, "module", "//pkg:target")
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    self._bep_test_result(
                        "//pkg:target",
                        "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.outputs",
                    ),
                ],
            )

            with mock.patch.dict(
                os.environ,
                {"TESTLOGS_DIR": str(root), "BUILD_WORKSPACE_DIRECTORY": str(root)},
            ):
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                ])

        self.assertEqual(0, rc)

    def test_expected_target_output_mapping(self) -> None:
        """Validate local Bazel labels map to bazel-testlogs output dirs."""
        root = Path("/tmp/bazel-testlogs")
        self.assertEqual(
            root / "target",
            self.mod._expected_target_root(root, "//:target"),
        )
        self.assertEqual(
            root / "pkg" / "sub" / "target",
            self.mod._expected_target_root(root, "//pkg/sub:target"),
        )

    def test_expected_target_rejects_external_label(self) -> None:
        """Validate external labels are rejected before path mapping."""
        with self.assertRaises(SystemExit):
            self.mod._expected_target_root(Path("/tmp/bazel-testlogs"), "@repo//pkg:test")

    def test_expected_target_outputs_discovers_nested_runs(self) -> None:
        """Validate expected targets accept retry and shard output layouts."""
        with tempfile.TemporaryDirectory() as tmp:
            testlogs = Path(tmp) / "bazel-testlogs"
            nested = testlogs / "pkg" / "target" / "shard_1_of_2" / "attempt_1" / "test.outputs"
            nested.mkdir(parents=True)

            self.assertEqual([nested], self.mod._expected_target_outputs(testlogs, "//pkg:target"))

    def test_expected_target_outputs_explains_missing_remote_outputs(self) -> None:
        """Validate expected target failures explain test execution and remote output download requirements."""
        with tempfile.TemporaryDirectory() as tmp:
            testlogs = Path(tmp) / "bazel-testlogs"
            testlogs.mkdir()

            stderr = io.StringIO()
            with self.assertRaises(SystemExit), mock.patch("sys.stderr", stderr):
                self.mod._expected_target_outputs(testlogs, "//pkg:target")
            self.assertIn("Run this exact instrumented test target before running the doctor", stderr.getvalue())
            self.assertIn("build-only", stderr.getvalue())
            self.assertIn("wrapper-only", stderr.getvalue())
            self.assertIn("--remote_download_outputs=all", stderr.getvalue())

    def test_validate_git_metadata_requires_core_tags(self) -> None:
        """Validate context.json must contain git metadata used by enrichment."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            context = tmp_path / "context.json"
            manifest = tmp_path / "manifest.txt"
            context.write_text(
                json.dumps({
                    "git.repository_url": "https://github.com/acme/repo.git",
                    "git.commit.sha": "abc123",
                    "git.branch": "main",
                }),
                encoding="utf-8",
            )
            manifest.write_text(f"test_optimization_data\tctx\t{context}\n", encoding="utf-8")
            self.mod._validate_git_metadata(manifest)

    def test_validate_outputs_rejects_full_bundle_no_match(self) -> None:
        """Validate invalid Go payload selection fails before upload."""
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "pkg" / "target" / "test.outputs"
            payload_dir = output / "payloads" / "tests"
            payload_dir.mkdir(parents=True)
            (payload_dir / "span_events_1.json").write_text("{}", encoding="utf-8")
            (output / "bazel_target_metadata.json").write_text(
                json.dumps({"bazel.go.payload_selection": "full_bundle_no_match"}),
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                self.mod._validate_outputs([output], True, True, True, True)

    def test_validate_outputs_accepts_full_bundle_no_match_when_allowed(self) -> None:
        """Validate full_bundle_no_match is a real doctor opt-out for known fallback scenarios."""
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "pkg" / "target" / "test.outputs"
            payload_dir = output / "payloads" / "tests"
            payload_dir.mkdir(parents=True)
            (payload_dir / "span_events_1.json").write_text("{}", encoding="utf-8")
            (output / "bazel_target_metadata.json").write_text(
                json.dumps({"bazel.go.payload_selection": "full_bundle_no_match"}),
                encoding="utf-8",
            )
            self.mod._validate_outputs([output], True, True, False, True)

    def test_validate_outputs_rejects_unknown_payload_selection(self) -> None:
        """Validate Go payload selection is limited to known safe states."""
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "pkg" / "target" / "test.outputs"
            payload_dir = output / "payloads" / "tests"
            payload_dir.mkdir(parents=True)
            (payload_dir / "span_events_1.json").write_text("{}", encoding="utf-8")
            (output / "bazel_target_metadata.json").write_text(
                json.dumps({"bazel.go.payload_selection": "unexpected"}),
                encoding="utf-8",
            )
            with self.assertRaises(SystemExit):
                self.mod._validate_outputs([output], True, True, True, True)

    def test_validate_outputs_accepts_known_payload_selection(self) -> None:
        """Validate known Go payload selection values pass the doctor."""
        for selection in ["module", "module_override", "full_bundle_disabled"]:
            with self.subTest(selection=selection):
                with tempfile.TemporaryDirectory() as tmp:
                    output = Path(tmp) / "pkg" / "target" / "test.outputs"
                    payload_dir = output / "payloads" / "tests"
                    payload_dir.mkdir(parents=True)
                    (payload_dir / "span_events_1.json").write_text("{}", encoding="utf-8")
                    (output / "bazel_target_metadata.json").write_text(
                        json.dumps({"bazel.go.payload_selection": selection}),
                        encoding="utf-8",
                    )
                    self.mod._validate_outputs([output], True, True, True, True)

    def test_validate_outputs_returns_payload_selection_summary(self) -> None:
        """Validate the doctor reports payload-selection counts for operator diagnostics."""
        with tempfile.TemporaryDirectory() as tmp:
            output = self._write_doctor_output(Path(tmp), "module_override")

            summary = self.mod._validate_outputs([output], True, True, True, True)

            self.assertEqual({"module_override": 1}, summary)
            self.assertEqual("module_override=1", self.mod._format_selection_summary(summary))

    def test_validate_outputs_rejects_selection_outside_allowlist(self) -> None:
        """Validate explicit allowed_payload_selections narrows accepted states."""
        with tempfile.TemporaryDirectory() as tmp:
            output = self._write_doctor_output(Path(tmp), "full_bundle_disabled")

            with self.assertRaises(SystemExit):
                self.mod._validate_outputs(
                    [output],
                    True,
                    True,
                    True,
                    True,
                    allowed_payload_selections={"module"},
                )

    def test_validate_outputs_checks_expected_selection_by_target(self) -> None:
        """Validate target-specific payload-selection expectations catch onboarding drift."""
        with tempfile.TemporaryDirectory() as tmp:
            output = self._write_doctor_output(Path(tmp), "module_override", "//pkg:target")

            self.mod._validate_outputs(
                [output],
                True,
                True,
                True,
                True,
                expected_payload_selection_by_target={"//pkg:target": "module_override"},
            )
            with self.assertRaises(SystemExit):
                self.mod._validate_outputs(
                    [output],
                    True,
                    True,
                    True,
                    True,
                    expected_payload_selection_by_target={"//pkg:target": "module"},
                )

    def test_validate_outputs_rejects_msgpack_payloads(self) -> None:
        """Validate raw msgpack payload files fail the doctor by default."""
        for filename in ["span_events_1.msgpack", "span_events_1.msgpack.gz"]:
            with self.subTest(filename=filename):
                with tempfile.TemporaryDirectory() as tmp:
                    output = Path(tmp) / "pkg" / "target" / "test.outputs"
                    payload_dir = output / "payloads" / "tests"
                    payload_dir.mkdir(parents=True)
                    (payload_dir / filename).write_bytes(b"msgpack")
                    (output / "bazel_target_metadata.json").write_text("{}", encoding="utf-8")
                    with self.assertRaises(SystemExit):
                        self.mod._validate_outputs([output], False, True, True, True)

    def test_validate_outputs_rejects_msgpack_payloads_when_json_exists(self) -> None:
        """Validate raw msgpack files fail even when a test also emitted JSON payloads."""
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "pkg" / "target" / "test.outputs"
            payload_dir = output / "payloads" / "tests"
            payload_dir.mkdir(parents=True)
            (payload_dir / "span_events_1.json").write_text("{}", encoding="utf-8")
            (payload_dir / "span_events_1.msgpack").write_bytes(b"msgpack")
            (output / "bazel_target_metadata.json").write_text("{}", encoding="utf-8")
            with self.assertRaises(SystemExit):
                self.mod._validate_outputs([output], True, True, True, True)

    def test_validate_outputs_keeps_rejecting_invalid_json(self) -> None:
        """Validate malformed JSON payloads remain a doctor failure."""
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "pkg" / "target" / "test.outputs"
            payload_dir = output / "payloads" / "tests"
            payload_dir.mkdir(parents=True)
            (payload_dir / "span_events_1.json").write_text("{", encoding="utf-8")
            (output / "bazel_target_metadata.json").write_text("{}", encoding="utf-8")
            with self.assertRaises(SystemExit):
                self.mod._validate_outputs([output], True, True, True, True)

    def test_global_discovery_ignores_plain_bazel_tests(self) -> None:
        """Validate discovery skips non-instrumented control test outputs."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plain = root / "plain" / "go_default_test" / "test.outputs"
            plain.mkdir(parents=True)

            instrumented = root / "svc" / "go_default_test" / "test.outputs"
            payload_dir = instrumented / "payloads" / "tests"
            payload_dir.mkdir(parents=True)
            (payload_dir / "span_events_1.json").write_text("{}", encoding="utf-8")

            self.assertEqual([instrumented], self.mod._discover_candidate_output_dirs(root))

    def test_global_discovery_includes_msgpack_only_outputs(self) -> None:
        """Validate msgpack-only outputs are still discovered so the doctor can reject them."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / "svc" / "go_default_test" / "test.outputs"
            payload_dir = output / "payloads" / "tests"
            payload_dir.mkdir(parents=True)
            (payload_dir / "span_events_1.msgpack").write_bytes(b"msgpack")

            self.assertEqual([output], self.mod._discover_candidate_output_dirs(root))

    def test_bazelrc_validation_ignores_comments(self) -> None:
        """Validate commented DD_GIT test_env examples are not active config."""
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            (workspace / ".bazelrc").write_text(
                "# test --test_env=DD_" "GIT_BRANCH=main\n"
                "test --test_env=TZ=UTC # --test_env=DD_" "GIT_COMMIT_SHA=abc\n",
                encoding="utf-8",
            )
            self.mod._validate_bazelrc(workspace)

    def test_bazelrc_validation_rejects_upload_credentials_in_test_env(self) -> None:
        """Validate upload credentials and endpoints are not forwarded to tests."""
        forbidden = [
            "DD_GIT_BRANCH",
            "DD_API_KEY",
            "DD_SITE",
            "DD_TEST_OPTIMIZATION_AGENT_URL",
            "DD_TEST_OPTIMIZATION_AGENTLESS_URL",
        ]
        for env_name in forbidden:
            with self.subTest(env_name=env_name):
                with tempfile.TemporaryDirectory() as tmp:
                    workspace = Path(tmp)
                    (workspace / ".bazelrc").write_text(
                        f"test:test-optimization --test_env={env_name}\n",
                        encoding="utf-8",
                    )
                    with self.assertRaises(SystemExit):
                        self.mod._validate_bazelrc(workspace)


class TestOptimizationDoctorLauncherTests(unittest.TestCase):
    """Test case group covering generated doctor launchers."""

    def test_launchers_forward_doctor_cli_args(self) -> None:
        """Validate generated launchers pass BEP freshness CLI args through to the runtime."""
        doctor_rule = _runfile("tools/core/test_optimization_doctor.bzl").read_text(encoding="utf-8")

        self.assertIn('exec "$PYTHON_BIN" "$RUNTIME_PATH" --config "$CONFIG_PATH" "$@"', doctor_rule)
        self.assertIn("& $PythonBin $RuntimePath --config $ConfigPath @args", doctor_rule)
        self.assertIn('-File "%%SCRIPT_DIR%%%s" %%*', doctor_rule)

    def test_windows_launcher_resolves_powershell_next_to_batch(self) -> None:
        """Validate the Windows launcher resolves the generated PowerShell script next to the batch file."""
        doctor_rule = _runfile("tools/core/test_optimization_doctor.bzl").read_text(encoding="utf-8")

        self.assertIn('set "SCRIPT_DIR=%%~dp0"', doctor_rule)
        self.assertIn('-File "%%SCRIPT_DIR%%%s"', doctor_rule)
        self.assertIn("% ps_file.basename", doctor_rule)
        self.assertIn('$candidates.Add("_main/$stripped")', doctor_rule)
        self.assertIn(".EndsWith(\"/$candidate\", [System.StringComparison]::Ordinal)", doctor_rule)
        self.assertIn("$scriptBase.bat.runfiles_manifest", doctor_rule)
        self.assertIn('Join-Path $runfilesDir "MANIFEST"', doctor_rule)
        self.assertNotIn("RUNFILES_MANIFEST_FILE -and (Test-Path", doctor_rule)
        self.assertNotIn("% ps_file.path,\n    )\n\n    is_windows", doctor_rule)


class TestOptimizationDoctorRuntimeTests(unittest.TestCase):
    """Test case group covering the doctor Python runtime."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the doctor runtime once for runtime helper tests."""
        cls.mod = _load_module(
            "test_optimization_doctor_runtime_mod",
            "tools/core/test_optimization_doctor.py",
        )

    def test_context_manifest_falls_back_to_config_sibling(self) -> None:
        """Validate context manifest resolution when Windows omits runfiles env vars."""
        with tempfile.TemporaryDirectory() as tmp:
            config_path = Path(tmp) / "dd_test_optimization_doctor.config.json"
            manifest_path = Path(tmp) / "dd_test_optimization_doctor.context_manifest"
            manifest_path.write_text(
                "test_optimization_data\tcontext.json\texternal/repo/context.json\n",
                encoding="utf-8",
            )
            config = {
                "context_manifest_path": "bazel-out/x64_windows-fastbuild/bin/dd_test_optimization_doctor.context_manifest",
                "context_manifest_short_path": "dd_test_optimization_doctor.context_manifest",
            }

            resolved = self.mod._resolve_configured_context_manifest(config, config_path)

            self.assertEqual(manifest_path.resolve(), resolved)

    def test_runfile_candidates_normalize_windows_artifact_paths(self) -> None:
        """Validate Windows-style artifact paths resolve to Bazel runfile variants."""
        candidates = self.mod._runfile_candidate_strings(r"external\repo\.testoptimization\context.json")

        self.assertIn("external/repo/.testoptimization/context.json", candidates)
        self.assertIn("repo/.testoptimization/context.json", candidates)

    def test_runfile_resolution_uses_execroot_for_external_artifacts(self) -> None:
        """Validate execroot-relative context paths resolve without runfiles env vars."""
        with tempfile.TemporaryDirectory() as tmp:
            execroot = Path(tmp) / "execroot" / "_main"
            context_path = execroot / "external" / "repo" / ".testoptimization" / "context.json"
            context_path.parent.mkdir(parents=True)
            context_path.write_text("{}", encoding="utf-8")

            with mock.patch.dict(os.environ, {self.mod.DOCTOR_EXECROOT_ENV: str(execroot)}, clear=False):
                resolved = self.mod._resolve_runfile_path(
                    [r"external\repo\.testoptimization\context.json"],
                )

            self.assertEqual(context_path.resolve(), resolved)

    def test_runfile_resolution_uses_execroot_for_short_external_artifacts(self) -> None:
        """Validate short external context paths resolve through the execroot external directory."""
        with tempfile.TemporaryDirectory() as tmp:
            execroot = Path(tmp) / "execroot" / "_main"
            context_path = execroot / "external" / "repo" / ".testoptimization" / "context.json"
            context_path.parent.mkdir(parents=True)
            context_path.write_text("{}", encoding="utf-8")

            with mock.patch.dict(os.environ, {self.mod.DOCTOR_EXECROOT_ENV: str(execroot)}, clear=False):
                resolved = self.mod._resolve_runfile_path(
                    [r"..\repo\.testoptimization\context.json"],
                )

            self.assertEqual(context_path.resolve(), resolved)

    def test_infer_bazel_execroot_from_generated_config(self) -> None:
        """Validate execroot inference from a generated Bazel config path."""
        with tempfile.TemporaryDirectory() as tmp:
            execroot = Path(tmp) / "execroot" / "_main"
            (execroot / "external").mkdir(parents=True)
            config_path = execroot / "bazel-out" / "x64_windows-fastbuild" / "bin" / "doctor.config.json"
            config_path.parent.mkdir(parents=True)
            config_path.write_text("{}", encoding="utf-8")

            self.assertEqual(execroot.resolve(), self.mod._infer_bazel_execroot(config_path))


class CheckSchemaParserParityTests(unittest.TestCase):
    """Test case group covering CheckSchemaParserParityTests behaviors."""
    @classmethod
    def setUpClass(cls) -> None:
        """Execute setUpClass lifecycle behavior."""
        cls.mod = _load_module(
            "check_schema_parser_parity_mod",
            "tools/core/schemas/check_schema_parser_parity.py",
        )

    def test_main_success_when_parsers_match(self) -> None:
        """Validate main success when parsers match behavior."""
        yaml_path = Path("/tmp/fake-agentless-schema.yaml")
        with mock.patch.object(self.mod, "_default_yaml_path", return_value=yaml_path), mock.patch.object(
            self.mod,
            "_load_yaml_with_pyyaml",
            return_value={"ok": True},
        ), mock.patch.object(
            self.mod,
            "_load_yaml_with_ruby",
            return_value={"ok": True},
        ):
            rc = self.mod.main()
        self.assertEqual(0, rc)

    def test_main_returns_mismatch_error(self) -> None:
        """Validate main returns mismatch error behavior."""
        yaml_path = Path("/tmp/fake-agentless-schema.yaml")
        with mock.patch.object(self.mod, "_default_yaml_path", return_value=yaml_path), mock.patch.object(
            self.mod,
            "_load_yaml_with_pyyaml",
            return_value={"ok": True},
        ), mock.patch.object(
            self.mod,
            "_load_yaml_with_ruby",
            return_value={"ok": False},
        ):
            rc = self.mod.main()
        self.assertEqual(1, rc)

    def test_main_returns_runtime_error_when_pyyaml_fails(self) -> None:
        """Validate main returns runtime error when pyyaml fails behavior."""
        yaml_path = Path("/tmp/fake-agentless-schema.yaml")
        with mock.patch.object(self.mod, "_default_yaml_path", return_value=yaml_path), mock.patch.object(
            self.mod,
            "_load_yaml_with_pyyaml",
            side_effect=RuntimeError("missing pyyaml"),
        ):
            rc = self.mod.main()
        self.assertEqual(2, rc)


class SyncAgentlessSchemaTests(unittest.TestCase):
    """Test case group covering SyncAgentlessSchemaTests behaviors."""
    @classmethod
    def setUpClass(cls) -> None:
        """Execute setUpClass lifecycle behavior."""
        cls.mod = _load_module(
            "sync_agentless_schema_mod",
            "tools/core/schemas/sync_agentless_schema.py",
        )

    def test_render_json_trailing_newline(self) -> None:
        """Validate render json trailing newline behavior."""
        out = self.mod.render_json({"a": 1})
        self.assertTrue(out.endswith("\n"))
        self.assertIn('"a": 1', out)
        self.assertEqual({"a": 1}, json.loads(out))

    def test_load_yaml_prefers_pyyaml_and_falls_back_to_ruby(self) -> None:
        """Validate load yaml prefers pyyaml and falls back to ruby behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            yaml_path = Path(tmp) / "schema.yaml"
            yaml_path.write_text("a: 1\n", encoding="utf-8")

            with mock.patch.object(
                self.mod,
                "_load_yaml_with_pyyaml",
                side_effect=RuntimeError("no pyyaml"),
            ), mock.patch.object(
                self.mod,
                "_load_yaml_with_ruby",
                return_value={"a": 1},
            ) as ruby_loader:
                out = self.mod.load_yaml(yaml_path)
                self.assertEqual({"a": 1}, out)
                ruby_loader.assert_called_once_with(yaml_path)

    def test_load_yaml_raises_when_both_backends_fail(self) -> None:
        """Validate load yaml raises when both backends fail behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            yaml_path = Path(tmp) / "schema.yaml"
            yaml_path.write_text("a: 1\n", encoding="utf-8")

            with mock.patch.object(
                self.mod,
                "_load_yaml_with_pyyaml",
                side_effect=RuntimeError("no pyyaml"),
            ), mock.patch.object(
                self.mod,
                "_load_yaml_with_ruby",
                side_effect=RuntimeError("no ruby"),
            ):
                with self.assertRaises(RuntimeError):
                    self.mod.load_yaml(yaml_path)

    def test_load_yaml_falls_back_when_pyyaml_raises_non_runtime_error(self) -> None:
        """Validate load yaml falls back when pyyaml raises non runtime error behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            yaml_path = Path(tmp) / "schema.yaml"
            yaml_path.write_text("a: 1\n", encoding="utf-8")

            with mock.patch.object(
                self.mod,
                "_load_yaml_with_pyyaml",
                side_effect=ValueError("bad yaml"),
            ), mock.patch.object(
                self.mod,
                "_load_yaml_with_ruby",
                return_value={"a": 1},
            ) as ruby_loader:
                out = self.mod.load_yaml(yaml_path)
                self.assertEqual({"a": 1}, out)
                ruby_loader.assert_called_once_with(yaml_path)

    def test_main_check_and_update_paths(self) -> None:
        """Validate main check and update paths behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            yaml_path = Path(tmp) / "agentless-schema.yaml"
            json_path = Path(tmp) / "agentless-schema.json"
            yaml_path.write_text("placeholder", encoding="utf-8")

            with mock.patch.object(self.mod, "load_yaml", return_value={"v": 1}):
                args_update = types.SimpleNamespace(
                    yaml_path=yaml_path,
                    json_path=json_path,
                    check=False,
                )
                with mock.patch.object(self.mod, "parse_args", return_value=args_update):
                    rc_update = self.mod.main()
                self.assertEqual(0, rc_update)
                self.assertEqual({"v": 1}, json.loads(json_path.read_text(encoding="utf-8")))

                args_check_ok = types.SimpleNamespace(
                    yaml_path=yaml_path,
                    json_path=json_path,
                    check=True,
                )
                with mock.patch.object(self.mod, "parse_args", return_value=args_check_ok):
                    rc_check_ok = self.mod.main()
                self.assertEqual(0, rc_check_ok)

                json_path.write_text(json.dumps({"v": 2}), encoding="utf-8")
                args_check_bad = types.SimpleNamespace(
                    yaml_path=yaml_path,
                    json_path=json_path,
                    check=True,
                )
                with mock.patch.object(self.mod, "parse_args", return_value=args_check_bad):
                    rc_check_bad = self.mod.main()
                self.assertEqual(1, rc_check_bad)

    def test_load_json_accepts_utf8_bom(self) -> None:
        """Validate load json accepts utf8 bom behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            json_path = Path(tmp) / "schema.json"
            # UTF-8 BOM + valid JSON payload.
            json_path.write_bytes(b"\xef\xbb\xbf{\"ok\": true}")
            loaded = self.mod.load_json(json_path)
            self.assertEqual({"ok": True}, loaded)


class CheckModuleVersionsTests(unittest.TestCase):
    """Test case group covering CheckModuleVersionsTests behaviors."""
    @classmethod
    def setUpClass(cls) -> None:
        """Execute setUpClass lifecycle behavior."""
        cls.mod = _load_module(
            "check_module_versions_mod",
            "tools/dev/check_module_versions.py",
        )

    def test_extract_module_version(self) -> None:
        """Validate extract module version behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "MODULE.bazel"
            module_file.write_text(
                'module(\n    name = "demo",\n    version = "1.2.3",\n)\n',
                encoding="utf-8",
            )
            self.assertEqual("1.2.3", self.mod._extract_module_version(module_file))

    def test_extract_module_version_inline(self) -> None:
        """Validate extract module version inline behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "MODULE.bazel"
            module_file.write_text(
                'module(name = "demo", compatibility_level = 1, version = "2.0.1")\n',
                encoding="utf-8",
            )
            self.assertEqual("2.0.1", self.mod._extract_module_version(module_file))

    def test_extract_module_version_with_comments_and_nested_parentheses(self) -> None:
        """Validate extract module version with comments and nested parentheses behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "MODULE.bazel"
            module_file.write_text(
                "\n".join(
                    [
                        "module(",
                        '    name = "demo",  # comment with ) should be ignored',
                        '    repo_name = "demo(with-paren)",',
                        '    version = "3.4.5",',
                        ")",
                    ]
                ),
                encoding="utf-8",
            )
            self.assertEqual("3.4.5", self.mod._extract_module_version(module_file))

    def test_extract_bazel_dep_version(self) -> None:
        """Validate extract bazel dep version behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "MODULE.bazel"
            module_file.write_text(
                "\n".join(
                    [
                        'module(name = "demo-go", version = "1.2.3")',
                        'bazel_dep(name = "datadog-rules-test-optimization", version = "1.2.3")',
                    ]
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                "1.2.3",
                self.mod._extract_bazel_dep_version(
                    module_file,
                    "datadog-rules-test-optimization",
                ),
            )

    def test_extract_bazel_dep_version_multiline_with_comments(self) -> None:
        """Validate extract bazel dep version multiline with comments behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "MODULE.bazel"
            module_file.write_text(
                "\n".join(
                    [
                        'module(name = "demo-go", version = "1.2.3")',
                        "bazel_dep(",
                        '    name = "datadog-rules-test-optimization",',
                        '    # comment with ) should not end the call',
                        '    version = "9.9.9",',
                        ")",
                    ]
                ),
                encoding="utf-8",
            )
            self.assertEqual(
                "9.9.9",
                self.mod._extract_bazel_dep_version(
                    module_file,
                    "datadog-rules-test-optimization",
                ),
            )

    def test_extract_starlark_string_constant(self) -> None:
        """Validate extract starlark string constant behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            bzl_file = Path(tmp) / "common_utils.bzl"
            bzl_file.write_text(
                'RULES_VERSION = "1.2.3"\nUPLOADER_VERSION = "2.0.0"\n',
                encoding="utf-8",
            )
            self.assertEqual(
                "1.2.3",
                self.mod._extract_starlark_string_constant(bzl_file, "RULES_VERSION"),
            )
            self.assertEqual(
                "2.0.0",
                self.mod._extract_starlark_string_constant(bzl_file, "UPLOADER_VERSION"),
            )

    def test_extract_starlark_string_constant_missing_raises(self) -> None:
        """Validate extract starlark string constant missing raises behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            bzl_file = Path(tmp) / "common_utils.bzl"
            bzl_file.write_text("RULES_VERSION = 123\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                self.mod._extract_starlark_string_constant(bzl_file, "RULES_VERSION")

    def test_extract_module_version_missing_raises(self) -> None:
        """Validate extract module version missing raises behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "MODULE.bazel"
            module_file.write_text('module(name = "demo")\n', encoding="utf-8")
            with self.assertRaises(ValueError):
                self.mod._extract_module_version(module_file)

    def test_extract_core_dep_missing_raises(self) -> None:
        """Validate extract core dep missing raises behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "MODULE.bazel"
            module_file.write_text(
                'module(name = "demo-go", version = "1.2.3")\n',
                encoding="utf-8",
            )
            with self.assertRaises(ValueError):
                self.mod._extract_bazel_dep_version(
                    module_file,
                    "datadog-rules-test-optimization",
                )

    def test_main_reports_version_mismatch(self) -> None:
        """Validate main reports version mismatch behavior."""
        with mock.patch.object(
            self.mod,
            "_extract_module_version",
            side_effect=["1.2.3", "1.2.4", "1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3"],
        ), mock.patch.object(
            self.mod,
            "_extract_bazel_dep_version",
            side_effect=["1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3"],
        ):
            self.assertEqual(1, self.mod.main())

    def test_main_reports_parse_errors(self) -> None:
        """Validate main reports parse errors behavior."""
        with mock.patch.object(
            self.mod,
            "_extract_module_version",
            side_effect=ValueError("bad module"),
        ):
            self.assertEqual(2, self.mod.main())

    def test_extract_call_args_blocks_handles_triple_quoted_strings(self) -> None:
        """Validate extract call args blocks handles triple quoted strings behavior."""
        text = "\n".join(
            [
                "module(",
                '    name = "demo",',
                '    doc = """',
                "line with ) and # should be ignored",
                '""",',
                '    version = "1.2.3",',
                ")",
            ]
        )
        blocks = self.mod._extract_call_args_blocks(text, "module")
        self.assertEqual(1, len(blocks))
        self.assertIn('version = "1.2.3"', blocks[0])

    def test_main_reports_semver_errors(self) -> None:
        """Validate main reports semver errors behavior."""
        with mock.patch.object(
            self.mod,
            "_extract_module_version",
            side_effect=["1.2", "1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3"],
        ), mock.patch.object(
            self.mod,
            "_extract_bazel_dep_version",
            side_effect=["1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3"],
        ), mock.patch.object(
            self.mod,
            "_extract_starlark_string_constant",
            side_effect=["1.2.3", "2.0"],
        ):
            self.assertEqual(1, self.mod.main())


class CheckBazelversionSyncTests(unittest.TestCase):
    """Test case group covering CheckBazelversionSyncTests behaviors."""

    @classmethod
    def setUpClass(cls) -> None:
        """Execute setUpClass lifecycle behavior."""
        cls.mod = _load_module(
            "check_bazelversion_sync_mod",
            "tools/dev/check_bazelversion_sync.py",
        )

    def _write_bazelversion_tree(
        self,
        repo_root: Path,
        root_version: str = "8.5.1",
        overrides: Optional[dict[str, str]] = None,
    ) -> None:
        """Create a synthetic repo layout for bazelversion parity checks."""
        overrides = overrides or {}
        (repo_root / ".bazelversion").write_text(root_version, encoding="utf-8")
        for language in self.mod._COMPANION_LANGUAGES:
            module_dir = repo_root / "modules" / language
            module_dir.mkdir(parents=True, exist_ok=True)
            version = overrides.get(language, root_version)
            (module_dir / ".bazelversion").write_text(version, encoding="utf-8")

    def test_main_accepts_matching_versions(self) -> None:
        """Validate main accepts matching versions behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp)
            self._write_bazelversion_tree(repo_root)
            with mock.patch.object(self.mod, "_repo_root", return_value=repo_root):
                self.assertEqual(0, self.mod.main())

    def test_main_reports_mismatch(self) -> None:
        """Validate main reports mismatch behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp)
            self._write_bazelversion_tree(
                repo_root,
                overrides={"ruby": "8.4.1"},
            )
            with mock.patch.object(self.mod, "_repo_root", return_value=repo_root):
                self.assertEqual(1, self.mod.main())


class LintUploaderTemplatesTests(unittest.TestCase):
    """Test case group covering LintUploaderTemplatesTests behaviors."""
    @classmethod
    def setUpClass(cls) -> None:
        """Execute setUpClass lifecycle behavior."""
        cls.mod = _load_module(
            "lint_uploader_templates_mod",
            "tools/dev/lint_uploader_templates.py",
        )

    def test_normalize_bash_replaces_tokens(self) -> None:
        """Validate normalize bash replaces tokens behavior."""
        normalized = self.mod._normalize_bash_template_for_lint(
            "A=__DDTPL_ALPHA__\nB=__DDTPL_BETA__\n"
        )
        self.assertNotIn("__DDTPL_ALPHA__", normalized)
        self.assertNotIn("__DDTPL_BETA__", normalized)
        self.assertIn("A=0", normalized)

    def test_lint_batch_template_checks_required_marker(self) -> None:
        """Validate lint batch template checks required marker behavior."""
        with self.assertRaises(RuntimeError):
            self.mod._lint_batch_template("@echo off\n")

    def test_lint_batch_template_accepts_expected_shape(self) -> None:
        """Validate lint batch template accepts expected shape behavior."""
        self.mod._lint_batch_template(
            "@echo off\n"
            "powershell.exe -File \"%SCRIPT_DIR%__DDTPL_PS_NAME__\" %*\n"
            "exit /b %ERRORLEVEL%\n"
        )

    def test_lint_batch_template_requires_argument_forwarding(self) -> None:
        """Validate Windows launcher keeps Bazel-run CLI args for the PowerShell uploader."""
        with self.assertRaises(RuntimeError):
            self.mod._lint_batch_template(
                "@echo off\n"
                "powershell.exe -File \"%SCRIPT_DIR%__DDTPL_PS_NAME__\"\n"
                "exit /b %ERRORLEVEL%\n"
            )


class RuntimeTemplateParityTests(unittest.TestCase):
    """Test case group covering RuntimeTemplateParityTests behaviors."""
    @staticmethod
    def _extract_starlark_fingerprint_alphabet(sync_text: str) -> str:
        """Internal helper for extract starlark fingerprint alphabet behavior."""
        match = re.search(
            r'_FINGERPRINT_ALPHABET\s*=\s*("(?:[^"\\]|\\.)*")',
            sync_text,
        )
        if match is None:
            raise AssertionError("unable to locate _FINGERPRINT_ALPHABET in sync file")
        return ast.literal_eval(match.group(1))

    @staticmethod
    def _extract_bash_fingerprint_alphabet(bash_text: str) -> str:
        """Internal helper for extract bash fingerprint alphabet behavior."""
        marker = "local alphabet=$'"
        start = bash_text.find(marker)
        if start < 0:
            raise AssertionError("unable to locate bash fingerprint alphabet")

        i = start + len(marker)
        encoded_chars: list[str] = []
        while i < len(bash_text):
            ch = bash_text[i]
            if ch == "\\" and i + 1 < len(bash_text):
                encoded_chars.append(ch)
                encoded_chars.append(bash_text[i + 1])
                i += 2
                continue
            if ch == "'":
                encoded = "".join(encoded_chars)
                return bytes(encoded, "utf-8").decode("unicode_escape")
            encoded_chars.append(ch)
            i += 1
        raise AssertionError("unterminated bash fingerprint alphabet")

    @staticmethod
    def _extract_powershell_fingerprint_alphabet(powershell_text: str) -> str:
        """Internal helper for extract powershell fingerprint alphabet behavior."""
        match = re.search(r"\$alphabet\s*=\s*'([^\n]*)'", powershell_text)
        if match is None:
            raise AssertionError("unable to locate PowerShell fingerprint alphabet")
        return match.group(1).replace("''", "'")

    def test_runtime_fingerprint_alphabet_matches_sync(self) -> None:
        """Validate runtime fingerprint alphabet matches sync behavior."""
        sync_text = _runfile("tools/core/test_optimization_sync.bzl").read_text(encoding="utf-8")
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        expected = self._extract_starlark_fingerprint_alphabet(sync_text)
        self.assertEqual(expected, self._extract_bash_fingerprint_alphabet(bash_text))
        self.assertEqual(expected, self._extract_powershell_fingerprint_alphabet(powershell_text))

    def test_runtime_unknown_char_bucketing_matches_sync(self) -> None:
        """Validate runtime unknown char bucketing matches sync behavior."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )
        self.assertIn("idx=$((alpha_len + (i % 7)))", bash_text)
        self.assertIn("$idx = $alphabet.Length + ($i % 7)", powershell_text)

    def test_sync_windows_mkdir_command_uses_path(self) -> None:
        """Validate sync windows mkdir command uses path behavior."""
        sync_text = _runfile("tools/core/test_optimization_sync.bzl").read_text(encoding="utf-8")
        self.assertIn("New-Item -ItemType Directory -Force -Path", sync_text)
        self.assertNotIn("New-Item -ItemType Directory -Force -LiteralPath", sync_text)

    def test_bash_runtime_has_no_windows_delegation(self) -> None:
        """Validate bash runtime has no windows delegation behavior."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8").lower()
        self.assertNotIn("mingw", bash_text)
        self.assertNotIn("msys", bash_text)
        self.assertNotIn("cygwin", bash_text)
        self.assertNotIn("exec powershell.exe", bash_text)

    def test_bash_runtime_guards_context_enrichment_failures(self) -> None:
        """Validate bash runtime falls back when jq context enrichment fails."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        self.assertIn("if ! jq --slurpfile ctx", bash_text)
        self.assertIn('log "warning: context enrichment failed for payload:', bash_text)
        self.assertIn('cp "$infile" "$tmpfile"', bash_text)

    def test_uploader_rejects_raw_msgpack_test_payloads(self) -> None:
        """Validate test uploads keep the Bazel JSON enrichment contract."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        self.assertIn("list_sorted_test_payload_files()", bash_text)
        self.assertIn("list_sorted_raw_test_msgpack_files()", bash_text)
        self.assertIn("raw msgpack test payload is not supported in Bazel file mode", bash_text)
        self.assertNotIn("upload_single_test_msgpack", bash_text)

        self.assertIn("function Get-SortedTestPayloadFiles", powershell_text)
        self.assertIn("function Get-SortedRawTestMsgpackFiles", powershell_text)
        self.assertIn("raw msgpack test payload is not supported in Bazel file mode", powershell_text)
        self.assertNotIn("Send-PostMsgpack", powershell_text)
        self.assertNotIn("Upload-SingleTest: posting raw msgpack", powershell_text)

    def test_uploader_supports_enrichment_dry_run_without_uploading(self) -> None:
        """Validate dry-run reuses enrichment while avoiding network upload and cleanup."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        self.assertIn("--dry-run", bash_text)
        self.assertIn("--validate-enrichment", bash_text)
        self.assertIn("--expected-enriched-tag", bash_text)
        self.assertIn("dry_run_single_test()", bash_text)
        self.assertIn('enrich_with_context "$file" "$body"', bash_text)
        self.assertIn("validate_enriched_payload_tags", bash_text)
        self.assertIn("dry-run kept test payload", bash_text)
        self.assertIn("if (( AGENTLESS == 1 && DRY_RUN == 0 ))", bash_text)

        self.assertIn("--dry-run", powershell_text)
        self.assertIn("--validate-enrichment", powershell_text)
        self.assertIn("--expected-enriched-tag", powershell_text)
        self.assertIn("function DryRun-SingleTest", powershell_text)
        self.assertIn("Merge-With-Context $FilePath $body", powershell_text)
        self.assertIn("Test-EnrichedPayloadTags", powershell_text)
        self.assertIn("Test-EnrichedPayloadTags logs through the success stream", powershell_text)
        self.assertIn("DryRun-SingleTest may emit validation diagnostics", powershell_text)
        self.assertIn("dry-run kept test payload", powershell_text)
        self.assertIn("if ($Agentless -and -not $script:DryRun)", powershell_text)

    def test_uploader_exposes_source_neutral_bep_freshness_flags(self) -> None:
        """Validate uploader runtimes expose source-neutral BEP freshness controls."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        for token in [
            "--freshness-source",
            "--freshness-mode",
            "--bep-json",
            "DD_TEST_OPTIMIZATION_FRESHNESS_SOURCE",
            "DD_TEST_OPTIMIZATION_FRESHNESS_MODE",
            "DD_TEST_OPTIMIZATION_BEP_JSON",
            "FRESHNESS_REMOTE_ONLY_OUTPUTS_FILE",
            "FRESHNESS_MISSING_OUTPUT_LABELS_FILE",
            "prepare_bep_eligibility",
            "test_output_dir_is_freshness_eligible",
        ]:
            self.assertIn(token, bash_text)

        for token in [
            "--freshness-source",
            "--freshness-mode",
            "--bep-json",
            "DD_TEST_OPTIMIZATION_FRESHNESS_SOURCE",
            "DD_TEST_OPTIMIZATION_FRESHNESS_MODE",
            "DD_TEST_OPTIMIZATION_BEP_JSON",
            "FreshnessRemoteOnlyOutputs",
            "FreshnessMissingOutputLabels",
            "Initialize-BepEligibility",
            "Test-OutputDirFreshnessEligible",
        ]:
            self.assertIn(token, powershell_text)

        self.assertIn("test_outputs_artifact_hint", bash_text)
        self.assertIn("event_has_mappable_output", bash_text)
        self.assertIn("Test-BepTestOutputsArtifactHint", powershell_text)
        self.assertIn("$eventRemoteOnlyAny", powershell_text)
        self.assertIn('elif endswith("/test.log") or endswith("/test.xml")', bash_text)
        self.assertIn('elif endswith("/outputs.zip")', bash_text)
        self.assertIn('/bazel-testlogs/', bash_text)
        self.assertNotIn("Resolve-DefaultBepIfAvailable", powershell_text)
        self.assertNotIn("resolve_default_bep_if_available", bash_text)
        self.assertIn('EndsWith("/test.log"', powershell_text)
        self.assertIn('EndsWith("/outputs.zip"', powershell_text)
        self.assertIn("reported as both fresh and cached", bash_text)
        self.assertIn("reported as both fresh and cached", powershell_text)
        self.assertLess(bash_text.index("--bep-json"), bash_text.index("--execution-log-json"))
        self.assertLess(
            powershell_text.index("--bep-json"),
            powershell_text.index("--execution-log-json"),
        )

    def test_uploader_checks_required_bep_before_no_payload_noop(self) -> None:
        """Validate configured BEP freshness is evaluated before no-payload early exits."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        expected_log = "BEP freshness is configured; checking BEP before treating missing local payloads as no-op"
        self.assertIn(expected_log, bash_text)
        self.assertIn(expected_log, powershell_text)
        self.assertLess(
            bash_text.index(expected_log),
            bash_text.index("prepare_freshness_eligibility"),
        )
        self.assertLess(
            powershell_text.index(expected_log),
            powershell_text.index("Initialize-FreshnessEligibility"),
        )
        self.assertIn("prepare_freshness_eligibility\nvalidate_bep_remote_only_outputs", bash_text)
        self.assertIn(
            "Initialize-FreshnessEligibility\n    Assert-NoRequiredRemoteOnlyBepOutputs",
            powershell_text,
        )

    def test_uploader_freshness_flags_have_source_neutral_ci_errors_and_precedence(self) -> None:
        """Validate new freshness flags own precedence and auto-mode CI guidance."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        for text in (bash_text, powershell_text):
            self.assertIn("freshness filtering is required in CI or required mode", text)
            self.assertIn("--build_event_json_file", text)
            self.assertIn("--freshness-source=bep --freshness-mode=required", text)
            self.assertIn("BEP required freshness cannot authorize", text)
            self.assertIn("BEP freshness source was selected but no BEP JSON file was configured", text)

        self.assertIn("FRESHNESS_MODE_HAS_NEW_CONFIG", bash_text)
        self.assertIn("if (( FRESHNESS_MODE_HAS_NEW_CONFIG == 0 ))", bash_text)
        self.assertIn("FRESHNESS_DISABLED_EXPLICIT", bash_text)
        self.assertIn("$FreshnessModeHasNewConfig", powershell_text)
        self.assertIn("if (-not $FreshnessModeHasNewConfig)", powershell_text)
        self.assertIn("$FreshnessDisabledExplicit", powershell_text)
        self.assertNotIn('resolve_runtime_file_path "$DEFAULT_EXECUTION_LOG_JSON"', bash_text)
        self.assertNotIn("Resolve-RuntimeFilePath $script:DefaultExecutionLogJson", powershell_text)

    def test_uploader_skips_empty_output_dirs_before_freshness_metadata_gate(self) -> None:
        """Validate BEP required mode ignores empty control test.outputs directories."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        self.assertIn("payload_dir_has_replayable_files()", bash_text)
        self.assertIn("test_payload_dir_has_candidate_files()", bash_text)
        self.assertRegex(
            bash_text,
            r'test_payload_dir_has_candidate_files "\$tests_dir" \|\| continue\s+'
            r'test_output_dir_is_freshness_eligible "\$outputs_dir" \|\| continue',
        )
        self.assertRegex(
            bash_text,
            r'payload_dir_has_replayable_files "\$cov_dir" \|\| continue\s+'
            r'test_output_dir_is_freshness_eligible "\$outputs_dir" \|\| continue',
        )
        self.assertRegex(
            bash_text,
            r'payload_dir_has_replayable_files "\$telemetry_dir" \|\| continue\s+'
            r'test_output_dir_is_freshness_eligible "\$outputs_dir" \|\| continue',
        )

        self.assertIn("function Test-PayloadDirHasReplayableFiles", powershell_text)
        self.assertIn("function Test-TestPayloadDirHasCandidateFiles", powershell_text)
        self.assertRegex(
            powershell_text,
            r'if \(-not \(Test-TestPayloadDirHasCandidateFiles \$testsDir\)\) \{ continue \}\s+'
            r'if \(-not \(Test-OutputDirFreshnessEligible \$outputsDir\.FullName\)\) \{ continue \}',
        )
        self.assertRegex(
            powershell_text,
            r'if \(-not \(Test-PayloadDirHasReplayableFiles \$covDir\)\) \{ continue \}\s+'
            r'if \(-not \(Test-OutputDirFreshnessEligible \$outputsDir\.FullName\)\) \{ continue \}',
        )
        self.assertRegex(
            powershell_text,
            r'if \(-not \(Test-PayloadDirHasReplayableFiles \$telemetryDir\)\) \{ continue \}\s+'
            r'if \(-not \(Test-OutputDirFreshnessEligible \$outputsDir\.FullName\)\) \{ continue \}',
        )

    def test_uploader_dry_run_validates_default_enrichment_tags(self) -> None:
        """Validate dry-run checks the git and Bazel tags needed by downstream upload."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        for tag in [
            "git.repository_url",
            "git.commit.sha",
            "bazel.target",
            "bazel.package",
        ]:
            self.assertIn(tag, bash_text)
            self.assertIn(tag, powershell_text)

        self.assertIn("missing expected tag(s)", bash_text)
        self.assertIn("missing expected tag(s)", powershell_text)
        self.assertIn(
            "--expected-enriched-tag=bazel.go.payload_selection",
            _runfile("tools/tests/integration/run_mock_server_tests.sh").read_text(encoding="utf-8"),
        )
        self.assertIn(
            "--expected-enriched-tag=bazel.go.payload_selection",
            _runfile("tools/tests/integration/run_mock_server_tests.ps1").read_text(encoding="utf-8"),
        )

    def test_uploader_enriches_span_event_payloads(self) -> None:
        """Validate Go tracer span events are not excluded from metadata enrichment."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        self.assertIn("Go/Orchestrion", bash_text)
        self.assertNotIn('if (.type? == "span") then .', bash_text)
        self.assertNotIn('select((.type // "") != "span")', bash_text)
        self.assertIn("events still receive context and Bazel tags before this CODEOWNERS pass", bash_text)

        self.assertIn("Go test payloads can encode CI Visibility test data as span events", powershell_text)
        self.assertIn("events still receive context and Bazel tags before this CODEOWNERS pass", powershell_text)
        self.assertNotIn('[string]$eventType -eq "span"', powershell_text)

    def test_uploader_skips_empty_test_payload_placeholders(self) -> None:
        """Validate empty JSON placeholders are not uploaded as test payloads."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        self.assertIn("test_payload_has_events()", bash_text)
        self.assertIn("Malformed JSON must stay on the normal upload path", bash_text)
        self.assertNotIn("jq -r '.events | if type==\"array\" then length else 0 end' \"$file\" 2>/dev/null || echo \"\"", bash_text)
        self.assertIn("skipping test payload with no events", bash_text)
        self.assertIn("function Test-TestPayloadHasEvents", powershell_text)
        self.assertIn("skipping test payload with no events", powershell_text)

    def test_bash_runtime_prefers_context_override_before_runfiles(self) -> None:
        """Validate bash runtime prefers explicit context override before data files."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        self.assertIn('CONTEXT_JSON_OVERRIDE="${DD_TEST_OPTIMIZATION_CONTEXT_JSON:-}"', bash_text)
        self.assertIn('CONTEXT_MANIFEST_PATH="__DDTPL_CONTEXT_MANIFEST_PATH__"', bash_text)
        self.assertIn('TELEMETRY_FACTS_MANIFEST_PATH="__DDTPL_TELEMETRY_FACTS_MANIFEST_PATH__"', bash_text)
        self.assertIn('context.json resolved via runtime override', bash_text)
        self.assertIn(
            'warning: DD_TEST_OPTIMIZATION_CONTEXT_JSON did not resolve to a readable file; falling back to configured data',
            bash_text,
        )
        self.assertLess(
            bash_text.index('CONTEXT_JSON_OVERRIDE="${DD_TEST_OPTIMIZATION_CONTEXT_JSON:-}"'),
            bash_text.index('CONTEXT_JSON=$(resolve_artifact_path "$CONTEXT_JSON_PATH")'),
        )
        self.assertIn('if [[ -z "$CONTEXT_JSON" ]]; then', bash_text)
        self.assertIn('sibling="$(dirname "$PRIMARY_CONTEXT_JSON")/telemetry_facts.json"', bash_text)

    def test_bash_runtime_supports_multi_context_selection(self) -> None:
        """Validate bash runtime includes bundled-context selection helpers."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        self.assertIn("PRIMARY_CONTEXT_JSON", bash_text)
        self.assertIn("log_stderr()", bash_text)
        self.assertIn("select_context_json_for_payload()", bash_text)
        self.assertIn('payload_repo_name_from_metadata()', bash_text)
        self.assertIn("selected bundled context", bash_text)
        self.assertIn("no bundled context matched repo", bash_text)
        self.assertIn('log_stderr "warning: skipping context enrichment', bash_text)

    def test_bash_runtime_guards_curl_command_substitutions(self) -> None:
        """Validate bash runtime captures curl failures without set -e aborts."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        self.assertIn("if http=$(curl_agentless -f -sS", bash_text)
        self.assertIn("if http=$(curl -f -sS", bash_text)
        self.assertIn("rc=$?", bash_text)
        self.assertIn('http="${http:-000}"', bash_text)

    def test_bash_runtime_scans_physical_testlogs_path(self) -> None:
        """Validate bash runtime follows bazel-testlogs symlinks for discovery."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        self.assertIn('TESTLOGS_SCAN_DIR="$(cd "$TESTLOGS_DIR" 2>/dev/null && pwd -P)"', bash_text)
        self.assertIn('find "$TESTLOGS_SCAN_DIR"', bash_text)

    def test_powershell_runtime_temp_and_testlogs_guards(self) -> None:
        """Validate PowerShell runtime temp fallback and TESTLOGS_DIR checks."""
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )
        self.assertIn("[System.IO.Path]::GetTempPath()", powershell_text)
        self.assertIn("unable to determine a temporary directory (TEMP/GetTempPath)", powershell_text)
        self.assertIn("Test-Path -LiteralPath $env:TESTLOGS_DIR -PathType Container", powershell_text)
        self.assertIn("TESTLOGS_DIR is set but is not a directory", powershell_text)
        self.assertIn("Resolve-DirectoryPhysicalPath", powershell_text)
        self.assertIn("Path = $TestlogsScanDir", powershell_text)

    def test_powershell_runtime_max_depth_warning(self) -> None:
        """Validate PowerShell runtime emits visible max-depth compatibility warning."""
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )
        self.assertIn("warning: DD_TEST_OPTIMIZATION_MAX_DEPTH ignored", powershell_text)

    def test_powershell_runtime_prefers_context_override_before_runfiles(self) -> None:
        """Validate PowerShell runtime prefers explicit context override before data files."""
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )
        self.assertIn("$ContextJsonOverride = $env:DD_TEST_OPTIMIZATION_CONTEXT_JSON", powershell_text)
        self.assertIn('$ContextManifestPath = "__DDTPL_CONTEXT_MANIFEST_PATH__"', powershell_text)
        self.assertIn('$TelemetryFactsManifestPath = "__DDTPL_TELEMETRY_FACTS_MANIFEST_PATH__"', powershell_text)
        self.assertIn("context.json resolved via runtime override", powershell_text)
        self.assertIn(
            "warning: DD_TEST_OPTIMIZATION_CONTEXT_JSON did not resolve to a readable file; falling back to configured data",
            powershell_text,
        )
        self.assertLess(
            powershell_text.index("$ContextJsonOverride = $env:DD_TEST_OPTIMIZATION_CONTEXT_JSON"),
            powershell_text.index("$script:PrimaryContextJson = Resolve-ArtifactPath $ContextJsonPath"),
        )
        self.assertIn("if (-not $script:PrimaryContextJson) {", powershell_text)
        self.assertIn('Join-Path (Split-Path -Parent $script:PrimaryContextJson) "telemetry_facts.json"', powershell_text)

    def test_powershell_runtime_supports_multi_context_selection(self) -> None:
        """Validate PowerShell runtime includes bundled-context selection helpers."""
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )
        self.assertIn("$script:PrimaryContextJson", powershell_text)
        self.assertIn("function Log-Stderr", powershell_text)
        self.assertIn("Load-ContextManifestEntries", powershell_text)
        self.assertIn("Resolve-ContextJsonForPayload", powershell_text)
        self.assertIn("selected bundled context", powershell_text)
        self.assertIn("no bundled context matched repo", powershell_text)
        self.assertIn("Log-Stderr \"warning: skipping context enrichment", powershell_text)


class MockDdServerTests(unittest.TestCase):
    """Test case group covering MockDdServerTests behaviors."""
    @classmethod
    def setUpClass(cls) -> None:
        """Execute setUpClass lifecycle behavior."""
        cls.mod = _load_module(
            "mock_dd_server_mod",
            "tools/tests/integration/mock_dd_server.py",
        )

    def test_require_single_header_rejects_duplicates(self) -> None:
        """Validate require single header rejects duplicates behavior."""
        from email.message import Message

        headers = Message()
        headers.add_header("DD-API-KEY", "a")
        headers.add_header("DD-API-KEY", "b")
        value, err = self.mod._require_single_header(headers, "DD-API-KEY")
        self.assertIsNone(value)
        self.assertEqual("duplicate DD-API-KEY headers", err)

    def test_normalize_headers_redacts_api_key(self) -> None:
        """Validate normalize headers redacts api key behavior."""
        out = self.mod._normalize_headers({"DD-API-KEY": "secret", "Content-Type": "application/json"})
        self.assertEqual("<redacted>", out["DD-API-KEY"])
        self.assertEqual("application/json", out["Content-Type"])

    def test_decode_uploader_coverage_payload_reads_coveragex_part(self) -> None:
        """Validate decode uploader coverage payload reads coveragex part behavior."""
        boundary = "abc123"
        body = (
            f"--{boundary}\r\n"
            "Content-Disposition: form-data; name=\"coveragex\"; filename=\"coverage.json\"\r\n"
            "Content-Type: application/json\r\n\r\n"
            "{\"mock_mode\":\"ok\"}\r\n"
            f"--{boundary}--\r\n"
        ).encode("utf-8")
        fake_handler = types.SimpleNamespace(headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
        decoded = self.mod._Handler._decode_uploader_coverage_payload(fake_handler, body)
        self.assertEqual({"mock_mode": "ok"}, decoded)

    def test_payload_contains_resource(self) -> None:
        """Validate payload contains resource behavior."""
        payload = {"events": [{"content": {"resource": "target"}}]}
        fake_handler = types.SimpleNamespace()
        self.assertTrue(self.mod._Handler._payload_contains_resource(fake_handler, payload, "target"))
        self.assertFalse(self.mod._Handler._payload_contains_resource(fake_handler, payload, "missing"))


if __name__ == "__main__":
    unittest.main()
