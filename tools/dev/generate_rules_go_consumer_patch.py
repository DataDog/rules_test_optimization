#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Generate generic consumer patch profiles from the rules_go Orchestrion fork."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import filecmp
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any

try:
    from tools.dev.diff_rules_go_fork import normalize_no_index_patch_paths
    from tools.dev.materialize_rules_go_fork import (
        apply_patch_series,
        copy_filtered_tree,
        download_upstream,
        read_series,
    )
    from tools.dev.rules_go_fork_registry import (
        DEFAULT_REGISTRY,
        REPO_ROOT,
        REMOVED_COMPLETE_VARIANT_ERROR,
        is_ignored_tree_path,
        load_registry,
    )
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from tools.dev.diff_rules_go_fork import normalize_no_index_patch_paths
    from tools.dev.materialize_rules_go_fork import (
        apply_patch_series,
        copy_filtered_tree,
        download_upstream,
        read_series,
    )
    from tools.dev.rules_go_fork_registry import (
        DEFAULT_REGISTRY,
        REPO_ROOT,
        REMOVED_COMPLETE_VARIANT_ERROR,
        is_ignored_tree_path,
        load_registry,
    )


DEFAULT_PROFILE_ROOT = REPO_ROOT / "third_party" / "rules_go_orchestrion" / "profiles"


@dataclass(frozen=True)
class PatchProfile:
    """Validated consumer patch profile metadata."""

    path: Path
    name: str
    description: str
    variant: str
    include: tuple[str, ...]
    exclude: tuple[str, ...]
    private_safe: bool


@dataclass(frozen=True)
class PathClassification:
    """Changed paths classified by one profile."""

    changed: list[str]
    included: list[str]
    excluded: list[str]
    unclassified: list[str]


@dataclass(frozen=True)
class PatchGenerationResult:
    """Generated patch output summary."""

    output: Path
    manifest: Path
    included: list[str]
    excluded: list[str]
    patch_sha256: str


def load_profile(path: Path) -> PatchProfile:
    """Load and validate one profile JSON file."""
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise ValueError("profile schema_version must be 1")
    name = _require_string(data, "name")
    description = _require_string(data, "description")
    variant = _require_string(data, "variant")
    if variant != "base":
        if variant == "complete":
            raise ValueError(REMOVED_COMPLETE_VARIANT_ERROR)
        raise ValueError("profile variant must be 'base', got %r" % variant)
    include = _require_string_list(data, "include")
    if not include:
        raise ValueError("profile include must be non-empty")
    exclude = _require_string_list(data, "exclude")
    private_safe = data.get("private_safe")
    if private_safe is not True:
        raise ValueError("profile private_safe must be true")
    for pattern in [*include, *exclude]:
        _validate_profile_pattern(pattern)
    return PatchProfile(
        path=Path(path),
        name=name,
        description=description,
        variant=variant,
        include=tuple(include),
        exclude=tuple(exclude),
        private_safe=True,
    )


def classify_paths(paths: list[str], profile: PatchProfile) -> PathClassification:
    """Classify changed paths as included, excluded, or unclassified."""
    changed = sorted({path for path in paths if not is_ignored_tree_path(Path(path))})
    included: list[str] = []
    excluded: list[str] = []
    unclassified: list[str] = []
    for path in changed:
        if matches_any(path, profile.exclude):
            excluded.append(path)
        elif matches_any(path, profile.include):
            included.append(path)
        else:
            unclassified.append(path)
    return PathClassification(
        changed=changed,
        included=included,
        excluded=excluded,
        unclassified=unclassified,
    )


def matches_any(path: str, patterns: tuple[str, ...]) -> bool:
    """Return whether path matches any profile pattern."""
    return any(matches_pattern(path, pattern) for pattern in patterns)


