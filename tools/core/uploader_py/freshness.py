# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Pre-worker BEP staging and freshness selection.

The doctor remains the source of truth for the non-trivial BEP and artifact
carrier formats. This module loads that runtime once, snapshots its result in
immutable uploader models, and keeps all filesystem and policy decisions out
of worker threads.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import importlib.util
import json
import logging
from pathlib import Path
import sys
from types import ModuleType
from typing import Iterable

from topt_runtime.bep_execution import BepTestExecution, exclusively_cached_labels, missing_test_shards, test_result_event_count
from topt_runtime.runfiles import RunfileResolutionError, RunfilesResolver

from .config import UploaderConfig
from .discovery import DiscoveryResult, ScanRoot, count_tasks_by_payload_type, read_target_label
from .json_utils import strict_json_loads
from .models import FileResult, FileStatus, FileTask, PayloadType


class FreshnessError(RuntimeError):
    """Freshness or staging could not authorize a safe uploader run."""

    def __init__(self, message: str, *, exit_code: int = 2) -> None:
        super().__init__(message)
        self.exit_code = exit_code


@dataclass(frozen=True)
class RemoteOutput:
    label: str
    output_key: str
    artifact: str


@dataclass(frozen=True)
class FreshnessPlan:
    """Immutable authorization snapshot used by discovery and postflight checks."""

    selected_source: str = "none"
    eligibility_enabled: bool = False
    eligible_outputs: frozenset[tuple[str, str]] = frozenset()
    cached_outputs: frozenset[tuple[str, str]] = frozenset()
    remote_only_outputs: tuple[RemoteOutput, ...] = ()
    missing_output_labels: frozenset[str] = frozenset()
    skipped_targets: frozenset[str] = frozenset()
    blocked_labels: frozenset[str] = frozenset()
    selected_artifact_outputs: frozenset[tuple[str, str]] = frozenset()
    staged_outputs: frozenset[tuple[str, str]] = frozenset()
    warning_codes: tuple[str, ...] = ()
    executions: tuple[BepTestExecution, ...] = ()
    require_test_results: bool = False
    ambiguous_outputs: frozenset[str] = frozenset()
    ambiguous_labels: frozenset[str] = frozenset()


@dataclass(frozen=True)
class FreshnessPreparation:
    """Freshness plan plus any staged artifacts owned by this invocation."""

    plan: FreshnessPlan
    scan_roots: tuple[ScanRoot, ...]
    staged_roots: tuple[Path, ...] = ()
    _doctor_runtime: ModuleType | None = None
    _staged_artifacts: tuple[object, ...] = ()
    _staging_base_path: Path | None = None

    def cleanup(self) -> None:
        """Remove only per-invocation staging roots owned by the doctor."""
        if not self._staged_artifacts:
            return
        assert self._doctor_runtime is not None
        assert self._staging_base_path is not None
        try:
            self._doctor_runtime._cleanup_staged_bep_run_roots(
                self._staged_artifacts,
                staging_base=self._staging_base_path,
            )
        except SystemExit as exc:
            raise FreshnessError(_doctor_failure(self._doctor_runtime, exc)) from exc


@dataclass(frozen=True)
class FreshnessFilterResult:
    discovery: DiscoveryResult
    skipped_outputs: tuple[str, ...] = ()
    identified_targets: tuple[str, ...] = ()
    ambiguous_outputs: tuple[str, ...] = ()


