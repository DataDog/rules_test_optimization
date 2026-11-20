# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Prepare shared inputs, run file workers, and aggregate immutable results.

This boundary keeps invocation-wide state out of independent worker pipelines.
"""

from __future__ import annotations

from contextlib import nullcontext
from dataclasses import dataclass
import logging
from pathlib import Path
import time
from typing import Callable
import uuid

from .codeowners import CodeOwnersMatcher, load_codeowners_matcher
from .config import UploaderConfig
from .credentials import check_api_key_fingerprint
from .ddtest_backend import (
    NativeUploadRun,
    NativeUploadSettings,
    NativeUploadUnavailable,
    is_native_task,
    run_native_upload,
)
from .discovery import DiscoveryResult
from .endpoints import EndpointSet
from .file_worker import WorkerRuntime, process_file
from .metrics import PhaseRecorder
from .batch_worker import prepare_test_work_items
from .batching import BatchCompatibilityError, schema_for_event_runtime_ids
from .models import FileResult, FileStatus, FileTask
from .reporting import AggregateReport
from .resources import LoadedResources
from .telemetry import TelemetryPlan, build_telemetry_plan
from .temporary import invocation_temporary_directory
from .transport import HttpTransport, validate_proxy_environment
from .worker_pool import (
    WorkerPoolInterrupted,
    WorkerPoolRun,
    run_file_workers,
)


@dataclass(frozen=True)
class CoordinatorSettings:
    """Worker-facing configuration with lifecycle-only options removed."""

    workspace: Path
    workers: int
    dry_run: bool
    validate_enrichment: bool
    expected_enriched_tags: tuple[str, ...]
    gzip_payloads: bool
    keep_payloads: bool
    filter_prefix: bool
    rules_version: str
    uploader_version: str
    api_key: str
    proxy_environment: tuple[tuple[str, str], ...] = ()
    codeowners_file: Path | None = None
    invocation_cwd: Path | None = None
    launcher_directory: Path | None = None
    batch_test_payloads: bool = False
    http_keep_alive: bool = False
    uploader_backend: str = "python"
    workers_explicit: bool = True
    # The resolved ddtest executable for uploader_backend = "ddtest".
    ddtest_executable: Path | None = None

    @classmethod
    def from_config(cls, config: UploaderConfig, ddtest_executable: Path | None = None) -> "CoordinatorSettings":
        return cls(
            workspace=config.workspace,
            workers=config.workers,
            dry_run=config.dry_run,
            validate_enrichment=config.validate_enrichment,
            expected_enriched_tags=config.expected_enriched_tags,
            gzip_payloads=config.gzip_payloads,
            keep_payloads=config.keep_payloads,
            filter_prefix=config.filter_prefix,
            rules_version=config.rule.rules_version,
            uploader_version=config.rule.uploader_version,
            api_key=config.api_key,
            proxy_environment=config.proxy_environment,
            codeowners_file=config.codeowners_file,
            invocation_cwd=config.invocation_cwd,
            launcher_directory=config.launcher_directory,
            batch_test_payloads=config.batch_test_payloads,
            http_keep_alive=config.http_keep_alive,
            uploader_backend=config.uploader_backend,
            workers_explicit=config.workers_explicit,
            ddtest_executable=ddtest_executable,
        )


@dataclass(frozen=True)
class _WorkerInputs:
    """Read-only resources prepared once before any worker starts."""

    codeowners: CodeOwnersMatcher
    telemetry: TelemetryPlan
    warning_codes: tuple[str, ...]


def _prepare_worker_inputs(
    discovery: DiscoveryResult,
    *,
    settings: CoordinatorSettings,
    endpoints: EndpointSet,
    resources: LoadedResources,
    logger: logging.Logger | None,
) -> _WorkerInputs:
    """Validate transport settings and snapshot shared enrichment resources."""
    validate_proxy_environment(settings.proxy_environment)
    codeowners = load_codeowners_matcher(
        explicit_path=settings.codeowners_file,
        workspace_root=settings.workspace,
        context_workspace=resources.context_workspace,
        cwd=settings.invocation_cwd,
        launcher_directory=settings.launcher_directory,
    )
    telemetry = build_telemetry_plan(
        discovery.tasks,
        resources.telemetry_facts_paths,
        primary_context=resources.primary_context,
        context_plan=resources.context_plan,
    )
    fingerprint = check_api_key_fingerprint(
        resources.primary_context,
        api_key=settings.api_key,
        agentless=endpoints.agentless,
    )
    fingerprint_warnings = (
        (fingerprint.warning_code,) if fingerprint.warning_code is not None else ()
    )
    warnings = tuple(
        dict.fromkeys(
            discovery.warning_codes
            + resources.warning_codes
            + codeowners.warnings
            + telemetry.warning_codes
            + fingerprint_warnings
        )
    )
    if logger is not None:
        logger.debug(
            "pre-worker resources ready: files=%d contexts=%d "
            "codeowners_file=%s codeowners_rules=%d telemetry_directives=%d",
            len(discovery.tasks),
            len(resources.context_plan.by_repo),
            str(codeowners.source_path) if codeowners.source_path is not None else "none",
            len(codeowners.rules),
            len(telemetry.entries),
        )
        if fingerprint.status == "mismatch":
            logger.warning(
                "warning_code=api_key_fingerprint_mismatch "
                "DD_API_KEY mismatch between fetch and uploader"
            )
        elif fingerprint.status == "evp_skipped":
            logger.warning(
                "warning_code=api_key_fingerprint_evp_skipped DD_API_KEY "
                "fingerprint present but uploader is in EVP mode; check skipped"
            )
        else:
            logger.debug("DD_API_KEY fingerprint check status=%s", fingerprint.status)
        for warning in (code for code in warnings if code not in fingerprint_warnings):
            logger.warning("pre-worker warning_code=%s", warning)
    return _WorkerInputs(codeowners, telemetry, warnings)


def run_discovered_tasks(
    discovery: DiscoveryResult,
    *,
    settings: CoordinatorSettings,
    endpoints: EndpointSet,
    resources: LoadedResources,
    logger: logging.Logger | None = None,
    transport_factory: Callable[[], object] | None = None,
    clock: Callable[[], float] = time.monotonic,
    identifier_factory: Callable[[], str] = lambda: str(uuid.uuid4()),
    measurements: PhaseRecorder | None = None,
) -> AggregateReport:
    """Run already-authorized tasks; workers never mutate coordinator state."""
    started = clock()
    with measurements.phase("worker_setup") if measurements is not None else nullcontext():
        worker_inputs = _prepare_worker_inputs(
            discovery,
            settings=settings,
            endpoints=endpoints,
            resources=resources,
            logger=logger,
        )
    batch_schema = None
    if settings.batch_test_payloads:
        try:
            batch_schema = schema_for_event_runtime_ids(resources.schema)
        except BatchCompatibilityError:
            pass
        if batch_schema is None and logger is not None:
            logger.warning("batching_schema_unavailable: using ordinary per-file uploads because the outbound CITESTCYCLE schema is unavailable")

    temporary_cleanup_errors: list[str] = []
    interrupted = False
    cancelled = 0
    runtime_id = identifier_factory()
    native = NativeUploadRun(results=(), cancelled=0, interrupted=False)
    native_warnings: tuple[str, ...] = ()
    worker_tasks = discovery.tasks
    with invocation_temporary_directory(
        on_cleanup_error=temporary_cleanup_errors.append,
    ) as temporary_root:
        if logger is not None:
            logger.debug("invocation temporary root created: %s", temporary_root)
        if settings.uploader_backend == "ddtest":
            native_tasks = tuple(task for task in discovery.tasks if is_native_task(task))
            try:
                if native_tasks:
                    with measurements.phase("native_upload") if measurements is not None else nullcontext():
                        native = _run_native_upload(
                            native_tasks, settings, endpoints, resources, worker_inputs,
                            runtime_id, temporary_root, logger,
                        )
                worker_tasks = tuple(task for task in discovery.tasks if not is_native_task(task))
            except NativeUploadUnavailable as exc:
                native_warnings = ("ddtest_backend_unavailable",)
                if logger is not None:
                    logger.warning("warning_code=ddtest_backend_unavailable using the Python workers: %s", exc)
            if native.interrupted:
                cancelled += len(worker_tasks)
                worker_tasks = ()
        runtime = WorkerRuntime(
            endpoints=endpoints,
            invocation_temp_root=temporary_root,
            context_plan=resources.context_plan,
            codeowners_matcher=worker_inputs.codeowners,
            runtime_id=runtime_id,
            rules_version=settings.rules_version,
            uploader_version=settings.uploader_version,
            api_key=settings.api_key,
            schema=resources.schema,
            batch_schema=batch_schema,
            dry_run=settings.dry_run,
            validate_enrichment=settings.validate_enrichment,
            expected_enriched_tags=settings.expected_enriched_tags,
            gzip_payloads=settings.gzip_payloads,
            keep_payloads=settings.keep_payloads,
            filter_prefix=settings.filter_prefix,
            telemetry_session_id=identifier_factory(),
            telemetry_plan=worker_inputs.telemetry,
            logger=logger,
            clock=clock,
        )
        create_transport = transport_factory or (
            lambda: HttpTransport(
                proxy_environment=settings.proxy_environment,
                logger=logger,
                keep_alive=settings.http_keep_alive,
            )
        )
        try:
            worker_run: WorkerPoolRun = run_file_workers(
                worker_tasks,
                workers=settings.workers,
                runtime=runtime,
                transport_factory=create_transport,
                process_file=process_file,
                prepare_work=prepare_test_work_items if batch_schema is not None else None,
                logger=logger,
                measurements=measurements,
            )
        except WorkerPoolInterrupted as exc:
            worker_run = exc.run
            interrupted = True
            cancelled += exc.cancelled
    interrupted = interrupted or native.interrupted
    cancelled += native.cancelled
    results = native.results + worker_run.results

    additional_warnings: tuple[str, ...] = native_warnings
    if settings.batch_test_payloads and batch_schema is None:
        additional_warnings += ("batching_schema_unavailable",)
    if temporary_cleanup_errors:
        additional_warnings += ("invocation_temp_cleanup_failed",)
        if logger is not None:
            logger.warning(
                "invocation temporary cleanup failed: %s",
                temporary_cleanup_errors[0],
            )
    elif logger is not None:
        logger.debug("invocation temporary root cleanup completed")
    if interrupted:
        additional_warnings += ("invocation_interrupted",)
        if logger is not None:
            logger.error(
                "interrupted after completed=%d cancelled=%d",
                len(results),
                cancelled,
            )
    initialization_warnings = tuple(
        dict.fromkeys(worker_inputs.warning_codes + additional_warnings)
    )

    if logger is not None:
        _log_results(results, logger)

    exit_code = (
        130
        if interrupted
        else int(any(result.status is FileStatus.FAILED for result in results))
    )
    report = AggregateReport.create(
        dry_run=settings.dry_run,
        exit_code=exit_code,
        configured_workers=settings.workers,
        worker_threads=worker_run.worker_threads,
        peak_active_workers=worker_run.peak_active_workers,
        elapsed_seconds=max(0.0, clock() - started),
        discovered_by_type=discovery.counts(),
        results=results,
        cancelled=cancelled,
        initialization_warning_codes=initialization_warnings,
        requests=worker_run.requests,
        native_workers=native.workers,
    )
    if logger is not None:
        stats = report.statistics()
        logger.debug(
            "coordinator completed exit_code=%d processed=%d cancelled=%d "
            "requests_attempted=%d elapsed=%.3fs",
            report.exit_code,
            stats["files"]["processed"],
            stats["files"]["cancelled"],
            stats["requests"]["attempted"],
            report.elapsed_seconds,
        )
    return report


def _run_native_upload(
    tasks: tuple[FileTask, ...],
    settings: CoordinatorSettings,
    endpoints: EndpointSet,
    resources: LoadedResources,
    worker_inputs: _WorkerInputs,
    runtime_id: str,
    work_directory: Path,
    logger: logging.Logger | None,
) -> NativeUploadRun:
    """Send the test and coverage tasks with ddtest's native uploader."""
    if settings.ddtest_executable is None:
        raise NativeUploadUnavailable("the uploader's runfiles do not contain the ddtest executable")
    return run_native_upload(
        tasks,
        settings=NativeUploadSettings(
            executable=settings.ddtest_executable,
            rules_version=settings.rules_version,
            api_key=settings.api_key,
            dry_run=settings.dry_run,
            keep_payloads=settings.keep_payloads,
            gzip_payloads=settings.gzip_payloads,
            batch_test_payloads=settings.batch_test_payloads,
            filter_prefix=settings.filter_prefix,
            validate_enrichment=settings.validate_enrichment,
            expected_enriched_tags=settings.expected_enriched_tags,
            workers=settings.workers if settings.workers_explicit else None,
            codeowners_file=worker_inputs.codeowners.source_path,
        ),
        endpoints=endpoints,
        context_plan=resources.context_plan,
        runtime_id=runtime_id,
        work_directory=work_directory,
        logger=logger,
    )


def _log_results(results: tuple[FileResult, ...], logger: logging.Logger) -> None:
    """Emit task diagnostics after workers stop, keeping logging centralized."""
    for result in results:
        logger.debug(
            "task=%s type=%s terminal_status=%s attempts=%d retries=%d",
            result.task_id,
            result.payload_type.value,
            result.status.value,
            result.requests_attempted,
            result.retries,
        )
        for warning_code in result.warning_codes:
            log_method = (
                logger.debug if result.status is FileStatus.SKIPPED else logger.warning
            )
            log_method(
                "task=%s file=%s warning_code=%s",
                result.task_id,
                result.source_path,
                warning_code,
            )
        if result.status is FileStatus.FAILED:
            logger.error(
                "task=%s file=%s failure_code=%s detail=%s",
                result.task_id,
                result.source_path,
                result.failure_code or "unknown",
                result.failure_message or "none",
            )
