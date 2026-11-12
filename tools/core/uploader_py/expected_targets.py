# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Validate expected Bazel targets and select their discovered outputs.

The pre-worker gate prevents unrelated or missing targets from entering the queue.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import json
from pathlib import Path, PurePosixPath
import re
from typing import Iterable

from topt_runtime.bep_execution import is_retry_output_directory
from topt_runtime.runfiles import RunfileResolutionError, RunfilesResolver

from .discovery import DiscoveryResult, count_tasks_by_payload_type, read_target_label
from .json_utils import strict_json_loads


class ExpectedTargetsError(ValueError):
    """Expected target inputs do not identify a safe complete local set."""


_BAZEL_TEST_ATTEMPT_DIRECTORY = re.compile(
    r"(?:shard|run)_\d+_of_\d+|attempt_\d+"
)


@dataclass(frozen=True)
class ExpectedTargetsPlan:
    targets: tuple[str, ...] = ()
    source: str = "discovery"


def load_expected_targets(
    *,
    static_targets: Iterable[str],
    expected_targets_file_paths: Iterable[str],
    resolver: RunfilesResolver,
    runtime_targets: Iterable[str] = (),
    runtime_selection: bool = False,
    runtime_targets_file: Path | None = None,
) -> ExpectedTargetsPlan:
    """Merge generated and runtime targets into one validated selection."""
    static = tuple(_validate_label(label) for label in static_targets)
    if len(static) != len(set(static)):
        raise ExpectedTargetsError("static expected_targets contains duplicates")
    candidates = tuple(path for path in expected_targets_file_paths if path)
    configured = tuple(sorted(static))
    configured_source = "static" if static else "discovery"
    if candidates:
        try:
            target_file = resolver.resolve_file(candidates)
        except RunfileResolutionError as exc:
            raise ExpectedTargetsError("expected_targets_file could not be resolved") from exc
        dynamic = _load_target_file(target_file)
        if static and set(static) != set(dynamic):
            raise ExpectedTargetsError(
                "static expected_targets and expected_targets_file contain different target sets"
            )
        configured = tuple(sorted(static)) if static else dynamic
        configured_source = "static_and_file" if static else "file"

    runtime = tuple(_validate_label(label) for label in runtime_targets)
    if len(runtime) != len(set(runtime)):
        raise ExpectedTargetsError(
            "runtime --expected-target arguments contain duplicate target labels"
        )
    file_targets = _load_target_file(runtime_targets_file) if runtime_targets_file is not None else ()
    runtime = tuple(sorted(set(runtime).union(file_targets)))
    if runtime:
        if configured and set(configured) != set(runtime):
            raise ExpectedTargetsError(
                "configured and runtime expected targets contain different target sets"
            )
        source = "runtime_and_configured" if configured else "runtime"
        return ExpectedTargetsPlan(runtime, source)
    if runtime_selection:
        raise ExpectedTargetsError(
            "runtime selection requires at least one --expected-target argument or a nonempty --expected-targets-file"
        )
    return ExpectedTargetsPlan(configured, configured_source)


def select_expected_outputs(
    discovery: DiscoveryResult,
    plan: ExpectedTargetsPlan,
    *,
    allow_missing: bool = False,
    bep_outputs: Iterable[tuple[str, str]] = (),
) -> DiscoveryResult:
    """Filter discovered outputs and stamp tasks with their expected target."""
    if not plan.targets:
        return discovery
    outputs_by_target: dict[str, list[str]] = {target: [] for target in plan.targets}
    target_by_output_key: dict[str, str] = {}
    index = _TargetOutputIndex(plan.targets)
    bep_labels_by_key: dict[str, set[str]] = {}
    for label, key in bep_outputs:
        bep_labels_by_key.setdefault(key, set()).add(label)
    for output in discovery.outputs:
        physical_retry = is_retry_output_directory(output.path.parent.name, output.path.name)
        bep_labels = bep_labels_by_key.get(output.output_key, set())
        matches = index.matches(output.output_key, allow_retry_pairs=physical_retry or bool(bep_labels))
        if len(matches) > 1:
            raise ExpectedTargetsError(
                f"test.outputs path matches multiple expected targets: {output.output_key}"
            )
        if not matches:
            continue
        target = matches[0]
        if len(bep_labels) == 1 and bep_labels != {target}:
            raise ExpectedTargetsError("BEP output target conflicts with expected target: " + output.output_key)
        if physical_retry or (bep_labels and "/test_attempts/" in output.output_key):
            declared = read_target_label(output.path)
            if declared and declared != target:
                raise ExpectedTargetsError("bazel.target metadata conflicts with expected target: " + output.output_key)
        outputs_by_target[target].append(output.output_key)
        target_by_output_key[output.output_key] = target

    missing = tuple(
        target for target in plan.targets if not outputs_by_target[target]
    )
    if missing and not allow_missing:
        raise ExpectedTargetsError(
            "expected targets have no local test.outputs: " + ", ".join(missing)
        )
    selected_outputs = tuple(
        output
        for output in discovery.outputs
        if output.output_key in target_by_output_key
    )
    selected_tasks = tuple(
        replace(task, target_label=target_by_output_key[task.output_key or ""])
        for task in discovery.tasks
        if (task.output_key or "") in target_by_output_key
    )
    return DiscoveryResult(
        outputs=selected_outputs,
        tasks=selected_tasks,
        discovered_by_type=count_tasks_by_payload_type(selected_tasks),
        warning_codes=discovery.warning_codes,
    )


