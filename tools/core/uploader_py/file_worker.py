# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Run the complete isolated pipeline for one uploader source file.

One worker owns enrichment through cleanup so files need no cross-worker sync.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field, replace
import gzip
import json
import logging
from pathlib import Path
import stat
import tempfile
from typing import Any, Mapping, Protocol

from validate_payload_schema import validate_payload as validate_schema_payload

from .codeowners import CodeOwnersMatch, CodeOwnersMatcher
from .endpoints import EndpointSet
from .enrichment import ContextPlan, enrich_test_payload, payload_repo_key
from .json_utils import strict_json_dumps, strict_json_loads
from .models import (
    MAX_TEST_PAYLOAD_BYTES,
    FileResult,
    FileStatus,
    FileTask,
    PayloadType,
)
from .splitting import (
    PreparedTestChunk,
    TestPayloadSplitError,
    compact_json_bytes,
    prepare_test_chunks,
)
from .telemetry import TelemetryDirective, TelemetryPlan
from .temporary import task_temporary_directory
from .transport import (
    HttpResult,
    HttpTransportError,
    PreparedMultipartBody,
    prepare_coverage_multipart,
    prepare_json_request,
    prepare_spooled_multipart_request,
)


DEFAULT_HEADER_LANGUAGE = "bazel-starlark"
DEFAULT_HEADER_LANGUAGE_VERSION = "n/a"
DEFAULT_HEADER_LANGUAGE_INTERPRETER = "bazel-run"
_COVERAGE_EVENT_BODY = b'{"dummy":true}'


class WorkerTransport(Protocol):
    """Subset of the worker-local transport used by file processors."""

    def post_json(
        self,
        url: str,
        headers: Mapping[str, str],
        body: bytes | Path,
        *,
        gzip_body: bool = False,
        content_encoding: str | None = None,
    ) -> HttpResult: ...

    def post_prepared_multipart(
        self,
        url: str,
        headers: Mapping[str, str],
        prepared: PreparedMultipartBody,
    ) -> HttpResult: ...


@dataclass(frozen=True)
class WorkerRuntime:
    """Invocation-wide read-only state shared by independent file workers."""

    endpoints: EndpointSet
    invocation_temp_root: Path
    context_plan: ContextPlan
    codeowners_matcher: CodeOwnersMatcher
    runtime_id: str
    rules_version: str
    uploader_version: str
    api_key: str = field(default="", repr=False)
    schema: dict[str, Any] | None = field(default=None, repr=False, compare=False)
    dry_run: bool = False
    validate_enrichment: bool = False
    expected_enriched_tags: tuple[str, ...] = ()
    gzip_payloads: bool = False
    keep_payloads: bool = False
    filter_prefix: bool = False
    telemetry_session_id: str = ""
    telemetry_plan: TelemetryPlan = field(default_factory=TelemetryPlan)
    logger: logging.Logger | None = field(default=None, repr=False, compare=False)


@dataclass(frozen=True)
class _TestRequest:
    """One bounded test chunk and its exact outbound representation."""

    chunk: PreparedTestChunk
    body: Path
    content_encoding: str | None = None


@dataclass(frozen=True)
class _TelemetryRequest:
    """One telemetry body paired with the headers derived from that body."""

    body: Path
    headers: dict[str, str]


def common_headers(
    runtime: WorkerRuntime,
    payload: Mapping[str, Any] | None = None,
) -> dict[str, str]:
    """Build legacy-compatible Datadog headers from an enriched test body."""
    language = DEFAULT_HEADER_LANGUAGE
    language_version = DEFAULT_HEADER_LANGUAGE_VERSION
    language_interpreter = DEFAULT_HEADER_LANGUAGE_INTERPRETER
    tracer_version = runtime.uploader_version

    if payload is not None:
        metadata = payload.get("metadata")
        global_metadata = metadata.get("*") if isinstance(metadata, dict) else None
        if isinstance(global_metadata, dict):
            language = _nonempty_string(global_metadata.get("language")) or language
            tracer_version = (
                _nonempty_string(global_metadata.get("library_version"))
                or tracer_version
            )
            language_version = (
                _nonempty_string(global_metadata.get("language_version"))
                or _nonempty_string(global_metadata.get("runtime_version"))
                or language_version
            )
            language_interpreter = (
                _nonempty_string(global_metadata.get("language_interpreter"))
                or _nonempty_string(global_metadata.get("runtime_name"))
                or language_interpreter
            )

    headers = {
        "Datadog-Meta-Lang": language,
        "Datadog-Meta-Lang-Version": language_version,
        "Datadog-Meta-Lang-Interpreter": language_interpreter,
        "Datadog-Meta-Tracer-Version": tracer_version,
        "Accept": "application/json",
    }
    if runtime.endpoints.agentless:
        headers["DD-API-KEY"] = runtime.api_key
    return headers


