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
    candidates = []
    if test_srcdir and test_workspace:
        candidates.append(Path(test_srcdir) / test_workspace / rel_path)
    if test_srcdir:
        candidates.append(Path(test_srcdir) / rel_path)

    for cand in candidates:
        if cand.exists():
            return cand
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
        value = self.mod._safe_size("/tmp/does-not-exist-validate-payload-schema")
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

    def test_extract_core_dep_version_from_go_module(self) -> None:
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
                self.mod._extract_core_dep_version_from_go_module(module_file),
            )


if __name__ == "__main__":
    unittest.main()
