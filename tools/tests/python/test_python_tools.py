#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for repository Python tooling scripts."""

from __future__ import annotations

import ast
import contextlib
import functools
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
from typing import Iterator, Optional
import unittest
import zipfile
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


def _cleanup_tempdir_with_windows_retry(path: Path) -> None:
    """Remove a temp directory, tolerating short-lived Windows subprocess handles."""
    for attempt in range(6):
        try:
            shutil.rmtree(path)
            return
        except OSError:
            if os.name != "nt" or attempt == 5:
                raise
            time.sleep(0.25 * (attempt + 1))


def _load_module(name: str, rel_path: str) -> types.ModuleType:
    """Internal helper for load module behavior."""
    path = _runfile(rel_path)
    spec = importlib.util.spec_from_file_location(name, str(path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module spec for {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _require_functional_bash(testcase: unittest.TestCase) -> str:
    """Return a usable Bash executable or skip the caller's test."""
    bash = shutil.which("bash")
    if bash is None:
        testcase.skipTest("bash is required for Bash runtime execution")
    result = subprocess.run(
        [bash, "-lc", "true"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        testcase.skipTest(f"bash is not functional in this environment: {result.stderr.strip()}")
    return bash


def _require_command(testcase: unittest.TestCase, command: str, reason: str) -> str:
    """Return an executable command path or skip the caller's test."""
    path = shutil.which(command)
    if path is None:
        testcase.skipTest(reason)
    return path


_BEP_ARTIFACT_STAGE_HELPER_RLOC = "tools/core/bep_artifact_stage_helper.py"
_DOCTOR_RUNTIME_RLOC = "tools/core/test_optimization_doctor.py"
_NON_SIBLING_DOCTOR_RUNTIME_RLOC = "tools/tests/python/fixtures/runtime_doctor/test_optimization_doctor.py"


class QuietSimpleHTTPRequestHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP handler that keeps unit test stderr deterministic."""

    def log_message(self, format: str, *args: object) -> None:
        return


class QuietBaseHTTPRequestHandler(http.server.BaseHTTPRequestHandler):
    """Base HTTP handler that keeps unit test stderr deterministic."""

    def log_message(self, format: str, *args: object) -> None:
        return


@contextlib.contextmanager
def _serve_directory(root: Path) -> Iterator[str]:
    """Serve a directory over local HTTP for BEP artifact staging tests."""
    handler = functools.partial(QuietSimpleHTTPRequestHandler, directory=str(root))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


@contextlib.contextmanager
def _serve_handler(handler: type[http.server.BaseHTTPRequestHandler]) -> Iterator[str]:
    """Serve a custom local HTTP handler for BEP artifact staging tests."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def _render_uploader_runtime_template(
    rel_path: str,
    *,
    bep_artifact_stage_helper_rloc: str = _BEP_ARTIFACT_STAGE_HELPER_RLOC,
    doctor_runtime_rloc: str = _DOCTOR_RUNTIME_RLOC,
) -> str:
    """Render uploader runtime template placeholders for direct unit tests."""
    text = _runfile(rel_path).read_text(encoding="utf-8")
    substitutions = {
        "bep_artifact_stage_helper_rloc": bep_artifact_stage_helper_rloc,
        "context_json_path": "",
        "context_json_rloc": "",
        "context_manifest_path": "",
        "context_manifest_rloc": "",
        "curl_retry_flags": "--retry 3 --retry-delay 2 --retry-connrefused",
        "debug": "false",
        "doctor_runtime_rloc": doctor_runtime_rloc,
        "fail_on_error": "false",
        "filter_prefix": "false",
        "gzip_payloads": "false",
        "keep_payloads": "false",
        "max_wait_sec": "300",
        "ps_name": "generated_uploader.ps1",
        "quiescent_sec": "10",
        "rules_version": "test-rules-version",
        "schema_json_path": "",
        "schema_json_rloc": "",
        "schema_validator_path": "",
        "schema_validator_rloc": "",
        "telemetry_facts_manifest_path": "",
        "telemetry_facts_manifest_rloc": "",
        "uploader_version": "test-uploader-version",
    }
    for key, value in substitutions.items():
        text = text.replace(f"__DDTPL_{key.upper()}__", value)
    unresolved = sorted(set(re.findall(r"__DDTPL_[A-Z0-9_]+__", text)))
    if unresolved:
        raise AssertionError(f"unresolved template placeholders in {rel_path}: {unresolved}")
    return text


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


class TestOptimizationCiWrapperTests(unittest.TestCase):
    """Test case group covering checked-in CI wrapper script contracts."""

    def test_bash_and_powershell_wrappers_use_per_run_bep_files(self) -> None:
        """Validate wrappers avoid shared BEP paths and pass BEP args explicitly."""
        bash_text = _runfile("tools/test_optimization/run_test_optimization_ci.sh").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/test_optimization/run_test_optimization_ci.ps1").read_text(encoding="utf-8")

        for text in (bash_text, powershell_text):
            self.assertIn("--build_event_json_file", text)
            self.assertIn("--bep-json", text)
            self.assertIn("--freshness-source=bep", text)
            self.assertIn("--freshness-mode=required", text)
            self.assertIn("--artifact-source=bep", text)
            self.assertIn("--artifact-staging-dir", text)
            self.assertIn("--report-json", text)
            self.assertIn("DD_TEST_OPTIMIZATION_REPORT_DIR", text)
            self.assertIn("DD_TEST_OPTIMIZATION_DOCTOR_REPORT_JSON", text)
            self.assertIn("uploader-dry-run-report.json", text)
            self.assertIn("uploader-upload-report.json", text)
            self.assertIn("--dry-run", text)
            self.assertIn("--validate-enrichment", text)
            self.assertIn("DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE", text)
            self.assertIn("DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR", text)
            self.assertIn("DD_TEST_OPTIMIZATION_PYTHON", text)
            self.assertIn("create_support_bundle.py", text)
            self.assertIn("--tmp-root", text)
            self.assertNotIn(".topt/bazel-bep.json", text)
            self.assertNotIn("DD_TEST_OPTIMIZATION_BEP_JSON=", text)

        self.assertIn("mktemp -d", bash_text)
        self.assertIn("DD_TEST_OPTIMIZATION_KEEP_TMP", bash_text)
        self.assertIn("resolve_python", bash_text)
        self.assertIn("resolve_output_base", bash_text)
        self.assertIn("NewGuid", powershell_text)
        self.assertIn("DD_TEST_OPTIMIZATION_KEEP_TMP", powershell_text)
        self.assertIn("Get-PythonForSupportBundle", powershell_text)
        self.assertIn("Get-OutputBase", powershell_text)

    def test_bash_wrapper_preserves_failed_test_status(self) -> None:
        """Validate Bash wrapper reports the original bazel test exit code."""
        bash = _require_functional_bash(self)
        wrapper = _runfile("tools/test_optimization/run_test_optimization_ci.sh")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_bazel = root / "bazel"
            log_path = root / "bazel.log"
            fake_bazel.write_text(
                f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> {str(log_path)!r}
case "$1" in
  test) exit 7 ;;
  run) exit 0 ;;
  *) exit 99 ;;
esac
""",
                encoding="utf-8",
            )
            fake_bazel.chmod(0o755)
            tmpdir = root / "tmp"
            tmpdir.mkdir()
            env = os.environ.copy()
            env["BAZEL"] = str(fake_bazel)
            env["DD_TEST_OPTIMIZATION_TMPDIR"] = str(tmpdir)

            result = subprocess.run(
                [
                    bash,
                    str(wrapper),
                    "--keep-tmp",
                    "--report-dir",
                    str(root / "reports"),
                    "//pkg:target",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(7, result.returncode, result.stderr)
            log_text = log_path.read_text(encoding="utf-8")
            self.assertIn("test --config=test-optimization", log_text)
            self.assertIn("--build_event_json_file=", log_text)
            self.assertIn("run --config=test-optimization //:dd_test_optimization_doctor -- --bep-json=", log_text)
            self.assertIn("--artifact-staging-dir=", log_text)
            normalized_log_text = log_text.replace("\\", "/")
            self.assertIn(f"--report-json={(root / 'reports' / 'doctor-report.json').as_posix()}", normalized_log_text)
            self.assertIn(
                f"--report-json={(root / 'reports' / 'uploader-dry-run-report.json').as_posix()}",
                normalized_log_text,
            )

    def test_bash_wrapper_support_bundle_preserves_failed_test_status(self) -> None:
        """Validate Bash support bundle path preserves the original test status."""
        if os.name == "nt":
            self.skipTest("Windows support bundle execution is covered by the PowerShell wrapper")
        bash = _require_functional_bash(self)
        wrapper = _runfile("tools/test_optimization/run_test_optimization_ci.sh")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_bazel = root / "bazel"
            log_path = root / "bazel.log"
            fake_bazel.write_text(
                f"""#!/usr/bin/env bash
printf '%s\n' "$*" >> {str(log_path)!r}
case "$1 $2" in
  "info output_base") printf '%s\n' {str(root / 'output-base')!r}; exit 0 ;;
esac
case "$1" in
  test) exit 7 ;;
  run) exit 0 ;;
  *) exit 99 ;;
esac
""",
                encoding="utf-8",
            )
            fake_bazel.chmod(0o755)
            fake_collector = root / "create_support_bundle.py"
            collector_log = root / "collector.log"
            fake_collector.write_text(
                f"""#!/usr/bin/env python3
import json
import pathlib
import sys

args = sys.argv[1:]
pathlib.Path({str(collector_log)!r}).write_text("\\n".join(args), encoding="utf-8")
manifest_path = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--command-manifest-json="))
manifest = json.loads(pathlib.Path(manifest_path).read_text(encoding="utf-8"))
assert manifest["targets"] == ["//pkg:target"], manifest
assert manifest["test_flags"] == ["--remote_download_regex=.*test[.]outputs.*"], manifest
assert len(manifest["bep_files"]) == 1 and manifest["bep_files"][0].endswith(".bep.json"), manifest
assert manifest["doctor_report_json"] == {str(root / "custom-doctor.json")!r}, manifest
assert manifest["upload_enabled"] is False, manifest
assert manifest["artifact_staging_dir"], manifest
output_path = None
for arg in args:
    if arg.startswith("--output="):
        output_path = arg.split("=", 1)[1]
        break
if output_path is None:
    raise AssertionError(f"missing --output argument: {{args!r}}")
pathlib.Path(output_path).write_bytes(b"fake support bundle")
sys.exit(0)
""",
                encoding="utf-8",
            )
            fake_collector.chmod(0o755)
            python_shim = root / "python-shim"
            python_shim_log = root / "python-shim.log"
            python_shim.write_text(
                f"""#!/usr/bin/env bash
