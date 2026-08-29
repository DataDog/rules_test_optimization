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
import os
from pathlib import Path
import time
from typing import Callable, Iterable

from .models import FileTask, PayloadType


_PAYLOAD_SUBDIRECTORIES = (
    (PayloadType.TEST, Path("payloads") / "tests"),
    (PayloadType.COVERAGE, Path("payloads") / "coverage"),
    (PayloadType.TELEMETRY, Path("payloads") / "telemetry"),
)
_PAYLOAD_SUFFIXES = frozenset({".json", ".msgpack"})


class DiscoveryError(ValueError):
    """Configured testlogs discovery cannot be performed safely."""


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
    candidates: dict[str, list[DiscoveredOutput]] = {}
    for scan_root in normalized_roots:
        for output_path in _find_test_outputs(scan_root.path, max_depth=max_depth):
            output_key = output_path.relative_to(scan_root.path).as_posix()
            candidates.setdefault(output_key, []).append(
                DiscoveredOutput(
                    path=output_path,
                    output_key=output_key,
                    scan_root=scan_root.path,
                    staged=scan_root.staged,
                )
            )

    warnings: list[str] = []
    outputs: list[DiscoveredOutput] = []
    for output_key in sorted(candidates):
        choices = candidates[output_key]
        if output_key in selected_for_staging:
            staged = [choice for choice in choices if choice.staged]
            if staged:
                outputs.append(staged[0])
                continue
            warnings.append("selected_staged_output_missing")
            continue
        outputs.append(choices[0])

    task_values: list[tuple[Path, str, PayloadType, DiscoveredOutput]] = []
    seen_sources: set[str] = set()
    for output in outputs:
        for payload_type, relative_directory in _PAYLOAD_SUBDIRECTORIES:
            payload_directory = output.path / relative_directory
            if not payload_directory.is_dir():
                continue
            for source_path in sorted(payload_directory.iterdir(), key=lambda item: item.name):
                if source_path.is_symlink():
                    if source_path.suffix.lower() in _PAYLOAD_SUFFIXES:
                        warnings.append("payload_symlink_skipped")
                    continue
                if not source_path.is_file() or source_path.suffix.lower() not in _PAYLOAD_SUFFIXES:
                    continue
                source_key = str(source_path.resolve(strict=False))
                if source_key in seen_sources:
                    continue
                seen_sources.add(source_key)
                relative_source = source_path.relative_to(output.path).as_posix()
                display_path = f"{output.output_key}/{relative_source}"
                task_values.append((source_path, display_path, payload_type, output))

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
            task_values,
            start=1,
        )
    )
    counts = tuple(
        (
            payload_type,
            sum(int(task.payload_type is payload_type) for task in tasks),
        )
        for payload_type in PayloadType
    )
    if max_depth > 0 and not outputs:
        warnings.append("max_depth_may_be_too_shallow")
    return DiscoveryResult(
        outputs=tuple(outputs),
        tasks=tasks,
        discovered_by_type=counts,
        warning_codes=tuple(dict.fromkeys(warnings)),
    )


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
    found: list[Path] = []
    for directory, subdirectories, _filenames in os.walk(root, followlinks=False):
        current = Path(directory)
        relative = current.relative_to(root)
        depth = 0 if relative == Path(".") else len(relative.parts)
        subdirectories.sort()
        if current.name == "test.outputs":
            found.append(current)
            subdirectories.clear()
            continue
        if max_depth > 0 and depth >= max_depth:
            subdirectories.clear()
    return tuple(sorted(found, key=lambda path: path.as_posix()))
