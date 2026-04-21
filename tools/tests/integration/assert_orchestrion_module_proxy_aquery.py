#!/usr/bin/env python3
"""Validate Orchestrion offline-proxy action wiring from Bazel aquery textproto."""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class PathFragment:
    """Represents a Bazel path fragment entry from aquery textproto."""

    fragment_id: int
    label: str
    parent_id: int | None = None


@dataclass
class Artifact:
    """Represents an aquery artifact entry."""

    artifact_id: int
    path_fragment_id: int


@dataclass
class DepSetOfFiles:
    """Represents an aquery dep-set node for action inputs."""

    dep_set_id: int
    direct_artifact_ids: list[int] = field(default_factory=list)
    transitive_dep_set_ids: list[int] = field(default_factory=list)


@dataclass
class Action:
    """Represents the subset of aquery action data needed by this check."""

    mnemonic: str
    environment: dict[str, str] = field(default_factory=dict)
    input_dep_set_ids: list[int] = field(default_factory=list)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Assert Orchestrion offline-proxy wiring in Bazel aquery textproto output.",
    )
    parser.add_argument(
        "aquery_textproto",
        type=Path,
        help="Path to the aquery --output=textproto file to validate.",
    )
    return parser.parse_args()


def _strip_quoted(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    return value


def _parse_scalar(line: str, prefix: str) -> str:
    return line.split(prefix, 1)[1].strip()


def _top_level_blocks(text: str) -> list[tuple[str, list[str]]]:
    """Collect top-level textproto blocks without needing the protobuf schema."""

    blocks: list[tuple[str, list[str]]] = []
    current_name: str | None = None
    current_lines: list[str] = []
    depth = 0

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if current_name is None:
            if line.endswith("{"):
                current_name = line[:-1].strip()
                current_lines = [line]
                depth = 1
            continue

        current_lines.append(line)
        depth += line.count("{")
        depth -= line.count("}")
        if depth == 0:
            blocks.append((current_name, current_lines))
            current_name = None
            current_lines = []

    return blocks


def _parse_path_fragment(lines: list[str]) -> PathFragment:
    fragment_id = None
    label = None
    parent_id = None
    for line in lines[1:-1]:
        if line.startswith("id:"):
            fragment_id = int(_parse_scalar(line, "id:"))
        elif line.startswith("label:"):
            label = _strip_quoted(_parse_scalar(line, "label:"))
        elif line.startswith("parent_id:"):
            parent_id = int(_parse_scalar(line, "parent_id:"))
    if fragment_id is None or label is None:
        raise ValueError(f"invalid path fragment block: {lines}")
    return PathFragment(fragment_id=fragment_id, label=label, parent_id=parent_id)


def _parse_artifact(lines: list[str]) -> Artifact:
    artifact_id = None
    path_fragment_id = None
    for line in lines[1:-1]:
        if line.startswith("id:"):
            artifact_id = int(_parse_scalar(line, "id:"))
        elif line.startswith("path_fragment_id:"):
            path_fragment_id = int(_parse_scalar(line, "path_fragment_id:"))
    if artifact_id is None or path_fragment_id is None:
        raise ValueError(f"invalid artifact block: {lines}")
    return Artifact(artifact_id=artifact_id, path_fragment_id=path_fragment_id)


def _parse_dep_set(lines: list[str]) -> DepSetOfFiles:
    dep_set_id = None
    direct_artifact_ids: list[int] = []
    transitive_dep_set_ids: list[int] = []
    for line in lines[1:-1]:
        if line.startswith("id:"):
            dep_set_id = int(_parse_scalar(line, "id:"))
        elif line.startswith("direct_artifact_ids:"):
            direct_artifact_ids.append(int(_parse_scalar(line, "direct_artifact_ids:")))
        elif line.startswith("transitive_dep_set_ids:"):
            transitive_dep_set_ids.append(int(_parse_scalar(line, "transitive_dep_set_ids:")))
    if dep_set_id is None:
        raise ValueError(f"invalid dep_set_of_files block: {lines}")
    return DepSetOfFiles(
        dep_set_id=dep_set_id,
        direct_artifact_ids=direct_artifact_ids,
        transitive_dep_set_ids=transitive_dep_set_ids,
    )


def _parse_action(lines: list[str]) -> Action:
    mnemonic = None
    environment: dict[str, str] = {}
    input_dep_set_ids: list[int] = []

    idx = 1
    while idx < len(lines) - 1:
        line = lines[idx]
        if line.startswith("mnemonic:"):
            mnemonic = _strip_quoted(_parse_scalar(line, "mnemonic:"))
        elif line.startswith("input_dep_set_ids:"):
            input_dep_set_ids.append(int(_parse_scalar(line, "input_dep_set_ids:")))
        elif line == "environment_variables {":
            key = None
            value = ""
            idx += 1
            while idx < len(lines) - 1 and lines[idx] != "}":
                nested = lines[idx]
                if nested.startswith("key:"):
                    key = _strip_quoted(_parse_scalar(nested, "key:"))
                elif nested.startswith("value:"):
                    value = _strip_quoted(_parse_scalar(nested, "value:"))
                idx += 1
            if key is not None:
                environment[key] = value
        idx += 1

    if mnemonic is None:
        raise ValueError(f"invalid action block: {lines}")
    return Action(mnemonic=mnemonic, environment=environment, input_dep_set_ids=input_dep_set_ids)


def _build_path(path_fragments: dict[int, PathFragment], fragment_id: int) -> str:
    labels: list[str] = []
    current_id: int | None = fragment_id
    while current_id is not None:
        fragment = path_fragments[current_id]
        labels.append(fragment.label)
        current_id = fragment.parent_id
    return "/".join(reversed(labels))


def _collect_artifact_ids(
    dep_sets: dict[int, DepSetOfFiles],
    dep_set_id: int,
    seen_dep_sets: set[int],
) -> set[int]:
    if dep_set_id in seen_dep_sets:
        return set()
    seen_dep_sets.add(dep_set_id)
    dep_set = dep_sets[dep_set_id]
    artifact_ids = set(dep_set.direct_artifact_ids)
    for child_id in dep_set.transitive_dep_set_ids:
        artifact_ids |= _collect_artifact_ids(dep_sets, child_id, seen_dep_sets)
    return artifact_ids


def _action_inputs(
    action: Action,
    artifacts: dict[int, Artifact],
    dep_sets: dict[int, DepSetOfFiles],
    path_fragments: dict[int, PathFragment],
) -> list[str]:
    artifact_ids: set[int] = set()
    for dep_set_id in action.input_dep_set_ids:
        artifact_ids |= _collect_artifact_ids(dep_sets, dep_set_id, set())
    inputs: list[str] = []
    for artifact_id in sorted(artifact_ids):
        artifact = artifacts.get(artifact_id)
        if artifact is None:
            continue
        inputs.append(_build_path(path_fragments, artifact.path_fragment_id))
    return inputs


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _contains_path_suffix(paths: list[str], suffix: str) -> bool:
    normalized_suffix = suffix.replace("\\", "/")
    return any(path.replace("\\", "/").endswith(normalized_suffix) for path in paths)


def _contains_module_proxy_payload(paths: list[str]) -> bool:
    for path in paths:
        normalized = path.replace("\\", "/")
        if "module_proxy/" not in normalized:
            continue
        if normalized.endswith("module_proxy/root.marker"):
            continue
        return True
    return False


def _assert_expected_action(
    action: Action,
    inputs: list[str],
    require_proxy: bool,
) -> None:
    env = action.environment
    if require_proxy:
        _require(
            "RULES_GO_ORCHESTRION_MODULE_PROXY_ROOT" in env,
            f"{action.mnemonic} is missing RULES_GO_ORCHESTRION_MODULE_PROXY_ROOT",
        )
        _require(
            "RULES_GO_ORCHESTRION_TOOL_VERSION_FILE" in env,
            f"{action.mnemonic} is missing RULES_GO_ORCHESTRION_TOOL_VERSION_FILE",
        )
        _require(
            _contains_path_suffix(inputs, "module_proxy/root.marker"),
            f"{action.mnemonic} is missing module_proxy/root.marker from declared inputs",
        )
        _require(
            _contains_path_suffix(inputs, "orchestrion_version.txt"),
            f"{action.mnemonic} is missing orchestrion_version.txt from declared inputs",
        )
        _require(
            _contains_module_proxy_payload(inputs),
            f"{action.mnemonic} is missing module_proxy payload files from declared inputs",
        )
        _require(
            all("proxy.golang.org" not in value for value in env.values()),
            f"{action.mnemonic} still references proxy.golang.org in its action environment",
        )
        _require(
            all("sum.golang.org" not in value for value in env.values()),
            f"{action.mnemonic} still references sum.golang.org in its action environment",
        )
        return

    forbidden_env = {
        "RULES_GO_ORCHESTRION_MODULE_PROXY_ROOT",
        "RULES_GO_ORCHESTRION_TOOL_VERSION_FILE",
    }
    forbidden_suffixes = [
        "module_proxy/root.marker",
        "orchestrion_version.txt",
    ]
    _require(
        forbidden_env.isdisjoint(env),
        f"{action.mnemonic} unexpectedly received offline-proxy env vars",
    )
    for suffix in forbidden_suffixes:
        _require(
            not _contains_path_suffix(inputs, suffix),
            f"{action.mnemonic} unexpectedly declared {suffix} as an input",
        )
    _require(
        not any("module_proxy/" in path.replace("\\", "/") for path in inputs),
        f"{action.mnemonic} unexpectedly declared module_proxy files as inputs",
    )


def main() -> int:
    args = parse_args()
    text = args.aquery_textproto.read_text(encoding="utf-8")

    path_fragments: dict[int, PathFragment] = {}
    artifacts: dict[int, Artifact] = {}
    dep_sets: dict[int, DepSetOfFiles] = {}
    actions: list[Action] = []

    for block_name, lines in _top_level_blocks(text):
        if block_name == "path_fragments":
            fragment = _parse_path_fragment(lines)
            path_fragments[fragment.fragment_id] = fragment
        elif block_name == "artifacts":
            artifact = _parse_artifact(lines)
            artifacts[artifact.artifact_id] = artifact
        elif block_name == "dep_set_of_files":
            dep_set = _parse_dep_set(lines)
            dep_sets[dep_set.dep_set_id] = dep_set
        elif block_name == "actions":
            actions.append(_parse_action(lines))

    compile_actions = [a for a in actions if a.mnemonic in {"GoCompilePkg", "GoCompilePkgExternal"}]
    stdlib_actions = [a for a in actions if a.mnemonic == "GoStdlib"]
    link_actions = [a for a in actions if a.mnemonic == "GoLink"]
    stdlib_list_actions = [a for a in actions if a.mnemonic == "GoStdlibList"]

    _require(compile_actions, "aquery did not contain any GoCompilePkg or GoCompilePkgExternal actions")
    _require(stdlib_actions, "aquery did not contain any GoStdlib actions")
    _require(link_actions, "aquery did not contain any GoLink actions")
    _require(stdlib_list_actions, "aquery did not contain any GoStdlibList actions")

    for action in compile_actions + stdlib_actions + link_actions:
        _assert_expected_action(action, _action_inputs(action, artifacts, dep_sets, path_fragments), require_proxy=True)

    for action in stdlib_list_actions:
        _assert_expected_action(action, _action_inputs(action, artifacts, dep_sets, path_fragments), require_proxy=False)

    print("aquery offline-proxy wiring check passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
