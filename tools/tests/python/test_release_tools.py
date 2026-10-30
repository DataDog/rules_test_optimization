# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Offline regression tests for the exact bytes and snippets shipped in releases."""

import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
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

RELEASE = _load_module("build_release", "tools/dev/build_release.py")


@unittest.skipIf(sys.platform == "win32" or not shutil.which("bash"), "requires POSIX symlinks and Bash")
class ReleaseConsumerHarnessTests(unittest.TestCase):
    def test_bep_simulation_copies_outputs_without_mutating_bazel_testlogs(self):
        for mode in ("bzlmod", "workspace"):
            harness = _runfile(f"tools/tests/integration/run_{mode}_go_integration.sh").read_text(encoding="utf-8")
            function = harness.split("simulate_bep_artifact_only_outputs() {", 1)[1].split("\n}\n", 1)[0]
            for use_symlink in (False, True):
                with self.subTest(mode=mode, use_symlink=use_symlink), tempfile.TemporaryDirectory(prefix="rto-bep-copy-") as temporary:
                    root = Path(temporary)
                    workspace = root / "workspace"
                    workspace.mkdir()
                    (workspace / ".topt").mkdir()
                    testlogs = root / "testlogs" if use_symlink else workspace / "bazel-testlogs"
                    output = testlogs / "app/hello_test/test.outputs"
                    output.mkdir(parents=True)
                    payload = output / "payload.json"
                    payload.write_text("{}", encoding="utf-8")
                    payload.chmod(0o444)
                    output.chmod(0o555)
                    if use_symlink:
                        (workspace / "bazel-testlogs").symlink_to(testlogs, target_is_directory=True)
                    bep = root / "fresh.bep.json"
                    bep.write_text(json.dumps({"testResult": {"testActionOutput": [{"name": "test.outputs", "uri": output.as_uri()}]}}) + "\n", encoding="utf-8")
                    try:
                        result = subprocess.run(
                            ["bash", "-c", "set -euo pipefail\nsimulate_bep_artifact_only_outputs() {" + function + '\n}\nsimulate_bep_artifact_only_outputs "$1" "$2"', "bep-copy", str(workspace), str(bep)],
                            env={**os.environ, "PYTHON": sys.executable}, text=True, capture_output=True, check=False,
                        )
                        self.assertEqual(result.returncode, 0, result.stderr)
                        simulated = workspace / ".topt/simulated-local-testlogs"
                        self.assertFalse(simulated.is_symlink())
                        self.assertFalse((simulated / "app/hello_test/test.outputs").exists())
                        self.assertEqual(payload.read_text(encoding="utf-8"), "{}")
                        self.assertEqual(output.stat().st_mode & 0o777, 0o555)
                        self.assertEqual(payload.stat().st_mode & 0o777, 0o444)
                        staged = workspace / ".topt/simulated-remote-artifacts/app/hello_test/test.outputs"
                        self.assertEqual((staged / "payload.json").read_text(encoding="utf-8"), "{}")
                        event = json.loads(bep.read_text(encoding="utf-8"))
                        self.assertEqual(event["testResult"]["testActionOutput"][0]["uri"], staged.resolve().as_uri())
                    finally:
                        output.chmod(0o755)
                        payload.chmod(0o644)


class ReleaseBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rto-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.env = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Release test",
            "GIT_AUTHOR_EMAIL": "release-test@example.invalid",
            "GIT_COMMITTER_NAME": "Release test",
            "GIT_COMMITTER_EMAIL": "release-test@example.invalid",
        }
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            self.env.pop(name, None)
        self.git("init", "--quiet")
        self.write("MODULE.bazel", 'module(name = "datadog-rules-test-optimization", version = "1.3.0")\n')
        for language in RELEASE.LANGUAGES:
            self.write(f"modules/{language}/MODULE.bazel", f'module(name = "datadog-rules-test-optimization-{language}", version = "1.3.0")\nbazel_dep(name = "datadog-rules-test-optimization", version = "1.3.0")\n')
        self.write("CHANGELOG.md", "## [Unreleased]\n\nNot part of this release.\n\n## [1.3.0] - 2026-10-21\n\n### Fixed\n\n- The actual changelog.\n\n## [1.2.0]\n\nOld notes.\n")
        self.write("bazelw", "#!/bin/sh\nexit 0\n")
        (self.repo / "bazelw").chmod(0o755)
        self.commit()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false", *args], env=self.env, text=True).strip()

    def write(self, path, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8", newline="\n")

    def commit(self):
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Release fixture")

    def build(self, name="dist", **kwargs):
        return RELEASE.build(self.repo, "HEAD", self.root / name, **kwargs)

    def test_archive_is_reproducible_and_only_contains_the_commit(self):
        self.write("untracked-secret", "must not ship")
        self.write("bazelw", "uncommitted edit must not ship\n")
        first = self.build("one")
        second = self.build("two")
        self.assertEqual(first, second)
        for path in (self.root / "one").iterdir():
            self.assertEqual(path.read_bytes(), (self.root / "two" / path.name).read_bytes())
        with tarfile.open(self.root / "one" / first["archive"]) as archive:
            names = archive.getnames()
            self.assertNotIn(f'{first["strip_prefix"]}/untracked-secret', names)
            launcher = archive.getmember(f'{first["strip_prefix"]}/bazelw')
            if os.name != "nt":
                self.assertTrue(launcher.mode & 0o111)
            self.assertEqual(archive.extractfile(launcher).read(), b"#!/bin/sh\nexit 0\n")

    def test_all_module_prefixes_exist_in_archive(self):
        metadata = self.build()
        self.assertEqual(len(metadata["modules"]), 7)
        self.assertNotIn("rules_go", metadata)
        with tarfile.open(self.root / "dist" / metadata["archive"]) as archive:
            for prefix in metadata["modules"].values():
                archive.getmember(f"{prefix}/MODULE.bazel")

    def test_archive_ignores_host_line_ending_preferences(self):
        original = self.build("original")
        self.git("config", "core.autocrlf", "true")
        self.git("config", "core.eol", "crlf")
        metadata = self.build()
        self.assertEqual(original, metadata)
        for path in (self.root / "original").iterdir():
            self.assertEqual(path.read_bytes(), (self.root / "dist" / path.name).read_bytes())
        with tarfile.open(self.root / "dist" / metadata["archive"]) as archive:
            launcher = archive.extractfile(f'{metadata["strip_prefix"]}/bazelw')
            self.assertEqual(launcher.read(), b"#!/bin/sh\nexit 0\n")

    def test_checksum_manifest_covers_every_other_asset(self):
        self.build()
        output = self.root / "dist"
        checked = set()
        for line in (output / "SHA256SUMS").read_text().splitlines():
            digest, name = line.split("  ", 1)
            self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), digest)
            checked.add(name)
        self.assertEqual(checked, {path.name for path in output.iterdir()} - {"SHA256SUMS"})
        for name in ("INSTALL.md", "RELEASE_NOTES.md", "release.json", "SHA256SUMS"):
            self.assertNotIn(b"\r\n", (output / name).read_bytes(), name)

    def test_notes_use_only_current_changelog_and_exact_install_pins(self):
        metadata = self.build()
        output = self.root / "dist"
        notes = (output / "RELEASE_NOTES.md").read_text()
        self.assertIn("The actual changelog.", notes)
        self.assertNotIn("Not part of this release.", notes)
        self.assertNotIn("Old notes.", notes)
        self.assertNotIn("git_override(", notes)
        self.assertIn("archive_override(", notes)
        self.assertIn("http_archive(", notes)
        self.assertIn(metadata["url"], notes)
        self.assertIn(metadata["sha256"], notes)
        self.assertIn(metadata["commit"], notes)
        self.assertNotIn("<commit", notes)

    def test_generated_archive_blocks_map_go_only_in_workspace(self):
        metadata = self.build()
        for bzlmod in (False, True):
            for name, prefix in metadata["modules"].items():
                with self.subTest(bzlmod=bzlmod, name=name):
                    block = RELEASE.archive_call(metadata, name, prefix, bzlmod=bzlmod)
                    call = ast.parse(block).body[0].value
                    attrs = {keyword.arg: ast.literal_eval(keyword.value) for keyword in call.keywords}
                    if not bzlmod and name == "datadog-rules-test-optimization-go":
                        self.assertEqual(attrs.get("repo_mapping"), {"@io_bazel_rules_go": "@io_bazel_rules_go"})
                    else:
                        self.assertNotIn("repo_mapping", attrs)

    def test_tag_mismatch_stops_before_creating_output(self):
        with self.assertRaisesRegex(ValueError, "release tag mismatch"):
            self.build(tag="v1.4.0")
        self.assertFalse((self.root / "dist").exists())

    def test_expected_tag_and_annotated_tag_resolve_to_commit(self):
        self.git("tag", "-a", "v1.3.0", "-m", "Release")
        result = RELEASE.build(self.repo, "v1.3.0", self.root / "dist", "v1.3.0")
        self.assertEqual(result["commit"], self.git("rev-parse", "HEAD"))

    def test_existing_output_is_never_overwritten(self):
        self.build()
        with self.assertRaisesRegex(ValueError, "must be empty"):
            self.build()

    def test_companion_version_and_core_dependency_must_match(self):
        path = "modules/go/MODULE.bazel"
        original = (self.repo / path).read_text()
        for index in (0, 1):
            text = original.replace('"1.3.0"', '"9.9.9"', 1) if index == 0 else '"9.9.9"'.join(original.rsplit('"1.3.0"', 1))
            self.write(path, text)
            self.commit()
            with self.assertRaisesRegex(ValueError, "does not match"):
                self.build(f"bad-{index}")

    def test_missing_companion_is_not_a_valid_bundle(self):
        self.git("rm", "modules/ruby/MODULE.bazel")
        self.git("commit", "--quiet", "-m", "Remove companion")
        with self.assertRaises(KeyError):
            self.build()

    def test_missing_changelog_section_is_not_a_release(self):
        self.write("CHANGELOG.md", "## [Unreleased]\n\nPending.\n")
        self.commit()
        with self.assertRaisesRegex(ValueError, "no release notes"):
            self.build()
        self.assertFalse((self.root / "dist").exists())


class ReleaseWorkflowGuardTests(unittest.TestCase):
    """Keep critical publishing guards explicit; actionlint checks YAML syntax."""

    def test_only_tag_pushes_prepare_a_draft_after_every_gate(self):
        workflow = _runfile(".github/workflows/release.yml").read_text()
        draft = workflow.split("\n  release-draft:\n", 1)[1]
        self.assertIn("github.event_name == 'push'", draft)
        self.assertIn("startsWith(github.ref, 'refs/tags/v')", draft)
        for job in ("release-validation", "release-hermetic", "release-shared-validation", "release-docs-links", "release-platform-smoke", "release-archive"):
            self.assertIn(f"      - {job}\n", draft)
        self.assertIn("--draft --verify-tag", draft)
        self.assertIn("sha256sum --check SHA256SUMS", draft)
        self.assertIn('metadata["commit"] == os.environ["GITHUB_SHA"]', draft)
        self.assertIn('gh api "repos/$GH_REPO/commits/', draft)
        self.assertEqual(workflow.count("contents: write"), 1)
        self.assertNotIn("gh release edit", workflow)
        self.assertNotIn("gh release upload", workflow)
        self.assertNotIn("git push", workflow)


if __name__ == "__main__":
    unittest.main()