printf '%s\n' "$1" >> {str(python_shim_log)!r}
exec {sys.executable!r} "$@"
""",
                encoding="utf-8",
            )
            python_shim.chmod(0o755)
            tmpdir = root / "tmp"
            tmpdir.mkdir()
            env = os.environ.copy()
            env["BAZEL"] = str(fake_bazel)
            env["DD_TEST_OPTIMIZATION_TMPDIR"] = str(tmpdir)
            env["DD_TEST_OPTIMIZATION_PYTHON"] = str(python_shim)

            result = subprocess.run(
                [
                    bash,
                    str(wrapper),
                    "--keep-tmp",
                    "--report-dir",
                    str(root / "reports"),
                    "--doctor-report-json",
                    str(root / "custom-doctor.json"),
                    "--test-flag",
                    "--remote_download_regex=.*test[.]outputs.*",
                    "--support-bundle",
                    str(root / "support.zip"),
                    "--support-bundle-collector",
                    str(fake_collector),
                    "//pkg:target",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(7, result.returncode, result.stderr)
            self.assertTrue((root / "support.zip").exists())
            collector_args = collector_log.read_text(encoding="utf-8")
            self.assertIn("--command-manifest-json=", collector_args)
            self.assertIn(f"--report-json={root / 'custom-doctor.json'}", collector_args)
            self.assertIn("--tmp-root=", collector_args)
            self.assertIn("--bep-json=", collector_args)
            shim_calls = python_shim_log.read_text(encoding="utf-8").splitlines()
            self.assertIn("-", shim_calls)
            self.assertIn(str(fake_collector), shim_calls)

    def test_bash_wrapper_support_bundle_with_real_collector_writes_zip(self) -> None:
        """Validate Bash wrapper can create a real support bundle archive."""
        if os.name == "nt":
            self.skipTest("Windows support bundle execution is covered by the PowerShell wrapper")
        bash = _require_functional_bash(self)
        wrapper = _runfile("tools/test_optimization/run_test_optimization_ci.sh")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_bazel = root / "bazel"
            log_path = root / "bazel.log"
            fake_bazel.write_text(
                f"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> {str(log_path)!r}
case "$1 $2" in
  "info output_base") printf '%s\\n' {str(root / 'output-base')!r}; exit 0 ;;
esac
if [[ "$1" == "test" ]]; then
  bep_json=""
  target=""
  for arg in "$@"; do
    case "$arg" in
      --build_event_json_file=*) bep_json="${{arg#--build_event_json_file=}}" ;;
      //*) target="$arg" ;;
    esac
  done
  mkdir -p "$(dirname "$bep_json")"
  cat > "$bep_json" <<JSON
{{"id":{{"testResult":{{"label":"$target","run":1,"shard":1,"attempt":1}}}},"testResult":{{"cachedLocally":false,"testActionOutput":[{{"name":"outputs.zip","uri":"file://{str(root / 'outputs.zip')}"}}]}}}}
JSON
  exit 0
fi
if [[ "$1" == "run" ]]; then
  report_json=""
  for arg in "$@"; do
    case "$arg" in
      --report-json=*) report_json="${{arg#--report-json=}}" ;;
    esac
  done
  if [[ -n "$report_json" ]]; then
    mkdir -p "$(dirname "$report_json")"
    case "$3" in
      *dd_test_optimization_doctor*) tool="dd-test-optimization-doctor" ;;
      *) tool="dd-test-optimization-uploader" ;;
    esac
    cat > "$report_json" <<JSON
{{"tool":"$tool","result":{{"status":"ok","reason_code":"ok","reason":"","next_steps":[]}},"summary":{{"payloads":{{"tests":1,"coverage":0,"telemetry":0}}}}}}
JSON
  fi
  exit 0
fi
exit 99
""",
                encoding="utf-8",
            )
            fake_bazel.chmod(0o755)
            tmpdir = root / "tmp"
            tmpdir.mkdir()
            support_bundle = root / "reports" / "support.zip"
            env = os.environ.copy()
            env["BAZEL"] = str(fake_bazel)
            env["DD_TEST_OPTIMIZATION_TMPDIR"] = str(tmpdir)
            env["DD_TEST_OPTIMIZATION_PYTHON"] = sys.executable

            result = subprocess.run(
                [
                    bash,
                    str(wrapper),
                    "--keep-tmp",
                    "--report-dir",
                    str(root / "reports"),
                    "--test-flag",
                    "--remote_download_regex=.*test[.]outputs.*",
                    "--support-bundle",
                    str(support_bundle),
                    "//pkg:target",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            with zipfile.ZipFile(support_bundle) as zf:
                names = set(zf.namelist())
                diagnostics = json.loads(zf.read("diagnostics.json").decode("utf-8"))
                command = json.loads(zf.read("command/flags.json").decode("utf-8"))

        self.assertIn("summary.md", names)
        self.assertIn("environment/runtime.json", names)
        self.assertIn("reports/doctor-report.json", names)
        self.assertIn("reports/uploader-dry-run-report.json", names)
        self.assertIn("command/flags.json", names)
        self.assertEqual("ok", diagnostics["summary"]["status"])
        self.assertEqual(2, diagnostics["summary"]["report_count"])
        self.assertEqual(1, diagnostics["summary"]["bep_summary_count"])
        self.assertEqual("ok", diagnostics["summary"]["primary_reason_code"])
        self.assertEqual(["//pkg:target"], command["targets"])
        self.assertEqual(["--remote_download_regex=.*test[.]outputs.*"], command["test_flags"])
        self.assertEqual("dd-test-optimization-doctor", diagnostics["reports"][0]["tool"])
        self.assertEqual("dd-test-optimization-uploader", diagnostics["reports"][1]["tool"])

    def test_powershell_wrapper_reaches_uploader_when_bazel_writes_stdout(self) -> None:
        """Validate PowerShell wrapper keeps command statuses separate from Bazel stdout."""
        pwsh = _require_command(self, "pwsh", "pwsh is required for PowerShell wrapper smoke")
        wrapper = _runfile("tools/test_optimization/run_test_optimization_ci.ps1")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_bazel = root / "bazel.ps1"
            log_path = root / "bazel.log"
            fake_bazel.write_text(
                f"""
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$BazelArgs)
Write-Output ("fake bazel stdout: " + ($BazelArgs -join ' '))
Add-Content -LiteralPath {str(log_path)!r} -Value ($BazelArgs -join ' ')
if ($BazelArgs.Count -gt 1 -and $BazelArgs[0] -eq 'info' -and $BazelArgs[1] -eq 'output_base') {{
  Write-Output {str(root / 'output-base')!r}
  exit 0
}}
if ($BazelArgs.Count -gt 0 -and $BazelArgs[0] -eq 'test') {{
  foreach ($Arg in $BazelArgs) {{
    if ($Arg.StartsWith("--build_event_json_file=")) {{
      $BepJson = $Arg.Substring("--build_event_json_file=".Length)
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $BepJson) | Out-Null
      Set-Content -LiteralPath $BepJson -Encoding UTF8 -Value '{{"id":{{"testResult":{{"label":"//pkg:target","run":1,"shard":1,"attempt":1}}}},"testResult":{{"cachedLocally":false,"testActionOutput":[{{"name":"outputs.zip","uri":"file:///tmp/outputs.zip"}}]}}}}'
    }}
  }}
  exit 0
}}
if ($BazelArgs.Count -gt 0 -and $BazelArgs[0] -eq 'run') {{
  $ReportJson = ""
  foreach ($Arg in $BazelArgs) {{
    if ($Arg.StartsWith("--report-json=")) {{
      $ReportJson = $Arg.Substring("--report-json=".Length)
    }}
  }}
  if (-not [string]::IsNullOrWhiteSpace($ReportJson)) {{
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ReportJson) | Out-Null
    if (($BazelArgs -join ' ') -like '*dd_test_optimization_doctor*') {{
      Set-Content -LiteralPath $ReportJson -Encoding UTF8 -Value '{{"tool":"dd-test-optimization-doctor","status":"ok","result":{{"status":"ok","reason_code":"ok","reason":"","next_steps":[]}}}}'
    }} else {{
      Set-Content -LiteralPath $ReportJson -Encoding UTF8 -Value '{{"tool":"dd-test-optimization-uploader","config":{{"artifact_source":"bep"}},"payloads":{{"tests":{{"processed":1}}}}}}'
    }}
  }}
  exit 0
}}
exit 99
""",
                encoding="utf-8",
            )
            fake_bazel.chmod(0o755)
            tmpdir = root / "tmp"
            tmpdir.mkdir()
            env = os.environ.copy()
            env["DD_TEST_OPTIMIZATION_TMPDIR"] = str(tmpdir)

            result = subprocess.run(
                [
                    pwsh,
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(wrapper),
                    "-Bazel",
                    str(fake_bazel),
                    "-ReportDir",
                    str(root / "reports"),
                    "-TestFlag",
                    "--remote_download_regex=.*test[.]outputs.*",
                    "//pkg:target",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stderr + result.stdout)
            self.assertTrue((root / "reports" / "doctor-report.json").exists(), result.stderr + result.stdout)
            self.assertTrue((root / "reports" / "uploader-dry-run-report.json").exists(), result.stderr + result.stdout)
            log_text = log_path.read_text(encoding="utf-8")

        self.assertIn("//:dd_upload_payloads", log_text)
        self.assertIn("--dry-run --validate-enrichment", log_text)

    def test_powershell_wrapper_support_bundle_preserves_failed_test_status(self) -> None:
        """Validate PowerShell support bundle path preserves the original test status."""
        pwsh = _require_command(self, "pwsh", "pwsh is required for PowerShell support bundle smoke")
        wrapper = _runfile("tools/test_optimization/run_test_optimization_ci.ps1")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake_bazel = root / "bazel.ps1"
            log_path = root / "bazel.log"
            fake_bazel.write_text(
                f"""
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$BazelArgs)
Add-Content -LiteralPath {str(log_path)!r} -Value ($BazelArgs -join ' ')
if ($BazelArgs.Count -gt 1 -and $BazelArgs[0] -eq 'info' -and $BazelArgs[1] -eq 'output_base') {{
  Write-Output {str(root / 'output-base')!r}
  exit 0
}}
if ($BazelArgs.Count -gt 0 -and $BazelArgs[0] -eq 'test') {{ exit 7 }}
if ($BazelArgs.Count -gt 0 -and $BazelArgs[0] -eq 'run') {{ exit 0 }}
exit 99
""",
                encoding="utf-8",
            )
            fake_bazel.chmod(0o755)
            fake_collector = root / "create_support_bundle.py"
            collector_log = root / "collector.log"
            fake_python = root / "fake_python.ps1"
            fake_collector.write_text(
                "# Placeholder collector path. fake_python.ps1 validates the forwarded arguments.\n",
                encoding="utf-8",
            )
            fake_collector.chmod(0o755)
            fake_python.write_text(
                f"""
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ShimArgs)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($ShimArgs.Count -lt 1) {{
  throw "missing collector path"
}}
if (-not (Test-Path -LiteralPath $ShimArgs[0] -PathType Leaf) -or -not $ShimArgs[0].EndsWith("create_support_bundle.py")) {{
  throw "unexpected collector path: $($ShimArgs[0])"
}}
$CollectorArgs = @()
if ($ShimArgs.Count -gt 1) {{
  $CollectorArgs = $ShimArgs[1..($ShimArgs.Count - 1)]
}}
Set-Content -LiteralPath {str(collector_log)!r} -Value ($CollectorArgs -join "`n") -Encoding UTF8
$ManifestPath = ""
$OutputPath = ""
foreach ($Arg in $CollectorArgs) {{
  if ($Arg.StartsWith("--command-manifest-json=")) {{
    $ManifestPath = $Arg.Substring("--command-manifest-json=".Length)
  }}
  if ($Arg.StartsWith("--output=")) {{
    $OutputPath = $Arg.Substring("--output=".Length)
  }}
}}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {{
  throw "missing --command-manifest-json argument: $($CollectorArgs -join ' ')"
}}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {{
  throw "missing --output argument: $($CollectorArgs -join ' ')"
}}
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$Targets = @($Manifest.targets)
if ($Targets.Count -ne 1 -or $Targets[0] -ne "//pkg:target") {{
  throw "unexpected targets: $($Targets -join ',')"
}}
$TestFlags = @($Manifest.test_flags)
if ($TestFlags.Count -ne 1 -or $TestFlags[0] -ne "--remote_download_regex=.*test[.]outputs.*") {{
  throw "unexpected test flags: $($TestFlags -join ',')"
}}
$BepFiles = @($Manifest.bep_files)
if ($BepFiles.Count -ne 1 -or -not $BepFiles[0].EndsWith(".bep.json")) {{
  throw "unexpected BEP files: $($BepFiles -join ',')"
}}
if (-not $Manifest.doctor_report_json.EndsWith("custom-doctor.json")) {{
  throw "unexpected doctor report: $($Manifest.doctor_report_json)"
}}
if ($Manifest.upload_enabled -ne $false) {{
  throw "unexpected upload flag: $($Manifest.upload_enabled)"
}}
if ([string]::IsNullOrWhiteSpace($Manifest.artifact_staging_dir)) {{
  throw "missing artifact staging dir"
}}
[System.IO.File]::WriteAllBytes($OutputPath, [System.Text.Encoding]::UTF8.GetBytes("fake support bundle"))
exit 0
""",
                encoding="utf-8",
            )
            fake_python.chmod(0o755)
            tmpdir = root / "tmp"
            tmpdir.mkdir()
            env = os.environ.copy()
            env["DD_TEST_OPTIMIZATION_TMPDIR"] = str(tmpdir)
            env["DD_TEST_OPTIMIZATION_PYTHON"] = str(fake_python)

            result = subprocess.run(
                [
                    pwsh,
                    "-NoLogo",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(wrapper),
                    "-Bazel",
                    str(fake_bazel),
                    "-KeepTmp",
                    "-ReportDir",
                    str(root / "reports"),
                    "-DoctorReportJson",
                    str(root / "custom-doctor.json"),
                    "-TestFlag",
                    "--remote_download_regex=.*test[.]outputs.*",
                    "-SupportBundle",
                    str(root / "support.zip"),
                    "-SupportBundleCollector",
                    str(fake_collector),
                    "//pkg:target",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(7, result.returncode, result.stderr)
            failure_output = result.stderr + result.stdout
            self.assertTrue(collector_log.exists(), failure_output)
            collector_args = collector_log.read_text(encoding="utf-8")
            self.assertTrue((root / "support.zip").exists(), failure_output + "\n" + collector_args)
            self.assertIn("--command-manifest-json=", collector_args)
            self.assertIn(f"--report-json={root / 'custom-doctor.json'}", collector_args)
            self.assertIn("--tmp-root=", collector_args)
            self.assertIn("--bep-json=", collector_args)


class ReportSummaryRendererTests(unittest.TestCase):
    """Test case group covering customer-facing diagnostic summary rendering."""

    def test_render_report_summary_explains_dry_run_no_upload(self) -> None:
        """Validate summary renderer prints the no-upload reason and next step."""
        mod = _load_module("render_report_summary", "tools/test_optimization/render_report_summary.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            doctor = root / "doctor-report.json"
            uploader = root / "uploader-dry-run-report.json"
            doctor.write_text(
                json.dumps({
                    "tool": "dd-test-optimization-doctor",
                    "result": {
                        "status": "ok",
                        "reason_code": "ok",
                        "reason": "Doctor validation succeeded.",
                        "next_steps": [],
                    },
                    "summary": {"expected_targets": 3, "payloads": {"tests": 5, "coverage": 0, "telemetry": 8}},
                    "bep": {"eligible_outputs": 3, "cached_outputs": 0, "remote_only_outputs": []},
                    "artifacts": {"staged_count": 3},
                }),
                encoding="utf-8",
            )
            uploader.write_text(
                json.dumps({
                    "tool": "dd-test-optimization-uploader",
                    "result": {
                        "status": "ok",
                        "reason_code": "upload_skipped_dry_run",
                        "reason": "Dry-run completed successfully; real upload was not requested.",
                        "next_steps": ["Run again with --upload to send payloads."],
                    },
                    "upload": {"attempted": False, "dry_run": True},
                    "payloads": {"discovered": {"tests": 5, "coverage": 0, "telemetry": 8}},
                }),
                encoding="utf-8",
            )

            text = mod.render_summary([doctor, uploader])

        self.assertIn("Reason: upload_skipped_dry_run", text)
        self.assertIn("Payloads discovered: tests=5, coverage=0, telemetry=8", text)
        self.assertIn("Run again with --upload", text)


class SupportBundleTests(unittest.TestCase):
    """Test case group covering support bundle collection."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.mod = _load_module(
            "create_support_bundle",
            "tools/test_optimization/create_support_bundle.py",
        )

    def test_create_support_bundle_writes_redacted_zip(self) -> None:
        """Validate support bundle zip content and redaction behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report_dir = root / "reports"
            report_dir.mkdir()
            long_reason = "remote bytestream://remote-cas/blobs/abc/123?token=secret " + ("x" * 20005)
            doctor_report = report_dir / "doctor-report.json"
            doctor_report.write_text(
                json.dumps({
                    "tool": "dd-test-optimization-doctor",
                    "result": {
                        "status": "fail",
                        "reason_code": "bep_output_remote_only_without_downloader",
                        "reason": long_reason,
                        "next_steps": ["Use --remote_download_regex to materialize outputs."],
                    },
                    "summary": {"payloads": {"tests": 2, "coverage": 0, "telemetry": 1}},
                    "config": {"workspace": str(root), "testlogs_dir": str(root / "bazel-testlogs")},
                    "outputs": [{"path": str(root / "bazel-testlogs" / "pkg" / "target" / "test.outputs")}],
                    "bep": {"remote_only_outputs": [{"uri": "https://example.invalid/a?X-Amz-Signature=abc"}]},
                }),
                encoding="utf-8",
            )
            bep = root / "one.bep.json"
            bep.write_text(
                json.dumps({
                    "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                    "testResult": {
                        "cachedLocally": False,
                        "testActionOutput": [
                            {
                                "name": "outputs.zip",
                                "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                                "pathPrefix": [
                                    "bazel-out",
                                    "darwin_arm64-fastbuild",
                                    "testlogs",
                                    "pkg",
                                    "target",
                                    "test.outputs",
                                ],
                            }
                        ],
                    },
                }) + "\n",
                encoding="utf-8",
            )
            command_manifest = root / "flags.json"
            command_manifest.write_text(
                json.dumps({
                    "bazel": "/opt/homebrew/bin/bazel",
                    "targets": ["//pkg:target"],
                    "test_flags": [
                        "--remote_download_regex=.*test\\.outputs.*",
                        "--test_env=DD_API_KEY=abc123",
                        "--test_env=DD_AUTHORIZATION=Bearer abc",
                    ],
                    "bep_files": [str(bep)],
                    "artifact_staging_dir": str(root / "tmp" / "bep-artifacts"),
                    "workspace_root": str(root),
                    "output_base": str(root / "output-base"),
                }),
                encoding="utf-8",
            )
            output = root / "support.zip"

            rc = self.mod.main([
                "--report-dir",
                str(report_dir),
                "--bep-json",
                str(bep),
                "--command-manifest-json",
                str(command_manifest),
                "--workspace-root",
                str(root),
                "--output-base",
                str(root / "output-base"),
                "--tmp-root",
                str(root / "tmp"),
                "--output",
                str(output),
            ])

            self.assertEqual(0, rc)
            with zipfile.ZipFile(output) as zf:
                names = set(zf.namelist())
                self.assertIn("diagnostics.json", names)
                self.assertIn("summary.md", names)
                self.assertIn("reports/doctor-report.json", names)
                self.assertIn("bep/1_one.bep.summary.json", names)
                self.assertIn("command/flags.json", names)
                self.assertIn("environment/runtime.json", names)
                diagnostics = json.loads(zf.read("diagnostics.json").decode("utf-8"))
                report_text = zf.read("reports/doctor-report.json").decode("utf-8")
                flags = json.loads(zf.read("command/flags.json").decode("utf-8"))
                summary = zf.read("summary.md").decode("utf-8")
                runtime = zf.read("environment/runtime.json").decode("utf-8")

        self.assertEqual(sorted(names), diagnostics["bundle"]["files"])
        self.assertEqual(
            "bep_output_remote_only_without_downloader",
            diagnostics["summary"]["primary_reason_code"],
        )
        self.assertEqual("fail", diagnostics["summary"]["status"])
        self.assertEqual("bep/1_one.bep.summary.json", diagnostics["bep"][0]["path"])
        self.assertIn("# Datadog Test Optimization Upload Diagnostics", summary)
        self.assertIn("## Support bundle", summary)
        self.assertIn("Primary reason: bep_output_remote_only_without_downloader", summary)
        self.assertNotIn(str(root), report_text)
        self.assertNotIn("X-Amz-Signature=abc", report_text)
        self.assertIn("<workspace>", report_text)
        self.assertNotIn("token=secret", summary)
        self.assertIn("...<truncated", summary)
        self.assertNotIn(str(root), summary)
        self.assertNotIn(str(root), runtime)
        self.assertEqual(str(Path("<tmp>") / "bep-artifacts"), flags["artifact_staging_dir"])
        self.assertEqual(
            [
                "--remote_download_regex=.*test\\.outputs.*",
                "--test_env=DD_API_KEY=<redacted>",
                "--test_env=DD_AUTHORIZATION=<redacted>",
            ],
            flags["test_flags"],
        )
        self.assertNotIn("abc123", json.dumps(flags, sort_keys=True))
        self.assertNotIn("Bearer abc", json.dumps(flags, sort_keys=True))

    def test_create_support_bundle_includes_explicit_report_paths(self) -> None:
        """Validate explicit reports are included before standard report names."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report_dir = root / "reports"
            report_dir.mkdir()
            explicit_report = root / "custom-doctor-report.json"
            explicit_report.write_text(
                json.dumps({
                    "tool": "dd-test-optimization-doctor",
                    "result": {"status": "ok", "reason_code": "ok", "reason": "", "next_steps": []},
                    "summary": {"payloads": {"tests": 1, "coverage": 0, "telemetry": 0}},
                }),
                encoding="utf-8",
            )
            second_dir = root / "other"
            second_dir.mkdir()
            second_report = second_dir / "custom-doctor-report.json"
            second_report.write_text(
                json.dumps({
                    "tool": "dd-test-optimization-uploader",
                    "result": {"status": "ok", "reason_code": "ok", "reason": "", "next_steps": []},
                    "summary": {"payloads": {"tests": 1, "coverage": 0, "telemetry": 0}},
                }),
                encoding="utf-8",
            )
            output = root / "support.zip"

            rc = self.mod.main([
                "--report-dir",
                str(report_dir),
                "--report-json",
                str(explicit_report),
                "--report-json",
                str(second_report),
                "--workspace-root",
                str(root),
                "--output",
                str(output),
            ])

            self.assertEqual(0, rc)
            with zipfile.ZipFile(output) as zf:
                names = set(zf.namelist())
                diagnostics = json.loads(zf.read("diagnostics.json").decode("utf-8"))

        self.assertIn("reports/custom-doctor-report.json", names)
        self.assertIn("reports/custom-doctor-report_2.json", names)
        self.assertEqual(2, diagnostics["summary"]["report_count"])
        self.assertEqual("dd-test-optimization-doctor", diagnostics["reports"][0]["tool"])
        self.assertEqual("dd-test-optimization-uploader", diagnostics["reports"][1]["tool"])

    def test_create_support_bundle_keeps_success_status_with_remote_only_warning(self) -> None:
        """Validate remote-only BEP warnings do not override successful reports."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report_dir = root / "reports"
            report_dir.mkdir()
            (report_dir / "doctor-report.json").write_text(
                json.dumps({
                    "tool": "dd-test-optimization-doctor",
                    "result": {"status": "ok", "reason_code": "ok", "reason": "", "next_steps": []},
                    "summary": {"payloads": {"tests": 1, "coverage": 0, "telemetry": 0}},
                }),
                encoding="utf-8",
            )
            bep = root / "remote.bep.json"
            bep.write_text(
                json.dumps({
                    "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                    "testResult": {
                        "cachedLocally": False,
                        "testActionOutput": [
                            {"name": "outputs.zip", "uri": "bytestream://remote-cas/blobs/deadbeef/123"}
                        ],
                    },
                }) + "\n",
                encoding="utf-8",
            )
            output = root / "support.zip"

            self.mod.main([
                "--report-dir",
                str(report_dir),
                "--bep-json",
                str(bep),
                "--workspace-root",
                str(root),
                "--output",
                str(output),
            ])

            with zipfile.ZipFile(output) as zf:
                diagnostics = json.loads(zf.read("diagnostics.json").decode("utf-8"))

        self.assertEqual("ok", diagnostics["summary"]["status"])
        self.assertEqual(["BEP file 1 contained 1 remote-only uploadable outputs."], diagnostics["summary"]["warnings"])

    def test_create_support_bundle_skips_missing_bep_with_warning(self) -> None:
        """Validate missing BEP paths are warnings, not fatal errors."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report_dir = root / "reports"
            report_dir.mkdir()
            (report_dir / "doctor-report.json").write_text(
                json.dumps({
                    "tool": "dd-test-optimization-doctor",
                    "result": {"status": "ok", "reason_code": "ok", "reason": "", "next_steps": []},
                    "summary": {"payloads": {"tests": 1, "coverage": 0, "telemetry": 0}},
                }),
                encoding="utf-8",
            )
            missing_bep = root / "missing.bep.json"
            output = root / "support.zip"

            rc = self.mod.main([
                "--report-dir",
                str(report_dir),
                "--bep-json",
                str(missing_bep),
                "--workspace-root",
                str(root),
                "--output",
                str(output),
            ])

            self.assertEqual(0, rc)
            with zipfile.ZipFile(output) as zf:
                diagnostics = json.loads(zf.read("diagnostics.json").decode("utf-8"))

        self.assertEqual("ok", diagnostics["summary"]["status"])
        self.assertEqual(0, diagnostics["summary"]["bep_summary_count"])
        self.assertEqual(
            ["BEP file 1 was missing or unreadable and was skipped: missing.bep.json"],
            diagnostics["summary"]["warnings"],
        )

    def test_create_support_bundle_marks_missing_reports_as_failure(self) -> None:
        """Validate a bundle with no usable reports is not reported as ok."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report_dir = root / "reports"
            report_dir.mkdir()
            output = root / "support.zip"

            rc = self.mod.main([
                "--report-dir",
                str(report_dir),
                "--workspace-root",
                str(root),
                "--output",
                str(output),
            ])

            self.assertEqual(0, rc)
            with zipfile.ZipFile(output) as zf:
                diagnostics = json.loads(zf.read("diagnostics.json").decode("utf-8"))

        self.assertEqual("fail", diagnostics["summary"]["status"])
        self.assertEqual("missing_reports", diagnostics["summary"]["primary_reason_code"])
        self.assertEqual(0, diagnostics["summary"]["report_count"])
        self.assertIn(
            "No usable doctor or uploader reports were included.",
            diagnostics["summary"]["warnings"],
        )

    def test_create_support_bundle_skips_malformed_report_with_warning(self) -> None:
        """Validate malformed reports are skipped without losing usable reports."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report_dir = root / "reports"
            report_dir.mkdir()
            (report_dir / "doctor-report.json").write_text("{not-json", encoding="utf-8")
            (report_dir / "uploader-dry-run-report.json").write_text(
                json.dumps({
                    "tool": "dd-test-optimization-uploader",
                    "result": {"status": "ok", "reason_code": "ok", "reason": "", "next_steps": []},
                    "summary": {"payloads": {"tests": 1, "coverage": 0, "telemetry": 0}},
                }),
                encoding="utf-8",
            )
            output = root / "support.zip"

            rc = self.mod.main([
                "--report-dir",
                str(report_dir),
                "--workspace-root",
                str(root),
                "--output",
                str(output),
            ])

            self.assertEqual(0, rc)
            with zipfile.ZipFile(output) as zf:
                diagnostics = json.loads(zf.read("diagnostics.json").decode("utf-8"))
                names = set(zf.namelist())

        self.assertEqual("ok", diagnostics["summary"]["status"])
        self.assertEqual(1, diagnostics["summary"]["report_count"])
        self.assertIn("reports/uploader-dry-run-report.json", names)
        self.assertNotIn("reports/doctor-report.json", names)
        self.assertIn(
            "Report file doctor-report.json was unreadable or malformed and was skipped (JSONDecodeError)",
            diagnostics["summary"]["warnings"],
        )

    def test_summarize_bep_supports_snake_case_and_cached_remote_events(self) -> None:
        """Validate BEP summary supports snake_case and cached remote events."""
        summary = self.mod.summarize_bep(
            _runfile("tools/tests/python/fixtures/bep_snake_case_remote_cached.ndjson")
        )

        self.assertEqual(2, summary["test_result_events"])
        self.assertEqual(["//pkg:remote_only", "//pkg:target"], summary["labels"])
        self.assertEqual(2, summary["labels_total"])
        self.assertFalse(summary["labels_truncated"])
        self.assertEqual(2, summary["uploadable_outputs"])
        self.assertEqual(1, summary["cached_outputs"])
        self.assertEqual(1, summary["remote_only_outputs"])
        self.assertEqual({"test.outputs": 2}, summary["outputs_by_name"])

    def test_summarize_bep_maps_log_xml_outputs_to_test_outputs(self) -> None:
        """Validate log and XML BEP outputs authorize sibling test.outputs."""
        summary = self.mod.summarize_bep(
            _runfile("tools/tests/python/fixtures/bep_captured_bazelw_wrapper_fresh.ndjson")
        )

        self.assertEqual(1, summary["test_result_events"])
        self.assertEqual(["//tools/tests/python:bazelw_wrapper_test"], summary["labels"])
        self.assertEqual(2, summary["uploadable_outputs"])
        self.assertEqual(0, summary["cached_outputs"])
        self.assertEqual(0, summary["remote_only_outputs"])
        self.assertEqual({"test.outputs": 2}, summary["outputs_by_name"])

    def test_summarize_bep_counts_http_and_opaque_remote_artifacts(self) -> None:
        """Validate HTTP and opaque CAS artifacts count as remote-only outputs."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bep = root / "remote-artifacts.bep.json"
            events = [
                {
                    "id": {"testResult": {"label": "//pkg:http", "run": 1, "shard": 1, "attempt": 1}},
                    "testResult": {
                        "testActionOutput": [
                            {
                                "name": "outputs.zip",
                                "uri": "https://user:pass@example.test/outputs.zip?sig=secret#fragment",
                                "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "http", "test.outputs"],
                            }
                        ]
                    },
                },
                {
                    "id": {"test_result": {"label": "//pkg:cas", "run": 1, "shard": 1, "attempt": 1}},
                    "test_result": {
                        "test_action_output": [
                            {"name": "outputs.zip", "uri": "blobs/deadbeef/123"}
                        ]
                    },
                },
            ]
            bep.write_text("\n".join(json.dumps(event) for event in events) + "\n", encoding="utf-8")

            summary = self.mod.summarize_bep(bep)

        self.assertEqual(2, summary["test_result_events"])
        self.assertEqual(["//pkg:cas", "//pkg:http"], summary["labels"])
        self.assertEqual(2, summary["uploadable_outputs"])
        self.assertEqual(0, summary["cached_outputs"])
        self.assertEqual(2, summary["remote_only_outputs"])
        self.assertEqual({"outputs.zip": 2}, summary["outputs_by_name"])

    def test_redact_json_scrubs_secret_like_keys(self) -> None:
        """Validate support bundle redaction scrubs secrets, URLs, and local paths."""
        with tempfile.TemporaryDirectory() as tmp:
            workspace_root = Path(tmp) / "repo"
            data = {
                "DD_API_KEY": "abc",
                "safe": "value",
                "nested": {"token": "secret", "path": str(workspace_root / "file.txt")},
                "url": "https://user:pass@example.test/outputs.zip?sig=secret#fragment",
                "message": "remote bytestream://remote-cas/blobs/deadbeef/123?token=secret",
                "flags": [
                    "--test_env=DD_API_KEY=abc",
                    "--repo_env=TOKEN=secret",
                    "--test_env=DD_AUTHORIZATION=Bearer abc",
                    "SAFE=value",
                ],
            }
            redacted = self.mod.redact_json(
                data,
                workspace_root=workspace_root,
                output_base=None,
                tmp_root=None,
            )
        self.assertEqual("<redacted>", redacted["DD_API_KEY"])
        self.assertEqual("<redacted>", redacted["nested"]["token"])
        self.assertEqual(str(Path("<workspace>") / "file.txt"), redacted["nested"]["path"])
        self.assertEqual("https://example.test/outputs.zip", redacted["url"])
        self.assertIn("token=<redacted>", redacted["message"])
        self.assertEqual(
            [
                "--test_env=DD_API_KEY=<redacted>",
                "--repo_env=TOKEN=<redacted>",
                "--test_env=DD_AUTHORIZATION=<redacted>",
                "SAFE=value",
            ],
            redacted["flags"],
        )
        self.assertEqual("value", redacted["safe"])
        rendered = json.dumps(redacted, sort_keys=True)
        for sensitive in ("abc", "secret", "user", "pass", "fragment"):
            self.assertNotIn(sensitive, rendered)

    def test_bound_json_truncates_large_lists_and_strings(self) -> None:
        """Validate bounded JSON truncates oversized lists and strings."""
        bounded = self.mod.bound_json({
            "items": list(range(105)),
            "message": "x" * 20005,
        })

        self.assertEqual(101, len(bounded["items"]))
        self.assertEqual(
            {"truncated": True, "total_items": 105, "omitted_items": 5},
            bounded["items"][-1],
        )
        self.assertTrue(bounded["message"].endswith("...<truncated 5 chars>"))


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
    def _write_outputs_zip(
        zip_path: Path,
        *,
        target: str = "//pkg:remote_only",
        payload_name: str = "span_events_1.json",
        payload_content: str = "{}",
    ) -> None:
        """Create a minimal Bazel outputs.zip carrier for staging tests."""
        zip_path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path, "w") as archive:
            archive.writestr(f"payloads/tests/{payload_name}", payload_content)
            archive.writestr(
                "bazel_target_metadata.json",
                json.dumps({
                    "bazel.target": target,
                    "bazel.go.payload_selection": "module",
                }),
            )

    def _http_outputs_zip_freshness(self, root: Path, url: str, *, label: str = "//pkg:remote_only") -> object:
        """Create BEP freshness for one HTTP outputs.zip carrier."""
        bep = root / "freshness.bep.json"
        target = label.split(":")[-1]
        self._write_bep(
            bep,
            [
                {
                    "id": {"testResult": {"label": label, "run": 1, "shard": 1, "attempt": 1}},
                    "testResult": {
                        "status": "PASSED",
                        "testActionOutput": [
                            {
                                "name": "test.outputs",
                                "uri": url,
                                "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", target],
                            },
                        ],
                    },
                },
            ],
        )
        return self.mod._parse_bep_freshness([bep])

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

    def _remote_outputs_zip_freshness(self, root: Path, *, label: str = "//pkg:remote_only") -> object:
        """Create BEP freshness for one remote stageable outputs.zip carrier."""
        bep = root / "freshness.bep.json"
        self._write_bep(
            bep,
            [
                {
                    "id": {"testResult": {"label": label, "run": 1, "shard": 1, "attempt": 1}},
                    "testResult": {
                        "status": "PASSED",
                        "testActionOutput": [
                            {
                                "name": "test.outputs",
                                "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                                "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "remote_only"],
                            },
                        ],
                    },
                },
            ],
        )
        return self.mod._parse_bep_freshness([bep])

    @staticmethod
    def _write_python_downloader(path: Path, source: str) -> Path:
        """Create a small downloader executable that works on POSIX and Windows."""
        script = path.with_suffix(".py")
        script.write_text("#!/usr/bin/env python3\n" + source.lstrip(), encoding="utf-8")
        if os.name == "nt":
            launcher = path.with_suffix(".cmd")
            launcher.write_text(
                f'@echo off\r\n"{sys.executable}" "{script}" %*\r\nexit /b %ERRORLEVEL%\r\n',
                encoding="utf-8",
            )
            return launcher
        script.chmod(0o755)
        return script

    @staticmethod
    def _extract_single_quoted_block(text: str, variable_name: str) -> str:
        """Extract a single-quoted multiline shell variable body from a template."""
        match = re.search(rf"{re.escape(variable_name)}='\n(?P<body>.*?)\n[ \t]*'", text, re.S)
        if match is None:
            raise AssertionError(f"unable to locate {variable_name}")
        return match.group("body")

    @staticmethod
    def _extract_powershell_function_block(text: str, start: str, end: str) -> str:
        """Extract a contiguous PowerShell function block by marker strings."""
        start_index = text.index(start)
        end_index = text.index(end, start_index)
        return text[start_index:end_index]

    @staticmethod
    def _extract_text_block(text: str, start: str, end: str) -> str:
        """Extract a contiguous text block by marker strings."""
        start_index = text.index(start)
        end_index = text.index(end, start_index)
        return text[start_index:end_index]

    def _python_canonical_bep_output_key(self, output: object) -> str:
        """Return the Python runtime's canonical output key for one BEP output."""
        candidates = self.mod._bep_file_reference_candidates(output)
        for candidate in self.mod._bep_canonical_output_key_candidates(output, candidates):
            output_key = self.mod._bep_test_output_key(candidate)
            if output_key:
                return output_key
        return ""

    def test_python_canonical_bep_output_key_precedence_is_unconditional(self) -> None:
        """Validate canonical Python output-key precedence without jq/pwsh availability."""
        cases: list[tuple[str, object, str]] = [
            (
                "pathPrefix beats external carrier uri",
                {
                    "name": "test.outputs",
                    "uri": "file:///tmp/workspace/.topt/simulated-remote-artifacts/app/hello_test/test.outputs",
                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "app", "hello_test"],
                },
                "app/hello_test/test.outputs",
            ),
            (
                "path beats external carrier uri",
                {
                    "name": "test.outputs",
                    "uri": "file:///tmp/workspace/.topt/simulated-remote-artifacts/pkg/path_target/test.outputs",
                    "path": "bazel-out/k8-fastbuild/testlogs/pkg/path_target/test.outputs",
                },
                "pkg/path_target/test.outputs",
            ),
            (
                "arbitrary external carrier has no key",
                {
                    "name": "test.outputs",
                    "uri": "file:///tmp/copied/test.outputs",
                },
                "",
            ),
            (
                "bare carrier name has no key",
                {"name": "test.outputs"},
                "",
            ),
            (
                "opaque remote carrier without metadata has no key",
                {
                    "name": "test.outputs",
                    "uri": "bytestream://remote-cas/blobs/no-key/123",
                },
                "",
            ),
        ]

        for name, output, expected in cases:
            with self.subTest(name=name):
                self.assertEqual(expected, self._python_canonical_bep_output_key(output))

    def _bash_jq_canonical_bep_output_keys(self, cases: list[dict[str, object]]) -> dict[str, str]:
        """Run Bash runtime jq functions against BEP output-key parity cases."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        key_defs = self._extract_single_quoted_block(bash_text, "bep_test_output_key_jq")
        remote_defs = self._extract_single_quoted_block(bash_text, "is_remote_only_bep_reference_jq")
        jq_program = key_defs + "\n" + remote_defs + r"""
