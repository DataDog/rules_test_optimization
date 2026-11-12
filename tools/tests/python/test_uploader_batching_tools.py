#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Protect event identity and exact envelope partitioning for test batches."""

from copy import deepcopy
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
from queue import Queue
import shutil
import subprocess
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock

from uploader_test_support import add_uploader_runtime_to_path, resolve_runfile

add_uploader_runtime_to_path()

from uploader_py.batching import BatchCompatibilityError, localize_runtime_ids, schema_for_event_runtime_ids  # noqa: E402
from uploader_py.application import run_uploader  # noqa: E402
from uploader_py.config import ConfigError, parse_uploader_config  # noqa: E402
from uploader_py.endpoints import build_endpoints  # noqa: E402
from uploader_py.logging_utils import configure_logging  # noqa: E402
from uploader_py.batch_worker import process_test_cohort  # noqa: E402
from uploader_py.file_worker import process_file  # noqa: E402
from uploader_py.models import FileResult, FileStatus, FileTask, PayloadType, WorkItemOutcome  # noqa: E402
from uploader_py.reporting import AggregateReport  # noqa: E402
from uploader_py.transport import HttpResult, prepare_json_request  # noqa: E402
from uploader_py.worker_pool import WorkerPoolInterrupted, run_file_workers  # noqa: E402
from topt_runtime.runfiles import RunfilesResolver  # noqa: E402
from test_uploader_file_worker_tools import _runtime as _base_runtime, _FakeTransport  # noqa: E402
from test_python_tools import _render_uploader_runtime_template  # noqa: E402
from validate_payload_schema import validate_payload  # noqa: E402


def payload(runtime="process-a"):
    return {"version": 1, "metadata": {"*": {"runtime-id": runtime, "language": "go", "library_version": "mini-test"}},
        "events": [{"type": "test", "version": 2, "content": {"trace_id": 1, "span_id": 2,
            "test_session_id": 3, "test_module_id": 4, "test_suite_id": 5,
            "name": "go.test", "service": "fixture", "resource": "example", "type": "test",
            "start": 1_000_000_000_000_000_000, "duration": 1, "error": 0,
            "meta": {"test.name": "example", "test.status": "pass"}}}]}


def _runtime(root, **changes):
    schema = json.loads(resolve_runfile("tools/core/schemas/agentless-schema.json").read_text())
    values = {"schema": schema, "batch_schema": schema_for_event_runtime_ids(schema)}
    values.update(changes)
    return _base_runtime(root, **values)


