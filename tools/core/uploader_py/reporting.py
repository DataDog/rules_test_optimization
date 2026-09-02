# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Aggregate results and render deterministic human and JSON reports.

One report model prevents terminal output and machine-readable counters from drifting.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, TextIO

from .json_utils import strict_json_dumps
from .models import FileResult, FileStatus, MAX_TEST_PAYLOAD_BYTES, PayloadType


@dataclass(frozen=True)
class LegacyReportContext:
    """Pre-worker values needed to preserve every schema-v1 report section."""

    validate_enrichment: bool = False
    artifact_source: str = "local"
    remote_artifacts: str = "disabled"
    freshness_source: str = "auto"
    freshness_mode: str = "auto"
    allow_cached_payload_uploads: bool = False
    bep_files: tuple[str, ...] = ()
    freshness_selected_source: str = "none"
    freshness_eligible_outputs: int = 0
    freshness_cached_outputs: int = 0
    freshness_remote_only_outputs: int = 0
    freshness_skipped_outputs: int = 0
    freshness_missing_output_labels: int = 0
    freshness_skipped_targets: int = 0
    staging_dir: str = ""
    staged_testlogs_dirs: int = 0
    selected_remote_artifacts: int = 0
    staged_remote_artifacts: int = 0
    remote_artifacts_ignored: int = 0
    test_outputs_dirs: int = 0
    reason_code: str = ""
    reason: str = ""
    next_steps: tuple[str, ...] = ()


