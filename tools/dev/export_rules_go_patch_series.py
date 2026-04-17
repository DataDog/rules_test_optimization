#!/usr/bin/env python3
"""Export the canonical rules_go patch series as checked-in unified diffs."""

from __future__ import annotations

import sys

from rules_go_patch_series_lib import (
    DEFAULT_MANIFEST_PATH,
    REPO_ROOT,
    commit_body,
    export_patch,
    load_manifest,
    manifest_path,
    write_patch_build_file,
)


def main() -> int:
    """Write the checked-in 1:1 patch series into the canonical patch directory."""
    manifest = load_manifest(DEFAULT_MANIFEST_PATH)
    patch_dir = manifest_path(manifest["patch_dir"])
    patch_dir.mkdir(parents=True, exist_ok=True)

    for patch in manifest["patches"]:
        body = commit_body(patch["commit"])
        diff = export_patch(manifest["subtree_path"], patch["commit"])
        output = patch_dir / patch["filename"]
        output.write_text(f"{body}\n\n{diff}", encoding="utf-8")
        print(output.relative_to(REPO_ROOT))

    write_patch_build_file(
        patch_dir,
        [patch["filename"] for patch in manifest["patches"]],
        filegroup_name="all_patches",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
