#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Verify generated rules_go consumer patch profiles."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import shutil
import subprocess
import sys
import tempfile

try:
    from tools.dev.compact_execution_log import CompactAction, read_compact_actions
    from tools.dev.generate_rules_go_consumer_patch import (
        DEFAULT_PROFILE_ROOT,
        REPO_ROOT,
        copy_filtered_tree,
        generate_consumer_patch,
        profile_path,
        read_private_safe_patterns,
        sha256_file,
        verify_private_safe,
        verify_private_safe_text,
    )
    from tools.dev.materialize_rules_go_fork import download_upstream
    from tools.dev.rules_go_fork_registry import DEFAULT_REGISTRY, ForkSelection, load_registry
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from tools.dev.compact_execution_log import CompactAction, read_compact_actions
    from tools.dev.generate_rules_go_consumer_patch import (
        DEFAULT_PROFILE_ROOT,
        REPO_ROOT,
        copy_filtered_tree,
        generate_consumer_patch,
        profile_path,
        read_private_safe_patterns,
        sha256_file,
        verify_private_safe,
        verify_private_safe_text,
    )
    from tools.dev.materialize_rules_go_fork import download_upstream
    from tools.dev.rules_go_fork_registry import DEFAULT_REGISTRY, ForkSelection, load_registry


def verify_profiles(
    *,
    registry_path: Path,
    profile_root: Path,
    profile: str,
    output_dir: Path,
    public_denylist: Path | None,
    private_blocklist_file: Path | None,
    upstream: str | None = None,
    run_functional_smoke: bool = True,
    bazel: Path = REPO_ROOT / "bazelw",
    go_version: str = "1.25.0",
    orchestrion_version: str = "v1.12.0",
    dd_trace_go_version: str = "v2.9.1",
) -> None:
    """Generate and validate one profile patch for selected upstreams."""
    registry = load_registry(registry_path)
    output_dir.mkdir(parents=True, exist_ok=True)
    generated_paths: list[Path] = []
    private_safe_patterns = read_private_safe_patterns(public_denylist, private_blocklist_file)
    upstream_ids = registry.upstream_ids()
    if upstream is not None:
        if upstream not in upstream_ids:
            raise ValueError(
                "unknown upstream %r; supported upstreams: %s"
                % (upstream, ", ".join(upstream_ids))
            )
        upstream_ids = [upstream]
    with temporary_smoke_root() as smoke_root:
        for upstream_id in upstream_ids:
            selection = registry.resolve(upstream_id, "base")
            patch = output_dir / ("%s-%s.patch" % (upstream_id, profile))
            manifest = output_dir / ("%s-%s.MANIFEST.json" % (upstream_id, profile))
            generate_consumer_patch(
                registry_path=registry_path,
                upstream=upstream_id,
                variant="base",
                profile_path=profile_path(profile_root, profile),
                output=patch,
                manifest=manifest,
                check_private_safe=public_denylist is not None or private_blocklist_file is not None,
                public_denylist=public_denylist,
                private_blocklist_file=private_blocklist_file,
            )
            if patch.stat().st_size == 0:
                raise ValueError("generated patch is empty: %s" % patch)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            if data.get("patch_sha256") != sha256_file(patch):
                raise ValueError("manifest SHA does not match generated patch: %s" % manifest)
            if data.get("included_paths") != sorted(data.get("included_paths", [])):
                raise ValueError("manifest included_paths are not sorted: %s" % manifest)
            if data.get("excluded_paths") != sorted(data.get("excluded_paths", [])):
                raise ValueError("manifest excluded_paths are not sorted: %s" % manifest)
            if run_functional_smoke:
                print("running functional smoke for %s/%s" % (upstream_id, profile))
                verify_workspace_runtime_functional_smoke(
                    selection=selection,
                    patch=patch,
                    work_root=smoke_root / upstream_id,
                    bazel=bazel,
                    go_version=go_version,
                    orchestrion_version=orchestrion_version,
                    dd_trace_go_version=dd_trace_go_version,
                    private_safe_patterns=private_safe_patterns,
                )
            generated_paths.extend([patch, manifest])
            print("verified %s" % patch)
    if public_denylist is not None or private_blocklist_file is not None:
        verify_private_safe(
            paths=generated_paths,
            public_denylist=public_denylist,
            private_blocklist_file=private_blocklist_file,
        )
    if private_blocklist_file is not None:
        verify_private_safe(
            paths=modified_tracked_files(private_blocklist_file),
            public_denylist=public_denylist,
            private_blocklist_file=private_blocklist_file,
        )


