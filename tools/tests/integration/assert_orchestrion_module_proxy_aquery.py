#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

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
    arguments: list[str] = field(default_factory=list)
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
    parser.add_argument(
        "--expected-orchestrion-mode",
        choices=("general", "test_optimization"),
        default="general",
        help="Expected Orchestrion mode on Orchestrion-enabled actions.",
    )
    parser.add_argument(
        "--required-test-optimization-pin-file",
        action="append",
        help=(
            "Pin-file basename that every non-stdlib Orchestrion action must "
            "declare in test_optimization mode. Repeat for fixture-specific "
            "pins such as orchestrion.yml."
        ),
    )
    parser.add_argument(
        "--require-plain-compile-in-test-optimization",
        action="store_true",
        help=(
            "Require non-Orchestrion customer and external test compile actions "
            "in test_optimization mode."
        ),
    )
    parser.add_argument(
        "--require-reduced-synthetic-testmain-link-inputs",
        action="store_true",
        help=(
            "Require test_optimization synthetic testmain GoLink actions to keep "
            "the synthetic manifest input while omitting the Orchestrion stdlib "
            "cache tree and proxy/pin-file inputs."
        ),
    )
    parser.add_argument(
        "--require-test-optimization-linker-flags",
        action="store_true",
        help=(
            "Require test_optimization synthetic testmain GoLink actions to pass "
            "-s and -w so test binaries skip symbol table and DWARF generation."
        ),
    )
    parser.add_argument(
        "--expected-test-optimization-linker-flag-count",
        type=int,
        default=None,
        help=(
            "When requiring test_optimization linker flags, require each of -s "
            "and -w to appear this many times on each synthetic testmain GoLink "
            "action."
        ),
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
    arguments: list[str] = []
    environment: dict[str, str] = {}
    input_dep_set_ids: list[int] = []

    idx = 1
    while idx < len(lines) - 1:
        line = lines[idx]
        if line.startswith("mnemonic:"):
            mnemonic = _strip_quoted(_parse_scalar(line, "mnemonic:"))
        elif line.startswith("arguments:"):
            arguments.append(_strip_quoted(_parse_scalar(line, "arguments:")))
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
    return Action(
        mnemonic=mnemonic,
        arguments=arguments,
        environment=environment,
        input_dep_set_ids=input_dep_set_ids,
    )


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


def _contains_path_fragment(paths: list[str], fragment: str) -> bool:
    normalized_fragment = fragment.replace("\\", "/")
    return any(normalized_fragment in path.replace("\\", "/") for path in paths)


def _contains_module_proxy_payload(paths: list[str]) -> bool:
    for path in paths:
        normalized = path.replace("\\", "/")
        if "module_proxy/" not in normalized:
            continue
        if normalized.endswith("module_proxy/root.marker"):
            continue
        return True
    return False


def _uses_orchestrion(action: Action) -> bool:
    """Return whether the action is expected to use Orchestrion inputs."""

    return "-orchestrion" in action.arguments


def _argument_value(arguments: list[str], flag: str) -> str | None:
    for idx, argument in enumerate(arguments):
        if argument == flag and idx + 1 < len(arguments):
            return arguments[idx + 1]
        if argument.startswith(flag + "="):
            return argument.split("=", 1)[1]
    return None


def _action_importpath(action: Action) -> str:
    return _argument_value(action.arguments, "-importpath") or ""


def _action_output(action: Action) -> str:
    return _argument_value(action.arguments, "-out") or _argument_value(action.arguments, "-o") or ""


def _is_fixture_go_tool_action(action: Action) -> bool:
    """Return whether an action belongs to the fixture Go tool transition proof."""

    return any("fixture_tool" in arg for arg in action.arguments)


def _is_rules_go_internal_compile_action(action: Action) -> bool:
    """Return whether a compile action belongs to rules_go's own helper binaries."""

    importpath = _action_importpath(action)
    if importpath.startswith("github.com/bazelbuild/rules_go/go/tools/"):
        return True
    output = _action_output(action).replace("\\", "/")
    return "/external/rules_go+/go/tools/" in output


def _is_synthetic_testmain_link_action(action: Action) -> bool:
    """Return whether a GoLink action links a generated Go test binary."""

    if action.mnemonic != "GoLink":
        return False
    main = (_argument_value(action.arguments, "-main") or "").replace("\\", "/")
    package_path = _argument_value(action.arguments, "-p") or ""
    return main.endswith("~testmain.a") and package_path in ("", "testmain")


def _assert_reduced_synthetic_testmain_link_inputs(action: Action, inputs: list[str]) -> None:
    main = (_argument_value(action.arguments, "-main") or "").replace("\\", "/")
    _require(
        main,
        "synthetic testmain GoLink is missing -main",
    )
    _require(
        not _uses_orchestrion(action),
        f"synthetic testmain GoLink unexpectedly passed -orchestrion (main={main!r})",
    )
    _require(
        _contains_path_suffix(inputs, main),
        f"synthetic testmain GoLink is missing main archive input {main}",
    )
    _require(
        _contains_path_suffix(inputs, main + ".orchestrion.pack"),
        f"synthetic testmain GoLink is missing synthetic packagefile manifest {main}.orchestrion.pack",
    )
    for suffix in ("orchestrion.tool.go", "orchestrion.yml"):
        _require(
            not _contains_path_suffix(inputs, suffix),
            f"synthetic testmain GoLink unexpectedly declared pin-file input {suffix}",
        )
    _require(
        not _contains_path_fragment(inputs, "stdlib_/gocache"),
        "synthetic testmain GoLink unexpectedly declared the Orchestrion stdlib cache directory as an input",
    )


def _assert_test_optimization_linker_flags(action: Action, expected_count: int | None) -> None:
    for flag in ("-s", "-w"):
        count = action.arguments.count(flag)
        if expected_count is None:
            _require(
                count > 0,
                f"synthetic testmain GoLink is missing test binary linker optimization flag {flag}",
            )
            continue
        _require(
            count == expected_count,
            (
                "synthetic testmain GoLink must pass test binary linker "
                f"optimization flag {flag} exactly {expected_count} time(s); got {count}"
            ),
        )


def _assert_expected_action(
    action: Action,
    inputs: list[str],
    require_proxy: bool,
    expected_orchestrion_mode: str,
    required_test_optimization_pin_files: list[str],
) -> None:
    env = action.environment
    if require_proxy:
        actual_mode = _argument_value(action.arguments, "-orchestrion_mode")
        _require(
            actual_mode == expected_orchestrion_mode,
            (
                f"{action.mnemonic} is missing -orchestrion_mode {expected_orchestrion_mode} "
                f"(got {actual_mode!r}, importpath={_action_importpath(action)!r}, output={_action_output(action)!r})"
            ),
        )
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
        if expected_orchestrion_mode == "test_optimization":
            if action.mnemonic != "GoStdlib":
                for suffix in required_test_optimization_pin_files:
                    _require(
                        _contains_path_suffix(inputs, suffix),
                        f"{action.mnemonic} in test_optimization mode is missing pin-file input {suffix}",
                    )
            _require(
                not _contains_path_suffix(inputs, "orchestrion.tool.go"),
                f"{action.mnemonic} in test_optimization mode should use the synthetic Test Optimization tool pin",
            )
            forbidden_runtime_fragments = [
                ".testoptimization/manifest.txt",
                "settings.json",
                "known_tests.json",
                "test_management.json",
                "_topt_bazel_metadata.json",
            ]
            for fragment in forbidden_runtime_fragments:
                _require(
                    not _contains_path_fragment(inputs, fragment),
                    f"{action.mnemonic} in test_optimization mode unexpectedly declared runtime data input {fragment}",
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
    if action.mnemonic in {"GoCompilePkg", "GoCompilePkgExternal"}:
        _require(
            "-stdlib_cache" not in action.arguments,
            f"{action.mnemonic} unexpectedly received -stdlib_cache",
        )
        _require(
            not _contains_path_fragment(inputs, "stdlib_/gocache"),
            f"{action.mnemonic} unexpectedly declared the Orchestrion stdlib cache directory as an input",
        )


def main() -> int:
    args = parse_args()
    required_test_optimization_pin_files = args.required_test_optimization_pin_file or ["go.mod"]
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

    orchestrion_actions = []
    orchestrion_stdlib_actions = []
    non_orchestrion_fixture_compile_actions = []
    non_orchestrion_external_test_compile_actions = []
    saw_plain_hello_external_test_compile = False
    fixture_go_tool_actions = []
    for action in compile_actions + stdlib_actions + link_actions:
        inputs = _action_inputs(action, artifacts, dep_sets, path_fragments)
        if (
            args.expected_orchestrion_mode == "test_optimization"
            and _is_rules_go_internal_compile_action(action)
        ):
            continue
        if _is_fixture_go_tool_action(action):
            fixture_go_tool_actions.append(action)
        require_proxy = _uses_orchestrion(action)
        if (
            args.expected_orchestrion_mode == "test_optimization"
            and action.mnemonic == "GoCompilePkgExternal"
            and require_proxy
            and not _is_fixture_go_tool_action(action)
        ):
            _require(False, "test_optimization mode unexpectedly passed -orchestrion to GoCompilePkgExternal")
        if (
            args.expected_orchestrion_mode == "test_optimization"
            and action.mnemonic in {"GoCompilePkg", "GoCompilePkgExternal"}
            and not require_proxy
            and not _is_fixture_go_tool_action(action)
        ):
            non_orchestrion_fixture_compile_actions.append(action)
            if action.mnemonic == "GoCompilePkgExternal":
                non_orchestrion_external_test_compile_actions.append(action)
                if _contains_path_suffix(inputs, "app/hello_external_test.go"):
                    saw_plain_hello_external_test_compile = True
        if require_proxy:
            orchestrion_actions.append(action)
            if action.mnemonic == "GoStdlib":
                orchestrion_stdlib_actions.append(action)
        _assert_expected_action(
            action,
            inputs,
            require_proxy=require_proxy,
            expected_orchestrion_mode=args.expected_orchestrion_mode,
            required_test_optimization_pin_files=required_test_optimization_pin_files,
        )

    _require(
        orchestrion_actions,
        "aquery did not contain any Orchestrion-enabled Go compile, stdlib, or link actions",
    )
    _require(
        orchestrion_stdlib_actions,
        "aquery did not contain any Orchestrion-enabled GoStdlib actions",
    )
    if args.expected_orchestrion_mode == "test_optimization" and args.require_plain_compile_in_test_optimization:
        _require(
            non_orchestrion_fixture_compile_actions,
            "test_optimization mode did not leave any fixture compile actions on the plain rules_go path",
        )
        _require(
            non_orchestrion_external_test_compile_actions,
            "test_optimization mode did not leave any external _test compile actions on the plain rules_go path",
        )
        _require(
            saw_plain_hello_external_test_compile,
            "test_optimization mode did not leave app/hello_external_test.go on the plain GoCompilePkgExternal path",
        )
    if args.expected_orchestrion_mode == "test_optimization" and args.require_reduced_synthetic_testmain_link_inputs:
        synthetic_testmain_link_actions = [
            action for action in link_actions
            if _is_synthetic_testmain_link_action(action)
        ]
        _require(
            synthetic_testmain_link_actions,
            "test_optimization mode did not produce a synthetic testmain GoLink action",
        )
        for action in synthetic_testmain_link_actions:
            _assert_reduced_synthetic_testmain_link_inputs(
                action,
                _action_inputs(action, artifacts, dep_sets, path_fragments),
            )
    if args.expected_orchestrion_mode == "test_optimization" and args.require_test_optimization_linker_flags:
        synthetic_testmain_link_actions = [
            action for action in link_actions
            if _is_synthetic_testmain_link_action(action)
        ]
        _require(
            synthetic_testmain_link_actions,
            "test_optimization mode did not produce a synthetic testmain GoLink action",
        )
        for action in synthetic_testmain_link_actions:
            _assert_test_optimization_linker_flags(
                action,
                args.expected_test_optimization_linker_flag_count,
            )
    _require(
        fixture_go_tool_actions,
        "aquery did not contain the fixture Go tool transition actions",
    )

    if args.expected_orchestrion_mode == "test_optimization":
        for action in fixture_go_tool_actions:
            _require(
                not _uses_orchestrion(action),
                f"{action.mnemonic} for fixture Go tool unexpectedly inherited Orchestrion",
            )
            _assert_expected_action(
                action,
                _action_inputs(action, artifacts, dep_sets, path_fragments),
                require_proxy=False,
                expected_orchestrion_mode=args.expected_orchestrion_mode,
                required_test_optimization_pin_files=required_test_optimization_pin_files,
            )

    for action in stdlib_list_actions:
        _assert_expected_action(
            action,
            _action_inputs(action, artifacts, dep_sets, path_fragments),
            require_proxy=False,
            expected_orchestrion_mode=args.expected_orchestrion_mode,
            required_test_optimization_pin_files=required_test_optimization_pin_files,
        )

    print("aquery offline-proxy wiring check passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
