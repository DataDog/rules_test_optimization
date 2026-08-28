# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Single-process uploader orchestration around the independent file workers."""

from __future__ import annotations

from dataclasses import replace
import logging
from pathlib import Path
import sys
import time
from typing import Callable, TextIO

from topt_runtime.runfiles import RunfilesResolver

from .config import ConfigError, UploaderConfig, validate_upload_credentials
from .coordinator import (
    CoordinatorOutcome,
    CoordinatorSettings,
    emit_outcome,
    execute_discovery,
)
from .discovery import (
    DiscoveryError,
    DiscoveryResult,
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
    filter_discovery_for_freshness,
    prepare_freshness,
    validate_fresh_outputs_accounted,
)
from .locking import WorkspaceLock, WorkspaceLockError
from .logging_utils import redact_url
from .models import PayloadType
from .reporting import AggregateReport, LegacyReportContext
from .resources import ResourceInputs, load_resources
from .temporary import TemporaryDirectoryError
from .worker_pool import WorkerPoolError


_CONTROLLED_ERRORS = (
    ConfigError,
    DiscoveryError,
    ExpectedTargetsError,
    FreshnessError,
    TemporaryDirectoryError,
    WorkerPoolError,
    WorkspaceLockError,
)


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
    workspace_lock = WorkspaceLock(config.workspace)
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
    expected_plan = ExpectedTargetsPlan()
    freshness_plan = FreshnessPlan()
    preparation = None
    raw_discovery = _empty_discovery()
    filtered_discovery = raw_discovery
    freshness_skipped = 0
    outcome: CoordinatorOutcome | None = None
    forced_reason: tuple[str, str, tuple[str, ...]] | None = None

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

    try:
        # acquire() returns the held lock and raises on conflicts. The public
        # wrapper releases it only after this function emits the final report.
        if workspace_lock.acquire():
            expected_plan = load_expected_targets(
                static_targets=config.rule.expected_targets,
                expected_targets_file_paths=(
                    config.rule.expected_targets_file_path,
                    config.rule.expected_targets_file_short_path,
                ),
                resolver=resolver,
            )
            local_root = resolve_local_testlogs_root(
                explicit=config.testlogs_dir,
                workspace=config.workspace,
                cwd=Path.cwd(),
            )
            preparation = prepare_freshness(
                config,
                resolver=resolver,
                local_testlogs_root=local_root,
                expected_targets=expected_plan.targets,
                logger=logger,
            )
            freshness_plan = preparation.plan
            logger.debug(
                "freshness prepared: selected_source=%s scan_roots=%s "
                "staged_roots=%s eligible=%d cached=%d remote_only=%d",
                freshness_plan.selected_source,
                tuple(str(root.path) for root in preparation.scan_roots),
                tuple(str(path) for path in preparation.staged_roots),
                len(freshness_plan.eligible_outputs),
                len(freshness_plan.cached_outputs),
                len(freshness_plan.remote_only_outputs),
            )
            expected_target_labels = frozenset(expected_plan.targets)
            cached_target_labels = frozenset(
                label for label, _output_key in freshness_plan.cached_outputs
            )
            all_expected_outputs_cached = bool(
                expected_target_labels
                and cached_target_labels == expected_target_labels
                and not freshness_plan.eligible_outputs
                and not freshness_plan.remote_only_outputs
                and not freshness_plan.missing_output_labels
            )
            if (
                not preparation.scan_roots
                and config.fail_on_error
                and not all_expected_outputs_cached
            ):
                raise DiscoveryError(
                    "FAIL_ON_ERROR is set and no local or staged testlogs root was found"
                )
            selected_output_keys = {
                output_key
                for _label, output_key in freshness_plan.selected_artifact_outputs
            }
            for output_key in sorted(selected_output_keys):
                logger.debug("freshness eligible output_key=%s", output_key)

            def discover() -> DiscoveryResult:
                return discover_file_tasks(
                    preparation.scan_roots,
                    max_depth=config.max_depth,
                    staged_output_keys=selected_output_keys,
                )

            if all_expected_outputs_cached:
                raw_discovery = _empty_discovery()
                logger.debug(
                    "all expected target outputs were cached; skipping discovery wait"
                )
            elif preparation.scan_roots:
                quiescence = wait_for_quiescence(
                    discover,
                    quiescent_seconds=config.quiescent_sec,
                    max_wait_seconds=config.max_wait_sec,
                )
                raw_discovery = quiescence.discovery
                logger.debug(
                    "discovery settled: reason=%s elapsed=%.2fs outputs=%d files=%d",
                    quiescence.reason,
                    quiescence.elapsed_seconds,
                    len(raw_discovery.outputs),
                    len(raw_discovery.tasks),
                )
            else:
                raw_discovery = discover()
                logger.debug("no local or staged testlogs roots were found")

            expected_discovery = select_expected_outputs(
                raw_discovery,
                expected_plan,
                allow_missing=freshness_plan.selected_source == "bep",
            )
            freshness_result = filter_discovery_for_freshness(
                expected_discovery,
                freshness_plan,
                freshness_mode=config.freshness_mode,
            )
            filtered_discovery = freshness_result.discovery
            freshness_skipped = len(freshness_result.skipped_outputs)
            for output_key in freshness_result.skipped_outputs:
                logger.debug("freshness skipped output_key=%s", output_key)
            if filtered_discovery.tasks:
                validate_upload_credentials(config)
            else:
                logger.debug("credential validation skipped: no upload tasks")
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
            outcome = execute_discovery(
                filtered_discovery,
                settings=CoordinatorSettings.from_config(config),
                endpoints=endpoints,
                resources=resources,
                logger=logger,
                transport_factory=transport_factory,
                clock=clock,
            )
            outcome = CoordinatorOutcome(
                replace(
                    outcome.report,
                    discovered_by_type=raw_discovery.discovered_by_type,
                ),
                outcome.initialization_warning_codes,
            )
            if outcome.report.exit_code == 130:
                forced_reason = (
                    "interrupted",
                    "Uploader interrupted after active workers finished.",
                    ("Re-run the uploader to process retained and cancelled files.",),
                )
            else:
                try:
                    validate_fresh_outputs_accounted(
                        freshness_plan,
                        filtered_discovery,
                        outcome.report.results,
                        expected_targets=expected_plan.targets,
                        fail_on_error=config.fail_on_error,
                    )
                except FreshnessError as exc:
                    logger.error("%s", exc)
                    outcome = CoordinatorOutcome(
                        replace(outcome.report, exit_code=exc.exit_code),
                        outcome.initialization_warning_codes,
                    )
                    forced_reason = (
                        "fresh_output_without_payloads",
                        str(exc),
                        ("Inspect the fresh test.outputs payload directories.",),
                    )

            if not raw_discovery.tasks:
                if all_expected_outputs_cached:
                    forced_reason = (
                        "ok",
                        "All expected target outputs were cached; nothing was uploaded.",
                        (),
                    )
                elif tests_executed(preparation.scan_roots) and config.fail_on_error:
                    outcome = CoordinatorOutcome(
                        replace(outcome.report, exit_code=1),
                        outcome.initialization_warning_codes,
                    )
                    forced_reason = (
                        "tests_ran_without_payloads",
                        "Tests ran but no payload files were found.",
                        (
                            "Check that DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true is set.",
                        ),
                    )
    except _CONTROLLED_ERRORS as exc:
        exit_code = exc.exit_code if isinstance(exc, FreshnessError) else 2
        logger.error("%s", exc)
        outcome = CoordinatorOutcome(
            _empty_report(
                config,
                exit_code=exit_code,
                elapsed_seconds=max(0.0, clock() - started),
                discovery=raw_discovery,
            )
        )
        forced_reason = _preflight_failure_reason(
            config,
            freshness_plan,
            exc,
        )
    finally:
        if preparation is not None:
            try:
                preparation.cleanup()
            except FreshnessError as exc:
                logger.error("failed to clean BEP staging: %s", exc)
                cleanup_warning = ("staging_cleanup_failed",)
                if outcome is None:
                    empty = _empty_report(
                        config,
                        exit_code=2,
                        elapsed_seconds=max(0.0, clock() - started),
                        discovery=raw_discovery,
                    )
                    warning_codes = tuple(
                        dict.fromkeys(
                            empty.initialization_warning_codes + cleanup_warning
                        )
                    )
                    outcome = CoordinatorOutcome(
                        replace(
                            empty,
                            initialization_warning_codes=warning_codes,
                        ),
                        warning_codes,
                    )
                else:
                    warning_codes = tuple(
                        dict.fromkeys(
                            outcome.initialization_warning_codes + cleanup_warning
                        )
                    )
                    cleanup_exit_code = (
                        outcome.report.exit_code
                        if outcome.report.exit_code != 0
                        else 2
                    )
                    outcome = CoordinatorOutcome(
                        replace(
                            outcome.report,
                            exit_code=cleanup_exit_code,
                            initialization_warning_codes=warning_codes,
                        ),
                        warning_codes,
                    )
                if outcome.report.exit_code == 2 and (
                    forced_reason is None or forced_reason[0] in {"", "ok"}
                ):
                    forced_reason = (
                        "staging_cleanup_failed",
                        str(exc),
                        ("Remove only the uploader-owned staging run directory.",),
                    )
            else:
                logger.debug("BEP staging cleanup completed")

    assert outcome is not None
    report_context = _legacy_context(
        config,
        freshness_plan=freshness_plan,
        raw_discovery=raw_discovery,
        staged_roots=(preparation.staged_roots if preparation is not None else ()),
        freshness_skipped=freshness_skipped,
        forced_reason=forced_reason,
    )
    logger.debug(
        "emitting final report: exit_code=%d results=%d warnings=%s",
        outcome.report.exit_code,
        len(outcome.report.results),
        outcome.report.initialization_warning_codes,
    )
    emit_outcome(
        outcome,
        stream=stream if stream is not None else sys.stdout,
        report_json=config.report_json,
        legacy_report_context=report_context,
    )
    return outcome.report.exit_code