@dataclass(frozen=True)
class AggregateReport:
    """Single source of truth for terminal stdout and JSON statistics."""

    dry_run: bool
    exit_code: int
    configured_workers: int
    worker_threads: int
    peak_active_workers: int
    elapsed_seconds: float
    discovered_by_type: tuple[tuple[PayloadType, int], ...]
    results: tuple[FileResult, ...]
    cancelled: int = 0
    initialization_warning_codes: tuple[str, ...] = ()

    @classmethod
    def create(
        cls,
        *,
        dry_run: bool,
        exit_code: int,
        configured_workers: int,
        worker_threads: int,
        peak_active_workers: int,
        elapsed_seconds: float,
        discovered_by_type: Mapping[PayloadType, int],
        results: Iterable[FileResult],
        cancelled: int = 0,
        initialization_warning_codes: Iterable[str] = (),
    ) -> "AggregateReport":
        if configured_workers <= 0:
            raise ValueError("configured_workers must be positive")
        integer_values = {
            "exit_code": exit_code,
            "worker_threads": worker_threads,
            "peak_active_workers": peak_active_workers,
            "cancelled": cancelled,
        }
        if any(value < 0 for value in integer_values.values()):
            raise ValueError("aggregate integer counters must be non-negative")
        if elapsed_seconds < 0:
            raise ValueError("elapsed_seconds must be non-negative")
        discovered = tuple(
            (payload_type, int(discovered_by_type.get(payload_type, 0)))
            for payload_type in PayloadType
        )
        if any(count < 0 for _payload_type, count in discovered):
            raise ValueError("discovered counters must be non-negative")
        terminal_results = tuple(results)
        task_ids = [result.task_id for result in terminal_results]
        if len(task_ids) != len(set(task_ids)):
            raise ValueError("aggregate results must contain unique task IDs")
        if peak_active_workers > worker_threads:
            raise ValueError("peak_active_workers cannot exceed worker_threads")
        return cls(
            dry_run=dry_run,
            exit_code=exit_code,
            configured_workers=configured_workers,
            worker_threads=worker_threads,
            peak_active_workers=peak_active_workers,
            elapsed_seconds=elapsed_seconds,
            discovered_by_type=discovered,
            results=terminal_results,
            cancelled=cancelled,
            initialization_warning_codes=tuple(initialization_warning_codes),
        )

    @property
    def mode(self) -> str:
        return "dry-run" if self.dry_run else "upload"

    @property
    def result_name(self) -> str:
        if self.exit_code == 0:
            return "success"
        if any(
            result.status is FileStatus.SUCCEEDED or result.requests_succeeded > 0
            for result in self.results
        ):
            return "partial_failure"
        return "failure"

    def statistics(self) -> dict[str, Any]:
        """Return the exact data model consumed by all report renderers."""
        succeeded = _status_count(self.results, FileStatus.SUCCEEDED)
        failed = _status_count(self.results, FileStatus.FAILED)
        skipped = _status_count(self.results, FileStatus.SKIPPED)
        processed = len(self.results)
        eligible = processed + self.cancelled
        deleted = sum(int(result.source_deleted) for result in self.results)
        discovered = sum(count for _payload_type, count in self.discovered_by_type)
        type_summaries = {
            payload_type.value: _payload_type_counts(self.results, payload_type)
            for payload_type in PayloadType
        }
        failure_codes = Counter(
            result.failure_code
            for result in self.results
            if result.failure_code is not None
        )
        warning_codes = Counter(self.initialization_warning_codes)
        warning_codes.update(
            warning
            for result in self.results
            for warning in result.warning_codes
        )
        return {
            "mode": self.mode,
            "result": self.result_name,
            "exit_code": self.exit_code,
            "elapsed_seconds": round(self.elapsed_seconds, 6),
            "files": {
                "discovered": discovered,
                "eligible": eligible,
                "processed": processed,
                "succeeded": succeeded,
                "failed": failed,
                "skipped": skipped,
                "cancelled": self.cancelled,
                "deleted": deleted,
                "retained": max(0, eligible - deleted),
            },
            "payload_types": type_summaries,
            "discovered_by_type": {
                payload_type.value: count
                for payload_type, count in self.discovered_by_type
            },
            "concurrency": {
                "workers": self.configured_workers,
                "worker_threads": self.worker_threads,
                "peak_active_workers": self.peak_active_workers,
            },
            "splitting": {
                "threshold_bytes": MAX_TEST_PAYLOAD_BYTES,
                "source_files_split": sum(
                    int(result.chunks_created > 1) for result in self.results
                ),
                "chunks_created": sum(result.chunks_created for result in self.results),
                "chunks_uploaded": sum(result.chunks_uploaded for result in self.results),
                "chunks_failed": sum(result.chunks_failed for result in self.results),
                "oversized_single_events": sum(
                    int(result.failure_code == "single_event_exceeds_payload_limit")
                    for result in self.results
                ),
            },
            "requests": {
                "planned": sum(result.requests_planned for result in self.results),
                "attempted": sum(result.requests_attempted for result in self.results),
                "succeeded": sum(result.requests_succeeded for result in self.results),
                "failed": sum(result.requests_failed for result in self.results),
                "retries": sum(result.retries for result in self.results),
            },
            "warnings": dict(sorted(warning_codes.items())),
            "failures": dict(sorted(failure_codes.items())),
        }

    def human_lines(self) -> tuple[str, ...]:
        """Render a compact stable statistics block for CI logs."""
        stats = self.statistics()
        files = stats["files"]
        payload_types = stats["payload_types"]
        splitting = stats["splitting"]
        requests = stats["requests"]
        concurrency = stats["concurrency"]

        def type_value(name: str) -> str:
            counts = payload_types[name]
            return f"{counts['succeeded']}/{counts['failed']}/{counts['skipped']}"

        return (
            (
                f"[dd-uploader] summary: mode={self.mode} result={self.result_name} "
                f"exit_code={self.exit_code} workers={self.configured_workers} "
                f"peak={concurrency['peak_active_workers']} "
                f"elapsed={self.elapsed_seconds:.2f}s"
            ),
            (
                "[dd-uploader] files: "
                f"discovered={files['discovered']} eligible={files['eligible']} "
                f"processed={files['processed']} succeeded={files['succeeded']} "
                f"failed={files['failed']} skipped={files['skipped']} "
                f"cancelled={files['cancelled']}"
            ),
            (
                "[dd-uploader] types: "
                f"tests={type_value('test')} coverage={type_value('coverage')} "
                f"telemetry={type_value('telemetry')} (succeeded/failed/skipped)"
            ),
            (
                "[dd-uploader] split: "
                f"files={splitting['source_files_split']} "
                f"chunks_created={splitting['chunks_created']} "
                f"chunks_uploaded={splitting['chunks_uploaded']} "
                f"chunks_failed={splitting['chunks_failed']}"
            ),
            (
                "[dd-uploader] requests: "
                f"planned={requests['planned']} attempted={requests['attempted']} "
                f"succeeded={requests['succeeded']} failed={requests['failed']} "
                f"retries={requests['retries']}"
            ),
            (
                "[dd-uploader] cleanup: "
                f"deleted={files['deleted']} retained={files['retained']}"
            ),
        )

    def schema_v1_report(
        self,
        context: LegacyReportContext,
    ) -> dict[str, Any]:
        """Preserve legacy fields and append explicit source/request sections."""
        stats = self.statistics()
        status = "ok" if self.exit_code == 0 else "fail"
        reason_code, reason, next_steps = _result_reason(self, context)
        legacy_counts = _legacy_payload_type_counts(self)
        failed_payloads = sum(
            counts["failed"] for counts in legacy_counts.values()
        )
        upload_attempted = not self.dry_run and stats["requests"]["attempted"] > 0
        successful_payloads = sum(
            counts["processed"] for counts in legacy_counts.values()
        )
        report_document = {
            "schema_version": 1,
            "tool": "dd-test-optimization-uploader",
            "status": status,
            "exit_code": self.exit_code,
            "result": {
                "status": status,
                "reason_code": reason_code,
                "reason": reason,
                "next_steps": list(next_steps),
            },
            "config": {
                "dry_run": self.dry_run,
                "validate_enrichment": context.validate_enrichment,
                "artifact_source": context.artifact_source,
                "remote_artifacts": context.remote_artifacts,
                "freshness_source": context.freshness_source,
                "freshness_mode": context.freshness_mode,
                "allow_cached_payload_uploads": context.allow_cached_payload_uploads,
            },
            "bep": {
                "files": list(context.bep_files),
                "freshness_selected_source": context.freshness_selected_source,
                "eligible_outputs": context.freshness_eligible_outputs,
                "cached_outputs": context.freshness_cached_outputs,
                "remote_only_outputs": context.freshness_remote_only_outputs,
                "skipped_outputs": context.freshness_skipped_outputs,
                "missing_output_labels": context.freshness_missing_output_labels,
                "skipped_targets": context.freshness_skipped_targets,
            },
            "artifacts": {
                "source": context.artifact_source,
                "staging_dir": context.staging_dir,
                "staged_testlogs_dirs": context.staged_testlogs_dirs,
                "selected_remote_artifacts": context.selected_remote_artifacts,
                "staged_remote_artifacts": context.staged_remote_artifacts,
                "remote_artifacts_ignored": context.remote_artifacts_ignored,
            },
            "upload": {
                "attempted": upload_attempted,
                "dry_run": self.dry_run,
                "payloads_attempted": (
                    successful_payloads + failed_payloads if upload_attempted else 0
                ),
                "payloads_uploaded": successful_payloads if upload_attempted else 0,
                "payloads_failed": failed_payloads,
            },
            "payloads": {
                "test_outputs_dirs": context.test_outputs_dirs,
                "discovered": {
                    "tests": stats["discovered_by_type"]["test"],
                    "coverage": stats["discovered_by_type"]["coverage"],
                    "telemetry": stats["discovered_by_type"]["telemetry"],
                },
                "tests": legacy_counts["tests"],
                "coverage": legacy_counts["coverage"],
                "telemetry": legacy_counts["telemetry"],
            },
            "upload_failures": failed_payloads,
        }
        # New sections are copied verbatim from the same aggregate used by
        # stdout so legacy and explicit source/request counters cannot drift.
        for key in (
            "files",
            "payload_types",
            "discovered_by_type",
            "concurrency",
            "splitting",
            "requests",
            "warnings",
            "failures",
        ):
            report_document[key] = stats[key]
        return report_document


