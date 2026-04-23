#!/usr/bin/env python3
"""Unit tests for the rules_go optional patch-bundle tooling."""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
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


def _manifest_key_variants(rel_path: str, test_workspace: str) -> list[str]:
    """Return the exact manifest keys that should resolve a requested runfile."""
    keys = [rel_path]
    if test_workspace:
        keys.insert(0, f"{test_workspace}/{rel_path}")
    return keys


def _manifest_key_matches(entry_key: str, requested_key: str) -> bool:
    """Accept exact manifest keys plus manifest-prefix variants used on Windows."""
    if entry_key == requested_key:
        return True
    if len(entry_key) <= len(requested_key):
        return False
    if not entry_key.endswith(requested_key):
        return False
    separator = entry_key[-len(requested_key) - 1]
    return separator in ("/", "\\")


def _runfile(rel_path: str) -> Path:
    """Resolve one runfile path for Bazel and non-Bazel execution."""
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
            keys = _manifest_key_variants(rel_path, test_workspace)
            with manifest.open("r", encoding="utf-8") as handle:
                for idx, line in enumerate(handle):
                    line = line.rstrip("\r\n")
                    if not line:
                        continue
                    key, sep, value = line.partition(" ")
                    if idx == 0:
                        key = key.lstrip("\ufeff")
                    if not sep or not value:
                        continue
                    if any(_manifest_key_matches(key, requested_key) for requested_key in keys):
                        return Path(value)

    raise FileNotFoundError(f"runfile not found: {rel_path}")


