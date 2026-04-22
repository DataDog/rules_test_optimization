#!/usr/bin/env python3
"""Shared helpers for the rules_go optional patch-bundle workflow."""

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST_PATH = REPO_ROOT / "third_party" / "rules_go_patch_series.json"
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


class PatchSeriesError(ValueError):
    """Raised when the patch-series manifest or requested selection is invalid."""


def run_git(*args: str, capture_output: bool = True) -> subprocess.CompletedProcess[str]:
    """Run git from the repository root and return the completed process."""
    return subprocess.run(
        ["git", *args],
        cwd=REPO_ROOT,
        check=True,
        text=True,
        capture_output=capture_output,
    )


def _git_command_succeeds(
    git_runner,
    *args: str,
) -> bool:
    """Return whether one git command succeeds without surfacing the exception."""
    try:
        git_runner(*args)
    except subprocess.CalledProcessError:
        return False
    return True


def _validate_manifest_commit_reachability(manifest: dict, git_runner=run_git) -> None:
    """Reject manifest commits that are missing from or detached from repository history."""
    commit_labels = [("base_commit", manifest["base_commit"])]
    commit_labels.extend((patch["filename"], patch["commit"]) for patch in manifest["patches"])
    for label, commit in commit_labels:
        if not _git_command_succeeds(git_runner, "cat-file", "-e", f"{commit}^{{commit}}"):
            raise PatchSeriesError(f"manifest commit for {label!r} does not exist: {commit}")

        if _git_command_succeeds(git_runner, "merge-base", "--is-ancestor", commit, "HEAD"):
            continue

        refs = git_runner(
            "for-each-ref",
            f"--contains={commit}",
            "--format=%(refname)",
        ).stdout.strip()
        if not refs:
            raise PatchSeriesError(
                f"manifest commit for {label!r} is not reachable from repository history: {commit}"
            )


def load_manifest(
    path: Path = DEFAULT_MANIFEST_PATH,
    *,
    git_runner=run_git,
    validate_commit_reachability: bool = True,
) -> dict:
    """Load and validate the canonical patch-series manifest.

    Set ``validate_commit_reachability`` to ``False`` only for workflows that
    consume the checked-in patch files directly and do not need local git
    history, such as exporting a bundle from a shallow clone or source snapshot.
    """
    manifest = json.loads(path.read_text(encoding="utf-8"))
    patch_filenames = tuple(patch["filename"] for patch in manifest["patches"])
    if patch_filenames != EXPECTED_PATCH_FILENAMES:
        raise PatchSeriesError(
            "manifest patch filenames do not match the required 1:1 patch series:\n"
            f"expected: {EXPECTED_PATCH_FILENAMES}\n"
            f"actual:   {patch_filenames}"
        )

    patch_lookup = {patch["filename"]: patch for patch in manifest["patches"]}
    if set(manifest["bundles"]) != {"none", "dd_source_full"}:
        raise PatchSeriesError(
            f"manifest bundles must be exactly ['dd_source_full', 'none'], got {sorted(manifest['bundles'])}"
        )

    for bundle_name, bundle_patches in manifest["bundles"].items():
        for filename in bundle_patches:
            if filename not in patch_lookup:
                raise PatchSeriesError(f"bundle {bundle_name!r} references unknown patch {filename!r}")

    for patch in manifest["patches"]:
        if patch["order"] < 1:
            raise PatchSeriesError(f"patch order must be >= 1: {patch['filename']}")
        for required in patch["requires"]:
            if required not in patch_lookup:
                raise PatchSeriesError(
                    f"patch {patch['filename']!r} requires unknown patch {required!r}"
                )

    if validate_commit_reachability:
        _validate_manifest_commit_reachability(manifest, git_runner=git_runner)
    return manifest


def manifest_patch_lookup(manifest: dict) -> dict[str, dict]:
    """Return a filename-indexed view of manifest patch metadata."""
    return {patch["filename"]: patch for patch in manifest["patches"]}


def manifest_path(path_str: str) -> Path:
    """Resolve a manifest-relative path from the repository root."""
    return REPO_ROOT / path_str


def patch_filenames_in_canonical_order(manifest: dict, filenames: Iterable[str]) -> list[str]:
    """Return the provided patch filenames sorted by manifest order."""
    order_lookup = {patch["filename"]: patch["order"] for patch in manifest["patches"]}
    return sorted(dict.fromkeys(filenames), key=lambda filename: order_lookup[filename])