class BatchEnvelopeTests(unittest.TestCase):
    def test_localized_payload_keeps_the_canonical_global_runtime_requirement(self):
        schema = json.loads(resolve_runfile("tools/core/schemas/agentless-schema.json").read_text())
        source = payload()
        localize_runtime_ids(source)
        self.assertTrue(validate_payload(source, schema).valid)
        self.assertEqual("process-a", source["metadata"]["*"]["runtime-id"])
        outbound = schema_for_event_runtime_ids(schema)
        source["metadata"]["*"].pop("runtime-id")
        self.assertFalse(validate_payload(source, outbound).valid)

    def test_type_event_test_levels_and_global_precedence_preserves_opaque_scopes(self):
        source = payload()
        source["metadata"].update({"test": {"runtime-id": "type"},
            "test_levels": {"runtime-id": "levels"}, "opaque": {"runtime-id": "opaque"}})
        source["events"] = [
            {"type": "test", "content": {"meta": {"runtime-id": "event"}}},
            {"type": "test_suite_end", "content": {}},
            {"type": "test_module_end", "content": {"meta": {"runtime-id": "module"}}},
            {"type": "span", "content": {}},
        ]
        localize_runtime_ids(source)
        self.assertEqual(["type", "levels", "module", "process-a"],
            [event["content"]["meta"]["runtime-id"] for event in source["events"]])
        self.assertEqual("opaque", source["metadata"]["opaque"]["runtime-id"])
        self.assertEqual("process-a", source["metadata"]["*"]["runtime-id"])
        self.assertNotIn("runtime-id", source["metadata"]["test"])
        self.assertNotIn("runtime-id", source["metadata"]["test_levels"])

    def test_larger_type_override_is_budgeted_before_replacing_an_event_id(self):
        source = payload()
        source["metadata"]["test"] = {"runtime-id": "x" * 1000}
        source["events"][0]["content"]["meta"]["runtime-id"] = "small"
        source["events"] *= 20
        original = deepcopy(source)
        with self.assertRaisesRegex(BatchCompatibilityError, "budget"):
            localize_runtime_ids(source, max_additional_bytes=5000)
        self.assertEqual(original, source)

    def test_outbound_schema_requires_event_ids_without_mutating_the_source_schema(self):
        schema = {"type": "object", "properties": {
            "metadata": {"type": "object", "properties": {"*": {"type": "object", "required": ["language", "runtime-id"]}}},
            "events": {"type": "array", "items": {"type": "object"}}}}
        original = deepcopy(schema)
        outbound_schema = schema_for_event_runtime_ids(schema)
        source = payload()
        localize_runtime_ids(source)
        self.assertTrue(validate_payload(source, outbound_schema).valid)
        source["events"][0]["content"]["meta"].pop("runtime-id")
        self.assertFalse(validate_payload(source, outbound_schema).valid)
        self.assertEqual(original, schema)
    def test_runtime_id_expansion_is_rejected_before_mutating_the_source(self):
        source = payload("x" * 1000)
        source["events"] *= 20
        original = deepcopy(source)
        with self.assertRaisesRegex(BatchCompatibilityError, "budget"):
            localize_runtime_ids(source, max_additional_bytes=5000)
        self.assertEqual(original, source)

    def test_processes_share_an_envelope_and_keep_distinct_event_runtime_ids(self):
        first, second = payload(), payload("process-b")
        first_key = localize_runtime_ids(first)
        self.assertEqual(first_key, localize_runtime_ids(second))
        self.assertEqual(["process-a", "process-b"], [source["events"][0]["content"]["meta"]["runtime-id"] for source in (first, second)])
        self.assertEqual({"runtime-id": "process-a", "language": "go", "library_version": "mini-test"}, first["metadata"]["*"])

    def test_event_and_type_overrides_keep_their_own_runtime_ids(self):
        source = payload()
        source["metadata"]["test"] = {"runtime-id": "type-runtime", "shared-tag": "unchanged"}
        source["events"] = [
            {"type": "test", "content": {"meta": {"runtime-id": "event-runtime"}}},
            {"type": "test", "content": {"meta": {}}},
            {"type": "test_suite_end", "content": {}},
        ]
        localize_runtime_ids(source)
        self.assertEqual(["type-runtime", "type-runtime", "process-a"], [event["content"]["meta"]["runtime-id"] for event in source["events"]])
        self.assertEqual({"shared-tag": "unchanged"}, source["metadata"]["test"])
        self.assertEqual("process-a", source["metadata"]["*"]["runtime-id"])

    def test_every_other_envelope_field_prevents_an_unsafe_merge(self):
        control = localize_runtime_ids(payload())
        for field, value in (("env", "different"), ("library_version", "different"), ("unknown", {"nested": True})):
            source = payload()
            source["metadata"]["*"][field] = value
            self.assertNotEqual(control, localize_runtime_ids(source))
        source = payload()
        source["custom_ingest_timestamp"] = 123
        self.assertNotEqual(control, localize_runtime_ids(source))

    def test_unsupported_event_does_not_mutate_earlier_events_or_defaults(self):
        for invalid in ({"type": "test", "content": {"meta": {"runtime-id": None}}}, {"type": "test", "content": {"meta": []}}, {"content": {}}):
            source = payload()
            source["events"].append(invalid)
            original = deepcopy(source)
            with self.assertRaises(BatchCompatibilityError):
                localize_runtime_ids(source)
            self.assertEqual(original, source)