def prepare_freshness(
    config: UploaderConfig,
    *,
    resolver: RunfilesResolver,
    local_testlogs_root: Path | None,
    expected_targets: Iterable[str] = (),
    logger: logging.Logger | None = None,
) -> FreshnessPreparation:
    """Parse freshness and optionally stage BEP artifacts before discovery."""
    expected_target_set = frozenset(expected_targets)
    warning_codes: list[str] = []
    bep_configured = bool(config.bep_json_files)
    staging_requested = config.artifact_source == "bep" or (
        config.artifact_source == "auto" and config.remote_artifacts != "disabled"
    )
    if config.artifact_source == "bep" and not bep_configured:
        raise FreshnessError(
            "--artifact-source=bep requires --bep-json or "
            "DD_TEST_OPTIMIZATION_BEP_JSON"
        )

    selected_source = _select_source(config, bep_configured, warning_codes)
    bep_processing_required = selected_source == "bep" or staging_requested
    doctor_runtime: ModuleType | None = None
    staged_artifacts: tuple[object, ...] = ()
    staging_base_path: Path | None = None
    selected_artifact_outputs: set[tuple[str, str]] = set()
    blocked_labels: set[str] = set()
    doctor_freshness = None

    if bep_processing_required:
        if not bep_configured:
            raise FreshnessError("BEP artifact staging requires a configured BEP JSON file")
        try:
            bep_files = tuple(
                _resolve_runtime_file(path, workspace=config.workspace)
                for path in config.bep_json_files
            )
        except FreshnessError:
            if config.freshness_mode != "optional" or staging_requested:
                raise
            warning_codes.append("bep_freshness_unavailable")
            selected_source = "none"
            bep_processing_required = False
            bep_files = ()
    if bep_processing_required:
        doctor_path = _resolve_doctor_runtime(config, resolver)
        doctor_runtime = _load_doctor_runtime(doctor_path, warning_codes)
        freshness_unavailable_is_error = config.freshness_mode != "optional" or staging_requested
        try:
            doctor_freshness = doctor_runtime._parse_bep_freshness(
                list(bep_files),
                unavailable_is_error=freshness_unavailable_is_error,
                workspace=config.workspace,
            )
            if doctor_freshness is not None:
                if staging_requested:
                    selected_artifact_outputs = set(
                        doctor_runtime._selected_bep_artifact_outputs(
                            doctor_freshness,
                            config.workspace,
                            config.remote_artifacts,
                        )
                    )
                    blocked_labels = set(
                        doctor_runtime._blocked_bep_artifact_labels(
                            doctor_freshness,
                            config.remote_artifacts,
                        )
                    )
                    staging_base_path = config.artifact_staging_dir.resolve()
                    staged_artifacts = tuple(
                        doctor_runtime._stage_bep_artifacts(
                            doctor_freshness,
                            workspace=config.workspace,
                            staging_dir=staging_base_path,
                            remote_artifacts=config.remote_artifacts,
                            downloader=(
                                str(config.bep_artifact_downloader)
                                if config.bep_artifact_downloader is not None
                                else ""
                            ),
                            downloader_timeout_sec=(
                                config.bep_artifact_downloader_timeout_sec
                            ),
                        )
                    )
                    doctor_runtime._apply_staged_bep_artifacts_to_freshness(
                        doctor_freshness,
                        list(staged_artifacts),
                    )
        except SystemExit as exc:
            raise FreshnessError(_doctor_failure(doctor_runtime, exc)) from exc
        except BaseException:
            # Staging must not survive interrupts or unexpected doctor errors.
            if staged_artifacts and staging_base_path is not None:
                doctor_runtime._cleanup_staged_bep_run_roots(
                    staged_artifacts,
                    staging_base=staging_base_path,
                )
            raise

    try:
        plan = _build_plan(
            config,
            selected_source=selected_source,
            doctor_freshness=doctor_freshness,
            selected_artifact_outputs=selected_artifact_outputs,
            blocked_labels=blocked_labels,
            expected_targets=expected_target_set,
            warning_codes=warning_codes,
            staged_outputs={
                (str(item.label), str(item.output_key)) for item in staged_artifacts
            },
        )
    except BaseException:
        # Planning failures must obey the same ownership cleanup contract.
        if staged_artifacts and doctor_runtime is not None and staging_base_path is not None:
            doctor_runtime._cleanup_staged_bep_run_roots(
                staged_artifacts,
                staging_base=staging_base_path,
            )
        raise

    scan_roots: list[ScanRoot] = []
    if local_testlogs_root is not None:
        scan_roots.append(ScanRoot(local_testlogs_root))
    staged_roots = tuple(
        sorted(
            {Path(item.staging_root).resolve() for item in staged_artifacts},
            key=lambda path: path.as_posix(),
        )
    )
    scan_roots.extend(ScanRoot(root, staged=True) for root in staged_roots)
    if logger is not None:
        for artifact in staged_artifacts:
            logger.debug(
                "BEP artifact staging selected output key: %s",
                artifact.output_key,
            )
        logger.debug(
            "freshness ready: source=%s eligible=%d cached=%d remote_only=%d "
            "skipped_targets=%d staged=%d",
            plan.selected_source,
            len(plan.eligible_outputs),
            len(plan.cached_outputs),
            len(plan.remote_only_outputs),
            len(plan.skipped_targets),
            len(plan.staged_outputs),
        )
        for warning in plan.warning_codes:
            logger.warning("preflight warning_code=%s", warning)
    return FreshnessPreparation(
        plan=plan,
        scan_roots=tuple(scan_roots),
        staged_roots=staged_roots,
        _doctor_runtime=doctor_runtime,
        _staged_artifacts=staged_artifacts,
        _staging_base_path=staging_base_path,
    )


