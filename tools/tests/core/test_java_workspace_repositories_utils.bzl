# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for WORKSPACE Java repository helper specs."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//tools/java:workspace_repositories.bzl",
    "build_java_workspace_repository_specs_for_tests",
)

def _java_git_specs_test(ctx):
    """Validate the default git repository shape."""
    env = unittest.begin(ctx)
    specs = build_java_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
    )
    asserts.equals(env, 1, len(specs))
    asserts.equals(env, "git_repository", specs[0]["kind"])
    asserts.equals(env, "datadog-rules-test-optimization-java", specs[0]["attrs"]["name"])
    asserts.equals(env, "modules/java", specs[0]["attrs"]["strip_prefix"])
    asserts.equals(
        env,
        {
            "@datadog-rules-test-optimization": "@datadog-rules-test-optimization",
            "@rules_java": "@rules_java",
        },
        specs[0]["attrs"]["repo_mapping"],
    )
    return unittest.end(env)

java_git_specs_test = unittest.make(_java_git_specs_test)

def _java_archive_specs_test(ctx):
    """Validate local-archive style repository specs."""
    env = unittest.begin(ctx)
    specs = build_java_workspace_repository_specs_for_tests(
        rto_commit = "",
        datadog_fetch = "archive",
        rto_archive_url = "file:///tmp/rto.tar.gz",
        rto_archive_sha256 = "1" * 64,
        rto_archive_prefix = "rules_test_optimization-local",
        rto_archive_type = "tar.gz",
    )
    asserts.equals(env, 1, len(specs))
    asserts.equals(env, "http_archive", specs[0]["kind"])
    asserts.equals(env, "datadog-rules-test-optimization-java", specs[0]["attrs"]["name"])
    asserts.equals(env, "rules_test_optimization-local/modules/java", specs[0]["attrs"]["strip_prefix"])
    asserts.equals(env, "file:///tmp/rto.tar.gz", specs[0]["attrs"]["urls"][0])
    asserts.equals(env, "1" * 64, specs[0]["attrs"]["sha256"])
    return unittest.end(env)

java_archive_specs_test = unittest.make(_java_archive_specs_test)

def _java_custom_repo_names_test(ctx):
    """Validate custom repository names are reflected in repo_mapping."""
    env = unittest.begin(ctx)
    specs = build_java_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        core_repo_name = "custom_rto_core",
        rules_java_repo_name = "custom_rules_java",
    )
    asserts.equals(
        env,
        {
            "@datadog-rules-test-optimization": "@custom_rto_core",
            "@rules_java": "@custom_rules_java",
        },
        specs[0]["attrs"]["repo_mapping"],
    )
    return unittest.end(env)

java_custom_repo_names_test = unittest.make(_java_custom_repo_names_test)

def _java_invalid_fetch_mode_target_impl(_ctx):
    """Create a target that fails during analysis for an invalid fetch mode."""
    build_java_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        datadog_fetch = "local",
    )
    return []

java_invalid_fetch_mode_target_rule = rule(implementation = _java_invalid_fetch_mode_target_impl)

def _java_missing_git_commit_target_impl(_ctx):
    """Create a target that fails during analysis for missing git commit input."""
    build_java_workspace_repository_specs_for_tests(
        rto_commit = "",
    )
    return []

java_missing_git_commit_target_rule = rule(implementation = _java_missing_git_commit_target_impl)

def _java_missing_archive_target_impl(_ctx):
    """Create a target that fails during analysis for missing archive inputs."""
    build_java_workspace_repository_specs_for_tests(
        rto_commit = "",
        datadog_fetch = "archive",
        rto_archive_url = "file:///tmp/rto.tar.gz",
    )
    return []

java_missing_archive_target_rule = rule(implementation = _java_missing_archive_target_impl)

def _java_existing_repo_target_impl(_ctx):
    """Create a target that fails during analysis for repository collisions."""
    build_java_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        existing_repositories = {
            "datadog-rules-test-optimization": {},
            "datadog-rules-test-optimization-java": {},
            "rules_java": {},
        },
    )
    return []

java_existing_repo_target_rule = rule(implementation = _java_existing_repo_target_impl)

def _java_missing_core_repo_target_impl(_ctx):
    """Create a target that fails when the core Datadog repo is not declared first."""
    build_java_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        existing_repositories = {"rules_java": {}},
    )
    return []

java_missing_core_repo_target_rule = rule(implementation = _java_missing_core_repo_target_impl)

def _java_missing_rules_java_repo_target_impl(_ctx):
    """Create a target that fails when rules_java is not declared first."""
    build_java_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        existing_repositories = {"datadog-rules-test-optimization": {}},
    )
    return []

java_missing_rules_java_repo_target_rule = rule(implementation = _java_missing_rules_java_repo_target_impl)

def _java_invalid_fetch_mode_failure_test_impl(ctx):
    """Assert invalid fetch mode failures remain actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "datadog_fetch must be one of")
    return analysistest.end(env)

java_invalid_fetch_mode_failure_test = analysistest.make(
    _java_invalid_fetch_mode_failure_test_impl,
    expect_failure = True,
)

def _java_missing_git_commit_failure_test_impl(ctx):
    """Assert missing git commit failures remain actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "rto_commit is required when datadog_fetch is 'git'")
    return analysistest.end(env)

java_missing_git_commit_failure_test = analysistest.make(
    _java_missing_git_commit_failure_test_impl,
    expect_failure = True,
)

def _java_missing_archive_failure_test_impl(ctx):
    """Assert archive mode reports all missing archive inputs."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "archive fetch mode requires")
    asserts.expect_failure(env, "rto_archive_sha256")
    asserts.expect_failure(env, "rto_archive_prefix")
    return analysistest.end(env)

java_missing_archive_failure_test = analysistest.make(
    _java_missing_archive_failure_test_impl,
    expect_failure = True,
)

def _java_existing_repo_failure_test_impl(ctx):
    """Assert repository collision failures include a correction snippet."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "repository 'datadog-rules-test-optimization-java' is already declared")
    asserts.expect_failure(env, "rules_java_repo_name")
    return analysistest.end(env)

java_existing_repo_failure_test = analysistest.make(
    _java_existing_repo_failure_test_impl,
    expect_failure = True,
)

def _java_missing_core_repo_failure_test_impl(ctx):
    """Assert missing core repo failures explain declaration ordering."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "core Datadog repository 'datadog-rules-test-optimization' is not declared")
    return analysistest.end(env)

java_missing_core_repo_failure_test = analysistest.make(
    _java_missing_core_repo_failure_test_impl,
    expect_failure = True,
)

def _java_missing_rules_java_repo_failure_test_impl(ctx):
    """Assert missing rules_java failures explain declaration ordering."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "rules_java repository 'rules_java' is not declared")
    return analysistest.end(env)

java_missing_rules_java_repo_failure_test = analysistest.make(
    _java_missing_rules_java_repo_failure_test_impl,
    expect_failure = True,
)