def write_statistics_json(path: Path, report: AggregateReport) -> None:
    """Atomically write the aggregate statistics without partial JSON files."""
    _write_json(path, report.statistics())


def write_schema_v1_report(
    path: Path,
    report: AggregateReport,
    context: LegacyReportContext,
) -> None:
    """Atomically write the backward-compatible public uploader report."""
    _write_json(path, report.schema_v1_report(context))


def emit_report(
    report: AggregateReport,
    *,
    stream: TextIO,
    report_json: Path | None = None,
    legacy_report_context: LegacyReportContext | None = None,
) -> None:
    """Render stdout and optional JSON from one immutable aggregate report."""
    for line in report.human_lines():
        print(line, file=stream)
    if report_json is None:
        return
    try:
        if legacy_report_context is None:
            write_statistics_json(report_json, report)
        else:
            write_schema_v1_report(report_json, report, legacy_report_context)
    except OSError as exc:
        print(
            "[dd-uploader] warning: failed to write uploader report: "
            f"{type(exc).__name__}",
            file=stream,
        )


def _write_json(path: Path, payload: Mapping[str, Any]) -> None:
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    temporary = parent / f".{path.name}.tmp"
    try:
        temporary.write_text(
            strict_json_dumps(
                payload,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        temporary.replace(path)
    except OSError:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def _legacy_payload_type_counts(
    report: AggregateReport,
) -> dict[str, dict[str, int]]:
    """Recreate schema-v1 counters, where processed means successful."""
    counts_by_type: dict[str, dict[str, int]] = {}
    for payload_type, legacy_key in (
        (PayloadType.TEST, "tests"),
        (PayloadType.COVERAGE, "coverage"),
    ):
        type_results = tuple(
            result
            for result in report.results
            if result.payload_type is payload_type
        )
        counts_by_type[legacy_key] = {
            "processed": _status_count(type_results, FileStatus.SUCCEEDED),
            "failed": _status_count(type_results, FileStatus.FAILED),
            "skipped": _status_count(type_results, FileStatus.SKIPPED),
        }

    telemetry = tuple(
        result
        for result in report.results
        if result.payload_type is PayloadType.TELEMETRY
    )
    if report.dry_run:
        telemetry_processed = sum(
            result.requests_planned
            for result in telemetry
            if result.status is FileStatus.SUCCEEDED
        )
    else:
        telemetry_processed = sum(result.requests_succeeded for result in telemetry)
    telemetry_failed = sum(
        (
            result.requests_failed
            if result.requests_failed > 0
            else int(result.status is FileStatus.FAILED)
        )
        for result in telemetry
    )
    counts_by_type["telemetry"] = {
        "processed": telemetry_processed,
        "failed": telemetry_failed,
        "skipped": _status_count(telemetry, FileStatus.SKIPPED),
    }
    return counts_by_type


def _result_reason(
    report: AggregateReport,
    context: LegacyReportContext,
) -> tuple[str, str, tuple[str, ...]]:
    if context.reason_code:
        return context.reason_code, context.reason, context.next_steps
    stats = report.statistics()
    if context.test_outputs_dirs == 0:
        return (
            "no_test_outputs_found",
            "No local or staged test.outputs directories were found.",
            (
                "Use --artifact-source=bep with the matching --bep-json, or "
                "configure Bazel to materialize test outputs.",
            ),
        )
    if stats["files"]["discovered"] == 0:
        return (
            "no_payload_json_found",
            "Test output directories were found, but no payloads were available.",
            ("Inspect TEST_UNDECLARED_OUTPUTS_DIR and outputs.zip.",),
        )
    if report.exit_code != 0 and stats["requests"]["attempted"] > 0:
        return (
            "upload_failed_http",
            "One or more payload uploads failed.",
            ("Check HTTP status diagnostics and Datadog credentials/site configuration.",),
        )
    if report.exit_code != 0:
        return (
            "payload_enrichment_failed",
            "Dry-run or payload processing failed for at least one payload.",
            ("Inspect uploader logs for the first payload validation failure.",),
        )
    if report.dry_run:
        return (
            "upload_skipped_dry_run",
            "Dry-run completed successfully; real upload was not requested.",
            ("Run again without --dry-run to send payloads.",),
        )
    return "ok", "Uploader completed successfully.", ()


def _payload_type_counts(
    results: tuple[FileResult, ...], payload_type: PayloadType
) -> dict[str, int]:
    type_results = tuple(
        result for result in results if result.payload_type is payload_type
    )
    return {
        status.value: _status_count(type_results, status)
        for status in FileStatus
    }


def _status_count(results: Iterable[FileResult], status: FileStatus) -> int:
    return sum(int(result.status is status) for result in results)