def field($obj; $camel; $snake):
  ($obj[$camel] // $obj[$snake]);
def candidates($output):
  if ($output | type) == "string" then [$output]
  else
    ($output.name // "") as $name
    | (field($output; "pathPrefix"; "path_prefix") // []) as $path_prefix
    | [
        ($output.uri // ""),
        ($output.path // ""),
        $name,
        (if (($path_prefix | type) == "array" and ($name | type) == "string" and $name != "")
         then (($path_prefix + [$name]) | map(select(type == "string" and . != "")) | join("/"))
         else ""
         end)
      ]
  end
  | map(select(type == "string" and . != ""));
.[] as $case
| ($case.output) as $output
| (candidates($output)) as $raw_candidates
| ([
    bep_canonical_output_key_candidates($output; $raw_candidates)[]?
    | test_outputs_key
    | select(. != "")
  ] | .[0] // "") as $output_key
| [$case.name, $output_key]
| @tsv
"""
        result = subprocess.run(
            ["jq", "-r", jq_program],
            input=json.dumps(cases),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return dict(line.split("\t", 1) for line in result.stdout.splitlines() if line)

    def _powershell_canonical_bep_output_keys(self, cases: list[dict[str, object]]) -> dict[str, str]:
        """Run PowerShell runtime functions against BEP output-key parity cases."""
        powershell_text = self._generated_powershell_runtime_text()
        script = "\n".join([
            "$ErrorActionPreference = 'Stop'",
            self._extract_powershell_function_block(
                powershell_text,
                "function Get-MapValue",
                "function Get-StringPropertyValue",
            ),
            self._extract_powershell_function_block(
                powershell_text,
                "function Get-BepTestOutputKey",
                "function Initialize-BepEligibility",
            ),
            r"""
$cases = [Console]::In.ReadToEnd() | ConvertFrom-Json
$rows = New-Object System.Collections.Generic.List[object]
foreach ($case in @($cases)) {
  $output = $case.output
  $rawCandidates = @(Get-BepFileReferenceCandidates $output)
  $outputKey = ""
  foreach ($candidate in @(Get-BepCanonicalOutputKeyCandidates $output $rawCandidates)) {
    $candidateKey = Get-BepTestOutputKey $candidate
    if (-not [string]::IsNullOrWhiteSpace($candidateKey)) {
      $outputKey = $candidateKey
      break
    }
  }
  $rows.Add([pscustomobject]@{ name = [string]$case.name; key = $outputKey }) | Out-Null
}
$rows | ConvertTo-Json -Compress
""",
        ])
        result = subprocess.run(
            ["pwsh", "-NoLogo", "-NoProfile", "-Command", script],
            input=json.dumps(cases),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        rows = json.loads(result.stdout or "[]")
        if isinstance(rows, dict):
            rows = [rows]
        return {str(row["name"]): str(row.get("key", "")) for row in rows}

    def _generated_powershell_runtime_text(self) -> str:
        """Return the rendered PowerShell uploader used by parity tests."""
        try:
            return _runfile("tools/tests/python/fixtures/generated_uploader/generated_uploader.ps1").read_text(
                encoding="utf-8"
            )
        except FileNotFoundError:
            if os.environ.get("TEST_SRCDIR"):
                raise
            return _render_uploader_runtime_template("tools/core/uploader_powershell_runtime.ps1.tpl")

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

    def test_parse_args_accepts_bep_artifact_resolution_flags(self) -> None:
        """Validate doctor accepts BEP artifact resolution flags."""
        args = self.mod._parse_args([
            "--config",
            "doctor.config.json",
            "--artifact-source=bep",
            "--remote-artifacts=download",
            "--artifact-staging-dir=.topt/custom-bep-artifacts",
            "--bep-artifact-downloader=/tmp/fetcher",
            "--bep-artifact-downloader-timeout-sec=1.5",
        ])

        self.assertEqual("bep", args.artifact_source)
        self.assertEqual("download", args.remote_artifacts)
        self.assertEqual(".topt/custom-bep-artifacts", args.artifact_staging_dir)
        self.assertEqual("/tmp/fetcher", args.bep_artifact_downloader)
        self.assertEqual(1.5, args.bep_artifact_downloader_timeout_sec)

    def test_parse_args_accepts_support_bundle_flag(self) -> None:
        """Validate doctor accepts a first-class support bundle output path."""
        args = self.mod._parse_args([
            "--config",
            "doctor.config.json",
            "--support-bundle",
            ".topt/reports/dd-test-optimization-support.zip",
        ])

        self.assertEqual(".topt/reports/dd-test-optimization-support.zip", args.support_bundle)

    def test_doctor_report_json_success_includes_payload_diagnostics(self) -> None:
        """Validate doctor writes a machine-readable report for successful local validation."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = self._write_doctor_output(root, "module", "//pkg:target")
            config_path = self._write_doctor_config(root, ["//pkg:target"])
            report_path = root / "doctor-report.json"

            with mock.patch.dict(
                os.environ,
                {"TESTLOGS_DIR": str(root), "BUILD_WORKSPACE_DIRECTORY": str(root)},
            ):
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--report-json",
                    str(report_path),
                ])

            report = json.loads(report_path.read_text(encoding="utf-8"))

        self.assertEqual(0, rc)
        self.assertEqual(1, report["schema_version"])
        self.assertEqual("dd-test-optimization-doctor", report["tool"])
        self.assertEqual("ok", report["status"])
        self.assertEqual("ok", report["result"]["status"])
        self.assertEqual("ok", report["result"]["reason_code"])
        self.assertEqual([], report["result"]["next_steps"])
        self.assertEqual(["//pkg:target"], report["config"]["expected_targets"])
        self.assertEqual(["//pkg:target"], report["targets"]["expected"])
        self.assertEqual([], report["targets"]["missing"])
        self.assertEqual(1, report["summary"]["validated_output_dirs"])
        self.assertEqual(1, report["summary"]["payloads"]["json"])
        self.assertEqual({"module": 1}, report["summary"]["payload_selection"])
        self.assertEqual([], report["errors"])
        self.assertEqual(1, len(report["outputs"]))
        output_report = report["outputs"][0]
        self.assertEqual(str(output.resolve()), output_report["path"])
        self.assertEqual("//pkg:target", output_report["label"])
        self.assertEqual("local", output_report["source"])
        self.assertEqual(1, output_report["payloads"]["json"])
        self.assertEqual(1, output_report["payloads"]["tests"])
        self.assertEqual(1, output_report["metadata"]["count"])
        self.assertEqual("module", output_report["metadata"]["payload_selection"])

    def test_doctor_support_bundle_success_includes_doctor_report_without_report_json(self) -> None:
        """Validate doctor-only support bundle creation does not require a report-json path."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = self._write_doctor_output(root, "module", "//pkg:target")
            config_path = self._write_doctor_config(root, ["//pkg:target"])
            bundle_path = root / "dd-test-optimization-support.zip"

            with mock.patch.dict(
                os.environ,
                {"TESTLOGS_DIR": str(root), "BUILD_WORKSPACE_DIRECTORY": str(root)},
            ):
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--support-bundle",
                    str(bundle_path),
                ])

            with zipfile.ZipFile(bundle_path) as zf:
                names = set(zf.namelist())
                diagnostics = json.loads(zf.read("diagnostics.json").decode("utf-8"))
                doctor_report = json.loads(zf.read("reports/doctor-report.json").decode("utf-8"))
                command = json.loads(zf.read("command/flags.json").decode("utf-8"))

        self.assertEqual(0, rc)
        self.assertIn("summary.md", names)
        self.assertIn("environment/runtime.json", names)
        self.assertEqual("ok", diagnostics["summary"]["status"])
        self.assertEqual("ok", diagnostics["summary"]["primary_reason_code"])
        self.assertEqual(1, diagnostics["summary"]["report_count"])
        self.assertEqual("dd-test-optimization-doctor", doctor_report["tool"])
        self.assertEqual("ok", doctor_report["result"]["status"])
        self.assertEqual(
            str(Path("<workspace>") / "pkg" / "target" / "test.outputs"),
            doctor_report["outputs"][0]["path"],
        )
        self.assertNotIn(str(root), json.dumps(doctor_report, sort_keys=True))
        self.assertEqual("doctor", command["source"])
        self.assertEqual("doctor_only_no_uploader", command["upload_mode"])
        self.assertEqual(["//pkg:target"], command["targets"])

    def test_doctor_report_json_failure_includes_error_and_partial_outputs(self) -> None:
        """Validate doctor writes partial diagnostics before raising controlled failures."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = self._write_doctor_output(root, "module", "//pkg:target")
            shutil.rmtree(output / "payloads")
            config_path = self._write_doctor_config(root, ["//pkg:target"])
            report_path = root / "doctor-report.json"
            stderr = io.StringIO()

            with (
                mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root), "BUILD_WORKSPACE_DIRECTORY": str(root)}),
                mock.patch("sys.stderr", stderr),
            ):
                with self.assertRaises(SystemExit) as raised:
                    self.mod.main([
                        "--config",
                        str(config_path),
                        "--report-json",
                        str(report_path),
                    ])

            report = json.loads(report_path.read_text(encoding="utf-8"))

        self.assertEqual(1, raised.exception.code)
        self.assertIn("missing JSON payloads", stderr.getvalue())
        self.assertEqual("fail", report["status"])
        self.assertTrue(report["errors"])
        self.assertIn("missing JSON payloads", report["errors"][0])
        self.assertEqual(1, report["summary"]["validated_output_dirs"])
        self.assertEqual(0, report["summary"]["payloads"]["json"])
        self.assertEqual(1, len(report["outputs"]))
        self.assertEqual(str(output.resolve()), report["outputs"][0]["path"])
        self.assertEqual(0, report["outputs"][0]["payloads"]["json"])

    def test_doctor_support_bundle_failure_preserves_exit_and_writes_bundle(self) -> None:
        """Validate support bundle creation does not mask doctor validation failure."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = self._write_doctor_output(root, "module", "//pkg:target")
            shutil.rmtree(output / "payloads")
            config_path = self._write_doctor_config(root, ["//pkg:target"])
            bundle_path = root / "dd-test-optimization-support.zip"
            stderr = io.StringIO()

            with (
                mock.patch.dict(os.environ, {"TESTLOGS_DIR": str(root), "BUILD_WORKSPACE_DIRECTORY": str(root)}),
                mock.patch("sys.stderr", stderr),
            ):
                with self.assertRaises(SystemExit) as raised:
                    self.mod.main([
                        "--config",
                        str(config_path),
                        "--support-bundle",
                        str(bundle_path),
                    ])

            with zipfile.ZipFile(bundle_path) as zf:
                diagnostics = json.loads(zf.read("diagnostics.json").decode("utf-8"))
                doctor_report = json.loads(zf.read("reports/doctor-report.json").decode("utf-8"))

        self.assertEqual(1, raised.exception.code)
        self.assertIn("missing JSON payloads", stderr.getvalue())
        self.assertEqual("fail", diagnostics["summary"]["status"])
        self.assertEqual("no_payload_json_found", diagnostics["summary"]["primary_reason_code"])
        self.assertEqual("fail", doctor_report["result"]["status"])
        self.assertEqual("no_payload_json_found", doctor_report["result"]["reason_code"])

    def test_doctor_report_json_classifies_cached_bep_outputs(self) -> None:
        """Validate doctor reports cached BEP outputs as the primary no-upload reason."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            testlogs = root / "bazel-testlogs"
            output = self._write_doctor_output(testlogs, "module")
            bep = root / "cached.ndjson"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "cachedLocally": True,
                            "testActionOutput": [
                                {"name": "test.outputs", "uri": output.as_uri()},
                            ],
                        },
                    },
                ],
            )
            config = self._write_doctor_config(root, ["//pkg:target"])
            report_path = root / "doctor-report.json"

            with mock.patch.dict(
                os.environ,
                {"TESTLOGS_DIR": str(testlogs), "BUILD_WORKSPACE_DIRECTORY": str(root)},
            ):
                with self.assertRaises(SystemExit):
                    self.mod.main([
                        "--config",
                        str(config),
                        "--bep-json",
                        str(bep),
                        "--freshness-source=bep",
                        "--freshness-mode=required",
                        "--report-json",
                        str(report_path),
                    ])

            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual("fail", report["result"]["status"])
            self.assertEqual("target_cached_by_bazel", report["result"]["reason_code"])
            self.assertEqual(["//pkg:target"], report["targets"]["cached"])

    def test_doctor_report_json_classifies_remote_only_without_downloader(self) -> None:
        """Validate strict BEP artifact mode reports remote-only artifacts without a downloader."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = self._write_doctor_config(root, ["//pkg:remote_only"])
            bep = root / "remote-only.ndjson"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:remote_only", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "executionInfo": {"strategy": "remote"},
                            "testActionOutput": [
                                {
                                    "name": "outputs.zip",
                                    "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                                    "pathPrefix": [
                                        "bazel-out",
                                        "k8-fastbuild",
                                        "testlogs",
                                        "pkg",
                                        "remote_only",
                                        "test.outputs",
                                    ],
                                },
                            ],
                        },
                    },
                ],
            )
            report_path = root / "doctor-report.json"

            with mock.patch.dict(os.environ, {"BUILD_WORKSPACE_DIRECTORY": str(root)}, clear=False):
                os.environ.pop("TESTLOGS_DIR", None)
                with self.assertRaises(SystemExit):
                    self.mod.main([
                        "--config",
                        str(config),
                        "--bep-json",
                        str(bep),
                        "--freshness-source=bep",
                        "--freshness-mode=required",
                        "--artifact-source=bep",
                        "--remote-artifacts=required",
                        "--report-json",
                        str(report_path),
                    ])

            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual("fail", report["result"]["status"])
            self.assertEqual("bep_output_remote_only_without_downloader", report["result"]["reason_code"])
            self.assertEqual(["//pkg:remote_only"], report["targets"]["remote_only"])

    def test_doctor_report_json_includes_bep_staged_outputs_zip(self) -> None:
        """Validate report records BEP-selected outputs.zip staging diagnostics."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            zip_path = (
                root
                / "execroot"
                / "bazel-out"
                / "k8-fastbuild"
                / "testlogs"
                / "pkg"
                / "zip_target"
                / "test.outputs"
                / "outputs.zip"
            )
            zip_path.parent.mkdir(parents=True)
            with zipfile.ZipFile(zip_path, "w") as archive:
                archive.writestr("payloads/tests/span_events_1.json", "{}")
                archive.writestr(
                    "bazel_target_metadata.json",
                    json.dumps({
                        "bazel.target": "//pkg:zip_target",
                        "bazel.go.payload_selection": "module",
                    }),
                )
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:zip_target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [{"uri": zip_path.as_uri()}],
                        },
                    },
                ],
            )
            report_path = root / "doctor-report.json"

            with mock.patch.dict(
                os.environ,
                {"BUILD_WORKSPACE_DIRECTORY": str(root), "TESTLOGS_DIR": ""},
                clear=False,
            ):
                os.environ.pop("TESTLOGS_DIR", None)
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=bep",
                    "--artifact-staging-dir",
                    str(root / ".topt" / "bep-artifacts"),
                    "--report-json",
                    str(report_path),
                ])

            report = json.loads(report_path.read_text(encoding="utf-8"))

        self.assertEqual(0, rc)
        self.assertEqual("ok", report["status"])
        self.assertEqual([str(bep.resolve())], report["bep"]["files"])
        self.assertEqual(1, report["bep"]["eligible_outputs"])
        self.assertEqual(0, report["bep"]["cached_outputs"])
        self.assertEqual([], report["bep"]["remote_only_outputs"])
        self.assertEqual([["//pkg:zip_target", "pkg/zip_target/test.outputs"]], report["bep"]["selected_artifact_outputs"])
        self.assertEqual(1, report["artifacts"]["staged_count"])
        self.assertEqual(1, len(report["artifacts"]["staged"]))
        self.assertFalse(report["artifacts"]["staged"][0]["downloaded"])
        self.assertEqual("outputs_zip", report["artifacts"]["staged"][0]["carrier"])
        self.assertEqual(1, len(report["outputs"]))
        self.assertEqual("staged", report["outputs"][0]["source"])
        self.assertEqual("//pkg:zip_target", report["outputs"][0]["label"])
        self.assertEqual(1, report["outputs"][0]["payloads"]["json"])

    def test_doctor_report_redacts_http_remote_only_artifact(self) -> None:
        """Validate doctor report redacts signed HTTP remote-only artifact URIs."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = self._write_doctor_config(root, ["//pkg:remote_only"])
            bep = root / "remote-only.ndjson"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:remote_only", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "executionInfo": {"strategy": "remote"},
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": "https://user:pass@example.test/outputs.zip?sig=secret-token#fragment",
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "remote_only"],
                                },
                            ],
                        },
                    },
                ],
            )
            report_path = root / "doctor-report.json"
            stderr = io.StringIO()

            with (
                mock.patch.dict(os.environ, {"BUILD_WORKSPACE_DIRECTORY": str(root)}, clear=False),
                mock.patch("sys.stderr", stderr),
            ):
                os.environ.pop("TESTLOGS_DIR", None)
                with self.assertRaises(SystemExit):
                    self.mod.main([
                        "--config",
                        str(config),
                        "--bep-json",
                        str(bep),
                        "--freshness-source=bep",
                        "--freshness-mode=required",
                        "--artifact-source=bep",
                        "--remote-artifacts=disabled",
                        "--report-json",
                        str(report_path),
                    ])

            report_text = report_path.read_text(encoding="utf-8")
            report = json.loads(report_text)

        self.assertEqual("https://example.test/outputs.zip", report["bep"]["remote_only_outputs"][0]["artifact"])
        for sensitive in ("secret-token", "fragment", "user", "pass"):
            self.assertNotIn(sensitive, report_text)
            self.assertNotIn(sensitive, stderr.getvalue())

    def test_doctor_report_redacts_http_staged_fetch_value(self) -> None:
        """Validate doctor staged artifact diagnostics redact signed HTTP fetch values."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            served_root = root / "http"
            self._write_outputs_zip(served_root / "outputs.zip", target="//pkg:remote_only")
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            with _serve_directory(served_root) as base_url:
                self._write_bep(
                    bep,
                    [
                        {
                            "id": {"testResult": {"label": "//pkg:remote_only", "run": 1, "shard": 1, "attempt": 1}},
                            "testResult": {
                                "status": "PASSED",
                                "testActionOutput": [
                                    {
                                        "name": "test.outputs",
                                        "uri": f"{base_url}/outputs.zip?sig=secret-token#fragment",
                                        "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "remote_only"],
                                    },
                                ],
                            },
                        },
                    ],
                )
                report_path = root / "doctor-report.json"
                with mock.patch.dict(
                    os.environ,
                    {"BUILD_WORKSPACE_DIRECTORY": str(root), "TESTLOGS_DIR": ""},
                    clear=False,
                ):
                    os.environ.pop("TESTLOGS_DIR", None)
                    rc = self.mod.main([
                        "--config",
                        str(config_path),
                        "--bep-json",
                        str(bep),
                        "--freshness-source=bep",
                        "--freshness-mode=required",
                        "--artifact-source=bep",
                        "--remote-artifacts=required",
                        "--report-json",
                        str(report_path),
                    ])
                expected = f"{base_url}/outputs.zip"
                report_text = report_path.read_text(encoding="utf-8")
                report = json.loads(report_text)

        self.assertEqual(0, rc)
        self.assertEqual(expected, report["artifacts"]["staged"][0]["fetch_value"])
        self.assertNotIn("secret-token", report_text)
        self.assertNotIn("fragment", report_text)

    def test_parse_args_rejects_scientific_downloader_timeout(self) -> None:
        """Validate downloader timeout rejects scientific notation before staging."""
        with self.assertRaises(SystemExit):
            self.mod._parse_args([
                "--config",
                "doctor.config.json",
                "--bep-artifact-downloader-timeout-sec=1e3",
            ])

    def test_parse_args_rejects_invalid_artifact_resolution_env_defaults(self) -> None:
        """Validate env defaults fail through controlled artifact resolution errors."""
        cases = [
            (
                {"DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE": "remote"},
                "unsupported artifact-source 'remote'",
            ),
            (
                {"DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS": "maybe"},
                "unsupported remote-artifacts 'maybe'",
            ),
            (
                {"DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER_TIMEOUT_SEC": "1e3"},
                "--bep-artifact-downloader-timeout-sec must be a finite number greater than zero",
            ),
        ]
        for env, expected in cases:
            with self.subTest(env=env):
                stderr = io.StringIO()
                with (
                    mock.patch.dict(os.environ, env, clear=False),
                    mock.patch("sys.stderr", stderr),
                    self.assertRaises(SystemExit),
                ):
                    self.mod._parse_args(["--config", "doctor.config.json"])
                error = stderr.getvalue()
                self.assertIn(expected, error)
                self.assertIn("[dd-test-optimization-doctor]", error)
                self.assertNotIn("Traceback", error)
                self.assertNotIn("usage:", error)

    def test_local_artifact_path_from_file_uri_normalizes_windows_drive(self) -> None:
        """Validate Windows drive-letter file URIs are converted before Path handling."""
        self.assertEqual(
            Path("C:/tmp/out/test.outputs"),
            self.mod._local_artifact_path_from_reference("file:///C:/tmp/out/test.outputs"),
        )
        self.assertEqual(
            Path("C:/tmp/out/test.outputs"),
            self.mod._local_artifact_path_from_reference("file://localhost/C:/tmp/out/test.outputs"),
        )

    def test_local_artifact_path_from_file_uri_preserves_unc_share(self) -> None:
        """Validate UNC file URI references keep their server/share prefix."""
        self.assertEqual(
            Path("//server/share/out/test.outputs"),
            self.mod._local_artifact_path_from_reference("file://server/share/out/test.outputs"),
        )

    def test_doctor_stages_bep_artifact_when_local_testlogs_are_missing(self) -> None:
        """Validate doctor can validate BEP-staged payloads without local bazel-testlogs."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_output = self._write_doctor_output(root / "external-artifacts", "module", "//pkg:target")
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": source_output.as_uri(),
                                    "pathPrefix": [
                                        "bazel-out",
                                        "k8-fastbuild",
                                        "testlogs",
                                        "pkg",
                                        "target",
                                    ],
                                },
                            ],
                        },
                    },
                ],
            )

            with mock.patch.dict(
                os.environ,
                {"BUILD_WORKSPACE_DIRECTORY": str(root)},
                clear=False,
            ):
                os.environ.pop("TESTLOGS_DIR", None)
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=bep",
                    "--remote-artifacts=download",
                    "--artifact-staging-dir",
                    str(root / ".topt" / "bep-artifacts"),
                ])

        self.assertEqual(0, rc)

    def test_doctor_artifact_source_local_does_not_stage_bep_artifacts(self) -> None:
        """Validate local artifact source preserves local-only output discovery."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_output = self._write_doctor_output(root / "external-artifacts", "module", "//pkg:target")
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": source_output.as_uri(),
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
                                },
                            ],
                        },
                    },
                ],
            )

            with mock.patch.dict(os.environ, {"BUILD_WORKSPACE_DIRECTORY": str(root)}, clear=False):
                os.environ.pop("TESTLOGS_DIR", None)
                with self.assertRaises(SystemExit):
                    self.mod.main([
                        "--config",
                        str(config_path),
                        "--bep-json",
                        str(bep),
                        "--freshness-source=bep",
                        "--freshness-mode=required",
                        "--artifact-source=local",
                    ])

    def test_doctor_auto_download_staged_output_wins_over_stale_local_same_key(self) -> None:
        """Validate auto staging does not trust stale local output keys."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            custom_testlogs = root / "custom-output-root"
            stale_local = self._write_doctor_output(custom_testlogs, "full_bundle_disabled", "//pkg:target")
            fresh_external = self._write_doctor_output(root / "external-artifacts", "module", "//pkg:target")
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": fresh_external.as_uri(),
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
                                },
                            ],
                        },
                    },
                ],
            )

            with mock.patch.dict(
                os.environ,
                {
                    "BUILD_WORKSPACE_DIRECTORY": str(root),
                    "TESTLOGS_DIR": str(custom_testlogs),
                },
                clear=False,
            ):
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=auto",
                    "--remote-artifacts=download",
                    "--artifact-staging-dir",
                    str(root / ".topt" / "bep-artifacts"),
                ])

            self.assertEqual(0, rc)
            self.assertTrue((stale_local / "payloads" / "tests" / "span_events_1.json").is_file())
            runs_root = root / ".topt" / "bep-artifacts" / "__runs"
            self.assertEqual([], list(runs_root.iterdir()) if runs_root.exists() else [])

    def test_doctor_staged_freshness_uses_bep_label_over_payload_metadata(self) -> None:
        """Validate staged freshness is authorized by the BEP test label."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_doctor_output(root / "bazel-testlogs", "module", "//pkg:stale")
            fresh_external = self._write_doctor_output(root / "external-artifacts", "module", "//pkg:public")
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:raw", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": fresh_external.as_uri(),
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
                                },
                            ],
                        },
                    },
                ],
            )

            with mock.patch.dict(
                os.environ,
                {
                    "BUILD_WORKSPACE_DIRECTORY": str(root),
                    "TESTLOGS_DIR": str(root / "bazel-testlogs"),
                },
                clear=False,
            ):
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=bep",
                    "--artifact-staging-dir",
                    str(root / ".topt" / "bep-artifacts"),
                ])

            self.assertEqual(0, rc)

    def test_doctor_expected_target_validation_uses_staged_target_mapping(self) -> None:
        """Validate staged expected targets still enforce per-target payload selection."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_output = self._write_doctor_output(root / "external-artifacts", "module", "//pkg:target")
            config_path = self._write_doctor_config(root, ["//pkg:target"])
            config = json.loads(config_path.read_text(encoding="utf-8"))
            config["expected_payload_selection_by_target"] = {"//pkg:target": "module"}
            config_path.write_text(json.dumps(config), encoding="utf-8")
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": source_output.as_uri(),
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
                                },
                            ],
                        },
                    },
                ],
            )

            with mock.patch.dict(os.environ, {"BUILD_WORKSPACE_DIRECTORY": str(root)}, clear=False):
                os.environ.pop("TESTLOGS_DIR", None)
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=bep",
                    "--remote-artifacts=download",
                    "--artifact-staging-dir",
                    str(root / ".topt" / "bep-artifacts"),
                ])

            self.assertEqual(0, rc)

    def test_doctor_required_remote_disabled_fails_remote_only_freshness(self) -> None:
        """Validate disabling downloads does not authorize stale local fallback in required mode."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_doctor_output(root / "bazel-testlogs", "module", "//pkg:remote_only")
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:remote_only", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
                                },
                            ],
                        },
                    },
                ],
            )

            with mock.patch.dict(
                os.environ,
                {
                    "BUILD_WORKSPACE_DIRECTORY": str(root),
                    "TESTLOGS_DIR": str(root / "bazel-testlogs"),
                },
                clear=False,
            ):
                with self.assertRaises(SystemExit):
                    self.mod.main([
                        "--config",
                        str(config_path),
                        "--bep-json",
                        str(bep),
                        "--freshness-source=bep",
                        "--freshness-mode=required",
                        "--artifact-source=bep",
                        "--remote-artifacts=disabled",
                    ])

    def test_doctor_required_no_key_carrier_fails_before_local_fallback(self) -> None:
        """Validate hinted no-key carriers fail in required artifact mode."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": "file:///tmp/copied/test.outputs",
                                },
                            ],
                        },
                    },
                ],
            )
            stderr = io.StringIO()

            with (
                mock.patch.dict(os.environ, {"BUILD_WORKSPACE_DIRECTORY": str(root)}, clear=False),
                mock.patch("sys.stderr", stderr),
            ):
                os.environ.pop("TESTLOGS_DIR", None)
                with self.assertRaises(SystemExit):
                    self.mod.main([
                        "--config",
                        str(config_path),
                        "--bep-json",
                        str(bep),
                        "--artifact-source=bep",
                        "--remote-artifacts=required",
                        "--freshness-source=bep",
                        "--freshness-mode=required",
                    ])

            self.assertIn("no mappable test.outputs key", stderr.getvalue())

    def test_doctor_download_no_key_carrier_blocks_stale_local_fallback(self) -> None:
        """Validate no-key BEP artifacts cannot authorize stale local payloads."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_doctor_output(root / "bazel-testlogs", "module", "//pkg:target")
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": "file:///tmp/copied/test.outputs",
                                },
                            ],
                        },
                    },
                ],
            )
            stderr = io.StringIO()

            with (
                mock.patch.dict(
                    os.environ,
                    {
                        "BUILD_WORKSPACE_DIRECTORY": str(root),
                        "TESTLOGS_DIR": str(root / "bazel-testlogs"),
                    },
                    clear=False,
                ),
                mock.patch("sys.stderr", stderr),
            ):
                with self.assertRaises(SystemExit):
                    self.mod.main([
                        "--config",
                        str(config_path),
                        "--bep-json",
                        str(bep),
                        "--artifact-source=bep",
                        "--remote-artifacts=download",
                        "--freshness-source=bep",
                        "--freshness-mode=disabled",
                    ])

            self.assertIn("no mappable test.outputs key", stderr.getvalue())

    def test_doctor_remote_artifacts_disabled_preserves_local_only_fallback(self) -> None:
        """Validate disabled artifact staging keeps existing local discovery behavior."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_doctor_output(root / "bazel-testlogs", "module", "//pkg:target")
            config_path = self._write_doctor_config(root, [])
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
                                },
                            ],
                        },
                    },
                ],
            )

            with mock.patch.dict(
                os.environ,
                {
                    "BUILD_WORKSPACE_DIRECTORY": str(root),
                    "TESTLOGS_DIR": str(root / "bazel-testlogs"),
                },
                clear=False,
            ):
                rc = self.mod.main([
                    "--config",
                    str(config_path),
                    "--bep-json",
                    str(bep),
                    "--artifact-source=bep",
                    "--remote-artifacts=disabled",
                    "--freshness-source=bep",
                    "--freshness-mode=disabled",
                ])

            self.assertEqual(0, rc)

    def test_doctor_artifact_source_bep_requires_bep_json(self) -> None:
        """Validate explicit BEP artifact source cannot silently fall back to local mode."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_doctor_output(root / "bazel-testlogs", "module", "//pkg:target")
            config_path = self._write_doctor_config(root, [])
            stderr = io.StringIO()
            with mock.patch.dict(
                os.environ,
                {"BUILD_WORKSPACE_DIRECTORY": str(root), "DD_TEST_OPTIMIZATION_BEP_JSON": ""},
                clear=False,
            ), mock.patch("sys.stderr", stderr):
                with self.assertRaises(SystemExit):
                    self.mod.main([
                        "--config",
                        str(config_path),
                        "--artifact-source=bep",
                    ])
            self.assertIn("--artifact-source=bep requires --bep-json or DD_TEST_OPTIMIZATION_BEP_JSON", stderr.getvalue())

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

    def test_bep_output_key_parity_across_python_bash_and_powershell(self) -> None:
        """Validate all runtimes use the same canonical BEP output-key precedence."""
        _require_command(self, "jq", "jq is required for Bash BEP parser parity")
        _require_command(self, "pwsh", "pwsh is required for PowerShell BEP parser parity")

        cases: list[dict[str, object]] = [
            {
                "name": "pathPrefix beats external carrier uri",
                "output": {
                    "name": "test.outputs",
                    "uri": "file:///tmp/workspace/.topt/simulated-remote-artifacts/app/hello_test/test.outputs",
                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "app", "hello_test"],
                },
                "expected": "app/hello_test/test.outputs",
            },
            {
                "name": "path beats external carrier uri",
                "output": {
                    "name": "test.outputs",
                    "uri": "file:///tmp/workspace/.topt/simulated-remote-artifacts/pkg/path_target/test.outputs",
                    "path": "bazel-out/k8-fastbuild/testlogs/pkg/path_target/test.outputs",
                },
                "expected": "pkg/path_target/test.outputs",
            },
            {
                "name": "trusted uri can provide key",
                "output": {
                    "name": "test.outputs",
                    "uri": "file:///tmp/execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/from_uri/test.outputs",
                },
                "expected": "pkg/from_uri/test.outputs",
            },
            {
                "name": "remote carrier uses canonical pathPrefix",
                "output": {
                    "name": "test.outputs",
                    "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "remote"],
                },
                "expected": "pkg/remote/test.outputs",
            },
            {
                "name": "outputs zip maps to containing test outputs",
                "output": "file:///tmp/execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/zip/outputs.zip",
                "expected": "pkg/zip/test.outputs",
            },
            {
                "name": "test log maps to sibling test outputs",
                "output": "file:///tmp/workspace/bazel-testlogs/pkg/log_target/test.log",
                "expected": "pkg/log_target/test.outputs",
            },
            {
                "name": "arbitrary external carrier has no key",
                "output": {
                    "name": "test.outputs",
                    "uri": "file:///tmp/copied/test.outputs",
                },
                "expected": "",
            },
            {
                "name": "bare carrier name has no key",
                "output": {
                    "name": "test.outputs",
                },
                "expected": "",
            },
            {
                "name": "opaque remote carrier without metadata has no key",
                "output": {
                    "name": "test.outputs",
                    "uri": "bytestream://remote-cas/blobs/no-key/123",
                },
                "expected": "",
            },
        ]

        expected = {str(case["name"]): str(case["expected"]) for case in cases}
        python_keys = {
            str(case["name"]): self._python_canonical_bep_output_key(case["output"])
            for case in cases
        }
        self.assertEqual(expected, python_keys)
        self.assertEqual(expected, self._bash_jq_canonical_bep_output_keys(cases))
        self.assertEqual(expected, self._powershell_canonical_bep_output_keys(cases))

    def test_parse_bep_freshness_records_stageable_file_uri_reference(self) -> None:
        """Validate fresh file:// test.outputs refs are retained for artifact staging."""
        bep = _runfile("tools/tests/python/fixtures/bep_fresh_test_outputs_file_uri.ndjson")

        freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//pkg:target", "pkg/target/test.outputs")}, freshness.eligible_outputs)
        self.assertEqual([], freshness.remote_only_outputs)
        self.assertEqual(1, len(freshness.artifact_references))
        ref = freshness.artifact_references[0]
        self.assertEqual("//pkg:target", ref.label)
        self.assertEqual("file:///tmp/execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.outputs", ref.fetch_value)
        self.assertEqual("pkg/target/test.outputs", ref.output_key)
        self.assertFalse(ref.cached)
        self.assertFalse(ref.remote_only)
        self.assertTrue(ref.is_test_outputs_hint)
        self.assertTrue(ref.fetch_is_stageable_carrier)

    def test_parse_bep_freshness_records_stageable_outputs_zip_reference(self) -> None:
        """Validate local outputs.zip refs stage as their containing test.outputs key."""
        bep = _runfile("tools/tests/python/fixtures/bep_fresh_outputs_zip_file_uri.ndjson")

        freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//pkg:target", "pkg/target/test.outputs")}, freshness.eligible_outputs)
        self.assertEqual(1, len(freshness.artifact_references))
        ref = freshness.artifact_references[0]
        self.assertEqual("pkg/target/test.outputs", ref.output_key)
        self.assertTrue(ref.fetch_value.endswith("/pkg/target/test.outputs/outputs.zip"))
        self.assertFalse(ref.remote_only)
        self.assertTrue(ref.is_test_outputs_hint)
        self.assertTrue(ref.fetch_is_stageable_carrier)

    def test_parse_bep_freshness_records_stageable_uri_only_file_reference(self) -> None:
        """Validate trusted file:// test.outputs URIs do not need duplicate name fields."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "execroot" / "bazel-out" / "k8-fastbuild" / "testlogs" / "pkg" / "uri_only" / "test.outputs"
            payload_dir = source / "payloads" / "tests"
            payload_dir.mkdir(parents=True)
            (payload_dir / "span_events_1.json").write_text("{}", encoding="utf-8")
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:uri_only", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [{"uri": source.as_uri()}],
                        },
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])
            ref = freshness.artifact_references[0]
            staged = self.mod._stage_bep_artifacts(
                freshness,
                workspace=root,
                staging_dir=root / ".topt" / "bep-artifacts",
                remote_artifacts="download",
            )

            self.assertEqual({("//pkg:uri_only", "pkg/uri_only/test.outputs")}, freshness.eligible_outputs)
            self.assertEqual("pkg/uri_only/test.outputs", ref.output_key)
            self.assertTrue(ref.is_test_outputs_hint)
            self.assertTrue(ref.fetch_is_stageable_carrier)
            self.assertEqual(1, len(staged))
            self.assertTrue((staged[0].output_dir / "payloads" / "tests" / "span_events_1.json").is_file())

    def test_parse_bep_freshness_records_stageable_uri_only_outputs_zip_reference(self) -> None:
        """Validate trusted file:// outputs.zip URIs do not need duplicate name fields."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            zip_path = root / "execroot" / "bazel-out" / "k8-fastbuild" / "testlogs" / "pkg" / "zip_uri_only" / "test.outputs" / "outputs.zip"
            zip_path.parent.mkdir(parents=True)
            with zipfile.ZipFile(zip_path, "w") as archive:
                archive.writestr("payloads/tests/span_events_1.json", "{}")
                archive.writestr(
                    "bazel_target_metadata.json",
                    json.dumps({"bazel.target": "//pkg:zip_uri_only"}),
                )
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:zip_uri_only", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [{"uri": zip_path.as_uri()}],
                        },
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])
            ref = freshness.artifact_references[0]
            staged = self.mod._stage_bep_artifacts(
                freshness,
                workspace=root,
                staging_dir=root / ".topt" / "bep-artifacts",
                remote_artifacts="download",
            )

            self.assertEqual({("//pkg:zip_uri_only", "pkg/zip_uri_only/test.outputs")}, freshness.eligible_outputs)
            self.assertEqual("pkg/zip_uri_only/test.outputs", ref.output_key)
            self.assertTrue(ref.is_test_outputs_hint)
            self.assertTrue(ref.fetch_is_stageable_carrier)
            self.assertEqual(1, len(staged))
            self.assertTrue((staged[0].output_dir / "bazel_target_metadata.json").is_file())

    def test_parse_bep_freshness_records_remote_stageable_reference_with_output_key(self) -> None:
        """Validate remote test.outputs refs carry stable output keys for staging clearance."""
        bep = _runfile("tools/tests/python/fixtures/bep_fresh_remote_bytestream.ndjson")

        freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual(set(), freshness.eligible_outputs)
        self.assertEqual(1, len(freshness.remote_only_outputs))
        remote = freshness.remote_only_outputs[0]
        self.assertEqual("//pkg:remote_only", remote.label)
        self.assertEqual("pkg/remote_only/test.outputs", remote.output_key)
        self.assertEqual("bytestream://remote-cas/blobs/deadbeef/123", remote.artifact)
        self.assertEqual(1, len(freshness.artifact_references))
        ref = freshness.artifact_references[0]
        self.assertEqual("pkg/remote_only/test.outputs", ref.output_key)
        self.assertTrue(ref.remote_only)
        self.assertTrue(ref.is_test_outputs_hint)
        self.assertTrue(ref.fetch_is_stageable_carrier)

    def test_parse_bep_freshness_records_path_prefix_reference(self) -> None:
        """Validate pathPrefix-only BEP File objects become stageable local references."""
        bep = _runfile("tools/tests/python/fixtures/bep_fresh_path_prefix.ndjson")

        freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//pkg:path_prefix", "pkg/path_prefix/test.outputs")}, freshness.eligible_outputs)
        self.assertEqual(1, len(freshness.artifact_references))
        ref = freshness.artifact_references[0]
        self.assertEqual("pkg/path_prefix/test.outputs", ref.output_key)
        self.assertEqual("/tmp/execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/path_prefix/test.outputs", ref.fetch_value)
        self.assertFalse(ref.remote_only)
        self.assertTrue(ref.is_test_outputs_hint)
        self.assertTrue(ref.fetch_is_stageable_carrier)

    def test_parse_bep_freshness_preserves_external_carrier_and_canonical_output_key(self) -> None:
        """Validate carrier URI does not override the canonical BEP output key."""
        with tempfile.TemporaryDirectory() as tmp:
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//app:hello_test", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": "file:///tmp/workspace/.topt/simulated-remote-artifacts/app/hello_test/test.outputs",
                                    "pathPrefix": [
                                        "bazel-out",
                                        "k8-fastbuild",
                                        "testlogs",
                                        "app",
                                        "hello_test",
                                    ],
                                },
                            ],
                        },
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//app:hello_test", "app/hello_test/test.outputs")}, freshness.eligible_outputs)
        ref = freshness.artifact_references[0]
        self.assertEqual(
            "file:///tmp/workspace/.topt/simulated-remote-artifacts/app/hello_test/test.outputs",
            ref.fetch_value,
        )
        self.assertEqual("app/hello_test/test.outputs", ref.output_key)

    def test_parse_bep_freshness_does_not_stage_individual_test_outputs_files(self) -> None:
        """Validate BEP files inside test.outputs are freshness refs, not staging carriers."""
        with tempfile.TemporaryDirectory() as tmp:
            bep = Path(tmp) / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//app:hello_test", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs/payloads/tests/span_events_1.json",
                                    "uri": "file:///tmp/execroot/main/bazel-out/k8-fastbuild/testlogs/app/hello_test/test.outputs/payloads/tests/span_events_1.json",
                                },
                                {
                                    "name": "test.outputs",
                                    "uri": "file:///tmp/workspace/.topt/simulated-remote-artifacts/app/hello_test/test.outputs",
                                    "pathPrefix": [
                                        "bazel-out",
                                        "k8-fastbuild",
                                        "testlogs",
                                        "app",
                                        "hello_test",
                                    ],
                                },
                            ],
                        },
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//app:hello_test", "app/hello_test/test.outputs")}, freshness.eligible_outputs)
        self.assertEqual(2, len(freshness.artifact_references))
        stageable = [ref for ref in freshness.artifact_references if ref.fetch_is_stageable_carrier]
        self.assertEqual(1, len(stageable))
        self.assertEqual(
            "file:///tmp/workspace/.topt/simulated-remote-artifacts/app/hello_test/test.outputs",
            stageable[0].fetch_value,
        )

    def test_parse_bep_freshness_rejects_unmappable_carrier_output_keys(self) -> None:
        """Validate opaque or arbitrary carriers do not create stable output keys."""
        cases = [
            {"name": "test.outputs", "uri": "bytestream://remote/test.outputs"},
            {"name": "test.outputs", "uri": "file:///tmp/copied/test.outputs"},
            {"name": "test.outputs", "uri": ".topt/simulated-remote-artifacts/app/hello_test/test.outputs"},
            {"name": "test.outputs"},
        ]
        for output in cases:
            with self.subTest(output=output):
                with tempfile.TemporaryDirectory() as tmp:
                    bep = Path(tmp) / "freshness.bep.json"
                    self._write_bep(
                        bep,
                        [
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
                                    "testActionOutput": [output],
                                },
                            },
                        ],
                    )

                    freshness = self.mod._parse_bep_freshness([bep])

                self.assertEqual("", freshness.artifact_references[0].output_key)
                self.assertEqual(set(), freshness.eligible_outputs)

    def test_parse_bep_freshness_does_not_stage_diagnostic_log_xml_refs(self) -> None:
        """Validate diagnostic-only outputs authorize freshness but are not carriers."""
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
                                    "name": "test.xml",
                                    "uri": "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.xml",
                                },
                            ],
                        },
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//pkg:target", "pkg/target/test.outputs")}, freshness.eligible_outputs)
        self.assertEqual([], freshness.remote_only_outputs)
        self.assertFalse(any(ref.fetch_is_stageable_carrier for ref in freshness.artifact_references))

    def test_parse_bep_freshness_ignores_remote_diagnostic_ref_when_uploadable_output_exists(self) -> None:
        """Validate remote diagnostics do not create required-mode staging failures."""
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
                                    "name": "test.outputs",
                                    "uri": "file:///execroot/main/bazel-out/k8-fastbuild/testlogs/pkg/target/test.outputs",
                                },
                                {
                                    "name": "test.log",
                                    "uri": "bytestream://remote-cas/blobs/diagnostic/456",
                                },
                            ],
                        },
                    },
                ],
            )

            freshness = self.mod._parse_bep_freshness([bep])

        self.assertEqual({("//pkg:target", "pkg/target/test.outputs")}, freshness.eligible_outputs)
        self.assertEqual([], freshness.remote_only_outputs)

    def test_stage_bep_artifacts_copies_local_test_outputs(self) -> None:
        """Validate local test.outputs directories stage into owned per-run roots."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "execroot" / "bazel-out" / "k8-fastbuild" / "testlogs" / "pkg" / "target" / "test.outputs"
            payload_dir = source / "payloads" / "tests"
            payload_dir.mkdir(parents=True)
            (payload_dir / "tests-1.json").write_text("{}", encoding="utf-8")
            freshness = self.mod.BepFreshness(
                eligible_outputs={("//pkg:target", "pkg/target/test.outputs")},
                cached_outputs=set(),
                remote_only_outputs=[],
                missing_output_mappings=set(),
                artifact_references=[
                    self.mod.BepArtifactReference(
                        label="//pkg:target",
                        uri=source.as_uri(),
                        name="test.outputs",
                        path="",
                        candidates=[source.as_uri(), "test.outputs"],
                        fetch_value=source.as_uri(),
                        output_key="pkg/target/test.outputs",
                        cached=False,
                        remote_only=False,
                        is_test_outputs_hint=True,
                        fetch_is_stageable_carrier=True,
                    ),
                ],
            )

            staged = self.mod._stage_bep_artifacts(
                freshness,
                workspace=root,
                staging_dir=root / ".topt" / "bep-artifacts",
                remote_artifacts="download",
            )

            self.assertEqual(1, len(staged))
            staged_output = staged[0].output_dir
            self.assertTrue((staged_output / "payloads" / "tests" / "tests-1.json").is_file())
            self.assertTrue((staged_output / self.mod.STAGING_MARKER).is_file())
            self.assertIn("__runs", staged[0].staging_root.parts)
            self.assertTrue((source / "payloads" / "tests" / "tests-1.json").is_file())

    def test_stage_bep_artifacts_extracts_local_outputs_zip(self) -> None:
        """Validate local outputs.zip artifacts stage as test.outputs contents."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            zip_path = root / "execroot" / "bazel-out" / "k8-fastbuild" / "testlogs" / "pkg" / "target" / "test.outputs" / "outputs.zip"
            zip_path.parent.mkdir(parents=True)
            with zipfile.ZipFile(zip_path, "w") as archive:
                archive.writestr("payloads/tests/tests-1.json", "{}")
                archive.writestr("bazel_target_metadata.json", "{}")
            freshness = self.mod.BepFreshness(
                eligible_outputs={("//pkg:target", "pkg/target/test.outputs")},
                cached_outputs=set(),
                remote_only_outputs=[],
                missing_output_mappings=set(),
                artifact_references=[
                    self.mod.BepArtifactReference(
                        label="//pkg:target",
                        uri=zip_path.as_uri(),
                        name="outputs.zip",
                        path="",
                        candidates=[zip_path.as_uri(), "outputs.zip"],
                        fetch_value=zip_path.as_uri(),
                        output_key="pkg/target/test.outputs",
                        cached=False,
                        remote_only=False,
                        is_test_outputs_hint=True,
                        fetch_is_stageable_carrier=True,
                    ),
                ],
            )

            staged = self.mod._stage_bep_artifacts(
                freshness,
                workspace=root,
                staging_dir=root / ".topt" / "bep-artifacts",
                remote_artifacts="download",
            )

            self.assertEqual(1, len(staged))
            self.assertTrue((staged[0].output_dir / "payloads" / "tests" / "tests-1.json").is_file())
            self.assertTrue((staged[0].output_dir / "bazel_target_metadata.json").is_file())

    def test_stage_bep_artifacts_rejects_unsafe_outputs_zip_member(self) -> None:
        """Validate unsafe zip members fail before publishing staged output dirs."""
        unsafe_members = [
            "../escape.json",
            "/abs/path.json",
            "C:/abs/path.json",
            "foo/../payload.json",
        ]
        for member_name in unsafe_members:
            with self.subTest(member_name=member_name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                zip_path = root / "source" / "outputs.zip"
                zip_path.parent.mkdir(parents=True)
                with zipfile.ZipFile(zip_path, "w") as archive:
                    archive.writestr(member_name, "{}")
                freshness = self.mod.BepFreshness(
                    eligible_outputs={("//pkg:target", "pkg/target/test.outputs")},
                    cached_outputs=set(),
                    remote_only_outputs=[],
                    missing_output_mappings=set(),
                    artifact_references=[
                        self.mod.BepArtifactReference(
                            label="//pkg:target",
                            uri=zip_path.as_uri(),
                            name="outputs.zip",
                            path="",
                            candidates=[zip_path.as_uri(), "outputs.zip"],
                            fetch_value=zip_path.as_uri(),
                            output_key="pkg/target/test.outputs",
                            cached=False,
                            remote_only=False,
                            is_test_outputs_hint=True,
                            fetch_is_stageable_carrier=True,
                        ),
                    ],
                )

                with self.assertRaises(SystemExit):
                    self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="required",
                    )

                runs_root = root / ".topt" / "bep-artifacts" / "__runs"
                self.assertEqual([], list(runs_root.iterdir()) if runs_root.exists() else [])

    def test_stage_bep_artifacts_rejects_dot_and_empty_outputs_zip_parts(self) -> None:
        """Validate zip extraction rejects empty and dot path components."""
        unsafe_members = [
            "payloads/./tests-1.json",
            "payloads//tests-1.json",
            "payloads/tests/.",
        ]
        for member_name in unsafe_members:
            with self.subTest(member_name=member_name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                zip_path = root / "source" / "outputs.zip"
                zip_path.parent.mkdir(parents=True)
                with zipfile.ZipFile(zip_path, "w") as archive:
                    archive.writestr(member_name, "{}")
                freshness = self.mod.BepFreshness(
                    eligible_outputs={("//pkg:target", "pkg/target/test.outputs")},
                    cached_outputs=set(),
                    remote_only_outputs=[],
                    missing_output_mappings=set(),
                    artifact_references=[
                        self.mod.BepArtifactReference(
                            label="//pkg:target",
                            uri=zip_path.as_uri(),
                            name="outputs.zip",
                            path="",
                            candidates=[zip_path.as_uri(), "outputs.zip"],
                            fetch_value=zip_path.as_uri(),
                            output_key="pkg/target/test.outputs",
                            cached=False,
                            remote_only=False,
                            is_test_outputs_hint=True,
                            fetch_is_stageable_carrier=True,
                        ),
                    ],
                )

                with self.assertRaises(SystemExit):
                    self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="required",
                    )

    def test_extract_outputs_zip_wraps_unsupported_member_errors(self) -> None:
        """Validate unsupported zip members use the controlled staging error path."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            zip_path = root / "outputs.zip"
            with zipfile.ZipFile(zip_path, "w") as archive:
                archive.writestr("payloads/tests/span_events_1.json", "{}")

            with mock.patch.object(
                self.mod.zipfile.ZipFile,
                "open",
                side_effect=NotImplementedError("unsupported compression method"),
            ):
                with self.assertRaises(self.mod.BepArtifactStageError) as raised:
                    self.mod._extract_outputs_zip(zip_path, root / "staged")

        self.assertIn("invalid BEP outputs.zip", str(raised.exception))

    def test_extract_outputs_zip_rejects_too_many_entries(self) -> None:
        """Validate outputs.zip entry limits include directory entries."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            zip_path = root / "outputs.zip"
            with zipfile.ZipFile(zip_path, "w") as archive:
                for index in range(self.mod.MAX_OUTPUTS_TREE_FILES + 1):
                    archive.writestr(f"dir-{index}/", "")

            with self.assertRaises(self.mod.BepArtifactStageError) as raised:
                self.mod._extract_outputs_zip(zip_path, root / "staged")

        self.assertIn("too many entries", str(raised.exception))

    def test_extract_outputs_zip_rejects_too_large_archive(self) -> None:
        """Validate outputs.zip decompressed byte limits fail before publish."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            zip_path = root / "outputs.zip"
            with zipfile.ZipFile(zip_path, "w") as archive:
                archive.writestr("payloads/tests/tests-1.json", "1234567890")

            with (
                mock.patch.object(self.mod, "MAX_OUTPUTS_TREE_BYTES", 5),
                self.assertRaises(self.mod.BepArtifactStageError) as raised,
            ):
                self.mod._extract_outputs_zip(zip_path, root / "staged")

        self.assertIn("too large", str(raised.exception))

    @unittest.skipUnless(hasattr(os, "symlink"), "symlink support is required")
    def test_stage_bep_artifacts_rejects_symlink_source_entries(self) -> None:
        """Validate local tree staging refuses symlink files and directories."""
        for entry_kind in ("file", "directory"):
            with self.subTest(entry_kind=entry_kind), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                source = root / "source" / "pkg" / "target" / "test.outputs"
                payload_dir = source / "payloads" / "tests"
                payload_dir.mkdir(parents=True)
                if entry_kind == "file":
                    target = root / "target.json"
                    target.write_text("{}", encoding="utf-8")
                    os.symlink(target, payload_dir / "span_events_1.json")
                else:
                    target_dir = root / "target-dir"
                    target_dir.mkdir()
                    os.symlink(target_dir, source / "linked-dir")
                    (payload_dir / "span_events_1.json").write_text("{}", encoding="utf-8")
                freshness = self.mod.BepFreshness(
                    eligible_outputs={("//pkg:target", "pkg/target/test.outputs")},
                    cached_outputs=set(),
                    remote_only_outputs=[],
                    missing_output_mappings=set(),
                    artifact_references=[
                        self.mod.BepArtifactReference(
                            label="//pkg:target",
                            uri=source.as_uri(),
                            name="test.outputs",
                            path="",
                            candidates=[source.as_uri(), "test.outputs"],
                            fetch_value=source.as_uri(),
                            output_key="pkg/target/test.outputs",
                            cached=False,
                            remote_only=False,
                            is_test_outputs_hint=True,
                            fetch_is_stageable_carrier=True,
                        ),
                    ],
                )

                with self.assertRaises(SystemExit):
                    self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="required",
                    )

    def test_stage_bep_artifacts_dedupes_same_physical_local_source(self) -> None:
        """Validate absolute, relative, and file URI carriers for one source dedupe."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = self._write_doctor_output(root / "external-artifacts", "module", "//pkg:target")
            relative_source = source.relative_to(root)
            freshness = self.mod.BepFreshness(
                eligible_outputs={("//pkg:target", "pkg/target/test.outputs")},
                cached_outputs=set(),
                remote_only_outputs=[],
                missing_output_mappings=set(),
                artifact_references=[
                    self.mod.BepArtifactReference(
                        label="//pkg:target",
                        uri=source.as_uri(),
                        name="test.outputs",
                        path="",
                        candidates=[source.as_uri(), "test.outputs"],
                        fetch_value=source.as_uri(),
                        output_key="pkg/target/test.outputs",
                        cached=False,
                        remote_only=False,
                        is_test_outputs_hint=True,
                        fetch_is_stageable_carrier=True,
                    ),
                    self.mod.BepArtifactReference(
                        label="//pkg:target",
                        uri="",
                        name="test.outputs",
                        path=str(relative_source),
                        candidates=[str(relative_source), "test.outputs"],
                        fetch_value=str(relative_source),
                        output_key="pkg/target/test.outputs",
                        cached=False,
                        remote_only=False,
                        is_test_outputs_hint=True,
                        fetch_is_stageable_carrier=True,
                    ),
                ],
            )

            staged = self.mod._stage_bep_artifacts(
                freshness,
                workspace=root,
                staging_dir=root / ".topt" / "bep-artifacts",
                remote_artifacts="required",
            )

            self.assertEqual(1, len(staged))
            self.assertTrue((staged[0].output_dir / "payloads" / "tests" / "span_events_1.json").is_file())

    def test_stage_bep_artifacts_rejects_ambiguous_carriers_in_required_mode(self) -> None:
        """Validate duplicate BEP carriers for one output key fail closed in strict mode."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_a = self._write_doctor_output(root / "source-a", "module", "//pkg:target")
            source_b = self._write_doctor_output(root / "source-b", "module", "//pkg:target")
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": source_a.as_uri(),
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
                                },
                                {
                                    "name": "test.outputs",
                                    "uri": source_b.as_uri(),
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
                                },
                            ],
                        },
                    },
                ],
            )
            freshness = self.mod._parse_bep_freshness([bep])

            with self.assertRaises(SystemExit):
                self.mod._stage_bep_artifacts(
                    freshness,
                    workspace=root,
                    staging_dir=root / ".topt" / "bep-artifacts",
                    remote_artifacts="required",
                )

    def test_stage_bep_artifacts_downloads_http_outputs_zip_without_downloader(self) -> None:
        """Validate native HTTP outputs.zip staging logs a redacted successful download."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            served_root = root / "http"
            source_zip = served_root / "outputs.zip"
            self._write_outputs_zip(source_zip)
            with _serve_directory(served_root) as base_url:
                url = f"{base_url}/outputs.zip?sig=secret-token#fragment"
                freshness = self._http_outputs_zip_freshness(root, url)
                stderr = io.StringIO()

                with mock.patch("sys.stderr", stderr):
                    staged = self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="required",
                        downloader="",
                        downloader_timeout_sec=5,
                    )

            self.assertEqual(1, len(staged))
            self.assertTrue(staged[0].downloaded)
            self.assertTrue(staged[0].remote_only)
            self.assertEqual("pkg/remote_only/test.outputs", staged[0].output_key)
            self.assertTrue((staged[0].output_dir / "payloads" / "tests" / "span_events_1.json").is_file())
            self.assertTrue((staged[0].output_dir / "bazel_target_metadata.json").is_file())
            self.assertIn("BEP HTTP artifact downloaded", stderr.getvalue())
            self.assertIn("/outputs.zip", stderr.getvalue())
            self.assertNotIn("secret-token", stderr.getvalue())
            self.assertNotIn("fragment", stderr.getvalue())

    def test_stage_bep_artifacts_http_failure_skips_in_download_mode(self) -> None:
        """Validate failed native HTTP staging skips in download mode without traceback."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            served_root = root / "http"
            served_root.mkdir()
            with _serve_directory(served_root) as base_url:
                freshness = self._http_outputs_zip_freshness(root, f"{base_url}/missing.zip")
                stderr = io.StringIO()
                with mock.patch("sys.stderr", stderr):
                    staged = self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="download",
                        downloader="",
                        downloader_timeout_sec=5,
                    )

            self.assertEqual([], staged)
            self.assertIn("BEP HTTP artifact download failed", stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())

    def test_stage_bep_artifacts_http_failure_fails_required_mode(self) -> None:
        """Validate failed native HTTP staging fails closed in required mode."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            served_root = root / "http"
            served_root.mkdir()
            with _serve_directory(served_root) as base_url:
                freshness = self._http_outputs_zip_freshness(root, f"{base_url}/missing.zip")
                stderr = io.StringIO()
                with self.assertRaises(SystemExit), mock.patch("sys.stderr", stderr):
                    self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="required",
                        downloader="",
                        downloader_timeout_sec=5,
                    )

            self.assertIn("could not be materialized", stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())

    def test_stage_bep_artifacts_http_retry_succeeds_after_transient_failure(self) -> None:
        """Validate native HTTP staging retries 5xx responses with exponential backoff."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_zip = root / "source" / "outputs.zip"
            self._write_outputs_zip(source_zip)
            zip_bytes = source_zip.read_bytes()

            class FlakyHandler(QuietBaseHTTPRequestHandler):
                attempts = 0

                def do_GET(self) -> None:
                    type(self).attempts += 1
                    if type(self).attempts < 3:
                        self.send_response(500)
                        self.end_headers()
                        return
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(zip_bytes)))
                    self.end_headers()
                    self.wfile.write(zip_bytes)

            with _serve_handler(FlakyHandler) as base_url:
                freshness = self._http_outputs_zip_freshness(root, f"{base_url}/outputs.zip")
                sleeps: list[float] = []
                with mock.patch.object(self.mod.time, "sleep", side_effect=sleeps.append):
                    staged = self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="required",
                        downloader="",
                        downloader_timeout_sec=5,
                    )

            self.assertEqual(1, len(staged))
            self.assertEqual(3, FlakyHandler.attempts)
            self.assertEqual([0.25, 0.5], sleeps)

    def test_stage_bep_artifacts_http_retry_exhaustion_warns_once(self) -> None:
        """Validate native HTTP staging warns once when retries are exhausted."""
        class AlwaysFailHandler(QuietBaseHTTPRequestHandler):
            attempts = 0

            def do_GET(self) -> None:
                type(self).attempts += 1
                self.send_response(500)
                self.end_headers()

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with _serve_handler(AlwaysFailHandler) as base_url:
                freshness = self._http_outputs_zip_freshness(root, f"{base_url}/outputs.zip")
                stderr = io.StringIO()
                with (
                    mock.patch.object(self.mod.time, "sleep"),
                    mock.patch("sys.stderr", stderr),
                ):
                    staged = self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="download",
                        downloader="",
                        downloader_timeout_sec=5,
                    )

            self.assertEqual([], staged)
            self.assertEqual(3, AlwaysFailHandler.attempts)
            self.assertEqual(1, stderr.getvalue().count("BEP HTTP artifact download failed"))
            self.assertNotIn("Traceback", stderr.getvalue())

    def test_stage_bep_artifacts_http_retry_succeeds_after_truncated_response(self) -> None:
        """Validate native HTTP staging retries truncated responses before zip extraction."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_zip = root / "source" / "outputs.zip"
            self._write_outputs_zip(source_zip)
            zip_bytes = source_zip.read_bytes()

            class TruncatedHandler(QuietBaseHTTPRequestHandler):
                attempts = 0

                def do_GET(self) -> None:
                    type(self).attempts += 1
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(zip_bytes)))
                    self.end_headers()
                    if type(self).attempts == 1:
                        self.wfile.write(zip_bytes[: max(1, len(zip_bytes) // 3)])
                        self.wfile.flush()
                        self.connection.close()
                        return
                    self.wfile.write(zip_bytes)

            with _serve_handler(TruncatedHandler) as base_url:
                freshness = self._http_outputs_zip_freshness(root, f"{base_url}/outputs.zip")
                sleeps: list[float] = []
                stderr = io.StringIO()
                with (
                    mock.patch.object(self.mod.time, "sleep", side_effect=sleeps.append),
                    mock.patch("sys.stderr", stderr),
                ):
                    staged = self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="required",
                        downloader="",
                        downloader_timeout_sec=5,
                    )

            self.assertEqual(1, len(staged))
            self.assertEqual(2, TruncatedHandler.attempts)
            self.assertEqual([0.25], sleeps)
            self.assertNotIn("invalid BEP outputs.zip", stderr.getvalue())

    def test_stage_bep_artifacts_explicit_downloader_overrides_http_builtin(self) -> None:
        """Validate explicit downloader wins even for HTTP BEP artifact references."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            served_root = root / "http"
            self._write_outputs_zip(served_root / "outputs.zip", payload_name="from_http.json")
            downloader_zip = root / "downloader" / "outputs.zip"
            self._write_outputs_zip(downloader_zip, payload_name="from_downloader.json")
            downloader = self._write_python_downloader(
                root / "downloader-script",
                """
import os
import shutil
import sys

out = ""
args = iter(sys.argv[1:])
for arg in args:
    if arg == "--output":
        out = next(args)
shutil.copyfile(os.environ["DOWNLOADER_ZIP"], out)
""",
            )
            with _serve_directory(served_root) as base_url:
                freshness = self._http_outputs_zip_freshness(root, f"{base_url}/outputs.zip")
                with mock.patch.dict(os.environ, {"DOWNLOADER_ZIP": str(downloader_zip)}):
                    staged = self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="required",
                        downloader=str(downloader),
                        downloader_timeout_sec=5,
                    )

            self.assertEqual(1, len(staged))
            self.assertTrue((staged[0].output_dir / "payloads" / "tests" / "from_downloader.json").is_file())
            self.assertFalse((staged[0].output_dir / "payloads" / "tests" / "from_http.json").exists())

    def test_stage_bep_artifacts_http_logs_redact_query_and_fragment(self) -> None:
        """Validate native HTTP staging diagnostics redact signed URL components."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            served_root = root / "http"
            served_root.mkdir()
            with _serve_directory(served_root) as base_url:
                url = f"{base_url}/missing.zip?sig=secret-token#fragment"
                freshness = self._http_outputs_zip_freshness(root, url)
                stderr = io.StringIO()
                with mock.patch("sys.stderr", stderr):
                    staged = self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="download",
                        downloader="",
                        downloader_timeout_sec=5,
                    )

            self.assertEqual([], staged)
            self.assertNotIn("secret-token", stderr.getvalue())
            self.assertNotIn("fragment", stderr.getvalue())
            self.assertIn("/missing.zip", stderr.getvalue())

    def test_stage_bep_artifacts_http_content_length_limit_is_enforced(self) -> None:
        """Validate native HTTP staging enforces the compressed artifact byte limit."""
        class OversizedHandler(QuietBaseHTTPRequestHandler):
            def do_GET(self) -> None:
                self.send_response(200)
                self.send_header("Content-Length", "9")
                self.end_headers()

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with _serve_handler(OversizedHandler) as base_url:
                freshness = self._http_outputs_zip_freshness(root, f"{base_url}/outputs.zip")
                stderr = io.StringIO()
                with (
                    mock.patch.object(self.mod, "MAX_OUTPUTS_TREE_BYTES", 8),
                    mock.patch("sys.stderr", stderr),
                    self.assertRaises(SystemExit),
                ):
                    self.mod._stage_bep_artifacts(
                        freshness,
                        workspace=root,
                        staging_dir=root / ".topt" / "bep-artifacts",
                        remote_artifacts="required",
                        downloader="",
                        downloader_timeout_sec=5,
                    )

            self.assertIn("too large", stderr.getvalue())
            self.assertEqual([], list((root / ".topt" / "bep-artifacts").rglob("outputs.zip")))

    def test_stage_bep_artifacts_downloads_remote_outputs_zip(self) -> None:
        """Validate remote-only BEP artifacts can be materialized by an external downloader."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_zip = root / "source" / "outputs.zip"
            source_zip.parent.mkdir(parents=True)
            with zipfile.ZipFile(source_zip, "w") as archive:
                archive.writestr("payloads/tests/span_events_1.json", "{}")
                archive.writestr(
                    "bazel_target_metadata.json",
                    json.dumps({
                        "bazel.target": "//pkg:remote_only",
                        "bazel.go.payload_selection": "module",
                    }),
                )
            downloader = self._write_python_downloader(
                root / "downloader with space",
                """
import os
import shutil
import sys

out = ""
args = iter(sys.argv[1:])
for arg in args:
    if arg == "--output":
        out = next(args)
shutil.copyfile(os.environ["SOURCE_ZIP"], out)
""",
            )
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:remote_only", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                                    "pathPrefix": [
                                        "bazel-out",
                                        "k8-fastbuild",
                                        "testlogs",
                                        "pkg",
                                        "remote_only",
                                    ],
                                },
                            ],
                        },
                    },
                ],
            )
            freshness = self.mod._parse_bep_freshness([bep])

            with mock.patch.dict(os.environ, {"SOURCE_ZIP": str(source_zip)}):
                staged = self.mod._stage_bep_artifacts(
                    freshness,
                    workspace=root,
                    staging_dir=root / ".topt" / "bep-artifacts",
                    remote_artifacts="required",
                    downloader=str(downloader),
                    downloader_timeout_sec=5,
                )
            self.mod._apply_staged_bep_artifacts_to_freshness(freshness, staged)

            self.assertEqual(1, len(staged))
            self.assertTrue(staged[0].downloaded)
            self.assertEqual("pkg/remote_only/test.outputs", staged[0].output_key)
            self.assertEqual([], freshness.remote_only_outputs)
            self.assertTrue((staged[0].output_dir / "payloads" / "tests" / "span_events_1.json").is_file())

    def test_stage_bep_artifacts_downloader_failure_does_not_reuse_stale_zip(self) -> None:
        """Validate downloader failures cannot authorize stale outputs.zip files."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            downloader = self._write_python_downloader(root / "downloader", "import sys\nsys.exit(42)\n")
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:remote_only", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "remote_only"],
                                },
                            ],
                        },
                    },
                ],
            )
            freshness = self.mod._parse_bep_freshness([bep])
            staging_dir = root / ".topt" / "bep-artifacts"
            stale_dst = (
                staging_dir
                / "__runs"
                / "preexisting"
                / "__downloads"
                / "_pkg_remote_only"
                / "pkg_remote_only_test.outputs"
                / "outputs.zip"
            )
            stale_dst.parent.mkdir(parents=True)
            stale_dst.write_text("not a real zip", encoding="utf-8")

            staged = self.mod._stage_bep_artifacts(
                freshness,
                workspace=root,
                staging_dir=staging_dir,
                remote_artifacts="download",
                downloader=str(downloader),
                downloader_timeout_sec=5,
            )

            self.assertEqual([], staged)

    def test_stage_bep_artifacts_downloader_failure_hides_output(self) -> None:
        """Validate downloader stdout/stderr is not copied into materialization warnings."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            downloader = self._write_python_downloader(
                root / "downloader",
                """