def verify_workspace_runtime_functional_smoke(
    *,
    selection: ForkSelection,
    patch: Path,
    work_root: Path,
    bazel: Path,
    go_version: str,
    orchestrion_version: str,
    dd_trace_go_version: str,
    private_safe_patterns: list[str],
) -> None:
    """Verify a generated patch in two independent consumer-style builds."""
    upstream_source = download_upstream(selection, work_root / "download")
    common_flags = [
        "--noenable_bzlmod",
        "--enable_workspace",
    ]
    consumer_flags = cgo_reproducibility_flags()
    plain_snapshots = []
    optimized_snapshots = []
    for run_name in ("first", "second"):
        run_root = work_root / run_name
        rules_go_root = run_root / "rules_go_patched"
        workspace = run_root / "workspace"
        output_user_root = run_root / "bazel_output_user_root"
        copy_filtered_tree(upstream_source, rules_go_root)
        run_private_safe(
            [
                "git",
                "-C",
                rules_go_root.as_posix(),
                "apply",
                "--binary",
                "-p1",
                patch.as_posix(),
            ],
            private_safe_patterns=private_safe_patterns,
        )
        write_smoke_workspace(
            workspace=workspace,
            rules_go_root=rules_go_root,
            go_version=go_version,
            orchestrion_version=orchestrion_version,
            dd_trace_go_version=dd_trace_go_version,
        )
        isolated_cache_flags = [
            "--disk_cache=%s" % (run_root / "disk_cache").as_posix(),
            "--remote_cache=",
        ]
        mode_flags = [*common_flags, *consumer_flags, *isolated_cache_flags]
        run_bazel(
            bazel,
            output_user_root,
            workspace,
            ["build", *common_flags, "@go_sdk//:builder"],
            private_safe_patterns=private_safe_patterns,
        )
        optimized_snapshots.append(
            run_orchestrion_reproducibility_snapshot(
                bazel,
                output_user_root,
                workspace,
                command="test",
                mode_flags=mode_flags,
                target="//app:hello_test.topt",
                raw_target="//app:hello_test.topt__raw_go_test",
                execution_log=run_root / "execution.compact.zst",
                private_safe_patterns=private_safe_patterns,
            )
        )
        plain_snapshots.append(
            run_plain_reproducibility_snapshot(
                bazel,
                output_user_root,
                workspace,
                command="build",
                mode_flags=mode_flags,
                target="//app:hello_test",
                private_safe_patterns=private_safe_patterns,
            )
        )

    first_plain, second_plain = plain_snapshots
    first_orchestrion, second_orchestrion = optimized_snapshots
    assert_plain_stdlib_cache(first_plain.stdlib_cache, patch)
    assert_plain_stdlib_cache(second_plain.stdlib_cache, patch)
    assert_orchestrion_stdlib_cache(first_orchestrion.stdlib_cache, patch)
    assert_orchestrion_stdlib_cache(second_orchestrion.stdlib_cache, patch)
    if first_plain.stdlib_cache != second_plain.stdlib_cache:
        raise ValueError(
            "plain stdlib cache inventories differ for %s: %s"
            % (
                patch,
                describe_snapshot_difference(
                    first_plain.stdlib_cache,
                    second_plain.stdlib_cache,
                ),
            )
        )
    if first_plain.action_keys != second_plain.action_keys:
        raise ValueError(
            "plain GoStdlib action keys differ for %s: %s"
            % (
                patch,
                describe_mapping_difference(
                    first_plain.action_keys,
                    second_plain.action_keys,
                ),
            )
        )
    if first_plain.outputs != second_plain.outputs:
        raise ValueError(
            "plain GoStdlib outputs differ for %s: %s"
            % (
                patch,
                describe_mapping_difference(
                    first_plain.outputs,
                    second_plain.outputs,
                ),
            )
        )
    if first_orchestrion.stdlib_cache != second_orchestrion.stdlib_cache:
        raise ValueError(
            "Test Optimization stdlib cache inventories differ for %s: %s"
            % (
                patch,
                describe_snapshot_difference(
                    first_orchestrion.stdlib_cache,
                    second_orchestrion.stdlib_cache,
                ),
            )
        )
    assert_no_actionable_reproducibility_findings(
        first_orchestrion.actions,
        second_orchestrion.actions,
        patch,
    )


def cgo_reproducibility_flags() -> list[str]:
    """Mirror consumer CGO/debug flags without adding deterministic policy."""
    return [
        "--compilation_mode=fastbuild",
        "--incompatible_strict_action_env",
        "--experimental_exec_configuration_distinguisher=diff_to_affected",
        "--experimental_platform_in_output_dir",
        "--@io_bazel_rules_go//go/config:pure=False",
        "--@io_bazel_rules_go//go/config:linkmode=normal",
        "--strip=never",
        "--copt=-fno-omit-frame-pointer",
        "--copt=-g",
        "--copt=-UNDEBUG",
    ]


def describe_snapshot_difference(
    first: StdlibCacheSnapshot, second: StdlibCacheSnapshot
) -> str:
    """Describe canonical cache entries that differ between two executions."""
    differences = []
    for relative in sorted(set(first.inventory) | set(second.inventory)):
        first_value = first.inventory.get(relative, "missing")
        second_value = second.inventory.get(relative, "missing")
        if first_value != second_value:
            differences.append("%s=(%s != %s)" % (relative, first_value, second_value))
    if first.manifest != second.manifest:
        differences.append("manifest contents differ")
    return ", ".join(differences) or "snapshot metadata differs"


def describe_mapping_difference(first: dict[str, str], second: dict[str, str]) -> str:
    """Describe a bounded set of differing action keys or output digests."""
    differences = []
    for key in sorted(set(first) | set(second)):
        first_value = first.get(key, "missing")
        second_value = second.get(key, "missing")
        if first_value != second_value:
            differences.append("%s=(%s != %s)" % (key, first_value, second_value))
    if len(differences) > 20:
        differences = [*differences[:20], "... and %d more" % (len(differences) - 20)]
    return ", ".join(differences) or "snapshot metadata differs"