def _empty_discovery() -> DiscoveryResult:
    return DiscoveryResult(
        outputs=(),
        tasks=(),
        discovered_by_type=tuple((payload_type, 0) for payload_type in PayloadType),
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
    freshness_skipped: int,
    forced_reason: tuple[str, str, tuple[str, ...]] | None,
) -> LegacyReportContext:
    reason_code, reason, next_steps = forced_reason or ("", "", ())
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
        freshness_skipped_outputs=freshness_skipped,
        freshness_missing_output_labels=len(freshness_plan.missing_output_labels),
        staging_dir=str(config.artifact_staging_dir),
        staged_testlogs_dirs=len(staged_roots),
        selected_remote_artifacts=len(freshness_plan.selected_artifact_outputs),
        staged_remote_artifacts=len(freshness_plan.staged_outputs),
        remote_artifacts_ignored=len(freshness_plan.blocked_labels),
        test_outputs_dirs=len(raw_discovery.outputs),
        reason_code=reason_code,
        reason=reason,
        next_steps=next_steps,
    )


def _preflight_failure_reason(
    config: UploaderConfig,
    plan: FreshnessPlan,
    error: BaseException,
) -> tuple[str, str, tuple[str, ...]]:
    message = str(error)
    lower_message = message.lower()
    if not config.bep_json_files and (
        config.freshness_source == "bep"
        or config.artifact_source == "bep"
        or config.freshness_mode == "required"
    ):
        return (
            "missing_bep_json",
            "BEP freshness or artifact staging was required, but no BEP JSON "
            "was configured.",
            ("Pass --bep-json from the matching bazel test invocation.",),
        )
    if plan.remote_only_outputs or "remote-only" in lower_message:
        return (
            "bep_output_remote_only_without_downloader",
            "BEP selected remote-only outputs that could not be materialized locally.",
            (
                "Enable --remote-artifacts=download with a downloader, or adjust Bazel remote download settings.",
            ),
        )
    if plan.cached_outputs and not plan.eligible_outputs:
        return (
            "target_cached_by_bazel",
            "Cached Bazel outputs did not satisfy the requested freshness contract.",
            ("Use the BEP from the exact matching bazel test invocation.",),
        )
    return (
        "upload_failed_unknown",
        message,
        ("Correct the uploader configuration or freshness inputs and retry.",),
    )
