#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for generated rules_go consumer patch profiles."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import types
import unittest


def _runfile(rel_path: str) -> Path:
    """Resolve a Bazel runfile, with a direct-checkout fallback."""
    test_srcdir = os.environ.get("TEST_SRCDIR", "")
    test_workspace = os.environ.get("TEST_WORKSPACE", "")
    workspace_dir = os.environ.get("BUILD_WORKSPACE_DIRECTORY", "")
    candidates = []
    if test_srcdir and test_workspace:
        candidates.append(Path(test_srcdir) / test_workspace / rel_path)
    if test_srcdir:
        candidates.append(Path(test_srcdir) / rel_path)
    if workspace_dir:
        candidates.append(Path(workspace_dir) / rel_path)
    here = Path(__file__).resolve().parent
    for candidate in [here] + list(here.parents):
        if (candidate / "MODULE.bazel").exists() or (candidate / ".git").exists():
            candidates.append(candidate / rel_path)
            break
    for candidate in candidates:
        if candidate.exists():
            return candidate

    manifest_path = os.environ.get("RUNFILES_MANIFEST_FILE", "")
    if manifest_path:
        manifest = Path(manifest_path)
        if manifest.exists():
            keys = [rel_path]
            if test_workspace:
                keys.insert(0, f"{test_workspace}/{rel_path}")
            with manifest.open("r", encoding="utf-8") as handle:
                for line in handle:
                    key, sep, value = line.rstrip("\n").partition(" ")
                    if sep and key in keys and value:
                        return Path(value)

    raise FileNotFoundError(f"runfile not found: {rel_path} (checked: {candidates})")


