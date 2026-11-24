# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Send selected test and coverage payloads with ddtest's native uploader.

The Python uploader still discovers the payloads, applies freshness and stages
remote artifacts. This module hands the selected test and coverage sources to
`ddtest instrument bazel upload` in one plan, with each test source's output
directory and the invocation's context selection, and turns ddtest's report
back into file results. ddtest reads each target's Bazel metadata, selects its
context, and enriches, validates, batches and sends the sources in parallel,
as the Python enrichment would. It deletes or retains each source as the
Python workers do.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import logging
import os
from pathlib import Path
import subprocess
from typing import Any, Iterable, Mapping, Sequence

from .endpoints import EndpointSet
from .enrichment import ContextPlan
from .models import FileResult, FileStatus, FileTask, PayloadType, RequestOutcome

PLAN_SCHEMA_VERSION = 1

# What test_url ends with for each delivery: the rest is the base URL that
# ddtest takes from its environment.
_AGENTLESS_TEST_PATH = "/api/v2/citestcycle"
_EVP_TEST_PATH = "/evp_proxy/v2/api/v2/citestcycle"

# Variables that select ddtest's delivery; the module sets them from the
# endpoints that the Python uploader resolved.
_DELIVERY_VARIABLES = (
    "DD_SITE",
    "DD_TEST_OPTIMIZATION_AGENT_URL",
    "DD_TEST_OPTIMIZATION_AGENTLESS_URL",
)


class NativeUploadUnavailable(RuntimeError):
    """ddtest cannot take this invocation's sources; the Python workers can."""


@dataclass(frozen=True)
class NativeUploadSettings:
    """The parts of the uploader configuration that the native upload uses."""

    executable: Path
    rules_version: str
    api_key: str
    dry_run: bool
    keep_payloads: bool
    gzip_payloads: bool
    batch_test_payloads: bool
    filter_prefix: bool
    validate_enrichment: bool
    expected_enriched_tags: tuple[str, ...]
    workers: int | None
    codeowners_file: Path | None


@dataclass(frozen=True)
class NativeUploadRun:
    """File results of the sources that ddtest handled."""

    results: tuple[FileResult, ...]
    cancelled: int
    interrupted: bool
    workers: int = 0
    # The test requests that ddtest sent with batching, which the results name.
    requests: tuple[RequestOutcome, ...] = ()


def is_native_task(task: FileTask) -> bool:
    """Whether ddtest sends this task; telemetry stays with the Python workers."""
    return task.payload_type in (PayloadType.TEST, PayloadType.COVERAGE)


