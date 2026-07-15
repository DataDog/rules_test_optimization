#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Materialize registry-backed rules_go Orchestrion fork trees from patch series."""

from __future__ import annotations

import argparse
import filecmp
import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

try:
    from tools.dev.rules_go_fork_registry import (
        DEFAULT_REGISTRY,
        ForkRegistry,
        ForkSelection,
        REPO_ROOT,
        REMOVED_COMPLETE_VARIANT_ERROR,
        is_ignored_tree_path,
        load_registry,
        repo_relative_path,
    )
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from tools.dev.rules_go_fork_registry import (
        DEFAULT_REGISTRY,
        ForkRegistry,
        ForkSelection,
        REPO_ROOT,
        REMOVED_COMPLETE_VARIANT_ERROR,
        is_ignored_tree_path,
        load_registry,
        repo_relative_path,
    )


def default_cache_root() -> Path:
    """Return the rules_go archive cache root."""
    override = os.environ.get("RULES_GO_ORCHESTRION_CACHE")
    if override:
        return Path(override)
    try:
        home = Path.home()
    except RuntimeError:
        return Path(tempfile.gettempdir()) / "rules_go_orchestrion"
    return home / ".cache" / "rules_go_orchestrion"


CACHE_ROOT = default_cache_root()


def run(argv: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    """Run a command, returning the completed process or raising with stderr."""
    result = subprocess.run(
        argv,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        **kwargs,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "command failed (%s): %s" % (" ".join(argv), result.stderr.strip())
        )
    return result


def archive_url(selection: ForkSelection) -> str:
    """Return the immutable upstream tarball URL for a commit."""
    repo_url = selection.upstream.repository.removesuffix(".git")
    return f"{repo_url}/archive/{selection.upstream.commit}.tar.gz"


def sha256_file(path: Path) -> str:
    """Return the SHA256 hex digest for one file."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_archive(selection: ForkSelection, tempdir: Path) -> Path:
    """Download or reuse a cached upstream tarball and verify its checksum."""
    if len(selection.upstream.archive_sha256) != 64:
        raise ValueError(
            "registry archive_sha256 must be a full SHA256 for %s" % selection.upstream_id
        )
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    cache_path = CACHE_ROOT / ("%s.tar.gz" % selection.upstream.commit)
    if not cache_path.is_file() or sha256_file(cache_path) != selection.upstream.archive_sha256:
        url = archive_url(selection)
        tmp_archive = tempdir / "upstream.tar.gz"
        with urllib.request.urlopen(url, timeout=60) as response, tmp_archive.open("wb") as handle:
            shutil.copyfileobj(response, handle)
        actual = sha256_file(tmp_archive)
        if actual != selection.upstream.archive_sha256:
            raise RuntimeError(
                "sha256 mismatch for %s: got %s, want %s"
                % (url, actual, selection.upstream.archive_sha256)
            )
        shutil.copy2(tmp_archive, cache_path)
    return cache_path


def download_upstream(selection: ForkSelection, tempdir: Path) -> Path:
    """Download and extract the exact upstream GitHub tarball for a selection."""
    tempdir.mkdir(parents=True, exist_ok=True)
    archive = download_archive(selection, tempdir)
    extract_dir = tempdir / "upstream"
    extract_dir.mkdir()
    with tarfile.open(archive, "r:gz") as tar:
        destination_root = extract_dir.resolve()
        for member in tar.getmembers():
            target_path = (extract_dir / member.name).resolve()
            if os.path.commonpath([str(destination_root), str(target_path)]) != str(destination_root):
                raise ValueError(
                    "refusing to extract archive member outside destination: %s" % member.name
                )
        if hasattr(tarfile, "data_filter"):
            tar.extractall(extract_dir, filter="data")
        else:
            tar.extractall(extract_dir)
    children = [path for path in extract_dir.iterdir() if path.is_dir()]
    if len(children) != 1:
        raise RuntimeError(
            "expected exactly one extracted upstream directory from %s" % archive_url(selection)
        )
    return children[0]


def copy_filtered_tree(src: Path, dst: Path) -> None:
    """Copy src to dst while dropping local Bazel output paths."""
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


def replace_tree(src: Path, dst: Path) -> None:
    """Replace dst with the filtered contents of src."""
    tmp_dst = dst.with_name(dst.name + ".tmp")
    if tmp_dst.exists():
        shutil.rmtree(tmp_dst)
    copy_filtered_tree(src, tmp_dst)
    if dst.exists():
        shutil.rmtree(dst)
    shutil.move(tmp_dst.as_posix(), dst.as_posix())


def ensure_git_repo(worktree: Path) -> None:
    """Initialize a throwaway repository so git apply never walks to a parent repo."""
    run(["git", "-C", worktree.as_posix(), "init", "-q"])


def read_series(series_path: Path) -> list[Path]:
    """Return patch paths relative to the upstream patch root."""
    return [
        Path(line.strip())
        for line in series_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def apply_patch_series(worktree: Path, patch_root: Path, series: list[Path]) -> None:
    """Apply patch files to a worktree with git apply --binary -p1."""
    ensure_git_repo(worktree)
    for relative_patch in series:
        patch = patch_root / relative_patch
        if not patch.is_file():
            raise FileNotFoundError("missing patch from series: %s" % patch)
        run(["git", "-C", worktree.as_posix(), "apply", "--binary", "-p1", patch.as_posix()])


def materialize_worktree(registry: ForkRegistry, selection: ForkSelection, tmp: Path) -> Path:
    """Return a temporary worktree for patch application; never write final output."""
    if selection.variant == "complete":
        raise ValueError(REMOVED_COMPLETE_VARIANT_ERROR)
    if selection.variant != "base":
        raise ValueError("rules_go_variant must be 'base', got %r" % selection.variant)
    upstream_root = download_upstream(selection, tmp / "download")
    worktree = tmp / "worktree-base"
    copy_filtered_tree(upstream_root, worktree)
    apply_patch_series(
        worktree,
        patch_root=selection.series_path.parent,
        series=read_series(selection.series_path),
    )
    return worktree


def materialize_selection(
    registry: ForkRegistry,
    selection: ForkSelection,
    output_root: Path,
) -> Path:
    """Write one materialized scratch tree to output_root/<upstream>/<variant>."""
    with tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp)
        worktree = materialize_worktree(registry, selection, tmp)
        destination = output_root / selection.upstream_id / selection.variant
        replace_tree(worktree, destination)
        return destination


def write_selection_to_registry_tree(
    registry: ForkRegistry,
    selection: ForkSelection,
) -> Path:
    """Rewrite the checked-in tree selected by the registry."""
    with tempfile.TemporaryDirectory() as raw_tmp:
        tmp = Path(raw_tmp)
        worktree = materialize_worktree(registry, selection, tmp)
        replace_tree(worktree, selection.tree_path)
        return selection.tree_path


def tree_file_map(root: Path) -> dict[str, Path]:
    """Return filtered regular files and symlinks below root keyed by relative path."""
    files: dict[str, Path] = {}
    for current_root, dirnames, filenames in os.walk(root):
        rel_root = Path(current_root).relative_to(root)
        dirnames[:] = [name for name in dirnames if not is_ignored_tree_path(rel_root / name)]
        for name in filenames:
            rel = rel_root / name
            if is_ignored_tree_path(rel):
                continue
            path = Path(current_root) / name
            if path.is_file() or path.is_symlink():
                files[rel.as_posix()] = path
    return files


def file_metadata(path: Path) -> tuple[int, int, str]:
    """Return file type, permission bits, and symlink target for comparison."""
    path_stat = path.lstat()
    link_target = os.readlink(path) if path.is_symlink() else ""
    return (stat.S_IFMT(path_stat.st_mode), stat.S_IMODE(path_stat.st_mode), link_target)


def compare_materialized_tree(expected: Path, actual: Path) -> list[str]:
    """Return deterministic drift entries between checked-in and materialized trees."""
    expected_files = tree_file_map(expected)
    actual_files = tree_file_map(actual)
    paths = sorted(set(expected_files) | set(actual_files))
    drift: list[str] = []
    for rel in paths:
        expected_path = expected_files.get(rel)
        actual_path = actual_files.get(rel)
        if expected_path is None:
            drift.append("unexpected generated file: %s" % rel)
        elif actual_path is None:
            drift.append("missing generated file: %s" % rel)
        elif file_metadata(expected_path) != file_metadata(actual_path):
            drift.append("metadata differs: %s" % rel)
        elif not expected_path.is_symlink() and not filecmp.cmp(expected_path, actual_path, shallow=False):
            drift.append("content differs: %s" % rel)
    return drift


def resolve_selection(registry: ForkRegistry, args: argparse.Namespace) -> ForkSelection:
    """Resolve CLI upstream and variant arguments."""
    return registry.resolve(args.upstream, args.variant)


def check_selection(registry: ForkRegistry, selection: ForkSelection) -> int:
    """Materialize and compare one selection against its checked-in tree."""
    with tempfile.TemporaryDirectory(prefix="rules_go_materialize_check_") as raw_tmp:
        output_root = Path(raw_tmp) / "out"
        actual = materialize_selection(registry, selection, output_root)
        drift = compare_materialized_tree(selection.tree_path, actual)
    if drift:
        print("materialized tree drift: %s/%s" % (selection.upstream_id, selection.variant), file=sys.stderr)
        for entry in drift[:200]:
            print(entry, file=sys.stderr)
        if len(drift) > 200:
            print("... %d additional drift entries" % (len(drift) - 200), file=sys.stderr)
        return 1
    print("materialized tree matches checked-in tree: %s/%s" % (selection.upstream_id, selection.variant))
    return 0


def render_upstream_ids(upstream_ids: list[str]) -> bytes:
    """Render shell-consumable upstream ids with platform-independent LF endings."""
    return "".join("%s\n" % upstream_id for upstream_id in upstream_ids).encode("utf-8")


def main(argv: list[str] | None = None) -> int:
    """Parse CLI arguments and run materializer commands."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolve_parser = subparsers.add_parser("resolve", help="Print a resolved fork tree path.")
    resolve_parser.add_argument("--upstream", default="default")
    resolve_parser.add_argument("--variant", default="base")

    subparsers.add_parser("list-upstreams", help="Print supported upstream ids.")

    check_parser = subparsers.add_parser("check", help="Check materialized output for drift.")
    check_parser.add_argument("--upstream", default="default")
    check_parser.add_argument("--variant", default="base")
    check_parser.add_argument("--all", action="store_true")

    write_parser = subparsers.add_parser("write", help="Write materialized output to the registry tree.")
    write_parser.add_argument("--upstream", default="default")
    write_parser.add_argument("--variant", default="base")

    args = parser.parse_args(argv)

    try:
        registry = load_registry(args.registry)
        if args.command == "resolve":
            selection = resolve_selection(registry, args)
            print(repo_relative_path(registry.repo_root, selection.tree_path))
            return 0
        if args.command == "list-upstreams":
            sys.stdout.buffer.write(render_upstream_ids(registry.upstream_ids()))
            return 0
        if args.command == "check":
            selections = registry.selections() if args.all else [resolve_selection(registry, args)]
            status = 0
            for selection in selections:
                status = max(status, check_selection(registry, selection))
            return status
        if args.command == "write":
            selection = resolve_selection(registry, args)
            written = write_selection_to_registry_tree(registry, selection)
            print("wrote %s" % repo_relative_path(registry.repo_root, written))
            return 0
    except (OSError, RuntimeError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2

    parser.error("unknown command %r" % args.command)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
