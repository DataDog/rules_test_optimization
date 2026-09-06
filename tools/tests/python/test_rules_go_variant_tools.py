#!/usr/bin/env python3
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for rules_go Orchestrion variant tooling."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
from types import SimpleNamespace
import unittest
from unittest import mock


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

    # Windows commonly executes Bazel tests in manifest mode without a populated
    # runfiles tree, so resolve declared data dependencies from the manifest too.
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


class RulesGoForkDiffToolTests(unittest.TestCase):
    """Test the rules_go fork diff helper."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the diff helper once for all tests."""
        cls.mod = _load_module(
            "diff_rules_go_fork",
            "tools/dev/diff_rules_go_fork.py",
        )

    def test_compare_trees_ignores_local_bazel_output_paths(self) -> None:
        """Local Bazel output paths are not reported as fork changes."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upstream = root / "upstream"
            fork = root / "fork"
            upstream.mkdir()
            fork.mkdir()
            (upstream / "same.txt").write_text("same\n", encoding="utf-8")
            (fork / "same.txt").write_text("same\n", encoding="utf-8")
            (fork / "bazel-testlogs").mkdir()
            (fork / "bazel-testlogs" / "local.txt").write_text("noise\n", encoding="utf-8")

            self.assertEqual(
                {"modified": [], "added": [], "removed": []},
                self.mod.compare_trees(upstream, fork),
            )

    def test_normalize_no_index_patch_paths_strips_temp_prefixes(self) -> None:
        """Patch export removes temp tree names from git diff --no-index headers."""
        patch = "\n".join(
            [
                "diff --git a/__old__/old.txt b/__new__/new.txt",
                "--- a/__old__/old.txt",
                "+++ b/__new__/new.txt",
                "rename from __old__/old.txt",
                "rename to __new__/new.txt",
                "copy from __old__/copy.txt",
                "copy to __new__/copy.txt",
                "Binary files a/__old__/bin.dat and b/__new__/bin.dat differ",
                "@@ -1 +1 @@",
                "-old",
                "+new",
                "",
            ]
        )

        got = self.mod.normalize_no_index_patch_paths(
            patch,
            old_prefix="__old__/",
            new_prefix="__new__/",
        )

        self.assertNotIn("__old__", got)
        self.assertNotIn("__new__", got)
        self.assertIn("diff --git a/old.txt b/new.txt", got)
        self.assertIn("--- a/old.txt", got)
        self.assertIn("+++ b/new.txt", got)
        self.assertIn("rename from old.txt", got)
        self.assertIn("rename to new.txt", got)
        self.assertIn("copy from copy.txt", got)
        self.assertIn("copy to copy.txt", got)
        self.assertIn("Binary files a/bin.dat and b/bin.dat differ", got)

    def test_registry_metadata_matches_report_schema(self) -> None:
        """Registry selections synthesize the metadata schema used by reports."""
        registry_mod = _load_module(
            "rules_go_fork_registry_for_diff_test",
            "tools/dev/rules_go_fork_registry.py",
        )
        registry = registry_mod.load_registry(
            _runfile("third_party/rules_go_orchestrion/registry.json")
        )
        selection = registry.resolve("v0_60_0", "base")

        metadata = self.mod.metadata_from_selection(registry, selection)

        self.assertEqual(
            "third_party/rgo/v0_60_0/base",
            metadata["fork_path"],
        )
        self.assertEqual(
            "fbbafef6e737fe18d3cdedfff4f8f060ac71d5f3",
            metadata["upstream"]["commit"],
        )
        self.assertEqual(
            "third_party/rgo/v0_60_0/base.CHANGED_FILES.md",
            metadata["generated_report"],
        )

    def test_default_metadata_path_exists(self) -> None:
        """The default metadata path follows the canonical materialized tree."""
        self.assertTrue(self.mod.DEFAULT_METADATA.is_file())
        self.assertEqual(
            "third_party/rgo/v0_60_0/base.METADATA.json",
            self.mod.DEFAULT_METADATA.relative_to(self.mod.REPO_ROOT).as_posix(),
        )

    def test_export_patch_series_with_old_tree_skips_upstream_download(self) -> None:
        """Local old-tree exports do not download upstream rules_go."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old_tree = root / "old"
            new_tree = root / "new"
            patch_root = root / "patches"
            output_dir = patch_root / "base"
            series_file = patch_root / "base.series"
            old_tree.mkdir()
            new_tree.mkdir()
            (old_tree / "example.txt").write_text("old\n", encoding="utf-8")
            (new_tree / "example.txt").write_text("new\n", encoding="utf-8")

            args = SimpleNamespace(
                export_patch_series=True,
                list=False,
                new_tree=str(new_tree),
                old_tree=str(old_tree),
                patch=False,
                patch_name="0001-full-delta.patch",
                patch_output_dir=str(output_dir),
                patch_root=str(patch_root),
                report_path="",
                series_file=str(series_file),
                write_report=False,
            )

            with mock.patch.object(self.mod, "download_upstream_tree") as download:
                status = self.mod.run_diff_command(
                    args,
                    Path("metadata.json"),
                    {"upstream": {"repository": "unused", "commit": "unused"}},
                    new_tree,
                    root / "report.md",
                )

            self.assertEqual(0, status)
            download.assert_not_called()
            self.assertTrue((output_dir / "0001-full-delta.patch").is_file())
            self.assertEqual("base/0001-full-delta.patch\n", series_file.read_text(encoding="utf-8"))