def filter_discovery_for_freshness(
    discovery: DiscoveryResult,
    plan: FreshnessPlan,
    *,
    freshness_mode: str,
    expected_targets: Iterable[str] = (),
) -> FreshnessFilterResult:
    """Select current-invocation outputs and stamp worker tasks with labels."""
    selected_outputs = []
    task_label_by_output: dict[str, str] = {}
    skipped_output_keys: list[str] = []
    tasks_by_output: dict[str, list[FileTask]] = {}
    for task in discovery.tasks:
        tasks_by_output.setdefault(task.output_key or "", []).append(task)

    labels_by_key: dict[str, set[str]] = {}
    for label, key in plan.eligible_outputs:
        labels_by_key.setdefault(key, set()).add(label)
    # Discover core-only test evidence before authorizing sibling shards. A
    # coverage-only or hierarchy-only shard must reach postflight accounting,
    # regardless of discovery order, rather than abort the usable test shard.
    core_test_keys: set[str] = set()
    known_core_labels = set(expected_targets)
    metadata_exists: dict[str, bool] = {}
    for output in discovery.outputs:
        metadata_path = output.path / "bazel_target_metadata.json"
        metadata_exists[output.output_key] = metadata_path.exists()
        candidates = labels_by_key.get(output.output_key, set())
        if plan.eligibility_enabled and len(candidates) == 1 and not metadata_exists[output.output_key] and not metadata_path.is_symlink():
            if any(_recognized_test_source(task) for task in tasks_by_output.get(output.output_key, []) if task.payload_type is PayloadType.TEST):
                core_test_keys.add(output.output_key)
                known_core_labels.update(candidates)
    relevant_ambiguities: set[str] = set()
    identified_targets: set[str] = set()
    for output in discovery.outputs:
        tasks = tasks_by_output.get(output.output_key, [])
        explicit_labels = {
            task.target_label for task in tasks if task.target_label is not None
        }
        target_label = (
            sorted(explicit_labels)[0]
            if len(explicit_labels) == 1
            else _read_target_label(output.path)
        )
        sidecar_label = target_label
        metadata_path = output.path / "bazel_target_metadata.json"
        if plan.eligibility_enabled and (metadata_path.is_symlink() or (metadata_exists[output.output_key] and not target_label)):
            if freshness_mode == "required":
                raise FreshnessError("BEP required freshness cannot authorize output because bazel.target metadata is missing or unsafe")
            skipped_output_keys.append(output.output_key)
            continue
        candidates = labels_by_key.get(output.output_key, set())
        recognized_core_test = False
        if not target_label and len(candidates) == 1:
            # Core-only consumers have no sidecar. Read one candidate payload
            # at a time until a typed test is found; normal companion targets
            # retain their sidecar fast path and worker-owned JSON parsing.
            recognized_core_test = output.output_key in core_test_keys
            if candidates.intersection(known_core_labels):
                target_label = next(iter(candidates))
        pair = (target_label, output.output_key)
        if (sidecar_label or recognized_core_test) and pair in plan.eligible_outputs:
            identified_targets.add(target_label)
        if target_label:
            task_label_by_output[output.output_key] = target_label
        if output.output_key in plan.ambiguous_outputs:
            if sidecar_label or any(_recognized_test_source(task) for task in tasks if task.payload_type is PayloadType.TEST):
                relevant_ambiguities.add(output.output_key)
            skipped_output_keys.append(output.output_key)
            continue
        if not tasks:
            continue
        if target_label in plan.blocked_labels or target_label in plan.ambiguous_labels:
            skipped_output_keys.append(output.output_key)
            continue
        if not plan.eligibility_enabled:
            selected_outputs.append(output)
            continue
        if not target_label:
            if plan.selected_source == "bep" and freshness_mode == "required":
                raise FreshnessError(
                    "BEP required freshness cannot authorize "
                    f"{output.path} because bazel.target metadata is missing"
                )
            skipped_output_keys.append(output.output_key)
            continue
        pair = (target_label, output.output_key)
        if pair in plan.eligible_outputs:
            selected_outputs.append(output)
            continue
        skipped_output_keys.append(output.output_key)

    selected_keys = {output.output_key for output in selected_outputs}
    selected_tasks = tuple(
        replace(
            task,
            target_label=task.target_label
            or task_label_by_output.get(task.output_key or ""),
        )
        for task in discovery.tasks
        if (task.output_key or "") in selected_keys
    )
    filtered_discovery = DiscoveryResult(
        outputs=tuple(selected_outputs),
        tasks=selected_tasks,
        discovered_by_type=count_tasks_by_payload_type(selected_tasks),
        warning_codes=tuple(
            dict.fromkeys(
                discovery.warning_codes
                + plan.warning_codes
                + (("freshness_outputs_skipped",) if skipped_output_keys else ())
            )
        ),
    )
    return FreshnessFilterResult(filtered_discovery, tuple(sorted(set(skipped_output_keys))), tuple(sorted(identified_targets)), tuple(sorted(relevant_ambiguities)))