def run_native_upload(
    tasks: Sequence[FileTask],
    *,
    settings: NativeUploadSettings,
    endpoints: EndpointSet,
    context_plan: ContextPlan,
    runtime_id: str,
    work_directory: Path,
    environment: Mapping[str, str] | None = None,
    logger: logging.Logger | None = None,
) -> NativeUploadRun:
    """Upload tasks with ddtest and return one result per task that it handled.

    Raises NativeUploadUnavailable before ddtest runs, when the executable or
    a common root of the sources is missing.
    """
    if not settings.executable.is_file():
        raise NativeUploadUnavailable(f"ddtest executable not found: {settings.executable}")
    filtered = tuple(
        _skipped(task, "prefix_filter") for task in tasks if settings.filter_prefix and not _passes_prefix(task)
    )
    selected = tuple(task for task in tasks if not settings.filter_prefix or _passes_prefix(task))
    if not selected:
        return NativeUploadRun(results=filtered, cancelled=0, interrupted=False)

    sources, contexts, selection, warnings = _plan_sources(selected, context_plan)
    codeowners = _real_path(settings.codeowners_file) if settings.codeowners_file else None
    root = _common_root([Path(source["path"]) for source in sources]
                        + [Path(source["output"]) for source in sources if "output" in source]
                        + ([codeowners] if codeowners else []))
    for source in sources:
        for key in ("path", "output"):
            if key in source:
                source[key] = os.path.relpath(source[key], root)
    plan: dict[str, Any] = {
        "schema_version": PLAN_SCHEMA_VERSION,
        "rules_version": settings.rules_version,
        "runtime_id": runtime_id,
        "contexts": contexts,
        "context_selection": selection,
        "sources": sources,
    }
    if codeowners is not None:
        plan["codeowners"] = os.path.relpath(codeowners, root)
        plan["codeowners_dialect"] = "gitlab" if codeowners.parent.name == ".gitlab" else "github"

    plan_path = work_directory / "ddtest-upload-plan.json"
    report_path = work_directory / "ddtest-upload-report.json"
    plan_path.write_text(json.dumps(plan), encoding="utf-8")
    command = _command(settings, plan_path, root, report_path)
    if logger is not None:
        logger.debug("ddtest upload: sources=%d root=%s command=%s", len(sources), root, " ".join(command))
    interrupted = False
    try:
        completed = subprocess.run(
            command,
            env=_environment(environment if environment is not None else os.environ, settings, endpoints),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        exit_code, stdout, stderr = completed.returncode, completed.stdout, completed.stderr
    except KeyboardInterrupt:
        # The terminal's interrupt reaches ddtest too; its report holds what it
        # finished before it stopped.
        interrupted, exit_code, stdout, stderr = True, 130, b"", b""
    _log_output(logger, stdout, stderr)

    by_id = {task.task_id: task for task in selected}
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
        entries = {entry["task_id"]: entry for entry in report["sources"]}
    except (OSError, ValueError, KeyError, TypeError) as exc:
        message = _failure_message(exit_code, stderr, exc)
        return NativeUploadRun(
            results=filtered + tuple(_failed(task, "ddtest_upload_failed", message, warnings.get(task.task_id, ()))
                                     for task in selected),
            cancelled=0,
            interrupted=interrupted,
        )
    results: list[FileResult] = list(filtered)
    cancelled = 0
    for task_id, task in by_id.items():
        entry = entries.get(task_id)
        if entry is None:
            results.append(_failed(task, "ddtest_upload_failed", "ddtest did not report the source", warnings.get(task_id, ())))
        elif entry.get("status") == "cancelled":
            cancelled += 1
        else:
            results.append(_result(task, entry, warnings.get(task_id, ())))
    requests = tuple(
        RequestOutcome(_request_id(request["request_id"]), tuple(request["source_ids"]), int(request["attempts"]),
                       request["succeeded"])
        for request in report.get("batch_requests") or ())
    return NativeUploadRun(results=tuple(results), cancelled=cancelled, interrupted=interrupted or exit_code == 130,
                           workers=int(report.get("workers", 0)), requests=requests)


def _request_id(ddtest_id: str) -> str:
    """Keep ddtest's request IDs apart from those of the Python workers."""
    return f"ddtest:{ddtest_id}"


def _passes_prefix(task: FileTask) -> bool:
    prefix = "span_events_" if task.payload_type is PayloadType.TEST else "coverage_"
    return task.source_path.name.startswith(prefix)


def _plan_sources(
    tasks: Iterable[FileTask],
    context_plan: ContextPlan,
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, Any], dict[str, tuple[str, ...]]]:
    """The plan's sources, contexts and context selection, and the warnings that ddtest does not report.

    A test source names its output directory, and ddtest reads its sidecar and
    selects its context as the Python enrichment does. A test source without
    one has no sidecar, so its context is selected here.
    """
    contexts = _ContextNames()
    selection: dict[str, Any] = {
        "by_repo": [{"repo": record.repo_key, "context": contexts.name(record.values)}
                    for record in context_plan.by_repo],
        "override": context_plan.override,
        "require_repo_match": context_plan.require_repo_match,
    }
    if context_plan.primary is not None:
        selection["primary"] = contexts.name(context_plan.primary.values)
    sources: list[dict[str, Any]] = []
    warnings: dict[str, tuple[str, ...]] = {}
    real_outputs: dict[Path, Path] = {}
    for task in tasks:
        path, output = _real_paths(task, real_outputs)
        source: dict[str, Any] = {"id": task.task_id, "path": str(path), "kind": task.payload_type.value}
        if task.payload_type is PayloadType.TEST:
            if output is not None:
                source["output"] = str(output)
            else:
                chosen = context_plan.select(None)
                if chosen.warning_code:
                    warnings[task.task_id] = (chosen.warning_code,)
                if chosen.values is not None:
                    source["context"] = contexts.name(chosen.values)
        sources.append(source)
    return sources, contexts.values, selection, warnings


class _ContextNames:
    """One plan context per distinct context, so that sources sharing it can
    share a batch, whatever repository key selected it."""

    def __init__(self) -> None:
        self.values: dict[str, Any] = {}
        self._names: dict[str, str] = {}

    def name(self, values: Mapping[str, Any]) -> str:
        identity = json.dumps(values, sort_keys=True, default=str)
        name = self._names.get(identity)
        if name is None:
            name = self._names[identity] = f"context-{len(self._names) + 1}"
            self.values[name] = dict(values)
        return name


def _real_paths(task: FileTask, real_outputs: dict[Path, Path]) -> tuple[Path, Path | None]:
    """A source's real path, and that of its output directory when it is below it.

    Discovery refuses links below an output, so a source's real path is its
    path below the output's real path, and one resolution serves every source
    of an output. A discovered task's paths are already real.
    """
    output = task.test_outputs_dir
    if task.real_paths and output is not None:
        return task.source_path, output
    if output is not None:
        try:
            relative = task.source_path.relative_to(output)
        except ValueError:
            relative = None
        if relative is not None and relative.parts and ".." not in relative.parts:
            real_output = real_outputs.get(output)
            if real_output is None:
                real_output = real_outputs[output] = _real_path(output)
            return real_output / relative, real_output
    return _real_path(task.source_path), None


