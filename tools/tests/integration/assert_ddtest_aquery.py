#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Assert that a dd_topt_go_test is built by `ddtest instrument` in aquery output.

Reads `bazel aquery 'deps(<test>)' --output=jsonproto` and checks that the
test's packages, standard library and link use the instrumented SDK, that the
compile gets the registration file and the link Mini's testopt library.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

_SDK_REPO_FRAGMENT = "topt_go_ddtest_sdk_"
_MINI_REPO_FRAGMENT = "topt_go_ddtest_mini"
_REGISTRATION_SUFFIX = "_zz_dd_ci_visibility_test.go"
_GO_BUILD_MNEMONICS = {
    "GoCompilePkg",
    "GoCompilePkgExternal",
    "GoLink",
    "GoStdlib",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("aquery_jsonproto", type=Path, help="aquery --output=jsonproto file.")
    parser.add_argument(
        "--test-label",
        required=True,
        help="Label of the public test, such as //app:hello_test.",
    )
    parser.add_argument(
        "--expected-linker-flag-count",
        type=int,
        default=None,
        help="Times each of -s and -w must appear on the test's GoLink.",
    )
    parser.add_argument(
        "--require-test-runner-only-no-remote-exec",
        action="store_true",
        help="Require no-remote-exec on the public TestRunner and on no Go build action.",
    )
    return parser.parse_args()


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


class Graph:
    def __init__(self, data: dict) -> None:
        self._fragments = {fragment["id"]: fragment for fragment in data.get("pathFragments", [])}
        self._artifacts = {
            artifact["id"]: self._path(artifact["pathFragmentId"])
            for artifact in data.get("artifacts", [])
        }
        self._dep_sets = {dep_set["id"]: dep_set for dep_set in data.get("depSetOfFiles", [])}
        self.targets = {target["id"]: target["label"] for target in data.get("targets", [])}
        self.actions = data.get("actions", [])

    def _path(self, fragment_id: int) -> str:
        parts = []
        while fragment_id:
            fragment = self._fragments[fragment_id]
            parts.append(fragment["label"])
            fragment_id = fragment.get("parentId", 0)
        return "/".join(reversed(parts))

    def inputs(self, action: dict) -> list[str]:
        paths = set()
        pending = list(action.get("inputDepSetIds", []))
        seen = set()
        while pending:
            dep_set_id = pending.pop()
            if dep_set_id in seen:
                continue
            seen.add(dep_set_id)
            dep_set = self._dep_sets[dep_set_id]
            paths.update(self._artifacts[artifact_id] for artifact_id in dep_set.get("directArtifactIds", []))
            pending.extend(dep_set.get("transitiveDepSetIds", []))
        return sorted(paths)

    def label(self, action: dict) -> str:
        return self.targets.get(action.get("targetId"), "")


def _sdk(action: dict) -> str:
    arguments = action.get("arguments", [])
    if "-sdk" not in arguments:
        return ""
    index = arguments.index("-sdk")
    return arguments[index + 1] if index + 1 < len(arguments) else ""


def _execution_info(action: dict) -> set[str]:
    return {entry["key"] for entry in action.get("executionInfo", [])}


def _is_test_action(graph: Graph, action: dict, test_label: str) -> bool:
    # The macro builds the test as a hidden raw go_test named after the public one.
    return graph.label(action).startswith(test_label + "__")


def main() -> int:
    args = parse_args()
    graph = Graph(json.loads(args.aquery_jsonproto.read_text(encoding="utf-8")))
    test_label = args.test_label

    compiles = [
        action
        for action in graph.actions
        if action["mnemonic"] in {"GoCompilePkg", "GoCompilePkgExternal"} and _is_test_action(graph, action, test_label)
    ]
    _require(
        {action["mnemonic"] for action in compiles} == {"GoCompilePkg", "GoCompilePkgExternal"},
        f"{test_label}: expected internal and external test compiles, got {sorted(action['mnemonic'] for action in compiles)}",
    )
    for action in compiles:
        _require(
            _SDK_REPO_FRAGMENT in _sdk(action),
            f"{action['mnemonic']} of {graph.label(action)} uses SDK {_sdk(action)!r}, not the instrumented one",
        )
    _require(
        any(path.endswith(_REGISTRATION_SUFFIX) for action in compiles for path in graph.inputs(action)),
        f"{test_label}: no test compile has the registration file *{_REGISTRATION_SUFFIX}",
    )

    links = [action for action in graph.actions if action["mnemonic"] == "GoLink" and _is_test_action(graph, action, test_label)]
    _require(len(links) == 1, f"{test_label}: expected one GoLink, got {len(links)}")
    link = links[0]
    _require(_SDK_REPO_FRAGMENT in _sdk(link), f"GoLink of {test_label} uses SDK {_sdk(link)!r}, not the instrumented one")
    _require(
        any(_MINI_REPO_FRAGMENT in path and "/testopt" in path for path in graph.inputs(link)),
        f"GoLink of {test_label} does not link Mini's testopt library",
    )
    if args.expected_linker_flag_count is not None:
        for flag in ("-s", "-w"):
            count = link.get("arguments", []).count(flag)
            _require(
                count == args.expected_linker_flag_count,
                f"GoLink of {test_label} passes {flag} {count} time(s), want {args.expected_linker_flag_count}",
            )

    stdlibs = [action for action in graph.actions if action["mnemonic"] == "GoStdlib"]
    _require(
        any(_SDK_REPO_FRAGMENT in _sdk(action) for action in stdlibs),
        f"no GoStdlib action uses the instrumented SDK: {sorted(_sdk(action) for action in stdlibs)}",
    )

    if args.require_test_runner_only_no_remote_exec:
        runners = [
            action
            for action in graph.actions
            if action["mnemonic"] == "TestRunner" and graph.label(action) == test_label
        ]
        _require(runners, f"{test_label}: aquery has no TestRunner")
        _require(
            all("no-remote-exec" in _execution_info(action) for action in runners),
            f"{test_label}: the TestRunner lacks no-remote-exec",
        )
        leaked = sorted(
            {
                action["mnemonic"]
                for action in graph.actions
                if action["mnemonic"] in _GO_BUILD_MNEMONICS and "no-remote-exec" in _execution_info(action)
            }
        )
        _require(not leaked, "no-remote-exec leaked from the TestRunner to Go build actions: " + ", ".join(leaked))

    print(f"aquery: {test_label} is built by ddtest instrument")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
