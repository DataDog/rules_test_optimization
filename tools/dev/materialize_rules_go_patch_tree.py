#!/usr/bin/env python3
"""Materialize a clean-base rules_go tree plus an optional patch selection."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from rules_go_patch_series_lib import (
    DEFAULT_MANIFEST_PATH,
    PatchSeriesError,
    apply_proof_overlay,
    load_manifest,
    materialize_bundle_tree,
    proof_overlay_root,
    resolve_patch_selection,
)


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse materialization CLI arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST_PATH)
    parser.add_argument("--bundle", help="named bundle to materialize")
    parser.add_argument(
        "--patch",
        action="append",
        default=[],
        help="explicit patch filename to materialize; may be repeated",
    )
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument(
        "--apply-proof-overlay",
        action="store_true",
        help="copy the maintainer-only proof overlay into the materialized tree",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="replace an existing destination directory",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Materialize a standalone rules_go tree from the clean base plus patches."""
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        manifest = load_manifest(args.manifest)
        selection = resolve_patch_selection(
            manifest,
            bundle_name=args.bundle,
            patch_filenames=args.patch,
        )
        materialize_bundle_tree(
            manifest,
            selection=selection,
            destination=args.destination,
            force=args.force,
        )
        if args.apply_proof_overlay:
            apply_proof_overlay(args.destination, proof_overlay_root(manifest))
    except PatchSeriesError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
