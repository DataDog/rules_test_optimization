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


def _proto_varint(value: int) -> bytes:
    encoded = bytearray()
    while value > 0x7F:
        encoded.append((value & 0x7F) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def _proto_field(number: int, value: int | bytes | str) -> bytes:
    if isinstance(value, int):
        return _proto_varint(number << 3) + _proto_varint(value)
    if isinstance(value, str):
        value = value.encode("utf-8")
    return _proto_varint((number << 3) | 2) + _proto_varint(len(value)) + value


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
            "go/private/orchestrion/extensions_test.go",
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
        self.assertIn("go/private/orchestrion/extensions_test.go", classification.excluded)

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

    def test_smoke_workspace_wires_hermetic_go_sdk_into_orchestrion(self) -> None:
        """The generated WORKSPACE smoke must not bootstrap from host Go."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            workspace = root / "workspace"
            self.mod.write_smoke_workspace(
                workspace=workspace,
                rules_go_root=root / "rules_go",
                go_version="1.25.0",
                orchestrion_version="v1.12.0",
                dd_trace_go_version="v2.9.1",
            )

            workspace_text = (workspace / "WORKSPACE").read_text(encoding="utf-8")
            build_text = (workspace / "app/BUILD.bazel").read_text(encoding="utf-8")
            self.assertIn('go_sdk_root = "@go_sdk//:ROOT"', workspace_text)
            self.assertIn('go_sdk_version = "1.25.0"', workspace_text)
            self.assertIn('name = "hello_test.topt"', build_text)
            self.assertIn('orchestrion_mode = "test_optimization"', build_text)
            self.assertIn("cgo = True", build_text)
            self.assertTrue((workspace / "app/hello_cgo.go").is_file())

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

    def test_smoke_environment_honors_explicit_bazel_version(self) -> None:
        """Consumer reproductions may select a Bazel version without editing the repo."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            with mock.patch.dict(os.environ, {"USE_BAZEL_VERSION": "8.8.0"}):
                env = self.mod.smoke_bazel_env(Path(raw_tmp) / "output-user-root")

        self.assertEqual("8.8.0", env["USE_BAZEL_VERSION"])

    def test_stdlib_cache_snapshot_accepts_manifested_data_entries(self) -> None:
        """The determinism verifier accepts only sorted manifested data entries."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            _write(root / "11" / "fmt-d", "woven fmt")
            _write(root / "aa" / "log-d", "woven log")
            _write(root / "bb" / "runtime-d", "woven runtime")
            _write(root / "cc" / "runtime-internal-d", "woven runtime internal")
            _write(
                root / ".orchestrion_stdlib_cache_manifest",
                "fmt=11/fmt-d\n"
                "log=aa/log-d\n"
                "runtime=bb/runtime-d\n"
                "runtime/internal/sys=cc/runtime-internal-d\n",
            )

            snapshot = self.mod.canonical_tree_inventory(root)
            self.mod.assert_orchestrion_stdlib_cache(snapshot, Path("profile.patch"))
            self.assertEqual(
                snapshot.manifest,
                "fmt=11/fmt-d\n"
                "log=aa/log-d\n"
                "runtime=bb/runtime-d\n"
                "runtime/internal/sys=cc/runtime-internal-d\n",
            )

    def test_action_snapshot_covers_cache_critical_instrumented_actions(self) -> None:
        """The replay snapshot covers stdlib, helpers, testmain compile, and link."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            workspace = Path(raw_tmp)
            paths = {
                1: {"id": 1, "label": "bazel-out"},
                2: {"id": 2, "label": "arm64-fastbuild", "parentId": 1},
                3: {"id": 3, "label": "bin", "parentId": 2},
                4: {"id": 4, "label": "external", "parentId": 3},
                5: {"id": 5, "label": "io_bazel_rules_go", "parentId": 4},
                6: {"id": 6, "label": "stdlib_", "parentId": 5},
                7: {"id": 7, "label": "synthetic_helpers", "parentId": 5},
                8: {"id": 8, "label": "app", "parentId": 3},
                9: {"id": 9, "label": "hello_test~testmain.a", "parentId": 8},
                10: {"id": 10, "label": "hello_test", "parentId": 8},
                11: {"id": 11, "label": "library.a", "parentId": 8},
            }
            artifacts = [
                {"id": 101, "pathFragmentId": 6},
                {"id": 102, "pathFragmentId": 7},
                {"id": 103, "pathFragmentId": 9},
                {"id": 104, "pathFragmentId": 10},
                {"id": 105, "pathFragmentId": 11},
            ]
            for relative, content in {
                "bazel-out/arm64-fastbuild/bin/external/io_bazel_rules_go/stdlib_/fmt.a": "stdlib",
                "bazel-out/arm64-fastbuild/bin/external/io_bazel_rules_go/synthetic_helpers/testing.a": "helpers",
                "bazel-out/arm64-fastbuild/bin/app/hello_test~testmain.a": "testmain",
                "bazel-out/arm64-fastbuild/bin/app/hello_test": "binary",
                "bazel-out/arm64-fastbuild/bin/app/library.a": "library",
            }.items():
                _write(workspace / relative, content)

            action_keys, outputs = self.mod.action_snapshot_from_aquery(
                {
                    "pathFragments": list(paths.values()),
                    "artifacts": artifacts,
                    "targets": [
                        {"id": 1, "label": "@@io_bazel_rules_go//:stdlib"},
                        {"id": 2, "label": "//app:hello_test"},
                    ],
                    "configuration": [{"id": 1, "mnemonic": "arm64-fastbuild"}],
                    "actions": [
                        {
                            "mnemonic": "GoStdlib",
                            "targetId": 1,
                            "configurationId": 1,
                            "outputIds": [101],
                            "actionKey": "stdlib-key",
                        },
                        {
                            "mnemonic": "GoSyntheticTestmainHelpers",
                            "targetId": 1,
                            "configurationId": 1,
                            "outputIds": [102],
                            "actionKey": "helpers-key",
                        },
                        {
                            "mnemonic": "GoCompilePkg",
                            "targetId": 2,
                            "configurationId": 1,
                            "outputIds": [103],
                            "actionKey": "testmain-key",
                        },
                        {
                            "mnemonic": "GoCompilePkg",
                            "targetId": 2,
                            "configurationId": 1,
                            "outputIds": [105],
                            "actionKey": "ordinary-library-key",
                        },
                        {
                            "mnemonic": "GoLink",
                            "targetId": 2,
                            "configurationId": 1,
                            "outputIds": [104],
                            "actionKey": "link-key",
                        },
                    ],
                },
                workspace=workspace,
                target_label="//app:hello_test",
            )

            self.assertEqual(4, len(action_keys))
            self.assertEqual(
                {"GoCompilePkg", "GoLink", "GoStdlib", "GoSyntheticTestmainHelpers"},
                {identity.split(" ", 1)[0] for identity in action_keys},
            )
            self.assertEqual(6, len(outputs))
            self.assertFalse(any("library.a" in path for path in outputs))

    def test_reproducibility_flags_mirror_cgo_debug_builds(self) -> None:
        """The replay mirrors consumer flags without adding compiler policy."""
        common = self.mod.cgo_reproducibility_flags()
        self.assertIn("--@io_bazel_rules_go//go/config:pure=False", common)
        self.assertIn("--@io_bazel_rules_go//go/config:linkmode=normal", common)
        self.assertIn("--incompatible_strict_action_env", common)
        self.assertIn("--experimental_platform_in_output_dir", common)
        self.assertIn("--copt=-g", common)
        self.assertFalse(any(flag.startswith("--repo_env=CC=") for flag in common))
        self.assertFalse(any(flag.startswith("--linkopt=") for flag in common))
        self.assertNotIn("--copt=-O2", common)

    def test_reproducibility_aquery_requires_requested_cgo_mode(self) -> None:
        """Each isolated replay must expose its requested CGO stdlib mode."""
        environment = [
            {"key": "CGO_ENABLED", "value": "1"},
            {"key": "CGO_CFLAGS", "value": "-O2 -g"},
            {
                "key": "CGO_LDFLAGS",
                "value": "-fuse-ld=lld -Wl,--build-id=md5 -Wl,--threads=4",
            },
        ]
        plain = {
            "mnemonic": "GoStdlib",
            "arguments": ["builder", "stdlib"],
            "environmentVariables": environment,
        }
        instrumented = {
            **plain,
            "arguments": ["builder", "stdlib", "-orchestrion", "orchestrion"],
        }
        self.mod.assert_cgo_aquery_actions(
            {"actions": [plain]}, expected_instrumented=False
        )
        self.mod.assert_cgo_aquery_actions(
            {"actions": [instrumented]}, expected_instrumented=True
        )
        with self.assertRaisesRegex(ValueError, "plain CGO-enabled"):
            self.mod.assert_cgo_aquery_actions(
                {"actions": [instrumented]},
                expected_instrumented=False,
            )

    def test_compact_log_requires_test_optimization_transition(self) -> None:
        """The compact-log gate rejects global or incomplete instrumentation."""
        def action(*arguments: str):
            return self.mod.CompactAction(
                target_label="@@io_bazel_rules_go//:stdlib",
                mnemonic="GoStdlib",
                command_args=arguments,
                environment_variables=(
                    ("CGO_ENABLED", "1"),
                    ("CGO_CFLAGS", "-g"),
                ),
                listed_outputs=("bazel-out/stdlib/gocache",),
                action_key="key",
                actual_outputs=(("bazel-out/stdlib/gocache/net.a", "digest"),),
            )

        valid = action(
            "builder",
            "-orchestrion",
            "external/rules_go_orchestrion_tool/orchestrion",
            "-orchestrion_mode",
            "test_optimization",
        )
        self.mod.assert_cgo_reproducibility_actions(
            [valid], expected_instrumented=True
        )
        with self.assertRaisesRegex(ValueError, "instrumented CGO-enabled"):
            self.mod.assert_cgo_reproducibility_actions(
                [action("builder", "-orchestrion", "tool")],
                expected_instrumented=True,
            )

    def test_reprise_classifier_only_returns_output_changing_actions(self) -> None:
        """The verifier uses the same actionable cells as Reprise's 2x2 table."""

        def action(key: str, output: str):
            return self.mod.CompactAction(
                target_label="//app:test.topt__raw_go_test",
                mnemonic="GoLink",
                command_args=(),
                environment_variables=(),
                listed_outputs=("bazel-out/app/test",),
                action_key=key,
                actual_outputs=(("bazel-out/app/test", output),),
            )

        baseline = action("key-a", "output-a")
        identity = baseline.identity
        self.assertEqual(
            [],
            self.mod.actionable_reproducibility_findings(
                {identity: baseline}, {identity: action("key-a", "output-a")}
            ),
        )
        self.assertEqual(
            [],
            self.mod.actionable_reproducibility_findings(
                {identity: baseline}, {identity: action("key-b", "output-a")}
            ),
        )
        tool_finding = self.mod.actionable_reproducibility_findings(
            {identity: baseline}, {identity: action("key-a", "output-b")}
        )
        self.assertEqual(["tool_nondeterminism"], [item.kind for item in tool_finding])
        input_finding = self.mod.actionable_reproducibility_findings(
            {identity: baseline}, {identity: action("key-b", "output-b")}
        )
        self.assertEqual(["input_driven"], [item.kind for item in input_finding])

        missing_key_finding = self.mod.actionable_reproducibility_findings(
            {identity: action("", "output-a")},
            {identity: action("", "output-b")},
        )
        self.assertEqual(
            ["output_drift_without_action_key"],
            [item.kind for item in missing_key_finding],
        )

    def test_reprise_classifier_rejects_action_set_drift(self) -> None:
        """An action missing from either cold run makes the comparison incomplete."""
        action = self.mod.CompactAction(
            target_label="//app:test.topt__raw_go_test",
            mnemonic="GoLink",
            command_args=(),
            environment_variables=(),
            listed_outputs=("bazel-out/app/test",),
            action_key="",
            actual_outputs=(("bazel-out/app/test", "output"),),
        )

        findings = self.mod.actionable_reproducibility_findings(
            {action.identity: action},
            {},
        )

        self.assertEqual(["action_set_changed"], [item.kind for item in findings])

    def test_reproducibility_action_allows_missing_cache_digest(self) -> None:
        """Cache-off Reprise logs still prove determinism from output digests."""
        action = self.mod.CompactAction(
            target_label="//app:test.topt__raw_go_test",
            mnemonic="GoLink",
            command_args=(),
            environment_variables=(),
            listed_outputs=("bazel-out/app/test",),
            action_key="",
            actual_outputs=(("bazel-out/app/test", "output"),),
        )

        selected = self.mod.select_reproducibility_actions(
            [action],
            raw_target="//app:test.topt__raw_go_test",
        )

        self.assertEqual({action.identity: action}, selected)

    def test_reproducibility_action_requires_output_digests(self) -> None:
        """A selected action without observed bytes cannot prove determinism."""
        action = self.mod.CompactAction(
            target_label="//app:test.topt__raw_go_test",
            mnemonic="GoLink",
            command_args=(),
            environment_variables=(),
            listed_outputs=("bazel-out/app/test",),
            action_key="key",
            actual_outputs=(),
        )
        with self.assertRaisesRegex(ValueError, "has no output digests"):
            self.mod.select_reproducibility_actions(
                [action],
                raw_target="//app:test.topt__raw_go_test",
            )

    def test_action_output_digest_is_independent_of_its_root(self) -> None:
        """Logical paths, modes, and bytes determine a declared output digest."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            first = root / "first"
            second = root / "second"
            _write(first / "nested" / "archive.a", "same bytes")
            _write(second / "nested" / "archive.a", "same bytes")

            first_digest = self.mod.canonical_artifact_digest(first)
            self.assertEqual(first_digest, self.mod.canonical_artifact_digest(second))

            _write(second / "nested" / "archive.a", "different bytes")
            self.assertNotEqual(first_digest, self.mod.canonical_artifact_digest(second))

    def test_stdlib_cache_snapshot_rejects_unmanifested_entries(self) -> None:
        """Action indexes and other unmanifested files fail verification."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            _write(root / "11" / "fmt-d", "woven fmt")
            _write(root / "11" / "fmt-a", "timestamped index")
            _write(
                root / ".orchestrion_stdlib_cache_manifest",
                "fmt=11/fmt-d\n",
            )

            snapshot = self.mod.canonical_tree_inventory(root)
            with self.assertRaisesRegex(ValueError, "unmanifested entries"):
                self.mod.assert_orchestrion_stdlib_cache(snapshot, Path("profile.patch"))

    def test_plain_stdlib_cache_snapshot_must_be_empty(self) -> None:
        """Plain mode may declare the cache TreeArtifact but cannot publish files."""
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            empty = self.mod.canonical_tree_inventory(root)
            self.mod.assert_plain_stdlib_cache(empty, Path("profile.patch"))
            _write(root / "trim.txt", "nondeterministic metadata")
            nonempty = self.mod.canonical_tree_inventory(root)
            with self.assertRaisesRegex(ValueError, "is not empty"):
                self.mod.assert_plain_stdlib_cache(nonempty, Path("profile.patch"))


class CompactExecutionLogTests(unittest.TestCase):
    """Validate the dependency-free projection of Bazel compact logs."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.mod = _load_module(
            "compact_execution_log",
            "tools/dev/compact_execution_log.py",
        )

    def test_tree_artifact_outputs_expand_like_bazel_json_logs(self) -> None:
        """A compact directory output becomes sorted path/digest pairs."""
        digest_a = _proto_field(1, "digest-a")
        digest_b = _proto_field(1, "digest-b")
        file_a = _proto_field(1, "a.a") + _proto_field(2, digest_a)
        file_b = _proto_field(1, "b.a") + _proto_field(2, digest_b)
        directory = (
            _proto_field(1, "bazel-out/stdlib")
            + _proto_field(2, file_b)
            + _proto_field(2, file_a)
        )
        directory_entry = _proto_field(1, 1) + _proto_field(4, directory)
        output = _proto_field(5, 1)
        environment = _proto_field(1, "CGO_ENABLED") + _proto_field(2, "1")
        action_digest = _proto_field(1, "action-key")
        spawn = (
            _proto_field(1, "builder")
            + _proto_field(2, environment)
            + _proto_field(6, output)
            + _proto_field(7, "@@rules_go//:stdlib")
            + _proto_field(8, "GoStdlib")
            + _proto_field(16, action_digest)
        )
        spawn_entry = _proto_field(7, spawn)
        stream = (
            _proto_varint(len(directory_entry))
            + directory_entry
            + _proto_varint(len(spawn_entry))
            + spawn_entry
        )

        actions = list(self.mod._decode_entries(stream))

        self.assertEqual(1, len(actions))
        self.assertEqual("action-key", actions[0].action_key)
        self.assertEqual(("bazel-out/stdlib",), actions[0].listed_outputs)
        self.assertEqual(
            (
                ("bazel-out/stdlib/a.a", "digest-a"),
                ("bazel-out/stdlib/b.a", "digest-b"),
            ),
            actions[0].actual_outputs,
        )

    def test_truncated_entry_reports_an_actionable_error(self) -> None:
        """A declared entry length cannot extend beyond the compact stream."""
        with self.assertRaisesRegex(
            self.mod.CompactExecutionLogError,
            "truncated ExecLogEntry",
        ):
            list(self.mod._decode_entries(_proto_varint(2) + b"\x08"))

    def test_unknown_spawn_output_reports_an_actionable_error(self) -> None:
        """A spawn cannot reference an output absent from the compact stream."""
        output = _proto_field(5, 99)
        spawn = _proto_field(6, output)
        spawn_entry = _proto_field(7, spawn)
        stream = _proto_varint(len(spawn_entry)) + spawn_entry

        with self.assertRaisesRegex(
            self.mod.CompactExecutionLogError,
            "unknown output id 99",
        ):
            list(self.mod._decode_entries(stream))


if __name__ == "__main__":
    unittest.main()
