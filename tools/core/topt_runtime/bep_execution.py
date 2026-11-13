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
import json
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


@dataclass(frozen=True)
class FreshnessPolicy:
    source_required: bool
    strict_bep: bool


def resolve_freshness_policy(mode: str, source: str, *, ci: bool = False) -> FreshnessPolicy:
    """Resolve auto once: a selected BEP is strict, even outside CI.

    The uploader requires a source in CI; doctor callers do not pass ci and
    retain their source-free local diagnostics. Execution logs cannot prove
    BEP topology and retain their narrower authorization contract.
    """
    return FreshnessPolicy(
        mode == "required" or (mode == "auto" and ci),
        source == "bep" and mode in {"required", "auto"},
    )


def _normalized_event_id(value):
    if isinstance(value, dict):
        return {re.sub(r"(?<!^)(?=[A-Z])", "_", key).lower(): _normalized_event_id(item)
                for key, item in value.items()}
    if isinstance(value, list):
        return [_normalized_event_id(item) for item in value]
    return value


def bep_topology_errors(events: list[dict], invocation: str, execution_identity) -> tuple[tuple[str, str], ...]:
    """Check announced graph closure and independent TestSummary counts.

    Empty label means a stream-wide error. Test-specific errors apply only to
    identified instrumented targets, or the consumer's exact expected list.
    Counts are compared arithmetically, never expanded into a Cartesian graph.
    """
    received, announced = set(), {}
    results, summaries = {}, {}
    cached_identities = set()
    errors: list[tuple[str, str]] = []
    started = finished = False
    last = []
    for index, event in enumerate(events):
        event_id = _normalized_event_id(event.get("id", {}))
        if not isinstance(event_id, dict) or not event_id:
            errors.append(("", "invalid BEP event identity"))
            continue
        key = json.dumps(event_id, sort_keys=True, separators=(",", ":"))
        received.add(key)
        started |= "started" in event_id and isinstance(event.get("started"), dict)
        finished |= "build_finished" in event_id and isinstance(event.get("finished"), dict)
        if event.get("lastMessage", event.get("last_message", False)) is True:
            last.append(index)
        children = event.get("children", [])
        if not isinstance(children, list):
            errors.append(("", "invalid BEP event children"))
            continue
        for child in children:
            child = _normalized_event_id(child)
            if not isinstance(child, dict) or not child:
                errors.append(("", "invalid BEP child identity"))
                continue
            child_key = json.dumps(child, sort_keys=True, separators=(",", ":"))
            test_id = child.get("test_result", child.get("test_summary", {}))
            label = test_id.get("label", "") if isinstance(test_id, dict) else ""
            announced[child_key] = label
        result_id = event_id.get("test_result")
        if isinstance(result_id, dict) and isinstance(result_id.get("label"), str):
            identity = execution_identity(invocation, result_id)
            results[identity] = event
            result = _normalized_event_id(event.get("testResult", event.get("test_result", {})))
            if isinstance(result, dict):
                info = result.get("execution_info", {})
                if result.get("cached_locally") is True or (isinstance(info, dict) and info.get("cached_remotely") is True):
                    cached_identities.add(identity)
            if not isinstance(event.get("testResult", event.get("test_result")), dict):
                errors.append((identity[1], "BEP TestResult was aborted or has no result payload: " + identity[1]))
        summary_id = event_id.get("test_summary")
        if isinstance(summary_id, dict) and isinstance(summary_id.get("label"), str):
            config = execution_identity(invocation, summary_id)[2]
            summary = event.get("testSummary", event.get("test_summary"))
            summaries[(summary_id["label"], config)] = _normalized_event_id(summary)
    if not started or not finished or last != [len(events) - 1]:
        errors.append(("", "BEP stream is incomplete: require started, BuildFinished and a final last_message event"))
    for key in sorted(announced.keys() - received):
        errors.append((announced[key], "BEP announced event is missing: " + key))
    grouped: dict[tuple, list[tuple]] = {}
    for identity in results:
        grouped.setdefault(identity[1:3], []).append(identity)
    for label, config in sorted(grouped.keys() | summaries.keys()):
        identities = grouped.get((label, config), [])
        summary = summaries.get((label, config))
        if not isinstance(summary, dict):
            errors.append((label, "BEP TestSummary is missing: " + label))
            continue
        values = [summary.get(name, 0) for name in ("total_run_count", "run_count", "shard_count", "attempt_count")]
        if any(isinstance(v, bool) or not isinstance(v, int) or v < 0 for v in values):
            errors.append((label, "invalid BEP TestSummary counts: " + label))
            continue
        total, runs, shards, attempts = values
        runs, shards = max(1, runs), max(1, shards)
        logical = {identity[3:5] for identity in identities}
        valid_indexes = all(1 <= run <= runs and 1 <= shard <= shards for run, shard in logical)
        # Historical handoffs use an omitted shard (protobuf default zero) for
        # unsharded tests. It may not stand in for any explicitly sharded run.
        if shards == 1 and all(shard == 0 for _, shard in logical):
            valid_indexes = all(1 <= run <= runs for run, _ in logical)
        # Cached TestResult collapses all historical retries to attempt 1;
        # its summary retains their original timings/counts. Announcements and
        # logical run/shard coverage remain exact for both cached and fresh data.
        collapsed_cache = any(identity in cached_identities for identity in identities)
        count_matches = total >= len(identities) if collapsed_cache else total == len(identities)
        if not count_matches or len(logical) != runs * shards or not valid_indexes:
            errors.append((label, "BEP TestSummary topology does not match received runs/shards/attempts: " + label))
        # Bazel TestSummary.getNumAttempts takes the maximum total attempts
        # for any shard across runs (not the sum of per-run maxima).
        attempts_by_shard = {}
        for identity in identities:
            attempts_by_shard[identity[4]] = attempts_by_shard.get(identity[4], 0) + 1
        received_attempts = max(attempts_by_shard.values(), default=0)
        attempts_match = received_attempts <= attempts <= total if collapsed_cache else received_attempts == attempts
        if attempts and not attempts_match:
            errors.append((label, "BEP TestSummary attempt count does not match received attempts: " + label))
    return tuple(errors)