def resolve_patch_selection(
    manifest: dict,
    *,
    bundle_name: str | None = None,
    patch_filenames: Iterable[str] = (),
) -> list[dict]:
    """Resolve and validate one bundle or explicit patch subset."""
    if bundle_name and tuple(patch_filenames):
        raise PatchSeriesError("choose either --bundle or --patch, not both")
    if not bundle_name and not tuple(patch_filenames):
        raise PatchSeriesError("select a bundle or at least one patch")

    patch_lookup = manifest_patch_lookup(manifest)
    if bundle_name:
        if bundle_name not in manifest["bundles"]:
            raise PatchSeriesError(f"unknown bundle {bundle_name!r}")
        selected = list(manifest["bundles"][bundle_name])
    else:
        unknown = sorted(set(patch_filenames) - set(patch_lookup))
        if unknown:
            raise PatchSeriesError(f"unknown patch selection: {', '.join(unknown)}")
        selected = patch_filenames_in_canonical_order(manifest, patch_filenames)

    missing_prerequisites: dict[str, list[str]] = {}
    for filename in selected:
        required = [
            prerequisite
            for prerequisite in patch_lookup[filename]["requires"]
            if prerequisite not in selected
        ]
        if required:
            missing_prerequisites[filename] = required
    if missing_prerequisites:
        rendered = ", ".join(
            f"{filename} requires {', '.join(required)}"
            for filename, required in sorted(missing_prerequisites.items())
        )
        raise PatchSeriesError(f"missing patch prerequisites: {rendered}")

    return [patch_lookup[filename] for filename in selected]


def commit_body(commit: str) -> str:
    """Return the prose header that should prefix an exported patch file."""
    body = run_git("show", "--format=%b", "--no-patch", commit).stdout.strip()
    if not body:
        raise PatchSeriesError(f"commit {commit} has an empty body")
    return body


def parent_commit(commit: str) -> str:
    """Resolve the direct parent of a patch commit."""
    return run_git("rev-parse", f"{commit}^").stdout.strip()


def export_patch(subtree_path: str, commit: str) -> str:
    """Export one subtree-relative unified diff for a manifest patch commit."""
    parent = parent_commit(commit)
    diff = run_git(
        "diff",
        parent,
        commit,
        f"--relative={subtree_path}",
        "--",
        subtree_path,
    ).stdout.lstrip()
    if not diff:
        raise PatchSeriesError(f"commit {commit} produced an empty subtree diff")
    return diff


def git_archive_subtree(commit: str, subtree_path: str, destination: Path) -> None:
    """Extract one committed subtree into a standalone directory."""
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
            _extract_archive_member(archive, member, destination)


def _extract_archive_member(archive: tarfile.TarFile, member: tarfile.TarInfo, destination: Path) -> None:
    """Extract one git-archive member into the destination with path-traversal checks.

    Python 3.12 added the ``filter=`` argument used by the safer tarfile APIs.
    Local developer environments in this repository still run older Python
    releases, so keep the same safety checks in a version-compatible fallback.
    """
    target_path = (destination / member.name).resolve()
    destination_root = destination.resolve()
    if os.path.commonpath([str(destination_root), str(target_path)]) != str(destination_root):
        raise PatchSeriesError(f"refusing to extract archive member outside destination: {member.name!r}")

    if hasattr(tarfile, "data_filter"):
        archive.extract(member, destination, filter="data")
        return

    archive.extract(member, destination)


def copy_worktree_subtree(subtree_path: str, destination: Path) -> None:
    """Copy the tracked worktree contents of a subtree into a standalone directory."""
    result = subprocess.run(
        ["git", "ls-files", "-z", "--", subtree_path],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
    )
    prefix = f"{subtree_path}/"
    for tracked_path in result.stdout.decode("utf-8").split("\0"):
        if not tracked_path or not tracked_path.startswith(prefix):
            continue
        relative_name = tracked_path[len(prefix):]
        source = REPO_ROOT / tracked_path
        if not source.exists() and not source.is_symlink():
            continue
        target = destination / relative_name
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            target.unlink(missing_ok=True)
            os.symlink(os.readlink(source), target)
        else:
            shutil.copy2(source, target)


def apply_patch_files(tree_root: Path, patch_paths: Iterable[Path]) -> None:
    """Apply a sequence of patch files with the consumer-visible patch tool."""
    for patch_path in patch_paths:
        subprocess.run(
            ["patch", "-p1", "-i", str(patch_path)],
            cwd=tree_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )


def patch_paths_for_selection(manifest: dict, selection: Iterable[dict]) -> list[Path]:
    """Resolve the repository-local filesystem paths for a patch selection."""
    patch_dir = manifest_path(manifest["patch_dir"])
    return [patch_dir / patch["filename"] for patch in selection]


