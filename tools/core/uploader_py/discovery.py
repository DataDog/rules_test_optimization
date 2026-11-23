# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Build a deterministic one-task-per-source plan from Bazel testlogs.

Discovery happens before scheduling so workers never race filesystem traversal.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess
import time
from typing import Callable, Iterable

from topt_runtime.bep_execution import canonical_output_directory_key, find_test_output_directories

from .models import FileTask, PayloadType
from .json_utils import strict_json_loads


_PAYLOAD_SUBDIRECTORIES = (
    (PayloadType.TEST, Path("payloads") / "tests"),
    (PayloadType.COVERAGE, Path("payloads") / "coverage"),
    (PayloadType.TELEMETRY, Path("payloads") / "telemetry"),
)
_PAYLOAD_SUFFIXES = frozenset({".json", ".msgpack"})


class DiscoveryError(ValueError):
    """Configured testlogs discovery cannot be performed safely."""


def read_bazel_metadata(output_dir: Path | None) -> tuple[dict | None, str | None]:
    """Read one regular target sidecar without following it outside its output."""
    if output_dir is None:
        return None, None
    metadata_file = output_dir / "bazel_target_metadata.json"
    if not metadata_file.is_file():
        return None, None
    try:
        resolved = metadata_file.resolve(strict=True)
        output_resolved = output_dir.resolve(strict=True)
    except OSError:
        return None, "bazel_metadata_invalid"
    if metadata_file.is_symlink() or resolved.parent != output_resolved:
        return None, "bazel_metadata_unsafe"
    try:
        value = strict_json_loads(metadata_file.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None, "bazel_metadata_invalid"
    return (value, None) if isinstance(value, dict) else (None, "bazel_metadata_invalid")


def read_target_label(output_dir: Path) -> str | None:
    """Read an optional regular sidecar without following it outside its output."""
    value, _warning = read_bazel_metadata(output_dir)
    label = value.get("bazel.target") if isinstance(value, dict) else None
    return label if isinstance(label, str) and label else None


@dataclass(frozen=True)
class ScanRoot:
    path: Path
    staged: bool = False


@dataclass(frozen=True)
class DiscoveredOutput:
    path: Path
    output_key: str
    scan_root: Path
    staged: bool


@dataclass(frozen=True)
class DiscoveryResult:
    outputs: tuple[DiscoveredOutput, ...]
    tasks: tuple[FileTask, ...]
    discovered_by_type: tuple[tuple[PayloadType, int], ...]
    warning_codes: tuple[str, ...] = ()

    def counts(self) -> dict[PayloadType, int]:
        return dict(self.discovered_by_type)


@dataclass(frozen=True)
class QuiescenceResult:
    discovery: DiscoveryResult
    reason: str
    elapsed_seconds: float


def count_tasks_by_payload_type(
    tasks: Iterable[FileTask],
) -> tuple[tuple[PayloadType, int], ...]:
    """Count supported tasks once in the stable public payload-type order."""
    counts = {payload_type: 0 for payload_type in PayloadType}
    for task in tasks:
        if task.payload_type in counts:
            counts[task.payload_type] += 1
    return tuple(counts.items())


def resolve_local_testlogs_root(
    *,
    explicit: Path | None,
    workspace: Path,
    cwd: Path,
) -> Path | None:
    """Resolve legacy TESTLOGS_DIR precedence without invoking Bazel recursively."""
    if explicit is not None:
        if not explicit.is_dir():
            raise DiscoveryError(f"TESTLOGS_DIR is not a directory: {explicit}")
        return explicit.resolve()
    candidates = (workspace / "bazel-testlogs", cwd / "bazel-testlogs")
    for candidate in candidates:
        if candidate.is_dir():
            return candidate.resolve()
    return None


def discover_file_tasks(
    scan_roots: Iterable[ScanRoot],
    *,
    max_depth: int = 0,
    staged_output_keys: Iterable[str] = (),
) -> DiscoveryResult:
    """Discover sources once and assign stable IDs without reading payload bodies."""
    if max_depth < 0:
        raise DiscoveryError("max_depth must be non-negative")
    normalized_roots = _normalize_scan_roots(scan_roots)
    selected_for_staging = frozenset(
        key.replace("\\", "/").lstrip("/") for key in staged_output_keys if key
    )
    outputs_by_key: dict[str, list[DiscoveredOutput]] = {}
    for scan_root in normalized_roots:
        for output_path in _find_test_outputs(scan_root.path, max_depth=max_depth):
            output_key = canonical_output_directory_key(output_path.relative_to(scan_root.path).as_posix())
            outputs_by_key.setdefault(output_key, []).append(
                DiscoveredOutput(
                    path=output_path,
                    output_key=output_key,
                    scan_root=scan_root.path,
                    staged=scan_root.staged,
                )
            )

    warnings: list[str] = []
    outputs: list[DiscoveredOutput] = []
    for output_key in sorted(outputs_by_key):
        candidate_outputs = outputs_by_key[output_key]
        if output_key in selected_for_staging:
            staged_outputs = [output for output in candidate_outputs if output.staged]
            if staged_outputs:
                outputs.append(staged_outputs[0])
                continue
            warnings.append("selected_staged_output_missing")
            continue
        outputs.append(candidate_outputs[0])

    discovered_sources: list[tuple[Path, str, PayloadType, DiscoveredOutput]] = []
    seen_sources: set[str] = set()
    for output in outputs:
        resolved_output: Path | None = None
        for payload_type, relative_directory in _PAYLOAD_SUBDIRECTORIES:
            payload_directory = output.path / relative_directory
            if not payload_directory.is_dir():
                if payload_directory.is_symlink():
                    warnings.append("payload_symlink_skipped")
                continue
            try:
                if resolved_output is None:
                    resolved_output = output.path.resolve()
            except OSError:
                warnings.append("payload_symlink_skipped")
                continue
            resolved_directory = _safe_payload_directory(payload_directory, output.path, resolved_output)
            if resolved_directory is None:
                warnings.append("payload_symlink_skipped")
                continue
            try:
                with os.scandir(payload_directory) as entries:
                    sources = sorted(entries, key=lambda item: item.name)
            except OSError:
                warnings.append("payload_directory_unreadable")
                continue
            for entry in sources:
                suffix = Path(entry.name).suffix.lower()
                if _entry_is(entry.is_symlink):
                    if suffix in _PAYLOAD_SUFFIXES:
                        warnings.append("payload_symlink_skipped")
                    continue
                if suffix not in _PAYLOAD_SUFFIXES or not _entry_is(entry.is_file):
                    continue
                # The source is not a symlink, so it resolves in its
                # directory's resolved path.
                relative_source = f"{relative_directory.as_posix()}/{entry.name}"
                source_key = str(resolved_directory / entry.name)
                if source_key in seen_sources:
                    continue
                seen_sources.add(source_key)
                source_path = payload_directory / entry.name
                display_path = f"{output.output_key}/{relative_source}"
                discovered_sources.append(
                    (source_path, display_path, payload_type, output)
                )

    tasks = tuple(
        FileTask(
            task_id=f"file-{index:06d}",
            source_path=source_path,
            display_path=display_path,
            payload_type=payload_type,
            test_outputs_dir=output.path,
            output_key=output.output_key,
        )
        for index, (source_path, display_path, payload_type, output) in enumerate(
            discovered_sources,
            start=1,
        )
    )
    if max_depth > 0 and not outputs:
        warnings.append("max_depth_may_be_too_shallow")
    return DiscoveryResult(
        outputs=tuple(outputs),
        tasks=tasks,
        discovered_by_type=count_tasks_by_payload_type(tasks),
        warning_codes=tuple(dict.fromkeys(warnings)),
    )


class NativeDiscoveryUnavailable(RuntimeError):
    """ddtest could not discover the payloads; Python discovery applies."""


def discover_file_tasks_with_ddtest(
    ddtest: Path,
    scan_roots: Iterable[ScanRoot],
    *,
    max_depth: int = 0,
    staged_output_keys: Iterable[str] = (),
) -> DiscoveryResult:
    """discover_file_tasks, with ddtest walking and listing in parallel.

    ddtest instrument bazel discover applies the same rules, so the result is
    the one that discover_file_tasks returns; the roots are normalized here, as
    there, and a ddtest failure raises NativeDiscoveryUnavailable.
    """
    if max_depth < 0:
        raise DiscoveryError("max_depth must be non-negative")
    normalized_roots = _normalize_scan_roots(scan_roots)
    request = json.dumps({
        "schema_version": 1,
        "scan_roots": [{"path": str(root.path), "staged": root.staged} for root in normalized_roots],
        "max_depth": max_depth,
        "staged_output_keys": [key for key in staged_output_keys if key],
    })
    try:
        completed = subprocess.run([str(ddtest), "instrument", "bazel", "discover"], input=request,
                                   capture_output=True, text=True, encoding="utf-8", check=False)
        if completed.returncode != 0:
            raise ValueError(completed.stderr.strip() or f"exit status {completed.returncode}")
        report = json.loads(completed.stdout)
        if report.get("schema_version") != 1:
            raise ValueError("unexpected discovery report")
        outputs = tuple(DiscoveredOutput(path=Path(entry["path"]), output_key=entry["output_key"],
                                         scan_root=Path(entry["scan_root"]), staged=bool(entry["staged"]))
                        for entry in report["outputs"])
        tasks = tuple(
            FileTask(
                task_id=f"file-{index:06d}",
                source_path=outputs[source["output"]].path / "payloads" / source["directory"] / source["name"],
                display_path=f"{outputs[source['output']].output_key}/payloads/{source['directory']}/{source['name']}",
                payload_type=PayloadType(source["payload_type"]),
                test_outputs_dir=outputs[source["output"]].path,
                output_key=outputs[source["output"]].output_key,
            )
            for index, source in enumerate(report["sources"], start=1))
        warnings = tuple(str(code) for code in report["warnings"])
    except (OSError, ValueError, KeyError, IndexError, TypeError) as exc:
        raise NativeDiscoveryUnavailable(str(exc)) from exc
    return DiscoveryResult(outputs=outputs, tasks=tasks, discovered_by_type=count_tasks_by_payload_type(tasks),
                           warning_codes=warnings)


def payload_latest_mtime(discovery: DiscoveryResult) -> float:
    """Return the latest known source mtime, or zero when no source exists."""
    latest = 0.0
    for task in discovery.tasks:
        try:
            latest = max(latest, task.source_path.stat().st_mtime)
        except OSError:
            continue
    return latest


def tests_executed(scan_roots: Iterable[ScanRoot]) -> bool:
    """Detect Bazel test.log/test.xml markers without following directory links."""
    for scan_root in _normalize_scan_roots(scan_roots):
        for _directory, _subdirectories, filenames in os.walk(
            scan_root.path,
            followlinks=False,
        ):
            if "test.log" in filenames or "test.xml" in filenames:
                return True
    return False


def wait_for_quiescence(
    discover: Callable[[], DiscoveryResult],
    *,
    quiescent_seconds: int,
    max_wait_seconds: int,
    poll_seconds: float = 2.0,
    clock: Callable[[], float] = time.time,
    sleeper: Callable[[float], None] = time.sleep,
) -> QuiescenceResult:
    """Refresh discovery until payload files settle or the wait budget expires."""
    if quiescent_seconds < 0 or max_wait_seconds < 0:
        raise DiscoveryError("quiescence and maximum wait must be non-negative")
    if poll_seconds <= 0:
        raise DiscoveryError("poll_seconds must be positive")
    started = clock()
    while True:
        current = discover()
        now = clock()
        elapsed = max(0.0, now - started)
        if not current.tasks:
            if max_wait_seconds == 0:
                return QuiescenceResult(current, "no_payload_immediate", elapsed)
            if elapsed >= max_wait_seconds:
                return QuiescenceResult(current, "max_wait", elapsed)
        else:
            latest_mtime = payload_latest_mtime(current)
            idle = max(0.0, now - latest_mtime)
            if quiescent_seconds == 0 or idle >= quiescent_seconds:
                return QuiescenceResult(current, "quiescent", elapsed)
            if max_wait_seconds == 0 or elapsed >= max_wait_seconds:
                return QuiescenceResult(current, "max_wait", elapsed)
        remaining = max_wait_seconds - elapsed
        sleeper(min(poll_seconds, remaining) if max_wait_seconds else poll_seconds)


def _normalize_scan_roots(scan_roots: Iterable[ScanRoot]) -> tuple[ScanRoot, ...]:
    normalized: list[ScanRoot] = []
    seen: set[str] = set()
    for scan_root in scan_roots:
        if not scan_root.path.is_dir():
            raise DiscoveryError(f"testlogs scan root is not a directory: {scan_root.path}")
        resolved = scan_root.path.resolve()
        key = str(resolved)
        if key in seen:
            continue
        seen.add(key)
        normalized.append(ScanRoot(resolved, scan_root.staged))
    return tuple(normalized)


def _find_test_outputs(root: Path, *, max_depth: int) -> tuple[Path, ...]:
    return find_test_output_directories(root, max_depth=max_depth)


def _entry_is(check: Callable[[], bool]) -> bool:
    """A DirEntry type check that is false on errors, as Path's checks are."""
    try:
        return check()
    except OSError:
        return False


def _safe_payload_directory(path: Path, output: Path, resolved_output: Path) -> Path | None:
    """Return the resolved payload directory if it is real and inside its output.

    Rejecting symlinks is not enough: a Windows junction is not a symlink to
    is_symlink() and can lead outside the output, so the resolved directory
    must also lie below the output's resolved path.
    """
    current = output
    for part in path.relative_to(output).parts:
        current /= part
        if current.is_symlink():
            return None
    try:
        resolved = path.resolve()
        resolved.relative_to(resolved_output)
    except (OSError, ValueError):
        return None
    return resolved
