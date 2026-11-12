# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Own a bounded cohort of test sources through preparation and acknowledgement.

Only whole small sources share requests. Incompatible, warning-bearing and
large sources keep the ordinary file pipeline. Coverage and telemetry never
enter this worker. Every yielded outcome commits its original source IDs.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from functools import partial
import itertools
from typing import Any, Iterator

from validate_payload_schema import validate_payload as validate_schema_payload
from topt_runtime.bep_execution import test_result_event_count, completed_empty_test_session

from .batching import BatchCompatibilityError, localize_runtime_ids
from .file_worker import (
    WorkerRuntime, WorkerTransport, _cleanup_source, _enrich_and_validate_test, _phase, _skipped,
    _failed, _http_failure, _prepare_test_requests, _read_json_object,
    common_headers, upload_prepared_test,
)
from .json_utils import strict_json_dumps, strict_json_loads
from .metrics import PhaseRecorder
from .models import MAX_TEST_PAYLOAD_BYTES, FileResult, FileStatus, FileTask, PayloadType, RequestOutcome, WorkItemOutcome
from .splitting import PreparedTestChunk, TestPayloadSplitError, compact_json_bytes
from .temporary import TemporaryDirectoryError, task_temporary_directory
from .transport import HttpResult, HttpTransportError, prepare_json_request
from .worker_pool import PreparedWorkItem


_MAX_BATCH_SOURCES = 64


@dataclass(frozen=True)
class _Source:
    task: FileTask
    events: bytes
    event_count: int
    test_events: int
    key: tuple[bytes, bytes]
    envelope: bytes
    headers: dict[str, str]
    warnings: tuple[str, ...]
    empty_test_session: bool = False
    source_bytes: int = 0
    phase_times: tuple[tuple[str, float, float], ...] = ()


def _frame(envelope: bytes) -> tuple[bytes, bytes]:
    return envelope[:-1] + (b"," if envelope != b"{}" else b"") + b'"events":[', b"]}"


@dataclass(frozen=True)
class _OrdinarySource:
    task: FileTask
    payload: dict[str, Any]
    warnings: list[str]
    measurements: PhaseRecorder
    source_bytes: int


def _source_result(result: FileResult, measurements: PhaseRecorder, source_bytes: int) -> FileResult:
    return replace(result, phase_times=(*result.phase_times, *measurements.snapshot()),
        source_bytes=source_bytes,
        prepared_body_bytes=result.prepared_body_bytes + dict(measurements.byte_counts()).get("prepared_body_bytes", 0))


def _prepare_small_source(task: FileTask, runtime: WorkerRuntime, source_bytes: int) -> _Source | _OrdinarySource | FileResult:
    measurements = PhaseRecorder(runtime.clock, runtime.cpu_clock)
    local_runtime = replace(runtime, measurements=measurements)
    with measurements.phase("file_pipeline"):
        try:
            prepared = _prepare_small_source_content(task, local_runtime, measurements, source_bytes)
        except Exception as exc:
            prepared = _failed(task, "unhandled_worker_exception", type(exc).__name__)
    if isinstance(prepared, FileResult):
        return _source_result(prepared, measurements, source_bytes)
    if isinstance(prepared, _Source):
        return replace(prepared, source_bytes=source_bytes, phase_times=measurements.snapshot())
    return prepared