def write_smoke_workspace(
    *,
    workspace: Path,
    rules_go_root: Path,
    go_version: str,
    orchestrion_version: str,
    dd_trace_go_version: str,
) -> None:
    """Create a WORKSPACE-mode CGO project with a real .topt transition."""
    app = workspace / "app"
    transition_repo = workspace / "transition_rule"
    app.mkdir(parents=True, exist_ok=True)
    transition_repo.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(
        REPO_ROOT / "modules/go/topt_go_orchestrion.bzl",
        transition_repo / "topt_go_orchestrion.bzl",
    )
    transition_repo.joinpath("WORKSPACE").write_text(
        'workspace(name = "datadog_go_transition")\n',
        encoding="utf-8",
    )
    transition_repo.joinpath("BUILD.bazel").write_text(
        'exports_files(["topt_go_orchestrion.bzl"])\n',
        encoding="utf-8",
    )
    workspace.joinpath("WORKSPACE").write_text(
        """workspace(name = "profile_smoke")

local_repository(
    name = "io_bazel_rules_go",
    path = "%s",
)

local_repository(
    name = "datadog_go_transition",
    path = "%s",
    repo_mapping = {"@rules_go": "@io_bazel_rules_go"},
)

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "bazel_gazelle",
    sha256 = "b760f7fe75173886007f7c2e616a21241208f3d90e8657dc65d36a771e916b6a",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/bazel-gazelle/releases/download/v0.39.1/bazel-gazelle-v0.39.1.tar.gz",
        "https://github.com/bazelbuild/bazel-gazelle/releases/download/v0.39.1/bazel-gazelle-v0.39.1.tar.gz",
    ],
)

load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")
load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies")
load("@io_bazel_rules_go//go:orchestrion_workspace.bzl", "go_orchestrion_tool_repo")

go_rules_dependencies()
go_register_toolchains(version = "%s")
gazelle_dependencies()

go_orchestrion_tool_repo(
    version = "%s",
    dd_trace_go_version = "%s",
    go_sdk_root = "@go_sdk//:ROOT",
    go_sdk_version = "%s",
)
"""
        % (
            rules_go_root.as_posix(),
            transition_repo.as_posix(),
            go_version,
            orchestrion_version,
            dd_trace_go_version,
            go_version,
        ),
        encoding="utf-8",
    )
    app.joinpath("BUILD.bazel").write_text(
        """load("@datadog_go_transition//:topt_go_orchestrion.bzl", "orch_go_test")
load("@io_bazel_rules_go//go:def.bzl", "go_library", "go_test")

exports_files(["metadata.json"])

go_library(
    name = "hello_lib",
    srcs = ["hello.go", "hello_cgo.go"],
    cgo = True,
    importpath = "example.com/profile_smoke/app",
)

go_test(
    name = "hello_test",
    srcs = ["hello_test.go"],
    embed = [":hello_lib"],
)

go_test(
    name = "hello_test.topt__raw_go_test",
    srcs = ["hello_test.go"],
    embed = [":hello_lib"],
    tags = ["manual"],
)

orch_go_test(
    name = "hello_test.topt",
    actual = ":hello_test.topt__raw_go_test",
    metadata = ":metadata.json",
    orchestrion_mode = "test_optimization",
)
""",
        encoding="utf-8",
    )
    app.joinpath("hello.go").write_text(
        'package app\n\nfunc Greeting() string { return CgoGreeting() }\n',
        encoding="utf-8",
    )
    app.joinpath("hello_cgo.go").write_text(
        '''package app

/*
#include <stdlib.h>
static int profile_smoke_value(void) { return 42; }
*/
import "C"

func CgoGreeting() string {
	if C.profile_smoke_value() == 42 {
		return "hello"
	}
	return "bad"
}
''',
        encoding="utf-8",
    )
    app.joinpath("hello_test.go").write_text(
        'package app\n\nimport "testing"\n\nfunc TestGreeting(t *testing.T) { if Greeting() != "hello" { t.Fatal("bad") } }\n',
        encoding="utf-8",
    )
    app.joinpath("metadata.json").write_text("{}\n", encoding="utf-8")