import sys

print("secret-token-on-stdout")
print("secret-token-on-stderr", file=sys.stderr)
sys.exit(7)
""",
            )
            freshness = self._remote_outputs_zip_freshness(root)
            stderr = io.StringIO()

            with mock.patch("sys.stderr", stderr):
                staged = self.mod._stage_bep_artifacts(
                    freshness,
                    workspace=root,
                    staging_dir=root / ".topt" / "bep-artifacts",
                    remote_artifacts="download",
                    downloader=str(downloader),
                    downloader_timeout_sec=5,
                )

            self.assertEqual([], staged)
            self.assertIn("exit code 7", stderr.getvalue())
            self.assertNotIn("secret-token", stderr.getvalue())

    def test_stage_bep_artifacts_missing_or_non_executable_downloader_fails_controlled(self) -> None:
        """Validate downloader startup failures use controlled errors without tracebacks."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            non_executable = root / "downloader"
            non_executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            for downloader in [root / "missing-downloader", non_executable]:
                with self.subTest(downloader=downloader):
                    freshness = self._remote_outputs_zip_freshness(root)
                    stderr = io.StringIO()

                    with self.assertRaises(SystemExit), mock.patch("sys.stderr", stderr):
                        self.mod._stage_bep_artifacts(
                            freshness,
                            workspace=root,
                            staging_dir=root / ".topt" / "bep-artifacts",
                            remote_artifacts="required",
                            downloader=str(downloader),
                            downloader_timeout_sec=5,
                        )

                    self.assertIn("BEP artifact downloader could not start", stderr.getvalue())
                    self.assertIn("could not be materialized", stderr.getvalue())
                    self.assertNotIn("Traceback", stderr.getvalue())

    def test_stage_bep_artifacts_downloader_timeout_hides_output(self) -> None:
        """Validate downloader timeout terminates quickly and does not leak output."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            downloader = self._write_python_downloader(
                root / "downloader",
                """
