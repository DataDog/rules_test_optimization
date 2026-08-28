#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Telemetry planning and per-file worker regression tests."""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest


def _runfile(rel_path: str) -> Path:
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY", "")
    test_srcdir = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "")
    candidates = []
    if test_srcdir and test_workspace:
        candidates.append(Path(test_srcdir) / test_workspace / rel_path)
    if test_srcdir:
        candidates.append(Path(test_srcdir) / rel_path)
    if workspace:
        candidates.append(Path(workspace) / rel_path)
    for parent in (Path(__file__).resolve().parent, *Path(__file__).resolve().parents):
        if (parent / "MODULE.bazel").exists() or (parent / ".git").exists():
            candidates.append(parent / rel_path)
            break
    for candidate in candidates:
        if candidate.exists():
            return candidate
    manifest_path = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_path and Path(manifest_path).is_file():
        keys = {rel_path, f"{test_workspace}/{rel_path}"}
        with Path(manifest_path).open("r", encoding="utf-8") as handle:
            for line in handle:
                key, separator, value = line.rstrip("\n").partition(" ")
                if separator and key in keys:
                    return Path(value)
    raise FileNotFoundError(f"runfile not found: {rel_path}")


CORE_DIR = _runfile("tools/core/uploader_main.py").parent
if str(CORE_DIR) not in sys.path:
    sys.path.insert(0, str(CORE_DIR))

from uploader_py.codeowners import CodeOwnersMatcher  # noqa: E402
from uploader_py.endpoints import EndpointSet  # noqa: E402
from uploader_py.enrichment import ContextPlan  # noqa: E402
from uploader_py.file_worker import WorkerRuntime, process_file  # noqa: E402
from uploader_py.models import FileStatus, FileTask, PayloadType  # noqa: E402
from uploader_py.telemetry import build_telemetry_plan  # noqa: E402
from uploader_py.transport import HttpResult, prepare_json_request  # noqa: E402


class _Transport:
    def __init__(self, *results: HttpResult) -> None:
        self.results = list(results)
        self.calls: list[dict[str, object]] = []

    def post_json(
        self,
        url,
        headers,
        body,
        *,
        gzip_body=False,
        content_encoding=None,
    ):
        self.calls.append(
            {
                "url": url,
                "headers": dict(headers),
                "body": Path(body).read_bytes(),
                "gzip": gzip_body,
                "content_encoding": content_encoding,
            }
        )
        return self.results.pop(0) if self.results else HttpResult(200, 1)

    def post_multipart(self, *_args, **_kwargs):
        raise AssertionError("telemetry must not use multipart")


class _RetryingSourceMutationTransport:
    """Simulate two transport attempts while the original source changes."""

    def __init__(self, source: Path, replacement: bytes) -> None:
        self.source = source
        self.replacement = replacement
        self.prepared_path: Path | None = None
        self.declared_length = 0
        self.bodies: tuple[bytes, bytes] = ()

    def post_json(
        self,
        url,
        headers,
        body,
        *,
        gzip_body=False,
        content_encoding=None,
    ):
        self.prepared_path = Path(body)
        request = prepare_json_request(
            url,
            headers,
            self.prepared_path,
            gzip_body=gzip_body,
            content_encoding=content_encoding,
        )
        self.declared_length = int(request.headers["Content-Length"])
        with request.body_factory() as first_attempt:
            first_body = first_attempt.read()
        self.source.write_bytes(self.replacement)
        with request.body_factory() as second_attempt:
            second_body = second_attempt.read()
        self.bodies = (first_body, second_body)
        return HttpResult(200, 2, retry_delays=(2.0,))

    def post_multipart(self, *_args, **_kwargs):
        raise AssertionError("telemetry must not use multipart")


def _task(source: Path) -> FileTask:
    return FileTask(
        task_id="telemetry-1",
        source_path=source,
        display_path=f"payloads/telemetry/{source.name}",
        payload_type=PayloadType.TELEMETRY,
    )


