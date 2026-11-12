# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Keep unacknowledged source bytes before releasing owned staging copies.

This is an inspection bundle, not a replay command. It deliberately receives no
credentials, request headers, download references, or arbitrary error messages.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import stat
import tempfile
from typing import Iterable

from .discovery import DiscoveryResult
from .freshness import FreshnessPreparation, collect_test_result_evidence, represented_test_targets
from .json_utils import strict_json_dumps
from .models import FileStatus
from .reporting import AggregateReport
from .resources import LoadedResources
from topt_runtime.bep_execution import missing_test_shards


class RetentionError(ValueError):
    """A complete verified bundle could not be published; keep original roots."""


@dataclass(frozen=True)
class RetentionOutcome:
    catalog: Path | None = None
    source_count: int = 0
    original_roots: tuple[Path, ...] = ()


def _copy_verified(source: Path, destination: Path) -> dict[str, object]:
    before = source.lstat()
    if not stat.S_ISREG(before.st_mode):
        raise RetentionError("retention source must be a regular file")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    digest = hashlib.sha256()
    with os.fdopen(os.open(source, flags), "rb") as reader, destination.open("xb") as writer:
        opened = os.fstat(reader.fileno())
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise RetentionError("retention source changed before copy")
        for block in iter(lambda: reader.read(128 * 1024), b""):
            digest.update(block)
            writer.write(block)
    after = source.lstat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise RetentionError("retention source changed during copy")
    copied = hashlib.sha256()
    with destination.open("rb") as reader:
        for block in iter(lambda: reader.read(128 * 1024), b""):
            copied.update(block)
    if copied.digest() != digest.digest() or destination.stat().st_size != before.st_size:
        raise RetentionError("retained file failed copy verification")
    return {"sha256": digest.hexdigest(), "bytes": before.st_size}