def process_file(
    task: FileTask,
    runtime: WorkerRuntime,
    transport: WorkerTransport,
) -> FileResult:
    """Attach task-scoped transport diagnostics around one complete pipeline."""
    set_log_context = getattr(transport, "set_log_context", None)
    clear_log_context = getattr(transport, "clear_log_context", None)
    if callable(set_log_context):
        set_log_context(
            task.task_id,
            task.payload_type.value,
            task.display_path,
        )
    try:
        return _process_file_with_context(task, runtime, transport)
    finally:
        if callable(clear_log_context):
            clear_log_context()


def _process_file_with_context(
    task: FileTask,
    runtime: WorkerRuntime,
    transport: WorkerTransport,
) -> FileResult:
    """Run one file's entire protocol without coordinating with other files."""
    _debug(runtime, task, "started complete file pipeline")
    if _debug_enabled(runtime):
        try:
            _debug(runtime, task, f"source_bytes={task.source_path.stat().st_size}")
        except OSError as exc:
            _debug(runtime, task, f"source size unavailable: {type(exc).__name__}")
    temporary_cleanup_errors: list[str] = []
    try:
        with task_temporary_directory(
            runtime.invocation_temp_root,
            task.task_id,
            on_cleanup_error=temporary_cleanup_errors.append,
        ) as task_directory:
            _debug(runtime, task, f"task temporary directory created: {task_directory}")
            result = _dispatch_file(
                task,
                runtime,
                transport,
                task_directory,
            )
    except HttpTransportError as exc:
        _debug(runtime, task, "transport rejected a locally prepared request")
        result = _failed(
            task,
            "request_preparation_failed",
            type(exc).__name__,
        )
    except OSError as exc:
        _debug(runtime, task, f"file pipeline failed with {type(exc).__name__}")
        result = _failed(task, "file_pipeline_io_failed", type(exc).__name__)

    if temporary_cleanup_errors:
        if runtime.logger is not None:
            runtime.logger.warning(
                "task=%s type=%s file=%s task temporary cleanup failed: %s",
                task.task_id,
                task.payload_type.value,
                task.display_path,
                temporary_cleanup_errors[0],
            )
        result = replace(
            result,
            warning_codes=tuple(
                dict.fromkeys(result.warning_codes + ("task_temp_cleanup_failed",))
            ),
        )
    else:
        _debug(runtime, task, "task temporary cleanup completed")
    return result


def _dispatch_file(
    task: FileTask,
    runtime: WorkerRuntime,
    transport: WorkerTransport,
    task_directory: Path,
) -> FileResult:
    if task.payload_type is PayloadType.TEST:
        return _process_test(task, runtime, transport, task_directory)
    if task.payload_type is PayloadType.COVERAGE:
        return _process_coverage(task, runtime, transport, task_directory)
    if task.payload_type is PayloadType.TELEMETRY:
        return _process_telemetry(task, runtime, transport, task_directory)
    return _failed(task, "unsupported_payload_type", str(task.payload_type))