class RulesGoForkRegistryTests(unittest.TestCase):
    """Test the versioned rules_go fork registry."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the registry helper once for all tests."""
        cls.registry_mod = _load_module(
            "rules_go_fork_registry",
            "tools/dev/rules_go_fork_registry.py",
        )

    def test_load_registry_resolves_default_base(self) -> None:
        """The registry resolves the default upstream and base variant."""
        registry_path = _runfile("third_party/rules_go_orchestrion/registry.json")
        registry = self.registry_mod.load_registry(registry_path)
        selection = registry.resolve(upstream="default", variant="base")
        self.assertEqual("v0_60_0", selection.upstream_id)
        self.assertEqual("base", selection.variant)
        self.assertEqual(
            "third_party/rgo/v0_60_0/base",
            selection.tree_path.relative_to(registry.repo_root).as_posix(),
        )
        self.assertEqual(
            "81da046a7e06954de7257d1d3ad20f76a3c79a1a4840b5a0c1e84037f084f64e",
            selection.upstream.archive_sha256,
        )

    def test_load_registry_accepts_base_only_schema_v2(self) -> None:
        """Schema v2 registries contain only the public base variant."""
        registry_path = _runfile("third_party/rules_go_orchestrion/registry.json")
        registry = self.registry_mod.load_registry(registry_path)

        self.assertEqual(2, registry.data["schema_version"])
        self.assertEqual({"base"}, {selection.variant for selection in registry.selections()})

    def test_load_registry_rejects_complete_variant(self) -> None:
        """The removed complete variant fails with the explicit migration message."""
        registry_path = _runfile("third_party/rules_go_orchestrion/registry.json")
        registry = self.registry_mod.load_registry(registry_path)

        with self.assertRaisesRegex(
            ValueError,
            'rules_go_variant "complete" is no longer supported. Use "base".',
        ):
            registry.resolve("v0_60_0", "complete")

    def test_load_registry_rejects_unknown_upstream(self) -> None:
        """Unknown upstream ids fail with a concrete message."""
        registry_path = _runfile("third_party/rules_go_orchestrion/registry.json")
        registry = self.registry_mod.load_registry(registry_path)
        with self.assertRaisesRegex(ValueError, "rules_go upstream"):
            registry.resolve(upstream="v9_99_0", variant="base")

    def test_load_registry_rejects_unknown_variant(self) -> None:
        """Unknown variants fail with a concrete message."""
        registry_path = _runfile("third_party/rules_go_orchestrion/registry.json")
        registry = self.registry_mod.load_registry(registry_path)
        with self.assertRaisesRegex(ValueError, "rules_go variant"):
            registry.resolve(upstream="v0_60_0", variant="custom")

    def test_load_registry_rejects_missing_required_fields(self) -> None:
        """Registry validation catches required-field typos early."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            registry_path = Path(raw_tmp) / "registry.json"
            registry_path.write_text(
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
                                    "commit": "abc",
                                    "tag": "v0.60.0",
                                    "archive_sha256": "0" * 64,
                                },
                                "patch_root": "third_party/rules_go_orchestrion/patches/v0_60_0",
                                "variants": {
                                    "base": {
                                        "tree_path": "third_party/rgo/v0_60_0/base"
                                    }
                                },
                            },
                        },
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "missing fields"):
                self.registry_mod.load_registry(registry_path)

    def test_load_registry_rejects_malformed_archive_sha256(self) -> None:
        """Registry validation requires full lowercase SHA256 archive checksums."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            registry_path = Path(raw_tmp) / "registry.json"
            registry_path.write_text(
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
                                    "commit": "abc",
                                    "tag": "v0.60.0",
                                    "archive_sha256": "not-a-sha",
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
            with self.assertRaisesRegex(ValueError, "archive_sha256"):
                self.registry_mod.load_registry(registry_path)

    def test_load_registry_rejects_non_base_variant_in_schema_v2(self) -> None:
        """Schema v2 rejects any public variant other than base."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            registry_path = Path(raw_tmp) / "registry.json"
            registry_path.write_text(
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
                                    "commit": "abc",
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
                                    "complete": {
                                        "tree_path": "third_party/rules_go_orchestrion_complete",
                                        "metadata_path": "third_party/rules_go_orchestrion_complete.METADATA.json",
                                        "changed_files_report": "third_party/rules_go_orchestrion_complete.CHANGED_FILES.md",
                                        "series": "third_party/rules_go_orchestrion/patches/v0_60_0/complete.series",
                                    },
                                },
                            },
                        },
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                ValueError,
                'rules_go_variant "complete" is no longer supported. Use "base".',
            ):
                self.registry_mod.load_registry(registry_path)

    def test_ignored_tree_path_filters_bazel_output_symlinks(self) -> None:
        """Local output and VCS metadata paths do not become fork differences."""
        self.assertTrue(self.registry_mod.is_ignored_tree_path(Path(".git/config")))
        self.assertTrue(
            self.registry_mod.is_ignored_tree_path(
                Path("tests/core/go_library/visible/.bzr/file-under-version-control")
            )
        )
        self.assertTrue(
            self.registry_mod.is_ignored_tree_path(Path("nested/.hg/store"))
        )
        self.assertTrue(
            self.registry_mod.is_ignored_tree_path(Path("nested/.svn/entries"))
        )
        self.assertTrue(self.registry_mod.is_ignored_tree_path(Path("bazel-bin")))
        self.assertTrue(
            self.registry_mod.is_ignored_tree_path(Path("nested/bazel-out/file"))
        )
        self.assertTrue(
            self.registry_mod.is_ignored_tree_path(
                Path("bazel-rules_go_orchestrion_base")
            )
        )
        self.assertFalse(
            self.registry_mod.is_ignored_tree_path(Path("go/private/context.bzl"))
        )

    def test_generated_starlark_map_contains_canonical_paths(self) -> None:
        """Generated Starlark map preserves canonical public strip prefixes."""
        content = _runfile("tools/go/rules_go_forks.bzl").read_text(encoding="utf-8")
        self.assertIn('RULES_GO_DEFAULT_UPSTREAM = "v0_60_0"', content)
        self.assertIn('"base": "third_party/rgo/v0_60_0/base"', content)
        self.assertIn('"v0_61_1"', content)
        self.assertIn(
            '"base": "third_party/rgo/v0_61_1/base"',
            content,
        )
        self.assertIn('"v0_62_0"', content)
        self.assertIn(
            '"base": "third_party/rgo/v0_62_0/base"',
            content,
        )
        self.assertIn('"v0_63_0"', content)
        self.assertIn(
            '"base": "third_party/rgo/v0_63_0/base"',
            content,
        )
        self.assertNotIn('        "complete":', content)
        self.assertIn('rules_go_variant \\"complete\\" is no longer supported', content)
        self.assertNotIn("rules_go_orchestrion_complete", content)

    def test_generated_go_map_contains_canonical_paths(self) -> None:
        """Generated Go map preserves canonical public strip prefixes."""
        content = _runfile(
            "modules/go/tools/onboardingpins/rules_go_forks_gen.go"
        ).read_text(encoding="utf-8")
        self.assertIn('const DefaultRulesGoUpstream = "v0_60_0"', content)
        self.assertIn('"base": "third_party/rgo/v0_60_0/base"', content)
        self.assertIn('"v0_61_1"', content)
        self.assertIn(
            '"base": "third_party/rgo/v0_61_1/base"',
            content,
        )
        self.assertIn('"v0_62_0"', content)
        self.assertIn(
            '"base": "third_party/rgo/v0_62_0/base"',
            content,
        )
        self.assertIn('"v0_63_0"', content)
        self.assertIn(
            '"base": "third_party/rgo/v0_63_0/base"',
            content,
        )
        self.assertNotIn('"complete":', content)
        self.assertNotIn("rules_go_orchestrion_complete", content)


class RulesGoReleaseArchiveContentsTests(unittest.TestCase):
    """Test release archive coverage for registry-backed fork artifacts."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the release archive checker and registry helper once."""
        cls.archive_mod = _load_module(
            "check_release_archive_contents",
            "tools/dev/check_release_archive_contents.py",
        )
        cls.registry_mod = _load_module(
            "rules_go_fork_registry_for_archive_test",
            "tools/dev/rules_go_fork_registry.py",
        )

    def test_required_archive_paths_include_registry_patches_and_versioned_trees(self) -> None:
        """Archive requirements are derived from every registered upstream."""
        registry = self.registry_mod.load_registry(
            _runfile("third_party/rules_go_orchestrion/registry.json")
        )

        required = self.archive_mod.required_archive_paths(registry)

        self.assertIn("third_party/rules_go_orchestrion/registry.json", required)
        self.assertIn(
            "third_party/rules_go_orchestrion/profiles/workspace_runtime.json",
            required,
        )
        self.assertIn("third_party/rules_go_orchestrion/patches/v0_60_0/base.series", required)
        self.assertIn(
            "third_party/rules_go_orchestrion/patches/v0_60_0/base/0001-full-delta.patch",
            required,
        )
        self.assertIn(
            "third_party/rules_go_orchestrion/patches/v0_61_1/base/0001-full-delta.patch",
            required,
        )
        self.assertIn(
            "third_party/rules_go_orchestrion/patches/v0_62_0/base/0001-full-delta.patch",
            required,
        )
        self.assertIn(
            "third_party/rules_go_orchestrion/patches/v0_63_0/base/0001-full-delta.patch",
            required,
        )
        self.assertIn(
            "third_party/rgo/v0_60_0/base/MODULE.bazel",
            required,
        )
        self.assertIn(
            "third_party/rgo/v0_60_0/base.METADATA.json",
            required,
        )
        self.assertIn(
            "third_party/rgo/v0_60_0/base.CHANGED_FILES.md",
            required,
        )
        self.assertIn(
            "third_party/rgo/v0_61_1/base/MODULE.bazel",
            required,
        )
        self.assertIn(
            "third_party/rgo/v0_61_1/base.METADATA.json",
            required,
        )
        self.assertIn(
            "third_party/rgo/v0_62_0/base/MODULE.bazel",
            required,
        )
        self.assertIn(
            "third_party/rgo/v0_62_0/base.METADATA.json",
            required,
        )
        self.assertIn(
            "third_party/rgo/v0_63_0/base/MODULE.bazel",
            required,
        )
        self.assertIn(
            "third_party/rgo/v0_63_0/base.METADATA.json",
            required,
        )
        self.assertIn("tools/go/rules_go_forks.bzl", required)
        self.assertIn("tools/dev/generate_rules_go_consumer_patch.py", required)
        self.assertIn("tools/dev/private_leak_public_denylist.txt", required)
        self.assertIn("tools/dev/verify_rules_go_profiles.py", required)
        self.assertIn(
            "modules/go/tools/onboardingpins/rules_go_forks_gen.go",
            required,
        )
        self.assertNotIn(
            "third_party/rules_go_orchestrion/patches/v0_61_1/complete/0001-complete-overlay.patch",
            required,
        )
        self.assertNotIn(
            "third_party/rules_go_orchestrion/versions/v0_61_1/complete.METADATA.json",
            required,
        )
        self.assertNotIn("third_party/rules_go_orchestrion_base.METADATA.json", required)

    def test_check_entries_reports_missing_required_paths(self) -> None:
        """Missing required archive paths fail with deterministic output."""
        missing = self.archive_mod.check_entries(
            {"present.txt", "missing.txt"},
            {"present.txt", "extra.txt"},
        )

        self.assertEqual(["missing.txt"], missing)


class RulesGoForkMaterializerTests(unittest.TestCase):
    """Test rules_go fork materialization from patch series."""

    @classmethod
    def setUpClass(cls) -> None:
        """Load the materializer once for all tests."""
        cls.mod = _load_module(
            "materialize_rules_go_fork",
            "tools/dev/materialize_rules_go_fork.py",
        )

    def test_materializer_applies_patch_series(self) -> None:
        """Materializer applies ordered patches and writes expected output."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            upstream = root / "upstream"
            upstream.mkdir()
            (upstream / "file.txt").write_bytes(b"upstream\n")
            patch_root = root / "patches"
            patch_dir = patch_root / "base"
            patch_dir.mkdir(parents=True)
            (patch_root / "base.series").write_text(
                "base/0001-change-file.patch\n",
                encoding="utf-8",
            )
            (patch_dir / "0001-change-file.patch").write_bytes(
                b"\n".join(
                    [
                        b"diff --git a/file.txt b/file.txt",
                        b"--- a/file.txt",
                        b"+++ b/file.txt",
                        b"@@ -1 +1 @@",
                        b"-upstream",
                        b"+patched",
                        b"",
                    ]
                )
            )
            selection = SimpleNamespace(
                upstream_id="fixture",
                variant="base",
                series_path=patch_root / "base.series",
                tree_path=root / "checked-in",
            )
            registry = SimpleNamespace(resolve=lambda upstream_id, variant: selection)
            original_download = self.mod.download_upstream
            self.mod.download_upstream = lambda selected, tempdir: upstream
            try:
                materialized = self.mod.materialize_selection(
                    registry,
                    selection,
                    output_root=root / "out",
                )
            finally:
                self.mod.download_upstream = original_download

            self.assertEqual(
                "patched\n",
                (materialized / "file.txt").read_text(encoding="utf-8"),
            )

    def test_list_upstreams_uses_lf_on_every_platform(self) -> None:
        """Bash consumers never receive a carriage return in an upstream id."""
        self.assertEqual(
            b"v0_60_0\nv0_61_1\n",
            self.mod.render_upstream_ids(["v0_60_0", "v0_61_1"]),
        )

    def test_materializer_rejects_complete_variant(self) -> None:
        """The removed complete variant fails before patch application."""
        selection = SimpleNamespace(
            upstream_id="fixture",
            variant="complete",
        )
        registry = SimpleNamespace()

        with self.assertRaisesRegex(
            ValueError,
            'rules_go_variant "complete" is no longer supported. Use "base".',
        ):
            self.mod.materialize_worktree(registry, selection, Path("/tmp/unused"))

    def test_default_cache_root_uses_env_override_without_home(self) -> None:
        """Cache override resolution does not require a discoverable home directory."""
        with tempfile.TemporaryDirectory() as tmp:
            cache_root = Path(tmp) / "rules-go-cache"
            with mock.patch.dict(
                os.environ,
                {"RULES_GO_ORCHESTRION_CACHE": str(cache_root)},
            ):
                with mock.patch.object(
                    self.mod.Path,
                    "home",
                    side_effect=RuntimeError("Could not determine home directory."),
                ):
                    self.assertEqual(cache_root, self.mod.default_cache_root())

    def test_default_cache_root_falls_back_to_tempdir_without_home(self) -> None:
        """Cache root stays available when Bazel does not expose a home directory."""
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.dict(os.environ, {}, clear=True):
                with mock.patch.object(
                    self.mod.Path,
                    "home",
                    side_effect=RuntimeError("Could not determine home directory."),
                ):
                    with mock.patch.object(self.mod.tempfile, "gettempdir", return_value=tmp):
                        self.assertEqual(
                            Path(tmp) / "rules_go_orchestrion",
                            self.mod.default_cache_root(),
                        )


if __name__ == "__main__":
    unittest.main()
