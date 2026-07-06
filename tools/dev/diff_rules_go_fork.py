#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

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
DEFAULT_METADATA = (
    REPO_ROOT
    / "third_party"
    / "rgo"
    / "v0_60_0"
    / "base.METADATA.json"
)

try:
    from tools.dev.rules_go_fork_registry import (
        DEFAULT_REGISTRY,
        is_ignored_tree_path,
        load_registry,
        repo_relative_path,
    )
except ModuleNotFoundError:
    sys.path.insert(0, str(REPO_ROOT))
    from tools.dev.rules_go_fork_registry import (
        DEFAULT_REGISTRY,
        is_ignored_tree_path,
        load_registry,
        repo_relative_path,
    )


def load_metadata(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    return data


def metadata_from_selection(registry, selection) -> dict:
    """Return the metadata schema used by fork delta reports."""
    return {
        "fork_path": repo_relative_path(registry.repo_root, selection.tree_path),
        "upstream": {
            "repository": selection.upstream.repository,
            "commit": selection.upstream.commit,
            "tag": selection.upstream.tag,
        },
        "generated_report": repo_relative_path(
            registry.repo_root,
            selection.changed_files_report,
        ),
        "generator": (
            "python3 tools/dev/diff_rules_go_fork.py "
            "--upstream %s --variant %s --write-report"
            % (selection.upstream_id, selection.variant)
        ),
    }


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


def tree_file_map(root: Path) -> dict[str, Path]:
    """Return comparable files below a tree, excluding local output paths."""
    files: dict[str, Path] = {}
    for current_root, dirnames, names in os.walk(root):
        rel_root = Path(current_root).relative_to(root)
        dirnames[:] = [
            name for name in dirnames
            if not is_ignored_tree_path(rel_root / name)
        ]
        for name in names:
            rel = rel_root / name
            if is_ignored_tree_path(rel):
                continue
            path = Path(current_root) / name
            if path.is_file() or path.is_symlink():
                files[rel.as_posix()] = path
    return files


def compare_trees(upstream_root: Path, fork_root: Path) -> dict[str, list[str]]:
    changed: dict[str, list[str]] = {
        "modified": [],
        "added": [],
        "removed": [],
    }

    upstream_files = tree_file_map(upstream_root)
    fork_files = tree_file_map(fork_root)

    for rel in sorted(set(upstream_files) | set(fork_files)):
        upstream_path = upstream_files.get(rel)
        fork_path = fork_files.get(rel)
        if upstream_path is not None and fork_path is not None:
            if upstream_path.is_symlink() or fork_path.is_symlink():
                same = (
                    upstream_path.is_symlink()
                    and fork_path.is_symlink()
                    and os.readlink(upstream_path) == os.readlink(fork_path)
                )
            else:
                same = filecmp.cmp(upstream_path, fork_path, shallow=False)
            if not same:
                changed["modified"].append(rel)
        elif fork_path is not None:
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


def copy_filtered_tree_for_patch_export(src: Path, dst: Path) -> None:
    """Copy a tree for patch export while dropping local Bazel output paths."""
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)
    for current_root, dirnames, filenames in os.walk(src):
        rel_root = Path(current_root).relative_to(src)
        dirnames[:] = [
            name for name in dirnames
            if not is_ignored_tree_path(rel_root / name)
        ]
        target_root = dst / rel_root
        target_root.mkdir(parents=True, exist_ok=True)
        for name in filenames:
            rel = rel_root / name
            if is_ignored_tree_path(rel):
                continue
            source = Path(current_root) / name
            target = target_root / name
            if source.is_symlink():
                target.symlink_to(os.readlink(source))
            else:
                shutil.copy2(source, target)


