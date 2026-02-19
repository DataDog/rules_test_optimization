#!/usr/bin/env python3
"""Unit tests for repository Python tooling scripts."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import types
from typing import Optional
import unittest
from unittest import mock


def _runfile(rel_path: str) -> Path:
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
    path = _runfile(rel_path)
    spec = importlib.util.spec_from_file_location(name, str(path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module spec for {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ValidatePayloadSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
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
        missing_path = os.path.join(
            tempfile.gettempdir(),
            "does-not-exist-validate-payload-schema",
        )
        value = self.mod._safe_size(missing_path)
        self.assertIsNone(value)

    def test_max_errors_flag_is_supported(self) -> None:
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

    def test_internal_predicates_and_helpers(self) -> None:
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
        schema = {"type": "number", "minimum": 10, "maximum": 20}
        errors: list[str] = []
        self.mod._validate(7, schema, schema, "$", errors, 10)
        self.assertIn("value 7 < minimum 10", errors[0])

        errors = []
        self.mod._validate(42, schema, schema, "$", errors, 10)
        self.assertIn("value 42 > maximum 20", errors[0])

    def test_validate_number_bounds_stops_at_max_errors(self) -> None:
        # Deliberately inconsistent schema to force both bounds to fail.
        schema = {"type": "number", "minimum": 10, "maximum": 5}
        errors: list[str] = []
        self.mod._validate(7, schema, schema, "$", errors, 1)
        self.assertEqual(1, len(errors))

    def test_validate_invalid_pattern_properties_regex(self) -> None:
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
        parsed = self.mod._parse_args(["schema.json", "payload.json", "--max-errors", "5"])
        self.assertEqual("schema.json", parsed.schema_path)
        self.assertEqual("payload.json", parsed.payload_path)
        self.assertEqual(5, parsed.max_errors)


class SyncAgentlessSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mod = _load_module(
            "sync_agentless_schema_mod",
            "tools/core/schemas/sync_agentless_schema.py",
        )

    def test_render_json_trailing_newline(self) -> None:
        out = self.mod.render_json({"a": 1})
        self.assertTrue(out.endswith("\n"))
        self.assertIn('"a": 1', out)
        self.assertEqual({"a": 1}, json.loads(out))

    def test_load_yaml_prefers_pyyaml_and_falls_back_to_ruby(self) -> None:
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


class CheckModuleVersionsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mod = _load_module(
            "check_module_versions_mod",
            "tools/dev/check_module_versions.py",
        )

    def test_extract_module_version(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "MODULE.bazel"
            module_file.write_text(
                'module(\n    name = "demo",\n    version = "1.2.3",\n)\n',
                encoding="utf-8",
            )
            self.assertEqual("1.2.3", self.mod._extract_module_version(module_file))

    def test_extract_module_version_inline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "MODULE.bazel"
            module_file.write_text(
                'module(name = "demo", compatibility_level = 1, version = "2.0.1")\n',
                encoding="utf-8",
            )
            self.assertEqual("2.0.1", self.mod._extract_module_version(module_file))

    def test_extract_module_version_with_comments_and_nested_parentheses(self) -> None:
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

    def test_extract_module_version_missing_raises(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            module_file = Path(tmp) / "MODULE.bazel"
            module_file.write_text('module(name = "demo")\n', encoding="utf-8")
            with self.assertRaises(ValueError):
                self.mod._extract_module_version(module_file)

    def test_extract_core_dep_missing_raises(self) -> None:
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
        with mock.patch.object(self.mod, "_extract_module_version", side_effect=["1.2.3", "1.2.4"]), mock.patch.object(
            self.mod,
            "_extract_bazel_dep_version",
            side_effect=["1.2.3", "1.2.3", "1.2.3", "1.2.3", "1.2.3"],
        ):
            self.assertEqual(1, self.mod.main())

    def test_main_reports_parse_errors(self) -> None:
        with mock.patch.object(
            self.mod,
            "_extract_module_version",
            side_effect=ValueError("bad module"),
        ):
            self.assertEqual(2, self.mod.main())


if __name__ == "__main__":
    unittest.main()