import sys
import time

print("timeout-secret", file=sys.stderr)
time.sleep(5)
""",
            )
            freshness = self._remote_outputs_zip_freshness(root)
            stderr = io.StringIO()

            with self.assertRaises(SystemExit), mock.patch("sys.stderr", stderr):
                self.mod._stage_bep_artifacts(
                    freshness,
                    workspace=root,
                    staging_dir=root / ".topt" / "bep-artifacts",
                    remote_artifacts="required",
                    downloader=str(downloader),
                    downloader_timeout_sec=0.05,
                )

            self.assertIn("BEP artifact downloader timed out", stderr.getvalue())
            self.assertIn("could not be materialized", stderr.getvalue())
            self.assertNotIn("timeout-secret", stderr.getvalue())

    def test_stage_bep_artifacts_rejects_invalid_downloaded_zip(self) -> None:
        """Validate invalid downloader-produced outputs.zip does not authorize payloads."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            downloader = self._write_python_downloader(
                root / "downloader",
                """
from pathlib import Path
import sys

out = ""
args = iter(sys.argv[1:])
for arg in args:
    if arg == "--output":
        out = next(args)
Path(out).write_text("not-a-zip", encoding="utf-8")
""",
            )
            freshness = self._remote_outputs_zip_freshness(root)
            stderr = io.StringIO()

            with mock.patch("sys.stderr", stderr):
                staged = self.mod._stage_bep_artifacts(
                    freshness,
                    workspace=root,
                    staging_dir=root / ".topt" / "bep-artifacts",
                    remote_artifacts="download",
                    downloader=str(downloader),
                    downloader_timeout_sec=5,
                )

            self.assertEqual([], staged)
            self.assertIn("invalid BEP outputs.zip", stderr.getvalue())

    def test_stage_bep_artifacts_rejects_downloaded_outputs_zip_directory(self) -> None:
        """Validate a downloader cannot satisfy the contract with an outputs.zip directory."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            downloader = self._write_python_downloader(
                root / "downloader",
                """