def _runtime(root: Path, plan, *, dry_run: bool = False) -> WorkerRuntime:
    return WorkerRuntime(
        endpoints=EndpointSet(
            agentless=True,
            site="datadoghq.com",
            test_url="https://test.invalid",
            coverage_url="https://coverage.invalid",
            telemetry_url="https://telemetry.invalid/api/v2/apmtelemetry",
        ),
        invocation_temp_root=root,
        context_plan=ContextPlan(None),
        codeowners_matcher=CodeOwnersMatcher(None, "", ""),
        runtime_id="uploader-runtime",
        rules_version="rules-1",
        uploader_version="uploader-1",
        api_key="secret",
        telemetry_session_id="session-fallback",
        telemetry_plan=plan,
        dry_run=dry_run,
    )


class TelemetryWorkerTests(unittest.TestCase):
    def test_primary_body_is_task_local_and_stable_across_retry(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "telemetry.json"
            original = (
                b'\xef\xbb\xbf{\n  "api_version": "v2",\n'
                b'  "request_type": "app-started",\n'
                b'  "runtime_id": "runtime-a",\n'
                b'  "application": {},\n  "payload": []\n}\n'
            )
            replacement = (
                b'{"api_version":"v2","request_type":"app-started",'
                b'"runtime_id":"runtime-b","application":{},"payload":[1]}'
            )
            source.write_bytes(original)
            task = _task(source)
            plan = build_telemetry_plan((task,), ())
            transport = _RetryingSourceMutationTransport(source, replacement)

            result = process_file(task, _runtime(root, plan), transport)

            self.assertEqual(FileStatus.SUCCEEDED, result.status)
            self.assertEqual(2, result.requests_attempted)
            self.assertEqual(1, result.retries)
            self.assertEqual((original, original), transport.bodies)
            self.assertEqual(len(original), transport.declared_length)
            self.assertIsNotNone(transport.prepared_path)
            self.assertNotEqual(source, transport.prepared_path)
            self.assertEqual("telemetry_body.json", transport.prepared_path.name)
            self.assertFalse(source.exists())

    def test_message_batch_anchor_is_augmented_by_its_own_worker(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "telemetry.json"
            source.write_text(
                json.dumps(
                    {
                        "api_version": "v2",
                        "request_type": "message-batch",
                        "runtime_id": "runtime-a",
                        "seq_id": 4,
                        "application": {
                            "service_name": "service-a",
                            "language_name": "python",
                            "tracer_version": "2.0.0",
                            "env": "none",
                        },
                        "payload": [
                            {
                                "request_type": "generate-metrics",
                                "payload": {
                                    "series": [{"tags": ["provider:bazel"]}]
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            facts = root / "telemetry_facts.json"
            facts.write_text(
                json.dumps(
                    {
                        "service_name": "service-a",
                        "runtime_name": "python",
                        "env": "ci",
                        "counts": [
                            {
                                "name": "event_created",
                                "value": 2,
                                "tags": ["provider:bazel"],
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )
            task = _task(source)
            plan = build_telemetry_plan(
                (task,),
                (facts,),
                primary_context={"ci.provider.name": "github"},
                clock=lambda: 123.9,
            )
            transport = _Transport(HttpResult(202, 1))

            result = process_file(task, _runtime(root, plan), transport)

            self.assertEqual(FileStatus.SUCCEEDED, result.status)
            self.assertEqual(1, result.requests_planned)
            self.assertTrue(result.source_deleted)
            body = json.loads(transport.calls[0]["body"])
            self.assertEqual("ci", body["application"]["env"])
            self.assertEqual(2, len(body["payload"]))
            self.assertEqual(
                ["provider:bazel/github"],
                body["payload"][0]["payload"]["series"][0]["tags"],
            )
            added = body["payload"][1]["payload"]["series"][0]
            self.assertEqual([[123, 2]], added["points"])
            self.assertEqual(["provider:bazel/github"], added["tags"])
            headers = transport.calls[0]["headers"]
            self.assertEqual("v2", headers["DD-Telemetry-API-Version"])
            self.assertEqual("message-batch", headers["DD-Telemetry-Request-Type"])
            self.assertEqual("runtime-a", headers["DD-Session-ID"])
            self.assertEqual("secret", headers["DD-API-KEY"])

    def test_synthetic_upload_belongs_to_anchor_and_cleanup_is_transactional(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "app-started.json"
            source.write_text(
                json.dumps(
                    {
                        "api_version": "v2",
                        "request_type": "app-started",
                        "runtime_id": "runtime-a",
                        "seq_id": 7,
                        "application": {
                            "service_name": "service-a",
                            "language_name": "go",
                            "tracer_version": "1.0.0",
                        },
                        "host": {"hostname": "builder"},
                        "payload": {},
                    }
                ),
                encoding="utf-8",
            )
            facts = root / "facts.json"
            facts.write_text(
                json.dumps(
                    {
                        "service_name": "service-a",
                        "runtime_name": "go",
                        "distributions": [
                            {"name": "duration", "value": [1, 2], "tags": []}
                        ],
                    }
                ),
                encoding="utf-8",
            )
            task = _task(source)
            plan = build_telemetry_plan((task,), (facts,), clock=lambda: 456)
            transport = _Transport(HttpResult(200, 1), HttpResult(500, 4))

            result = process_file(task, _runtime(root, plan), transport)

            self.assertEqual(FileStatus.FAILED, result.status)
            self.assertEqual(2, result.requests_planned)
            self.assertEqual(5, result.requests_attempted)
            self.assertEqual(1, result.requests_succeeded)
            self.assertEqual(3, result.retries)
            self.assertTrue(source.exists())
            synthetic = json.loads(transport.calls[1]["body"])
            self.assertEqual("message-batch", synthetic["request_type"])
            self.assertEqual(8, synthetic["seq_id"])
            self.assertEqual(456, synthetic["tracer_time"])
            self.assertEqual(
                "message-batch",
                transport.calls[1]["headers"]["DD-Telemetry-Request-Type"],
            )

    def test_dry_run_prepares_source_and_synthetic_without_transport(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            source = root / "telemetry.json"
            source.write_text(
                json.dumps(
                    {
                        "api_version": "v2",
                        "request_type": "app-started",
                        "application": {
                            "service_name": "service-a",
                            "language_name": "ruby",
                        },
                    }
                ),
                encoding="utf-8",
            )
            facts = root / "facts.json"
            facts.write_text(
                json.dumps(
                    {
                        "service_name": "service-a",
                        "counts": [{"name": "created", "value": 1}],
                    }
                ),
                encoding="utf-8",
            )
            task = _task(source)
            plan = build_telemetry_plan((task,), (facts,), clock=lambda: 1)
            transport = _Transport()

            result = process_file(task, _runtime(root, plan, dry_run=True), transport)

            self.assertEqual(FileStatus.SUCCEEDED, result.status)
            self.assertEqual(2, result.requests_planned)
            self.assertEqual(0, result.requests_attempted)
            self.assertEqual([], transport.calls)
            self.assertTrue(source.exists())

    def test_ambiguous_cross_language_facts_are_not_assigned(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            tasks = []
            for language in ("go", "python"):
                source = root / f"{language}.json"
                source.write_text(
                    json.dumps(
                        {
                            "api_version": "v2",
                            "request_type": "app-started",
                            "application": {
                                "service_name": "shared",
                                "language_name": language,
                            },
                        }
                    ),
                    encoding="utf-8",
                )
                tasks.append(_task(source))
            facts = root / "facts.json"
            facts.write_text(
                json.dumps(
                    {
                        "service_name": "shared",
                        "counts": [{"name": "created", "value": 1}],
                    }
                ),
                encoding="utf-8",
            )

            plan = build_telemetry_plan(tasks, (facts,))

            self.assertEqual((), plan.entries)
            self.assertIn("telemetry_facts_language_ambiguous", plan.warning_codes)


if __name__ == "__main__":
    unittest.main()
