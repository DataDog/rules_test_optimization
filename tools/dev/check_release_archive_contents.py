#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Verify release/archive coverage for registry-backed rules_go fork artifacts."""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

try:
    from tools.dev.materialize_rules_go_fork import read_series
    from tools.dev.rules_go_fork_registry import (
        DEFAULT_REGISTRY,
        REPO_ROOT,
        ForkRegistry,
        load_registry,
        repo_relative_path,
    )
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from tools.dev.materialize_rules_go_fork import read_series
    from tools.dev.rules_go_fork_registry import (
        DEFAULT_REGISTRY,
        REPO_ROOT,
        ForkRegistry,
        load_registry,
        repo_relative_path,
    )


def run(argv: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    """Run a command and raise with stderr if it fails."""
    result = subprocess.run(
        argv,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        **kwargs,
    )
    if result.returncode != 0:
        raise RuntimeError("command failed (%s): %s" % (" ".join(argv), result.stderr.strip()))
    return result


def required_archive_paths(registry: ForkRegistry) -> set[str]:
    """Return repository-relative files that must be present in release archives."""
    repo_root = registry.repo_root
    selections = registry.selections()
    registry_artifact_root = _registry_artifact_root(registry, selections)
    required = {
        ".bazelignore",
        "tools/dev/check_release_archive_contents.py",
        "tools/dev/generate_rules_go_consumer_patch.py",
        "tools/dev/generate_rules_go_fork_maps.py",
        "tools/dev/materialize_rules_go_fork.py",
        "tools/dev/private_leak_public_denylist.txt",
        "tools/dev/rules_go_fork_registry.py",
        "tools/dev/verify_rules_go_profiles.py",
        "tools/go/rules_go_forks.bzl",
        "modules/go/tools/onboardingpins/rules_go_forks_gen.go",
        repo_relative_path(repo_root, registry_artifact_root / "BUILD.bazel"),
        repo_relative_path(repo_root, registry_artifact_root / "profiles" / "workspace_runtime.json"),
        repo_relative_path(repo_root, registry_artifact_root / "registry.json"),
    }

    for selection in selections:
        required.update(
            {
                repo_relative_path(repo_root, selection.tree_path / "MODULE.bazel"),
                repo_relative_path(repo_root, selection.tree_path / "WORKSPACE"),
                repo_relative_path(repo_root, selection.tree_path / "BUILD.bazel"),
                repo_relative_path(repo_root, selection.metadata_path),
                repo_relative_path(repo_root, selection.changed_files_report),
                repo_relative_path(repo_root, selection.series_path),
            }
        )
        for patch in read_series(selection.series_path):
            required.add(repo_relative_path(repo_root, selection.series_path.parent / patch))

    return required


def _registry_artifact_root(registry: ForkRegistry, selections: list) -> Path:
    """Return the repository-normalized directory that contains registry artifacts."""
    for selection in selections:
        if selection.patch_root.parent.name == "patches":
            return selection.patch_root.parent.parent
    return registry.root


def git_archive_entries(repo_root: Path, treeish: str) -> set[str]:
    """Return all paths included in `git archive treeish`."""
    with tempfile.NamedTemporaryFile(prefix="rto-release-archive-", suffix=".tar") as handle:
        run(["git", "-C", repo_root.as_posix(), "archive", "--format=tar", treeish, "-o", handle.name])
        with tarfile.open(handle.name, "r:") as archive:
            return {member.name.removeprefix("./") for member in archive.getmembers()}


def worktree_entries(repo_root: Path) -> set[str]:
    """Return git-visible paths in the current worktree, including untracked additions."""
    result = run(
        [
            "git",
            "-C",
            repo_root.as_posix(),
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
        ]
    )
    return {line for line in result.stdout.splitlines() if line}


def check_entries(required: set[str], entries: set[str]) -> list[str]:
    """Return sorted missing release archive paths."""
    return sorted(required - entries)


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--registry",
        type=Path,
        default=DEFAULT_REGISTRY,
        help="Path to rules_go fork registry JSON.",
    )
    parser.add_argument(
        "--source",
        choices=("git-archive", "worktree"),
        default="git-archive",
        help="Source used to collect release candidate paths.",
    )
    parser.add_argument(
        "--treeish",
        default="HEAD",
        help="Git tree-ish to archive when --source=git-archive.",
    )
    args = parser.parse_args(argv)

    registry = load_registry(args.registry)
    required = required_archive_paths(registry)
    if args.source == "git-archive":
        entries = git_archive_entries(REPO_ROOT, args.treeish)
        source_description = f"git archive {args.treeish}"
    else:
        entries = worktree_entries(REPO_ROOT)
        source_description = "current git-visible worktree"

    missing = check_entries(required, entries)
    if missing:
        print("release archive is missing required rules_go fork artifacts:", file=sys.stderr)
        for path in missing:
            print(path, file=sys.stderr)
        return 1

    print(
        "release archive contents verified from %s: %d required rules_go fork artifacts present"
        % (source_description, len(required))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