from pathlib import Path
import sys

out = ""
args = iter(sys.argv[1:])
for arg in args:
    if arg == "--output":
        out = next(args)
Path(out).mkdir(parents=True)
""",
            )
            freshness = self._remote_outputs_zip_freshness(root)
            stderr = io.StringIO()

            with self.assertRaises(SystemExit), mock.patch("sys.stderr", stderr):
                self.mod._stage_bep_artifacts(
                    freshness,
                    workspace=root,
                    staging_dir=root / ".topt" / "bep-artifacts",
                    remote_artifacts="required",
                    downloader=str(downloader),
                    downloader_timeout_sec=5,
                )

            self.assertIn("did not produce a file", stderr.getvalue())

    def test_bep_artifact_stage_helper_validates_tsv_before_stdout_and_cleans_up(self) -> None:
        """Validate helper rejects unsafe TSV fields without publishing partial stdout."""
        helper = _runfile("tools/core/bep_artifact_stage_helper.py")
        doctor_runtime = _runfile("tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_output = self._write_doctor_output(root / "external-artifacts", "module", "//pkg:target")
            staging_base = root / ".topt" / "bep-artifacts"
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:bad\tlabel", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": source_output.as_uri(),
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
                                },
                            ],
                        },
                    },
                ],
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "--doctor-runtime",
                    str(doctor_runtime),
                    "--staging-dir",
                    str(staging_base),
                    "--remote-artifacts=download",
                    "--artifact-source=bep",
                    str(bep),
                ],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            runs_root = staging_base / "__runs"
            remaining_roots = list(runs_root.iterdir()) if runs_root.exists() else []

        self.assertNotEqual(0, result.returncode)
        self.assertEqual("", result.stdout)
        self.assertIn("cannot emit BEP artifact staging TSV field", result.stderr)
        self.assertEqual([], remaining_roots)

    def test_bep_artifact_stage_helper_emits_stable_tsv_protocol(self) -> None:
        """Validate helper stages local BEP artifacts and emits parseable TSV rows."""
        helper = _runfile("tools/core/bep_artifact_stage_helper.py")
        doctor_runtime = _runfile("tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_output = self._write_doctor_output(root / "external-artifacts", "module", "//pkg:target")
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": source_output.as_uri(),
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "target"],
                                },
                            ],
                        },
                    },
                ],
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "--doctor-runtime",
                    str(doctor_runtime),
                    "--staging-dir",
                    str(root / ".topt" / "bep-artifacts"),
                    "--remote-artifacts=download",
                    "--artifact-source=bep",
                    str(bep),
                ],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(0, result.returncode, result.stderr)
        stdout_lines = result.stdout.splitlines()
        self.assertIn("selected\t//pkg:target\tpkg/target/test.outputs", stdout_lines)
        self.assertTrue(any(line.startswith("root\t") for line in stdout_lines))
        self.assertTrue(any(line.startswith("staged\t//pkg:target\tpkg/target/test.outputs\t") for line in stdout_lines))
        self.assertEqual("", result.stderr)

    def test_bep_artifact_stage_helper_selects_remote_without_downloader_in_download_mode(self) -> None:
        """Validate helper suppresses stale local fallback even when remote staging skips."""
        helper = _runfile("tools/core/bep_artifact_stage_helper.py")
        doctor_runtime = _runfile("tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:remote_only", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": "bytestream://remote-cas/blobs/deadbeef/123",
                                    "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "remote_only"],
                                },
                            ],
                        },
                    },
                ],
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "--doctor-runtime",
                    str(doctor_runtime),
                    "--staging-dir",
                    str(root / ".topt" / "bep-artifacts"),
                    "--remote-artifacts=download",
                    "--artifact-source=bep",
                    str(bep),
                ],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("selected\t//pkg:remote_only\tpkg/remote_only/test.outputs", result.stdout)
        self.assertNotIn("staged\t//pkg:remote_only\tpkg/remote_only/test.outputs", result.stdout)
        self.assertIn("remote-only and no downloader is configured", result.stderr)

    def test_bep_artifact_stage_helper_blocks_no_key_local_fallback_in_download_mode(self) -> None:
        """Validate helper marks no-key BEP artifact labels as stale-local blockers."""
        helper = _runfile("tools/core/bep_artifact_stage_helper.py")
        doctor_runtime = _runfile("tools/core/test_optimization_doctor.py")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bep = root / "freshness.bep.json"
            self._write_bep(
                bep,
                [
                    {
                        "id": {"testResult": {"label": "//pkg:target", "run": 1, "shard": 1, "attempt": 1}},
                        "testResult": {
                            "status": "PASSED",
                            "testActionOutput": [
                                {
                                    "name": "test.outputs",
                                    "uri": "file:///tmp/copied/test.outputs",
                                },
                            ],
                        },
                    },
                ],
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "--doctor-runtime",
                    str(doctor_runtime),
                    "--staging-dir",
                    str(root / ".topt" / "bep-artifacts"),
                    "--remote-artifacts=download",
                    "--artifact-source=bep",
                    str(bep),
                ],
                cwd=root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("blocked_label\t//pkg:target", result.stdout.splitlines())
        self.assertNotIn("selected\t//pkg:target", result.stdout)
        self.assertNotIn("staged\t//pkg:target", result.stdout)
        self.assertIn("no mappable test.outputs key", result.stderr)

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
            self.assertIn("--remote_download_minimal", stderr.getvalue())
            self.assertIn("--remote_download_regex=.*test[.]outputs.*", stderr.getvalue())
            self.assertIn("--artifact-source=bep", stderr.getvalue())

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

    def test_launchers_expose_support_bundle_collector_runfiles(self) -> None:
        """Validate doctor launchers make the bundled collector available to the runtime."""
        doctor_rule = _runfile("tools/core/test_optimization_doctor.bzl").read_text(encoding="utf-8")

        self.assertIn("_support_bundle_collector", doctor_rule)
        self.assertIn("_support_bundle_renderer", doctor_rule)
        self.assertIn("create_support_bundle.py", doctor_rule)
        self.assertIn("render_report_summary.py", doctor_rule)
        self.assertIn("DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_COLLECTOR", doctor_rule)
        self.assertIn("DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE_RENDERER", doctor_rule)


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
    def _extract_text_block(text: str, start: str, end: str) -> str:
        """Extract a contiguous text block by marker strings."""
        start_index = text.index(start)
        end_index = text.index(end, start_index)
        return text[start_index:end_index]

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

    @staticmethod
    def _write_bep_staging_smoke_fixture(root: Path) -> Path:
        """Create a BEP + outputs.zip fixture for generated uploader smoke tests."""
        source_zip = root / "remote" / "outputs.zip"
        source_zip.parent.mkdir()
        test_payload = {
            "events": [
                {
                    "type": "test",
                    "content": {
                        "resource": "pkg.generated",
                        "meta": {},
                        "metrics": {},
                    },
                },
            ],
        }
        with zipfile.ZipFile(source_zip, "w") as archive:
            archive.writestr(
                "payloads/tests/span_events_generated_remote.json",
                json.dumps(test_payload) + "\n",
            )
            archive.writestr(
                "bazel_target_metadata.json",
                json.dumps({
                    "bazel.target": "//pkg:generated",
                    "bazel.go.payload_selection": "module",
                }),
            )

        bep = root / "freshness.bep.json"
        TestOptimizationDoctorTests._write_bep(
            bep,
            [
                {
                    "id": {"testResult": {"label": "//pkg:generated", "run": 1, "shard": 1, "attempt": 1}},
                    "testResult": {
                        "status": "PASSED",
                        "testActionOutput": [
                            {
                                "name": "outputs.zip",
                                "uri": source_zip.as_uri(),
                                "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "generated"],
                            },
                        ],
                    },
                },
            ],
        )
        return bep

    @staticmethod
    def _write_signed_http_remote_only_bep(root: Path) -> Path:
        """Create a BEP fixture whose remote-only artifact URL contains secrets."""
        bep = root / "signed-http-remote-only.bep.json"
        TestOptimizationDoctorTests._write_bep(
            bep,
            [
                {
                    "id": {"testResult": {"label": "//pkg:remote_only", "run": 1, "shard": 1, "attempt": 1}},
                    "testResult": {
                        "status": "PASSED",
                        "testActionOutput": [
                            {
                                "name": "test.outputs",
                                "uri": "https://user:supersecret@example.test/outputs.zip?sig=secret-token#fragment",
                                "pathPrefix": ["bazel-out", "k8-fastbuild", "testlogs", "pkg", "remote_only"],
                            },
                        ],
                    },
                },
            ],
        )
        return bep

    @staticmethod
    def _write_non_sibling_runtime_runfiles(root: Path) -> Path:
        """Create runfiles with helper and doctor runtime at independent rlocs."""
        runfiles_dir = root / "runtime.runfiles"
        for rloc, source_rloc in [
            (_BEP_ARTIFACT_STAGE_HELPER_RLOC, _BEP_ARTIFACT_STAGE_HELPER_RLOC),
            (_NON_SIBLING_DOCTOR_RUNTIME_RLOC, _DOCTOR_RUNTIME_RLOC),
        ]:
            dest = runfiles_dir / rloc
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(_runfile(source_rloc).read_bytes())
        return runfiles_dir

    @staticmethod
    def _generated_uploader_smoke_env(root: Path, runfiles_dir: Path) -> dict[str, str]:
        """Build a clean environment for generated uploader smoke tests."""
        env = os.environ.copy()
        env.update({
            "BUILD_WORKSPACE_DIRECTORY": str(root),
            "DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE": "bep",
            "DD_TEST_OPTIMIZATION_DEBUG": "1",
            "DD_TEST_OPTIMIZATION_MAX_WAIT_SEC": "0",
            "DD_TEST_OPTIMIZATION_QUIESCENT_SEC": "0",
            "DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS": "download",
            "PYTHON": sys.executable,
            "RUNFILES_DIR": str(runfiles_dir),
            "TESTLOGS_DIR": str(root / "bazel-testlogs"),
        })
        env.pop("RUNFILES_MANIFEST_FILE", None)
        return env

    def _assert_uploader_report_success(self, report_path: Path, bep_path: Path, staging_dir: Path) -> None:
        """Validate a successful generated uploader machine-readable report."""
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(1, report["schema_version"])
        self.assertEqual("dd-test-optimization-uploader", report["tool"])
        self.assertEqual("ok", report["status"])
        self.assertEqual(0, report["exit_code"])
        self.assertEqual("ok", report["result"]["status"])
        self.assertEqual("upload_skipped_dry_run", report["result"]["reason_code"])
        self.assertFalse(report["upload"]["attempted"])
        self.assertTrue(report["upload"]["dry_run"])
        self.assertTrue(report["config"]["dry_run"])
        self.assertEqual("bep", report["config"]["artifact_source"])
        self.assertEqual("download", report["config"]["remote_artifacts"])
        self.assertEqual("bep", report["config"]["freshness_source"])
        self.assertEqual("required", report["config"]["freshness_mode"])
        self.assertEqual([str(bep_path)], report["bep"]["files"])
        self.assertEqual("bep", report["bep"]["freshness_selected_source"])
        self.assertEqual(1, report["bep"]["eligible_outputs"])
        self.assertEqual(str(staging_dir), report["artifacts"]["staging_dir"])
        self.assertEqual(1, report["artifacts"]["selected_remote_artifacts"])
        self.assertEqual(1, report["artifacts"]["staged_remote_artifacts"])
        self.assertEqual(1, report["artifacts"]["staged_testlogs_dirs"])
        self.assertEqual(1, report["payloads"]["test_outputs_dirs"])
        self.assertEqual(1, report["payloads"]["discovered"]["tests"])
        self.assertEqual(1, report["payloads"]["tests"]["processed"])
        self.assertEqual(0, report["payloads"]["tests"]["failed"])
        self.assertEqual(0, report["payloads"]["tests"]["skipped"])
        self.assertEqual(0, report["payloads"]["coverage"]["processed"])
        self.assertEqual(0, report["payloads"]["telemetry"]["processed"])
        self.assertEqual(0, report["upload_failures"])

    def _assert_uploader_report_failure(self, report_path: Path, bep_path: Path) -> None:
        """Validate a failed generated uploader machine-readable report."""
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(1, report["schema_version"])
        self.assertEqual("dd-test-optimization-uploader", report["tool"])
        self.assertEqual("fail", report["status"])
        self.assertEqual(1, report["exit_code"])
        self.assertEqual("fail", report["result"]["status"])
        self.assertEqual("payload_enrichment_failed", report["result"]["reason_code"])
        self.assertFalse(report["upload"]["attempted"])
        self.assertTrue(report["upload"]["dry_run"])
        self.assertTrue(report["config"]["dry_run"])
        self.assertTrue(report["config"]["validate_enrichment"])
        self.assertEqual([str(bep_path)], report["bep"]["files"])
        self.assertEqual(1, report["payloads"]["test_outputs_dirs"])
        self.assertEqual(0, report["payloads"]["tests"]["processed"])
        self.assertGreaterEqual(report["payloads"]["tests"]["failed"], 1)
        self.assertEqual(1, report["upload_failures"])

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
        self.assertIn("FreshnessRemoteOnlyOutputs.ToArray()", powershell_text)
        self.assertNotIn("@($script:FreshnessRemoteOnlyOutputs)", powershell_text)
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
        self.assertIn(
            "prepare_freshness_eligibility\nmerge_staged_bep_freshness\nvalidate_bep_remote_only_outputs",
            bash_text,
        )
        self.assertIn(
            "Initialize-FreshnessEligibility\n    Merge-StagedBepFreshness\n    Assert-NoRequiredRemoteOnlyBepOutputs",
            powershell_text,
        )

    def test_uploader_remote_only_logs_redact_http_artifact_references(self) -> None:
        """Validate uploader remote-only warnings render redacted HTTP artifact references."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        self.assertIn("display_artifact_reference()", bash_text)
        self.assertIn('display_artifact_reference "$first_artifact"', bash_text)
        self.assertNotIn(": ${first_artifact:-<unknown>}; skipping", bash_text)
        self.assertNotIn(": ${first_artifact:-<unknown>}. Rerun", bash_text)
        self.assertNotIn(": ${first_artifact:-<unknown>}; remote artifact", bash_text)

        self.assertIn("function Format-ArtifactReferenceForLog", powershell_text)
        self.assertIn("Format-ArtifactReferenceForLog $first.Artifact", powershell_text)
        self.assertNotIn(": $($first.Artifact); skipping", powershell_text)
        self.assertNotIn(": $($first.Artifact). Rerun", powershell_text)
        self.assertNotIn(": $($first.Artifact); remote artifact", powershell_text)

    def test_generated_bash_uploader_redacts_http_remote_only_warning(self) -> None:
        """Validate generated Bash uploader logs/report redact signed HTTP artifacts."""
        _require_command(self, "jq", "jq is required for Bash BEP freshness parsing")
        bash = _require_functional_bash(self)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bazel-testlogs").mkdir()
            bep = self._write_signed_http_remote_only_bep(root)
            generated_bash = root / "generated_uploader.sh"
            generated_bash.write_text(
                _render_uploader_runtime_template("tools/core/uploader_bash_runtime.sh.tpl"),
                encoding="utf-8",
            )
            generated_bash.chmod(0o755)
            report = root / "uploader-report.json"
            env = os.environ.copy()
            env.update({
                "BUILD_WORKSPACE_DIRECTORY": str(root),
                "DD_TEST_OPTIMIZATION_MAX_WAIT_SEC": "0",
                "DD_TEST_OPTIMIZATION_QUIESCENT_SEC": "0",
                "RUNFILES_DIR": str(root / "empty.runfiles"),
                "TESTLOGS_DIR": str(root / "bazel-testlogs"),
            })
            (root / "empty.runfiles").mkdir()

            result = subprocess.run(
                [
                    bash,
                    str(generated_bash),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=optional",
                    "--remote-artifacts=disabled",
                    "--report-json",
                    str(report),
                    "--dry-run",
                ],
                cwd=root,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )

            output = result.stdout + result.stderr
            self.assertTrue(report.is_file(), output)
            report_text = report.read_text(encoding="utf-8")
            report_doc = json.loads(report_text)

        self.assertEqual(0, result.returncode, output)
        self.assertIn("https://example.test/outputs.zip", output)
        for sensitive in ("secret-token", "fragment", "user:supersecret", "sig=secret-token"):
            self.assertNotIn(sensitive, output)
            self.assertNotIn(sensitive, report_text)
        self.assertEqual(1, report_doc["bep"]["remote_only_outputs"])
        self.assertNotIn("artifact", report_doc["bep"])

    def test_generated_powershell_uploader_redacts_http_remote_only_warning(self) -> None:
        """Validate generated PowerShell uploader logs/report redact signed HTTP artifacts."""
        if os.name == "nt":
            self.skipTest("generated PowerShell uploader execution smoke is covered on non-Windows")
        pwsh = _require_command(self, "pwsh", "pwsh is required for generated PowerShell uploader execution")

        root = Path(tempfile.mkdtemp())
        try:
            (root / "bazel-testlogs").mkdir()
            bep = self._write_signed_http_remote_only_bep(root)
            generated_ps = root / "generated_uploader.ps1"
            generated_ps.write_text(
                _render_uploader_runtime_template("tools/core/uploader_powershell_runtime.ps1.tpl"),
                encoding="utf-8",
            )
            report = root / "uploader-report.json"
            env = os.environ.copy()
            env.update({
                "BUILD_WORKSPACE_DIRECTORY": str(root),
                "DD_TEST_OPTIMIZATION_MAX_WAIT_SEC": "0",
                "DD_TEST_OPTIMIZATION_QUIESCENT_SEC": "0",
                "RUNFILES_DIR": str(root / "empty.runfiles"),
                "TESTLOGS_DIR": str(root / "bazel-testlogs"),
            })
            (root / "empty.runfiles").mkdir()

            result = subprocess.run(
                [
                    pwsh,
                    "-NoLogo",
                    "-NoProfile",
                    "-File",
                    str(generated_ps),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=optional",
                    "--remote-artifacts=disabled",
                    "--report-json",
                    str(report),
                    "--dry-run",
                ],
                cwd=root,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )

            output = result.stdout + result.stderr
            self.assertTrue(report.is_file(), output)
            report_text = report.read_text(encoding="utf-8")
            report_doc = json.loads(report_text)
        finally:
            _cleanup_tempdir_with_windows_retry(root)

        self.assertEqual(0, result.returncode, output)
        self.assertIn("https://example.test/outputs.zip", output)
        for sensitive in ("secret-token", "fragment", "user:supersecret", "sig=secret-token"):
            self.assertNotIn(sensitive, output)
            self.assertNotIn(sensitive, report_text)
        self.assertEqual(1, report_doc["bep"]["remote_only_outputs"])
        self.assertNotIn("artifact", report_doc["bep"])

    def test_generated_uploaders_require_configured_remote_artifacts(self) -> None:
        """Validate required remote artifact mode fails when BEP outputs are not materialized."""
        _require_command(self, "jq", "jq is required for Bash BEP freshness parsing")
        bash = _require_functional_bash(self)
        if os.name == "nt":
            self.skipTest("generated PowerShell uploader execution smoke is covered on non-Windows")
        pwsh = _require_command(self, "pwsh", "pwsh is required for generated PowerShell uploader execution")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bazel-testlogs").mkdir()
            bep = self._write_signed_http_remote_only_bep(root)
            runfiles_dir = root / "empty.runfiles"
            runfiles_dir.mkdir()
            env = os.environ.copy()
            env.update({
                "BUILD_WORKSPACE_DIRECTORY": str(root),
                "DD_TEST_OPTIMIZATION_MAX_WAIT_SEC": "0",
                "DD_TEST_OPTIMIZATION_QUIESCENT_SEC": "0",
                "RUNFILES_DIR": str(runfiles_dir),
                "TESTLOGS_DIR": str(root / "bazel-testlogs"),
            })

            generated_bash = root / "generated_uploader.sh"
            generated_bash.write_text(
                _render_uploader_runtime_template("tools/core/uploader_bash_runtime.sh.tpl"),
                encoding="utf-8",
            )
            generated_bash.chmod(0o755)
            bash_result = subprocess.run(
                [
                    bash,
                    str(generated_bash),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=optional",
                    "--remote-artifacts=required",
                    "--dry-run",
                ],
                cwd=root,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )

            generated_ps = root / "generated_uploader.ps1"
            generated_ps.write_text(
                _render_uploader_runtime_template("tools/core/uploader_powershell_runtime.ps1.tpl"),
                encoding="utf-8",
            )
            powershell_result = subprocess.run(
                [
                    pwsh,
                    "-NoLogo",
                    "-NoProfile",
                    "-File",
                    str(generated_ps),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=optional",
                    "--remote-artifacts=required",
                    "--dry-run",
                ],
                cwd=root,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )

        for runtime, result in (("Bash", bash_result), ("PowerShell", powershell_result)):
            output = result.stdout + result.stderr
            self.assertEqual(2, result.returncode, f"{runtime} output:\n{output}")
            self.assertIn("BEP references remote-only test outputs", output)
            self.assertIn("local test.outputs was not found", output)

    def test_uploader_templates_declare_bep_artifact_helper_runfiles(self) -> None:
        """Validate generated runtimes receive explicit helper and doctor runtime labels."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )
        rule_text = _runfile("tools/core/test_optimization_uploader.bzl").read_text(encoding="utf-8")

        self.assertIn('BEP_ARTIFACT_STAGE_HELPER_RLOC="__DDTPL_BEP_ARTIFACT_STAGE_HELPER_RLOC__"', bash_text)
        self.assertIn('DOCTOR_RUNTIME_RLOC="__DDTPL_DOCTOR_RUNTIME_RLOC__"', bash_text)
        self.assertIn('$script:BepArtifactStageHelperRloc = "__DDTPL_BEP_ARTIFACT_STAGE_HELPER_RLOC__"', powershell_text)
        self.assertIn('$script:DoctorRuntimeRloc = "__DDTPL_DOCTOR_RUNTIME_RLOC__"', powershell_text)
        self.assertIn("bep_artifact_stage_helper_rloc", rule_text)
        self.assertIn("doctor_runtime_rloc", rule_text)
        self.assertIn("_bep_artifact_stage_helper", rule_text)
        self.assertIn("_doctor_runtime", rule_text)
        self.assertIn("bep_artifact_stage_helper.py", rule_text)
        self.assertIn("test_optimization_doctor.py", rule_text)
        self.assertIn("files = depset([bash_file, ps_file, bat_file])", rule_text)
        self.assertIn("--artifact-source=local|bep|auto", rule_text)
        self.assertIn("DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE", rule_text)
        self.assertIn("--remote-artifacts=disabled|download|required", rule_text)
        self.assertIn("DD_TEST_OPTIMIZATION_BEP_ARTIFACT_DOWNLOADER", rule_text)
        self.assertIn("Artifact staging requires Python at uploader runtime", rule_text)

    def test_generated_uploader_runtime_outputs_are_inspectable(self) -> None:
        """Validate generated uploader files render helper runfiles without placeholders."""
        if os.environ.get("TEST_SRCDIR"):
            base = "tools/tests/python/fixtures/generated_uploader"
            generated_bash = _runfile(f"{base}/generated_uploader.sh").read_text(encoding="utf-8")
            generated_ps = _runfile(f"{base}/generated_uploader.ps1").read_text(encoding="utf-8")
            generated_bat = _runfile(f"{base}/generated_uploader.bat").read_text(encoding="utf-8")
        else:
            generated_bash = _render_uploader_runtime_template("tools/core/uploader_bash_runtime.sh.tpl")
            generated_ps = _render_uploader_runtime_template("tools/core/uploader_powershell_runtime.ps1.tpl")
            generated_bat = _render_uploader_runtime_template("tools/core/uploader_batch_runtime.bat.tpl")

        for text in (generated_bash, generated_ps, generated_bat):
            self.assertNotIn("__DDTPL_", text)
        self.assertIn('BEP_ARTIFACT_STAGE_HELPER_RLOC="tools/core/bep_artifact_stage_helper.py"', generated_bash)
        self.assertIn('DOCTOR_RUNTIME_RLOC="tools/core/test_optimization_doctor.py"', generated_bash)
        self.assertIn('$script:BepArtifactStageHelperRloc = "tools/core/bep_artifact_stage_helper.py"', generated_ps)
        self.assertIn('$script:DoctorRuntimeRloc = "tools/core/test_optimization_doctor.py"', generated_ps)
        self.assertIn("generated_uploader.ps1", generated_bat)

    def test_bash_uploader_artifact_staging_uses_helper_and_multi_root_cache(self) -> None:
        """Validate Bash staging delegates to Python helper and dedupes discovery by key."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")

        for token in [
            "--artifact-source",
            "--remote-artifacts",
            "--artifact-staging-dir",
            "--bep-artifact-downloader",
            "--bep-artifact-downloader-timeout-sec",
            "DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE",
            "DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS",
            "DD_TEST_OPTIMIZATION_ARTIFACT_STAGING_DIR",
            "stage_bep_artifacts()",
            "parse_bep_artifact_helper_output()",
            "TESTLOGS_SCAN_DIRS",
            "SELECTED_BEP_ARTIFACT_OUTPUT_KEYS_FILE",
            "BLOCKED_BEP_ARTIFACT_LABELS_FILE",
            "STAGED_REMOTE_CLEARANCES_FILE",
        ]:
            self.assertIn(token, bash_text)
        self.assertIn('bep_artifact_staging_python()', bash_text)
        self.assertIn('"$python_bin" "$BEP_ARTIFACT_STAGE_HELPER"', bash_text)
        self.assertIn('--doctor-runtime "$DOCTOR_RUNTIME"', bash_text)
        self.assertIn('elif ! is_absolute_path "$ARTIFACT_STAGING_DIR"', bash_text)
        self.assertIn('[A-Za-z]:/*|[A-Za-z]:\\\\*|\\\\\\\\*) return 0', bash_text)
        self.assertIn('ARTIFACT_STAGING_DIR="$BUILD_WORKSPACE_DIRECTORY/$ARTIFACT_STAGING_DIR"', bash_text)
        self.assertIn('outputs_dir="${outputs_dir//\\\\//}"', bash_text)
        self.assertIn('scan_root="${scan_root//\\\\//}"', bash_text)
        self.assertIn('resolved_bep_json="$(resolve_runtime_file_path "$bep_json")"', bash_text)
        self.assertIn('"${resolved_bep_files[@]}"', bash_text)
        self.assertNotIn('"${helper_args[@]}" "${BEP_JSON_FILES[@]}"', bash_text)
        self.assertIn("selected)", bash_text)
        self.assertIn("blocked_label)", bash_text)
        self.assertIn("staged)", bash_text)
        self.assertIn("root)", bash_text)
        self.assertNotIn("mapfile", bash_text)
        self.assertNotIn("readarray", bash_text)

    def test_powershell_uploader_artifact_staging_uses_helper_and_multi_root_cache(self) -> None:
        """Validate PowerShell staging delegates to Python helper and dedupes discovery by key."""
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        for token in [
            "--artifact-source",
            "--remote-artifacts",
            "--artifact-staging-dir",
            "--bep-artifact-downloader",
            "--bep-artifact-downloader-timeout-sec",
            "DD_TEST_OPTIMIZATION_ARTIFACT_SOURCE",
            "DD_TEST_OPTIMIZATION_REMOTE_ARTIFACTS",
            "DD_TEST_OPTIMIZATION_ARTIFACT_STAGING_DIR",
            "function Stage-BepArtifacts",
            "function Parse-BepArtifactHelperOutput",
            "$script:TestlogsScanDirs",
            "$script:SelectedBepArtifactOutputKeys",
            "$script:BlockedBepArtifactLabels",
            "$script:StagedRemoteClearances",
        ]:
            self.assertIn(token, powershell_text)
        self.assertIn("& $PythonBin $script:BepArtifactStageHelper", powershell_text)
        self.assertIn("$previousErrorActionPreference = $ErrorActionPreference", powershell_text)
        self.assertIn("$ErrorActionPreference = 'Continue'", powershell_text)
        self.assertIn("$ErrorActionPreference = $previousErrorActionPreference", powershell_text)
        self.assertIn('2> $helperStderr', powershell_text)
        self.assertIn("Get-Content -LiteralPath $helperStderr", powershell_text)
        self.assertNotIn("$script:BepArtifactStageHelper @cmd 2>&1", powershell_text)
        self.assertIn("if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }", powershell_text)
        self.assertIn('"--doctor-runtime", $script:DoctorRuntime', powershell_text)
        self.assertIn("-not [System.IO.Path]::IsPathRooted($ArtifactStagingDir)", powershell_text)
        self.assertIn("Join-Path $env:BUILD_WORKSPACE_DIRECTORY $ArtifactStagingDir", powershell_text)
        self.assertIn("$resolvedBepJson = Resolve-RuntimeFilePath $bepJson", powershell_text)
        self.assertIn("$cmd += @($resolvedBepJsonFiles.ToArray())", powershell_text)
        self.assertNotIn("$cmd += @($script:BepJsonFiles.ToArray())", powershell_text)
        self.assertIn('"selected"', powershell_text)
        self.assertIn('"blocked_label"', powershell_text)
        self.assertIn('"staged"', powershell_text)
        self.assertIn('"root"', powershell_text)
        self.assertIn("$parts = $line.Split([char]9)", powershell_text)
        self.assertNotIn('$line -split "`t", -1', powershell_text)

    def test_bash_blocked_bep_artifact_labels_work_without_jq_freshness(self) -> None:
        """Validate no-key BEP artifacts block stale local fallback even without jq."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        function_blocks = "\n".join([
            self._extract_text_block(
                bash_text,
                "test_output_target_label()",
                "log_execution_skip_once()",
            ),
            self._extract_text_block(
                bash_text,
                "test_output_dir_is_freshness_eligible()",
                "test_output_dir_is_execution_eligible()",
            ),
        ])
        script = f"""
