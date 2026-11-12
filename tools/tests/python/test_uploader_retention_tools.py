#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Verify retained bytes and publication order independently of HTTP delivery."""

from dataclasses import replace
from contextlib import ExitStack
import errno
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from unittest import mock

from uploader_test_support import add_uploader_runtime_to_path, resolve_runfile

add_uploader_runtime_to_path()

from uploader_py.discovery import DiscoveryResult  # noqa: E402
from uploader_py import freshness as freshness_runtime  # noqa: E402
from uploader_py.application import run_uploader  # noqa: E402
from uploader_py.config import parse_uploader_config  # noqa: E402
from uploader_py.models import FileResult, FileStatus, FileTask, PayloadType  # noqa: E402
from uploader_py.enrichment import ContextPlan, ContextRecord  # noqa: E402
from uploader_py.endpoints import build_endpoints  # noqa: E402
from uploader_py.logging_utils import configure_logging  # noqa: E402
from uploader_py.freshness import FreshnessPlan, FreshnessPreparation  # noqa: E402
from uploader_py.reporting import AggregateReport  # noqa: E402
from uploader_py.resources import LoadedResources  # noqa: E402
from uploader_py.retention import RetentionError, _copy_verified, retain_pending_outputs  # noqa: E402
from topt_runtime.bep_execution import BepTestExecution  # noqa: E402
from topt_runtime.runfiles import RunfilesResolver  # noqa: E402


