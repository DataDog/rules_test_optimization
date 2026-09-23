# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Logging must change diagnostics, never payload selection or report contents."""

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from uploader_test_support import add_uploader_runtime_to_path, resolve_runfile

add_uploader_runtime_to_path()

from topt_runtime.log_levels import LEVELS, enabled, resolve_log_level
from uploader_py.application import _log_legacy_freshness_markers
from uploader_py.config import ConfigError, parse_uploader_config
from uploader_py.logging_utils import configure_logging
from uploader_py.reporting import AggregateReport, emit_report
import test_optimization_doctor as doctor
import validate_payload_schema as schema


class LogLevelTests(unittest.TestCase):
    def test_core_tools_load_through_isolated_runpy_coverage_entrypoint(self):
        script = (
            "import runpy, sys; "
            "suite = runpy.run_path(sys.argv[1]); "
            "suite['_load_module']('schema_probe', 'tools/core/validate_payload_schema.py'); "
            "suite['_load_module']('doctor_probe', 'tools/core/test_optimization_doctor.py')"
        )
        result = subprocess.run(
            [sys.executable, "-I", "-c", script,
             str(resolve_runfile("tools/tests/python/test_python_tools.py"))],
            text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_defaults_legacy_debug_and_explicit_precedence(self):
        self.assertEqual("INFO", resolve_log_level({}))
        self.assertEqual("DEBUG", resolve_log_level({}, debug=True))
        self.assertEqual("DEBUG", resolve_log_level({"DD_TEST_OPTIMIZATION_DEBUG": "1"}))
        for level in LEVELS:
            env = {
                "DD_TEST_OPTIMIZATION_LOG_LEVEL": " " + level.lower() + " ",
                "DD_TEST_OPTIMIZATION_DEBUG": "1",
            }
            self.assertEqual(level, resolve_log_level(env, debug=True))
            for severity in LEVELS:
                self.assertEqual(LEVELS[severity] >= LEVELS[level], enabled(severity, level=level))
        for invalid in ("WARNING", "TRACE", "OFF", "secret"):
            with self.assertRaisesRegex(ValueError, "must be ERROR, WARN, INFO, or DEBUG") as error:
                resolve_log_level({"DD_TEST_OPTIMIZATION_LOG_LEVEL": invalid})
            self.assertNotIn(invalid, str(error.exception).split(" must ")[0])

    def test_config_explicit_level_overrides_cli_env_and_rule_debug(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(json.dumps({"debug": True}))
            for level in LEVELS:
                config = parse_uploader_config(
                    ["--config", str(path), "--debug"],
                    environ={"DD_TEST_OPTIMIZATION_LOG_LEVEL": level, "DD_TEST_OPTIMIZATION_DEBUG": "1"},
                )
                self.assertEqual(level, config.log_level)
                self.assertEqual(level == "DEBUG", config.debug)
            with self.assertRaises(ConfigError):
                parse_uploader_config(["--config", str(path)], environ={"DD_TEST_OPTIMIZATION_LOG_LEVEL": "invalid"})

    def test_logging_filter_and_redaction_at_every_level(self):
        for level in LEVELS:
            stream = io.StringIO()
            logger = configure_logging(debug=True, log_level=level, stream=stream, secrets=("private-key",))
            for severity, number in LEVELS.items():
                logger.log(number, "%s private-key", severity)
            output = stream.getvalue()
            self.assertNotIn("private-key", output)
            for severity in LEVELS:
                self.assertEqual(enabled(severity, level=level), severity + " <redacted>" in output)

    def test_cached_output_details_are_debug_only_and_summary_is_bounded(self):
        outputs = tuple("pkg/target%d/test.outputs" % index for index in range(1000))
        plan = SimpleNamespace(
            selected_source="bep",
            eligible_outputs=(),
            remote_only_outputs=(),
            cached_outputs=tuple(("//pkg:target%d" % i, path) for i, path in enumerate(outputs)),
        )
        config = SimpleNamespace(bep_json_files=(Path("bep.json"),), freshness_mode="required")
        for level in LEVELS:
            stream = io.StringIO()
            logger = configure_logging(debug=True, log_level=level, stream=stream)
            # Duplicate paths from discovery and BEP must only count once.
            _log_legacy_freshness_markers(config, plan, outputs, logger)
            output = stream.getvalue()
            self.assertEqual(1000 if level == "DEBUG" else 0, output.count("skipping cached or non-current test output:"))
            self.assertEqual(level in ("DEBUG", "INFO"), "skipped_cached_or_non_current_outputs=1000" in output)
            if level == "INFO":
                self.assertEqual(2, len(output.splitlines()))
            elif level in ("WARN", "ERROR"):
                self.assertEqual("", output)

    def test_report_json_and_failures_survive_filtering(self):
        for exit_code in (0, 1):
            report = AggregateReport.create(
                dry_run=True, exit_code=exit_code, configured_workers=1,
                worker_threads=0, peak_active_workers=0, elapsed_seconds=0,
                discovered_by_type={}, results=(),
            )
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "report.json"
                documents = []
                for level in LEVELS:
                    stream = io.StringIO()
                    emit_report(report, stream=stream, report_json=path, log_level=level)
                    documents.append(path.read_bytes())
                    self.assertEqual(exit_code, json.loads(documents[-1])["exit_code"])
                    if level in ("WARN", "ERROR"):
                        self.assertEqual(1 if exit_code else 0, len(stream.getvalue().splitlines()))
                self.assertTrue(all(doc == documents[0] for doc in documents))

    def test_doctor_and_schema_diagnostics_follow_the_same_levels(self):
        for level in LEVELS:
            stream = io.StringIO()
            with (
                mock.patch.dict(os.environ, {
                    "DD_TEST_OPTIMIZATION_LOG_LEVEL": level,
                    "DD_TEST_OPTIMIZATION_DEBUG": "1",
                }),
                contextlib.redirect_stderr(stream),
                contextlib.redirect_stdout(stream),
            ):
                doctor._info("information-marker")
                doctor._summary("summary-marker")
                doctor._warn("warning-marker")
                schema._debug("debug-marker", debug=True)
                with self.assertRaises(SystemExit) as error:
                    doctor._fail("error-marker")
            self.assertEqual(1, error.exception.code)
            output = stream.getvalue()
            for severity, marker in (
                ("INFO", "information-marker"), ("INFO", "summary-marker"),
                ("WARN", "warning-marker"), ("DEBUG", "debug-marker"),
                ("ERROR", "error-marker"),
            ):
                self.assertEqual(enabled(severity, level=level), marker in output)

    def test_schema_legacy_opt_out_and_explicit_level_precedence(self):
        env = {
            "DD_TEST_OPTIMIZATION_DEBUG": "1",
            "DD_TEST_OPTIMIZATION_SCHEMA_DEBUG": "0",
            "DD_TEST_OPTIMIZATION_LOG_LEVEL": "",
        }
        with mock.patch.dict(os.environ, env):
            stream = io.StringIO()
            with contextlib.redirect_stderr(stream):
                schema._debug("hidden-marker")
            self.assertEqual("", stream.getvalue())
            self.assertFalse(schema._debug_enabled())
            with mock.patch.dict(os.environ, {"DD_TEST_OPTIMIZATION_LOG_LEVEL": "DEBUG"}):
                self.assertTrue(schema._debug_enabled())

    def test_invalid_level_does_not_silently_run_doctor(self):
        stream = io.StringIO()
        with (
            mock.patch.dict(os.environ, {"DD_TEST_OPTIMIZATION_LOG_LEVEL": "secret-invalid-value"}),
            contextlib.redirect_stderr(stream),
        ):
            with self.assertRaises(SystemExit) as error:
                doctor.main([])
        self.assertNotEqual(0, error.exception.code)
        self.assertIn("must be ERROR, WARN, INFO, or DEBUG", stream.getvalue())
        self.assertNotIn("secret-invalid-value", stream.getvalue())

    def test_legacy_shell_logging_boundaries_preserve_machine_stdout(self):
        # Execute the actual template logging functions, without upload setup.
        bash = resolve_runfile("tools/core/uploader_bash_runtime.sh.tpl").read_text()
        bash = bash[:bash.index('dbg "startup runfiles env:')]
        ps = resolve_runfile("tools/core/uploader_powershell_runtime.ps1.tpl").read_text()
        ps = ps[ps.index("# Logging functions"):ps.index("function Write-Utf8NoBomFile")]
        runtimes = []
        bash_executable = shutil.which("bash")
        if os.name == "nt":
            # PATH may select Windows' WSL launcher, not the installed Git Bash.
            git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
            if git_bash.is_file():
                bash_executable = str(git_bash)
        if bash_executable:
            runtimes.append(([bash_executable, "-c"], bash + '\nlog "info-marker"; log "warning: warn-marker"; log "error: error-marker"; dbg "debug-marker"; printf "machine-result\\n"\n'))
        if shutil.which("pwsh"):
            runtimes.append((["pwsh", "-NoProfile", "-NonInteractive", "-Command"], ps + '\nLog "info-marker"; Log "warning: warn-marker"; Log "error: error-marker"; Dbg "debug-marker"; Write-Output "machine-result"'))
        self.assertTrue(runtimes, "at least one supported shell must be available")
        for command, script in runtimes:
            for level in (*LEVELS, "invalid"):
                with self.subTest(shell=command[0], level=level):
                    env = dict(os.environ, DD_TEST_OPTIMIZATION_LOG_LEVEL=level, DD_TEST_OPTIMIZATION_DEBUG="1")
                    result = subprocess.run([*command, script], env=env, text=True, capture_output=True, timeout=20)
                    if level == "invalid":
                        self.assertEqual(2, result.returncode)
                        self.assertIn("must be ERROR, WARN, INFO, or DEBUG", result.stderr)
                        continue
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertIn("machine-result", result.stdout)
                    output = result.stdout + result.stderr
                    for severity, marker in (
                        ("INFO", "info-marker"), ("WARN", "warn-marker"),
                        ("ERROR", "error-marker"), ("DEBUG", "debug-marker"),
                    ):
                        self.assertEqual(enabled(severity, level=level), marker in output, output)