class BatchWorkerTests(unittest.TestCase):
    def test_live_batch_attempts_are_not_added_again_when_the_cohort_finishes(self):
        from io import StringIO
        from uploader_py.logging_utils import configure_logging

        class Transport(_FakeTransport):
            def set_attempt_callback(self, callback):
                self.callback = callback

            def post_json(self, *args, **kwargs):
                self.callback()
                return super().post_json(*args, **kwargs)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            transport = Transport()
            snapshots = []
            with mock.patch("uploader_py.worker_pool._report_progress",
                side_effect=lambda _stop, _logger, snapshot, _total: snapshots.append(snapshot)):
                run = run_file_workers(self._tasks(root), workers=1, runtime=_runtime(root),
                    transport_factory=lambda: transport, process_file=process_file,
                    process_cohort=process_test_cohort,
                    logger=configure_logging(debug=False, stream=StringIO()))
            self.assertEqual((2, 0, 1), snapshots[0]())
            self.assertEqual(1, sum(request.attempts for request in run.requests))
            self.assertIsNone(transport.callback)

    def test_unexpected_source_failures_keep_measurements_and_do_not_poison_siblings(self):
        from uploader_py import batch_worker
        for stage in ("prepare", "ordinary"):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                tasks = self._tasks(root)
                original = tasks[1].source_path.read_bytes()
                transport = _FakeTransport()
                changes = {"schema": {"type": "object", "required": ["missing"]}} if stage == "ordinary" else {}
                runtime = _runtime(root, **changes)
                if stage == "prepare":
                    name = "_read_json_object"
                    actual = batch_worker._read_json_object

                    def process(path, *args):
                        if path == tasks[1].source_path:
                            raise RecursionError("source parse")
                        return actual(path, *args)
                else:
                    name = "_upload_ordinary_prepared"
                    actual = batch_worker._upload_ordinary_prepared

                    def process(task, *args):
                        if task.task_id == tasks[1].task_id:
                            raise RecursionError("source encoding")
                        return actual(task, *args)
                with mock.patch.object(batch_worker, name, side_effect=process):
                    run, _report = self._run(tasks, runtime, transport)
                self.assertEqual([FileStatus.SUCCEEDED, FileStatus.FAILED], [r.status for r in run.results])
                self.assertEqual("unhandled_worker_exception", run.results[1].failure_code)
                self.assertEqual(len(original), run.results[1].source_bytes)
                self.assertIn("read_parse", {p[0] for p in run.results[1].phase_times})
                self.assertEqual(original, tasks[1].source_path.read_bytes())
                self.assertEqual(1, len(transport.json_calls))
                if stage == "ordinary":
                    self.assertIn("schema_validation_failed", run.results[1].warning_codes)

    def _tasks(self, root, count=2):
        tasks = []
        for index in range(count):
            source = root / f"source-{index}.json"
            document = payload(f"process-{index}")
            document["events"][0]["content"]["meta"]["test.name"] = f"test-{index}"
            source.write_text(json.dumps(document))
            tasks.append(FileTask(str(index), source, source.name, PayloadType.TEST))
        return tuple(tasks)

    def _run(self, tasks, runtime, transport):
        run = run_file_workers(tasks, workers=1, runtime=runtime, transport_factory=lambda: transport,
            process_file=process_file, process_cohort=process_test_cohort)
        report = AggregateReport.create(dry_run=runtime.dry_run,
            exit_code=int(any(result.status is FileStatus.FAILED for result in run.results)),
            configured_workers=1, worker_threads=run.worker_threads, peak_active_workers=run.peak_active_workers,
            elapsed_seconds=0, discovered_by_type={PayloadType.TEST: len(tasks)}, results=run.results, requests=run.requests)
        return run, report

    def test_two_processes_share_one_compressed_request_and_two_source_outcomes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            transport = _FakeTransport()
            run, report = self._run(tasks, _runtime(root, gzip_payloads=True), transport)
            self.assertEqual(1, len(transport.json_calls))
            body = json.loads(gzip.decompress(transport.json_calls[0]["body"]))
            self.assertEqual("process-0", body["metadata"]["*"]["runtime-id"])
            self.assertTrue(validate_payload(body, _runtime(root).schema).valid)
            self.assertEqual(["process-0", "process-1"], [event["content"]["meta"]["runtime-id"] for event in body["events"]])
            self.assertEqual(["test-0", "test-1"], [event["content"]["meta"]["test.name"] for event in body["events"]])
            self.assertEqual(2, report.statistics()["files"]["succeeded"])
            self.assertEqual({"planned": 1, "attempted": 1, "succeeded": 1, "failed": 0, "retries": 0}, report.statistics()["requests"])
            self.assertEqual(1, report.statistics()["batching"]["shared_requests"])
            self.assertEqual([1, 1], [result.test_events for result in run.results])
            self.assertTrue(all(result.source_deleted and not task.source_path.exists() for task, result in zip(tasks, run.results)))

    def test_non_payload_rejections_do_not_fan_out_or_delete_sources(self):
        for response in (HttpResult(401, 1), HttpResult(403, 1), HttpResult(429, 3), HttpResult(500, 3), HttpResult(None, 3, transport_error="connection closed")):
            with self.subTest(response=response), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                tasks = self._tasks(root)
                original = [task.source_path.read_bytes() for task in tasks]
                transport = _FakeTransport(response)
                run, report = self._run(tasks, _runtime(root), transport)
                self.assertEqual(1, len(transport.json_calls))
                self.assertTrue(all(result.status is FileStatus.FAILED for result in run.results))
                self.assertEqual(original, [task.source_path.read_bytes() for task in tasks])
                self.assertEqual(response.attempts, report.statistics()["requests"]["attempted"])
                self.assertEqual(response.retries, report.statistics()["requests"]["retries"])

    def test_one_source_fallback_isolates_a_bad_payload_and_counts_shared_rejection_once(self):
        for keep in (False, True):
            with self.subTest(keep=keep), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                tasks = self._tasks(root)
                original = [task.source_path.read_bytes() for task in tasks]
                transport = _FakeTransport(HttpResult(400, 1), HttpResult(202, 1), HttpResult(400, 1))
                run, report = self._run(tasks, _runtime(root, keep_payloads=keep), transport)
                self.assertEqual([FileStatus.SUCCEEDED, FileStatus.FAILED], [result.status for result in run.results])
                self.assertEqual(3, len(transport.json_calls))
                self.assertEqual({"planned": 3, "attempted": 3, "succeeded": 1, "failed": 2, "retries": 0}, report.statistics()["requests"])
                self.assertEqual(keep, tasks[0].source_path.exists())
                if keep:
                    self.assertEqual(original[0], tasks[0].source_path.read_bytes())
                self.assertEqual(original[1], tasks[1].source_path.read_bytes())

    def test_recovered_aggregate_size_rejection_is_visible_without_failing_good_sources(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            transport = _FakeTransport(HttpResult(413, 1), HttpResult(202, 1), HttpResult(202, 1))
            run, report = self._run(self._tasks(root), _runtime(root), transport)
            self.assertEqual(0, report.exit_code)
            self.assertEqual(1, report.statistics()["requests"]["failed"])
            self.assertTrue(all("batch_rejected_then_source_fallback" in result.warning_codes for result in run.results))

    def test_dry_run_prepares_one_body_without_http_or_source_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            original = [task.source_path.read_bytes() for task in tasks]
            transport = _FakeTransport()
            run, report = self._run(tasks, _runtime(root, dry_run=True, gzip_payloads=True), transport)
            self.assertEqual([], transport.json_calls)
            self.assertEqual(original, [task.source_path.read_bytes() for task in tasks])
            self.assertEqual(1, report.statistics()["requests"]["planned"])
            self.assertEqual(0, report.statistics()["requests"]["attempted"])
            self.assertTrue(all(result.status is FileStatus.SUCCEEDED for result in run.results))

    def test_runtime_expansion_falls_back_without_changing_global_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root, 1)
            document = payload("x" * 32000)
            document["events"] *= 20
            tasks[0].source_path.write_text(json.dumps(document))
            transport = _FakeTransport()
            with mock.patch("uploader_py.batch_worker.MAX_TEST_PAYLOAD_BYTES", 256000):
                run, report = self._run(tasks, _runtime(root), transport)
            self.assertEqual(0, report.exit_code)
            self.assertEqual(1, len(transport.json_calls))
            body = json.loads(transport.json_calls[0]["body"])
            self.assertEqual("x" * 32000, body["metadata"]["*"]["runtime-id"])
            self.assertTrue(all("runtime-id" not in event["content"]["meta"] for event in body["events"]))

    def test_unencodable_source_does_not_discard_a_healthy_pending_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            document = payload("second")
            document["events"][0]["content"]["meta"]["test.name"] = "\ud800"
            tasks[1].source_path.write_text(json.dumps(document))
            rejected_bytes = tasks[1].source_path.read_bytes()
            run, report = self._run(tasks, _runtime(root), _FakeTransport())
            self.assertEqual(1, report.statistics()["files"]["succeeded"])
            self.assertEqual(1, report.statistics()["files"]["failed"])
            self.assertEqual(rejected_bytes, tasks[1].source_path.read_bytes())
            self.assertFalse(tasks[0].source_path.exists())

    def test_dry_run_counts_one_encoded_body_and_source_bytes_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            source_bytes = sum(task.source_path.stat().st_size for task in tasks)
            with mock.patch("uploader_py.batch_worker.prepare_json_request", wraps=prepare_json_request) as prepare:
                run, report = self._run(tasks, _runtime(root, dry_run=True, gzip_payloads=True), _FakeTransport())
            self.assertEqual(1, prepare.call_count)
            performance = report.statistics()["performance"]
            self.assertEqual(source_bytes, performance["processed_source_bytes"])
            self.assertGreater(performance["prepared_body_bytes"], 0)
            self.assertEqual(sum(request.prepared_body_bytes for request in run.requests), performance["prepared_body_bytes"])
            self.assertTrue(all(result.prepared_body_bytes == 0 for result in run.results))
            self.assertIn("batch_request", performance["worker_phases"])
            self.assertIn("read_parse", performance["worker_phases"])

    def test_cohorts_are_bounded_by_original_sources(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            transport = _FakeTransport()
            run, report = self._run(self._tasks(root, 129), _runtime(root), transport)
            self.assertEqual(129, len(run.results))
            self.assertEqual([64, 64, 1], [len(request.source_ids) for request in run.requests])
            self.assertEqual(3, report.statistics()["requests"]["attempted"])

    def test_envelope_change_flushes_without_mixing_sources(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            body = json.loads(tasks[1].source_path.read_text())
            body["custom_ingest_timestamp"] = 1_735_689_600_000
            tasks[1].source_path.write_text(json.dumps(body))
            transport = _FakeTransport()
            _run, report = self._run(tasks, _runtime(root), transport)
            self.assertEqual(2, len(transport.json_calls))
            self.assertEqual(2, report.statistics()["requests"]["attempted"])
            self.assertTrue(all(result.request_ids for result in _run.results))

    def test_byte_guard_flushes_before_adding_another_whole_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            for task in tasks:
                document = json.loads(task.source_path.read_text())
                document["events"][0]["content"]["meta"]["padding"] = "x" * 350
                task.source_path.write_text(json.dumps(document))
            transport = _FakeTransport()
            with mock.patch("uploader_py.batch_worker.MAX_TEST_PAYLOAD_BYTES", 1200):
                run, report = self._run(tasks, _runtime(root), transport)
            self.assertEqual(2, len(transport.json_calls))
            self.assertTrue(all(len(call["body"]) <= 1200 for call in transport.json_calls))
            self.assertTrue(all(result.request_ids for result in run.results))
            self.assertEqual(2, report.statistics()["requests"]["succeeded"])

    def test_individually_large_sources_use_the_existing_per_file_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root, 1)
            document = json.loads(tasks[0].source_path.read_text())
            document["events"][0]["content"]["meta"]["padding"] = "x" * 1000
            tasks[0].source_path.write_text(json.dumps(document))
            transport = _FakeTransport()
            with mock.patch("uploader_py.batch_worker.MAX_TEST_PAYLOAD_BYTES", 900):
                run, report = self._run(tasks, _runtime(root), transport)
            self.assertEqual(1, len(transport.json_calls))
            self.assertFalse(run.results[0].request_ids)
            self.assertIn("runtime-id", json.loads(transport.json_calls[0]["body"])["metadata"]["*"])
            self.assertEqual(1, report.statistics()["files"]["succeeded"])

    def test_warning_only_source_keeps_the_per_file_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            transport = _FakeTransport()
            run, report = self._run(tasks, _runtime(root, schema={"type": "object", "required": ["missing"]}), transport)
            self.assertEqual(2, len(transport.json_calls))
            self.assertTrue(all("schema_validation_failed" in result.warning_codes for result in run.results))
            self.assertEqual(2, report.statistics()["files"]["succeeded"])

    def test_invalid_source_header_does_not_prevent_a_healthy_flush(self):
        class ValidatingTransport(_FakeTransport):
            def post_json(self, url, headers, body, **kwargs):
                prepare_json_request(url, headers, body, content_encoding=kwargs.get("content_encoding"))
                return super().post_json(url, headers, body, **kwargs)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            document = json.loads(tasks[0].source_path.read_text())
            document["metadata"]["*"]["library_version"] = "bad\nversion"
            tasks[0].source_path.write_text(json.dumps(document))
            transport = ValidatingTransport()
            run, _report = self._run(tasks, _runtime(root), transport)
            self.assertEqual([FileStatus.FAILED, FileStatus.SUCCEEDED], [result.status for result in run.results])
            self.assertEqual(1, len(transport.json_calls))
            self.assertTrue(tasks[0].source_path.exists())
            self.assertFalse(tasks[1].source_path.exists())

    def test_disappearing_source_does_not_discard_a_pending_healthy_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            tasks[1].source_path.unlink()
            transport = _FakeTransport()
            run, _report = self._run(tasks, _runtime(root), transport)
            self.assertEqual([FileStatus.SUCCEEDED, FileStatus.FAILED], [result.status for result in run.results])
            self.assertEqual(1, len(transport.json_calls))

    def test_cleanup_warning_survives_preparation_failure_in_both_paths(self):
        class FailingTransport(_FakeTransport):
            def post_json(self, url, headers, body, **kwargs):
                prepare_json_request(url, headers, body, content_encoding=kwargs.get("content_encoding"))
                raise OSError("fixture transport failure")

        cleanup = tempfile.TemporaryDirectory.cleanup
        def failed_cleanup(directory):
            cleanup(directory)
            raise PermissionError("fixture cleanup failure")

        for ordinary in (False, True):
            for invalid_header in (False, True):
                with self.subTest(ordinary=ordinary, invalid_header=invalid_header), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    tasks = self._tasks(root)
                    if invalid_header:
                        for task in tasks:
                            document = json.loads(task.source_path.read_text())
                            document["metadata"]["*"]["library_version"] = "bad\nversion"
                            task.source_path.write_text(json.dumps(document))
                    changes = {"schema": {"type": "object", "required": ["missing"]}} if ordinary else {}
                    with mock.patch("uploader_py.temporary.tempfile.TemporaryDirectory.cleanup", autospec=True, side_effect=failed_cleanup):
                        run, report = self._run(tasks, _runtime(root, **changes), FailingTransport())
                    self.assertEqual(2, report.statistics()["files"]["failed"])
                    self.assertTrue(all("task_temp_cleanup_failed" in result.warning_codes for result in run.results))
                    self.assertEqual(["request_preparation_failed" if invalid_header else "file_pipeline_io_failed"] * 2,
                        [result.failure_code for result in run.results])
                    self.assertTrue(all(task.source_path.exists() for task in tasks))

    def test_rejected_batch_cleanup_warning_survives_successful_source_fallback(self):
        cleanup = tempfile.TemporaryDirectory.cleanup
        first = True
        def failed_first_cleanup(directory):
            nonlocal first
            cleanup(directory)
            if first:
                first = False
                raise PermissionError("fixture cleanup failure")

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            transport = _FakeTransport(HttpResult(400, 1), HttpResult(202, 1), HttpResult(202, 1))
            with mock.patch("uploader_py.temporary.tempfile.TemporaryDirectory.cleanup", autospec=True, side_effect=failed_first_cleanup):
                run, report = self._run(tasks, _runtime(root), transport)
            self.assertEqual(0, report.exit_code)
            self.assertEqual(3, report.statistics()["requests"]["attempted"])
            self.assertTrue(all("task_temp_cleanup_failed" in result.warning_codes for result in run.results))

    def test_missing_outbound_schema_preserves_the_ordinary_file_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            for task in tasks:
                document = json.loads(task.source_path.read_text())
                document["events"][0]["version"] = 99
                task.source_path.write_text(json.dumps(document))
            transport = _FakeTransport()
            run, _report = self._run(tasks, _runtime(root, schema=None, batch_schema=None), transport)
            self.assertEqual(2, len(transport.json_calls))
            self.assertTrue(all(not result.request_ids for result in run.results))
            self.assertTrue(all("runtime-id" in json.loads(call["body"])["metadata"]["*"] for call in transport.json_calls))

    def test_telemetry_and_coverage_do_not_flush_unrelated_test_cohorts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tests = self._tasks(root, 3)
            telemetry = FileTask("telemetry", root / "telemetry.json", "telemetry", PayloadType.TELEMETRY)
            coverage = FileTask("coverage", root / "coverage.json", "coverage", PayloadType.COVERAGE)
            tasks = (tests[0], telemetry, tests[1], coverage, tests[2])
            transport = _FakeTransport()
            def ordinary(task, _runtime, _transport):
                self.assertIsNot(task.payload_type, PayloadType.TEST)
                return FileResult(task.task_id, task.display_path, task.payload_type, FileStatus.SUCCEEDED,
                    requests_planned=1, requests_attempted=1, requests_succeeded=1)
            run = run_file_workers(tasks, workers=1, runtime=_runtime(root), transport_factory=lambda: transport,
                process_file=ordinary, process_cohort=process_test_cohort)
            self.assertEqual([task.task_id for task in tasks], [result.task_id for result in run.results])
            self.assertEqual(1, len(transport.json_calls))
            self.assertEqual(3, len(run.requests[0].source_ids))
            report = AggregateReport.create(dry_run=False, exit_code=0, configured_workers=1, worker_threads=run.worker_threads,
                peak_active_workers=run.peak_active_workers, elapsed_seconds=0, results=run.results, requests=run.requests,
                discovered_by_type={PayloadType.TEST: 3, PayloadType.TELEMETRY: 1, PayloadType.COVERAGE: 1})
            self.assertEqual(3, report.statistics()["requests"]["attempted"])

    def test_later_worker_exception_preserves_committed_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root)
            def processor(cohort, _runtime, _transport):
                first = cohort[0]
                yield WorkItemOutcome((FileResult(first.task_id, first.display_path, PayloadType.TEST, FileStatus.SUCCEEDED),))
                raise RuntimeError("later preparation failure")
            run = run_file_workers(tasks, workers=1, runtime=object(), transport_factory=object, process_file=process_file, process_cohort=processor)
            self.assertEqual([FileStatus.SUCCEEDED, FileStatus.FAILED], [result.status for result in run.results])
            self.assertEqual("unhandled_worker_exception", run.results[1].failure_code)

    def test_interrupt_commits_the_active_request_and_cancels_remaining_sources(self):
        started = threading.Event()
        release = threading.Event()
        class Shutdown(threading.Event):
            def set(self):
                super().set()
                release.set()
        shutdown = Shutdown()
        class BlockingTransport(_FakeTransport):
            def post_json(self, *args, **kwargs):
                result = super().post_json(*args, **kwargs)
                started.set()
                if not release.wait(5):
                    raise AssertionError("coordinator did not release the active request")
                return result
        original_join = Queue.join
        join_calls = 0
        def interrupt_first_join(queue):
            nonlocal join_calls
            join_calls += 1
            if join_calls == 1:
                self.assertTrue(started.wait(5), "batch request did not start")
                raise KeyboardInterrupt
            return original_join(queue)
        pool_threading = SimpleNamespace(Thread=threading.Thread, Lock=threading.Lock, Event=lambda: shutdown, current_thread=threading.current_thread)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            tasks = self._tasks(root, 4)
            for task in tasks[2:]:
                document = json.loads(task.source_path.read_text())
                document["custom_ingest_timestamp"] = 1_735_689_600_000
                task.source_path.write_text(json.dumps(document))
            transport = BlockingTransport()
            try:
                with mock.patch("uploader_py.worker_pool.threading", pool_threading), mock.patch.object(Queue, "join", interrupt_first_join):
                    with self.assertRaises(WorkerPoolInterrupted) as raised:
                        self._run(tasks, _runtime(root), transport)
            finally:
                release.set()
            self.assertEqual(["0", "1"], [result.task_id for result in raised.exception.run.results])
            self.assertEqual(2, raised.exception.cancelled)
            self.assertEqual(1, len(raised.exception.run.requests))
            self.assertEqual([False, False, True, True], [task.source_path.exists() for task in tasks])


