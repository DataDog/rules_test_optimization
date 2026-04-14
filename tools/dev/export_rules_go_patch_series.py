#!/usr/bin/env python3
"""Export the vendored rules_go patch series as checked-in unified diffs."""

from __future__ import annotations

import json
import subprocess
import sys
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


def run_git(*args: str) -> str:
    """Run git in the repository root and return stdout as text."""
    result = subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout


def load_manifest(path: Path) -> dict:
    """Load the patch-series manifest and enforce the 1:1 filename contract."""
    manifest = json.loads(path.read_text(encoding="utf-8"))
    patch_filenames = tuple(patch["filename"] for patch in manifest["patches"])
    if patch_filenames != EXPECTED_PATCH_FILENAMES:
        raise ValueError(
            "manifest patch filenames do not match the required 1:1 patch series:\n"
            f"expected: {EXPECTED_PATCH_FILENAMES}\n"
            f"actual:   {patch_filenames}"
        )
    return manifest


def commit_body(commit: str) -> str:
    """Return the prose header that should prefix the exported patch file."""
    body = run_git("show", "--format=%b", "--no-patch", commit).strip()
    if not body:
        raise ValueError(f"commit {commit} has an empty body")
    return body


def parent_commit(commit: str) -> str:
    """Resolve the direct parent of a subtree patch commit."""
    return run_git("rev-parse", f"{commit}^").strip()


def export_patch(subtree_path: str, commit: str) -> str:
    """Export the subtree-relative unified diff for a single patch commit."""
    parent = parent_commit(commit)
    diff = run_git(
        "diff",
        parent,
        commit,
        f"--relative={subtree_path}",
        "--",
        subtree_path,
    ).lstrip()
    if not diff:
        raise ValueError(f"commit {commit} produced an empty subtree diff")
    return diff


def main() -> int:
    """Write the checked-in 1:1 patch series into the vendored patch directory."""
    manifest = load_manifest(DEFAULT_MANIFEST)
    patch_dir = REPO_ROOT / manifest["patch_dir"]
    patch_dir.mkdir(parents=True, exist_ok=True)

    for patch in manifest["patches"]:
        body = commit_body(patch["commit"])
        diff = export_patch(manifest["subtree_path"], patch["commit"])
        output = patch_dir / patch["filename"]
        output.write_text(f"{body}\n\n{diff}", encoding="utf-8")
        print(output.relative_to(REPO_ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
