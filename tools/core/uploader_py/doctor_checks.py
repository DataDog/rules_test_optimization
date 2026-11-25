# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""The doctor's output checks in the uploader's run.

An uploader that names a doctor applies the doctor's checks to the outputs
that it selects, so that one `bazel run` validates and uploads. ddtest's
post-process applies them when it runs the invocation; this module applies
them when the Python uploader does, with the doctor's own functions and
messages, before any payload is sent and deleted.
"""

from __future__ import annotations

import contextlib
from dataclasses import dataclass
import importlib.util
import json
import logging
from pathlib import Path
import sys
from types import ModuleType
from typing import Any, Iterable, Mapping, TextIO

from topt_runtime.runfiles import RunfileResolutionError, RunfilesResolver

from .config import UploaderConfig
from .discovery import DiscoveredOutput
from .enrichment import ContextPlan, ContextRecord
from .freshness import FreshnessPreparation
from .models import FileTask


@dataclass(frozen=True)
class DoctorOutcome:
    """The checks' exit status and, when they failed, the report's reason."""

    exit_code: int
    reason_code: str = ""
    message: str = ""
    next_steps: tuple[str, ...] = ()


@dataclass(frozen=True)
class DoctorConfig:
    """The named doctor's configuration and the file it was read from."""

    document: dict[str, Any]
    path: Path


def load_doctor_config(config: UploaderConfig, resolver: RunfilesResolver,
                       logger: logging.Logger) -> DoctorConfig | None:
    """The configuration of the doctor that the rule names, or None.

    A configuration that cannot be read skips the checks with a warning.
    """
    candidates = tuple(path for path in (config.rule.doctor_config_path, config.rule.doctor_config_short_path) if path)
    if not candidates:
        return None
    try:
        path = resolver.resolve_file(candidates)
        document = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(document, dict):
            raise ValueError("not a JSON object")
    except (RunfileResolutionError, OSError, ValueError) as exc:
        logger.warning("warning_code=doctor_config_unavailable skipping the doctor's output checks: %s", exc)
        return None
    return DoctorConfig(document, path)


def context_records(plan: ContextPlan) -> list[ContextRecord]:
    """The contexts whose Git metadata the doctor checks, as post-process lists them."""
    records = list(plan.by_repo)
    if plan.primary is not None and plan.primary not in records:
        records.append(plan.primary)
    return records


