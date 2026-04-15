#!/usr/bin/env python3
"""Verify that the checked-in rules_go patch series reproduces the vendored fork."""

from __future__ import annotations

import filecmp
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = REPO_ROOT / "third_party" / "rules_go_orchestrion.PATCH_SERIES.json"
EXPECTED_PATCH_FILENAMES = (
    "0002-Include-logs-for-test-reports-regardless-of-failure-.patch",
    "0008-Pass-through-cflags-to-the-assembler-in-cgo-mode.patch",
    "0009-Use-LLVM-for-all-linking.patch",
    "0011-fix-cdeps-propagation.patch",
    "0013-Add-buildInfo-metadata-support.patch",
    "0014-Fix-protobuf-compatibility-use-rules_proto-for-Proto.patch",
    "0015-Set-GoLink-resource_set-to-match-lld-thread-count.patch",
    "0015-Optimize-_filter_options-use-O1-dict-lookup-for-exac.patch",
    "0016-Fix-go_context-check-cached-CgoContextInfo-provider-b.patch",
)

# Local validation-only files live inside the vendored subtree but are not part
# of the recorded upstream patch replay. The verifier compares the replayed
# patch series against the vendored fork while intentionally skipping these
# auxiliary files; their behavior is covered separately by the smoke targets.
LOCAL_VALIDATION_ONLY_PATHS = {
    "go/private/context.bzl",
    "patches/BUILD.bazel",
    "patches/0002-Include-logs-for-test-reports-regardless-of-failure-.patch",
    "patches/0008-Pass-through-cflags-to-the-assembler-in-cgo-mode.patch",
    "patches/0009-Use-LLVM-for-all-linking.patch",
    "patches/0011-fix-cdeps-propagation.patch",
    "patches/0013-Add-buildInfo-metadata-support.patch",
    "patches/0014-Fix-protobuf-compatibility-use-rules_proto-for-Proto.patch",
    "patches/0015-Set-GoLink-resource_set-to-match-lld-thread-count.patch",
    "patches/0015-Optimize-_filter_options-use-O1-dict-lookup-for-exac.patch",
    "patches/0016-Fix-go_context-check-cached-CgoContextInfo-provider-b.patch",
    "tests/core/cgo/asm_cflags/BUILD.bazel",
    "tests/core/cgo/asm_cflags/asm_cflags.go",
    "tests/core/cgo/asm_cflags/asm_cflags_linux_amd64.S",
    "tests/core/cgo/asm_cflags/asm_cflags_test.go",
    "tests/core/go_proto_library/BUILD.bazel",
    "tests/core/starlark/context_tests.bzl",
}


def load_manifest(path: Path) -> dict:
    """Load the patch-series manifest and enforce the required series shape."""
    manifest = json.loads(path.read_text(encoding="utf-8"))
    patch_filenames = tuple(patch["filename"] for patch in manifest["patches"])
    if patch_filenames != EXPECTED_PATCH_FILENAMES:
        raise ValueError(
            "manifest patch filenames do not match the required 1:1 patch series:\n"
            f"expected: {EXPECTED_PATCH_FILENAMES}\n"
            f"actual:   {patch_filenames}"
        )
    return manifest


def git_archive_subtree(commit: str, subtree_path: str, destination: Path) -> None:
    """Extract one committed subtree into a standalone directory for comparison."""
    result = subprocess.run(
        ["git", "archive", "--format=tar", commit, subtree_path],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
    )
    prefix = f"{subtree_path}/"
    with tarfile.open(fileobj=io.BytesIO(result.stdout), mode="r:") as archive:
        for member in archive.getmembers():
            if not member.name.startswith(prefix):
                continue
            relative_name = member.name[len(prefix):]
            if not relative_name:
                continue
            member.name = relative_name
            archive.extract(member, destination, filter="data")


def copy_worktree_subtree(subtree_path: str, destination: Path) -> None:
    """Copy tracked files from the checked-out vendored subtree for comparison."""
    result = subprocess.run(
        ["git", "ls-files", "-z", "--", subtree_path],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
    )
    prefix = f"{subtree_path}/"
    for tracked_path in result.stdout.decode("utf-8").split("\0"):
        if not tracked_path:
            continue
        if not tracked_path.startswith(prefix):
            continue
        relative_name = tracked_path[len(prefix):]
        if not relative_name:
            continue
        source = REPO_ROOT / tracked_path
        target = destination / relative_name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


def compare_trees(left: Path, right: Path, excluded_paths: set[str]) -> list[str]:
    """Return relative file paths that differ between the two extracted trees."""
    mismatches: list[str] = []
    all_paths = set()
    for root, _, files in os.walk(left):
        rel_root = Path(root).relative_to(left)
        for name in files:
            all_paths.add((rel_root / name).as_posix())
    for root, _, files in os.walk(right):
        rel_root = Path(root).relative_to(right)
        for name in files:
            all_paths.add((rel_root / name).as_posix())

    for rel in sorted(all_paths):
        if rel in excluded_paths:
            continue
        left_path = left / rel
        right_path = right / rel
        if not left_path.exists() or not right_path.exists():
            mismatches.append(rel)
            continue
        if not filecmp.cmp(left_path, right_path, shallow=False):
            mismatches.append(rel)
    return mismatches


def apply_patch_series(tree_root: Path, patch_paths: list[Path]) -> None:
    """Apply the checked-in patch series with the same tool the consumer would use."""
    for patch_path in patch_paths:
        subprocess.run(
            ["patch", "-p1", "-i", str(patch_path)],
            cwd=tree_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )


def main() -> int:
    """Verify that the checked-in patch files exactly reproduce the vendored subtree."""
    manifest = load_manifest(DEFAULT_MANIFEST)
    patch_paths = [REPO_ROOT / manifest["patch_dir"] / patch["filename"] for patch in manifest["patches"]]
    missing_patches = [path for path in patch_paths if not path.exists()]
    if missing_patches:
        for path in missing_patches:
            print(f"missing patch file: {path.relative_to(REPO_ROOT)}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="rules_go_patch_verify_") as tempdir:
        temp_root = Path(tempdir)
        base_tree = temp_root / "base"
        expected_tree = temp_root / "expected"
        base_tree.mkdir()
        expected_tree.mkdir()

        git_archive_subtree(manifest["base_commit"], manifest["subtree_path"], base_tree)
        copy_worktree_subtree(manifest["subtree_path"], expected_tree)
        apply_patch_series(base_tree, patch_paths)

        mismatches = compare_trees(base_tree, expected_tree, LOCAL_VALIDATION_ONLY_PATHS)
        if mismatches:
            print("patch series verification failed; mismatched paths:", file=sys.stderr)
            for rel in mismatches:
                print(rel, file=sys.stderr)
            return 1

    print("patch series verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