class BatchConfigurationTests(unittest.TestCase):
    def test_environment_overrides_rule_with_strict_boolean_parsing(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.json"
            config.write_text('{"schema_version":1,"batch_test_payloads":true}')
            args = ["--config", str(config)]
            self.assertTrue(parse_uploader_config(args, environ={}).batch_test_payloads)
            self.assertFalse(parse_uploader_config(args, environ={"DD_TEST_OPTIMIZATION_BATCH_TEST_PAYLOADS": "false"}).batch_test_payloads)
            config.write_text('{"schema_version":1,"batch_test_payloads":false}')
            self.assertTrue(parse_uploader_config(args, environ={"DD_TEST_OPTIMIZATION_BATCH_TEST_PAYLOADS": "true"}).batch_test_payloads)
            with self.assertRaises(ConfigError):
                parse_uploader_config(args, environ={"DD_TEST_OPTIMIZATION_BATCH_TEST_PAYLOADS": "maybe"})
            config.write_text('{"schema_version":1,"batch_test_payloads":"true"}')
            with self.assertRaises(ConfigError):
                parse_uploader_config(args, environ={})

    def test_legacy_launchers_reject_runtime_opt_in_before_upload_setup(self):
        shells = []
        if shutil.which("bash"):
            shells.append(([shutil.which("bash")], "sh", "uploader_bash_runtime.sh.tpl"))
        powershell = shutil.which("pwsh") or shutil.which("powershell")
        if powershell:
            shells.append(([powershell, "-NoProfile", "-File"], "ps1", "uploader_powershell_runtime.ps1.tpl"))
        if not shells:
            self.skipTest("no supported legacy launcher interpreter")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for shell, suffix, template in shells:
                script = root / ("legacy." + suffix)
                script.write_text(_render_uploader_runtime_template("tools/core/" + template))
                for value in ("1", " TRUE ", "yes", "maybe"):
                    with self.subTest(shell=suffix, value=value):
                        env = {key: val for key, val in os.environ.items() if not key.startswith(("DD_", "DATADOG_"))}
                        env["DD_TEST_OPTIMIZATION_BATCH_TEST_PAYLOADS"] = value
                        result = subprocess.run([*shell, str(script)], env=env, cwd=root, capture_output=True, text=True, timeout=20)
                        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
                        self.assertIn("must be true or false" if value == "maybe" else "requires use_python_uploader = True", result.stderr)

    def test_application_uploads_event_runtime_ids_over_real_loopback_http(self):
        self._run_loopback_application("canonical")

    def test_missing_schema_reports_one_warning_and_uses_ordinary_http_uploads(self):
        self._run_loopback_application("missing")

    def test_unsupported_schema_reports_one_warning_and_uses_ordinary_http_uploads(self):
        self._run_loopback_application("unsupported")

    def test_rejected_shared_request_keeps_each_source_and_its_request_reference(self):
        self._run_loopback_application("canonical", reject=True)

    def _run_loopback_application(self, schema_kind, *, reject=False):
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                self.server.encoded_bytes.append(len(body))
                if self.headers.get("Content-Encoding") == "gzip":
                    body = gzip.decompress(body)
                self.server.bodies.append(json.loads(body))
                self.send_response(403 if reject else 202)
                self.send_header("Content-Length", "0")
                self.end_headers()
            def log_message(self, *_args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.bodies = []
        server.encoded_bytes = []
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                output = root / "bazel-testlogs/pkg/test/test.outputs/payloads/tests"
                output.mkdir(parents=True)
                source_tasks = BatchWorkerTests()._tasks(output)
                source_bytes = sum(task.source_path.stat().st_size for task in source_tasks)
                context = root / "context.json"
                context.write_text('{"service":"fixture"}')
                config_path = root / "config.json"
                settings = {"schema_version": 1, "workers": 1, "max_wait_sec": 0, "quiescent_sec": 0}
                if schema_kind == "canonical":
                    settings["schema_json_path"] = str(resolve_runfile("tools/core/schemas/agentless-schema.json"))
                elif schema_kind == "unsupported":
                    custom_schema = root / "custom-schema.json"
                    custom_schema.write_text('{"type":"object"}')
                    settings["schema_json_path"] = str(custom_schema)
                config_path.write_text(json.dumps(settings))
                report = root / "report.json"
                arguments = ["--config", str(config_path), "--allow-cached-payload-uploads", f"--report-json={report}"]
                if reject:
                    arguments.append(f"--retained-outputs-dir={root / 'retained'}")
                config = parse_uploader_config(arguments,
                    environ={"BUILD_WORKSPACE_DIRECTORY": str(root), "DD_API_KEY": "dummy-key",
                        "DD_TEST_OPTIMIZATION_CONTEXT_JSON": str(context), "DD_TEST_OPTIMIZATION_BATCH_TEST_PAYLOADS": "1",
                        "DD_TEST_OPTIMIZATION_GZIP": "1", "DD_TEST_OPTIMIZATION_AGENTLESS_URL": f"http://127.0.0.1:{server.server_address[1]}"}, cwd=root)
                diagnostics = io.StringIO()
                exit_code = run_uploader(config, resolver=RunfilesResolver.from_environment(cwd=root, environ={}), endpoints=build_endpoints(config),
                    logger=configure_logging(debug=False, stream=diagnostics), stream=io.StringIO())
                self.assertEqual(1 if reject else 0, exit_code)
                actual = json.loads(report.read_text())
                performance = actual["performance"]
                self.assertEqual(source_bytes, performance["processed_source_bytes"])
                self.assertEqual(sum(server.encoded_bytes), performance["prepared_body_bytes"])
                self.assertIn("http", performance["worker_phases"])
                if schema_kind == "canonical":
                    self.assertIn("batch_request", performance["worker_phases"])
                if reject:
                    self.assertEqual(1, len(server.bodies))
                    self.assertEqual(2, actual["files"]["failed"])
                    self.assertEqual(1, actual["requests"]["failed"])
                    catalogs = list((root / "retained").glob("*/catalog.json"))
                    self.assertEqual(1, len(catalogs))
                    catalog = json.loads(catalogs[0].read_text())
                    self.assertNotIn("dummy-key", catalogs[0].read_text())
                    self.assertEqual(2, len(catalog["sources"]))
                    self.assertEqual(1, len(catalog["requests"]))
                    request = catalog["requests"][0]
                    self.assertFalse(request["succeeded"])
                    self.assertEqual(set(request["source_ids"]), {source["task_id"] for source in catalog["source_outcomes"]})
                    self.assertTrue(all(source["request_ids"] == [request["request_id"]] for source in catalog["source_outcomes"]))
                    for source in catalog["sources"]:
                        self.assertEqual((output / source["source_name"]).read_bytes(), (catalogs[0].parent / source["payload"]).read_bytes())
                    return
                if schema_kind != "canonical":
                    self.assertEqual(2, len(server.bodies))
                    self.assertTrue(all("runtime-id" in body["metadata"]["*"] for body in server.bodies))
                    self.assertEqual(1, actual["warnings"]["batching_schema_unavailable"])
                    self.assertEqual(1, diagnostics.getvalue().count("batching_schema_unavailable"))
                    return
                self.assertEqual(1, len(server.bodies))
                self.assertEqual("process-0", server.bodies[0]["metadata"]["*"]["runtime-id"])
                self.assertEqual(["process-0", "process-1"], [event["content"]["meta"]["runtime-id"] for event in server.bodies[0]["events"]])
                self.assertEqual(2, actual["files"]["succeeded"])
                self.assertEqual(1, actual["requests"]["attempted"])
                self.assertEqual(1, actual["batching"]["shared_requests"])
                self.assertFalse(list(output.glob("*.json")))
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