def ensure_clean_destination(path: Path, *, force: bool = False) -> None:
    """Prepare a destination path for tree materialization or bundle export."""
    if path.exists():
        if not force:
            raise PatchSeriesError(f"destination already exists: {path}")
        if path.is_file() or path.is_symlink():
            path.unlink()
        else:
            shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def remove_normalized_paths(tree_root: Path, excluded_paths: Iterable[str]) -> None:
    """Delete the non-canonical paths that are intentionally outside the exact-tree proof."""
    for relative_path in excluded_paths:
        target = tree_root / relative_path
        if not target.exists() and not target.is_symlink():
            continue
        if target.is_dir() and not target.is_symlink():
            shutil.rmtree(target)
        else:
            target.unlink()


def hash_file(path: Path) -> str:
    """Return the SHA-256 digest of one regular file."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_entries(tree_root: Path) -> list[dict]:
    """Collect the canonical file and symlink entries for a tree manifest."""
    entries: list[dict] = []
    for path in sorted(tree_root.rglob("*")):
        if path.is_dir() and not path.is_symlink():
            continue
        relative_path = path.relative_to(tree_root).as_posix()
        if path.is_symlink():
            entries.append(
                {
                    "path": relative_path,
                    "kind": "symlink",
                    "target": os.readlink(path),
                }
            )
            continue
        entries.append(
            {
                "path": relative_path,
                "kind": "file",
                "executable": bool(path.stat().st_mode & stat.S_IXUSR),
                "sha256": hash_file(path),
            }
        )
    return entries


def write_tree_manifest(path: Path, entries: list[dict]) -> None:
    """Write a normalized exact-tree manifest to disk."""
    payload = {"entries": entries}
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def load_tree_manifest(path: Path) -> dict[str, dict]:
    """Load a tree-manifest file into a path-indexed dictionary."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    return {entry["path"]: entry for entry in payload["entries"]}


def compare_entry_maps(expected: dict[str, dict], actual: dict[str, dict]) -> list[str]:
    """Return the relative paths whose canonical manifest entries do not match."""
    mismatches: list[str] = []
    for path in sorted(set(expected) | set(actual)):
        if expected.get(path) != actual.get(path):
            mismatches.append(path)
    return mismatches


def materialize_bundle_tree(
    manifest: dict,
    *,
    selection: Iterable[dict],
    destination: Path,
    force: bool = False,
) -> None:
    """Create a standalone tree containing the clean base plus the selected patch bundle."""
    ensure_clean_destination(destination, force=force)
    git_archive_subtree(manifest["base_commit"], manifest["subtree_path"], destination)
    apply_patch_files(destination, patch_paths_for_selection(manifest, selection))


def apply_proof_overlay(tree_root: Path, overlay_root: Path) -> None:
    """Copy the maintainer-only proof overlay into a materialized tree."""
    for path in sorted(overlay_root.rglob("*")):
        if path.is_dir() and not path.is_symlink():
            continue
        relative_path = path.relative_to(overlay_root)
        target = tree_root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() or target.is_symlink():
            if target.is_dir() and not target.is_symlink():
                raise PatchSeriesError(
                    f"proof overlay path collides with a directory: {relative_path.as_posix()}"
                )
            target.unlink()
        if path.is_symlink():
            os.symlink(os.readlink(path), target)
            continue
        shutil.copy2(path, target)
        os.chmod(target, stat.S_IMODE(path.stat().st_mode))


def proof_overlay_root(manifest: dict) -> Path:
    """Return the repository-local directory containing proof-overlay files."""
    return manifest_path(manifest["proof_overlay_dir"])


def write_patch_build_file(
    destination: Path,
    patch_filenames: Iterable[str],
    *,
    filegroup_name: str | None = None,
) -> None:
    """Write the patch BUILD file with explicit public exports.

    The checked-in canonical patch directory keeps an `all_patches` filegroup for
    Bazel data dependencies inside this repository. Consumer-owned exported patch
    bundles only need the explicit `exports_files([...])` contract.
    """
    patch_filenames = list(patch_filenames)
    lines = [
        'package(default_visibility = ["//visibility:public"])',
        "",
        "exports_files([",
    ]
    for filename in patch_filenames:
        lines.append(f'    "{filename}",')
    lines.extend(["])", ""])
    if filegroup_name:
        lines.extend(
            [
                "filegroup(",
                f'    name = "{filegroup_name}",',
                "    srcs = [",
            ]
        )
        for filename in patch_filenames:
            lines.append(f'        ":{filename}",')
        lines.extend(["    ],", ")", ""])
    (destination / "BUILD.bazel").write_text("\n".join(lines), encoding="utf-8")
