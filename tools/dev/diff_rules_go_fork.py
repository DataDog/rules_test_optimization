#!/usr/bin/env python3
"""Compare the vendored rules_go fork against its pinned upstream base."""

from __future__ import annotations

import argparse
import filecmp
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_METADATA = REPO_ROOT / "third_party" / "rules_go_orchestrion_base.METADATA.json"


def load_metadata(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    return data


def download_upstream_tree(repository: str, commit: str, tempdir: Path) -> Path:
    if repository != "https://github.com/bazel-contrib/rules_go.git":
        raise ValueError("unsupported upstream repository: %s" % repository)

    tarball_url = "https://github.com/bazel-contrib/rules_go/archive/%s.tar.gz" % commit
    tarball_path = tempdir / "rules_go.tar.gz"
    urllib.request.urlretrieve(tarball_url, tarball_path)

    with tarfile.open(tarball_path, "r:gz") as archive:
        extract_archive_safely(archive, tempdir)

    extracted = tempdir / ("rules_go-%s" % commit)
    if not extracted.is_dir():
        raise FileNotFoundError("expected extracted upstream tree at %s" % extracted)
    return extracted


def extract_archive_safely(archive: tarfile.TarFile, destination: Path) -> None:
    """Extract one tar archive with path-traversal checks across Python versions.

    Python 3.12 added the ``filter=`` argument used by the safer tarfile APIs.
    Repository maintainer workflows still run on older Python releases, so keep
    equivalent safety checks in a compatible fallback.
    """
    destination_root = destination.resolve()
    for member in archive.getmembers():
        target_path = (destination / member.name).resolve()
        if os.path.commonpath([str(destination_root), str(target_path)]) != str(destination_root):
            raise ValueError("refusing to extract archive member outside destination: %s" % member.name)

    if hasattr(tarfile, "data_filter"):
        archive.extractall(destination, filter="data")
        return

    archive.extractall(destination)


def compare_trees(upstream_root: Path, fork_root: Path) -> dict[str, list[str]]:
    changed: dict[str, list[str]] = {
        "modified": [],
        "added": [],
        "removed": [],
    }

    all_paths = set()
    for root, _, files in os.walk(upstream_root):
        rel_root = Path(root).relative_to(upstream_root)
        for name in files:
            all_paths.add((rel_root / name).as_posix())
    for root, _, files in os.walk(fork_root):
        rel_root = Path(root).relative_to(fork_root)
        for name in files:
            all_paths.add((rel_root / name).as_posix())

    for rel in sorted(all_paths):
        upstream_path = upstream_root / rel
        fork_path = fork_root / rel
        upstream_exists = upstream_path.exists()
        fork_exists = fork_path.exists()
        if upstream_exists and fork_exists:
            same = filecmp.cmp(upstream_path, fork_path, shallow=False)
            if not same:
                changed["modified"].append(rel)
        elif fork_exists:
            changed["added"].append(rel)
        else:
            changed["removed"].append(rel)

    return changed


def build_report(metadata_path: Path, metadata: dict, changed: dict[str, list[str]]) -> str:
    upstream = metadata["upstream"]
    total = sum(len(values) for values in changed.values())
    lines = [
        "# rules_go fork delta",
        "",
        "This file is generated. Do not edit by hand.",
        "",
        "## Upstream base",
        "",
        "- Repository: `%s`" % upstream["repository"],
        "- Commit: `%s`" % upstream["commit"],
    ]
    if upstream.get("tag"):
        lines.append("- Tag: `%s`" % upstream["tag"])
    lines.extend([
        "- Vendored fork: `%s`" % metadata["fork_path"],
        "- Regenerate: `%s`" % metadata["generator"],
        "",
        "## Summary",
        "",
        "- Total changed paths: `%d`" % total,
        "- Modified files: `%d`" % len(changed["modified"]),
        "- Added files: `%d`" % len(changed["added"]),
        "- Removed files: `%d`" % len(changed["removed"]),
        "",
    ])

    for section, title in (
        ("modified", "Modified files"),
        ("added", "Added files"),
        ("removed", "Removed files"),
    ):
        lines.append("## %s" % title)
        lines.append("")
        if not changed[section]:
            lines.append("- None")
        else:
            for rel in changed[section]:
                lines.append("- `%s`" % rel)
        lines.append("")

    lines.append(
        "_Generated from `%s` using `%s`._"
        % (
            metadata_path.relative_to(REPO_ROOT).as_posix(),
            "tools/dev/diff_rules_go_fork.py",
        )
    )
    lines.append("")
    return "\n".join(lines)


def print_list(changed: dict[str, list[str]]) -> None:
    for section in ("modified", "added", "removed"):
        for rel in changed[section]:
            print("%s\t%s" % (section, rel))


def emit_patch(upstream_root: Path, fork_root: Path) -> int:
    with tempfile.TemporaryDirectory(prefix="rules_go_diff_") as tmp:
        patch_root = Path(tmp)
        upstream_view = patch_root / "upstream"
        fork_view = patch_root / "fork"
        shutil.copytree(upstream_root, upstream_view)
        shutil.copytree(fork_root, fork_view)
        result = subprocess.run(
            [
                "git",
                "diff",
                "--no-index",
                "--src-prefix=upstream/",
                "--dst-prefix=fork/",
                "upstream",
                "fork",
            ],
            cwd=patch_root,
            check=False,
        )
    if result.returncode in (0, 1):
        return 0
    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--metadata",
        default=str(DEFAULT_METADATA),
        help="Path to the fork metadata file.",
    )
    parser.add_argument(
        "--write-report",
        action="store_true",
        help="Rewrite the checked-in markdown report from metadata.",
    )
    parser.add_argument(
        "--report-path",
        default="",
        help="Override the markdown report path.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="Print the changed path list to stdout.",
    )
    parser.add_argument(
        "--patch",
        action="store_true",
        help="Emit a full unified diff against the upstream base.",
    )
    args = parser.parse_args()

    metadata_path = Path(args.metadata).resolve()
    metadata = load_metadata(metadata_path)
    fork_root = (REPO_ROOT / metadata["fork_path"]).resolve()

    with tempfile.TemporaryDirectory(prefix="rules_go_upstream_") as tmp:
        upstream_root = download_upstream_tree(
            metadata["upstream"]["repository"],
            metadata["upstream"]["commit"],
            Path(tmp),
        )
        changed = compare_trees(upstream_root, fork_root)

        if args.list:
            print_list(changed)

        if args.write_report:
            report_path = Path(args.report_path) if args.report_path else REPO_ROOT / metadata["generated_report"]
            report = build_report(metadata_path, metadata, changed)
            report_path.write_text(report, encoding="utf-8")
            print("wrote %s" % report_path.relative_to(REPO_ROOT))

        if args.patch:
            return emit_patch(upstream_root, fork_root)

        if not args.list and not args.write_report and not args.patch:
            total = sum(len(values) for values in changed.values())
            print("changed paths: %d" % total)
            print("modified: %d" % len(changed["modified"]))
            print("added: %d" % len(changed["added"]))
            print("removed: %d" % len(changed["removed"]))

    return 0


if __name__ == "__main__":
    sys.exit(main())