def first_bep_completeness_error(errors: Iterable[tuple[str, str]], labels: Iterable[str]) -> str | None:
    selected = set(labels)
    return next((message for label, message in errors if not label or label in selected), None)


def missing_test_shards(
    executions: Iterable[BepTestExecution],
    proven_outputs: set[tuple[str, str]],
    selected_labels: set[str],
    empty_outputs: set[tuple[str, str]] | None = None,
) -> list[tuple]:
    """A fresh attempt can satisfy only its own invocation/configuration/run/shard.

    A later populated retry can satisfy an earlier empty failed attempt of that
    same shard. Cached attempts never conceal fresh ones. Empty shards need
    separate positive completion evidence; missing data is not sufficient.
    """
    empty_outputs = empty_outputs or set()
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
                           if any((identity[1], key) in proven_outputs or (attempt.status == "PASSED" and (identity[1], key) in empty_outputs) for key in attempt.output_keys)}
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


def find_test_output_directories(
    root: Path, *, max_depth: int = 0, root_is_target: bool = False,
) -> tuple[Path, ...]:
    """Find current outputs and Bazel's renamed previous-attempt output roots.

    A direct sidecar or ZIP marks an output root and stops traversal. Without
    those markers, names and a child named payloads may also be packages or
    targets: defer selection until their descendants have been inspected.
    An expected target root is never an output itself. Never follow directory
    symlinks.
    """
    marked: set[Path] = set()
    payload_roots: set[Path] = set()
    unmarked: set[Path] = set()
    for directory, subdirectories, _filenames in os.walk(root, followlinks=False):
        current = Path(directory)
        relative = current.relative_to(root)
        depth = 0 if relative == Path(".") else len(relative.parts)
        subdirectories.sort()
        has_marker = "bazel_target_metadata.json" in _filenames or "outputs.zip" in _filenames
        has_payloads = "payloads" in subdirectories
        retry_root = is_retry_output_directory(current.parent.name, current.name) and (has_marker or has_payloads)
        if (current != root or not root_is_target) and (current.name == "test.outputs" or retry_root):
            if has_marker:
                marked.add(current)
                subdirectories.clear()
                continue
            if has_payloads:
                payload_roots.add(current)
            else:
                unmarked.add(current)
        if max_depth > 0 and depth >= max_depth:
            subdirectories.clear()

    # Prefer actual output roots to similarly named package/target ancestors.
    # Core-only outputs have no sidecar; their payload root still owns names
    # such as payloads/tests/nested/test.outputs inside its payload tree.
    parents = {parent for path in marked | payload_roots for parent in path.parents}
    selected = marked | (payload_roots - parents)
    unmarked = {path for path in unmarked
        if path not in parents and selected.isdisjoint(path.parents)}
    parents = {parent for path in unmarked for parent in path.parents}
    return tuple(sorted(selected | (unmarked - parents), key=lambda path: path.as_posix()))


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


def completed_empty_test_session(payload: object) -> bool:
    """Mini explicitly completed a zero-tests session; hierarchy alone is not proof.

    This marker is already emitted by Mini. It is useful only when its file is
    bound to a fresh PASSED TestResult of this exact execution by BEP.
    """
    if not isinstance(payload, dict) or test_result_event_count(payload):
        return False
    events = payload.get("events", [])
    if not isinstance(events, list):
        return False
    for event in events:
        if not isinstance(event, dict) or event.get("type") != "test_session_end":
            continue
        content = event.get("content")
        if not isinstance(content, dict):
            continue
        meta, metrics = content.get("meta", {}), content.get("metrics", {})
        if not isinstance(meta, dict) or not isinstance(metrics, dict):
            continue
        session_id = content.get("test_session_id")
        exit_code = metrics.get("test.exit_code")
        if (meta.get("test.session.empty_reason") == "zero_tests" and meta.get("test.status") == "skip"
            and isinstance(session_id, int) and not isinstance(session_id, bool) and session_id > 0
            and exit_code == 0 and not isinstance(exit_code, bool) and content.get("error") == 0):
            return True
    return False
