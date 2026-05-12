"""Tests for the Python Test Optimization bootstrap snippet generator."""

from __future__ import annotations

import contextlib
import io
import importlib.util
from pathlib import Path
import tempfile
import unittest

_MAIN_PATH = Path(__file__).with_name("main.py")
_SPEC = importlib.util.spec_from_file_location("dd_topt_py_bootstrap_main", _MAIN_PATH)
assert _SPEC is not None
main = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
_SPEC.loader.exec_module(main)


def _args(*extra: str) -> main.argparse.Namespace:
    """Parse standard valid bootstrap arguments with optional overrides."""
    base = [
        "--mode=workspace",
        "--service=python-service",
        "--runtime-version=3.12",
        "--runtime-module-path=example.python.app",
        "--rto-commit=abc123",
    ]
    return main.build_parser().parse_args([*base, *extra])


class BootstrapSnippetTest(unittest.TestCase):
    """Validate generated snippets stay safe for consumer onboarding."""

    def test_workspace_snippet_contains_helper(self) -> None:
        """WORKSPACE output wires the public Python helper."""
        args = _args()
        main._validate_args(args)
        snippet = main.render_workspace_snippet(args)
        self.assertIn("datadog_python_test_optimization_workspace_repositories", snippet)
        self.assertIn("test_optimization_sync", snippet)
        self.assertNotRegex(snippet, r"(?m)^        (load|# Declare|datadog_python_test_optimization_workspace_repositories|test_optimization_sync)")

    def test_bzlmod_snippet_contains_bazel_dep(self) -> None:
        """Bzlmod output keeps the module dependency shape visible."""
        args = _args("--mode=bzlmod")
        main._validate_args(args)
        snippet = main.render_bzlmod_snippet(args)
        self.assertIn('bazel_dep(name = "datadog-rules-test-optimization"', snippet)
        self.assertIn('bazel_dep(name = "datadog-rules-test-optimization-python"', snippet)
        self.assertNotRegex(snippet, r"(?m)^        (bazel_dep|archive_override|git_override|test_optimization_sync|use_repo)")

    def test_bzlmod_archive_snippet_emits_sha256_pin(self) -> None:
        """Bzlmod archive output preserves the checksum supplied by the user."""
        args = _args(
            "--mode=bzlmod",
            "--datadog-fetch=archive",
            "--rto-archive-url=https://example.invalid/rules.tar.gz",
            "--rto-archive-sha256=abc123",
            "--rto-archive-prefix=rules_test_optimization-abc123",
        )
        main._validate_args(args)
        snippet = main.render_bzlmod_snippet(args)
        self.assertEqual(2, snippet.count('sha256 = "abc123"'))
        self.assertNotIn('integrity = ""', snippet)

    def test_private_ssh_mode_uses_ssh_remote(self) -> None:
        """Private SSH mode avoids unauthenticated archive fetches."""
        args = _args("--private-repo-fetch=ssh-git")
        main._validate_args(args)
        self.assertIn("ssh://git@github.com/DataDog/rules_test_optimization.git", main.render_workspace_snippet(args))

    def test_archive_mode_requires_archive_inputs(self) -> None:
        """Archive mode fails early when URL, SHA, or prefix are missing."""
        args = _args("--datadog-fetch=archive")
        with self.assertRaisesRegex(main.BootstrapError, "rto-archive-url"):
            main._validate_args(args)

    def test_bazelrc_has_no_forbidden_test_env_or_fetch_salt(self) -> None:
        """Generated .bazelrc keeps secrets and git metadata out of test_env."""
        args = _args()
        snippet = main.render_bazelrc_snippet(args)
        self.assertIn("common:test-optimization --repo_env=DD_API_KEY", snippet)
        self.assertIn("test:test-optimization --remote_download_outputs=all", snippet)
        self.assertNotIn("--test_env=DD_GIT_", snippet)
        self.assertNotIn("--test_env=DD_API_KEY", snippet)
        self.assertNotIn("--test_env=DD_SITE", snippet)
        self.assertNotIn("--test_env=DD_TEST_OPTIMIZATION_AGENT", snippet)
        self.assertNotIn("DD_CIVISIBILITY_AGENTLESS_ENABLED", snippet)
        self.assertNotIn("FETCH_SALT", snippet)

    def test_normal_commands_do_not_include_fetch_salt(self) -> None:
        """Normal commands do not force metadata refreshes."""
        args = _args("--expected-target=//app:test")
        self.assertNotIn("FETCH_SALT", main.render_command_snippet(args))

    def test_default_output_does_not_include_fetch_salt(self) -> None:
        """Default onboarding output excludes the explicit refresh command."""
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            self.assertEqual(0, main.main([
                "--mode=workspace",
                "--service=python-service",
                "--runtime-version=3.12",
                "--runtime-module-path=example.python.app",
                "--rto-commit=abc123",
            ]))
        self.assertNotIn("FETCH_SALT", stdout.getvalue())

    def test_refresh_snippet_is_explicit_and_sync_only(self) -> None:
        """Force refresh output is isolated from normal test and upload commands."""
        args = _args("--print-refresh-snippet")
        snippet = main.render_refresh_snippet(args)
        self.assertIn("FETCH_SALT", snippet)
        self.assertIn("sync --config=test-optimization", snippet)
        self.assertNotIn("test --config", snippet)
        self.assertNotIn("run --config", snippet)

    def test_command_snippet_honors_bazel_command_and_test_targets(self) -> None:
        """Command output uses the requested Bazel wrapper and test targets."""
        args = _args("--bazel-command=./bazelw", "--test-target=//app:explicit", "--expected-target=//app:expected")
        snippet = main.render_command_snippet(args)
        self.assertIn("./bazelw test --config=test-optimization //app:explicit", snippet)
        self.assertNotIn("//app:expected", snippet)

    def test_command_snippet_gates_real_upload_on_validation(self) -> None:
        """Generated commands do not run the real upload after validation failures."""
        args = _args("--expected-target=//app:expected")
        snippet = main.render_command_snippet(args)
        self.assertIn("doctor_status=0", snippet)
        self.assertIn('if [ "$doctor_status" -ne 0 ]; then', snippet)
        self.assertIn("dry_run_status=0", snippet)
        self.assertIn('if [ "$dry_run_status" -ne 0 ]; then', snippet)
        self.assertLess(
            snippet.index("--dry-run --validate-enrichment || dry_run_status=$?"),
            snippet.index('DD_API_KEY="$DD_API_KEY"'),
        )

    def test_command_snippet_falls_back_to_expected_targets(self) -> None:
        """Expected targets are reused for commands when test targets are omitted."""
        args = _args("--expected-target=//app:expected")
        self.assertIn("bazel test --config=test-optimization //app:expected", main.render_command_snippet(args))

    def test_target_snippet_uses_package_local_targets(self) -> None:
        """Target output wires the helper and strict expected targets."""
        args = _args("--expected-target=//app:test")
        snippet = main.render_targets_snippet(args)
        self.assertIn("dd_test_optimization_targets", snippet)
        self.assertIn("//app:test", snippet)
        self.assertTrue(snippet.startswith("load("))
        self.assertIn('    expected_targets = [\n        "//app:test",\n    ],', snippet)

    def test_target_snippet_without_expected_targets_is_validly_indented(self) -> None:
        """Placeholder target output stays valid Starlark indentation."""
        args = _args()
        snippet = main.render_targets_snippet(args)
        self.assertTrue(snippet.startswith("load("))
        self.assertIn("    # Add only instrumented test targets", snippet)
        self.assertIn("    expected_targets = [],", snippet)

    def test_managed_pytest_snippet_lists_consumer_dependencies(self) -> None:
        """Managed pytest examples remind consumers to provide pytest and ddtrace."""
        args = _args("--runner-mode=managed_pytest")
        snippet = main.render_test_snippet(args)
        self.assertIn('requirement("ddtrace")', snippet)
        self.assertIn('requirement("pytest")', snippet)

    def test_consumer_runner_snippet_contains_module_identifier(self) -> None:
        """Consumer runner examples preserve module selection guidance."""
        args = _args(
            "--runner-mode=consumer_runner",
            "--module-identifier=example.python.app",
            "--py-test-rule-load-label=//tools:python.bzl",
            "--py-test-rule-symbol=dd_py_test",
        )
        snippet = main.render_test_snippet(args)
        self.assertIn('runner_mode = "consumer_runner"', snippet)
        self.assertIn('module_identifier = "example.python.app"', snippet)
        self.assertIn("py_test_rule = dd_py_test", snippet)

    def test_write_modes_are_idempotent_and_preserve_user_content(self) -> None:
        """Managed block writes preserve unmanaged content and replace only generated content."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".bazelrc"
            path.write_text("# user content\n", encoding="utf-8")
            args = _args("--write-bazelrc", f"--bazelrc-path={path}")
            main._validate_args(args)
            main.write_outputs(args)
            first = path.read_text(encoding="utf-8")
            main.write_outputs(args)
            second = path.read_text(encoding="utf-8")
            self.assertEqual(first, second)
            self.assertIn("# user content", second)
            self.assertEqual(1, second.count(main.BEGIN_MARKER))

    def test_write_targets_creates_parent_directories(self) -> None:
        """Target write mode creates lightweight packages on demand."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "tools" / "test_optimization" / "BUILD.bazel"
            args = _args("--write-targets", f"--targets-build-path={path}")
            main._validate_args(args)
            main.write_outputs(args)
            self.assertTrue(path.exists())
            self.assertIn("dd_test_optimization_targets", path.read_text(encoding="utf-8"))

    def test_write_targets_fails_on_unmanaged_target_collision(self) -> None:
        """Target write mode does not silently shadow existing user targets."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "BUILD.bazel"
            path.write_text('some_rule(name = "dd_upload_payloads")\n', encoding="utf-8")
            args = _args("--write-targets", f"--targets-build-path={path}")
            main._validate_args(args)
            with self.assertRaisesRegex(main.BootstrapError, "unmanaged target name"):
                main.write_outputs(args)


if __name__ == "__main__":
    unittest.main()