def _recognized_test_source(task: FileTask) -> bool:
    # Core-only fallback and ambiguous outputs lack a trusted sidecar. This
    # bounded one-file-at-a-time probe is absent from the companion fast path.
    try:
        return test_result_event_count(strict_json_loads(task.source_path.read_text(encoding="utf-8-sig"))) > 0
    except (OSError, UnicodeError, json.JSONDecodeError):
        return False


def validate_fresh_outputs_accounted(
    plan: FreshnessPlan,
    discovery: DiscoveryResult,
    results: Iterable[FileResult],
    *,
    expected_targets: Iterable[str],
    fail_on_error: bool,
    identified_targets: Iterable[str] = (),
    ambiguous_outputs: Iterable[str] | None = None,
) -> str | None:
    """Validate BEP coverage after workers have processed usable outputs."""
    if plan.selected_source != "bep":
        return
    expected_target_set = frozenset(expected_targets)
    relevant_ambiguities = set(plan.ambiguous_outputs if ambiguous_outputs is None else ambiguous_outputs)
    if plan.ambiguous_labels.intersection(expected_target_set.union(identified_targets)):
        raise FreshnessError("BEP freshness is ambiguous: target reported as both platform-skipped and executed")
    if expected_target_set:
        relevant_ambiguities.update(key for execution in plan.executions if execution.identity[1] in expected_target_set for key in execution.output_keys if key in plan.ambiguous_outputs)
    if relevant_ambiguities:
        raise FreshnessError("BEP freshness has ambiguous execution provenance for " + sorted(relevant_ambiguities)[0])
    if expected_target_set:
        represented_labels = {
            label for label, _output_key in plan.eligible_outputs
        }.union(
            label for label, _output_key in plan.cached_outputs
        ).union(
            output.label for output in plan.remote_only_outputs
        ).union(plan.skipped_targets).union(exclusively_cached_labels(plan.executions))
        missing_expected = sorted(expected_target_set.difference(represented_labels))
        if missing_expected:
            label = missing_expected[0]
            detail = (
                "the fresh TestResult did not contain a mappable test.outputs reference"
                if label in plan.missing_output_labels
                else "no TestResult matched this target"
            )
            raise FreshnessError(
                "expected target output is neither fresh nor exclusively cached in "
                f"BEP: {label} ({detail})",
                exit_code=1,
            )

    enforce_test_results = fail_on_error or plan.require_test_results
    remote_outputs = tuple(output for output in plan.remote_only_outputs
        if not expected_target_set or output.label in expected_target_set)
    if remote_outputs and enforce_test_results:
        raise FreshnessError("BEP references remote-only test outputs for " + remote_outputs[0].label + ", but local test.outputs was not found")
    results = tuple(results)
    if plan.executions:
        results_by_id = {result.task_id: result for result in results}
        proven_outputs = set()
        selected_labels = set(expected_target_set).union(identified_targets)
        for task in discovery.tasks:
            result = results_by_id.get(task.task_id)
            if task.target_label and result is not None and task.payload_type is PayloadType.TEST and result.test_events > 0:
                selected_labels.add(task.target_label)
            if result is not None and task.payload_type is PayloadType.TEST and result.test_events > 0:
                if result.status is FileStatus.SUCCEEDED or result.requests_attempted > 0:
                    # Transport acknowledgement has its own error policy. A
                    # rejected request still contains identified test evidence.
                    proven_outputs.add((task.target_label, task.output_key))
        missing = missing_test_shards(plan.executions, proven_outputs, selected_labels)
        if missing:
            invocation, label, configuration, run, shard = missing[0]
            message = ("fresh shard produced no test-result evidence: "
                f"{label} configuration={configuration!r} run={run} shard={shard} invocation={invocation}")
            if enforce_test_results:
                raise FreshnessError(message, exit_code=1)
            return message
        invalid_tests = [results_by_id[task.task_id] for task in discovery.tasks
            if task.payload_type is PayloadType.TEST and task.target_label in selected_labels and task.task_id in results_by_id
            and results_by_id[task.task_id].status is FileStatus.FAILED
            and results_by_id[task.task_id].requests_attempted == 0]
        if invalid_tests:
            message = "fresh test payload failed before delivery: " + invalid_tests[0].source_path
            if enforce_test_results:
                raise FreshnessError(message, exit_code=1)
            return message
        return
    if not enforce_test_results:
        return
    non_skipped_task_ids = {
        result.task_id
        for result in results
        if result.status is not FileStatus.SKIPPED
    }
    handled_pairs = {
        (task.target_label, task.output_key)
        for task in discovery.tasks
        if task.task_id in non_skipped_task_ids
        and task.target_label is not None
        and task.output_key is not None
    }
    if expected_target_set:
        # Bazel may publish several TestResult outputs for one target while only
        # some attempts contain payloads. The target is accounted for once any
        # of its fresh attempts produced a non-skipped worker result.
        handled_labels = {label for label, _output_key in handled_pairs}
        unhandled_outputs = sorted(
            pair for pair in plan.eligible_outputs if pair[0] not in handled_labels
        )
        if unhandled_outputs:
            label, output_key = unhandled_outputs[0]
            raise FreshnessError(
                "fresh expected test output produced no uploadable payloads: "
                f"{label} {output_key}",
                exit_code=1,
            )
        remote_outputs = tuple(
            output
            for output in plan.remote_only_outputs
            if output.label in expected_target_set
        )
        if remote_outputs:
            raise FreshnessError(
                "BEP references remote-only test outputs for "
                f"{remote_outputs[0].label}, but local test.outputs was not found"
            )
        return
    if plan.eligible_outputs and not handled_pairs:
        raise FreshnessError(
            f"BEP reported {len(plan.eligible_outputs)} fresh test output(s), "
            "but none produced uploadable payloads",
            exit_code=1,
        )


