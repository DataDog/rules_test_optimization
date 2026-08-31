# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Own the locked uploader lifecycle around independent file workers.

Preflight, postflight, and reporting live here so workers only process files.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import logging
from pathlib import Path
import sys
import time
from typing import Callable, TextIO

from topt_runtime.runfiles import RunfilesResolver

from .config import ConfigError, UploaderConfig, validate_upload_credentials
from .coordinator import CoordinatorSettings, run_discovered_tasks
from .discovery import (
    DiscoveryError,
    DiscoveryResult,
    count_tasks_by_payload_type,
    discover_file_tasks,
    resolve_local_testlogs_root,
    tests_executed,
    wait_for_quiescence,
)
from .endpoints import EndpointSet
from .expected_targets import (
    ExpectedTargetsError,
    ExpectedTargetsPlan,
    load_expected_targets,
    select_expected_outputs,
)
from .freshness import (
    FreshnessError,
    FreshnessPlan,
    FreshnessPreparation,
    filter_discovery_for_freshness,
    prepare_freshness,
    validate_fresh_outputs_accounted,
)
from .locking import WorkspaceLock, WorkspaceLockError
from .logging_utils import redact_url
from .models import FileStatus, PayloadType
from .reporting import AggregateReport, LegacyReportContext, emit_report
from .resources import LoadedResources, ResourceError, ResourceInputs, load_resources
from .temporary import TemporaryDirectoryError
from .transport import HttpTransportError
from .worker_pool import WorkerPoolError


_CONTROLLED_ERRORS = (
    ConfigError,
    DiscoveryError,
    ExpectedTargetsError,
    ResourceError,
    FreshnessError,
    TemporaryDirectoryError,
    HttpTransportError,
    WorkerPoolError,
    WorkspaceLockError,
)


@dataclass(frozen=True)
class _ReportReason:
    """Explicit reason fields carried from lifecycle decisions into reporting."""

    code: str = ""
    message: str = ""
    next_steps: tuple[str, ...] = ()


