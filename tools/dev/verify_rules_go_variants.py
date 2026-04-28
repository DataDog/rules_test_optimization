#!/usr/bin/env python3
"""Verify the published rules_go Orchestrion variant contract."""

from __future__ import annotations

import argparse
import filecmp
import json
import os
from pathlib import Path
import stat
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_METADATA = REPO_ROOT / "third_party" / "rules_go_orchestrion_variants.json"


def tree_file_map(root: Path) -> dict[str, Path]:
    """Return all regular files below a variant tree keyed by relative path."""
    files: dict[str, Path] = {}
    for current_root, _, names in os.walk(root):
        rel_root = Path(current_root).relative_to(root)
        for name in names:
            path = Path(current_root) / name
            if path.is_file() or path.is_symlink():
                files[(rel_root / name).as_posix()] = path
    return files


def changed_paths(base_root: Path, complete_root: Path) -> list[str]:
    """Return every file path that differs between the base and complete variants."""
    base_files = tree_file_map(base_root)
    complete_files = tree_file_map(complete_root)
    paths = sorted(set(base_files) | set(complete_files))
    changed: list[str] = []
    for path in paths:
        base_path = base_files.get(path)
        complete_path = complete_files.get(path)
        if base_path is None or complete_path is None:
            changed.append(path)
            continue
        if file_metadata(base_path) != file_metadata(complete_path):
            changed.append(path)
            continue
        if base_path.is_symlink() or complete_path.is_symlink():
            continue
        if not filecmp.cmp(base_path, complete_path, shallow=False):
            changed.append(path)
    return changed


def file_metadata(path: Path) -> tuple[int, int, str]:
    """Return the file type, permission bits, and symlink target for comparison."""
    path_stat = path.lstat()
    link_target = os.readlink(path) if path.is_symlink() else ""
    return (stat.S_IFMT(path_stat.st_mode), stat.S_IMODE(path_stat.st_mode), link_target)


def load_metadata(path: Path) -> dict:
    """Load the variant metadata file."""
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def variant_root(metadata: dict, key: str) -> Path:
    """Return a repository-relative variant root from metadata."""
    value = metadata.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} must be a non-empty string")
    root = REPO_ROOT / value
    if not root.is_dir():
        raise ValueError(f"{key} does not exist or is not a directory: {value}")
    return root


def allowed_paths(metadata: dict) -> set[str]:
    """Return the set of complete-variant differences declared as intentional."""
    entries = metadata.get("allowed_differences")
    if not isinstance(entries, list):
        raise ValueError("allowed_differences must be a list")
    paths: set[str] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise ValueError(f"allowed_differences[{index}] must be an object")
        path = entry.get("path")
        reason = entry.get("reason")
        owner = entry.get("owner")
        if not isinstance(path, str) or not path:
            raise ValueError(f"allowed_differences[{index}].path must be a non-empty string")
        if not isinstance(reason, str) or not reason:
            raise ValueError(f"allowed_differences[{index}].reason must be a non-empty string")
        if owner not in ("base", "complete"):
            raise ValueError(f"allowed_differences[{index}].owner must be 'base' or 'complete'")
        paths.add(path)
    return paths


def verify(metadata_path: Path) -> int:
    """Verify that base and complete differ only by the declared metadata paths."""
    metadata = load_metadata(metadata_path)
    base_root = variant_root(metadata, "base_path")
    complete_root = variant_root(metadata, "complete_path")
    actual = set(changed_paths(base_root, complete_root))
    allowed = allowed_paths(metadata)

    unexpected = sorted(actual - allowed)
    missing = sorted(allowed - actual)
    if unexpected or missing:
        if unexpected:
            print("unexpected rules_go variant differences:", file=sys.stderr)
            for path in unexpected:
                print(path, file=sys.stderr)
        if missing:
            print("declared rules_go variant differences no longer present:", file=sys.stderr)
            for path in missing:
                print(path, file=sys.stderr)
        return 1

    print(f"rules_go variants verified: {len(actual)} declared differences")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Parse CLI arguments and run variant verification."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return verify(args.metadata)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