def _select_source(
    config: UploaderConfig,
    bep_configured: bool,
    warning_codes: list[str],
) -> str:
    if config.freshness_mode == "disabled":
        if bep_configured:
            warning_codes.append("freshness_disabled_bep_ignored")
        if config.execution_log_json is not None:
            warning_codes.append("freshness_disabled_execution_log_ignored")
        return "none"
    freshness_required = config.freshness_mode == "required" or (
        config.freshness_mode == "auto" and config.ci
    )
    if config.freshness_source == "bep":
        if bep_configured:
            return "bep"
        if freshness_required:
            raise FreshnessError(
                "BEP freshness filtering is required but no BEP JSON file was configured"
            )
        warning_codes.append("bep_freshness_not_configured")
        return "none"
    if config.freshness_source == "execution_log":
        if config.execution_log_json is not None:
            return "execution_log"
        if freshness_required:
            raise FreshnessError(
                "execution-log freshness filtering is required but no execution log "
                "was configured"
            )
        warning_codes.append("execution_log_freshness_not_configured")
        return "none"
    if bep_configured:
        return "bep"
    if config.execution_log_json is not None:
        return "execution_log"
    if freshness_required:
        raise FreshnessError(
            "freshness filtering is required in CI or required mode, but no BEP "
            "or execution log was configured"
        )
    warning_codes.append("freshness_not_configured")
    return "none"


