#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Exercise complete enrichment, split, upload, and cleanup for one file.

The suite protects the invariant that one worker owns every derived request.
"""

from __future__ import annotations

from contextlib import contextmanager
import gzip
from io import StringIO
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from uploader_test_support import add_uploader_runtime_to_path

add_uploader_runtime_to_path()

from uploader_py.codeowners import CodeOwnersMatcher  # noqa: E402
from uploader_py.endpoints import EndpointSet  # noqa: E402
from uploader_py.enrichment import ContextPlan, ContextRecord  # noqa: E402
from uploader_py.file_worker import WorkerRuntime, common_headers, process_file  # noqa: E402
from uploader_py.logging_utils import configure_logging  # noqa: E402
from uploader_py.models import (  # noqa: E402
    MAX_TEST_PAYLOAD_BYTES,
    FileStatus,
    FileTask,
    PayloadType,
)
from uploader_py.transport import HttpResult  # noqa: E402


class _FakeTransport:
    def __init__(self, *results: HttpResult) -> None:
        self.results = list(results)
        self.json_calls: list[dict[str, object]] = []
        self.multipart_calls: list[dict[str, object]] = []

    def post_json(
        self,
        url,
        headers,
        body,
        *,
        gzip_body=False,
        content_encoding=None,
    ):
        self.json_calls.append(
            {
                "url": url,
                "headers": dict(headers),
                "body": Path(body).read_bytes() if isinstance(body, Path) else body,
                "gzip_body": gzip_body,
                "content_encoding": content_encoding,
            }
        )
        return self.results.pop(0) if self.results else HttpResult(200, 1)

    def post_prepared_multipart(self, url, headers, prepared):
        self.multipart_calls.append(
            {
                "url": url,
                "headers": dict(headers),
                "body": prepared.path.read_bytes(),
                "content_type": prepared.content_type,
                "content_length": prepared.content_length,
            }
        )
        return self.results.pop(0) if self.results else HttpResult(200, 1)


def _runtime(root: Path, **changes: object) -> WorkerRuntime:
    values: dict[str, object] = {
        "endpoints": EndpointSet(
            agentless=True,
            site="datadoghq.com",
            test_url="https://test.invalid/api/v2/citestcycle",
            coverage_url="https://coverage.invalid/api/v2/citestcov",
            telemetry_url="https://telemetry.invalid/api/v2/apmtelemetry",
        ),
        "invocation_temp_root": root,
        "context_plan": ContextPlan(
            ContextRecord.create(
                "repo",
                {
                    "git.repository_url": "https://example.invalid/repo.git",
                    "git.commit.sha": "abcdef",
                    "env": "ci",
                },
            ),
        ),
        "codeowners_matcher": CodeOwnersMatcher(None, "", ""),
        "runtime_id": "runtime-1",
        "rules_version": "rules-1",
        "uploader_version": "uploader-1",
        "api_key": "secret",
    }
    values.update(changes)
    return WorkerRuntime(**values)  # type: ignore[arg-type]


def _test_task(source: Path, outputs: Path | None = None) -> FileTask:
    return FileTask(
        task_id="test-1",
        source_path=source,
        display_path="payloads/tests/events.json",
        payload_type=PayloadType.TEST,
        test_outputs_dir=outputs,
    )


class FileWorkerTests(unittest.TestCase):
    def test_non_finite_test_json_fails_before_enrichment_or_http(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "events.json"
            source.write_text(
                '{"events":[{"content":{"metrics":{"invalid":NaN}}}]}',
                encoding="utf-8",
            )
            transport = _FakeTransport()

            result = process_file(_test_task(source), _runtime(root), transport)

            self.assertEqual(FileStatus.FAILED, result.status)
            self.assertEqual("invalid_test_json", result.failure_code)
            self.assertEqual([], transport.json_calls)
            self.assertTrue(source.exists())

    def test_task_temporary_cleanup_failure_preserves_successful_upload(self) -> None:
        @contextmanager
        def cleanup_failure(invocation_root, _task_id, *, on_cleanup_error):
            directory = invocation_root / "simulated-task-temp"
            directory.mkdir()
            yield directory
            on_cleanup_error("PermissionError")

        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "events.json"
            source.write_text('{"events":[{"content":{}}]}', encoding="utf-8")
            transport = _FakeTransport(HttpResult(200, 1))

            with patch(
                "uploader_py.file_worker.task_temporary_directory",
                cleanup_failure,
            ):
                result = process_file(_test_task(source), _runtime(root), transport)

            self.assertEqual(FileStatus.SUCCEEDED, result.status)
            self.assertEqual(1, result.requests_succeeded)
            self.assertTrue(result.source_deleted)
            self.assertIn("task_temp_cleanup_failed", result.warning_codes)

    def test_debug_changes_only_logs_not_body_result_or_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            sources: list[Path] = []
            transports: list[_FakeTransport] = []
            results = []
            logs: list[str] = []
            for debug in (False, True):
                run_root = root / ("debug" if debug else "normal")
                run_root.mkdir()
                source = run_root / "events.json"
                source.write_text(
                    '{"events":[{"content":{"meta":{}}}]}',
                    encoding="utf-8",
                )
                stream = StringIO()
                transport = _FakeTransport(HttpResult(200, 1))
                runtime = _runtime(
                    run_root,
                    keep_payloads=True,
                    logger=configure_logging(
                        debug=debug,
                        secrets=("secret",),
                        stream=stream,
                    ),
                )
                sources.append(source)
                transports.append(transport)
                results.append(process_file(_test_task(source), runtime, transport))
                logs.append(stream.getvalue())

            self.assertEqual(results[0], results[1])
            self.assertEqual(transports[0].json_calls, transports[1].json_calls)
            self.assertTrue(all(source.exists() for source in sources))
            self.assertEqual("", logs[0])
            self.assertIn("source_bytes=", logs[1])
            self.assertIn("context_selected=yes", logs[1])
            self.assertIn("enriched_bytes=", logs[1])
            self.assertIn("threshold_bytes=4718592", logs[1])
            self.assertIn("chunk=1/1 bytes=", logs[1])
            self.assertIn("task temporary cleanup completed", logs[1])
            self.assertNotIn("secret", logs[1])

    def test_test_worker_enriches_validates_splits_uploads_and_deletes_source(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            outputs = root / "test.outputs"
            source_dir = outputs / "payloads" / "tests"
            source_dir.mkdir(parents=True)
            source = source_dir / "events.json"
            source.write_text(
                json.dumps(
                    {
                        "metadata": {"*": {"language": "go", "library_version": "1.2.3"}},
                        "events": [
                            {"content": {"meta": {"test.source.file": "src/a.go"}}},
                            {"content": {"meta": {"test.source.file": "src/b.go"}}},
                        ],
                    }
                ),
                encoding="utf-8",
            )
            (outputs / "bazel_target_metadata.json").write_text(
                json.dumps({"bazel.target": "//pkg:test", "bazel.package": "pkg"}),
                encoding="utf-8",
            )
            transport = _FakeTransport(HttpResult(202, 2, retry_delays=(2.0,)))

            result = process_file(
                _test_task(source, outputs),
                _runtime(root, gzip_payloads=True),
                transport,
            )

            self.assertEqual(FileStatus.SUCCEEDED, result.status)
            self.assertEqual(2, result.events)
            self.assertEqual(1, result.chunks_created)
            self.assertEqual(1, result.chunks_uploaded)
            self.assertEqual(2, result.requests_attempted)
            self.assertEqual(1, result.retries)
            self.assertTrue(result.source_deleted)
            self.assertFalse(source.exists())
            self.assertEqual(1, len(transport.json_calls))
            call = transport.json_calls[0]
            self.assertFalse(call["gzip_body"])
            self.assertEqual("gzip", call["content_encoding"])
            self.assertEqual("secret", call["headers"]["DD-API-KEY"])
            self.assertEqual("go", call["headers"]["Datadog-Meta-Lang"])
            body = json.loads(gzip.decompress(call["body"]))
            self.assertEqual("//pkg:test", body["events"][0]["content"]["meta"]["bazel.target"])
            self.assertEqual("abcdef", body["events"][1]["content"]["meta"]["git.commit.sha"])

    def test_preventive_split_happens_before_first_request(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "events.json"
            source.write_text(
                json.dumps(
                    {
                        "events": [
                            {"content": {"meta": {"value": "x" * 2_400_000}}},
                            {"content": {"meta": {"value": "y" * 2_400_000}}},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            transport = _FakeTransport(HttpResult(200, 1), HttpResult(200, 1))

            result = process_file(_test_task(source), _runtime(root), transport)

            self.assertEqual(FileStatus.SUCCEEDED, result.status)
            self.assertEqual(2, result.chunks_created)
            self.assertEqual(2, len(transport.json_calls))
            self.assertTrue(
                all(len(call["body"]) <= MAX_TEST_PAYLOAD_BYTES for call in transport.json_calls)
            )

    def test_failed_middle_chunk_retains_source_and_stops_later_chunks(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "events.json"
            source.write_text(
                json.dumps(
                    {
                        "events": [
                            {"content": {"meta": {"value": "x" * 2_400_000}}},
                            {"content": {"meta": {"value": "y" * 2_400_000}}},
                            {"content": {"meta": {"value": "z" * 2_400_000}}},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            transport = _FakeTransport(
                HttpResult(200, 1),
                HttpResult(503, 4),
                HttpResult(200, 1),
            )

            result = process_file(_test_task(source), _runtime(root), transport)

            self.assertEqual(FileStatus.FAILED, result.status)
            self.assertEqual(3, result.chunks_created)
            self.assertEqual(1, result.chunks_uploaded)
            self.assertEqual(1, result.chunks_failed)
            self.assertEqual(2, len(transport.json_calls))
            self.assertEqual(5, result.requests_attempted)
            self.assertEqual(3, result.retries)
            self.assertTrue(source.exists())

    def test_413_is_terminal_and_source_is_kept(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "events.json"
            source.write_text('{"events":[{"content":{}}]}', encoding="utf-8")
            transport = _FakeTransport(HttpResult(413, 1, body_excerpt=b"too large"))

            result = process_file(_test_task(source), _runtime(root), transport)

            self.assertEqual(FileStatus.FAILED, result.status)
            self.assertEqual("payload_limit_contract_mismatch", result.failure_code)
            self.assertIn("threshold_bytes=4718592", result.failure_message)
            self.assertEqual(1, result.requests_attempted)
            self.assertEqual(0, result.retries)
            self.assertTrue(source.exists())

    def test_unsplit_payload_types_report_413_without_claiming_a_split(self) -> None:
        cases = (
            (PayloadType.COVERAGE, "coverage.json", b'{"files":[]}'),
            (
                PayloadType.TELEMETRY,
                "telemetry.json",
                (
                    b'{"api_version":"v2","request_type":"app-started",'
                    b'"runtime_id":"runtime","application":{},"payload":[]}'
                ),
            ),
        )
        for payload_type, filename, body in cases:
            with self.subTest(payload_type=payload_type), tempfile.TemporaryDirectory() as raw_root:
                root = Path(raw_root)
                source = root / filename
                source.write_bytes(body)
                task = FileTask(
                    task_id=f"{payload_type.value}-413",
                    source_path=source,
                    display_path=f"payloads/{payload_type.value}/{filename}",
                    payload_type=payload_type,
                )

                result = process_file(
                    task,
                    _runtime(root),
                    _FakeTransport(HttpResult(413, 1, body_excerpt=b"too large")),
                )

                self.assertEqual(FileStatus.FAILED, result.status)
                self.assertEqual("upload_http_413", result.failure_code)
                self.assertIn(f"unsplit {payload_type.value} payload", result.failure_message)
                self.assertNotIn("preventive split", result.failure_message)
                self.assertEqual(1, result.requests_attempted)
                self.assertEqual(0, result.retries)
                self.assertTrue(source.exists())

    def test_gzip_failure_warns_and_falls_back_to_exact_json(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "events.json"
            source.write_text('{"events":[{"content":{}}]}', encoding="utf-8")
            transport = _FakeTransport(HttpResult(200, 1))
            logs = StringIO()

            with patch("uploader_py.file_worker.gzip.compress", side_effect=OSError):
                result = process_file(
                    _test_task(source),
                    _runtime(
                        root,
                        gzip_payloads=True,
                        logger=configure_logging(
                            debug=True,
                            secrets=("secret",),
                            stream=logs,
                        ),
                    ),
                    transport,
                )

            self.assertEqual(FileStatus.SUCCEEDED, result.status)
            self.assertIn("gzip_preparation_failed", result.warning_codes)
            self.assertIsNone(transport.json_calls[0]["content_encoding"])
            self.assertEqual(1, len(json.loads(transport.json_calls[0]["body"])["events"]))
            self.assertIn(
                "gzip preparation completed compressed=0 fallback_json=1",
                logs.getvalue(),
            )

    def test_dry_run_uses_same_preparation_without_network_or_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "events.json"
            source.write_text(
                '{"events":[{"content":{"meta":{}}}]}',
                encoding="utf-8",
            )
            transport = _FakeTransport()
            runtime = _runtime(
                root,
                dry_run=True,
                validate_enrichment=True,
                expected_enriched_tags=("git.repository_url", "git.commit.sha"),
            )

            result = process_file(_test_task(source), runtime, transport)

            self.assertEqual(FileStatus.SUCCEEDED, result.status)
            self.assertEqual(1, result.chunks_created)
            self.assertEqual(1, result.requests_planned)
            self.assertEqual(0, result.requests_attempted)
            self.assertEqual([], transport.json_calls)
            self.assertTrue(source.exists())

    def test_dry_run_validates_each_protocol_request_without_transport_calls(self) -> None:
        cases = (
            (
                PayloadType.TEST,
                "events.json",
                b'{"events":[{"content":{}}]}',
            ),
            (PayloadType.COVERAGE, "coverage.json", b'{"files":[]}'),
            (
                PayloadType.TELEMETRY,
                "telemetry.json",
                (
                    b'{"api_version":"v2","request_type":"app-started",'
                    b'"runtime_id":"runtime","application":{},"payload":[]}'
                ),
            ),
        )
        invalid_endpoints = EndpointSet(
            agentless=True,
            site="datadoghq.com",
            test_url="not-an-absolute-url",
            coverage_url="not-an-absolute-url",
            telemetry_url="not-an-absolute-url",
        )
        for payload_type, filename, body in cases:
            with self.subTest(payload_type=payload_type), tempfile.TemporaryDirectory() as raw_root:
                root = Path(raw_root)
                source = root / filename
                source.write_bytes(body)
                task = FileTask(
                    task_id=f"dry-run-{payload_type.value}",
                    source_path=source,
                    display_path=f"payloads/{payload_type.value}/{filename}",
                    payload_type=payload_type,
                )
                transport = _FakeTransport()

                result = process_file(
                    task,
                    _runtime(
                        root,
                        dry_run=True,
                        endpoints=invalid_endpoints,
                    ),
                    transport,
                )

                self.assertEqual(FileStatus.FAILED, result.status)
                self.assertEqual("request_preparation_failed", result.failure_code)
                self.assertEqual([], transport.json_calls)
                self.assertEqual([], transport.multipart_calls)
                self.assertTrue(source.exists())

    def test_dry_run_validates_headers_without_transport_calls(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "events.json"
            source.write_text('{"events":[{"content":{}}]}', encoding="utf-8")
            transport = _FakeTransport()

            result = process_file(
                _test_task(source),
                _runtime(root, dry_run=True, api_key="invalid\nheader"),
                transport,
            )

            self.assertEqual(FileStatus.FAILED, result.status)
            self.assertEqual("request_preparation_failed", result.failure_code)
            self.assertEqual([], transport.json_calls)
            self.assertTrue(source.exists())

    def test_dry_run_enrichment_validation_fails_before_split_and_network(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "events.json"
            source.write_text('{"events":[{"content":{}}]}', encoding="utf-8")
            transport = _FakeTransport()

            result = process_file(
                _test_task(source),
                _runtime(
                    root,
                    dry_run=True,
                    validate_enrichment=True,
                    expected_enriched_tags=("bazel.target",),
                ),
                transport,
            )

            self.assertEqual(FileStatus.FAILED, result.status)
            self.assertEqual("enrichment_tags_missing", result.failure_code)
            self.assertEqual([], transport.json_calls)
            self.assertTrue(source.exists())

    def test_empty_test_payload_and_prefix_filter_are_non_error_skips(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            empty = root / "span_events_empty.json"
            empty.write_text('{"events":[]}', encoding="utf-8")
            filtered = root / "custom.json"
            filtered.write_text('{"events":[{"content":{}}]}', encoding="utf-8")
            transport = _FakeTransport()

            empty_result = process_file(_test_task(empty), _runtime(root), transport)
            filtered_result = process_file(
                _test_task(filtered),
                _runtime(root, filter_prefix=True),
                transport,
            )

            self.assertEqual(FileStatus.SKIPPED, empty_result.status)
            self.assertEqual(FileStatus.SKIPPED, filtered_result.status)
            self.assertEqual([], transport.json_calls)
            self.assertTrue(empty.exists())
            self.assertTrue(filtered.exists())

    def test_coverage_worker_supports_json_and_msgpack_multipart(self) -> None:
        for suffix, expected_type in (
            (".json", "application/json"),
            (".msgpack", "application/msgpack"),
        ):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as raw_root:
                root = Path(raw_root)
                source = root / f"coverage{suffix}"
                source.write_bytes(b"coverage-body")
                task = FileTask(
                    task_id="coverage-1",
                    source_path=source,
                    display_path=f"payloads/coverage/coverage{suffix}",
                    payload_type=PayloadType.COVERAGE,
                )
                transport = _FakeTransport(HttpResult(200, 1))

                result = process_file(task, _runtime(root, keep_payloads=True), transport)

                self.assertEqual(FileStatus.SUCCEEDED, result.status)
                self.assertEqual(1, result.requests_succeeded)
                self.assertTrue(source.exists())
                call = transport.multipart_calls[0]
                self.assertIn(expected_type.encode("ascii"), call["body"])
                self.assertIn(b'{"dummy":true}', call["body"])
                self.assertEqual(len(call["body"]), call["content_length"])

    def test_coverage_dry_run_spools_exact_body_without_transport(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "coverage.json"
            source.write_bytes(b'{"files":[]}')
            task = FileTask(
                task_id="coverage-dry-run",
                source_path=source,
                display_path="payloads/coverage/coverage.json",
                payload_type=PayloadType.COVERAGE,
            )
            transport = _FakeTransport()

            result = process_file(task, _runtime(root, dry_run=True), transport)

            self.assertEqual(FileStatus.SUCCEEDED, result.status)
            self.assertEqual(1, result.requests_planned)
            self.assertEqual([], transport.multipart_calls)
            self.assertTrue(source.exists())

    def test_evp_headers_and_common_header_defaults_are_protocol_specific(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            endpoints = EndpointSet(
                agentless=False,
                site="datadoghq.com",
                test_url="https://agent.invalid/evp_proxy/v2/api/v2/citestcycle",
                coverage_url="https://agent.invalid/evp_proxy/v2/api/v2/citestcov",
                telemetry_url="https://agent.invalid/telemetry/proxy/api/v2/apmtelemetry",
            )
            runtime = _runtime(root, endpoints=endpoints)
            headers = common_headers(runtime)
            self.assertNotIn("DD-API-KEY", headers)
            self.assertEqual("bazel-starlark", headers["Datadog-Meta-Lang"])
            self.assertEqual("uploader-1", headers["Datadog-Meta-Tracer-Version"])


if __name__ == "__main__":
    unittest.main()
