# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Coordinator-owned resource setup, worker execution, and result aggregation."""

from __future__ import annotations

from dataclasses import dataclass
import logging
from pathlib import Path
import time
from typing import Callable, TextIO
import uuid

from .codeowners import load_codeowners_matcher
from .config import UploaderConfig
from .credentials import check_api_key_fingerprint
from .discovery import DiscoveryResult
from .endpoints import EndpointSet
from .file_worker import WorkerRuntime, process_file
from .models import FileStatus
from .reporting import (
    AggregateReport,
    LegacyReportContext,
    write_schema_v1_report,
    write_statistics_json,
)
from .resources import LoadedResources
from .telemetry import build_telemetry_plan
from .temporary import invocation_temporary_directory
from .transport import HttpTransport, validate_proxy_environment
from .worker_pool import (
    WorkerPoolInterrupted,
    WorkerPoolRun,
    run_file_workers_with_stats,
)


@dataclass(frozen=True)
class CoordinatorSettings:
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

    @classmethod
    def from_config(cls, config: UploaderConfig) -> "CoordinatorSettings":
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
        )


@dataclass(frozen=True)
class CoordinatorOutcome:
    report: AggregateReport
    initialization_warning_codes: tuple[str, ...] = ()


def execute_discovery(
    discovery: DiscoveryResult,
    *,
    settings: CoordinatorSettings,
    endpoints: EndpointSet,
    resources: LoadedResources,
    logger: logging.Logger | None = None,
    transport_factory: Callable[[], object] | None = None,
    clock: Callable[[], float] = time.monotonic,
    identifier_factory: Callable[[], str] = lambda: str(uuid.uuid4()),
) -> CoordinatorOutcome:
    """Run already-authorized tasks; workers never mutate coordinator state."""
    started = clock()
    validate_proxy_environment(settings.proxy_environment)
    matcher = load_codeowners_matcher(
        explicit_path=settings.codeowners_file,
        workspace_root=settings.workspace,
        context_workspace=resources.context_workspace,
        cwd=settings.invocation_cwd,
        launcher_directory=settings.launcher_directory,
    )
    telemetry_plan = build_telemetry_plan(
        discovery.tasks,
        resources.telemetry_facts_paths,
        primary_context=resources.primary_context,
    )
    fingerprint_check = check_api_key_fingerprint(
        resources.primary_context,
        api_key=settings.api_key,
        agentless=endpoints.agentless,
    )
    fingerprint_warnings = (
        (fingerprint_check.warning_code,)
        if fingerprint_check.warning_code is not None
        else ()
    )
    base_initialization_warnings = tuple(
        dict.fromkeys(
            discovery.warning_codes
            + resources.warning_codes
            + matcher.warnings
            + telemetry_plan.warning_codes
            + fingerprint_warnings
        )
    )
    if logger is not None:
        logger.debug(
            "pre-worker resources ready: files=%d contexts=%d "
            "codeowners_file=%s codeowners_rules=%d telemetry_directives=%d",
            len(discovery.tasks),
            len(resources.context_plan.by_repo),
            str(matcher.source_path) if matcher.source_path is not None else "none",
            len(matcher.rules),
            len(telemetry_plan.entries),
        )
        if fingerprint_check.status == "mismatch":
            logger.warning(
                "warning_code=api_key_fingerprint_mismatch "
                "DD_API_KEY mismatch between fetch and uploader"
            )
        elif fingerprint_check.status == "evp_skipped":
            logger.warning(
                "warning_code=api_key_fingerprint_evp_skipped DD_API_KEY "
                "fingerprint present but uploader is in EVP mode; check skipped"
            )
        else:
            logger.debug(
                "DD_API_KEY fingerprint check status=%s",
                fingerprint_check.status,
            )
        for warning in (
            code
            for code in base_initialization_warnings
            if code not in fingerprint_warnings
        ):
            logger.warning("pre-worker warning_code=%s", warning)

    temporary_cleanup_errors: list[str] = []
    interrupted = False
    cancelled = 0
    with invocation_temporary_directory(
        on_cleanup_error=temporary_cleanup_errors.append,
    ) as temporary_root:
        if logger is not None:
            logger.debug("invocation temporary root created: %s", temporary_root)
        runtime = WorkerRuntime(
            endpoints=endpoints,
            invocation_temp_root=temporary_root,
            context_plan=resources.context_plan,
            codeowners_matcher=matcher,
            runtime_id=identifier_factory(),
            rules_version=settings.rules_version,
            uploader_version=settings.uploader_version,
            api_key=settings.api_key,
            schema=resources.schema,
            dry_run=settings.dry_run,
            validate_enrichment=settings.validate_enrichment,
            expected_enriched_tags=settings.expected_enriched_tags,
            gzip_payloads=settings.gzip_payloads,
            keep_payloads=settings.keep_payloads,
            filter_prefix=settings.filter_prefix,
            telemetry_session_id=identifier_factory(),
            telemetry_plan=telemetry_plan,
            logger=logger,
        )
        factory = transport_factory or (
            lambda: HttpTransport(
                proxy_environment=settings.proxy_environment,
                logger=logger,
            )
        )
        try:
            pool_run: WorkerPoolRun = run_file_workers_with_stats(
                discovery.tasks,
                workers=settings.workers,
                runtime=runtime,
                transport_factory=factory,
                process_file=process_file,
                logger=logger,
            )
        except WorkerPoolInterrupted as exc:
            pool_run = exc.run
            interrupted = True
            cancelled = exc.cancelled

    additional_warnings: tuple[str, ...] = ()
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
                len(pool_run.results),
                cancelled,
            )
    initialization_warnings = tuple(
        dict.fromkeys(base_initialization_warnings + additional_warnings)
    )

    if logger is not None:
        for result in pool_run.results:
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
                    logger.debug
                    if result.status is FileStatus.SKIPPED
                    else logger.warning
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

    exit_code = (
        130
        if interrupted
        else int(any(result.status is FileStatus.FAILED for result in pool_run.results))
    )
    report = AggregateReport.create(
        dry_run=settings.dry_run,
        exit_code=exit_code,
        configured_workers=settings.workers,
        worker_threads=pool_run.worker_threads,
        peak_active_workers=pool_run.peak_active_workers,
        elapsed_seconds=max(0.0, clock() - started),
        discovered_by_type=discovery.counts(),
        results=pool_run.results,
        cancelled=cancelled,
        initialization_warning_codes=initialization_warnings,
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
    return CoordinatorOutcome(report, initialization_warnings)


def emit_outcome(
    outcome: CoordinatorOutcome,
    *,
    stream: TextIO,
    report_json: Path | None = None,
    legacy_report_context: LegacyReportContext | None = None,
) -> None:
    """Render stdout and optional JSON from the exact same aggregate object."""
    for line in outcome.report.human_lines():
        print(line, file=stream)
    if report_json is not None:
        try:
            if legacy_report_context is None:
                write_statistics_json(report_json, outcome.report)
            else:
                write_schema_v1_report(
                    report_json,
                    outcome.report,
                    legacy_report_context,
                )
        except OSError as exc:
            print(
                "[dd-uploader] warning: failed to write uploader report: "
                f"{type(exc).__name__}",
                file=stream,
            )