def _build_plan(
    config: UploaderConfig,
    *,
    selected_source: str,
    doctor_freshness: object | None,
    selected_artifact_outputs: set[tuple[str, str]],
    blocked_labels: set[str],
    expected_targets: frozenset[str],
    warning_codes: list[str],
    staged_outputs: set[tuple[str, str]],
) -> FreshnessPlan:
    if selected_source == "execution_log":
        assert config.execution_log_json is not None
        execution_log = _resolve_runtime_file(
            config.execution_log_json,
            workspace=config.workspace,
        )
        eligible_outputs = _parse_execution_log(execution_log)
        if expected_targets:
            eligible_outputs = {pair for pair in eligible_outputs if pair[0] in expected_targets}
        return FreshnessPlan(
            selected_source="execution_log",
            eligibility_enabled=True,
            eligible_outputs=frozenset(eligible_outputs),
            warning_codes=tuple(dict.fromkeys(warning_codes)),
        )

    if doctor_freshness is None:
        return FreshnessPlan(
            selected_source="none",
            selected_artifact_outputs=frozenset(selected_artifact_outputs),
            blocked_labels=frozenset(blocked_labels),
            warning_codes=tuple(dict.fromkeys(warning_codes)),
        )

    eligible_outputs = set(doctor_freshness.eligible_outputs)
    cached_outputs = set(doctor_freshness.cached_outputs)
    remote_outputs = tuple(
        RemoteOutput(item.label, item.output_key, item.artifact)
        for item in doctor_freshness.remote_only_outputs
        if item.output_key not in doctor_freshness.ambiguous_outputs
        and item.label not in doctor_freshness.ambiguous_labels
    )
    missing_output_labels = set(doctor_freshness.missing_output_mappings)
    skipped_targets = set(doctor_freshness.skipped_targets)
    if expected_targets:
        eligible_outputs = {pair for pair in eligible_outputs if pair[0] in expected_targets}
        cached_outputs = {pair for pair in cached_outputs if pair[0] in expected_targets}
        remote_outputs = tuple(item for item in remote_outputs if item.label in expected_targets)
        missing_output_labels.intersection_update(expected_targets)
        skipped_targets.intersection_update(expected_targets)

    if remote_outputs:
        if config.freshness_mode == "required" or config.remote_artifacts == "required":
            first_remote_output = remote_outputs[0]
            raise FreshnessError(
                "BEP references remote-only test outputs for "
                f"{first_remote_output.label}, but local test.outputs was not found"
            )
        warning_codes.append("bep_remote_only_outputs_skipped")

    return FreshnessPlan(
        selected_source=selected_source,
        executions=tuple(doctor_freshness.executions),
        require_test_results=config.freshness_mode == "required",
        ambiguous_outputs=doctor_freshness.ambiguous_outputs,
        ambiguous_labels=doctor_freshness.ambiguous_labels,
        eligibility_enabled=selected_source == "bep",
        eligible_outputs=frozenset(eligible_outputs),
        cached_outputs=frozenset(cached_outputs),
        remote_only_outputs=remote_outputs,
        missing_output_labels=frozenset(missing_output_labels),
        skipped_targets=frozenset(skipped_targets),
        blocked_labels=frozenset(blocked_labels),
        selected_artifact_outputs=frozenset(selected_artifact_outputs),
        staged_outputs=frozenset(
            pair for pair in eligible_outputs if pair in staged_outputs
        ),
        warning_codes=tuple(dict.fromkeys(warning_codes)),
    )