def matches_pattern(path: str, pattern: str) -> bool:
    """Return whether a repository-relative path matches one profile pattern."""
    normalized = Path(path).as_posix()
    if is_ignored_tree_path(Path(normalized)):
        return False
    if pattern.startswith("/"):
        return normalized == pattern[1:]
    if any(token in pattern for token in ("*", "?", "[")):
        return fnmatch.fnmatchcase(normalized, pattern)
    return normalized == pattern


def changed_paths_between_trees(upstream_root: Path, fork_root: Path) -> list[str]:
    """Return all file, symlink, content, and mode differences between two trees."""
    upstream_files = tree_file_map(upstream_root)
    fork_files = tree_file_map(fork_root)
    changed: list[str] = []
    for rel in sorted(set(upstream_files) | set(fork_files)):
        upstream_path = upstream_files.get(rel)
        fork_path = fork_files.get(rel)
        if upstream_path is None or fork_path is None:
            changed.append(rel)
            continue
        if file_metadata(upstream_path) != file_metadata(fork_path):
            changed.append(rel)
            continue
        if upstream_path.is_symlink() or fork_path.is_symlink():
            continue
        if not filecmp.cmp(upstream_path, fork_path, shallow=False):
            changed.append(rel)
    return changed


def generate_patch_from_trees(
    *,
    upstream_root: Path,
    fork_root: Path,
    profile: PatchProfile,
    output: Path,
    manifest: Path,
    manifest_context: dict[str, str],
    check_private_safe: bool = False,
    public_denylist: Path | None = None,
    private_blocklist_file: Path | None = None,
) -> PatchGenerationResult:
    """Generate a profile patch from already-materialized upstream and fork trees."""
    private_safe_patterns = (
        read_private_safe_patterns(public_denylist, private_blocklist_file)
        if check_private_safe
        else []
    )
    classification = classify_paths(changed_paths_between_trees(upstream_root, fork_root), profile)
    if classification.unclassified:
        raise ValueError(
            "%s profile does not classify these changed paths:\n%s"
            % (profile.name, "\n".join(classification.unclassified))
        )
    if not classification.included:
        raise ValueError("%s profile selected no changed paths" % profile.name)

    output.parent.mkdir(parents=True, exist_ok=True)
    manifest.parent.mkdir(parents=True, exist_ok=True)

    patch_text = generate_sparse_patch(
        upstream_root,
        fork_root,
        classification.included,
        private_safe_patterns=private_safe_patterns,
    )
    output.write_text(patch_text, encoding="utf-8", newline="\n")

    verify_patch_applies_to_clean_upstream(
        upstream_root=upstream_root,
        fork_root=fork_root,
        patch=output,
        included=classification.included,
        private_safe_patterns=private_safe_patterns,
    )
    verify_excluded_paths_absent(output, classification.excluded)

    patch_sha = sha256_file(output)
    manifest_data: dict[str, Any] = {
        "schema_version": 1,
        "profile": profile.name,
        "upstream_id": manifest_context["upstream_id"],
        "rules_go_version": manifest_context["rules_go_version"],
        "upstream_repository": manifest_context["upstream_repository"],
        "upstream_commit": manifest_context["upstream_commit"],
        "variant": manifest_context["variant"],
        "included_paths": classification.included,
        "excluded_paths": classification.excluded,
        "private_safe": True,
        "patch_sha256": patch_sha,
    }
    manifest.write_text(
        json.dumps(manifest_data, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )

    if check_private_safe:
        verify_private_safe(
            paths=[output, manifest, profile.path],
            public_denylist=public_denylist,
            private_blocklist_file=private_blocklist_file,
        )
        verify_modified_tracked_files_private_safe(
            public_denylist=public_denylist,
            private_blocklist_file=private_blocklist_file,
        )

    return PatchGenerationResult(
        output=output,
        manifest=manifest,
        included=classification.included,
        excluded=classification.excluded,
        patch_sha256=patch_sha,
    )


def generate_consumer_patch(
    *,
    registry_path: Path,
    upstream: str,
    variant: str,
    profile_path: Path,
    output: Path,
    manifest: Path,
    check_private_safe: bool = False,
    public_denylist: Path | None = None,
    private_blocklist_file: Path | None = None,
) -> PatchGenerationResult:
    """Generate one profile patch for a registry selection."""
    registry = load_registry(registry_path)
    profile = load_profile(profile_path)
    selection = registry.resolve(upstream, variant)
    if selection.variant != profile.variant:
        raise ValueError("profile variant %r does not match selection variant %r" % (profile.variant, selection.variant))
    with tempfile.TemporaryDirectory(prefix="rules_go_consumer_patch_") as raw_tmp:
        tmp = Path(raw_tmp)
        upstream_source = download_upstream(selection, tmp / "download")
        upstream_root = tmp / "upstream"
        fork_root = tmp / "fork"
        copy_filtered_tree(upstream_source, upstream_root)
        copy_filtered_tree(upstream_source, fork_root)
        apply_patch_series(
            fork_root,
            patch_root=selection.series_path.parent,
            series=read_series(selection.series_path),
        )
        return generate_patch_from_trees(
            upstream_root=upstream_root,
            fork_root=fork_root,
            profile=profile,
            output=output,
            manifest=manifest,
            manifest_context={
                "upstream_id": selection.upstream_id,
                "rules_go_version": selection.rules_go_version,
                "upstream_repository": selection.upstream.repository,
                "upstream_commit": selection.upstream.commit,
                "variant": selection.variant,
            },
            check_private_safe=check_private_safe,
            public_denylist=public_denylist,
            private_blocklist_file=private_blocklist_file,
        )


def generate_sparse_patch(
    upstream_root: Path,
    fork_root: Path,
    included: list[str],
    *,
    private_safe_patterns: list[str] | None = None,
) -> str:
    """Generate a deterministic git patch for included paths only."""
    patterns = private_safe_patterns or []
    with tempfile.TemporaryDirectory(prefix="rules_go_sparse_patch_") as raw_tmp:
        tmp = Path(raw_tmp)
        old_view = tmp / "__old__"
        new_view = tmp / "__new__"
        old_view.mkdir()
        new_view.mkdir()
        for rel in sorted(included):
            copy_sparse_path(upstream_root, old_view, rel)
            copy_sparse_path(fork_root, new_view, rel)
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
        verify_private_safe_text("git diff stdout", result.stdout, patterns)
        verify_private_safe_text("git diff stderr", result.stderr, patterns)
        if result.returncode not in (0, 1):
            raise RuntimeError(result.stderr)
        patch_text = normalize_no_index_patch_paths(
            result.stdout,
            old_prefix="__old__/",
            new_prefix="__new__/",
        )
        if not patch_text:
            raise ValueError("profile patch is empty")
        return patch_text


def copy_sparse_path(src_root: Path, dst_root: Path, rel: str) -> None:
    """Copy one sparse path into a view, preserving symlinks and mode bits."""
    source = src_root / rel
    if not source.exists() and not source.is_symlink():
        return
    target = dst_root / rel
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        target.symlink_to(os.readlink(source))
    else:
        shutil.copy2(source, target)


def verify_patch_applies_to_clean_upstream(
    *,
    upstream_root: Path,
    fork_root: Path,
    patch: Path,
    included: list[str],
    private_safe_patterns: list[str] | None = None,
) -> None:
    """Verify generated patch application reproduces included fork paths."""
    patterns = private_safe_patterns or []
    with tempfile.TemporaryDirectory(prefix="rules_go_patch_apply_") as raw_tmp:
        apply_root = Path(raw_tmp) / "apply"
        copy_filtered_tree(upstream_root, apply_root)
        run_private_safe(
            ["git", "-C", apply_root.as_posix(), "apply", "--binary", "-p1", patch.as_posix()],
            private_safe_patterns=patterns,
        )
        for rel in included:
            expected = fork_root / rel
            actual = apply_root / rel
            if expected.exists() or expected.is_symlink():
                if not actual.exists() and not actual.is_symlink():
                    raise ValueError("generated patch did not create included path %s" % rel)
                if file_metadata(expected) != file_metadata(actual):
                    raise ValueError("generated patch metadata mismatch for %s" % rel)
                if not expected.is_symlink() and not filecmp.cmp(expected, actual, shallow=False):
                    raise ValueError("generated patch content mismatch for %s" % rel)
            elif actual.exists() or actual.is_symlink():
                raise ValueError("generated patch did not delete included path %s" % rel)


def verify_excluded_paths_absent(patch: Path, excluded: list[str]) -> None:
    """Verify excluded paths do not appear in normalized patch headers."""
    text = patch.read_text(encoding="utf-8")
    for rel in excluded:
        headers = [
            "diff --git a/%s b/%s" % (rel, rel),
            "--- a/%s" % rel,
            "+++ b/%s" % rel,
            "rename from %s" % rel,
            "rename to %s" % rel,
            "copy from %s" % rel,
            "copy to %s" % rel,
        ]
        if any(header in text for header in headers):
            raise ValueError("excluded path appears in generated patch: %s" % rel)


def verify_private_safe(
    *,
    paths: list[Path],
    public_denylist: Path | None,
    private_blocklist_file: Path | None,
) -> None:
    """Scan generated files for public and optional private denylist patterns."""
    patterns = read_private_safe_patterns(public_denylist, private_blocklist_file)
    for path in paths:
        if path is None or not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        verify_private_safe_text(path.as_posix(), text, patterns)


def verify_modified_tracked_files_private_safe(
    *,
    public_denylist: Path | None,
    private_blocklist_file: Path | None,
) -> None:
    """Scan modified tracked files when a local private blocklist is present."""
    if private_blocklist_file is None:
        return
    verify_private_safe(
        paths=modified_tracked_files(),
        public_denylist=public_denylist,
        private_blocklist_file=private_blocklist_file,
    )


def modified_tracked_files() -> list[Path]:
    """Return modified tracked repository files for local private-safety scans."""
    paths: set[Path] = set()
    for args in (
        ["diff", "--name-only", "--diff-filter=ACMRT"],
        ["diff", "--cached", "--name-only", "--diff-filter=ACMRT"],
    ):
        result = subprocess.run(
            ["git", "-C", REPO_ROOT.as_posix(), *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip())
        for line in result.stdout.splitlines():
            path = REPO_ROOT / line
            if path.is_file():
                paths.add(path)
    return sorted(paths)


def read_private_safe_patterns(
    public_denylist: Path | None,
    private_blocklist_file: Path | None,
) -> list[str]:
    """Return all public and optional private fixed-string denylist patterns."""
    patterns = []
    if public_denylist is not None:
        patterns.extend(read_denylist(public_denylist))
    if private_blocklist_file is not None:
        patterns.extend(read_denylist(private_blocklist_file))
    return patterns


def verify_private_safe_text(source: str, text: str, patterns: list[str]) -> None:
    """Scan captured text without echoing the matched private pattern."""
    for pattern in patterns:
        if pattern in text:
            raise ValueError("private-safe scan failed for %s" % source)


def run_private_safe(
    argv: list[str],
    *,
    private_safe_patterns: list[str] | None = None,
    **kwargs: Any,
) -> subprocess.CompletedProcess[str]:
    """Run one command and scan captured output before reporting failures."""
    result = subprocess.run(
        argv,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        **kwargs,
    )
    patterns = private_safe_patterns or []
    verify_private_safe_text("%s stdout" % argv[0], result.stdout, patterns)
    verify_private_safe_text("%s stderr" % argv[0], result.stderr, patterns)
    if result.returncode != 0:
        raise RuntimeError(
            "command failed (%s): %s" % (" ".join(argv), result.stderr.strip())
        )
    return result


def read_denylist(path: Path) -> list[str]:
    """Return non-empty fixed-string denylist patterns."""
    return [
        line.strip()
        for line in Path(path).read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


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


def sha256_file(path: Path) -> str:
    """Return the SHA256 digest for a file."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_string(data: dict[str, Any], key: str) -> str:
    """Return a required non-empty string field."""
    value = data.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError("profile field %s must be a non-empty string" % key)
    return value


def _require_string_list(data: dict[str, Any], key: str) -> list[str]:
    """Return a required string list field."""
    value = data.get(key)
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise ValueError("profile field %s must be a list of non-empty strings" % key)
    return value


def _validate_profile_pattern(pattern: str) -> None:
    """Validate one include/exclude pattern."""
    normalized = pattern.removeprefix("/")
    if not pattern.startswith("/") and "/" not in normalized and not any(token in normalized for token in ("*", "?", "[")):
        raise ValueError("profile pattern %r is a bare basename; use a root anchor such as /%s" % (pattern, pattern))
    if ".." in Path(normalized).parts:
        raise ValueError("profile pattern must not contain '..': %s" % pattern)


def profile_path(profile_root: Path, profile: str) -> Path:
    """Return the JSON file path for a profile name or direct path."""
    candidate = Path(profile)
    if candidate.suffix == ".json" or candidate.is_absolute() or "/" in profile:
        return candidate if candidate.is_absolute() else (REPO_ROOT / candidate)
    return profile_root / ("%s.json" % profile)


def _generate_for_all_upstreams(args: argparse.Namespace) -> int:
    """Generate one profile patch per registered upstream."""
    registry = load_registry(args.registry)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    status = 0
    for upstream_id in registry.upstream_ids():
        output = args.output_dir / ("%s-%s.patch" % (upstream_id, args.profile))
        manifest = args.output_dir / ("%s-%s.MANIFEST.json" % (upstream_id, args.profile))
        generate_consumer_patch(
            registry_path=args.registry,
            upstream=upstream_id,
            variant=args.variant,
            profile_path=profile_path(args.profile_root, args.profile),
            output=output,
            manifest=manifest,
            check_private_safe=args.check_private_safe,
            public_denylist=args.public_denylist,
            private_blocklist_file=args.private_blocklist_file,
        )
        print("wrote %s" % output)
        print("wrote %s" % manifest)
    return status


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--profile-root", type=Path, default=DEFAULT_PROFILE_ROOT)
    parser.add_argument("--upstream", default="")
    parser.add_argument("--all-upstreams", action="store_true")
    parser.add_argument("--variant", default="base")
    parser.add_argument("--profile", default="workspace_runtime")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--check-private-safe", action="store_true")
    parser.add_argument("--public-denylist", type=Path)
    parser.add_argument("--private-blocklist-file", type=Path)
    args = parser.parse_args(argv)

    try:
        if args.variant == "complete":
            raise ValueError(REMOVED_COMPLETE_VARIANT_ERROR)
        if args.all_upstreams:
            if args.output or args.manifest:
                parser.error("--all-upstreams cannot be combined with --output/--manifest")
            if not args.output_dir:
                parser.error("--all-upstreams requires --output-dir")
            return _generate_for_all_upstreams(args)
        if not args.upstream:
            parser.error("--upstream is required unless --all-upstreams is set")
        if not args.output or not args.manifest:
            parser.error("--output and --manifest are required")
        generate_consumer_patch(
            registry_path=args.registry,
            upstream=args.upstream,
            variant=args.variant,
            profile_path=profile_path(args.profile_root, args.profile),
            output=args.output,
            manifest=args.manifest,
            check_private_safe=args.check_private_safe,
            public_denylist=args.public_denylist,
            private_blocklist_file=args.private_blocklist_file,
        )
        print("wrote %s" % args.output)
        print("wrote %s" % args.manifest)
        return 0
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