def _process_test(
    task: FileTask,
    runtime: WorkerRuntime,
    transport: WorkerTransport,
    task_directory: Path,
) -> FileResult:
    if task.source_path.suffix.lower() != ".json":
        return _failed(
            task,
            "unsupported_test_payload_format",
            "test payloads must be JSON",
        )
    if runtime.filter_prefix and not task.source_path.name.startswith("span_events_"):
        return _skipped(task, "prefix_filter")

    payload, read_failure = _read_json_object(task.source_path, "test")
    if read_failure is not None:
        return _failed(task, *read_failure)
    assert payload is not None
    events = payload.get("events")
    if not isinstance(events, list) or not events:
        return _skipped(task, "test_payload_without_events")

    warnings: list[str] = []
    failure = _enrich_and_validate_test(task, runtime, payload, warnings)
    if failure is not None:
        return failure

    try:
        chunks = prepare_test_chunks(payload, task_directory)
    except TestPayloadSplitError as exc:
        return FileResult(
            task_id=task.task_id,
            source_path=task.display_path,
            payload_type=task.payload_type,
            status=FileStatus.FAILED,
            events=_event_count(payload),
            warning_codes=_unique_codes(warnings),
            failure_code=exc.code,
            failure_message=str(exc),
        )
    requests = _prepare_test_requests(
        task,
        runtime,
        chunks,
        task_directory,
        warnings,
    )

    test_result_fields = dict(
        task_id=task.task_id,
        source_path=task.display_path,
        payload_type=task.payload_type,
        events=_event_count(payload),
        chunks_created=len(requests),
        requests_planned=len(requests),
    )
    headers = common_headers(runtime, payload)
    if not runtime.endpoints.agentless:
        headers["X-Datadog-EVP-Subdomain"] = "citestcycle-intake"
    if runtime.dry_run:
        for request in requests:
            prepare_json_request(
                runtime.endpoints.test_url,
                headers,
                request.body,
                content_encoding=request.content_encoding,
            )
        _debug(runtime, task, "dry-run completed without network or source cleanup")
        return FileResult(
            status=FileStatus.SUCCEEDED,
            warning_codes=_unique_codes(warnings),
            **test_result_fields,
        )

    requests_attempted = 0
    requests_succeeded = 0
    requests_failed = 0
    retries = 0
    failed_chunks: list[PreparedTestChunk] = []
    first_failure: tuple[str, str] | None = None
    for request in requests:
        chunk = request.chunk
        _debug(
            runtime,
            task,
            f"uploading test chunk {chunk.index}/{len(requests)} "
            f"({chunk.size_bytes} bytes)",
        )
        http_result = transport.post_json(
            runtime.endpoints.test_url,
            headers,
            request.body,
            content_encoding=request.content_encoding,
        )
        requests_attempted += http_result.attempts
        retries += http_result.retries
        _debug(
            runtime,
            task,
            f"test chunk {chunk.index} completed after "
            f"{http_result.attempts} attempt(s)",
        )
        if not http_result.succeeded:
            failure_code, failure_message = _http_failure(
                http_result,
                payload_type=task.payload_type,
                payload_limit_context=(
                    f"chunk={chunk.index}/{len(requests)} "
                    f"uncompressed_bytes={chunk.size_bytes} "
                    f"outbound_bytes={request.body.stat().st_size} "
                    f"threshold_bytes={MAX_TEST_PAYLOAD_BYTES}"
                ),
            )
            requests_failed += 1
            failed_chunks.append(chunk)
            if first_failure is None:
                first_failure = (failure_code, failure_message)
            continue
        requests_succeeded += 1

    if first_failure is not None:
        if requests_succeeded and not runtime.keep_payloads:
            persisted = _persist_failed_test_chunks(
                task.source_path,
                payload,
                failed_chunks,
            )
            if persisted:
                if runtime.logger is not None:
                    runtime.logger.info(
                        "task=%s type=%s file=%s retained %d failed test "
                        "chunk(s) for retry",
                        task.task_id,
                        task.payload_type.value,
                        task.display_path,
                        requests_failed,
                    )
            else:
                warnings.append("failed_test_chunks_persist_failed")
                if runtime.logger is not None:
                    runtime.logger.warning(
                        "task=%s type=%s file=%s failed to retain rejected test "
                        "chunks; keeping the original source",
                        task.task_id,
                        task.payload_type.value,
                        task.display_path,
                    )
        return FileResult(
            status=FileStatus.FAILED,
            chunks_uploaded=requests_succeeded,
            chunks_failed=requests_failed,
            requests_attempted=requests_attempted,
            requests_succeeded=requests_succeeded,
            requests_failed=requests_failed,
            retries=retries,
            warning_codes=_unique_codes(warnings),
            failure_code=first_failure[0],
            failure_message=first_failure[1],
            **test_result_fields,
        )

    deleted, cleanup_warning = _cleanup_source(task.source_path, runtime.keep_payloads)
    _debug(runtime, task, f"test cleanup completed source_deleted={deleted}")
    final_warnings = list(warnings)
    if cleanup_warning:
        final_warnings.append(cleanup_warning)
    return FileResult(
        status=FileStatus.SUCCEEDED,
        chunks_uploaded=len(requests),
        requests_attempted=requests_attempted,
        requests_succeeded=requests_succeeded,
        retries=retries,
        source_deleted=deleted,
        warning_codes=_unique_codes(final_warnings),
        **test_result_fields,
    )