def _parse_execution_log(path: Path) -> set[tuple[str, str]]:
    eligible: set[tuple[str, str]] = set()
    for line_number, raw_line in enumerate(_stream_execution_log(path), start=1):
        if not raw_line.strip():
            continue
        try:
            value = strict_json_loads(raw_line)
        except json.JSONDecodeError as exc:
            raise FreshnessError(
                f"invalid execution log JSON in {path}:{line_number}: {exc}"
            ) from exc
        if not isinstance(value, dict) or value.get("mnemonic", "") != "TestRunner":
            continue
        runner = value.get("runner", "")
        if value.get("cacheHit", False) is True or (
            isinstance(runner, str) and "cache hit" in runner.lower()
        ):
            continue
        label = value.get("targetLabel")
        if not isinstance(label, str) or not label:
            continue
        raw_outputs: list[object] = []
        listed = value.get("listedOutputs", [])
        if isinstance(listed, list):
            raw_outputs.extend(listed)
        actual = value.get("actualOutputs", [])
        if isinstance(actual, list):
            for item in actual:
                raw_outputs.append(item.get("path", "") if isinstance(item, dict) else "")
        for raw_output in raw_outputs:
            if not isinstance(raw_output, str):
                continue
            output_key = _execution_output_key(raw_output)
            if output_key:
                eligible.add((label, output_key))
    return eligible


def _stream_execution_log(path: Path) -> Iterable[str]:
    """Yield one action record at a time so large logs stay memory-bounded."""
    try:
        with path.open("r", encoding="utf-8-sig") as lines:
            yield from lines
    except (OSError, UnicodeError) as exc:
        raise FreshnessError(f"failed to read execution log JSON {path}: {exc}") from exc


def _execution_output_key(raw: str) -> str:
    normalized = raw.replace("\\", "/")
    if "/testlogs/" in normalized:
        normalized = normalized.rsplit("/testlogs/", 1)[1]
    if "/test.outputs/" in normalized:
        normalized = normalized.split("/test.outputs/", 1)[0] + "/test.outputs"
    elif not normalized.endswith("/test.outputs"):
        return ""
    return normalized.removeprefix("./").lstrip("/")


def _read_target_label(output_dir: Path) -> str | None:
    return read_target_label(output_dir)


def _resolve_runtime_file(path: Path, *, workspace: Path) -> Path:
    expanded = path.expanduser()
    candidates = (
        (expanded if expanded.is_absolute() else workspace / expanded),
        (expanded if expanded.is_absolute() else Path.cwd() / expanded),
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise FreshnessError(f"configured freshness file not found: {path}")


def _resolve_doctor_runtime(
    config: UploaderConfig,
    resolver: RunfilesResolver,
) -> Path:
    candidates = tuple(
        candidate
        for candidate in (
            config.rule.doctor_runtime_path,
            config.rule.doctor_runtime_short_path,
        )
        if candidate
    )
    if not candidates:
        raise FreshnessError("generated uploader config has no doctor runtime")
    try:
        return resolver.resolve_file(candidates)
    except RunfileResolutionError as exc:
        raise FreshnessError("doctor runtime could not be resolved from runfiles") from exc


def _load_doctor_runtime(path: Path, warning_codes: list[str]) -> ModuleType:
    name = f"_dd_topt_uploader_doctor_{id(warning_codes)}"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise FreshnessError(f"doctor runtime is not importable: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    module._warn = lambda _message: warning_codes.append("bep_runtime_warning")
    module._info = lambda _message: None
    return module


def _doctor_failure(doctor_runtime: ModuleType, exc: SystemExit) -> str:
    message = getattr(doctor_runtime, "_LAST_FAILURE_MESSAGE", "")
    return message or f"doctor BEP runtime failed with exit code {exc.code}"
