#!/usr/bin/env python3
"""Export one canonical patch bundle into a consumer-owned patch directory."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import sys

from rules_go_patch_series_lib import (
    DEFAULT_MANIFEST_PATH,
    PatchSeriesError,
    ensure_clean_destination,
    load_manifest,
    manifest_path,
    resolve_patch_selection,
    write_patch_build_file,
)


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse bundle-export CLI arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST_PATH)
    parser.add_argument("--bundle", help="named bundle to export")
    parser.add_argument(
        "--patch",
        action="append",
        default=[],
        help="explicit patch filename to export; may be repeated",
    )
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument(
        "--force",
        action="store_true",
        help="replace an existing destination directory",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Export a canonical bundle or subset into a consumer patch directory."""
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        manifest = load_manifest(args.manifest, validate_commit_reachability=False)
        selection = resolve_patch_selection(
            manifest,
            bundle_name=args.bundle,
            patch_filenames=args.patch,
        )
        ensure_clean_destination(args.destination, force=args.force)
        patch_dir = manifest_path(manifest["patch_dir"])
        patch_filenames = [patch["filename"] for patch in selection]
        for filename in patch_filenames:
            shutil.copy2(patch_dir / filename, args.destination / filename)
        write_patch_build_file(args.destination, patch_filenames)
        for filename in patch_filenames:
            print(f"//third_party/rules_go_patches:{filename}")
    except PatchSeriesError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
