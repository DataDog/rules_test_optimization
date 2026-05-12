# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for WORKSPACE Python repository helper specs."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//tools/python:workspace_repositories.bzl",
    "build_python_workspace_repository_specs_for_tests",
)

def _python_git_specs_test(ctx):
    """Validate the default git repository shape."""
    env = unittest.begin(ctx)
    specs = build_python_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
    )
    asserts.equals(env, 1, len(specs))
    asserts.equals(env, "git_repository", specs[0]["kind"])
    asserts.equals(env, "datadog-rules-test-optimization-python", specs[0]["attrs"]["name"])
    asserts.equals(env, "modules/python", specs[0]["attrs"]["strip_prefix"])
    asserts.equals(env, {"@rules_python": "@rules_python"}, specs[0]["attrs"]["repo_mapping"])
    return unittest.end(env)

python_git_specs_test = unittest.make(_python_git_specs_test)

def _python_archive_specs_test(ctx):
    """Validate local-archive style repository specs."""
    env = unittest.begin(ctx)
    specs = build_python_workspace_repository_specs_for_tests(
        rto_commit = "",
        datadog_fetch = "archive",
        rto_archive_url = "file:///tmp/rto.tar.gz",
        rto_archive_sha256 = "1" * 64,
        rto_archive_prefix = "rules_test_optimization-local",
        rto_archive_type = "tar.gz",
    )
    asserts.equals(env, 1, len(specs))
    asserts.equals(env, "http_archive", specs[0]["kind"])
    asserts.equals(env, "datadog-rules-test-optimization-python", specs[0]["attrs"]["name"])
    asserts.equals(env, "rules_test_optimization-local/modules/python", specs[0]["attrs"]["strip_prefix"])
    asserts.equals(env, "file:///tmp/rto.tar.gz", specs[0]["attrs"]["urls"][0])
    asserts.equals(env, "1" * 64, specs[0]["attrs"]["sha256"])
    return unittest.end(env)

python_archive_specs_test = unittest.make(_python_archive_specs_test)

def _python_custom_rules_python_repo_name_test(ctx):
    """Validate custom rules_python repo names are reflected in repo_mapping."""
    env = unittest.begin(ctx)
    specs = build_python_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        rules_python_repo_name = "custom_rules_python",
    )
    asserts.equals(env, {"@rules_python": "@custom_rules_python"}, specs[0]["attrs"]["repo_mapping"])
    return unittest.end(env)

python_custom_rules_python_repo_name_test = unittest.make(_python_custom_rules_python_repo_name_test)

def _python_invalid_fetch_mode_target_impl(_ctx):
    """Create a target that fails during analysis for an invalid fetch mode."""
    build_python_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        datadog_fetch = "local",
    )
    return []

python_invalid_fetch_mode_target_rule = rule(implementation = _python_invalid_fetch_mode_target_impl)

def _python_missing_git_commit_target_impl(_ctx):
    """Create a target that fails during analysis for missing git commit input."""
    build_python_workspace_repository_specs_for_tests(
        rto_commit = "",
    )
    return []

python_missing_git_commit_target_rule = rule(implementation = _python_missing_git_commit_target_impl)

def _python_missing_archive_target_impl(_ctx):
    """Create a target that fails during analysis for missing archive inputs."""
    build_python_workspace_repository_specs_for_tests(
        rto_commit = "",
        datadog_fetch = "archive",
        rto_archive_url = "file:///tmp/rto.tar.gz",
    )
    return []

python_missing_archive_target_rule = rule(implementation = _python_missing_archive_target_impl)

def _python_existing_repo_target_impl(_ctx):
    """Create a target that fails during analysis for repository collisions."""
    build_python_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        existing_repositories = {"datadog-rules-test-optimization-python": {}},
    )
    return []

python_existing_repo_target_rule = rule(implementation = _python_existing_repo_target_impl)

def _python_missing_rules_python_repo_target_impl(_ctx):
    """Create a target that fails when rules_python is not declared first."""
    build_python_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        existing_repositories = {},
    )
    return []

python_missing_rules_python_repo_target_rule = rule(implementation = _python_missing_rules_python_repo_target_impl)

def _python_invalid_fetch_mode_failure_test_impl(ctx):
    """Assert invalid fetch mode failures remain actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "datadog_fetch must be one of")
    return analysistest.end(env)

python_invalid_fetch_mode_failure_test = analysistest.make(
    _python_invalid_fetch_mode_failure_test_impl,
    expect_failure = True,
)

def _python_missing_git_commit_failure_test_impl(ctx):
    """Assert missing git commit failures remain actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "rto_commit is required when datadog_fetch is 'git'")
    return analysistest.end(env)

python_missing_git_commit_failure_test = analysistest.make(
    _python_missing_git_commit_failure_test_impl,
    expect_failure = True,
)

def _python_missing_archive_failure_test_impl(ctx):
    """Assert archive mode reports all missing archive inputs."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "archive fetch mode requires")
    asserts.expect_failure(env, "rto_archive_sha256")
    asserts.expect_failure(env, "rto_archive_prefix")
    return analysistest.end(env)

python_missing_archive_failure_test = analysistest.make(
    _python_missing_archive_failure_test_impl,
    expect_failure = True,
)

def _python_existing_repo_failure_test_impl(ctx):
    """Assert repository collision failures include a correction snippet."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "repository 'datadog-rules-test-optimization-python' is already declared")
    asserts.expect_failure(env, "rules_python_repo_name")
    return analysistest.end(env)

python_existing_repo_failure_test = analysistest.make(
    _python_existing_repo_failure_test_impl,
    expect_failure = True,
)

def _python_missing_rules_python_repo_failure_test_impl(ctx):
    """Assert missing rules_python failures explain declaration ordering."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "rules_python repository 'rules_python' is not declared")
    asserts.expect_failure(env, "Declare rules_python before calling this helper")
    return analysistest.end(env)

python_missing_rules_python_repo_failure_test = analysistest.make(
    _python_missing_rules_python_repo_failure_test_impl,
    expect_failure = True,
)