def _enrich_and_validate_test(
    task: FileTask,
    runtime: WorkerRuntime,
    payload: dict[str, Any],
    warnings: list[str],
) -> FileResult | None:
    """Enrich one mutable test payload and validate its prepared shape."""
    bazel_metadata, sidecar_warning = _load_bazel_metadata(task)
    if sidecar_warning:
        warnings.append(sidecar_warning)
    repo_key = payload_repo_key(bazel_metadata)
    context_selection = runtime.context_plan.select(repo_key)
    if sidecar_warning:
        sidecar_state = "invalid"
    elif bazel_metadata is not None:
        sidecar_state = "loaded"
    else:
        sidecar_state = "absent"
    _debug(
        runtime,
        task,
        "Bazel sidecar=%s context_repo=%s context_selected=%s context_warning=%s"
        % (
            sidecar_state,
            repr(repo_key[:256]) if repo_key is not None else "none",
            "yes" if context_selection.values is not None else "no",
            context_selection.warning_code or "none",
        ),
    )
    codeowners_cache: dict[str, CodeOwnersMatch] = {}
    try:
        enrichment = enrich_test_payload(
            payload,
            context_selection=context_selection,
            bazel_metadata=bazel_metadata,
            runtime_id=runtime.runtime_id,
            rules_version=runtime.rules_version,
            codeowners_matcher=runtime.codeowners_matcher,
            codeowners_cache=codeowners_cache,
        )
    except (TypeError, ValueError, OSError) as exc:
        _debug(runtime, task, f"enrichment failed with {type(exc).__name__}")
        return _failed(task, "test_enrichment_failed", type(exc).__name__)

    warnings.extend(enrichment.warning_codes)
    _debug(
        runtime,
        task,
        "enrichment completed events=%d codeowners_scanned=%d enriched=%d "
        "existing=%d missing_source=%d unmatched=%d errors=%d"
        % (
            _event_count(payload),
            enrichment.codeowners.scanned,
            enrichment.codeowners.enriched,
            enrichment.codeowners.skipped_existing,
            enrichment.codeowners.skipped_missing_source,
            enrichment.codeowners.skipped_unmatched,
            enrichment.codeowners.skipped_errors,
        ),
    )
    if _debug_enabled(runtime):
        for source_path, match in codeowners_cache.items():
            _debug(
                runtime,
                task,
                "CODEOWNERS source=%r candidate=%r matched=%s owner_count=%d"
                % (
                    source_path[:256],
                    match.candidate[:256] if match.candidate is not None else None,
                    match.matched,
                    len(match.owners),
                ),
            )
        try:
            enriched_bytes = len(compact_json_bytes(payload))
        except TestPayloadSplitError as exc:
            _debug(runtime, task, f"enriched_bytes unavailable: {exc.code}")
        else:
            _debug(runtime, task, f"enriched_bytes={enriched_bytes}")

    if runtime.schema is not None:
        try:
            validation = validate_schema_payload(payload, runtime.schema)
        except (TypeError, ValueError, KeyError) as exc:
            warnings.append("schema_validation_internal_error")
            _debug(runtime, task, f"schema validation failed with {type(exc).__name__}")
        else:
            if not validation.valid:
                warnings.append("schema_validation_failed")
                _debug(
                    runtime,
                    task,
                    f"schema validation reported {len(validation.errors)} error(s)",
                )
            if validation.warnings:
                warnings.append("schema_validation_warning")
    _debug(runtime, task, "warning-only schema validation completed")

    if runtime.validate_enrichment:
        missing_tags = _missing_enriched_tags(payload, runtime.expected_enriched_tags)
        if missing_tags:
            return FileResult(
                task_id=task.task_id,
                source_path=task.display_path,
                payload_type=task.payload_type,
                status=FileStatus.FAILED,
                events=_event_count(payload),
                warning_codes=_unique_codes(warnings),
                failure_code="enrichment_tags_missing",
                failure_message=",".join(missing_tags),
            )
        _debug(runtime, task, "expected enrichment tags validated")
    return None


def _prepare_test_requests(
    task: FileTask,
    runtime: WorkerRuntime,
    chunks: tuple[PreparedTestChunk, ...],
    task_directory: Path,
    warnings: list[str],
) -> tuple[_TestRequest, ...]:
    """Choose JSON or deterministic gzip for every pre-split request body."""
    _debug(
        runtime,
        task,
        f"split threshold_bytes={MAX_TEST_PAYLOAD_BYTES} chunks={len(chunks)}",
    )
    for chunk in chunks:
        _debug(
            runtime,
            task,
            f"chunk={chunk.index}/{len(chunks)} bytes={chunk.size_bytes} "
            f"events={chunk.event_count}",
        )

    requests: list[_TestRequest] = []
    for chunk in chunks:
        if not runtime.gzip_payloads:
            requests.append(_TestRequest(chunk, chunk.path))
            continue
        gzip_path = task_directory / f"test_chunk_{chunk.index:04d}.json.gz"
        try:
            gzip_path.write_bytes(gzip.compress(chunk.path.read_bytes(), mtime=0))
        except OSError as exc:
            warnings.append("gzip_preparation_failed")
            requests.append(_TestRequest(chunk, chunk.path))
            _debug(
                runtime,
                task,
                f"gzip preparation failed with {type(exc).__name__}; using JSON",
            )
        else:
            requests.append(_TestRequest(chunk, gzip_path, "gzip"))

    if runtime.gzip_payloads:
        compressed = sum(request.content_encoding == "gzip" for request in requests)
        _debug(
            runtime,
            task,
            "gzip preparation completed compressed=%d fallback_json=%d"
            % (compressed, len(requests) - compressed),
        )
    return tuple(requests)


