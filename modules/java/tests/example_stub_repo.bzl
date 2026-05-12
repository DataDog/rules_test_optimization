# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Thin aliases to shared test stubs in the core module."""

load(
    "@datadog-rules-test-optimization//tools/tests:example_stub_repo.bzl",
    _example_stub_repo = "example_stub_repo",
    _example_stub_repo_extension = "example_stub_repo_extension",
    _render_stub_build_for_tests = "render_stub_build_for_tests",
)

example_stub_repo = _example_stub_repo
example_stub_repo_extension = _example_stub_repo_extension
render_stub_build_for_tests = _render_stub_build_for_tests
