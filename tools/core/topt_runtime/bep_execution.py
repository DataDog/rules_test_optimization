# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Execution-bound test evidence shared by doctor and uploader.

Directory names locate artifacts; they never establish execution identity.
"""

from __future__ import annotations
from dataclasses import dataclass
import os
from pathlib import Path, PurePosixPath
import re
from typing import Iterable


@dataclass(frozen=True)
class BepTestExecution:
    identity: tuple[str, str, str, int, int, int]  # invocation, label, configuration, run, shard, attempt
    cached: bool
    status: str
    output_keys: frozenset[str]
    carriers: tuple[tuple[str, str], ...] = ()


def missing_test_shards(
    executions: Iterable[BepTestExecution],
    proven_outputs: set[tuple[str, str]],
    selected_labels: set[str],
) -> list[tuple]:
    """A fresh attempt can satisfy only its own invocation/configuration/run/shard.

    A later populated retry can satisfy an earlier empty failed attempt of that
    same shard. Cached attempts never conceal fresh ones. Empty shards need
    separate positive completion evidence; missing data is not sufficient.
    """
    shards: dict[tuple, list[BepTestExecution]] = {}
    for execution in executions:
        if execution.identity[1] in selected_labels:
            shards.setdefault(execution.identity[:-1], []).append(execution)
    # Bazel's TestStatus enum: only an explicit failed/aborted attempt may be
    # satisfied by a later populated retry. A passed or unknown empty result
    # is not evidence, and an earlier payload cannot mask a later lost attempt.
    # https://github.com/bazelbuild/bazel/blob/8.8.2/src/main/java/com/google/devtools/build/lib/buildeventstream/proto/build_event_stream.proto
    retryable_statuses = {"TIMEOUT", "FAILED", "INCOMPLETE", "REMOTE_FAILURE", "FAILED_TO_BUILD", "TOOL_HALTED_BEFORE_TESTING"}
    missing = []
    for identity, attempts in sorted(shards.items()):
        fresh = [attempt for attempt in attempts if not attempt.cached]
        proven_attempts = {attempt.identity[-1] for attempt in fresh
                           if any((identity[1], key) in proven_outputs for key in attempt.output_keys)}
        for attempt in fresh:
            number = attempt.identity[-1]
            if number in proven_attempts:
                continue
            if attempt.status in retryable_statuses and any(later > number for later in proven_attempts):
                continue
            missing.append(identity)
            break
    return missing


def ambiguous_execution_outputs(executions: Iterable[BepTestExecution]) -> frozenset[str]:
    """Reject output keys reused by independent or conflicting executions."""
    by_key: dict[str, set[tuple]] = {}
    by_identity: dict[tuple, set[BepTestExecution]] = {}
    ambiguous: set[str] = set()
    for execution in executions:
        by_identity.setdefault(execution.identity, set()).add(execution)
        for key in execution.output_keys:
            by_key.setdefault(key, set()).add(execution.identity)
        carriers_by_key: dict[str, set[str]] = {}
        for key, carrier in execution.carriers:
            carriers_by_key.setdefault(key, set()).add(carrier)
        # These are complete normalized carriers (directories or outputs.zip),
        # not the individual payload/log/xml files of a directory.
        for key, carriers in carriers_by_key.items():
            if len(carriers) > 1:
                ambiguous.add(key)
    ambiguous.update(key for key, identities in by_key.items() if len(identities) > 1)
    for records in by_identity.values():
        if len(records) > 1:
            ambiguous.update(key for record in records for key in record.output_keys)
    return frozenset(ambiguous)


_RETRY_OUTPUT_DIRECTORY = re.compile(r"attempt_[0-9]+[.]outputs")


def is_retry_output_directory(parent: str, name: str) -> bool:
    """Recognize Bazel's paired previous-attempt output directory."""
    return parent == "test_attempts" and _RETRY_OUTPUT_DIRECTORY.fullmatch(name) is not None


def canonical_output_directory_key(value: str) -> str:
    """Give a physical retry output root the same virtual test.outputs suffix."""
    path = PurePosixPath(value.replace("\\", "/"))
    if is_retry_output_directory(path.parent.name, path.name):
        return path.as_posix() + "/test.outputs"
    return path.as_posix()


def find_test_output_directories(root: Path, *, max_depth: int = 0) -> tuple[Path, ...]:
    """Find current outputs and Bazel's renamed previous-attempt output roots.

    Do not descend into payloads or mistake a target named like a retry root
    for its child test.outputs directory. Never follow directory symlinks.
    """
    found = []
    for directory, subdirectories, _filenames in os.walk(root, followlinks=False):
        current = Path(directory)
        relative = current.relative_to(root)
        depth = 0 if relative == Path(".") else len(relative.parts)
        subdirectories.sort()
        retry_root = (is_retry_output_directory(current.parent.name, current.name)
                      and ("payloads" in subdirectories or "bazel_target_metadata.json" in _filenames or "outputs.zip" in _filenames))
        if current.name == "test.outputs" or retry_root:
            found.append(current)
            subdirectories.clear()
            continue
        if max_depth > 0 and depth >= max_depth:
            subdirectories.clear()
    return tuple(sorted(found, key=lambda path: path.as_posix()))


def test_result_event_count(payload: object) -> int:
    """Count typed test events and legacy CI test spans, excluding hierarchy ends."""
    if not isinstance(payload, dict) or not isinstance(payload.get("events"), list):
        return 0
    count = 0
    for event in payload["events"]:
        if not isinstance(event, dict):
            continue
        event_type = event.get("type")
        content = event.get("content")
        if isinstance(content, dict) and (event_type == "test" or (
                event_type in (None, "span") and content.get("type") == "test")):
            count += 1
    return count


def exclusively_cached_labels(executions: Iterable[BepTestExecution]) -> set[str]:
    cached: set[str] = set()
    fresh: set[str] = set()
    for execution in executions:
        (cached if execution.cached else fresh).add(execution.identity[1])
    return cached.difference(fresh)