def _process_coverage(
    task: FileTask,
    runtime: WorkerRuntime,
    transport: WorkerTransport,
    task_directory: Path,
) -> FileResult:
    suffix = task.source_path.suffix.lower()
    if suffix not in {".json", ".msgpack"}:
        return _failed(
            task,
            "unsupported_coverage_payload_format",
            "coverage payloads must be JSON or msgpack",
        )
    if runtime.filter_prefix and not task.source_path.name.startswith("coverage_"):
        return _skipped(task, "prefix_filter")
    try:
        with task.source_path.open("rb") as handle:
            handle.read(1)
    except OSError as exc:
        return _failed(task, "coverage_payload_read_failed", type(exc).__name__)

    coverage_result_fields = dict(
        task_id=task.task_id,
        source_path=task.display_path,
        payload_type=task.payload_type,
        requests_planned=1,
    )
    coverage_filename = (
        "filecoveragex.msgpack" if suffix == ".msgpack" else "filecoveragex.json"
    )
    coverage_content_type = (
        "application/msgpack" if suffix == ".msgpack" else "application/json"
    )
    prepared = prepare_coverage_multipart(
        task_directory / "coverage_multipart.body",
        event_body=_COVERAGE_EVENT_BODY,
        coverage_path=task.source_path,
        coverage_filename=coverage_filename,
        coverage_content_type=coverage_content_type,
    )
    _debug(
        runtime,
        task,
        f"prepared coverage multipart bytes={prepared.content_length} "
        f"content_type={coverage_content_type}",
    )
    headers = common_headers(runtime)
    if not runtime.endpoints.agentless:
        headers["X-Datadog-EVP-Subdomain"] = "citestcov-intake"
    if runtime.dry_run:
        prepare_spooled_multipart_request(
            runtime.endpoints.coverage_url,
            headers,
            prepared,
        )
        _debug(
            runtime,
            task,
            f"dry-run prepared {prepared.content_length}-byte coverage multipart body",
        )
        return FileResult(status=FileStatus.SUCCEEDED, **coverage_result_fields)

    http_result = transport.post_prepared_multipart(
        runtime.endpoints.coverage_url,
        headers,
        prepared,
    )
    _debug(
        runtime,
        task,
        f"coverage request completed after {http_result.attempts} attempt(s)",
    )
    if not http_result.succeeded:
        failure_code, failure_message = _http_failure(
            http_result,
            payload_type=task.payload_type,
        )
        return FileResult(
            status=FileStatus.FAILED,
            requests_attempted=http_result.attempts,
            requests_failed=1,
            retries=http_result.retries,
            failure_code=failure_code,
            failure_message=failure_message,
            **coverage_result_fields,
        )

    deleted, cleanup_warning = _cleanup_source(task.source_path, runtime.keep_payloads)
    _debug(runtime, task, f"coverage cleanup completed source_deleted={deleted}")
    return FileResult(
        status=FileStatus.SUCCEEDED,
        requests_attempted=http_result.attempts,
        requests_succeeded=1,
        retries=http_result.retries,
        source_deleted=deleted,
        warning_codes=(cleanup_warning,) if cleanup_warning else (),
        **coverage_result_fields,
    )