def normalize_no_index_patch_paths(text: str, old_prefix: str, new_prefix: str) -> str:
    """Remove temp directory names from git diff --no-index patch header lines."""
    normalized = []
    for line in text.splitlines(keepends=True):
        if line.startswith("diff --git "):
            line = line.replace(" a/" + old_prefix, " a/", 1)
            line = line.replace(" a/" + new_prefix, " a/", 1)
            line = line.replace(" b/" + old_prefix, " b/", 1)
            line = line.replace(" b/" + new_prefix, " b/", 1)
        elif line.startswith("--- a/"):
            line = line.replace("--- a/" + old_prefix, "--- a/", 1)
            line = line.replace("--- a/" + new_prefix, "--- a/", 1)
        elif line.startswith("+++ b/"):
            line = line.replace("+++ b/" + old_prefix, "+++ b/", 1)
            line = line.replace("+++ b/" + new_prefix, "+++ b/", 1)
        elif line.startswith("rename from "):
            line = line.replace("rename from " + old_prefix, "rename from ", 1)
            line = line.replace("rename from " + new_prefix, "rename from ", 1)
        elif line.startswith("rename to "):
            line = line.replace("rename to " + old_prefix, "rename to ", 1)
            line = line.replace("rename to " + new_prefix, "rename to ", 1)
        elif line.startswith("copy from "):
            line = line.replace("copy from " + old_prefix, "copy from ", 1)
            line = line.replace("copy from " + new_prefix, "copy from ", 1)
        elif line.startswith("copy to "):
            line = line.replace("copy to " + old_prefix, "copy to ", 1)
            line = line.replace("copy to " + new_prefix, "copy to ", 1)
        elif line.startswith("Binary files a/"):
            line = line.replace("Binary files a/" + old_prefix, "Binary files a/", 1)
            line = line.replace("Binary files a/" + new_prefix, "Binary files a/", 1)
            line = line.replace(" and b/" + old_prefix, " and b/", 1)
            line = line.replace(" and b/" + new_prefix, " and b/", 1)
        normalized.append(line)
    return "".join(normalized)


