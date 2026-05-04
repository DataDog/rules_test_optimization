#!/usr/bin/env python3
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

    def test_expected_target_output_mapping(self) -> None:
        """Validate local Bazel labels map to bazel-testlogs output dirs."""
        root = Path("/tmp/bazel-testlogs")
        self.assertEqual(
            root / "target" / "test.outputs",
            self.mod._expected_target_output(root, "//:target"),
        )
        self.assertEqual(
            root / "pkg" / "sub" / "target" / "test.outputs",
            self.mod._expected_target_output(root, "//pkg/sub:target"),
        )

    def test_expected_target_rejects_external_label(self) -> None:
        """Validate external labels are rejected before path mapping."""
        with self.assertRaises(SystemExit):
            self.mod._expected_target_output(Path("/tmp/bazel-testlogs"), "@repo//pkg:test")

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
                self.mod._validate_outputs([output], True, True, True)

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