def _process_telemetry(
    task: FileTask,
    runtime: WorkerRuntime,
    transport: WorkerTransport,
    task_directory: Path,
) -> FileResult:
    if task.source_path.suffix.lower() != ".json":
        return _failed(
            task,
            "unsupported_telemetry_payload_format",
            "telemetry payloads must be JSON",
        )
    payload, source_bytes, read_failure = _read_json_object_with_raw(
        task.source_path,
        "telemetry",
    )
    if read_failure is not None:
        return _failed(task, *read_failure)
    assert payload is not None
    assert source_bytes is not None

    directive = runtime.telemetry_plan.directive_for(task.source_path)
    warnings: list[str] = []
    source_body = _prepare_telemetry_source(
        source_bytes,
        payload,
        directive,
        runtime.telemetry_plan.provider_suffix,
        task_directory,
        warnings,
    )
    metadata_failure = _telemetry_metadata_failure(payload)
    if metadata_failure is not None:
        return FileResult(
            task_id=task.task_id,
            source_path=task.display_path,
            payload_type=task.payload_type,
            status=FileStatus.FAILED,
            warning_codes=_unique_codes(warnings),
            failure_code="invalid_telemetry_metadata",
            failure_message=metadata_failure,
        )

    requests: list[_TelemetryRequest] = [
        _TelemetryRequest(source_body, _telemetry_headers(runtime, payload))
    ]
    if directive.create_synthetic:
        synthetic = _build_synthetic_telemetry(payload, directive, warnings)
        if synthetic is not None:
            _rewrite_telemetry_provider_tags(
                synthetic,
                runtime.telemetry_plan.provider_suffix,
            )
            synthetic_path = task_directory / "telemetry_synthetic.json"
            synthetic_path.write_bytes(_compact_json_line(synthetic))
            requests.append(
                _TelemetryRequest(synthetic_path, _telemetry_headers(runtime, synthetic))
            )
    _debug(runtime, task, f"prepared {len(requests)} telemetry request(s)")
    if _debug_enabled(runtime):
        for index, request in enumerate(requests, start=1):
            try:
                body_bytes = request.body.stat().st_size
            except OSError as exc:
                _debug(
                    runtime,
                    task,
                    f"telemetry request={index}/{len(requests)} size unavailable: "
                    f"{type(exc).__name__}",
                )
            else:
                _debug(
                    runtime,
                    task,
                    f"telemetry request={index}/{len(requests)} bytes={body_bytes}",
                )

    telemetry_result_fields = dict(
        task_id=task.task_id,
        source_path=task.display_path,
        payload_type=task.payload_type,
        requests_planned=len(requests),
    )
    if runtime.dry_run:
        for request in requests:
            prepare_json_request(
                runtime.endpoints.telemetry_url,
                request.headers,
                request.body,
            )
        _debug(runtime, task, "dry-run completed telemetry preparation without network")
        return FileResult(
            status=FileStatus.SUCCEEDED,
            warning_codes=_unique_codes(warnings),
            **telemetry_result_fields,
        )

    requests_attempted = 0
    requests_succeeded = 0
    retries = 0
    for request in requests:
        http_result = transport.post_json(
            runtime.endpoints.telemetry_url,
            request.headers,
            request.body,
        )
        requests_attempted += http_result.attempts
        retries += http_result.retries
        _debug(
            runtime,
            task,
            "telemetry request completed after "
            f"{http_result.attempts} attempt(s)",
        )
        if not http_result.succeeded:
            failure_code, failure_message = _http_failure(
                http_result,
                payload_type=task.payload_type,
            )
            return FileResult(
                status=FileStatus.FAILED,
                requests_attempted=requests_attempted,
                requests_succeeded=requests_succeeded,
                requests_failed=1,
                retries=retries,
                warning_codes=_unique_codes(warnings),
                failure_code=failure_code,
                failure_message=failure_message,
                **telemetry_result_fields,
            )
        requests_succeeded += 1

    deleted, cleanup_warning = _cleanup_source(task.source_path, runtime.keep_payloads)
    _debug(runtime, task, f"telemetry cleanup completed source_deleted={deleted}")
    if cleanup_warning:
        warnings.append(cleanup_warning)
    return FileResult(
        status=FileStatus.SUCCEEDED,
        requests_attempted=requests_attempted,
        requests_succeeded=requests_succeeded,
        retries=retries,
        source_deleted=deleted,
        warning_codes=_unique_codes(warnings),
        **telemetry_result_fields,
    )


def _prepare_telemetry_source(
    source_bytes: bytes,
    payload: dict[str, Any],
    directive: TelemetryDirective,
    provider_suffix: str,
    task_directory: Path,
    warnings: list[str],
) -> Path:
    changed = False
    application = payload.get("application")
    if directive.env_override:
        if isinstance(application, dict):
            application["env"] = directive.env_override
            changed = True
        else:
            warnings.append("telemetry_env_normalization_skipped")

    if directive.append_messages:
        messages = _decode_telemetry_messages(directive.messages_json)
        items = payload.get("payload")
        if messages is None or not isinstance(items, list):
            warnings.append("telemetry_augmentation_skipped")
        else:
            items.extend(messages)
            changed = True

    if provider_suffix:
        _rewrite_telemetry_provider_tags(payload, provider_suffix)
        # Preserve legacy serialization behavior whenever provider rewriting is
        # enabled, even when this particular body has no matching series tag.
        changed = True

    body_path = task_directory / "telemetry_body.json"
    body_path.write_bytes(_compact_json_line(payload) if changed else source_bytes)
    return body_path


