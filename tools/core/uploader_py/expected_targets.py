# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Invocation-scoped expected-target validation before file scheduling."""

from __future__ import annotations

from dataclasses import dataclass, replace
import json
from pathlib import Path, PurePosixPath
import re
from typing import Iterable

from topt_runtime.runfiles import RunfileResolutionError, RunfilesResolver

from .discovery import DiscoveryResult
from .models import PayloadType


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
) -> ExpectedTargetsPlan:
    """Merge the generated static list and optional schema-v1 target file."""
    static = tuple(_validate_label(label) for label in static_targets)
    if len(static) != len(set(static)):
        raise ExpectedTargetsError("static expected_targets contains duplicates")
    candidates = tuple(path for path in expected_targets_file_paths if path)
    if not candidates:
        return ExpectedTargetsPlan(tuple(sorted(static)), "static" if static else "discovery")
    try:
        target_file = resolver.resolve_file(candidates)
    except RunfileResolutionError as exc:
        raise ExpectedTargetsError("expected_targets_file could not be resolved") from exc
    dynamic = _load_target_file(target_file)
    if static and set(static) != set(dynamic):
        raise ExpectedTargetsError(
            "static expected_targets and expected_targets_file contain different target sets"
        )
    if static:
        return ExpectedTargetsPlan(tuple(sorted(static)), "static_and_file")
    return ExpectedTargetsPlan(dynamic, "file")


def select_expected_outputs(
    discovery: DiscoveryResult,
    plan: ExpectedTargetsPlan,
    *,
    allow_missing: bool = False,
) -> DiscoveryResult:
    """Filter discovered outputs and stamp tasks with their expected target."""
    if not plan.targets:
        return discovery
    outputs_by_target: dict[str, list[str]] = {target: [] for target in plan.targets}
    target_by_output_key: dict[str, str] = {}
    for output in discovery.outputs:
        matches = [
            target
            for target in plan.targets
            if _output_belongs_to_target(output.output_key, target)
        ]
        if len(matches) > 1:
            most_specific = max(len(_target_output_parts(target)) for target in matches)
            matches = [
                target
                for target in matches
                if len(_target_output_parts(target)) == most_specific
            ]
        if len(matches) > 1:
            raise ExpectedTargetsError(
                f"test.outputs path matches multiple expected targets: {output.output_key}"
            )
        if not matches:
            continue
        target = matches[0]
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
    counts = tuple(
        (
            payload_type,
            sum(int(task.payload_type is payload_type) for task in selected_tasks),
        )
        for payload_type in PayloadType
    )
    return DiscoveryResult(
        outputs=selected_outputs,
        tasks=selected_tasks,
        discovered_by_type=counts,
        warning_codes=discovery.warning_codes,
    )


def _load_target_file(path: Path) -> tuple[str, ...]:
    try:
        value = json.loads(path.read_bytes().decode("utf-8-sig"))
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
    if value != value.strip() or any(ord(character) <= 32 or ord(character) == 127 for character in value):
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


def _output_belongs_to_target(output_key: str, label: str) -> bool:
    expected_parts = _target_output_parts(label)
    output_parts = PurePosixPath(output_key.replace("\\", "/")).parts
    if not output_parts or output_parts[-1] != "test.outputs":
        return False
    if output_parts[: len(expected_parts)] != expected_parts:
        return False
    attempt_parts = output_parts[len(expected_parts) : -1]
    return all(_BAZEL_TEST_ATTEMPT_DIRECTORY.fullmatch(part) for part in attempt_parts)


def _target_output_parts(label: str) -> tuple[str, ...]:
    package, target = label[2:].split(":", 1)
    return tuple(filter(None, package.split("/"))) + tuple(target.split("/"))
