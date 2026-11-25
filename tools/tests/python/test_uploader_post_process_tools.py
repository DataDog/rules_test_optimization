# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""One uploader run that applies the doctor's checks and uploads.

The uploader runs the invocation with ddtest's post-process, or with the
Python uploader when ddtest leaves it there. Both apply the named doctor's
checks with the same messages and exit status, and send every fresh valid
payload whatever the checks find.
"""

from __future__ import annotations

from io import StringIO
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from uploader_test_support import add_uploader_runtime_to_path, complete_bep_json, resolve_runfile

add_uploader_runtime_to_path()

from topt_runtime.runfiles import RunfilesResolver  # noqa: E402
from uploader_py.application import run_uploader  # noqa: E402
from uploader_py.config import parse_uploader_config  # noqa: E402
from uploader_py.endpoints import build_endpoints  # noqa: E402
from uploader_py.logging_utils import configure_logging  # noqa: E402

_PAYLOAD = {
    "version": 1,
    "metadata": {"*": {"runtime-id": "process-a", "language": "go", "library_version": "fixture"}},
    "events": [{"type": "test", "version": 2, "content": {
        "trace_id": 1, "span_id": 2, "test_session_id": 3, "test_module_id": 4, "test_suite_id": 5,
        "name": "go.test", "service": "original", "resource": "fixture", "type": "test",
        "start": 1000000000000000000, "duration": 1, "error": 0,
        "meta": {"test.name": "fixture", "test.status": "pass", "test.source.file": "pkg/thing_test.go"}}}],
}

_PREFIX = "[dd-test-optimization-doctor] "


def _ddtest() -> Path:
    logical = os.environ.get("DDTEST_EXECUTABLE", "")
    if not logical:
        raise unittest.SkipTest("DDTEST_EXECUTABLE is set only under Bazel")
    return resolve_runfile(logical)


def _output(root: Path, name: str, *, selection: str = "module", payload: bool = True,
            sidecar: str | None = None) -> Path:
    output = root / "bazel-testlogs" / "pkg" / name / "test.outputs"
    output.mkdir(parents=True)
    if payload:
        tests = output / "payloads" / "tests"
        tests.mkdir(parents=True)
        (tests / "span_events_1.json").write_text(json.dumps(_PAYLOAD), encoding="utf-8")
    (output / "bazel_target_metadata.json").write_text(
        sidecar if sidecar is not None else json.dumps(
            {"bazel.target": f"//pkg:{name}", "bazel.package": "pkg", "bazel.go.payload_selection": selection}),
        encoding="utf-8")
    return output


class PostProcessDoctorTests(unittest.TestCase):
    def run_uploader(self, root: Path, *, post_process: bool, arguments: tuple[str, ...] = (),
                     environment: dict[str, str] | None = None, context: bool = False) -> tuple[int, str, str, dict]:
        """Run the uploader with a named doctor that allows only the module selection."""
        doctor_config = root / "doctor.config.json"
        doctor_config.write_text(json.dumps({
            "forbid_dd_git_test_env": False, "require_git_metadata": False, "require_json_payloads": True,
            "require_bazel_metadata": True, "forbid_full_bundle_no_match": True, "forbid_msgpack_payloads": True,
            "allowed_payload_selections": ["module"], "expected_payload_selection_by_target": {},
        }), encoding="utf-8")
        config_path = root / "uploader-config.json"
        config_path.write_text(json.dumps({
            "schema_version": 1, "quiescent_sec": 0, "max_wait_sec": 0, "fail_on_error": True, "workers": 2,
            "rules_version": "rules-test", "uploader_version": "uploader-test", "workspace_name": "workspace",
            "doctor_runtime_path": str(resolve_runfile("tools/core/test_optimization_doctor.py")),
            # The Python backend leaves the invocation to the Python uploader.
            "uploader_backend": "ddtest" if post_process else "python",
            "ddtest_path": str(_ddtest()), "post_process": post_process,
            "doctor_config_path": str(doctor_config),
            **({"context_manifest_path": str(self.context_manifest(root))} if context else {}),
        }), encoding="utf-8")
        report_path = root / "report.json"
        environment = {"BUILD_WORKSPACE_DIRECTORY": str(root), "TESTLOGS_DIR": str(root / "bazel-testlogs"),
                       "DD_API_KEY": "", "DD_SITE": "datadoghq.com", **(environment or {})}
        config = parse_uploader_config(["--config", str(config_path), "--dry-run", f"--report-json={report_path}",
                                        f"--doctor-report-json={root / 'doctor-report.json'}", *arguments],
                                       environ=environment, cwd=root)
        diagnostics, summary = StringIO(), StringIO()
        rc = run_uploader(config, resolver=RunfilesResolver.from_environment(environ={}, cwd=root),
                          endpoints=build_endpoints(config),
                          logger=configure_logging(debug=False, stream=diagnostics), stream=summary)
        report = json.loads(report_path.read_text())
        report["doctor"] = json.loads((root / "doctor-report.json").read_text())
        return rc, summary.getvalue(), diagnostics.getvalue(), report

    def context_manifest(self, root: Path) -> Path:
        """A manifest naming one context, which batching requires."""
        context = root / "context.json"
        context.write_text(json.dumps({"git.repository_url": "https://example.org/repo", "git.commit.sha": "abcdef",
                                       "ci.workspace_path": str(root)}), encoding="utf-8")
        manifest = root / "contexts.manifest"
        manifest.write_text(f"repo\tmissing\t{context}\n", encoding="utf-8")
        return manifest

    def both(self, populate) -> dict[bool, tuple[int, str, str, dict]]:
        runs = {}
        for post_process in (True, False):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                # populate may return extra uploader arguments.
                populated = populate(root)
                arguments = tuple(populated) if isinstance(populated, list) else ()
                rc, summary, diagnostics, report = self.run_uploader(root, post_process=post_process,
                                                                     arguments=arguments)
                # The runs compare their messages with the workspace named alike.
                runs[post_process] = (rc, summary.replace(str(root), "ROOT"), diagnostics.replace(str(root), "ROOT"),
                                      json.loads(json.dumps(report).replace(str(root), "ROOT")))
        return runs

    def doctor_lines(self, text: str) -> list[str]:
        return [line for line in text.splitlines() if line.startswith(_PREFIX)]

    def test_the_run_validates_and_uploads(self) -> None:
        for post_process, (rc, summary, diagnostics, report) in self.both(lambda root: _output(root, "a")).items():
            with self.subTest(post_process=post_process):
                self.assertEqual(0, rc, diagnostics)
                self.assertEqual([_PREFIX + "payload selection summary: module=1",
                                  _PREFIX + "OK: validated 1 test output directorie(s)"], self.doctor_lines(summary))
                self.assertIn("[dd-uploader] summary: mode=dry-run result=success exit_code=0", summary)
                self.assertEqual(1, report["files"]["succeeded"])
                self.assertEqual(("ok", 0, {"module": 1}), (report["doctor"]["status"], report["doctor"]["exit_code"],
                                                            report["doctor"]["summary"]["payload_selection"]))

    def test_a_failed_check_fails_the_run_but_keeps_the_upload(self) -> None:
        def populate(root: Path) -> None:
            _output(root, "a")
            _output(root, "b", selection="full_bundle_disabled")

        runs = self.both(populate)
        for post_process, (rc, _summary, diagnostics, report) in runs.items():
            with self.subTest(post_process=post_process):
                self.assertEqual(1, rc, diagnostics)
                self.assertEqual(1, report["exit_code"])
                self.assertEqual(2, report["files"]["succeeded"])
                self.assertIn("has bazel.go.payload_selection='full_bundle_disabled'; allowed values for this doctor "
                              "target are: module", diagnostics)
        self.assertEqual(self.doctor_lines(runs[True][2]), self.doctor_lines(runs[False][2]))
        self.assertEqual(runs[True][3]["result"], runs[False][3]["result"])
        for _rc, _summary, _diagnostics, report in runs.values():
            self.assertEqual(("fail", 1), (report["doctor"]["status"], report["doctor"]["exit_code"]))
        self.assertEqual(runs[True][3]["doctor"]["result"], runs[False][3]["doctor"]["result"])

    def test_an_output_with_nothing_to_upload_is_checked(self) -> None:
        def populate(root: Path) -> None:
            _output(root, "a")
            _output(root, "empty", payload=False)

        runs = self.both(populate)
        for post_process, (rc, _summary, diagnostics, _report) in runs.items():
            with self.subTest(post_process=post_process):
                self.assertEqual(1, rc, diagnostics)
                self.assertIn(_PREFIX + "missing JSON payloads under ", diagnostics)
        self.assertEqual(self.doctor_lines(runs[True][2]), self.doctor_lines(runs[False][2]))

    def test_the_doctor_report_accounts_for_expected_targets_and_the_bep(self) -> None:
        def populate(root: Path) -> list[str]:
            output = _output(root, "a")
            bep = root / "bep.json"
            result = {"id": {"testResult": {"label": "//pkg:a", "run": 1, "shard": 1, "attempt": 1}},
                      "testResult": {"status": "PASSED", "testActionOutput": [
                          {"name": "test.outputs", "uri": output.as_uri()}]}}
            bep.write_text(complete_bep_json(json.dumps(result), invocation=str(bep)), encoding="utf-8")
            return [f"--bep-json={bep}", "--freshness-source=bep", "--freshness-mode=required",
                    "--expected-target=//pkg:a"]

        runs = self.both(populate)
        for post_process, (rc, _summary, diagnostics, report) in runs.items():
            with self.subTest(post_process=post_process):
                self.assertEqual(0, rc, diagnostics)
                doctor = report["doctor"]
                for name in ("expected", "seen_in_bep", "fresh"):
                    self.assertEqual(["//pkg:a"], doctor["targets"][name], name)
                self.assertEqual(1, doctor["bep"]["eligible_outputs"])
                self.assertEqual(["ROOT/bep.json"], doctor["bep"]["files"])
                self.assertEqual("uploader", doctor["config"]["expected_targets_source"])
                self.assertEqual("ROOT/doctor.config.json", doctor["config"]["config_path"])
                self.assertEqual(1, doctor["summary"]["expected_targets"])
        for section in ("config", "targets", "bep", "artifacts", "summary"):
            self.assertEqual(runs[True][3]["doctor"][section], runs[False][3]["doctor"][section], section)

    def test_post_process_batches_when_the_environment_asks(self) -> None:
        # The rule leaves batching off; DD_TEST_OPTIMIZATION_BATCH_TEST_PAYLOADS
        # turns it on, for post-process as for the Python uploader.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            output = _output(root, "a")
            second = output / "payloads" / "tests" / "span_events_2.json"
            second.write_text(json.dumps(_PAYLOAD), encoding="utf-8")
            rc, _summary, diagnostics, report = self.run_uploader(
                root, post_process=True, environment={"DD_TEST_OPTIMIZATION_BATCH_TEST_PAYLOADS": "1"}, context=True)
        self.assertEqual(0, rc, diagnostics)
        self.assertEqual(2, report["files"]["succeeded"])
        self.assertEqual(1, report["requests"]["planned"], report["requests"])

    def test_a_sidecar_only_python_reads_is_checked_by_the_python_uploader(self) -> None:
        # ddtest's reader rejects duplicate keys, so post-process leaves the
        # run, checks included, to the Python uploader, whose reader keeps the
        # last value.
        sidecar = ('{"bazel.target": "//pkg:a", "bazel.target": "//pkg:a", "bazel.package": "pkg", '
                   '"bazel.go.payload_selection": "full_bundle_no_match"}')
        runs = self.both(lambda root: _output(root, "a", sidecar=sidecar))
        for post_process, (rc, _summary, diagnostics, report) in runs.items():
            with self.subTest(post_process=post_process):
                self.assertEqual(1, rc, diagnostics)
                self.assertIn("has bazel.go.payload_selection='full_bundle_no_match'", diagnostics)
                self.assertEqual(1, report["files"]["succeeded"])
        self.assertEqual(runs[True][2], runs[False][2])


class DoctorValidateTests(unittest.TestCase):
    @unittest.skipIf(os.name == "nt", "ddtest validates on POSIX; Windows keeps the Python doctor")
    def test_the_doctor_validates_with_ddtest_as_it_does_alone(self) -> None:
        ddtest = _ddtest()
        runs = []
        for delegate in (True, False):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                _output(root, "a")
                _output(root, "b", selection="full_bundle_disabled")
                calls = root / "calls"
                wrapper = root / "ddtest"
                wrapper.write_text(f'#!/bin/sh\necho "$*" >> "{calls}"\nexec "{ddtest}" "$@"\n', encoding="utf-8")
                wrapper.chmod(0o755)
                config = root / "doctor.config.json"
                config.write_text(json.dumps({
                    "ddtest_path": str(wrapper) if delegate else "", "expected_targets": [],
                    "require_git_metadata": False, "require_bazel_metadata": True, "require_json_payloads": True,
                    "forbid_full_bundle_no_match": True, "forbid_msgpack_payloads": True,
                    "forbid_dd_git_test_env": False, "allowed_payload_selections": ["module"],
                    "expected_payload_selection_by_target": {},
                }), encoding="utf-8")
                environment = dict(os.environ, BUILD_WORKSPACE_DIRECTORY=str(root),
                                   TESTLOGS_DIR=str(root / "bazel-testlogs"))
                environment.pop("DD_TEST_OPTIMIZATION_LOG_LEVEL", None)
                completed = subprocess.run(
                    [sys.executable, str(resolve_runfile("tools/core/test_optimization_doctor.py")),
                     "--config", str(config)],
                    capture_output=True, text=True, env=environment, check=False)
                invoked = calls.read_text().split() if calls.exists() else []
                runs.append((completed.returncode, completed.stdout.replace(str(root), "ROOT"),
                             completed.stderr.replace(str(root), "ROOT")))
                if delegate:
                    self.assertIn("validate", invoked)
        self.assertEqual(1, runs[0][0], runs[0])
        self.assertIn("allowed values for this doctor target are: module", runs[0][2])
        self.assertEqual(runs[1], runs[0])


if __name__ == "__main__":
    unittest.main()