def run_doctor_checks(
    *,
    doctor_runtime: Path,
    doctor_config: DoctorConfig,
    workspace: Path,
    outputs: Iterable[DiscoveredOutput],
    tasks: Iterable[FileTask],
    expected_targets: Iterable[str],
    contexts: Iterable[ContextRecord],
    ddtest: Path | None,
    report_json: Path | None = None,
    settings: Mapping[str, str] | None = None,
    preparation: FreshnessPreparation | None = None,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
) -> DoctorOutcome:
    """Apply the doctor's checks to the outputs that the uploader selected.

    With expected targets, each of their outputs is checked; otherwise only
    outputs that hold a payload or a sidecar, as the standalone doctor finds
    its candidates. The doctor prints its messages; a failure returns its exit
    status and the report's reason. With report_json, the doctor's report is
    written there, as the doctor writes it: with the expected targets, whose
    source is "uploader", and the BEP and staged artifacts of preparation.
    """
    doctor = _load_doctor(doctor_runtime)
    # The report records the uploader's freshness settings.
    args = doctor._parse_args(["--config", str(doctor_config.path), "--report-json", str(report_json or "")])
    for name, value in (settings or {}).items():
        setattr(args, name, value)
    report = doctor._new_diagnostic_report(args)
    expected = list(expected_targets)
    context = preparation.report_context if preparation is not None else None
    doctor._update_diagnostic_config(
        report,
        config_path=doctor_config.path,
        workspace=workspace,
        testlogs_dir=context.testlogs_dir if context is not None else None,
        expected_targets=expected,
        expected_targets_source="uploader" if expected else report["config"]["expected_targets_source"],
        bep_files=list(context.bep_files) if context is not None else [],
        staging_requested=context.staging_requested if context is not None else False,
    )
    if context is not None:
        doctor._update_diagnostic_bep(
            report,
            context.freshness,
            selected_bep_artifact_outputs=set(context.selected_artifact_outputs),
            blocked_bep_artifact_labels=set(context.blocked_labels),
        )
        doctor._update_diagnostic_artifacts(
            report,
            staging_enabled=context.staging_requested and context.freshness is not None,
            staging_base=preparation._staging_base_path,
            staged=list(preparation._staged_artifacts),
        )
    checks = doctor_config.document
    output_dirs = [output.path for output in outputs]
    labels = {task.test_outputs_dir: task.target_label for task in tasks
              if task.test_outputs_dir is not None and task.target_label}
    with contextlib.ExitStack() as stack:
        if stdout is not None:
            stack.enter_context(contextlib.redirect_stdout(stdout))
        if stderr is not None:
            stack.enter_context(contextlib.redirect_stderr(stderr))
        stack.enter_context(doctor._cached_filesystem())
        doctor._run_cache.inspector = ddtest
        try:
            if checks.get("forbid_dd_git_test_env", False):
                doctor._validate_bazelrc(workspace)
            if checks.get("require_git_metadata", False):
                _validate_context_git(doctor, list(contexts))
            if not expected:
                doctor._inspect_outputs(output_dirs)
                output_dirs = [path for path in output_dirs if _has_files(doctor, path)]
            if not output_dirs:
                doctor._update_diagnostic_output_summary(report, [])
                doctor._summary("OK: no fresh payloads require validation")
                return _success(doctor, args, report)
            doctor._inspect_outputs(output_dirs)
            target_by_output_dir = {doctor._resolved(path): label for path, label in labels.items()}
            doctor._update_diagnostic_output_summary(report, doctor._diagnostic_output_entries(
                output_dirs, target_by_output_dir=target_by_output_dir, staged=[], testlogs_dir=None))
            summary = doctor._validate_outputs(
                output_dirs,
                require_json_payloads=checks.get("require_json_payloads", True),
                require_bazel_metadata=checks.get("require_bazel_metadata", True),
                forbid_full_bundle_no_match=checks.get("forbid_full_bundle_no_match", False),
                forbid_msgpack_payloads=checks.get("forbid_msgpack_payloads", True),
                allowed_payload_selections=set(checks.get("allowed_payload_selections") or []) or None,
                expected_payload_selection_by_target=checks.get("expected_payload_selection_by_target", {}),
                target_by_output_dir=target_by_output_dir,
                test_result_outputs={},
                empty_session_outputs={},
            )
            report["summary"]["payload_selection"] = dict(sorted(summary.items()))
            doctor._summary(f"payload selection summary: {doctor._format_selection_summary(summary)}")
            doctor._summary(f"OK: validated {len(output_dirs)} test output directorie(s)")
            return _success(doctor, args, report)
        except SystemExit as exc:
            message = getattr(doctor, "_LAST_FAILURE_MESSAGE", "") or f"doctor exited with status {exc.code}"
            doctor._record_diagnostic_failure(report, exc)
            _write_report(doctor, args, report)
            return _failure(doctor, doctor._exit_code(exc) or 1, message)
        except Exception as exc:  # noqa: BLE001 - the payloads are still sent; the run fails.
            message = f"doctor checks could not run: {exc}"
            print(f"[dd-test-optimization-doctor] {message}", file=sys.stderr)
            doctor._LAST_FAILURE_MESSAGE = message
            doctor._record_diagnostic_failure(report, SystemExit(1))
            _write_report(doctor, args, report)
            return _failure(doctor, 1, message)


def _load_doctor(path: Path) -> ModuleType:
    """A fresh copy of the doctor runtime, whose messages it prints."""
    name = f"_dd_topt_uploader_doctor_checks_{id(path)}"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"doctor runtime is not importable: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def _has_files(doctor: ModuleType, path: Path) -> bool:
    files = doctor._output_files(path)
    return bool(files.json_payloads or files.msgpack_payloads or files.metadata)


def _validate_context_git(doctor: ModuleType, contexts: list[ContextRecord]) -> None:
    """The doctor's _validate_git_metadata_contexts, over the uploader's contexts."""
    if not contexts:
        doctor._fail("require_git_metadata=True but no context.json was provided in data")
    for record in contexts:
        values = record.values
        missing = []
        if not values.get("git.repository_url"):
            missing.append("git.repository_url")
        if not values.get("git.commit.sha"):
            missing.append("git.commit.sha")
        if not (values.get("git.branch") or values.get("git.tag")):
            missing.append("git.branch or git.tag")
        if missing:
            doctor._fail(f"context {record.repo_key} is missing required git metadata: {', '.join(missing)}")


def _success(doctor: ModuleType, args: Any, report: dict[str, Any]) -> DoctorOutcome:
    report["status"] = "ok"
    report["exit_code"] = 0
    doctor._set_report_result(report, status="ok", reason_code="ok", reason="Doctor validation succeeded.")
    _write_report(doctor, args, report)
    return DoctorOutcome(0)


def _write_report(doctor: ModuleType, args: Any, report: dict[str, Any]) -> None:
    if args.report_json:
        doctor._write_diagnostic_report(args, report)


def _failure(doctor: ModuleType, exit_code: int, message: str) -> DoctorOutcome:
    code, reason, steps = doctor._classify_diagnostic_failure({}, message)
    return DoctorOutcome(exit_code, code, reason, tuple(steps))
