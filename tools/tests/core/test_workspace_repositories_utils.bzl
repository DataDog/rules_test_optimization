# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for WORKSPACE Go repository helper specs."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//tools/go:workspace_repositories.bzl",
    "build_workspace_repository_specs_for_tests",
)

def _go_git_specs_test(ctx):
    """Validate the default git repository shape."""
    env = unittest.begin(ctx)
    specs = build_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
    )
    asserts.equals(env, 1, len(specs))
    asserts.equals(env, "git_repository", specs[0]["kind"])
    asserts.equals(env, "datadog-rules-test-optimization-go", specs[0]["attrs"]["name"])
    asserts.equals(env, "modules/go", specs[0]["attrs"]["strip_prefix"])
    asserts.equals(env, {"@io_bazel_rules_go": "@io_bazel_rules_go"}, specs[0]["attrs"]["repo_mapping"])
    return unittest.end(env)

go_git_specs_test = unittest.make(_go_git_specs_test)

def _go_archive_specs_test(ctx):
    """Validate local-archive style repository specs."""
    env = unittest.begin(ctx)
    specs = build_workspace_repository_specs_for_tests(
        rto_commit = "",
        datadog_fetch = "archive",
        rto_archive_url = "file:///tmp/rto.tar.gz",
        rto_archive_sha256 = "1" * 64,
        rto_archive_prefix = "rules_test_optimization-local",
        rto_archive_type = "tar.gz",
    )
    asserts.equals(env, 1, len(specs))
    asserts.equals(env, "http_archive", specs[0]["kind"])
    asserts.equals(env, "datadog-rules-test-optimization-go", specs[0]["attrs"]["name"])
    asserts.equals(env, "rules_test_optimization-local/modules/go", specs[0]["attrs"]["strip_prefix"])
    asserts.equals(env, "file:///tmp/rto.tar.gz", specs[0]["attrs"]["urls"][0])
    asserts.equals(env, "1" * 64, specs[0]["attrs"]["sha256"])
    return unittest.end(env)

go_archive_specs_test = unittest.make(_go_archive_specs_test)

def _go_custom_rules_go_repo_name_test(ctx):
    """Validate custom rules_go repo names are reflected in repo_mapping."""
    env = unittest.begin(ctx)
    specs = build_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        rules_go_repo_name = "custom_rules_go",
    )
    asserts.equals(env, {"@io_bazel_rules_go": "@custom_rules_go"}, specs[0]["attrs"]["repo_mapping"])
    return unittest.end(env)

go_custom_rules_go_repo_name_test = unittest.make(_go_custom_rules_go_repo_name_test)

def _go_invalid_fetch_mode_target_impl(_ctx):
    """Create a target that fails during analysis for an invalid fetch mode."""
    build_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        datadog_fetch = "local",
    )
    return []

go_invalid_fetch_mode_target_rule = rule(implementation = _go_invalid_fetch_mode_target_impl)

def _go_missing_git_commit_target_impl(_ctx):
    """Create a target that fails during analysis for missing git commit input."""
    build_workspace_repository_specs_for_tests(
        rto_commit = "",
    )
    return []

go_missing_git_commit_target_rule = rule(implementation = _go_missing_git_commit_target_impl)

def _go_missing_archive_target_impl(_ctx):
    """Create a target that fails during analysis for missing archive inputs."""
    build_workspace_repository_specs_for_tests(
        rto_commit = "",
        datadog_fetch = "archive",
        rto_archive_url = "file:///tmp/rto.tar.gz",
    )
    return []

go_missing_archive_target_rule = rule(implementation = _go_missing_archive_target_impl)

def _go_existing_repo_target_impl(_ctx):
    """Create a target that fails during analysis for repository collisions."""
    build_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        existing_repositories = {"datadog-rules-test-optimization-go": {}},
    )
    return []

go_existing_repo_target_rule = rule(implementation = _go_existing_repo_target_impl)

def _go_missing_rules_go_repo_target_impl(_ctx):
    """Create a target that fails when rules_go is not declared first."""
    build_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        existing_repositories = {},
    )
    return []

go_missing_rules_go_repo_target_rule = rule(implementation = _go_missing_rules_go_repo_target_impl)

def _go_invalid_fetch_mode_failure_test_impl(ctx):
    """Assert invalid fetch mode failures remain actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "datadog_fetch must be one of")
    return analysistest.end(env)

go_invalid_fetch_mode_failure_test = analysistest.make(
    _go_invalid_fetch_mode_failure_test_impl,
    expect_failure = True,
)

def _go_missing_git_commit_failure_test_impl(ctx):
    """Assert missing git commit failures remain actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "rto_commit is required when datadog_fetch is 'git'")
    return analysistest.end(env)

go_missing_git_commit_failure_test = analysistest.make(
    _go_missing_git_commit_failure_test_impl,
    expect_failure = True,
)

def _go_missing_archive_failure_test_impl(ctx):
    """Assert archive mode reports all missing archive inputs."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "archive fetch mode requires")
    asserts.expect_failure(env, "rto_archive_sha256")
    asserts.expect_failure(env, "rto_archive_prefix")
    return analysistest.end(env)

go_missing_archive_failure_test = analysistest.make(
    _go_missing_archive_failure_test_impl,
    expect_failure = True,
)

def _go_existing_repo_failure_test_impl(ctx):
    """Assert repository collision failures include a correction snippet."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "repository 'datadog-rules-test-optimization-go' is already declared")
    asserts.expect_failure(env, "rules_go_repo_name")
    return analysistest.end(env)

go_existing_repo_failure_test = analysistest.make(
    _go_existing_repo_failure_test_impl,
    expect_failure = True,
)

def _go_missing_rules_go_repo_failure_test_impl(ctx):
    """Assert missing rules_go failures explain declaration ordering."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "rules_go repository 'io_bazel_rules_go' is not declared")
    asserts.expect_failure(env, "Declare rules_go before calling this helper")
    return analysistest.end(env)

go_missing_rules_go_repo_failure_test = analysistest.make(
    _go_missing_rules_go_repo_failure_test_impl,
    expect_failure = True,
)