def run_uploader(
    config: UploaderConfig,
    *,
    resolver: RunfilesResolver,
    endpoints: EndpointSet,
    logger: logging.Logger,
    stream: TextIO | None = None,
    transport_factory: Callable[[], object] | None = None,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    """Execute one locked uploader invocation and release after reporting."""
    workspace_lock = WorkspaceLock(config.lock_workspace)
    try:
        return _run_uploader_with_lock(
            config,
            resolver=resolver,
            endpoints=endpoints,
            logger=logger,
            stream=stream,
            transport_factory=transport_factory,
            clock=clock,
            workspace_lock=workspace_lock,
        )
    finally:
        workspace_lock.release()


def _run_uploader_with_lock(
    config: UploaderConfig,
    *,
    resolver: RunfilesResolver,
    endpoints: EndpointSet,
    logger: logging.Logger,
    stream: TextIO | None,
    transport_factory: Callable[[], object] | None,
    clock: Callable[[], float],
    workspace_lock: WorkspaceLock,
) -> int:
    """Hold the workspace lock through preflight, cleanup, and reporting."""
    started = clock()
    expected_targets_plan = ExpectedTargetsPlan()
    freshness_plan = FreshnessPlan()
    freshness_preparation: FreshnessPreparation | None = None
    raw_discovery = _empty_discovery()
    freshness_skipped_count = 0
    report: AggregateReport | None = None
    report_reason: _ReportReason | None = None
    workers_completed = False

    _log_invocation(config, endpoints, resolver, logger)

    try:
        # The public wrapper keeps the lock through final report emission.
        workspace_lock.acquire()
        expected_targets_plan = load_expected_targets(
            static_targets=config.rule.expected_targets,
            expected_targets_file_paths=(
                config.rule.expected_targets_file_path,
                config.rule.expected_targets_file_short_path,
            ),
            resolver=resolver,
            runtime_targets=config.runtime_expected_targets,
            runtime_selection=config.rule.runtime_selection,
        )
        resources = _load_resources(config, resolver, logger)
        local_root = resolve_local_testlogs_root(
            explicit=config.testlogs_dir,
            workspace=config.workspace,
            cwd=Path.cwd(),
        )
        freshness_preparation = prepare_freshness(
            config,
            resolver=resolver,
            local_testlogs_root=local_root,
            expected_targets=expected_targets_plan.targets,
            logger=logger,
        )
        freshness_plan = freshness_preparation.plan
        logger.debug(
            "freshness prepared: selected_source=%s scan_roots=%s "
            "staged_roots=%s eligible=%d cached=%d remote_only=%d",
            freshness_plan.selected_source,
            tuple(str(root.path) for root in freshness_preparation.scan_roots),
            tuple(str(path) for path in freshness_preparation.staged_roots),
            len(freshness_plan.eligible_outputs),
            len(freshness_plan.cached_outputs),
            len(freshness_plan.remote_only_outputs),
        )
        all_expected_outputs_cached = _all_expected_outputs_cached(
            expected_targets_plan,
            freshness_plan,
        )
        if (
            not freshness_preparation.scan_roots
            and config.fail_on_error
            and not all_expected_outputs_cached
        ):
            raise DiscoveryError(
                "FAIL_ON_ERROR is set and no local or staged testlogs root was found"
            )
        raw_discovery = _discover_payloads(
            config,
            freshness_preparation,
            all_expected_outputs_cached=all_expected_outputs_cached,
            logger=logger,
        )

        expected_discovery = select_expected_outputs(
            raw_discovery,
            expected_targets_plan,
            allow_missing=freshness_plan.selected_source == "bep",
        )
        freshness_selection = filter_discovery_for_freshness(
            expected_discovery,
            freshness_plan,
            freshness_mode=config.freshness_mode,
        )
        eligible_discovery = freshness_selection.discovery
        freshness_skipped_outputs = freshness_selection.skipped_outputs
        freshness_skipped_count = len(freshness_skipped_outputs)
        for output_key in freshness_skipped_outputs:
            logger.debug("freshness skipped output_key=%s", output_key)
        _log_legacy_freshness_markers(
            config,
            freshness_plan,
            freshness_skipped_outputs,
            logger,
        )
        if eligible_discovery.tasks:
            validate_upload_credentials(config)
        else:
            logger.debug("credential validation skipped: no upload tasks")
        report = run_discovered_tasks(
            eligible_discovery,
            settings=CoordinatorSettings.from_config(config),
            endpoints=endpoints,
            resources=resources,
            logger=logger,
            transport_factory=transport_factory,
            clock=clock,
        )
        workers_completed = True
        report = replace(
            report,
            discovered_by_type=raw_discovery.discovered_by_type,
        )
        if report.exit_code == 130:
            report_reason = _ReportReason(
                code="interrupted",
                message="Uploader interrupted after active workers finished.",
                next_steps=(
                    "Re-run the uploader to process retained and cancelled files.",
                ),
            )
        else:
            try:
                validate_fresh_outputs_accounted(
                    freshness_plan,
                    eligible_discovery,
                    report.results,
                    expected_targets=expected_targets_plan.targets,
                    fail_on_error=config.fail_on_error,
                )
            except FreshnessError as exc:
                logger.error("%s", exc)
                report = replace(report, exit_code=exc.exit_code)
                if "remote-only" in str(exc).lower():
                    report_reason = _preflight_failure_reason(
                        config,
                        freshness_plan,
                        exc,
                    )
                else:
                    report_reason = _ReportReason(
                        code="fresh_output_without_payloads",
                        message=str(exc),
                        next_steps=(
                            "Inspect the fresh test.outputs payload directories.",
                        ),
                    )

        if not raw_discovery.tasks:
            if all_expected_outputs_cached:
                report_reason = _ReportReason(
                    code="ok",
                    message=(
                        "All expected target outputs were cached; nothing was "
                        "uploaded."
                    ),
                )
            elif (
                tests_executed(freshness_preparation.scan_roots)
                and config.fail_on_error
            ):
                report = replace(report, exit_code=1)
                report_reason = _ReportReason(
                    code="tests_ran_without_payloads",
                    message="Tests ran but no payload files were found.",
                    next_steps=(
                        "Check that DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true is set.",
                    ),
                )
    except _CONTROLLED_ERRORS as exc:
        exit_code = exc.exit_code if isinstance(exc, FreshnessError) else 2
        logger.error("%s", exc)
        report = _empty_report(
            config,
            exit_code=exit_code,
            elapsed_seconds=max(0.0, clock() - started),
            discovery=raw_discovery,
        )
        report_reason = _preflight_failure_reason(
            config,
            freshness_plan,
            exc,
        )
    finally:
        report, report_reason = _cleanup_staging(
            freshness_preparation,
            report,
            report_reason,
            config=config,
            discovery=raw_discovery,
            started=started,
            clock=clock,
            logger=logger,
        )

    assert report is not None
    # The coordinator measures only worker preparation and delivery. Final
    # invocation statistics must also include locking, BEP staging, discovery
    # quiescence, resource loading, and staging cleanup.
    report = replace(
        report,
        elapsed_seconds=max(0.0, clock() - started),
    )
    report_context = _legacy_context(
        config,
        freshness_plan=freshness_plan,
        raw_discovery=raw_discovery,
        staged_roots=(
            freshness_preparation.staged_roots
            if freshness_preparation is not None
            else ()
        ),
        freshness_skipped_count=freshness_skipped_count,
        report_reason=report_reason,
    )
    logger.debug(
        "emitting final report: exit_code=%d results=%d warnings=%s",
        report.exit_code,
        len(report.results),
        report.initialization_warning_codes,
    )
    if workers_completed:
        _log_legacy_result_markers(config, report, logger)
    emit_report(
        report,
        stream=stream if stream is not None else sys.stdout,
        report_json=config.report_json,
        legacy_report_context=report_context,
    )
    return report.exit_code


def _log_legacy_freshness_markers(
    config: UploaderConfig,
    freshness_plan: FreshnessPlan,
    skipped_outputs: tuple[str, ...],
    logger: logging.Logger,
) -> None:
    """Keep stable freshness markers after selecting Python by default."""
    if freshness_plan.selected_source == "bep":
        logger.info(
            "freshness filtering enabled: source=bep files=%d "
            "eligible_outputs=%d remote_only_outputs=%d",
            len(config.bep_json_files),
            len(freshness_plan.eligible_outputs),
            len(freshness_plan.remote_only_outputs),
        )
    elif freshness_plan.selected_source == "execution_log":
        logger.info("freshness filtering enabled: source=execution_log")
    elif config.freshness_mode == "disabled":
        logger.info("freshness filtering disabled")

    skipped_or_cached_outputs = sorted(
        set(skipped_outputs).union(
            output_key for _label, output_key in freshness_plan.cached_outputs
        )
    )
    for output_key in skipped_or_cached_outputs:
        logger.info(
            "skipping cached or non-current test output: %s (freshness selection)",
            output_key,
        )


def _log_legacy_result_markers(
    config: UploaderConfig,
    report: AggregateReport,
    logger: logging.Logger,
) -> None:
    """Keep stable per-test result markers alongside the aggregate report."""
    successful_tests = tuple(
        result
        for result in report.results
        if result.payload_type is PayloadType.TEST
        and result.status is FileStatus.SUCCEEDED
    )
    if config.validate_enrichment:
        validation_prefix = "dry-run " if config.dry_run else ""
        for result in successful_tests:
            logger.info(
                "%svalidated enriched test payload: %s",
                validation_prefix,
                result.source_path,
            )
    if config.dry_run:
        logger.info("dry-run validated %d test payloads", len(successful_tests))
    else:
        logger.info("uploaded %d test payloads", len(successful_tests))


def _cleanup_staging(
    freshness_preparation: FreshnessPreparation | None,
    report: AggregateReport | None,
    report_reason: _ReportReason | None,
    *,
    config: UploaderConfig,
    discovery: DiscoveryResult,
    started: float,
    clock: Callable[[], float],
    logger: logging.Logger,
) -> tuple[AggregateReport | None, _ReportReason | None]:
    """Clean owned BEP staging without discarding completed upload results."""
    if freshness_preparation is None:
        return report, report_reason
    try:
        freshness_preparation.cleanup()
    except FreshnessError as exc:
        logger.error("failed to clean BEP staging: %s", exc)
        if report is None:
            report = _empty_report(
                config,
                exit_code=2,
                elapsed_seconds=max(0.0, clock() - started),
                discovery=discovery,
            )
        warning_codes = tuple(
            dict.fromkeys(
                report.initialization_warning_codes + ("staging_cleanup_failed",)
            )
        )
        report = replace(
            report,
            exit_code=report.exit_code or 2,
            initialization_warning_codes=warning_codes,
        )
        if report.exit_code == 2 and (
            report_reason is None or report_reason.code in {"", "ok"}
        ):
            report_reason = _ReportReason(
                code="staging_cleanup_failed",
                message=str(exc),
                next_steps=(
                    "Remove only the uploader-owned staging run directory.",
                ),
            )
    else:
        logger.debug("BEP staging cleanup completed")
    return report, report_reason


def _log_invocation(
    config: UploaderConfig,
    endpoints: EndpointSet,
    resolver: RunfilesResolver,
    logger: logging.Logger,
) -> None:
    """Record the immutable inputs that explain the rest of the run."""
    logger.debug(
        "effective config: mode=%s workers=%d validate_enrichment=%s "
        "gzip=%s keep_payloads=%s filter_prefix=%s fail_on_error=%s "
        "workspace=%s testlogs=%s freshness_source=%s freshness_mode=%s "
        "artifact_source=%s remote_artifacts=%s proxy_configured=%s",
        "dry-run" if config.dry_run else "upload",
        config.workers,
        config.validate_enrichment,
        config.gzip_payloads,
        config.keep_payloads,
        config.filter_prefix,
        config.fail_on_error,
        config.workspace,
        config.testlogs_dir or "auto",
        config.freshness_source,
        config.freshness_mode,
        config.artifact_source,
        config.remote_artifacts,
        bool(config.proxy_environment),
    )
    logger.debug(
        "endpoint mode=%s tests=%s coverage=%s telemetry=%s",
        "agentless" if endpoints.agentless else "evp",
        redact_url(endpoints.test_url),
        redact_url(endpoints.coverage_url),
        redact_url(endpoints.telemetry_url),
    )
    logger.debug(
        "runfiles snapshot: cwd=%s roots=%s workspace_names=%s manifest=%s "
        "manifest_entries=%d",
        resolver.cwd,
        tuple(str(path) for path in resolver.roots),
        resolver.workspace_names,
        resolver.manifest_path or "none",
        len(resolver.manifest_entries),
    )


def _all_expected_outputs_cached(
    expected: ExpectedTargetsPlan,
    freshness: FreshnessPlan,
) -> bool:
    expected_labels = frozenset(expected.targets)
    cached_labels = frozenset(label for label, _key in freshness.cached_outputs)
    return bool(
        expected_labels
        and cached_labels == expected_labels
        and not freshness.eligible_outputs
        and not freshness.remote_only_outputs
        and not freshness.missing_output_labels
    )


def _discover_payloads(
    config: UploaderConfig,
    preparation: FreshnessPreparation,
    *,
    all_expected_outputs_cached: bool,
    logger: logging.Logger,
) -> DiscoveryResult:
    """Discover a stable source-file snapshot after freshness has authorized it."""
    selected_output_keys = {
        output_key
        for _label, output_key in preparation.plan.selected_artifact_outputs
    }
    for output_key in sorted(selected_output_keys):
        logger.debug("freshness eligible output_key=%s", output_key)

    def scan() -> DiscoveryResult:
        return discover_file_tasks(
            preparation.scan_roots,
            max_depth=config.max_depth,
            staged_output_keys=selected_output_keys,
        )

    if all_expected_outputs_cached:
        logger.debug("all expected target outputs were cached; skipping discovery wait")
        return _empty_discovery()
    if not preparation.scan_roots:
        logger.debug("no local or staged testlogs roots were found")
        return scan()

    quiescence = wait_for_quiescence(
        scan,
        quiescent_seconds=config.quiescent_sec,
        max_wait_seconds=config.max_wait_sec,
    )
    discovery = quiescence.discovery
    logger.debug(
        "discovery settled: reason=%s elapsed=%.2fs outputs=%d files=%d",
        quiescence.reason,
        quiescence.elapsed_seconds,
        len(discovery.outputs),
        len(discovery.tasks),
    )
    return discovery


def _load_resources(
    config: UploaderConfig,
    resolver: RunfilesResolver,
    logger: logging.Logger,
) -> LoadedResources:
    """Resolve and log the read-only context shared by all workers."""
    resources = load_resources(
        resolver,
        ResourceInputs(
            context_override=config.context_json,
            context_manifest_paths=(
                config.rule.context_manifest_path,
                config.rule.context_manifest_short_path,
            ),
            telemetry_facts_manifest_paths=(
                config.rule.telemetry_facts_manifest_path,
                config.rule.telemetry_facts_manifest_short_path,
            ),
            schema_paths=(
                config.rule.schema_json_path,
                config.rule.schema_json_short_path,
            ),
            runtime_context_entries=config.runtime_context_entries,
            runtime_selection=config.rule.runtime_selection,
            workspace=config.workspace,
            invocation_cwd=config.invocation_cwd,
        ),
    )
    logger.debug(
        "resources resolved: primary_context=%s contexts=%d "
        "telemetry_facts=%d schema=%s warnings=%s",
        resources.primary_context_path or "none",
        len(resources.context_plan.by_repo),
        len(resources.telemetry_facts_paths),
        "loaded" if resources.schema is not None else "absent",
        resources.warning_codes,
    )
    return resources


def _empty_discovery() -> DiscoveryResult:
    return DiscoveryResult(
        outputs=(),
        tasks=(),
        discovered_by_type=count_tasks_by_payload_type(()),
    )


def _empty_report(
    config: UploaderConfig,
    *,
    exit_code: int,
    elapsed_seconds: float,
    discovery: DiscoveryResult,
) -> AggregateReport:
    return AggregateReport.create(
        dry_run=config.dry_run,
        exit_code=exit_code,
        configured_workers=config.workers,
        worker_threads=0,
        peak_active_workers=0,
        elapsed_seconds=elapsed_seconds,
        discovered_by_type=discovery.counts(),
        results=(),
        initialization_warning_codes=discovery.warning_codes,
    )


def _legacy_context(
    config: UploaderConfig,
    *,
    freshness_plan: FreshnessPlan,
    raw_discovery: DiscoveryResult,
    staged_roots: tuple[Path, ...],
    freshness_skipped_count: int,
    report_reason: _ReportReason | None,
) -> LegacyReportContext:
    final_reason = report_reason or _ReportReason()
    return LegacyReportContext(
        validate_enrichment=config.validate_enrichment,
        artifact_source=config.artifact_source,
        remote_artifacts=config.remote_artifacts,
        freshness_source=config.freshness_source,
        freshness_mode=config.freshness_mode,
        allow_cached_payload_uploads=config.freshness_disabled_explicitly,
        bep_files=tuple(str(path) for path in config.bep_json_files),
        freshness_selected_source=freshness_plan.selected_source,
        freshness_eligible_outputs=len(freshness_plan.eligible_outputs),
        freshness_cached_outputs=len(freshness_plan.cached_outputs),
        freshness_remote_only_outputs=len(freshness_plan.remote_only_outputs),
        freshness_skipped_outputs=freshness_skipped_count,
        freshness_missing_output_labels=len(freshness_plan.missing_output_labels),
        staging_dir=str(config.artifact_staging_dir),
        staged_testlogs_dirs=len(staged_roots),
        selected_remote_artifacts=len(freshness_plan.selected_artifact_outputs),
        staged_remote_artifacts=len(freshness_plan.staged_outputs),
        remote_artifacts_ignored=len(freshness_plan.blocked_labels),
        test_outputs_dirs=len(raw_discovery.outputs),
        reason_code=final_reason.code,
        reason=final_reason.message,
        next_steps=final_reason.next_steps,
    )


def _preflight_failure_reason(
    config: UploaderConfig,
    plan: FreshnessPlan,
    error: BaseException,
) -> _ReportReason:
    message = str(error)
    lower_message = message.lower()
    if not config.bep_json_files and (
        config.freshness_source == "bep"
        or config.artifact_source == "bep"
        or config.freshness_mode == "required"
    ):
        return _ReportReason(
            code="missing_bep_json",
            message=(
                "BEP freshness or artifact staging was required, but no BEP JSON "
                "was configured."
            ),
            next_steps=(
                "Pass --bep-json from the matching bazel test invocation.",
            ),
        )
    if plan.remote_only_outputs or "remote-only" in lower_message:
        return _ReportReason(
            code="bep_output_remote_only_without_downloader",
            message=(
                "BEP selected remote-only outputs that could not be materialized "
                "locally."
            ),
            next_steps=(
                "Enable --remote-artifacts=download with a downloader, or adjust "
                "Bazel remote download settings.",
            ),
        )
    if plan.cached_outputs and not plan.eligible_outputs:
        return _ReportReason(
            code="target_cached_by_bazel",
            message=(
                "Cached Bazel outputs did not satisfy the requested freshness "
                "contract."
            ),
            next_steps=(
                "Use the BEP from the exact matching bazel test invocation.",
            ),
        )
    return _ReportReason(
        code="upload_failed_unknown",
        message=message,
        next_steps=(
            "Correct the uploader configuration or freshness inputs and retry.",
        ),
    )