def _telemetry_headers(
    runtime: WorkerRuntime,
    payload: Mapping[str, Any],
) -> dict[str, str]:
    application = payload.get("application")
    application_values = application if isinstance(application, dict) else {}
    headers = {
        "DD-Telemetry-API-Version": _nonempty_string(payload.get("api_version")),
        "DD-Telemetry-Request-Type": _nonempty_string(payload.get("request_type")),
        "DD-Session-ID": (
            _nonempty_string(payload.get("runtime_id"))
            or runtime.telemetry_session_id
            or runtime.runtime_id
        ),
    }
    language = _nonempty_string(application_values.get("language_name"))
    tracer_version = _nonempty_string(application_values.get("tracer_version"))
    if language:
        headers["DD-Client-Library-Language"] = language
    if tracer_version:
        headers["DD-Client-Library-Version"] = tracer_version
    if runtime.endpoints.agentless:
        headers["DD-API-KEY"] = runtime.api_key
    return headers


def _telemetry_metadata_failure(payload: Mapping[str, Any]) -> str | None:
    if not _nonempty_string(payload.get("api_version")):
        return "missing or invalid api_version"
    if not _nonempty_string(payload.get("request_type")):
        return "missing or invalid request_type"
    return None


def _decode_telemetry_messages(raw: bytes) -> list[Any] | None:
    try:
        value = strict_json_loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return copy.deepcopy(value) if isinstance(value, list) else None


def _build_synthetic_telemetry(
    payload: Mapping[str, Any],
    directive: TelemetryDirective,
    warnings: list[str],
) -> dict[str, Any] | None:
    messages = _decode_telemetry_messages(directive.messages_json)
    application = payload.get("application")
    if messages is None or not isinstance(application, dict):
        warnings.append("telemetry_synthetic_skipped")
        return None
    synthetic = {
        "api_version": payload.get("api_version"),
        "request_type": "message-batch",
        "runtime_id": payload.get("runtime_id"),
        "seq_id": directive.synthetic_seq_id,
        "tracer_time": directive.synthetic_timestamp,
        "application": copy.deepcopy(application),
        "host": copy.deepcopy(payload.get("host")),
        "payload": messages,
    }
    if "debug" in payload:
        synthetic["debug"] = copy.deepcopy(payload["debug"])
    return synthetic


def _rewrite_telemetry_provider_tags(
    payload: dict[str, Any],
    provider_suffix: str,
) -> None:
    if not provider_suffix:
        return
    replacement = f"provider:bazel/{provider_suffix}"

    def rewrite_message(message: Any) -> None:
        if not isinstance(message, dict):
            return
        request_type = message.get("request_type")
        body = message.get("payload")
        if request_type in {"generate-metrics", "distributions"}:
            if not isinstance(body, dict):
                return
            series_items = body.get("series")
            if not isinstance(series_items, list):
                return
            for series in series_items:
                if not isinstance(series, dict):
                    continue
                tags = series.get("tags")
                if not isinstance(tags, list):
                    continue
                for index, tag in enumerate(tags):
                    if tag == "provider:bazel":
                        tags[index] = replacement
        elif request_type == "message-batch" and isinstance(body, list):
            for child in body:
                rewrite_message(child)

    rewrite_message(payload)