def _load_target_file(path: Path) -> tuple[str, ...]:
    try:
        value = strict_json_loads(path.read_bytes().decode("utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ExpectedTargetsError("expected_targets_file is not valid JSON") from exc
    if not isinstance(value, dict) or set(value) != {"schema_version", "targets"}:
        raise ExpectedTargetsError(
            "expected_targets_file must contain exactly schema_version and targets"
        )
    if value["schema_version"] != 1:
        raise ExpectedTargetsError("expected_targets_file schema_version must be 1")
    targets = value["targets"]
    if not isinstance(targets, list):
        raise ExpectedTargetsError("expected_targets_file targets must be an array")
    normalized = tuple(_validate_label(label) for label in targets)
    if len(normalized) != len(set(normalized)):
        raise ExpectedTargetsError("expected_targets_file contains duplicate labels")
    if normalized != tuple(sorted(normalized)):
        raise ExpectedTargetsError("expected_targets_file targets must be sorted")
    return normalized


def _validate_label(value: object) -> str:
    if not isinstance(value, str):
        raise ExpectedTargetsError("expected target labels must be strings")
    contains_control_character = any(
        ord(character) <= 32 or ord(character) == 127 for character in value
    )
    if value != value.strip() or contains_control_character:
        raise ExpectedTargetsError(f"invalid expected target label: {value!r}")
    if value.startswith("@") or not value.startswith("//"):
        raise ExpectedTargetsError(f"expected target must be local: {value!r}")
    body = value[2:]
    if body.count(":") != 1:
        raise ExpectedTargetsError(f"expected target must contain one colon: {value!r}")
    package, target = body.split(":", 1)
    if not target or "*" in value or "..." in value or "\\" in value:
        raise ExpectedTargetsError(f"expected target must be fully expanded: {value!r}")
    for component in tuple(filter(None, package.split("/"))) + tuple(target.split("/")):
        if component in {".", "..", ""}:
            raise ExpectedTargetsError(f"invalid expected target path: {value!r}")
    if package.startswith("/") or package.endswith("/") or "//" in package:
        raise ExpectedTargetsError(f"invalid expected target package: {value!r}")
    return value


class _TargetOutputIndex:
    """Match deepest target roots without scanning the target catalog per output."""

    def __init__(self, targets: Iterable[str]) -> None:
        self._labels_by_parts: dict[tuple[str, ...], list[str]] = {}
        for label in targets:
            self._labels_by_parts.setdefault(_target_output_parts(label), []).append(label)

    def matches(self, output_key: str, *, allow_retry_pairs: bool = False) -> list[str]:
        parts = PurePosixPath(output_key.replace("\\", "/")).parts
        if not parts or parts[-1] != "test.outputs":
            return []
        # Once a suffix is not a Bazel attempt component, no shallower target
        # can own this output. Check the exact (deepest) root first.
        length = len(parts) - 1
        while length > 0:
            labels = self._labels_by_parts.get(parts[:length])
            if labels:
                return labels
            if _BAZEL_TEST_ATTEMPT_DIRECTORY.fullmatch(parts[length - 1]):
                length -= 1
            elif allow_retry_pairs and length >= 2 and is_retry_output_directory(parts[length - 2], parts[length - 1]):
                length -= 2
            else:
                break
        return []


def _target_output_parts(label: str) -> tuple[str, ...]:
    package, target = label[2:].split(":", 1)
    return tuple(filter(None, package.split("/"))) + tuple(target.split("/"))