def _load_module(name: str, rel_path: str) -> types.ModuleType:
    """Load one Python module from a runfile path."""
    path = _runfile(rel_path)
    spec = importlib.util.spec_from_file_location(name, str(path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module spec for {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class RulesGoPatchToolTests(unittest.TestCase):
    """Tests for manifest handling, bundle export, and exact-tree helpers."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the shared helper and the bundle-export CLI once."""
        cls.lib = _load_module(
            "rules_go_patch_series_lib",
            "tools/dev/rules_go_patch_series_lib.py",
        )
        cls.export_bundle = _load_module(
            "export_rules_go_patch_bundle_mod",
            "tools/dev/export_rules_go_patch_bundle.py",
        )
        manifest_path = _runfile("third_party/rules_go_patch_series.json")

        def fake_git_runner(*args: str, capture_output: bool = True):
            """Keep shared contract tests independent from checkout history depth."""
            if args[:2] == ("merge-base", "--is-ancestor"):
                return subprocess.CompletedProcess(["git", *args], 0, stdout="", stderr="")
            if args[0] == "for-each-ref":
                return subprocess.CompletedProcess(
                    ["git", *args],
                    0,
                    stdout="refs/heads/feat/rules-go-optional-patch-bundles\n",
                    stderr="",
                )
            return subprocess.CompletedProcess(["git", *args], 0, stdout="", stderr="")

        cls.manifest = cls.lib.load_manifest(manifest_path, git_runner=fake_git_runner)

    @contextlib.contextmanager
    def _export_bundle_with_fake_manifest(self):
        """Run export-bundle assertions without depending on checkout git history or runfiles layout."""
        original_load_manifest = self.export_bundle.load_manifest
        with tempfile.TemporaryDirectory() as tmp:
            patch_dir = Path(tmp) / "rules_go_patches"
            patch_dir.mkdir(parents=True)
            for filename in self.lib.EXPECTED_PATCH_FILENAMES:
                shutil.copy2(
                    _runfile(f"third_party/rules_go_patches/{filename}"),
                    patch_dir / filename,
                )

            manifest = copy.deepcopy(self.manifest)
            # Use an absolute source directory so bundle export behaves the same
            # under Windows manifest-based runfiles and POSIX runfiles trees.
            manifest["patch_dir"] = str(patch_dir)
            self.export_bundle.load_manifest = (
                lambda _path, *, validate_commit_reachability=True: manifest
            )
            try:
                yield
            finally:
                self.export_bundle.load_manifest = original_load_manifest

    def test_manifest_exposes_expected_split_contract(self) -> None:
        """Validate the manifest points at the new base, patch, and overlay locations."""
        self.assertEqual("third_party/rules_go_orchestrion", self.manifest["subtree_path"])
        self.assertEqual("third_party/rules_go_patches", self.manifest["patch_dir"])
        self.assertEqual("tools/tests/rules_go_patch_regressions", self.manifest["proof_overlay_dir"])
        self.assertEqual([], self.manifest["bundles"]["none"])
        self.assertEqual(
            self.lib.EXPECTED_PATCH_FILENAMES,
            tuple(self.manifest["bundles"]["dd_source_full"]),
        )

    def test_bundle_selection_uses_canonical_order(self) -> None:
        """Validate bundle selection returns the expected manifest order."""
        selection = self.lib.resolve_patch_selection(self.manifest, bundle_name="dd_source_full")
        self.assertEqual(
            list(self.lib.EXPECTED_PATCH_FILENAMES),
            [patch["filename"] for patch in selection],
        )

    def test_subset_selection_rejects_missing_prerequisites(self) -> None:
        """Validate explicit patch subsets fail when prerequisites are omitted."""
        with self.assertRaisesRegex(self.lib.PatchSeriesError, "missing patch prerequisites"):
            self.lib.resolve_patch_selection(
                self.manifest,
                patch_filenames=[
                    "0016-lazy-cc-toolchain-resolution.patch",
                ],
            )

    def test_subset_selection_rejects_unknown_patches(self) -> None:
        """Validate explicit patch subsets fail on unknown patch filenames."""
        with self.assertRaisesRegex(self.lib.PatchSeriesError, "unknown patch selection"):
            self.lib.resolve_patch_selection(
                self.manifest,
                patch_filenames=["not-a-real.patch"],
            )

    def test_manifest_key_matching_accepts_windows_style_prefixes(self) -> None:
        """Validate manifest lookup tolerates BOM-prefixed and path-prefixed keys."""
        requested = "tools/dev/rules_go_patch_series_lib.py"
        self.assertTrue(_manifest_key_matches(requested, requested))
        self.assertTrue(_manifest_key_matches(f"_main/{requested}", requested))
        self.assertTrue(_manifest_key_matches(f"_main\\{requested}", requested))
        self.assertFalse(_manifest_key_matches(f"_main{requested}", requested))

    def test_manifest_rejects_missing_commits(self) -> None:
        """Validate manifest loading fails when a referenced git commit does not exist."""
        broken_manifest = copy.deepcopy(self.manifest)
        broken_manifest["base_commit"] = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = Path(tmp) / "rules_go_patch_series.json"
            manifest_path.write_text(
                json.dumps(broken_manifest, indent=2) + "\n",
                encoding="utf-8",
            )

            def fake_git_runner(*args: str, capture_output: bool = True):
                if args[:3] == ("cat-file", "-e", f"{broken_manifest['base_commit']}^{{commit}}"):
                    raise subprocess.CalledProcessError(128, ["git", *args])
                return subprocess.CompletedProcess(["git", *args], 0, stdout="", stderr="")

            with self.assertRaisesRegex(self.lib.PatchSeriesError, "does not exist"):
                self.lib.load_manifest(manifest_path, git_runner=fake_git_runner)

    def test_manifest_rejects_unreachable_commits(self) -> None:
        """Validate manifest loading fails when a commit exists but is detached from history."""
        broken_manifest = copy.deepcopy(self.manifest)
        broken_manifest["patches"][0]["commit"] = "1111111111111111111111111111111111111111"
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = Path(tmp) / "rules_go_patch_series.json"
            manifest_path.write_text(
                json.dumps(broken_manifest, indent=2) + "\n",
                encoding="utf-8",
            )

            def fake_git_runner(*args: str, capture_output: bool = True):
                if args[:2] == ("cat-file", "-e"):
                    return subprocess.CompletedProcess(["git", *args], 0, stdout="", stderr="")
                if args[:2] == ("merge-base", "--is-ancestor"):
                    raise subprocess.CalledProcessError(1, ["git", *args])
                if args[0] == "for-each-ref":
                    return subprocess.CompletedProcess(["git", *args], 0, stdout="", stderr="")
                return subprocess.CompletedProcess(["git", *args], 0, stdout="", stderr="")

            with self.assertRaisesRegex(self.lib.PatchSeriesError, "not reachable"):
                self.lib.load_manifest(manifest_path, git_runner=fake_git_runner)

    def test_manifest_can_skip_commit_reachability_for_copy_only_flows(self) -> None:
        """Validate copy-only tools can load the manifest without local git history."""
        broken_manifest = copy.deepcopy(self.manifest)
        broken_manifest["patches"][0]["commit"] = "1111111111111111111111111111111111111111"
        with tempfile.TemporaryDirectory() as tmp:
            manifest_path = Path(tmp) / "rules_go_patch_series.json"
            manifest_path.write_text(
                json.dumps(broken_manifest, indent=2) + "\n",
                encoding="utf-8",
            )

            def fake_git_runner(*args: str, capture_output: bool = True):
                if args[:2] == ("cat-file", "-e"):
                    return subprocess.CompletedProcess(["git", *args], 0, stdout="", stderr="")
                if args[:2] == ("merge-base", "--is-ancestor"):
                    raise subprocess.CalledProcessError(1, ["git", *args])
                if args[0] == "for-each-ref":
                    return subprocess.CompletedProcess(["git", *args], 0, stdout="", stderr="")
                return subprocess.CompletedProcess(["git", *args], 0, stdout="", stderr="")

            loaded = self.lib.load_manifest(
                manifest_path,
                git_runner=fake_git_runner,
                validate_commit_reachability=False,
            )
            self.assertEqual(
                "1111111111111111111111111111111111111111",
                loaded["patches"][0]["commit"],
            )

    def test_export_bundle_writes_explicit_build_file_and_labels(self) -> None:
        """Validate bundle export writes the expected BUILD file and label list."""
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "third_party" / "rules_go_patches"
            stdout = io.StringIO()
            with self._export_bundle_with_fake_manifest(), contextlib.redirect_stdout(stdout):
                rc = self.export_bundle.main(
                    [
                        "--patch",
                        "0002-Include-logs-for-test-reports-regardless-of-failure-.patch",
                        "--patch",
                        "0009-Use-LLVM-for-all-linking.patch",
                        "--destination",
                        str(destination),
                    ]
                )
            self.assertEqual(0, rc)

            build_file = (destination / "BUILD.bazel").read_text(encoding="utf-8")
            self.assertIn('package(default_visibility = ["//visibility:public"])', build_file)
            self.assertIn(
                '"0002-Include-logs-for-test-reports-regardless-of-failure-.patch"',
                build_file,
            )
            self.assertIn('"0009-Use-LLVM-for-all-linking.patch"', build_file)
            self.assertTrue(
                (destination / "0002-Include-logs-for-test-reports-regardless-of-failure-.patch").exists()
            )
            self.assertTrue((destination / "0009-Use-LLVM-for-all-linking.patch").exists())
            self.assertEqual(
                [
                    "//third_party/rules_go_patches:0002-Include-logs-for-test-reports-regardless-of-failure-.patch",
                    "//third_party/rules_go_patches:0009-Use-LLVM-for-all-linking.patch",
                ],
                stdout.getvalue().strip().splitlines(),
            )

    def test_export_bundle_skips_commit_reachability_validation(self) -> None:
        """Validate bundle export still works when local git history is unavailable."""
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "third_party" / "rules_go_patches"
            manifest_calls: list[bool] = []
            original_load_manifest = self.export_bundle.load_manifest

            def fake_load_manifest(_path, *, validate_commit_reachability=True):
                manifest_calls.append(validate_commit_reachability)
                manifest = copy.deepcopy(self.manifest)
                manifest["patch_dir"] = str(_runfile("third_party/rules_go_patches"))
                return manifest

            stdout = io.StringIO()
            self.export_bundle.load_manifest = fake_load_manifest
            try:
                with contextlib.redirect_stdout(stdout):
                    rc = self.export_bundle.main(
                        [
                            "--bundle",
                            "dd_source_full",
                            "--destination",
                            str(destination),
                        ]
                    )
            finally:
                self.export_bundle.load_manifest = original_load_manifest

            self.assertEqual([False], manifest_calls)
            self.assertEqual(0, rc)
            self.assertTrue((destination / "BUILD.bazel").exists())
            self.assertEqual(
                len(self.lib.EXPECTED_PATCH_FILENAMES),
                len(stdout.getvalue().strip().splitlines()),
            )

    def test_export_bundle_rejects_unmanaged_destination_without_force(self) -> None:
        """Validate bundle export fails if the destination already exists unmanaged."""
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "third_party" / "rules_go_patches"
            destination.mkdir(parents=True)
            (destination / "leftover.txt").write_text("keep me", encoding="utf-8")

            stderr = io.StringIO()
            with self._export_bundle_with_fake_manifest(), contextlib.redirect_stderr(stderr):
                rc = self.export_bundle.main(
                    [
                        "--patch",
                        "0002-Include-logs-for-test-reports-regardless-of-failure-.patch",
                        "--destination",
                        str(destination),
                    ]
                )
            self.assertEqual(1, rc)
            self.assertIn("destination already exists", stderr.getvalue())

    def test_tree_manifest_round_trip_tracks_files_and_symlinks(self) -> None:
        """Validate tree manifests capture regular files and, when available, symlinks without directories."""
        with tempfile.TemporaryDirectory() as tmp:
            tree_root = Path(tmp) / "tree"
            tree_root.mkdir()
            file_path = tree_root / "bin" / "tool.sh"
            file_path.parent.mkdir(parents=True)
            file_path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            file_path.chmod(0o755)
            symlink_path = tree_root / "bin" / "tool-link"
            symlink_supported = True
            try:
                os.symlink("tool.sh", symlink_path)
            except (NotImplementedError, OSError):
                # Windows Bazel runners do not always allow non-admin symlink
                # creation, so keep file-manifest coverage portable and only
                # assert symlink serialization when the platform supports it.
                symlink_supported = False

            entries = self.lib.tree_entries(tree_root)
            manifest_path = Path(tmp) / "tree_manifest.json"
            self.lib.write_tree_manifest(manifest_path, entries)
            loaded = self.lib.load_tree_manifest(manifest_path)

            self.assertIn("bin/tool.sh", loaded)
            self.assertNotIn("bin", loaded)
            self.assertEqual("file", loaded["bin/tool.sh"]["kind"])
            expected_executable = bool(file_path.stat().st_mode & stat.S_IXUSR)
            self.assertEqual(expected_executable, loaded["bin/tool.sh"]["executable"])
            if symlink_supported:
                self.assertIn("bin/tool-link", loaded)
                self.assertEqual("symlink", loaded["bin/tool-link"]["kind"])
                self.assertEqual("tool.sh", loaded["bin/tool-link"]["target"])


if __name__ == "__main__":
    unittest.main()
