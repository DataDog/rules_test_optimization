"""Thin aliases to shared test stubs in the core module.

Keeping a single implementation in `@datadog-rules-test-optimization//tools/tests`
avoids drift between core and companion test fixture behavior.
"""

load(
    "@datadog-rules-test-optimization//tools/tests:example_stub_repo.bzl",
    _example_stub_repo = "example_stub_repo",
    _example_stub_repo_extension = "example_stub_repo_extension",
    _render_stub_build_for_tests = "render_stub_build_for_tests",
)

example_stub_repo = _example_stub_repo
example_stub_repo_extension = _example_stub_repo_extension
render_stub_build_for_tests = _render_stub_build_for_tests