def _load_module(name: str, rel_path: str) -> types.ModuleType:
    """Load a Python tool module from runfiles."""
    path = _runfile(rel_path)
    spec = importlib.util.spec_from_file_location(name, str(path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module spec for {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _write(path: Path, content: str, mode: int = 0o644) -> None:
    """Write one fixture file with parent directories."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    os.chmod(path, mode)


def _copy_tree(src: Path, dst: Path) -> None:
    """Copy a fixture tree preserving symlinks and metadata."""
    shutil.copytree(src, dst, symlinks=True)


class RulesGoProfileToolTests(unittest.TestCase):
    """Test public profile patch generation behavior."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the generator once for all tests."""
        cls.mod = _load_module(
            "generate_rules_go_consumer_patch",
            "tools/dev/generate_rules_go_consumer_patch.py",
        )

    def workspace_profile(self):
        """Load the checked-in workspace runtime profile."""
        return self.mod.load_profile(
            _runfile("third_party/rules_go_orchestrion/profiles/workspace_runtime.json")
        )

    def test_workspace_runtime_profile_classifies_all_fixture_paths(self) -> None:
        """The profile includes runtime paths and excludes module/test paths."""
        profile = self.workspace_profile()
        changed = [
            "BUILD.bazel",
            "MODULE.bazel",
            "MODULE.bazel.lock",
            "docs/doc_helpers.bzl",
            "go/extensions.bzl",
            "go/orchestrion_workspace.bzl",
            "go/private/BUILD.bazel",
            "go/private/actions/compilepkg.bzl",
            "go/private/orchestrion/extensions.bzl",
            "go/tools/builders/BUILD.bazel",
            "go/tools/builders/builder.go",
            "go/tools/builders/env_test.go",
            "tests/core/starlark/context_tests.bzl",
        ]

        classification = self.mod.classify_paths(changed, profile)

        self.assertEqual([], classification.unclassified)
        self.assertIn("BUILD.bazel", classification.included)
        self.assertIn("MODULE.bazel", classification.excluded)
        self.assertIn("go/extensions.bzl", classification.excluded)
        self.assertIn("go/private/BUILD.bazel", classification.included)
        self.assertIn("go/tools/builders/BUILD.bazel", classification.included)
        self.assertIn("go/tools/builders/builder.go", classification.included)
        self.assertIn("go/tools/builders/env_test.go", classification.excluded)

    def test_profile_validation_rejects_bare_basename_patterns(self) -> None:
        """Root-only excludes must be anchored, not bare basenames."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            path = Path(raw_tmp) / "bad_profile.json"
            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "name": "bad",
                        "description": "bad profile",
                        "variant": "base",
                        "include": ["go/private/**"],
                        "exclude": ["BUILD.bazel"],
                        "private_safe": True,
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "bare basename"):
                self.mod.load_profile(path)

    def test_generate_patch_from_trees_applies_and_is_deterministic(self) -> None:
        """Generated profile patches apply cleanly and exclude non-profile paths."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            upstream = root / "upstream"
            fork = root / "fork"
            upstream.mkdir()
            _write(upstream / "BUILD.bazel", "upstream root\n")
            _write(upstream / "MODULE.bazel", "upstream module\n")
            _write(upstream / "go/private/BUILD.bazel", "upstream private build\n")
            _write(upstream / "go/tools/builders/builder.go", "package main\n")
            _write(upstream / "go/tools/builders/env_test.go", "package main\n")
            _write(upstream / "go/private/orchestrion/extensions.bzl", "upstream ext\n")
            (upstream / "go/private/orchestrion/link").symlink_to("upstream-target")

            _copy_tree(upstream, fork)
            _write(fork / "BUILD.bazel", "fork root\n")
            _write(fork / "MODULE.bazel", "fork module\n")
            _write(fork / "go/private/BUILD.bazel", "fork private build\n")
            _write(fork / "go/tools/builders/builder.go", "package main\nvar Changed = true\n")
            _write(fork / "go/tools/builders/env_test.go", "package main\nvar TestOnly = true\n")
            _write(fork / "go/tools/builders/tool_version.go", "package main\n", mode=0o755)
            (fork / "go/private/orchestrion/link").unlink()
            (fork / "go/private/orchestrion/link").symlink_to("fork-target")
            (fork / "bazel-bin").mkdir()
            _write(fork / "bazel-bin/noise.txt", "noise\n")

            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            profile = self.workspace_profile()

            result_one = self.mod.generate_patch_from_trees(
                upstream_root=upstream,
                fork_root=fork,
                profile=profile,
                output=first / "workspace-runtime.patch",
                manifest=first / "workspace-runtime.MANIFEST.json",
                manifest_context={
                    "upstream_id": "fixture",
                    "rules_go_version": "0.0.0",
                    "upstream_repository": "https://github.com/bazel-contrib/rules_go.git",
                    "upstream_commit": "abc123",
                    "variant": "base",
                },
            )
            result_two = self.mod.generate_patch_from_trees(
                upstream_root=upstream,
                fork_root=fork,
                profile=profile,
                output=second / "workspace-runtime.patch",
                manifest=second / "workspace-runtime.MANIFEST.json",
                manifest_context={
                    "upstream_id": "fixture",
                    "rules_go_version": "0.0.0",
                    "upstream_repository": "https://github.com/bazel-contrib/rules_go.git",
                    "upstream_commit": "abc123",
                    "variant": "base",
                },
            )

            patch_text = (first / "workspace-runtime.patch").read_text(encoding="utf-8")
            manifest_data = json.loads(
                (first / "workspace-runtime.MANIFEST.json").read_text(encoding="utf-8")
            )
            self.assertEqual(result_one.included, result_two.included)
            self.assertEqual(
                (first / "workspace-runtime.patch").read_bytes(),
                (second / "workspace-runtime.patch").read_bytes(),
            )
            self.assertNotIn(b"\r\n", (first / "workspace-runtime.patch").read_bytes())
            self.assertEqual(
                (first / "workspace-runtime.MANIFEST.json").read_bytes(),
                (second / "workspace-runtime.MANIFEST.json").read_bytes(),
            )
            self.assertIn("go/private/BUILD.bazel", patch_text)
            self.assertIn("go/tools/builders/builder.go", patch_text)
            self.assertIn("go/tools/builders/tool_version.go", patch_text)
            self.assertIn("go/private/orchestrion/link", patch_text)
            self.assertNotIn("MODULE.bazel", patch_text)
            self.assertNotIn("env_test.go", patch_text)
            self.assertNotIn("bazel-bin", patch_text)
            self.assertEqual(
                hashlib.sha256((first / "workspace-runtime.patch").read_bytes()).hexdigest(),
                manifest_data["patch_sha256"],
            )
            self.assertEqual(result_one.included, manifest_data["included_paths"])
            self.assertIn("MODULE.bazel", manifest_data["excluded_paths"])

            apply_root = root / "apply"
            _copy_tree(upstream, apply_root)
            subprocess.run(
                [
                    "git",
                    "-C",
                    apply_root.as_posix(),
                    "apply",
                    "--binary",
                    "-p1",
                    (first / "workspace-runtime.patch").as_posix(),
                ],
                check=True,
            )
            self.assertEqual(
                "fork private build\n",
                (apply_root / "go/private/BUILD.bazel").read_text(encoding="utf-8"),
            )
            self.assertEqual(
                "upstream module\n",
                (apply_root / "MODULE.bazel").read_text(encoding="utf-8"),
            )
            self.assertEqual("fork-target", os.readlink(apply_root / "go/private/orchestrion/link"))
            if os.name != "nt":
                self.assertEqual(
                    stat.S_IMODE((apply_root / "go/tools/builders/tool_version.go").stat().st_mode),
                    0o755,
                )

    def test_private_safety_scan_rejects_denylist_hits(self) -> None:
        """Private-safety checks fail without printing full matched content."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            patch = root / "patch.diff"
            manifest = root / "manifest.json"
            profile = root / "profile.json"
            denylist = root / "denylist.txt"
            patch.write_text("contains DENYLIST_SENTINEL\n", encoding="utf-8")
            manifest.write_text('{"private_safe": true}\n', encoding="utf-8")
            profile.write_text('{"name": "profile"}\n', encoding="utf-8")
            denylist.write_text("DENYLIST_SENTINEL\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "private-safe scan failed"):
                self.mod.verify_private_safe(
                    paths=[patch, manifest, profile],
                    public_denylist=denylist,
                    private_blocklist_file=None,
                )

    def test_private_safety_scan_rejects_captured_text(self) -> None:
        """Private-safety checks also cover captured command output."""
        with self.assertRaisesRegex(ValueError, "private-safe scan failed for fixture stderr"):
            self.mod.verify_private_safe_text(
                "fixture stderr",
                "contains DENYLIST_SENTINEL\n",
                ["DENYLIST_SENTINEL"],
            )

    def test_private_safety_scan_rejects_modified_tracked_files(self) -> None:
        """Generator private-safety checks cover locally modified tracked files."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            tracked = root / "tracked.txt"
            blocklist = root / "private-blocklist.txt"
            tracked.write_text("clean\n", encoding="utf-8")
            blocklist.write_text("MODIFIED_TRACKED_SENTINEL\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test User"], cwd=root, check=True)
            subprocess.run(["git", "add", "tracked.txt"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "initial"], cwd=root, check=True)
            tracked.write_text("MODIFIED_TRACKED_SENTINEL\n", encoding="utf-8")

            original_repo_root = self.mod.REPO_ROOT
            self.mod.REPO_ROOT = root
            try:
                with self.assertRaisesRegex(ValueError, "private-safe scan failed"):
                    self.mod.verify_modified_tracked_files_private_safe(
                        public_denylist=None,
                        private_blocklist_file=blocklist,
                    )
            finally:
                self.mod.REPO_ROOT = original_repo_root


class RulesGoProfileVerifierTests(unittest.TestCase):
    """Test profile verification CLI helpers."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the verifier once for all tests."""
        cls.mod = _load_module(
            "verify_rules_go_profiles",
            "tools/dev/verify_rules_go_profiles.py",
        )

    def test_unknown_upstream_fails_before_generation(self) -> None:
        """A requested upstream must exist in the registry."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            registry = root / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "schema_version": 2,
                        "default_upstream": "v0_60_0",
                        "default_variant": "base",
                        "upstreams": {
                            "v0_60_0": {
                                "rules_go_version": "0.60.0",
                                "upstream": {
                                    "repository": "https://github.com/bazel-contrib/rules_go.git",
                                    "commit": "abc123",
                                    "tag": "v0.60.0",
                                    "archive_sha256": "0" * 64,
                                },
                                "patch_root": "third_party/rules_go_orchestrion/patches/v0_60_0",
                                "variants": {
                                    "base": {
                                        "tree_path": "third_party/rgo/v0_60_0/base",
                                        "metadata_path": "third_party/rgo/v0_60_0/base.METADATA.json",
                                        "changed_files_report": "third_party/rgo/v0_60_0/base.CHANGED_FILES.md",
                                        "series": "third_party/rules_go_orchestrion/patches/v0_60_0/base.series",
                                    },
                                },
                            },
                        },
                    }
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "unknown upstream"):
                self.mod.verify_profiles(
                    registry_path=registry,
                    profile_root=root,
                    profile="workspace_runtime",
                    output_dir=root / "out",
                    public_denylist=None,
                    private_blocklist_file=None,
                    upstream="v9_99_9",
                )

    def test_run_bazel_scans_captured_output_before_failure_details(self) -> None:
        """Verifier command wrappers must not leak denylisted command output."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            if os.name == "nt":
                fake_bazel = root / "fake_bazel.bat"
                fake_bazel.write_text("@echo DENYLIST_SENTINEL\r\n", encoding="utf-8")
            else:
                fake_bazel = root / "fake_bazel"
                _write(fake_bazel, "#!/bin/sh\necho DENYLIST_SENTINEL\n", mode=0o755)
            with self.assertRaisesRegex(ValueError, "private-safe scan failed for bazel stdout"):
                self.mod.run_bazel(
                    fake_bazel,
                    root / "bazel-output",
                    root,
                    ["version"],
                    private_safe_patterns=["DENYLIST_SENTINEL"],
                )


if __name__ == "__main__":
    unittest.main()