def retain_pending_outputs(
    discovery: DiscoveryResult,
    report: AggregateReport | None,
    preparation: FreshnessPreparation | None,
    resources: LoadedResources | None,
    *,
    destination: Path | None,
    disposable_roots: Iterable[Path],
    expected_targets: Iterable[str],
    keep_payloads: bool,
    reason_code: str,
) -> RetentionOutcome:
    """Publish source copies and their catalog last, or leave originals in place.

    A failed source may already contain only its rejected chunks. Hash its bytes
    at copy time, rather than imposing a hash from before that atomic rewrite.
    Contexts follow the sync contract: they are non-secret, immutable JSON data.
    """
    expected_targets = tuple(expected_targets)
    results = {result.task_id: result for result in report.results} if report else {}
    pending = []
    for task in discovery.tasks:
        result = results.get(task.task_id)
        if keep_payloads or result is None or result.status is FileStatus.FAILED:
            pending.append(task)
    if not pending:
        return RetentionOutcome()
    roots = tuple(sorted({(task.test_outputs_dir or task.source_path.parent).resolve() for task in pending}))
    if destination is None:
        for task in pending:
            if not stat.S_ISREG(task.source_path.lstat().st_mode):
                raise RetentionError("unresolved source must remain a regular file")
        return RetentionOutcome(source_count=len(pending), original_roots=roots)

    destination = destination.resolve()
    for forbidden in (*disposable_roots, *roots):
        if destination.is_relative_to(forbidden.resolve()):
            raise RetentionError("retention destination is inside a disposable or source root")
    destination.mkdir(parents=True, exist_ok=True)
    owned = Path(tempfile.mkdtemp(prefix="upload-", dir=destination))
    entries = []
    try:
        for index, task in enumerate(pending):
            directory = owned / f"source-{index:06d}"
            directory.mkdir()
            payload = directory / "payload.json"
            copied = _copy_verified(task.source_path, payload)
            entry = {"task_id": task.task_id, "target": task.target_label,
                "source_name": task.source_path.name,
                "output_key": task.output_key, "payload_type": task.payload_type.value,
                "payload": payload.relative_to(owned).as_posix(), **copied,
                "disposition": "debug_original" if keep_payloads else "unacknowledged",
                "outcome": results[task.task_id].status.value if task.task_id in results else "unknown"}
            if task.test_outputs_dir is not None:
                sidecar = task.test_outputs_dir / "bazel_target_metadata.json"
                if sidecar.exists() or sidecar.is_symlink():
                    sidecar_copy = directory / sidecar.name
                    entry["metadata"] = {"path": sidecar_copy.relative_to(owned).as_posix(), **_copy_verified(sidecar, sidecar_copy)}
            entries.append(entry)

        contexts = []
        telemetry_facts = []
        if resources is not None:
            records = list(resources.context_plan.by_repo)
            if resources.context_plan.primary is not None and resources.context_plan.primary not in records:
                records.append(resources.context_plan.primary)
            for index, context in enumerate(records):
                body = strict_json_dumps(dict(context.values), sort_keys=True).encode()
                path = owned / f"context-{index:06d}.json"
                path.write_bytes(body)
                if path.read_bytes() != body:
                    raise RetentionError("retained context failed copy verification")
                contexts.append({"repo_key": context.repo_key, "path": path.name, "sha256": hashlib.sha256(body).hexdigest()})
            if any(task.payload_type.value == "telemetry" for task in pending):
                for index, facts in enumerate(resources.telemetry_facts_paths):
                    target = owned / f"telemetry-facts-{index:06d}.json"
                    # Resolve declared immutable runfiles, which may be file
                    # symlinks. Payload/sidecar symlinks remain forbidden.
                    telemetry_facts.append({"path": target.name, **_copy_verified(facts.resolve(), target)})
        executions = []
        deficits: dict[str, object] = {}
        if preparation is not None:
            executions = [{"identity": list(execution.identity), "cached": execution.cached,
                "status": execution.status, "output_keys": sorted(execution.output_keys)}
                for execution in preparation.plan.executions]
            proven, labels = collect_test_result_evidence(discovery, report.results if report else ())
            labels.update(expected_targets)
            labels.update(task.target_label for task in discovery.tasks if task.target_label)
            deficits = {"missing_test_shards": [list(identity) for identity in missing_test_shards(preparation.plan.executions, proven, labels)],
                "missing_expected_targets": (sorted(set(expected_targets).difference(represented_test_targets(preparation.plan)))
                    if preparation.plan.selected_source == "bep" else []),
                "missing_output_labels": sorted(preparation.plan.missing_output_labels),
                "ambiguous_output_keys": sorted(preparation.plan.ambiguous_outputs),
                "ambiguous_targets": sorted(preparation.plan.ambiguous_labels)}
        source_outcomes = [{"task_id": task.task_id, "target": task.target_label, "output_key": task.output_key,
            "outcome": results[task.task_id].status.value if task.task_id in results else "unknown",
            "test_events": results[task.task_id].test_events if task.task_id in results else None,
            "requests_attempted": results[task.task_id].requests_attempted if task.task_id in results else None,
            "requests_succeeded": results[task.task_id].requests_succeeded if task.task_id in results else None,
            "request_ids": list(results[task.task_id].request_ids) if task.task_id in results else [],
            "failure_code": results[task.task_id].failure_code if task.task_id in results else None}
            for task in discovery.tasks]
        catalog = {"schema_version": 1, "purpose": "private_inspection", "sources": entries,
            "contexts": contexts, "executions": executions,
            "telemetry_facts": telemetry_facts,
            "source_outcomes": source_outcomes, "unfulfilled_requirements": deficits,
            "expected_targets": sorted(set(expected_targets)), "uploader_reason_code": reason_code,
            "uploader_exit_code": report.exit_code if report else None,
            "automatic_replay_supported": False}
        if report is not None and report.requests:
            catalog["requests"] = [{"request_id": request.request_id, "source_ids": list(request.source_ids),
                "attempts": request.attempts, "succeeded": request.succeeded} for request in report.requests]
        unpublished = owned / "catalog.pending"
        unpublished.write_text(strict_json_dumps(catalog, sort_keys=True, indent=2) + "\n")
        os.replace(unpublished, owned / "catalog.json")
    except RetentionError:
        raise
    except (OSError, ValueError) as exc:
        raise RetentionError(f"retention failed ({type(exc).__name__}); original outputs remain required") from exc
    return RetentionOutcome(owned / "catalog.json", len(pending), roots)


def write_retention_status(path: Path | None, wrapper_root: Path | None, *, cleanup_safe: bool) -> None:
    """Publish the private wrapper handoff only inside its disposable root."""
    if path is None:
        return
    if wrapper_root is None or not path.resolve().is_relative_to(wrapper_root.resolve()):
        raise RetentionError("retention status must be inside the wrapper's temporary root")
    document = {"schema_version": 1, "wrapper_temp_root": str(wrapper_root.resolve()), "cleanup_safe": cleanup_safe}
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".retention-", delete=False) as writer:
        writer.write(strict_json_dumps(document) + "\n")
        temporary = Path(writer.name)
    os.replace(temporary, path)
