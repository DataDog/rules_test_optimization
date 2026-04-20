#!/usr/bin/env python3
"""Verify the clean-base rules_go split and the canonical optional patch bundle."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import tempfile

from rules_go_patch_series_lib import (
    DEFAULT_MANIFEST_PATH,
    PatchSeriesError,
    REPO_ROOT,
    compare_entry_maps,
    copy_worktree_subtree,
    git_archive_subtree,
    load_manifest,
    load_tree_manifest,
    manifest_path,
    materialize_bundle_tree,
    remove_normalized_paths,
    resolve_patch_selection,
    tree_entries,
    write_tree_manifest,
)


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse verifier CLI arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST_PATH)
    parser.add_argument("--bundle", help="named bundle to verify")
    parser.add_argument(
        "--patch",
        action="append",
        default=[],
        help="explicit patch filename to verify; may be repeated",
    )
    parser.add_argument(
        "--write-full-tree-manifest",
        action="store_true",
        help="rewrite the exact-tree manifest from the current canonical full bundle",
    )
    return parser.parse_args(argv)


def verify_clean_base(manifest: dict) -> int:
    """Compare the checked-in clean base subtree to the recorded base commit."""
    with tempfile.TemporaryDirectory(prefix="rules_go_patch_verify_base_") as tempdir:
        temp_root = Path(tempdir)
        expected_tree = temp_root / "expected"
        actual_tree = temp_root / "actual"
        expected_tree.mkdir()
        actual_tree.mkdir()

        git_archive_subtree(manifest["base_commit"], manifest["subtree_path"], expected_tree)
        copy_worktree_subtree(manifest["subtree_path"], actual_tree)
        expected_entries = {entry["path"]: entry for entry in tree_entries(expected_tree)}
        actual_entries = {entry["path"]: entry for entry in tree_entries(actual_tree)}
        mismatches = compare_entry_maps(expected_entries, actual_entries)
        if mismatches:
            print("clean-base verification failed; mismatched paths:", file=sys.stderr)
            for path in mismatches:
                print(path, file=sys.stderr)
            return 1
    print("clean base verified")
    return 0


def canonical_full_bundle_entries(manifest: dict) -> dict[str, dict]:
    """Materialize the canonical full bundle and return its normalized tree entries."""
    with tempfile.TemporaryDirectory(prefix="rules_go_patch_verify_full_") as tempdir:
        materialized_tree = Path(tempdir) / "tree"
        selection = resolve_patch_selection(manifest, bundle_name="dd_source_full")
        materialize_bundle_tree(manifest, selection=selection, destination=materialized_tree, force=True)
        remove_normalized_paths(materialized_tree, manifest["proof_overlay_paths"])
        return {entry["path"]: entry for entry in tree_entries(materialized_tree)}


def verify_bundle(manifest: dict, bundle_name: str) -> int:
    """Verify one named bundle against its expected proof surface."""
    if bundle_name == "none":
        return verify_clean_base(manifest)
    if bundle_name != "dd_source_full":
        raise PatchSeriesError(
            f"bundle verification is only supported for 'none' or 'dd_source_full', got {bundle_name!r}"
        )

    expected_entries = load_tree_manifest(manifest_path(manifest["full_tree_manifest"]))
    actual_entries = canonical_full_bundle_entries(manifest)
    mismatches = compare_entry_maps(expected_entries, actual_entries)
    if mismatches:
        print("canonical full-bundle verification failed; mismatched paths:", file=sys.stderr)
        for path in mismatches:
            print(path, file=sys.stderr)
        return 1
    print("canonical full bundle verified")
    return 0


def write_full_tree_manifest(manifest: dict) -> int:
    """Regenerate the exact-tree manifest for the canonical full patch bundle."""
    entries = list(canonical_full_bundle_entries(manifest).values())
    entries.sort(key=lambda entry: entry["path"])
    output_path = manifest_path(manifest["full_tree_manifest"])
    write_tree_manifest(output_path, entries)
    print(output_path.relative_to(REPO_ROOT))
    return 0


def verify_subset(manifest: dict, patch_filenames: list[str]) -> int:
    """Validate patch ordering, prerequisites, and clean application for a subset."""
    with tempfile.TemporaryDirectory(prefix="rules_go_patch_verify_subset_") as tempdir:
        materialized_tree = Path(tempdir) / "tree"
        selection = resolve_patch_selection(manifest, patch_filenames=patch_filenames)
        materialize_bundle_tree(manifest, selection=selection, destination=materialized_tree, force=True)
    ordered = ", ".join(patch["filename"] for patch in selection)
    print(f"subset verified: {ordered}")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Dispatch patch-series verification modes."""
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        manifest = load_manifest(args.manifest)
        if args.write_full_tree_manifest:
            if args.bundle or args.patch:
                raise PatchSeriesError("--write-full-tree-manifest cannot be combined with --bundle or --patch")
            return write_full_tree_manifest(manifest)
        if args.bundle:
            if args.patch:
                raise PatchSeriesError("choose either --bundle or --patch, not both")
            return verify_bundle(manifest, args.bundle)
        if args.patch:
            return verify_subset(manifest, args.patch)
        raise PatchSeriesError("select one of --bundle, --patch, or --write-full-tree-manifest")
    except PatchSeriesError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