def export_patch_series(
    old_root: Path,
    new_root: Path,
    patch_root: Path,
    output_dir: Path,
    series_path: Path,
    patch_name: str,
) -> None:
    """Export one deterministic git-apply-compatible patch and series file."""
    output_dir.mkdir(parents=True, exist_ok=True)
    series_path.parent.mkdir(parents=True, exist_ok=True)
    patch_root = patch_root.resolve()
    output_dir = output_dir.resolve()
    series_path = series_path.resolve()
    with tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp)
        old_copy = tmp / "__old__"
        new_copy = tmp / "__new__"
        copy_filtered_tree_for_patch_export(old_root, old_copy)
        copy_filtered_tree_for_patch_export(new_root, new_copy)
        result = subprocess.run(
            [
                "git",
                "diff",
                "--no-index",
                "--binary",
                "--no-ext-diff",
                "--src-prefix=a/",
                "--dst-prefix=b/",
                "--",
                "__old__",
                "__new__",
            ],
            cwd=tmp,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode not in (0, 1):
            raise RuntimeError(result.stderr)
        patch_text = normalize_no_index_patch_paths(
            result.stdout,
            old_prefix="__old__/",
            new_prefix="__new__/",
        )
        patch_path = output_dir / patch_name
        patch_path.write_text(patch_text, encoding="utf-8")
        series_path.write_text("%s\n" % patch_path.relative_to(patch_root).as_posix(), encoding="utf-8")
    print("wrote %s" % display_path(patch_path))
    print("wrote %s" % display_path(series_path))


def resolve_repo_path(value: str) -> Path:
    """Resolve a command-line path relative to the repository root."""
    path = Path(value)
    if not path.is_absolute():
        path = REPO_ROOT / path
    return path.resolve()


def display_path(path: Path) -> str:
    """Return a readable path, relative to the repo when possible."""
    try:
        return path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def run_diff_command(
    args: argparse.Namespace,
    metadata_path: Path,
    metadata: dict,
    fork_root: Path,
    default_report_path: Path,
    label: str = "",
) -> int:
    """Run the diff helper workflow for one metadata object."""
    if args.export_patch_series:
        if not args.new_tree:
            raise ValueError("--new-tree is required with --export-patch-series")
        if not args.patch_root:
            raise ValueError("--patch-root is required with --export-patch-series")
        if not args.patch_output_dir:
            raise ValueError("--patch-output-dir is required with --export-patch-series")
        if not args.series_file:
            raise ValueError("--series-file is required with --export-patch-series")
        if args.old_tree:
            export_patch_series(
                old_root=resolve_repo_path(args.old_tree),
                new_root=resolve_repo_path(args.new_tree),
                patch_root=resolve_repo_path(args.patch_root),
                output_dir=resolve_repo_path(args.patch_output_dir),
                series_path=resolve_repo_path(args.series_file),
                patch_name=args.patch_name,
            )
            return 0

    with tempfile.TemporaryDirectory(prefix="rules_go_upstream_") as tmp:
        upstream_root = download_upstream_tree(
            metadata["upstream"]["repository"],
            metadata["upstream"]["commit"],
            Path(tmp),
        )
        changed = compare_trees(upstream_root, fork_root)

        if label:
            print("%s:" % label)

        if args.list:
            print_list(changed)

        if args.write_report:
            report_path = Path(args.report_path) if args.report_path else default_report_path
            report = build_report(metadata_path, metadata, changed)
            report_path.write_text(report, encoding="utf-8")
            print("wrote %s" % report_path.relative_to(REPO_ROOT))

        if args.patch:
            return emit_patch(upstream_root, fork_root)

        if args.export_patch_series:
            export_patch_series(
                old_root=upstream_root,
                new_root=resolve_repo_path(args.new_tree),
                patch_root=resolve_repo_path(args.patch_root),
                output_dir=resolve_repo_path(args.patch_output_dir),
                series_path=resolve_repo_path(args.series_file),
                patch_name=args.patch_name,
            )
            return 0

        if not args.list and not args.write_report and not args.patch:
            total = sum(len(values) for values in changed.values())
            print("changed paths: %d" % total)
            print("modified: %d" % len(changed["modified"]))
            print("added: %d" % len(changed["added"]))
            print("removed: %d" % len(changed["removed"]))

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--metadata",
        default=str(DEFAULT_METADATA),
        help="Path to the fork metadata file.",
    )
    parser.add_argument(
        "--registry",
        default=str(DEFAULT_REGISTRY),
        help="Path to the fork registry for --upstream/--variant mode.",
    )
    parser.add_argument(
        "--upstream",
        default="",
        help="Registry upstream id to compare.",
    )
    parser.add_argument(
        "--variant",
        default="",
        help="Registry variant id to compare.",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Compare every registry upstream and variant selection.",
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
    parser.add_argument("--export-patch-series", action="store_true", help="Write patch files for the selected fork.")
    parser.add_argument("--old-tree", default="", help="Repository-relative source tree for patch export.")
    parser.add_argument("--new-tree", default="", help="Repository-relative destination tree for patch export.")
    parser.add_argument("--patch-root", default="", help="Upstream patch root used for .series relative paths.")
    parser.add_argument("--patch-output-dir", default="", help="Directory for --export-patch-series output.")
    parser.add_argument("--series-file", default="", help="Series file to write for --export-patch-series.")
    parser.add_argument("--patch-name", default="0001-full-delta.patch", help="Patch filename to write inside --patch-output-dir.")
    args = parser.parse_args()

    use_registry = bool(args.all or args.upstream or args.variant)
    if use_registry and args.metadata != str(DEFAULT_METADATA):
        parser.error("--metadata cannot be combined with --upstream/--variant registry mode")
    if args.all and (args.upstream or args.variant):
        parser.error("--all cannot be combined with --upstream or --variant")
    if args.all and args.export_patch_series:
        parser.error("--all cannot be combined with --export-patch-series")
    if args.all and args.patch:
        parser.error("--all cannot be combined with --patch")

    if use_registry:
        registry = load_registry(Path(args.registry).resolve())
        selections = registry.selections() if args.all else [
            registry.resolve(args.upstream or "default", args.variant or "default"),
        ]
        status = 0
        for selection in selections:
            status = max(
                status,
                run_diff_command(
                    args,
                    metadata_path=selection.metadata_path,
                    metadata=metadata_from_selection(registry, selection),
                    fork_root=selection.tree_path,
                    default_report_path=selection.changed_files_report,
                    label=("%s/%s" % (selection.upstream_id, selection.variant)) if args.all else "",
                ),
            )
        return status
    else:
        metadata_path = Path(args.metadata).resolve()
        metadata = load_metadata(metadata_path)
        fork_root = (REPO_ROOT / metadata["fork_path"]).resolve()
        default_report_path = REPO_ROOT / metadata["generated_report"]

    try:
        return run_diff_command(args, metadata_path, metadata, fork_root, default_report_path)
    except ValueError as exc:
        parser.error(str(exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())