def _real_path(path: Path) -> Path:
    # os.Root in ddtest refuses links that leave the root, such as
    # bazel-testlogs; the real paths share a root without them.
    return Path(os.path.realpath(path))


def _common_root(paths: Sequence[Path]) -> Path:
    try:
        common = Path(os.path.commonpath([str(path) for path in paths]))
    except ValueError as exc:
        # Windows paths on different drives have no common root.
        raise NativeUploadUnavailable(f"the payloads share no root: {exc}") from exc
    return common if common.is_dir() else common.parent


def _command(settings: NativeUploadSettings, plan: Path, root: Path, report: Path) -> list[str]:
    command = [
        str(settings.executable), "instrument", "bazel", "upload",
        "--plan", str(plan),
        "--root", str(root),
        "--report-json", str(report),
        f"--gzip={_flag(settings.gzip_payloads)}",
        f"--keep-payloads={_flag(settings.keep_payloads)}",
        f"--batch-test-payloads={_flag(settings.batch_test_payloads)}",
    ]
    if settings.dry_run:
        command.append("--dry-run")
    if settings.workers is not None:
        command += ["--workers", str(settings.workers)]
    if settings.validate_enrichment:
        command.append("--validate-enrichment")
        for tag in settings.expected_enriched_tags:
            command += ["--expected-enriched-tag", tag]
    return command


def _flag(value: bool) -> str:
    return "true" if value else "false"


def _environment(
    base: Mapping[str, str],
    settings: NativeUploadSettings,
    endpoints: EndpointSet,
) -> dict[str, str]:
    """ddtest's environment, with the delivery that the Python uploader resolved."""
    environment = {name: value for name, value in base.items() if name not in _DELIVERY_VARIABLES}
    environment["DD_API_KEY"] = settings.api_key
    if not endpoints.agentless:
        environment["DD_TEST_OPTIMIZATION_AGENT_URL"] = _base_url(endpoints.test_url, _EVP_TEST_PATH)
    elif endpoints.test_url == f"https://citestcycle-intake.{endpoints.site}{_AGENTLESS_TEST_PATH}":
        environment["DD_SITE"] = endpoints.site
    else:
        environment["DD_TEST_OPTIMIZATION_AGENTLESS_URL"] = _base_url(endpoints.test_url, _AGENTLESS_TEST_PATH)
    return environment


def _base_url(test_url: str, suffix: str) -> str:
    if not test_url.endswith(suffix):
        raise NativeUploadUnavailable(f"unexpected test intake URL for ddtest: {test_url}")
    return test_url[: -len(suffix)]


def _result(task: FileTask, entry: Mapping[str, Any], warnings: tuple[str, ...]) -> FileResult:
    requests = entry.get("requests") or {}
    return FileResult(
        task_id=task.task_id,
        source_path=task.display_path,
        payload_type=task.payload_type,
        status=FileStatus(entry["status"]),
        events=int(entry.get("events", 0)),
        chunks_created=int(entry.get("chunks_created", 0)),
        chunks_uploaded=int(entry.get("chunks_uploaded", 0)),
        chunks_failed=int(entry.get("chunks_failed", 0)),
        requests_planned=int(requests.get("planned", 0)),
        requests_attempted=int(requests.get("attempted", 0)),
        requests_succeeded=int(requests.get("succeeded", 0)),
        requests_failed=int(requests.get("failed", 0)),
        retries=int(requests.get("retries", 0)),
        source_deleted=bool(entry.get("source_deleted", False)),
        warning_codes=tuple(dict.fromkeys(warnings + tuple(entry.get("warning_codes") or ()))),
        failure_code=entry.get("failure_code") or None,
        failure_message=entry.get("failure_message") or None,
        source_bytes=int(entry.get("source_bytes", 0)),
        prepared_body_bytes=int(entry.get("prepared_body_bytes", 0)),
        test_events=int(entry.get("test_events", 0)),
        empty_test_session=bool(entry.get("empty_test_session", False)),
        request_ids=tuple(_request_id(request_id) for request_id in entry.get("request_ids") or ()),
    )


def _failed(task: FileTask, code: str, message: str, warnings: tuple[str, ...] = ()) -> FileResult:
    return FileResult(
        task_id=task.task_id,
        source_path=task.display_path,
        payload_type=task.payload_type,
        status=FileStatus.FAILED,
        warning_codes=warnings,
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


def _failure_message(exit_code: int, stderr: bytes, error: Exception) -> str:
    detail = stderr.decode("utf-8", "replace").strip().splitlines()
    last = detail[-1] if detail else type(error).__name__
    return f"ddtest exited with {exit_code} without a report: {last}"[:500]


def _log_output(logger: logging.Logger | None, stdout: bytes, stderr: bytes) -> None:
    if logger is None:
        return
    for line in stdout.decode("utf-8", "replace").splitlines():
        logger.debug("ddtest: %s", line)
    for line in stderr.decode("utf-8", "replace").splitlines():
        logger.warning("ddtest: %s", line)