def run_bazel(
    bazel: Path,
    output_user_root: Path,
    cwd: Path,
    args: list[str],
    private_safe_patterns: list[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run Bazel through this repository's wrapper in a temporary workspace."""
    env = smoke_bazel_env(output_user_root)
    result = subprocess.run(
        [
            bazel.as_posix(),
            "--batch",
            "--output_user_root=%s" % output_user_root.as_posix(),
            *args,
        ],
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    patterns = private_safe_patterns or []
    verify_private_safe_text("bazel stdout", result.stdout, patterns)
    verify_private_safe_text("bazel stderr", result.stderr, patterns)
    if result.returncode != 0:
        details = "\n".join(
            part[-4000:]
            for part in (result.stdout.strip(), result.stderr.strip())
            if part
        )
        raise RuntimeError(
            "bazel command failed (%s):\n%s" % (" ".join(args), details)
        )
    return result


@dataclass(frozen=True)
class StdlibCacheSnapshot:
    """Canonical declared-cache inventory plus its manifest contents."""

    inventory: dict[str, str]
    manifest: str | None


@dataclass(frozen=True)
class ReproducibilitySnapshot:
    """Ordinary stdlib cache, action keys, and outputs from one build."""

    stdlib_cache: StdlibCacheSnapshot
    action_keys: dict[str, str]
    outputs: dict[str, str]


@dataclass(frozen=True)
class OptimizedReproducibilitySnapshot:
    """Instrumented cache and Reprise-compatible actions from one cold build."""

    stdlib_cache: StdlibCacheSnapshot
    actions: dict[tuple[str, str, tuple[str, ...]], CompactAction]


def run_plain_reproducibility_snapshot(
    bazel: Path,
    output_user_root: Path,
    workspace: Path,
    *,
    command: str,
    mode_flags: list[str],
    target: str,
    private_safe_patterns: list[str] | None = None,
) -> ReproducibilitySnapshot:
    """Build once and capture the ordinary CGO stdlib action and bytes."""
    run_bazel(
        bazel,
        output_user_root,
        workspace,
        [command, *mode_flags, target],
        private_safe_patterns=private_safe_patterns,
    )
    aquery = run_bazel(
        bazel,
        output_user_root,
        workspace,
        [
            "aquery",
            *mode_flags,
            "--output=jsonproto",
            'mnemonic("GoStdlib", deps(%s))' % target,
        ],
        private_safe_patterns=private_safe_patterns,
    )
    aquery_data = json.loads(aquery.stdout)
    assert_cgo_aquery_actions(
        aquery_data,
        expected_instrumented=False,
    )
    stdlib_cache = plain_stdlib_cache_from_aquery(aquery_data, workspace)
    action_keys, outputs = action_snapshot_from_aquery(
        aquery_data,
        workspace=workspace,
        target_label=target,
    )
    if not action_keys:
        raise ValueError(
            "plain reproducibility aquery for %s is missing GoStdlib" % target
        )
    return ReproducibilitySnapshot(
        stdlib_cache=stdlib_cache,
        action_keys=action_keys,
        outputs=outputs,
    )


def plain_stdlib_cache_from_aquery(
    data: dict[str, object], workspace: Path
) -> StdlibCacheSnapshot:
    """Inspect only gocache outputs declared by ordinary GoStdlib actions."""
    path_fragments = {
        int(fragment["id"]): fragment for fragment in data.get("pathFragments", [])
    }
    artifacts = {
        int(artifact["id"]): resolve_path_fragment(
            int(artifact["pathFragmentId"]), path_fragments
        )
        for artifact in data.get("artifacts", [])
    }
    cache_paths = set()
    for action in data.get("actions", []):
        if action.get("mnemonic") != "GoStdlib":
            continue
        for output_id in action.get("outputIds", []):
            relative = artifacts[int(output_id)]
            if PurePosixPath(relative).name == "gocache":
                cache_paths.add(relative)
    if not cache_paths:
        raise ValueError("plain reproducibility aquery has no GoStdlib gocache")
    for relative in sorted(cache_paths):
        snapshot = canonical_tree_inventory(workspace / relative)
        if snapshot.inventory or snapshot.manifest is not None:
            raise ValueError(
                "ordinary GoStdlib gocache is not empty: %s contains %s"
                % (relative, sorted(snapshot.inventory))
            )
    return StdlibCacheSnapshot(inventory={}, manifest=None)


def run_orchestrion_reproducibility_snapshot(
    bazel: Path,
    output_user_root: Path,
    workspace: Path,
    *,
    command: str,
    mode_flags: list[str],
    target: str,
    raw_target: str,
    execution_log: Path,
    private_safe_patterns: list[str] | None = None,
) -> OptimizedReproducibilitySnapshot:
    """Run one real .topt target and read its compact execution log."""
    stdlib_cache = run_stdlib_inventory(
        bazel,
        output_user_root,
        workspace,
        command=command,
        mode_flags=mode_flags,
        target=target,
        execution_log=execution_log,
        private_safe_patterns=private_safe_patterns,
    )
    if not execution_log.is_file() or execution_log.stat().st_size == 0:
        raise ValueError("Bazel did not write compact execution log %s" % execution_log)
    actions = select_reproducibility_actions(
        read_compact_actions(execution_log),
        raw_target=raw_target,
    )
    assert_cgo_reproducibility_actions(actions.values(), expected_instrumented=True)
    required = {
        "GoCompilePkg",
        "GoLink",
        "GoStdlib",
        "GoSyntheticTestmainHelpers",
    }
    found = {action.mnemonic for action in actions.values()}
    missing = sorted(required - found)
    if missing:
        raise ValueError(
            "compact execution log for %s is missing actions: %s"
            % (target, ", ".join(missing))
        )
    return OptimizedReproducibilitySnapshot(
        stdlib_cache=stdlib_cache,
        actions=actions,
    )


def select_reproducibility_actions(
    actions: list[CompactAction], *, raw_target: str
) -> dict[tuple[str, str, tuple[str, ...]], CompactAction]:
    """Select the four action families whose outputs feed a .topt binary."""
    selected = {}
    for action in actions:
        if action.mnemonic in {"GoStdlib", "GoSyntheticTestmainHelpers"}:
            pass
        elif not bazel_labels_match(action.target_label, raw_target):
            continue
        elif action.mnemonic == "GoCompilePkg":
            if not any("~testmain.a" in path for path in action.listed_outputs):
                continue
        elif action.mnemonic != "GoLink":
            continue

        if action.identity in selected:
            raise ValueError("duplicate compact-log action identity: %s" % (action.identity,))
        if not action.actual_outputs:
            raise ValueError(
                "compact-log action has no output digests: %s" % (action.identity,)
            )
        selected[action.identity] = action
    return selected


def bazel_labels_match(actual: str, expected: str) -> bool:
    """Compare main-repository labels across canonical-label spellings."""
    return actual.lstrip("@") == expected


@dataclass(frozen=True)
class ReproducibilityFinding:
    """One output or action-set difference between independent builds."""

    action: CompactAction
    kind: str
    differing_outputs: tuple[str, ...]


def actionable_reproducibility_findings(
    first: dict[tuple[str, str, tuple[str, ...]], CompactAction],
    second: dict[tuple[str, str, tuple[str, ...]], CompactAction],
) -> list[ReproducibilityFinding]:
    """Return output-changing findings, even when cache digests are absent."""
    findings = []
    for identity in sorted(set(first) | set(second)):
        left = first.get(identity)
        right = second.get(identity)
        if left is None or right is None:
            action = left or right
            if action is None:
                continue
            outputs = tuple(path for path, _ in action.actual_outputs)
            findings.append(
                ReproducibilityFinding(
                    action=action,
                    kind="action_set_changed",
                    differing_outputs=outputs or action.listed_outputs,
                )
            )
            continue
        if left.actual_outputs == right.actual_outputs:
            # A changed action key with identical bytes is Reprise's
            # non-actionable wasted_rebuild case.
            continue
        right_outputs = dict(right.actual_outputs)
        differing = tuple(
            path
            for path, digest in left.actual_outputs
            if right_outputs.get(path) != digest
        )
        left_paths = {path for path, _ in left.actual_outputs}
        differing += tuple(
            path for path, _ in right.actual_outputs if path not in left_paths
        )
        if not left.action_key or not right.action_key:
            kind = "output_drift_without_action_key"
        elif left.action_key == right.action_key:
            kind = "tool_nondeterminism"
        else:
            kind = "input_driven"
        findings.append(
            ReproducibilityFinding(
                action=left,
                kind=kind,
                differing_outputs=differing,
            )
        )
    return findings


def assert_no_actionable_reproducibility_findings(
    first: dict[tuple[str, str, tuple[str, ...]], CompactAction],
    second: dict[tuple[str, str, tuple[str, ...]], CompactAction],
    patch: Path,
) -> None:
    """Fail when Reprise would report an output-changing selected action."""
    findings = actionable_reproducibility_findings(first, second)
    if not findings:
        return
    details = []
    for finding in findings:
        outputs = ", ".join(finding.differing_outputs[:5])
        if len(finding.differing_outputs) > 5:
            outputs += ", ... and %d more" % (len(finding.differing_outputs) - 5)
        details.append(
            "%s %s [%s]: %s"
            % (
                finding.action.mnemonic,
                finding.action.target_label,
                finding.kind,
                outputs,
            )
        )
    raise ValueError(
        "Test Optimization actions are not reproducible for %s: %s"
        % (patch, "; ".join(details))
    )


def action_snapshot_from_aquery(
    data: dict[str, object],
    *,
    workspace: Path,
    target_label: str,
) -> tuple[dict[str, str], dict[str, str]]:
    """Return stable identities, action keys, and output digests from aquery JSON."""
    path_fragments = {
        int(fragment["id"]): fragment
        for fragment in data.get("pathFragments", [])
    }
    artifacts = {
        int(artifact["id"]): resolve_path_fragment(
            int(artifact["pathFragmentId"]), path_fragments
        )
        for artifact in data.get("artifacts", [])
    }
    targets = {
        int(target["id"]): str(target.get("label", ""))
        for target in data.get("targets", [])
    }
    configurations = {
        int(configuration["id"]): str(configuration.get("mnemonic", ""))
        for configuration in data.get("configuration", [])
    }

    action_keys: dict[str, str] = {}
    outputs: dict[str, str] = {}
    for action in data.get("actions", []):
        mnemonic = str(action.get("mnemonic", ""))
        output_paths = sorted(
            artifacts[int(output_id)] for output_id in action.get("outputIds", [])
        )
        action_target = targets.get(int(action.get("targetId", 0)), "")
        if not is_reproducibility_action(
            mnemonic=mnemonic,
            target=action_target,
            outputs=output_paths,
            requested_target=target_label,
        ):
            continue

        configuration = configurations.get(int(action.get("configurationId", 0)), "")
        identity = "%s %s [%s] -> %s" % (
            mnemonic,
            action_target,
            configuration,
            ",".join(output_paths),
        )
        if identity in action_keys:
            raise ValueError("duplicate reproducibility action identity: %s" % identity)
        action_keys[identity] = str(action.get("actionKey", ""))
        if not action_keys[identity]:
            raise ValueError("reproducibility action has no action key: %s" % identity)
        for output_path in output_paths:
            for relative, digest in canonical_artifact_inventory(
                workspace / output_path
            ).items():
                identity = output_path if not relative else output_path + "/" + relative
                if identity in outputs:
                    raise ValueError("duplicate reproducibility output: %s" % identity)
                outputs[identity] = digest
    return action_keys, outputs


def assert_cgo_aquery_actions(
    data: dict[str, object],
    *,
    expected_instrumented: bool,
) -> None:
    """Require an aquery to cover the expected CGO/debug stdlib mode."""
    matching = []
    for action in data.get("actions", []):
        if action.get("mnemonic") != "GoStdlib":
            continue
        arguments = [str(arg) for arg in action.get("arguments", [])]
        environment = {
            str(item.get("key", item.get("name", ""))): str(item.get("value", ""))
            for item in action.get("environmentVariables", [])
        }
        if environment.get("CGO_ENABLED") != "1":
            continue
        if "-g" not in environment.get("CGO_CFLAGS", "").split():
            continue
        if ("-orchestrion" in arguments) == expected_instrumented:
            matching.append(action)
    if not matching:
        mode = "instrumented" if expected_instrumented else "plain"
        raise ValueError(
            "reproducibility aquery must contain a %s CGO-enabled "
            "GoStdlib action with debug flags" % mode
        )


def assert_cgo_reproducibility_actions(
    actions, *, expected_instrumented: bool
) -> None:
    """Require a compact log to contain the requested CGO stdlib mode."""
    for action in actions:
        if action.mnemonic != "GoStdlib":
            continue
        environment = dict(action.environment_variables)
        if environment.get("CGO_ENABLED") != "1":
            continue
        if "-g" not in environment.get("CGO_CFLAGS", "").split():
            continue
        instrumented = (
            "-orchestrion" in action.command_args
            and "-orchestrion_mode" in action.command_args
            and "test_optimization" in action.command_args
            and any("rules_go_orchestrion_tool" in arg for arg in action.command_args)
        )
        if instrumented == expected_instrumented:
            return
    mode = "instrumented" if expected_instrumented else "plain"
    raise ValueError(
        "compact execution log must contain a %s CGO-enabled "
        "GoStdlib action with debug flags" % mode
    )


def resolve_path_fragment(
    fragment_id: int, fragments: dict[int, dict[str, object]]
) -> str:
    """Resolve one aquery path-fragment chain without host path assumptions."""
    labels = []
    seen = set()
    while fragment_id:
        if fragment_id in seen:
            raise ValueError("cycle in aquery path fragments at id %d" % fragment_id)
        seen.add(fragment_id)
        fragment = fragments.get(fragment_id)
        if fragment is None:
            raise ValueError("unknown aquery path fragment id %d" % fragment_id)
        labels.append(str(fragment.get("label", "")))
        fragment_id = int(fragment.get("parentId", 0))
    return PurePosixPath(*reversed(labels)).as_posix()


def is_reproducibility_action(
    *,
    mnemonic: str,
    target: str,
    outputs: list[str],
    requested_target: str,
) -> bool:
    """Select the four actions whose stability controls instrumented test caching."""
    if mnemonic in {"GoStdlib", "GoSyntheticTestmainHelpers"}:
        return True
    if target != requested_target:
        return False
    if mnemonic == "GoCompilePkg":
        return any("~testmain.a" in output for output in outputs)
    return mnemonic == "GoLink"


def canonical_artifact_digest(path: Path) -> str:
    """Hash a declared file, symlink, or TreeArtifact including logical paths."""
    digest = hashlib.sha256()
    if path.is_symlink():
        digest.update(b"symlink\0")
        digest.update(os.readlink(path).encode("utf-8"))
        return digest.hexdigest()
    if path.is_file():
        digest.update(b"file\0")
        digest.update(b"executable\0" if path.stat().st_mode & 0o111 else b"regular\0")
        update_digest_from_file(digest, path)
        return digest.hexdigest()
    if not path.is_dir():
        raise ValueError("declared action output does not exist: %s" % path)

    digest.update(b"tree\0")
    for child in sorted(path.rglob("*")):
        relative = child.relative_to(path).as_posix().encode("utf-8")
        digest.update(relative)
        digest.update(b"\0")
        if child.is_symlink():
            digest.update(b"symlink\0")
            digest.update(os.readlink(child).encode("utf-8"))
        elif child.is_dir():
            digest.update(b"directory\0")
        elif child.is_file():
            digest.update(b"file\0")
            digest.update(
                b"executable\0" if child.stat().st_mode & 0o111 else b"regular\0"
            )
            update_digest_from_file(digest, child)
        else:
            raise ValueError("unsupported action output entry: %s" % child)
        digest.update(b"\0")
    return digest.hexdigest()


def canonical_artifact_inventory(path: Path) -> dict[str, str]:
    """Expand a declared tree so failures identify the exact unstable entry."""
    if path.is_symlink() or not path.is_dir():
        return {"": canonical_artifact_digest(path)}

    inventory = {"": "tree"}
    for child in sorted(path.rglob("*")):
        relative = child.relative_to(path).as_posix()
        if child.is_dir() and not child.is_symlink():
            inventory[relative] = "directory"
        else:
            inventory[relative] = canonical_artifact_digest(child)
    return inventory


def update_digest_from_file(digest, path: Path) -> None:
    """Hash a file without retaining large archives in memory."""
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)


def run_stdlib_inventory(
    bazel: Path,
    output_user_root: Path,
    workspace: Path,
    *,
    command: str,
    mode_flags: list[str],
    target: str,
    execution_log: Path | None = None,
    private_safe_patterns: list[str] | None = None,
) -> StdlibCacheSnapshot:
    """Execute one stdlib action and inventory its declared cache TreeArtifact."""
    execution_log_flags = []
    if execution_log is not None:
        execution_log.parent.mkdir(parents=True, exist_ok=True)
        execution_log_flags = [
            "--execution_log_compact_file=%s" % execution_log.as_posix(),
        ]
    run_bazel(
        bazel,
        output_user_root,
        workspace,
        [command, *mode_flags, *execution_log_flags, target],
        private_safe_patterns=private_safe_patterns,
    )
    output_path_result = run_bazel(
        bazel,
        output_user_root,
        workspace,
        ["info", *mode_flags, "output_path"],
        private_safe_patterns=private_safe_patterns,
    )
    output_path = Path(output_path_result.stdout.strip())
    candidates = sorted(
        path
        for path in output_path.rglob("gocache")
        if path.parent.name == "stdlib_" and path.is_dir()
    )
    if not candidates:
        raise ValueError(
            "expected a declared GoStdlib gocache under %s" % output_path
        )
    snapshots = [(path, canonical_tree_inventory(path)) for path in candidates]
    manifested = [(path, snapshot) for path, snapshot in snapshots if snapshot.manifest is not None]
    if len(manifested) > 1:
        raise ValueError(
            "multiple declared GoStdlib caches contain manifests under %s: %s"
            % (output_path, [path.as_posix() for path, _ in manifested])
        )
    for path, snapshot in snapshots:
        if manifested and path == manifested[0][0]:
            continue
        if snapshot.inventory:
            raise ValueError(
                "non-selected declared GoStdlib cache is not empty: %s contains %s"
                % (path, sorted(snapshot.inventory))
            )
    if manifested:
        return manifested[0][1]
    return StdlibCacheSnapshot(inventory={}, manifest=None)


def canonical_tree_inventory(root: Path) -> StdlibCacheSnapshot:
    """Return a deterministic relative-path inventory and reject symlinks."""
    inventory: dict[str, str] = {}
    manifest: str | None = None
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise ValueError("declared stdlib cache contains symlink %s" % relative)
        if path.is_dir():
            inventory[relative] = "dir"
            continue
        if not path.is_file():
            raise ValueError("declared stdlib cache contains non-file %s" % relative)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        inventory[relative] = "file:%s" % digest
        if relative == ".orchestrion_stdlib_cache_manifest":
            manifest = path.read_text(encoding="utf-8")
    return StdlibCacheSnapshot(inventory=inventory, manifest=manifest)


def assert_plain_stdlib_cache(snapshot: StdlibCacheSnapshot, patch: Path) -> None:
    """Require the plain-mode declared stdlib cache to be empty."""
    if snapshot.inventory or snapshot.manifest is not None:
        raise ValueError(
            "plain stdlib cache for %s is not empty: %s"
            % (patch, sorted(snapshot.inventory))
        )


def assert_orchestrion_stdlib_cache(snapshot: StdlibCacheSnapshot, patch: Path) -> None:
    """Require only sorted, manifested Go cache data entries."""
    manifest_name = ".orchestrion_stdlib_cache_manifest"
    inventory = snapshot.inventory
    manifest_value = inventory.get(manifest_name, "")
    if not manifest_value.startswith("file:"):
        raise ValueError("Test Optimization stdlib cache for %s has no manifest" % patch)
    if snapshot.manifest is None:
        raise ValueError("Test Optimization stdlib cache for %s has no manifest contents" % patch)
    lines = snapshot.manifest.splitlines()
    if not lines:
        raise ValueError("Test Optimization stdlib cache manifest for %s is empty" % patch)

    expected = {manifest_name}
    archives: set[str] = set()
    directories: set[str] = set()
    packages: set[str] = set()
    package_order: list[str] = []
    for line in lines:
        package, separator, relative = line.partition("=")
        relative_path = PurePosixPath(relative)
        if (
            not separator
            or not package
            or package in packages
            or not relative
            or "\\" in relative
            or relative_path.is_absolute()
            or ".." in relative_path.parts
            or relative_path.name.endswith("-a")
            or not relative_path.name.endswith("-d")
        ):
            raise ValueError(
                "invalid Test Optimization stdlib cache manifest entry for %s: %r"
                % (patch, line)
            )
        packages.add(package)
        package_order.append(package)
        archives.add(relative)
        parent = relative_path.parent
        while parent != PurePosixPath("."):
            directories.add(parent.as_posix())
            parent = parent.parent

    if package_order != sorted(package_order):
        raise ValueError("Test Optimization stdlib cache manifest for %s is unsorted" % patch)

    expected.update(archives)
    expected.update(directories)
    actual = set(inventory)
    if actual != expected:
        raise ValueError(
            "Test Optimization stdlib cache for %s contains unmanifested entries: missing=%s extra=%s"
            % (patch, sorted(expected - actual), sorted(actual - expected))
        )
    for relative in archives:
        if not inventory[relative].startswith("file:"):
            raise ValueError("manifested stdlib archive %s is not a file" % relative)
    for relative in directories:
        if inventory[relative] != "dir":
            raise ValueError("stdlib cache parent %s is not a directory" % relative)


@contextmanager
def temporary_smoke_root():
    """Create and remove a smoke tempdir without Python-level Bazel tree cleanup."""
    smoke_root = Path(tempfile.mkdtemp(prefix="rules_go_profile_smoke_"))
    try:
        yield smoke_root
    finally:
        remove_tree(smoke_root)


def remove_tree(path: Path) -> None:
    """Best-effort removal for large Bazel/Go SDK output trees."""
    if not path.exists():
        return
    result = run_cleanup_command(["rm", "-rf", path.as_posix()])
    if result.returncode == 0 or not path.exists():
        return
    run_cleanup_command(["chmod", "-R", "u+w", path.as_posix()])
    run_cleanup_command(["rm", "-rf", path.as_posix()])


def run_cleanup_command(argv: list[str]) -> subprocess.CompletedProcess[bytes]:
    """Run a cleanup command without letting slow temp cleanup block verification."""
    try:
        return subprocess.run(
            argv,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(argv, 124)


def smoke_bazel_env(output_user_root: Path) -> dict[str, str]:
    """Return the minimal environment needed by the Bazel smoke test."""
    smoke_home = output_user_root.parent / "home"
    smoke_tmp = output_user_root.parent / "tmp"
    smoke_home.mkdir(parents=True, exist_ok=True)
    smoke_tmp.mkdir(parents=True, exist_ok=True)
    path_entries: list[str] = []
    for tool in ("bash", "date", "tr", "awk", "sed", "git", "bazelisk", "bazel"):
        resolved = shutil.which(tool)
        if resolved is not None:
            path_entries.append(str(Path(resolved).parent))
    path_entries.extend(["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin"])
    env = {
        "HOME": smoke_home.as_posix(),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "LOGNAME": "rules_go_smoke",
        "PATH": os.pathsep.join(dict.fromkeys(path_entries)),
        "TMPDIR": smoke_tmp.as_posix(),
        "USER": "rules_go_smoke",
        "USE_BAZEL_VERSION": os.environ.get(
            "USE_BAZEL_VERSION",
            (REPO_ROOT / ".bazelversion").read_text().strip(),
        ),
    }
    for key in ("JAVA_HOME", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"):
        if key in os.environ:
            env[key] = os.environ[key]
    return env


def run_private_safe(
    argv: list[str],
    *,
    private_safe_patterns: list[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one command and scan captured output before reporting failures."""
    result = subprocess.run(
        argv,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    patterns = private_safe_patterns or []
    verify_private_safe_text("%s stdout" % argv[0], result.stdout, patterns)
    verify_private_safe_text("%s stderr" % argv[0], result.stderr, patterns)
    if result.returncode != 0:
        raise RuntimeError(
            "command failed (%s): %s" % (" ".join(argv), result.stderr.strip())
        )
    return result


def modified_tracked_files(private_blocklist_file: Path | None) -> list[Path]:
    """Return modified tracked repository files when a private scan is requested."""
    if private_blocklist_file is None:
        return []
    paths: set[Path] = set()
    for args in (
        ["diff", "--name-only", "--diff-filter=ACMRT"],
        ["diff", "--cached", "--name-only", "--diff-filter=ACMRT"],
    ):
        result = subprocess.run(
            ["git", "-C", REPO_ROOT.as_posix(), *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip())
        for line in result.stdout.splitlines():
            path = REPO_ROOT / line
            if path.is_file():
                paths.add(path)
    return sorted(paths)


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--profile-root", type=Path, default=DEFAULT_PROFILE_ROOT)
    parser.add_argument("--profile", default="workspace_runtime")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument(
        "--upstream",
        help="Verify only one upstream support line. Defaults to all registered upstreams.",
    )
    parser.add_argument(
        "--public-denylist",
        type=Path,
        default=REPO_ROOT / "tools/dev/private_leak_public_denylist.txt",
        help="Public denylist used to reject private-only strings in generated artifacts.",
    )
    parser.add_argument("--private-blocklist-file", type=Path)
    parser.add_argument(
        "--skip-functional-smoke",
        action="store_true",
        help="Skip the generated-patch WORKSPACE smoke. Intended only for focused unit tests.",
    )
    parser.add_argument("--bazel", type=Path, default=REPO_ROOT / "bazelw")
    parser.add_argument("--go-version", default="1.25.0")
    parser.add_argument("--orchestrion-version", default="v1.12.0")
    parser.add_argument("--dd-trace-go-version", default="v2.9.1")
    args = parser.parse_args(argv)
    try:
        if args.output_dir:
            verify_profiles(
                registry_path=args.registry,
                profile_root=args.profile_root,
                profile=args.profile,
                output_dir=args.output_dir,
                public_denylist=args.public_denylist,
                private_blocklist_file=args.private_blocklist_file,
                upstream=args.upstream,
                run_functional_smoke=not args.skip_functional_smoke,
                bazel=args.bazel,
                go_version=args.go_version,
                orchestrion_version=args.orchestrion_version,
                dd_trace_go_version=args.dd_trace_go_version,
            )
        else:
            with tempfile.TemporaryDirectory(prefix="rules_go_profiles_") as raw_tmp:
                verify_profiles(
                    registry_path=args.registry,
                    profile_root=args.profile_root,
                    profile=args.profile,
                    output_dir=Path(raw_tmp),
                    public_denylist=args.public_denylist,
                    private_blocklist_file=args.private_blocklist_file,
                    upstream=args.upstream,
                    run_functional_smoke=not args.skip_functional_smoke,
                    bazel=args.bazel,
                    go_version=args.go_version,
                    orchestrion_version=args.orchestrion_version,
                    dd_trace_go_version=args.dd_trace_go_version,
                )
        return 0
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