class RetentionTests(unittest.TestCase):
    def test_wrapper_handoff_paths_use_the_invocation_directory_not_runfiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            config = root / "config.json"
            config.write_text('{"schema_version":1}')
            working = root / "workspace/subdirectory"
            env = {"BUILD_WORKSPACE_DIRECTORY": str(root / "workspace"),
                "BUILD_WORKING_DIRECTORY": str(working),
                "DD_TEST_OPTIMIZATION_INTERNAL_WRAPPER_TEMP_ROOT": "temporary/wrapper",
                "DD_TEST_OPTIMIZATION_INTERNAL_RETENTION_STATUS_FILE": "temporary/wrapper/status.json"}
            parsed = parse_uploader_config(["--config", str(config)], environ=env, cwd=root / "runfiles")
            self.assertEqual(working / "temporary/wrapper", parsed.wrapper_temp_root)
            self.assertEqual(working / "temporary/wrapper/status.json", parsed.retention_status_file)
            env["DD_TEST_OPTIMIZATION_INTERNAL_WRAPPER_TEMP_ROOT"] = str(root / "absolute")
            parsed = parse_uploader_config(["--config", str(config)], environ=env, cwd=root / "runfiles")
            self.assertEqual(root / "absolute", parsed.wrapper_temp_root)

    def test_catalog_infers_missing_expected_targets_only_from_bep(self):
        for source in ("none", "execution_log", "bep"):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                discovery, report = self._inputs(root)
                preparation = FreshnessPreparation(FreshnessPlan(selected_source=source), ())
                outcome = retain_pending_outputs(discovery, report, preparation, None,
                    destination=root / "retained", disposable_roots=(), expected_targets=("//pkg:test",),
                    keep_payloads=False, reason_code="upload_failed")
                missing = json.loads(outcome.catalog.read_text())["unfulfilled_requirements"]["missing_expected_targets"]
                self.assertEqual(["//pkg:test"] if source == "bep" else [], missing)

    def test_retention_path_cli_overrides_environment_and_uses_workspace(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            config = root / "config.json"
            config.write_text('{"schema_version":1}')
            env = {"BUILD_WORKSPACE_DIRECTORY": str(root), "DD_TEST_OPTIMIZATION_RETAINED_OUTPUTS_DIR": "from-env"}
            arguments = ["--config", str(config)]
            self.assertEqual(root / "from-env", parse_uploader_config(arguments, environ=env, cwd=root).retained_outputs_dir)
            parsed = parse_uploader_config([*arguments, "--retained-outputs-dir=from-cli"], environ=env, cwd=root)
            self.assertEqual(root / "from-cli", parsed.retained_outputs_dir)
            self.assertIsNone(parsed.retention_status_file)
            self.assertIsNone(parsed.wrapper_temp_root)

    def _inputs(self, root, status=FileStatus.FAILED):
        output = root / "staging/test.outputs"
        source = output / "payloads/tests/events.json"
        source.parent.mkdir(parents=True)
        source.write_bytes(b'{"events":[{"pending":true}]}')
        (output / "bazel_target_metadata.json").write_text('{"bazel.target":"//pkg:test"}')
        task = FileTask("source-1", source, "pkg/test/test.outputs/payloads/tests/events.json", PayloadType.TEST,
            test_outputs_dir=output, output_key="pkg/test/test.outputs", target_label="//pkg:test")
        report = AggregateReport.create(dry_run=False, exit_code=1, configured_workers=1, worker_threads=1,
            peak_active_workers=1, elapsed_seconds=0, discovered_by_type={PayloadType.TEST: 1},
            results=(FileResult(task.task_id, task.display_path, PayloadType.TEST, status),))
        return DiscoveryResult((), (task,), ((PayloadType.TEST, 1),)), report

    def _retain(self, discovery, report, destination, **kwargs):
        return retain_pending_outputs(discovery, report, None, None, destination=destination,
            disposable_roots=kwargs.pop("disposable_roots", ()), expected_targets=("//pkg:test",),
            keep_payloads=kwargs.pop("keep_payloads", False), reason_code="fresh_output_without_payloads", **kwargs)

    def test_pending_subset_and_metadata_survive_original_staging_removal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            discovery, report = self._inputs(root)
            source = discovery.tasks[0].source_path
            outcome = self._retain(discovery, report, root / "retained", disposable_roots=(root / "staging",))
            catalog = json.loads(outcome.catalog.read_text())
            copied = outcome.catalog.parent / catalog["sources"][0]["payload"]
            self.assertEqual(source.read_bytes(), copied.read_bytes())
            self.assertEqual("unacknowledged", catalog["sources"][0]["disposition"])
            self.assertEqual(1, catalog["uploader_exit_code"])
            self.assertEqual(["//pkg:test"], catalog["expected_targets"])
            self.assertFalse(catalog["automatic_replay_supported"])
            self.assertEqual("events.json", catalog["sources"][0]["source_name"])
            source.unlink()
            self.assertEqual(b'{"events":[{"pending":true}]}', copied.read_bytes())
            self.assertEqual('{"bazel.target":"//pkg:test"}', (outcome.catalog.parent / catalog["sources"][0]["metadata"]["path"]).read_text())

    def test_keep_mode_marks_accepted_data_as_debug_original(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            discovery, report = self._inputs(root, FileStatus.SUCCEEDED)
            self.assertIsNone(self._retain(discovery, report, root / "unused").catalog)
            self.assertFalse((root / "unused").exists())
            outcome = self._retain(discovery, report, root / "retained", keep_payloads=True)
            self.assertEqual("debug_original", json.loads(outcome.catalog.read_text())["sources"][0]["disposition"])
            self.assertTrue(discovery.tasks[0].source_path.exists())

    def test_no_destination_preserves_original_roots_without_a_catalog(self):
        with tempfile.TemporaryDirectory() as tmp:
            discovery, report = self._inputs(Path(tmp))
            outcome = self._retain(discovery, report, None)
            self.assertIsNone(outcome.catalog)
            self.assertEqual(1, outcome.source_count)
            self.assertEqual((discovery.tasks[0].test_outputs_dir.resolve(),), outcome.original_roots)
            self.assertTrue(discovery.tasks[0].source_path.exists())

    def test_context_and_telemetry_facts_are_snapshotted_with_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            discovery, report = self._inputs(root)
            task = replace(discovery.tasks[0], payload_type=PayloadType.TELEMETRY)
            facts = root / "facts.json"
            facts.write_bytes(b'{"rules_version":"test"}')
            record = ContextRecord.create("data", {"service": "fixture"})
            resources = LoadedResources(ContextPlan(record, (record,)), dict(record.values), None, (facts,), None)
            outcome = retain_pending_outputs(replace(discovery, tasks=(task,)), report, None, resources,
                destination=root / "retained", disposable_roots=(), expected_targets=("//pkg:test",),
                keep_payloads=False, reason_code="upload_failed")
            catalog = json.loads(outcome.catalog.read_text())
            self.assertEqual(1, len(catalog["contexts"]))
            self.assertEqual({"service": "fixture"}, json.loads((outcome.catalog.parent / catalog["contexts"][0]["path"]).read_text()))
            self.assertEqual(facts.read_bytes(), (outcome.catalog.parent / catalog["telemetry_facts"][0]["path"]).read_bytes())

    def test_catalog_keeps_accepted_outcomes_and_original_missing_shards(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            discovery, report = self._inputs(root)
            pending = replace(discovery.tasks[0], output_key="pkg/test/shard_1/test.outputs")
            accepted = replace(pending, task_id="accepted", output_key="pkg/test/shard_0/test.outputs", source_path=root / "already-cleaned.json")
            accepted_result = FileResult("accepted", "accepted.json", PayloadType.TEST, FileStatus.SUCCEEDED,
                test_events=1, requests_attempted=1, requests_succeeded=1, source_deleted=True)
            report = AggregateReport.create(dry_run=False, exit_code=1, configured_workers=1, worker_threads=1,
                peak_active_workers=1, elapsed_seconds=0, discovered_by_type={PayloadType.TEST: 2},
                results=(*report.results, accepted_result))
            discovery = replace(discovery, tasks=(pending, accepted), discovered_by_type=((PayloadType.TEST, 2),))
            executions = tuple(BepTestExecution(("invocation", "//pkg:test", "configuration", 1, shard, 1), False, "PASSED",
                frozenset({f"pkg/test/shard_{shard}/test.outputs"})) for shard in range(3))
            preparation = FreshnessPreparation(FreshnessPlan(selected_source="bep", executions=executions,
                eligible_outputs=frozenset(("//pkg:test", key) for execution in executions for key in execution.output_keys)), ())
            outcome = retain_pending_outputs(discovery, report, preparation, None, destination=root / "retained",
                disposable_roots=(), expected_targets=iter(("//pkg:test", "//pkg:absent")), keep_payloads=False, reason_code="fresh_output_without_payloads")
            catalog = json.loads(outcome.catalog.read_text())
            self.assertEqual(["//pkg:absent", "//pkg:test"], catalog["expected_targets"])
            self.assertEqual(1, len(catalog["sources"]))
            self.assertEqual(2, len(catalog["source_outcomes"]))
            self.assertEqual("succeeded", catalog["source_outcomes"][1]["outcome"])
            self.assertEqual([1, 2], [identity[4] for identity in catalog["unfulfilled_requirements"]["missing_test_shards"]])
            self.assertEqual(["//pkg:absent"], catalog["unfulfilled_requirements"]["missing_expected_targets"])
            self.assertFalse(accepted.source_path.exists())

    def test_completed_remote_carrier_survives_preparation_or_freshness_failure(self):
        """Real HTTP download/extraction, no uploader transport or backend calls."""
        for case in ("staging_failure", "planning_failure", "freshness_excluded", "interrupt_after_download", "interrupt_before_commit", "interrupt_after_commit", "optional_success"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                raw = b'{"events":[{"type":"test","content":{"meta":{"test.name":"pending"}}}]}'
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, "w") as bundle:
                    bundle.writestr("payloads/tests/events.json", raw)
                    bundle.writestr("bazel_target_metadata.json", json.dumps({"bazel.target": "//wrong:target" if case == "freshness_excluded" else "//pkg:a"}))
                archive = buffer.getvalue()
                class Handler(BaseHTTPRequestHandler):
                    def do_GET(self):
                        body = archive if "/a/" in self.path else b"not a valid ZIP"
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                    def log_message(self, *_args):
                        pass
                server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
                thread = threading.Thread(target=server.serve_forever)
                thread.start()
                try:
                    records = []
                    for label in (("a", "b") if case in {"staging_failure", "planning_failure"} else ("a",)):
                        records.append({"id": {"testResult": {"label": "//pkg:" + label, "run": 1, "shard": 0, "attempt": 1}},
                            "testResult": {"status": "PASSED", "testActionOutput": [{"name": "test.outputs/outputs.zip", "pathPrefix": ["bazel-out", "config", "testlogs", "pkg", label],
                                "uri": f"http://127.0.0.1:{server.server_address[1]}/testlogs/pkg/{label}/test.outputs/outputs.zip"}]}})
                    bep = root / "bep.ndjson"
                    bep.write_text("\n".join(json.dumps(record) for record in records))
                    config_path = root / "config.json"
                    config_path.write_text(json.dumps({"schema_version": 1, "max_wait_sec": 0, "quiescent_sec": 0,
                        "doctor_runtime_path": str(resolve_runfile("tools/core/test_optimization_doctor.py"))}))
                    arguments = ["--config", str(config_path), "--artifact-source=bep", "--freshness-source=bep", "--freshness-mode=" + ("optional" if case == "optional_success" else "required"),
                        f"--bep-json={bep}", f"--artifact-staging-dir={root / 'staging'}", f"--retained-outputs-dir={root / 'retained'}",
                        "--remote-artifacts=" + ("required" if case == "staging_failure" else "download")]
                    if case == "optional_success":
                        arguments.append("--dry-run")
                    config = parse_uploader_config(arguments,
                        environ={"BUILD_WORKSPACE_DIRECTORY": str(root),
                            "DD_TEST_OPTIMIZATION_INTERNAL_WRAPPER_TEMP_ROOT": str(root / "staging"),
                            "DD_TEST_OPTIMIZATION_INTERNAL_RETENTION_STATUS_FILE": str(root / "staging/status.json")}, cwd=root)
                    transport_factory = mock.Mock() if case == "optional_success" else mock.Mock(side_effect=AssertionError("excluded/preflight sources must not be uploaded"))
                    diagnostics = io.StringIO()
                    with ExitStack() as patches:
                        if case.startswith("interrupt_"):
                            load_doctor = freshness_runtime._load_doctor_runtime
                            def load_interruptible_doctor(*args):
                                doctor = load_doctor(*args)
                                if case == "interrupt_after_download":
                                    download = doctor._download_http_artifact
                                    def interrupt_download(*args, **kwargs):
                                        source = download(*args, **kwargs)
                                        self.assertIsNotNone(source)
                                        self.assertEqual(archive, source.read_bytes())
                                        raise KeyboardInterrupt
                                    patches.enter_context(mock.patch.object(doctor, "_download_http_artifact", interrupt_download))
                                    return doctor
                                commit = doctor._commit_staging_destination
                                def interrupt_commit(temporary, destination):
                                    if case == "interrupt_after_commit":
                                        commit(temporary, destination)
                                    raise KeyboardInterrupt
                                patches.enter_context(mock.patch.object(doctor, "_commit_staging_destination", interrupt_commit))
                                return doctor
                            patches.enter_context(mock.patch.object(freshness_runtime, "_load_doctor_runtime", load_interruptible_doctor))
                        try:
                            exit_code = run_uploader(config, resolver=RunfilesResolver.from_environment(cwd=root, environ={}), endpoints=build_endpoints(config),
                                logger=configure_logging(debug=False, stream=diagnostics), stream=io.StringIO(), transport_factory=transport_factory)
                        except KeyboardInterrupt:
                            self.assertTrue(case.startswith("interrupt_"))
                            exit_code = 130
                    self.assertEqual(130 if case.startswith("interrupt_") else (0 if case in {"freshness_excluded", "optional_success"} else 2), exit_code, diagnostics.getvalue())
                    if case == "optional_success":
                        transport_factory.return_value.post_json.assert_not_called()
                        self.assertNotIn("bep_remote_only_outputs_skipped", diagnostics.getvalue())
                        self.assertFalse(list((root / "staging/__runs").iterdir()))
                        continue
                    transport_factory.assert_not_called()
                    catalogs = list((root / "retained").glob("*/catalog.json"))
                    if case == "interrupt_after_download":
                        self.assertFalse(json.loads((root / "staging/status.json").read_text())["cleanup_safe"])
                        self.assertFalse(catalogs)
                        pending = list((root / "staging/__runs").rglob("outputs.zip"))
                        self.assertEqual(1, len(pending))
                        self.assertEqual(archive, pending[0].read_bytes())
                        self.assertIn("preserving incomplete BEP materialization", diagnostics.getvalue())
                        continue
                    if case == "interrupt_before_commit":
                        self.assertFalse(catalogs)
                        pending = list((root / "staging/__runs").rglob("payloads/tests/events.json"))
                        self.assertEqual(1, len(pending))
                        self.assertEqual(raw, pending[0].read_bytes())
                        self.assertIn("preserving incomplete BEP materialization", diagnostics.getvalue())
                        continue
                    self.assertEqual(1, len(catalogs), diagnostics.getvalue())
                    catalog = json.loads(catalogs[0].read_text())
                    self.assertEqual(1, len(catalog["sources"]))
                    copied = catalogs[0].parent / catalog["sources"][0]["payload"]
                    self.assertEqual(raw, copied.read_bytes())
                    self.assertTrue(catalog["executions"])
                    self.assertFalse(list((root / "staging/__runs").iterdir()))
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join()

    def test_destination_under_wrapper_or_source_root_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            discovery, report = self._inputs(root)
            for destination in (root / "wrapper/reports/retained", root / "staging/test.outputs/retained"):
                with self.subTest(destination=destination), self.assertRaises(RetentionError):
                    self._retain(discovery, report, destination, disposable_roots=(root / "wrapper",))
                self.assertFalse(destination.exists())

    def test_copy_error_never_publishes_catalog_or_deletes_original(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            discovery, report = self._inputs(root)
            with mock.patch("uploader_py.retention._copy_verified", side_effect=OSError("disk full")), self.assertRaises(RetentionError):
                self._retain(discovery, report, root / "retained")
            self.assertFalse(list((root / "retained").glob("*/catalog.json")))
            self.assertTrue(discovery.tasks[0].source_path.exists())

    def test_catalog_publication_error_leaves_original_recoverable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            discovery, report = self._inputs(root)
            with mock.patch("uploader_py.retention.os.replace", side_effect=OSError("disk full")), self.assertRaises(RetentionError):
                self._retain(discovery, report, root / "retained")
            self.assertFalse(list((root / "retained").glob("*/catalog.json")))
            self.assertTrue(discovery.tasks[0].source_path.exists())
            self.assertEqual(1, len(list((root / "retained").glob("*/source-*/payload.json"))))

    def test_verification_rejects_corrupt_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, destination = root / "source", root / "destination"
            source.write_bytes(b"pending")
            original_open = Path.open
            def open_file(path, *args, **kwargs):
                if path == destination and args == ("rb",):
                    return io.BytesIO(b"corrupt")
                return original_open(path, *args, **kwargs)
            with mock.patch.object(Path, "open", open_file), self.assertRaises(RetentionError):
                _copy_verified(source, destination)
            self.assertEqual(b"pending", source.read_bytes())

    def test_retention_does_not_require_cross_filesystem_rename_or_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            discovery, report = self._inputs(root)
            original_replace = os.replace
            def replace_file(source, destination):
                if Path(source).parent != Path(destination).parent:
                    raise OSError(errno.EXDEV, "different filesystem")
                return original_replace(source, destination)
            with mock.patch("os.rename", side_effect=OSError(errno.EXDEV, "different filesystem")), mock.patch("os.link", side_effect=OSError(errno.EXDEV, "different filesystem")), mock.patch("os.replace", replace_file):
                outcome = self._retain(discovery, report, root / "other-filesystem")
            self.assertTrue(outcome.catalog.is_file())
            self.assertTrue(discovery.tasks[0].source_path.is_file())

    def test_source_symlink_cannot_be_copied(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            discovery, report = self._inputs(root)
            original = discovery.tasks[0].source_path
            link = root / "link.json"
            try:
                link.symlink_to(original)
            except OSError as exc:
                self.skipTest(f"symlinks unavailable: {exc}")
            task = replace(discovery.tasks[0], source_path=link)
            with self.assertRaises(RetentionError):
                self._retain(replace(discovery, tasks=(task,)), report, root / "retained")
            self.assertFalse(list((root / "retained").glob("*/catalog.json")))
            self.assertTrue(original.exists())

    def test_wrappers_preserve_pending_bytes_after_the_process_exits(self):
        wrappers = []
        if os.name != "nt" and shutil.which("bash"):
            wrappers.append(("bash", [shutil.which("bash")], "sh"))
        powershell = shutil.which("pwsh") or shutil.which("powershell")
        if powershell:
            wrappers.append(("powershell", [powershell, "-NoProfile", "-File"], "ps1"))
        if not wrappers:
            self.skipTest("no supported wrapper interpreter")
        for shell, launcher, extension in wrappers:
            for case in ("success", "partial", "partial_keep", "partial_chunks", "durable", "copy_failure", "missing_status", "corrupt_status", "wrong_status_root", "keep", "precedence", "support_bundle"):
                with self.subTest(shell=shell, case=case), tempfile.TemporaryDirectory() as tmp:
                    self._run_wrapper(Path(tmp), launcher, extension, case)

    def test_powershell_legacy_preserves_retention_paths(self):
        interpreters = []
        if shutil.which("pwsh"):
            interpreters.append((shutil.which("pwsh"), True))
        if os.name == "nt":
            windows_powershell = shutil.which("powershell.exe")
            self.assertIsNotNone(windows_powershell, "Windows PowerShell 5.1 is required on Windows")
            interpreters.append((windows_powershell, False))
        if not interpreters:
            self.skipTest("PowerShell unavailable")
        for interpreter, set_legacy in interpreters:
            for case in ("success", "durable"):
                with self.subTest(interpreter=interpreter, case=case), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    launcher = [interpreter, "-NoProfile", "-File"]
                    if set_legacy:
                        adapter = root / "legacy.ps1"
                        adapter.write_text("$PSNativeCommandArgumentPassing = 'Legacy'\n"
                            "$wrapper = $args[0]\n"
                            "$arguments = @($args | Select-Object -Skip 1)\n"
                            "& $wrapper @arguments\nexit $LASTEXITCODE\n", encoding="utf-8")
                        launcher.append(str(adapter))
                    self._run_wrapper(root, launcher, "ps1", case)

    @unittest.skipIf(os.name == "nt", "POSIX SIGINT delivery; Windows interruption remains a CI/platform check")
    def test_interrupt_keeps_unacknowledged_staged_source(self):
        bash = shutil.which("bash")
        if not bash:
            self.skipTest("Bash unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            self._run_wrapper(Path(tmp), [bash], "sh", "interrupt")

    def _run_wrapper(self, root, launcher, extension, case):
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if self.headers.get("Content-Encoding") == "gzip":
                    body = gzip.decompress(body)
                document = json.loads(body)
                name = document["events"][0]["content"]["meta"]["test.name"]
                self.server.observed.append(name)
                if case == "interrupt" and name == "pending":
                    self.server.pending_started.set()
                    self.server.release_pending.wait(30)
                reject = case in {"partial", "partial_keep", "partial_chunks", "durable", "copy_failure", "precedence", "support_bundle", "interrupt"} and name == "pending"
                if reject:
                    self.server.rejected_body = body
                self.send_response(400 if reject else 202)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        server.observed = []
        server.pending_started = threading.Event()
        server.release_pending = threading.Event()
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            self._exercise_wrapper(root, launcher, extension, case, server)
        finally:
            server.release_pending.set()
            server.shutdown()
            server.server_close()
            thread.join()

    def _exercise_wrapper(self, root, launcher, extension, case, server):
        config = root / "config.json"
        config.write_text(json.dumps({"schema_version": 1, "max_wait_sec": 0, "quiescent_sec": 0,
            "workers": 2, "fail_on_error": True, "expected_targets": ["//pkg:test"],
            "doctor_runtime_path": str(resolve_runfile("tools/core/test_optimization_doctor.py"))}))
        context = root / "context.json"
        context.write_text(json.dumps({"service": "fixture", "git.repository_url": "https://example.test/fixture.git", "git.commit.sha": "a" * 40}))
        script = root / "fake-bazel.py"
        script.write_text('''#!''' + sys.executable + '''
import json, os
from pathlib import Path
import subprocess, sys, zipfile
root = Path(__file__).parent
case = os.environ["RETENTION_TEST_CASE"]
if sys.argv[1] == "test":
    archive = root / "producer/bazel-testlogs/pkg/test/test.outputs/outputs.zip"
    archive.parent.mkdir(parents=True)
    with zipfile.ZipFile(archive, "w") as bundle:
        if case == "partial_chunks":
            bundle.writestr("payloads/tests/events.json", json.dumps({"events": [{"type": "test", "content": {"meta": {"test.name": name, "test.status": "pass", "padding": "x" * 1200}}} for name in ("accepted", "pending")]}))
        else:
            for name in ("accepted", "pending"):
                bundle.writestr("payloads/tests/" + name + ".json", json.dumps({"events": [{"type": "test", "content": {"meta": {"test.name": name, "test.status": "pass"}}}]}))
        bundle.writestr("bazel_target_metadata.json", json.dumps({"bazel.target": "//pkg:test", "bazel.package": "pkg"}))
    bep = next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--build_event_json_file="))
    Path(bep).write_text(json.dumps({"id": {"testResult": {"label": "//pkg:test", "run": 1, "shard": 0, "attempt": 1}},
        "testResult": {"status": "PASSED", "testActionOutput": [{"name": "test.outputs/outputs.zip", "uri": archive.as_uri()}]}}))
    sys.exit(7 if case == "precedence" else 0)
if sys.argv[1] == "run":
    if "//:dd_test_optimization_doctor" in sys.argv:
        sys.exit(11 if case == "precedence" else 0)
    runtime = sys.argv[sys.argv.index("--") + 1:]
    bootstrap = """
import os
from pathlib import Path
Path(os.environ['RETENTION_UPLOADER_PID_FILE']).write_text(str(os.getpid()))
if os.environ['RETENTION_TEST_CASE'] == 'partial_chunks':
    from uploader_py import file_worker
    from uploader_py.splitting import prepare_test_chunks
    file_worker.prepare_test_chunks = lambda payload, directory: prepare_test_chunks(payload, directory, limit_bytes=1800)
from uploader_py.main import main
raise SystemExit(main())
"""
    result = subprocess.run([sys.executable, "-c", bootstrap, "--config", str(root / "config.json"), *runtime])
    status = os.environ.get("DD_TEST_OPTIMIZATION_INTERNAL_RETENTION_STATUS_FILE")
    if status and case in ("missing_status", "corrupt_status", "wrong_status_root"):
        if case == "missing_status":
            Path(status).unlink(missing_ok=True)
        elif case == "wrong_status_root":
            Path(status).write_text(json.dumps({"schema_version": 1, "wrapper_temp_root": str(root / "not-this-invocation"), "cleanup_safe": True}))
        else:
            Path(status).write_text("{invalid")
    sys.exit(result.returncode)
if sys.argv[1] == "info":
    print(root / "output-base")
    sys.exit(0)
sys.exit(99)
''')
        script.chmod(0o700)
        bazel = script
        if extension == "ps1":
            # Exercise a native executable, as with bazel.exe. Python treats the
            # first verb as a script; each adapter restores the Bazel argv shape.
            bazel = Path(sys.executable)
            for verb in ("test", "run", "info"):
                (root / verb).write_text("import runpy, sys\n"
                    f"sys.argv.insert(1, {verb!r})\n"
                    f"runpy.run_path({str(script)!r}, run_name='__main__')\n",
                    encoding="utf-8")
        env = {key: value for key, value in os.environ.items() if not key.startswith(("DD_", "DATADOG_")) and key.lower() not in {"http_proxy", "https_proxy", "all_proxy", "no_proxy"}}
        env.update({"BAZEL": str(bazel), "RETENTION_TEST_CASE": case, "BUILD_WORKSPACE_DIRECTORY": str(root),
            "RETENTION_UPLOADER_PID_FILE": str(root / "uploader.pid"),
            "DD_API_KEY": "dummy-api-key", "DD_TEST_OPTIMIZATION_CONTEXT_JSON": str(context),
            "DD_TEST_OPTIMIZATION_AGENTLESS_URL": f"http://127.0.0.1:{server.server_address[1]}",
            "DD_TEST_OPTIMIZATION_TMPDIR": str(root / "temporary"), "DD_TEST_OPTIMIZATION_PYTHON": sys.executable,
            "PYTHONPATH": str(resolve_runfile("tools/core/uploader_py/main.py").parents[1])})
        if os.name == "nt":
            # PowerShell needs executable extensions even when given an absolute
            # path. Make native command discovery explicit in the isolated test.
            env["PATHEXT"] = ".COM;.EXE;.BAT;.CMD"
        if extension == "ps1" and case == "success":
            python_path = sys.executable.replace("'", "''")
            command = f"& '{python_path}' -c 'raise SystemExit(7)'; exit $LASTEXITCODE"
            preflight = subprocess.run([launcher[0], "-NoProfile", "-Command", command],
                cwd=root, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(7, preflight.returncode,
                f"Native PowerShell preflight failed; PATHEXT={env.get('PATHEXT', '<unset>')}\n"
                + preflight.stdout + preflight.stderr)
        wrapper = resolve_runfile(f"tools/test_optimization/run_test_optimization_ci.{extension}")
        options = ["--upload"] if extension == "sh" else ["-Upload"]
        if case == "durable":
            options += ["--report-dir" if extension == "sh" else "-ReportDir", str(root / "reports")]
        if case == "copy_failure":
            blocked = root / "not-a-directory"
            blocked.write_text("original file")
            options += ["--retained-outputs-dir" if extension == "sh" else "-RetainedOutputsDir", str(blocked)]
        if case in {"keep", "partial_keep"}:
            env["DD_TEST_OPTIMIZATION_KEEP_PAYLOADS"] = "1"
        if case == "support_bundle":
            options += ["--support-bundle" if extension == "sh" else "-SupportBundle", str(root / "support.zip")]
        command = [*launcher, str(wrapper), *options, "//pkg:test"]
        process = subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            if case == "interrupt":
                self.assertTrue(server.pending_started.wait(10), "uploader did not reach the pending request")
                uploader_pid = int((root / "uploader.pid").read_text())
                os.kill(uploader_pid, signal.SIGINT)
                server.release_pending.set()
            stdout, stderr = process.communicate(timeout=60)
        finally:
            server.release_pending.set()
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        expected_exit = 130 if case == "interrupt" else (7 if case == "precedence" else (1 if case in {"partial", "partial_keep", "partial_chunks", "durable", "copy_failure", "support_bundle"} else 0))
        self.assertEqual(expected_exit, result.returncode, result.stdout + result.stderr)
        self.assertCountEqual(["accepted", "pending"], server.observed)
        temporary_roots = list((root / "temporary").glob("dd-topt*"))
        if case in {"success", "durable"}:
            self.assertFalse(temporary_roots, result.stdout + result.stderr)
        else:
            self.assertEqual(1, len(temporary_roots), result.stdout + result.stderr)
            self.assertIn("keeping Test Optimization temporary files:", result.stdout + result.stderr)
        if case in {"partial", "partial_keep", "copy_failure", "precedence", "keep", "support_bundle", "interrupt"}:
            pending = list(temporary_roots[0].rglob("payloads/tests/pending.json"))
            self.assertEqual(1, len(pending))
            self.assertEqual("pending", json.loads(pending[0].read_text())["events"][0]["content"]["meta"]["test.name"])
            expected_bytes = json.dumps({"events": [{"type": "test", "content": {"meta": {"test.name": "pending", "test.status": "pass"}}}]}).encode()
            self.assertEqual(expected_bytes, pending[0].read_bytes())
            accepted = list(temporary_roots[0].rglob("payloads/tests/accepted.json"))
            self.assertEqual(int(case in {"keep", "partial_keep"}), len(accepted))
        if case == "partial_chunks":
            pending = list(temporary_roots[0].rglob("payloads/tests/events.json"))
            self.assertEqual(1, len(pending))
            self.assertEqual(server.rejected_body, pending[0].read_bytes())
            self.assertEqual(["pending"], [event["content"]["meta"]["test.name"] for event in json.loads(pending[0].read_bytes())["events"]])
        if case == "support_bundle":
            self.assertTrue((root / "support.zip").is_file())
            self.assertFalse(list(root.glob("reports/retained/*/catalog.json")))
            report = json.loads((temporary_roots[0] / "reports/uploader-upload-report.json").read_text())
            self.assertFalse(report["retention"]["durable_destination_configured"])
            self.assertNotIn("output_retention_failed", report["warnings"])
        if case == "durable":
            catalogs = list((root / "reports/retained").glob("*/catalog.json"))
            self.assertEqual(1, len(catalogs))
            catalog = json.loads(catalogs[0].read_text())
            self.assertEqual(1, len(catalog["sources"]))
            self.assertNotIn("dummy-api-key", catalogs[0].read_text())
            payload = catalogs[0].parent / catalog["sources"][0]["payload"]
            self.assertEqual("pending", json.loads(payload.read_text())["events"][0]["content"]["meta"]["test.name"])