set -euo pipefail
log() {{ printf '%s\\n' "$*" >&2; }}
log_freshness_skip_once() {{ return 0; }}
validate_bep_remote_only_outputs() {{ return 0; }}
test_output_dir_key() {{ printf 'pkg/target/test.outputs\\n'; }}
BAZEL_TARGET_METADATA_OUTPUT=bazel_target_metadata.json
JQ_AVAILABLE=0
FRESHNESS_ELIGIBILITY_ENABLED=0
FRESHNESS_SELECTED_SOURCE=bep
FRESHNESS_MODE=disabled
FRESHNESS_CACHED_OUTPUTS_FILE=
FRESHNESS_MISSING_OUTPUT_LABELS_FILE=
FRESHNESS_ELIGIBLE_OUTPUTS_FILE=/dev/null
BLOCKED_BEP_ARTIFACT_LABELS_FILE="$1"
{function_blocks}
if test_output_dir_is_freshness_eligible "$2"; then
  echo eligible
  exit 1
fi
echo blocked
"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            outputs_dir = root / "bazel-testlogs" / "pkg" / "target" / "test.outputs"
            outputs_dir.mkdir(parents=True)
            (outputs_dir / "bazel_target_metadata.json").write_text(
                json.dumps({"bazel.target": "//pkg:target"}),
                encoding="utf-8",
            )
            blocked_labels = root / "blocked-labels.txt"
            blocked_labels.write_text("//pkg:target\n", encoding="utf-8")
            bash = _require_functional_bash(self)

            result = subprocess.run(
                [bash, "-c", script, "bash-test", str(blocked_labels), str(outputs_dir)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        self.assertIn("blocked", result.stdout)

    def test_generated_bash_uploader_executes_bep_staging_runfiles(self) -> None:
        """Validate generated Bash uploader resolves non-sibling helper runfiles."""
        _require_command(self, "jq", "jq is required for Bash BEP freshness parsing")
        bash = _require_functional_bash(self)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            empty_testlogs = root / "bazel-testlogs"
            empty_testlogs.mkdir()
            bep = self._write_bep_staging_smoke_fixture(root)
            runfiles_dir = self._write_non_sibling_runtime_runfiles(root)
            generated_bash = root / "generated_uploader.sh"
            generated_bash.write_text(
                _render_uploader_runtime_template(
                    "tools/core/uploader_bash_runtime.sh.tpl",
                    doctor_runtime_rloc=_NON_SIBLING_DOCTOR_RUNTIME_RLOC,
                ),
                encoding="utf-8",
            )
            generated_bash.chmod(0o755)
            env = self._generated_uploader_smoke_env(root, runfiles_dir)
            env["DD_TEST_OPTIMIZATION_BEP_JSON"] = str(bep)
            report = root / "uploader-report.json"
            staging_dir = root / ".topt" / "bep-artifacts"
            result = subprocess.run(
                [
                    bash,
                    str(generated_bash),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=bep",
                    "--remote-artifacts=download",
                    "--artifact-staging-dir",
                    str(staging_dir),
                    "--report-json",
                    str(report),
                    "--dry-run",
                ],
                cwd=root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            output = result.stdout + result.stderr
            self.assertEqual(0, result.returncode, output)
            self.assertIn("BEP artifact staging selected output key", output)
            self.assertIn("dry-run kept test payload", output)
            self.assertIn("dry-run done", output)
            self.assertNotIn("BEP artifact stage helper not found in runfiles", output)
            self.assertNotIn("BEP artifact staging doctor runtime not found in runfiles", output)
            self._assert_uploader_report_success(report, bep, staging_dir)

    def test_generated_bash_uploader_writes_failure_report(self) -> None:
        """Validate generated Bash uploader writes a report for controlled upload failures."""
        _require_command(self, "jq", "jq is required for Bash dry-run enrichment validation")
        bash = _require_functional_bash(self)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            empty_testlogs = root / "bazel-testlogs"
            empty_testlogs.mkdir()
            bep = self._write_bep_staging_smoke_fixture(root)
            runfiles_dir = self._write_non_sibling_runtime_runfiles(root)
            generated_bash = root / "generated_uploader.sh"
            generated_bash.write_text(
                _render_uploader_runtime_template(
                    "tools/core/uploader_bash_runtime.sh.tpl",
                    doctor_runtime_rloc=_NON_SIBLING_DOCTOR_RUNTIME_RLOC,
                ),
                encoding="utf-8",
            )
            generated_bash.chmod(0o755)
            env = self._generated_uploader_smoke_env(root, runfiles_dir)
            env["DD_TEST_OPTIMIZATION_BEP_JSON"] = str(bep)
            report = root / "uploader-report.json"
            env["DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON"] = str(report)
            result = subprocess.run(
                [
                    bash,
                    str(generated_bash),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=bep",
                    "--remote-artifacts=download",
                    "--artifact-staging-dir",
                    str(root / ".topt" / "bep-artifacts"),
                    "--dry-run",
                    "--validate-enrichment",
                    "--expected-enriched-tag=missing.required.tag",
                ],
                cwd=root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            output = result.stdout + result.stderr
            self.assertEqual(1, result.returncode, output)
            self.assertIn("missing expected tag", output)
            self._assert_uploader_report_failure(report, bep)

    def test_generated_bash_uploader_report_classifies_missing_bep_json(self) -> None:
        """Validate Bash uploader report explains missing BEP configuration."""
        bash = _require_functional_bash(self)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bazel-testlogs").mkdir()
            generated_bash = root / "generated_uploader.sh"
            generated_bash.write_text(
                _render_uploader_runtime_template("tools/core/uploader_bash_runtime.sh.tpl"),
                encoding="utf-8",
            )
            generated_bash.chmod(0o755)
            report = root / "uploader-report.json"
            env = os.environ.copy()
            env.update({
                "BUILD_WORKSPACE_DIRECTORY": str(root),
                "RUNFILES_DIR": str(root / "empty.runfiles"),
                "TESTLOGS_DIR": str(root / "bazel-testlogs"),
            })
            env.pop("DD_TEST_OPTIMIZATION_BEP_JSON", None)
            (root / "empty.runfiles").mkdir()

            result = subprocess.run(
                [
                    bash,
                    str(generated_bash),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=bep",
                    "--report-json",
                    str(report),
                    "--dry-run",
                ],
                cwd=root,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, result.returncode)
            body = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual("missing_bep_json", body["result"]["reason_code"])
            self.assertFalse(body["upload"]["attempted"])

    def test_generated_powershell_uploader_executes_bep_staging_runfiles(self) -> None:
        """Validate generated PowerShell uploader resolves non-sibling helper runfiles."""
        if os.name == "nt":
            self.skipTest("generated PowerShell uploader execution smoke is covered on non-Windows")
        pwsh = _require_command(self, "pwsh", "pwsh is required for generated PowerShell uploader execution")

        root = Path(tempfile.mkdtemp())
        try:
            empty_testlogs = root / "bazel-testlogs"
            empty_testlogs.mkdir()
            bep = self._write_bep_staging_smoke_fixture(root)
            runfiles_dir = self._write_non_sibling_runtime_runfiles(root)
            generated_ps = root / "generated_uploader.ps1"
            generated_ps.write_text(
                _render_uploader_runtime_template(
                    "tools/core/uploader_powershell_runtime.ps1.tpl",
                    doctor_runtime_rloc=_NON_SIBLING_DOCTOR_RUNTIME_RLOC,
                ),
                encoding="utf-8",
            )
            env = self._generated_uploader_smoke_env(root, runfiles_dir)
            env["DD_TEST_OPTIMIZATION_BEP_JSON"] = str(bep)
            report = root / "uploader-report.json"
            staging_dir = root / ".topt" / "bep-artifacts"
            result = subprocess.run(
                [
                    pwsh,
                    "-NoLogo",
                    "-NoProfile",
                    "-File",
                    str(generated_ps),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=bep",
                    "--remote-artifacts=download",
                    "--artifact-staging-dir",
                    str(staging_dir),
                    "--report-json",
                    str(report),
                    "--dry-run",
                ],
                cwd=root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            output = result.stdout + result.stderr
            self.assertEqual(0, result.returncode, output)
            self.assertIn("BEP artifact staging selected output key", output)
            self.assertIn("dry-run kept test payload", output)
            self.assertIn("dry-run done", output)
            self.assertNotIn("BEP artifact stage helper not found in runfiles", output)
            self.assertNotIn("BEP artifact staging doctor runtime not found in runfiles", output)
            self._assert_uploader_report_success(report, bep, staging_dir)
        finally:
            _cleanup_tempdir_with_windows_retry(root)

    def test_generated_powershell_uploader_writes_failure_report(self) -> None:
        """Validate generated PowerShell uploader writes a report for controlled upload failures."""
        if os.name == "nt":
            self.skipTest("generated PowerShell uploader execution smoke is covered on non-Windows")
        pwsh = _require_command(self, "pwsh", "pwsh is required for generated PowerShell uploader execution")

        root = Path(tempfile.mkdtemp())
        try:
            empty_testlogs = root / "bazel-testlogs"
            empty_testlogs.mkdir()
            bep = self._write_bep_staging_smoke_fixture(root)
            runfiles_dir = self._write_non_sibling_runtime_runfiles(root)
            generated_ps = root / "generated_uploader.ps1"
            generated_ps.write_text(
                _render_uploader_runtime_template(
                    "tools/core/uploader_powershell_runtime.ps1.tpl",
                    doctor_runtime_rloc=_NON_SIBLING_DOCTOR_RUNTIME_RLOC,
                ),
                encoding="utf-8",
            )
            env = self._generated_uploader_smoke_env(root, runfiles_dir)
            env["DD_TEST_OPTIMIZATION_BEP_JSON"] = str(bep)
            report = root / "uploader-report.json"
            env["DD_TEST_OPTIMIZATION_UPLOADER_REPORT_JSON"] = str(report)
            result = subprocess.run(
                [
                    pwsh,
                    "-NoLogo",
                    "-NoProfile",
                    "-File",
                    str(generated_ps),
                    "--bep-json",
                    str(bep),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=bep",
                    "--remote-artifacts=download",
                    "--artifact-staging-dir",
                    str(root / ".topt" / "bep-artifacts"),
                    "--dry-run",
                    "--validate-enrichment",
                    "--expected-enriched-tag=missing.required.tag",
                ],
                cwd=root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            output = result.stdout + result.stderr
            self.assertEqual(1, result.returncode, output)
            self.assertIn("missing expected tag", output)
            self._assert_uploader_report_failure(report, bep)
        finally:
            _cleanup_tempdir_with_windows_retry(root)

    def test_generated_powershell_uploader_report_classifies_missing_bep_json(self) -> None:
        """Validate PowerShell uploader report explains missing BEP configuration."""
        if os.name == "nt":
            self.skipTest("generated PowerShell uploader execution smoke is covered on non-Windows")
        pwsh = _require_command(self, "pwsh", "pwsh is required for generated PowerShell uploader execution")

        root = Path(tempfile.mkdtemp())
        try:
            (root / "bazel-testlogs").mkdir()
            generated_ps = root / "generated_uploader.ps1"
            generated_ps.write_text(
                _render_uploader_runtime_template("tools/core/uploader_powershell_runtime.ps1.tpl"),
                encoding="utf-8",
            )
            report = root / "uploader-report.json"
            env = os.environ.copy()
            env.update({
                "BUILD_WORKSPACE_DIRECTORY": str(root),
                "RUNFILES_DIR": str(root / "empty.runfiles"),
                "TESTLOGS_DIR": str(root / "bazel-testlogs"),
            })
            env.pop("DD_TEST_OPTIMIZATION_BEP_JSON", None)
            (root / "empty.runfiles").mkdir()

            result = subprocess.run(
                [
                    pwsh,
                    "-NoLogo",
                    "-NoProfile",
                    "-File",
                    str(generated_ps),
                    "--freshness-source=bep",
                    "--freshness-mode=required",
                    "--artifact-source=bep",
                    "--report-json",
                    str(report),
                    "--dry-run",
                ],
                cwd=root,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )

            self.assertNotEqual(0, result.returncode)
            body = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual("missing_bep_json", body["result"]["reason_code"])
            self.assertFalse(body["upload"]["attempted"])
        finally:
            _cleanup_tempdir_with_windows_retry(root)

    def test_uploader_staging_cleanup_normalizes_physical_paths(self) -> None:
        """Validate staging cleanup tolerates symlink-normalized temp roots."""
        bash_text = _runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text(encoding="utf-8")
        powershell_text = _runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text(
            encoding="utf-8"
        )

        self.assertIn('full_runs_root="$(cd "$runs_root"', bash_text)
        self.assertIn('full_staged_root="$(cd "$staged_root"', bash_text)
        self.assertIn('"$full_runs_root"/*) rm -rf "$full_staged_root"', bash_text)
        self.assertNotIn('"$runs_root"/*) rm -rf "$staged_root"', bash_text)
        self.assertIn("$fullRoot = Resolve-DirectoryPhysicalPath $stagedRoot", powershell_text)
        self.assertIn("$fullRuns = Resolve-DirectoryPhysicalPath $runsRoot", powershell_text)
        self.assertIn("Test-PathUnderDirectory $fullRoot $fullRuns", powershell_text)

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
        self.assertIn('TESTLOGS_SCAN_DIRS+=("$TESTLOGS_SCAN_DIR")', bash_text)
        self.assertIn('find "$scan_dir"', bash_text)

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
        self.assertIn("$script:TestlogsScanDirs.Add($TestlogsScanDir)", powershell_text)
        self.assertIn("Path = $scanDir", powershell_text)

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