def _prepare_small_source_content(
    task: FileTask, runtime: WorkerRuntime, measurements: PhaseRecorder, source_bytes: int,
) -> _Source | _OrdinarySource | FileResult:
    with measurements.phase("read_parse"):
        payload, read_failure = _read_json_object(task.source_path, "test")
    if read_failure is not None:
        return _failed(task, *read_failure)
    assert payload is not None
    if not isinstance(payload.get("events"), list) or not payload["events"]:
        return _skipped(task, "test_payload_without_events")
    warnings: list[str] = []
    failure, context = _enrich_and_validate_test(task, runtime, payload, warnings)
    if failure is not None:
        return failure
    try:
        with measurements.phase("encoding_split"):
            encoded_size = len(compact_json_bytes(payload))
            ordinary = bool(warnings) or context.values is None or encoded_size > MAX_TEST_PAYLOAD_BYTES
            if not ordinary:
                try:
                    headers = common_headers(runtime, payload)
                    envelope_key = localize_runtime_ids(payload, max_additional_bytes=MAX_TEST_PAYLOAD_BYTES - encoded_size)
                except BatchCompatibilityError:
                    ordinary = True
            if not ordinary:
                events = compact_json_bytes(payload["events"])[1:-1]
                envelope = strict_json_dumps({key: value for key, value in payload.items() if key != "events"},
                    sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                prefix, suffix = _frame(envelope)
                ordinary = len(prefix) + len(events) + len(suffix) > MAX_TEST_PAYLOAD_BYTES
            if ordinary:
                return _OrdinarySource(task, payload, warnings, measurements, source_bytes)
            key = (envelope_key, strict_json_dumps(dict(context.values), sort_keys=True, separators=(",", ":")).encode())
            if len(envelope) + len(events) + len(key[0]) + len(key[1]) > MAX_TEST_PAYLOAD_BYTES:
                return _OrdinarySource(task, payload, warnings, measurements, source_bytes)
            return _Source(task, events, len(payload["events"]), test_result_event_count(payload), key, envelope, headers, tuple(warnings), empty_test_session=completed_empty_test_session(payload))
    except TestPayloadSplitError as exc:
        return replace(_failed(task, exc.code, str(exc)), events=len(payload["events"]),
            test_events=test_result_event_count(payload), warning_codes=tuple(warnings))


def _run_ordinary_source(source: _OrdinarySource, runtime: WorkerRuntime, transport: WorkerTransport) -> FileResult:
    measurements = source.measurements
    local_runtime = replace(runtime, measurements=measurements)
    set_measurements = getattr(transport, "set_measurements", None)
    if callable(set_measurements):
        set_measurements(measurements)
    try:
        with measurements.phase("file_pipeline"):
            try:
                result = _upload_ordinary_prepared(source.task, local_runtime, transport, source.payload, source.warnings)
            except Exception as exc:
                result = replace(_failed(source.task, "unhandled_worker_exception", type(exc).__name__),
                    warning_codes=tuple(source.warnings))
        return _source_result(result, measurements, source.source_bytes)
    finally:
        if callable(set_measurements):
            set_measurements(None)


def prepare_test_work_items(
    tasks: tuple[FileTask, ...], runtime: WorkerRuntime,
) -> Iterator[PreparedWorkItem[WorkerRuntime, WorkerTransport]]:
    """Stream compatible requests and independent fallbacks into the existing pool.

    Only this producer owns the pending accumulator. The bounded worker queue
    transfers prepared buffers without retaining the whole invocation in memory.
    """
    if runtime.batch_schema is None:
        for task in tasks:
            yield PreparedWorkItem((task,))
        return
    pending: list[_Source] = []
    body_size = 0
    retained_size = 0
    for task in tasks:
        if task.payload_type is not PayloadType.TEST:
            yield PreparedWorkItem((task,))
            continue
        try:
            source_bytes = task.source_path.stat().st_size
        except OSError as exc:
            result = _failed(task, "file_pipeline_io_failed", type(exc).__name__)
            yield PreparedWorkItem((task,), partial(_process_prepared, result))
            continue
        if (task.source_path.suffix.lower() != ".json"
            or (runtime.filter_prefix and not task.source_path.name.startswith("span_events_"))
            or source_bytes > MAX_TEST_PAYLOAD_BYTES):
            if pending:
                yield _batch_work_item(tuple(pending))
                pending.clear()
            body_size = retained_size = 0
            yield PreparedWorkItem((task,))
            continue
        prepared = _prepare_small_source(task, runtime, source_bytes)
        if isinstance(prepared, FileResult):
            yield PreparedWorkItem((task,), partial(_process_prepared, prepared))
            continue
        if isinstance(prepared, _OrdinarySource):
            if pending:
                yield _batch_work_item(tuple(pending))
                pending.clear()
            body_size = retained_size = 0
            yield PreparedWorkItem((task,), partial(_process_prepared, prepared))
            continue
        prefix, suffix = _frame(prepared.envelope)
        single_size = len(prefix) + len(prepared.events) + len(suffix)
        source_size = len(prepared.envelope) + len(prepared.events) + len(prepared.key[0]) + len(prepared.key[1])
        if pending and (pending[0].key != prepared.key
            or len(pending) == _MAX_BATCH_SOURCES
            or body_size + 1 + len(prepared.events) > MAX_TEST_PAYLOAD_BYTES
            or retained_size + source_size > MAX_TEST_PAYLOAD_BYTES):
            yield _batch_work_item(tuple(pending))
            pending.clear()
            body_size = retained_size = 0
        body_size = body_size + 1 + len(prepared.events) if pending else single_size
        retained_size += source_size
        pending.append(prepared)
    if pending:
        yield _batch_work_item(tuple(pending))


def _batch_work_item(sources: tuple[_Source, ...]) -> PreparedWorkItem[WorkerRuntime, WorkerTransport]:
    return PreparedWorkItem(tuple(source.task for source in sources), partial(_process_prepared, sources))


def _process_prepared(
    prepared: tuple[_Source, ...] | _OrdinarySource | FileResult,
    runtime: WorkerRuntime, transport: WorkerTransport,
) -> Iterator[WorkItemOutcome]:
    if isinstance(prepared, FileResult):
        yield WorkItemOutcome((prepared,))
    elif isinstance(prepared, _OrdinarySource):
        yield WorkItemOutcome((_run_ordinary_source(prepared, runtime, transport),))
    else:
        task_id = prepared[0].task.task_id
        yield from _upload_batch(prepared, runtime, transport, f"{len(task_id)}:{task_id}", itertools.count())


def _upload_ordinary_prepared(
    task: FileTask, runtime: WorkerRuntime, transport: WorkerTransport,
    payload: dict[str, Any], warnings: list[str],
) -> FileResult:
    """Keep ordinary preparation errors scoped to the owning source."""
    cleanup_errors: list[str] = []
    try:
        with task_temporary_directory(runtime.invocation_temp_root, task.task_id, on_cleanup_error=cleanup_errors.append) as temporary:
            result = upload_prepared_test(task, runtime, transport, temporary, payload, warnings)
    except HttpTransportError as exc:
        result = _failed(task, "request_preparation_failed", type(exc).__name__)
    except (OSError, TemporaryDirectoryError) as exc:
        result = _failed(task, "file_pipeline_io_failed", type(exc).__name__)
    result = replace(result, warning_codes=tuple(dict.fromkeys((*warnings, *result.warning_codes))))
    if cleanup_errors:
        result = replace(result, warning_codes=tuple(dict.fromkeys((*result.warning_codes, "task_temp_cleanup_failed"))))
    return result


def _upload_batch(
    sources: tuple[_Source, ...], runtime: WorkerRuntime, transport: WorkerTransport,
    cohort_id: str, sequence: Iterator[int],
) -> Iterator[WorkItemOutcome]:
    request_id = f"{cohort_id}:{next(sequence)}"
    outcome, response = _send_once(sources, runtime, transport, request_id)
    if len(sources) > 1 and response is not None and response.status_code in {400, 413, 422} and response.transport_error is None:
        # No new retry pool or re-enrichment: one source-boundary pass isolates
        # a payload rejection. Authentication/transport/server errors never fan
        # out. Intake admission for these rejections must be checked for rollout.
        yield WorkItemOutcome(requests=outcome.requests)
        batch_warnings = {result.task_id: result.warning_codes for result in outcome.results}
        for source in sources:
            single_id = f"{cohort_id}:{next(sequence)}"
            single, _response = _send_once((source,), runtime, transport, single_id)
            results = tuple(replace(result,
                request_ids=(request_id, *result.request_ids),
                requests_planned=result.requests_planned + 1,
                requests_attempted=result.requests_attempted + response.attempts,
                requests_failed=result.requests_failed + 1,
                retries=result.retries + response.retries,
                warning_codes=tuple(dict.fromkeys((*batch_warnings[result.task_id], *result.warning_codes, "batch_rejected_then_source_fallback"))))
                for result in single.results)
            yield WorkItemOutcome(results, single.requests)
        return
    yield outcome


def _send_once(
    sources: tuple[_Source, ...], runtime: WorkerRuntime, transport: WorkerTransport, request_id: str,
) -> tuple[WorkItemOutcome, HttpResult | None]:
    measurements = PhaseRecorder(runtime.clock, runtime.cpu_clock)
    local_runtime = replace(runtime, measurements=measurements)
    set_measurements = getattr(transport, "set_measurements", None)
    if callable(set_measurements):
        set_measurements(measurements)
    cleanup_errors: list[str] = []
    try:
        with measurements.phase("batch_request"):
            try:
                outcome, response = _prepare_and_send(sources, local_runtime, transport, request_id, cleanup_errors)
            except HttpTransportError as exc:
                code, message = "request_preparation_failed", type(exc).__name__
                outcome, response = WorkItemOutcome(tuple(_failed(source.task, code, message) for source in sources)), None
            except (OSError, TemporaryDirectoryError) as exc:
                code, message = "file_pipeline_io_failed", type(exc).__name__
                outcome, response = WorkItemOutcome(tuple(_failed(source.task, code, message) for source in sources)), None
            except Exception as exc:
                code, message = "unhandled_worker_exception", type(exc).__name__
                outcome, response = WorkItemOutcome(tuple(_failed(source.task, code, message) for source in sources)), None
    finally:
        if callable(set_measurements):
            set_measurements(None)
    phase_times = measurements.snapshot()
    prepared_bytes = dict(measurements.byte_counts()).get("prepared_body_bytes", 0)
    source_by_id = {source.task.task_id: source for source in sources}
    results = []
    for index, result in enumerate(outcome.results):
        source = source_by_id[result.task_id]
        results.append(replace(result, phase_times=source.phase_times + (phase_times if not outcome.requests and index == 0 else ()),
            source_bytes=source.source_bytes, prepared_body_bytes=prepared_bytes if not outcome.requests and index == 0 else 0,
            warning_codes=tuple(dict.fromkeys((*source.warnings, *result.warning_codes,
                *(("task_temp_cleanup_failed",) if cleanup_errors else ()))))))
    requests = tuple(replace(request, phase_times=phase_times, prepared_body_bytes=prepared_bytes) for request in outcome.requests)
    return WorkItemOutcome(tuple(results), requests), response


def _prepare_and_send(
    sources: tuple[_Source, ...], runtime: WorkerRuntime, transport: WorkerTransport, request_id: str,
    cleanup_errors: list[str],
) -> tuple[WorkItemOutcome, HttpResult | None]:
    with _phase(runtime, "encoding_split"):
        prefix, suffix = _frame(sources[0].envelope)
        body = prefix + b",".join(source.events for source in sources) + suffix
        if len(body) > MAX_TEST_PAYLOAD_BYTES:
            raise ValueError("batch exceeded the uncompressed request guard")
    with _phase(runtime, "validation"):
        document = strict_json_loads(body)
        assert runtime.batch_schema is not None
        if not validate_schema_payload(document, runtime.batch_schema).valid:
            return WorkItemOutcome(tuple(_failed(source.task, "invalid_batch_representation", "outbound batch failed schema validation") for source in sources)), None
        del document
    warnings: list[str] = []
    response = None
    with task_temporary_directory(runtime.invocation_temp_root, sources[0].task.task_id, on_cleanup_error=cleanup_errors.append) as temporary:
        path = temporary / "test_chunk_0001.json"
        with _phase(runtime, "request_encoding"):
            path.write_bytes(body)
            del body
            chunk = PreparedTestChunk(1, path, path.stat().st_size, 0, sum(source.event_count for source in sources))
            prepared = _prepare_test_requests(sources[0].task, runtime, (chunk,), temporary, warnings)[0]
        headers = dict(sources[0].headers)
        if not runtime.endpoints.agentless:
            headers["X-Datadog-EVP-Subdomain"] = "citestcycle-intake"
        if runtime.dry_run:
            with _phase(runtime, "request_encoding_transport"):
                request = prepare_json_request(runtime.endpoints.test_url, headers, prepared.body, content_encoding=prepared.content_encoding)
            assert runtime.measurements is not None
            runtime.measurements.add_bytes("prepared_body_bytes", int(request.headers["Content-Length"]))
        else:
            with _phase(runtime, "delivery"):
                response = transport.post_json(runtime.endpoints.test_url, headers, prepared.body, content_encoding=prepared.content_encoding)
        success = response is None or response.succeeded
        failure = _http_failure(response, payload_type=PayloadType.TEST, payload_limit_context=f"sources={len(sources)} bytes={chunk.size_bytes}") if not success else None
        results = []
        for source in sources:
            with _phase(runtime, "source_cleanup"):
                deleted, cleanup_warning = _cleanup_source(source.task.source_path, runtime.keep_payloads) if success and not runtime.dry_run else (False, None)
            results.append(FileResult(source.task.task_id, source.task.display_path, PayloadType.TEST,
                FileStatus.SUCCEEDED if success else FileStatus.FAILED, events=source.event_count, test_events=source.test_events, empty_test_session=source.empty_test_session,
                chunks_created=1, chunks_uploaded=int(response is not None and success), chunks_failed=int(not success),
                requests_planned=1, requests_attempted=response.attempts if response else 0,
                requests_succeeded=int(response is not None and success), requests_failed=int(not success),
                retries=response.retries if response else 0, source_deleted=deleted,
                warning_codes=tuple(dict.fromkeys((*source.warnings, *warnings, *((cleanup_warning,) if cleanup_warning else ())))),
                failure_code=failure[0] if failure else None, failure_message=failure[1] if failure else None,
                request_ids=(request_id,)))
    request = RequestOutcome(request_id, tuple(source.task.task_id for source in sources), response.attempts if response else 0, response.succeeded if response else None)
    return WorkItemOutcome(tuple(results), (request,)), response
