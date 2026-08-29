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

from topt_runtime.runfiles import RunfileResolutionError, RunfilesResolver

from .config import UploaderConfig
from .discovery import DiscoveryResult, ScanRoot, count_tasks_by_payload_type
from .json_utils import strict_json_loads
from .models import FileResult, FileStatus, FileTask


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
    blocked_labels: frozenset[str] = frozenset()
    selected_artifact_outputs: frozenset[tuple[str, str]] = frozenset()
    staged_outputs: frozenset[tuple[str, str]] = frozenset()
    warning_codes: tuple[str, ...] = ()


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
        bep_files = tuple(
            _resolve_runtime_file(path, workspace=config.workspace)
            for path in config.bep_json_files
        )
        doctor_path = _resolve_doctor_runtime(config, resolver)
        doctor_runtime = _load_doctor_runtime(doctor_path, warning_codes)
        freshness_unavailable_is_error = config.freshness_mode != "optional" or staging_requested
        try:
            doctor_freshness = doctor_runtime._parse_bep_freshness(
                list(bep_files),
                unavailable_is_error=freshness_unavailable_is_error,
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
        logger.debug(
            "freshness ready: source=%s eligible=%d cached=%d remote_only=%d "
            "staged=%d",
            plan.selected_source,
            len(plan.eligible_outputs),
            len(plan.cached_outputs),
            len(plan.remote_only_outputs),
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
) -> FreshnessFilterResult:
    """Select current-invocation outputs and stamp worker tasks with labels."""
    selected_outputs = []
    task_label_by_output: dict[str, str] = {}
    skipped_output_keys: list[str] = []
    tasks_by_output: dict[str, list[FileTask]] = {}
    for task in discovery.tasks:
        tasks_by_output.setdefault(task.output_key or "", []).append(task)

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
        if target_label:
            task_label_by_output[output.output_key] = target_label
        if target_label in plan.blocked_labels:
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
        if (
            plan.selected_source == "bep"
            and freshness_mode == "required"
            and target_label in plan.missing_output_labels
        ):
            raise FreshnessError(
                "BEP required freshness cannot authorize "
                f"{output.path} because the fresh TestResult for {target_label} "
                "did not contain a mappable test.outputs reference"
            )
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
    return FreshnessFilterResult(filtered_discovery, tuple(sorted(set(skipped_output_keys))))


def validate_fresh_outputs_accounted(
    plan: FreshnessPlan,
    discovery: DiscoveryResult,
    results: Iterable[FileResult],
    *,
    expected_targets: Iterable[str],
    fail_on_error: bool,
) -> None:
    """Preserve the legacy fail-on-error check after all workers finish."""
    if not fail_on_error or plan.selected_source != "bep":
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
    expected_target_set = frozenset(expected_targets)
    if expected_target_set:
        unhandled_outputs = sorted(plan.eligible_outputs.difference(handled_pairs))
        if unhandled_outputs:
            label, output_key = unhandled_outputs[0]
            raise FreshnessError(
                "fresh expected test output produced no uploadable payloads: "
                f"{label} {output_key}",
                exit_code=1,
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
    )
    missing_output_labels = set(doctor_freshness.missing_output_mappings)
    if expected_targets:
        eligible_outputs = {pair for pair in eligible_outputs if pair[0] in expected_targets}
        cached_outputs = {pair for pair in cached_outputs if pair[0] in expected_targets}
        remote_outputs = tuple(item for item in remote_outputs if item.label in expected_targets)
        missing_output_labels.intersection_update(expected_targets)
        covered_labels = {
            label for label, _output_key in eligible_outputs.union(cached_outputs)
        }.union(item.label for item in remote_outputs).union(missing_output_labels)
        absent = sorted(expected_targets.difference(covered_labels))
        if absent:
            raise FreshnessError(
                "expected target output is neither fresh nor exclusively cached in "
                f"BEP: {absent[0]} (no TestResult matched this target)"
            )
        missing_expected = sorted(expected_targets.intersection(missing_output_labels))
        if missing_expected:
            raise FreshnessError(
                "expected target output is neither fresh nor exclusively cached in "
                f"BEP: {missing_expected[0]} (the fresh TestResult did not contain "
                "a mappable test.outputs reference)"
            )

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
        eligibility_enabled=selected_source == "bep",
        eligible_outputs=frozenset(eligible_outputs),
        cached_outputs=frozenset(cached_outputs),
        remote_only_outputs=remote_outputs,
        missing_output_labels=frozenset(missing_output_labels),
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
    metadata_file = output_dir / "bazel_target_metadata.json"
    try:
        value = strict_json_loads(metadata_file.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    label = value.get("bazel.target") if isinstance(value, dict) else None
    return label if isinstance(label, str) and label else None


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