def _compact_json_line(payload: Mapping[str, Any]) -> bytes:
    return (
        strict_json_dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def _load_bazel_metadata(
    task: FileTask,
) -> tuple[dict[str, Any] | None, str | None]:
    if task.test_outputs_dir is None:
        return None, None
    sidecar = task.test_outputs_dir / "bazel_target_metadata.json"
    if not sidecar.is_file():
        return None, None
    try:
        sidecar_resolved = sidecar.resolve(strict=True)
        output_resolved = task.test_outputs_dir.resolve(strict=True)
    except OSError:
        return None, "bazel_metadata_invalid"
    if sidecar.is_symlink() or sidecar_resolved.parent != output_resolved:
        return None, "bazel_metadata_unsafe"
    payload, failure = _read_json_object(sidecar, "Bazel metadata")
    if failure is not None:
        return None, "bazel_metadata_invalid"
    return payload, None


def _read_json_object(
    path: Path,
    label: str,
) -> tuple[dict[str, Any] | None, tuple[str, str] | None]:
    value, _raw, failure = _read_json_object_with_raw(path, label)
    return value, failure


def _read_json_object_with_raw(
    path: Path,
    label: str,
) -> tuple[
    dict[str, Any] | None,
    bytes | None,
    tuple[str, str] | None,
]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        return None, None, (
            f"{label.lower().replace(' ', '_')}_payload_read_failed",
            type(exc).__name__,
        )
    try:
        value = strict_json_loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return None, None, (
            f"invalid_{label.lower().replace(' ', '_')}_json",
            type(exc).__name__,
        )
    if not isinstance(value, dict):
        return None, None, (
            f"invalid_{label.lower().replace(' ', '_')}",
            f"{label} must be a JSON object",
        )
    return value, raw, None


def _missing_enriched_tags(
    payload: Mapping[str, Any],
    expected_tags: tuple[str, ...],
) -> tuple[str, ...]:
    events = payload.get("events")
    event_objects = events if isinstance(events, list) else ()
    missing: list[str] = []
    for tag in expected_tags:
        if not tag:
            continue
        present = False
        for event in event_objects:
            if not isinstance(event, dict):
                continue
            content = event.get("content")
            if not isinstance(content, dict):
                continue
            meta = content.get("meta")
            metrics = content.get("metrics")
            if (isinstance(meta, dict) and tag in meta) or (
                isinstance(metrics, dict) and tag in metrics
            ):
                present = True
                break
        if not present:
            missing.append(tag)
    return tuple(missing)


def _cleanup_source(path: Path, keep_payloads: bool) -> tuple[bool, str | None]:
    if keep_payloads:
        return False, None
    try:
        path.unlink()
        return True, None
    except FileNotFoundError:
        return False, "source_cleanup_missing"
    except OSError:
        try:
            path.chmod(path.stat().st_mode | stat.S_IWUSR)
            # POSIX unlink checks the directory, and Bazel output trees may be read-only.
            parent = path.parent
            parent.chmod(parent.stat().st_mode | stat.S_IWUSR)
            path.unlink()
            return True, None
        except OSError:
            return False, "source_cleanup_failed"


def _persist_failed_test_chunks(
    source_path: Path,
    payload: Mapping[str, Any],
    failed_chunks: list[PreparedTestChunk],
) -> bool:
    """Atomically replace a partially uploaded source with its failed events."""
    events = payload.get("events")
    if not isinstance(events, list) or not failed_chunks:
        return False
    retry_payload = dict(payload)
    retry_payload["events"] = [
        event
        for chunk in failed_chunks
        for event in events[chunk.event_start : chunk.event_end]
    ]
    try:
        retry_body = compact_json_bytes(retry_payload)
    except TestPayloadSplitError:
        return False

    parent = source_path.parent
    for repair_permissions in (False, True):
        if repair_permissions:
            try:
                parent.chmod(parent.stat().st_mode | stat.S_IWUSR)
                source_path.chmod(source_path.stat().st_mode | stat.S_IWUSR)
            except OSError:
                pass
        temporary_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="wb",
                prefix=f".{source_path.name}.retry.",
                dir=parent,
                delete=False,
            ) as temporary:
                temporary.write(retry_body)
                temporary_path = Path(temporary.name)
            temporary_path.replace(source_path)
            return True
        except OSError:
            if temporary_path is not None:
                try:
                    temporary_path.unlink()
                except OSError:
                    pass
    return False


def _http_failure(
    http_result: HttpResult,
    *,
    payload_type: PayloadType,
    payload_limit_context: str | None = None,
) -> tuple[str, str]:
    if http_result.status_code == 413:
        if payload_type is PayloadType.TEST and payload_limit_context:
            return (
                "payload_limit_contract_mismatch",
                f"HTTP 413 after preventive split; {payload_limit_context}",
            )
        return (
            "upload_http_413",
            f"HTTP 413 for unsplit {payload_type.value} payload; "
            f"{payload_type.value} splitting is not supported",
        )
    if http_result.status_code is not None:
        return "upload_http_error", f"HTTP {http_result.status_code}"
    return "upload_transport_error", http_result.transport_error or "transport error"


def _event_count(payload: Mapping[str, Any]) -> int:
    events = payload.get("events")
    return len(events) if isinstance(events, list) else 0


def _nonempty_string(value: Any) -> str:
    return value if isinstance(value, str) and value else ""


def _unique_codes(codes: list[str]) -> tuple[str, ...]:
    return tuple(dict.fromkeys(code for code in codes if code))


def _failed(task: FileTask, code: str, message: str) -> FileResult:
    return FileResult(
        task_id=task.task_id,
        source_path=task.display_path,
        payload_type=task.payload_type,
        status=FileStatus.FAILED,
        failure_code=code,
        failure_message=message,
    )


def _skipped(task: FileTask, code: str) -> FileResult:
    return FileResult(
        task_id=task.task_id,
        source_path=task.display_path,
        payload_type=task.payload_type,
        status=FileStatus.SKIPPED,
        warning_codes=(code,),
    )


def _debug(runtime: WorkerRuntime, task: FileTask, message: str) -> None:
    if runtime.logger is not None:
        runtime.logger.debug(
            "task=%s type=%s file=%s %s",
            task.task_id,
            task.payload_type.value,
            task.display_path,
            message,
        )


def _debug_enabled(runtime: WorkerRuntime) -> bool:
    return runtime.logger is not None and runtime.logger.isEnabledFor(logging.DEBUG)
