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

def _base_git_specs_test(ctx):
    """Validate the default git/git base repository shape."""
    env = unittest.begin(ctx)
    specs = build_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
    )
    asserts.equals(env, "git_repository", specs[0]["kind"])
    asserts.equals(env, "datadog-rules-test-optimization-go", specs[0]["attrs"]["name"])
    asserts.equals(env, "modules/go", specs[0]["attrs"]["strip_prefix"])
    asserts.equals(env, {"@rules_go": "@io_bazel_rules_go"}, specs[0]["attrs"]["repo_mapping"])
    asserts.equals(env, "git_repository", specs[1]["kind"])
    asserts.equals(env, "io_bazel_rules_go", specs[1]["attrs"]["name"])
    asserts.equals(env, "third_party/rules_go_orchestrion_base", specs[1]["attrs"]["strip_prefix"])
    return unittest.end(env)

base_git_specs_test = unittest.make(_base_git_specs_test)

def _complete_git_archive_specs_test(ctx):
    """Validate the git/archive complete repository shape."""
    env = unittest.begin(ctx)
    specs = build_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        rules_go_fetch = "archive",
        rules_go_variant = "complete",
        rto_archive_url = "https://example.test/archive.tar.gz",
        rto_archive_sha256 = "0" * 64,
        rto_archive_prefix = "rules_test_optimization-abc123",
    )
    asserts.equals(env, "git_repository", specs[0]["kind"])
    asserts.equals(env, "http_archive", specs[1]["kind"])
    asserts.equals(env, "io_bazel_rules_go", specs[1]["attrs"]["name"])
    asserts.equals(
        env,
        "rules_test_optimization-abc123/third_party/rules_go_orchestrion_complete",
        specs[1]["attrs"]["strip_prefix"],
    )
    return unittest.end(env)

complete_git_archive_specs_test = unittest.make(_complete_git_archive_specs_test)

def _archive_archive_specs_test(ctx):
    """Validate local-archive style archive/archive repository specs."""
    env = unittest.begin(ctx)
    specs = build_workspace_repository_specs_for_tests(
        rto_commit = "",
        datadog_fetch = "archive",
        rules_go_fetch = "archive",
        rules_go_variant = "base",
        rto_archive_url = "file:///tmp/rto.tar.gz",
        rto_archive_sha256 = "1" * 64,
        rto_archive_prefix = "rules_test_optimization-local",
        rto_archive_type = "tar.gz",
    )
    asserts.equals(env, "http_archive", specs[0]["kind"])
    asserts.equals(env, "rules_test_optimization-local/modules/go", specs[0]["attrs"]["strip_prefix"])
    asserts.equals(env, "http_archive", specs[1]["kind"])
    asserts.equals(env, "rules_test_optimization-local/third_party/rules_go_orchestrion_base", specs[1]["attrs"]["strip_prefix"])
    return unittest.end(env)

archive_archive_specs_test = unittest.make(_archive_archive_specs_test)

def _custom_rules_go_repo_name_test(ctx):
    """Validate custom rules_go repo names are reflected in repo_mapping."""
    env = unittest.begin(ctx)
    specs = build_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        rules_go_repo_name = "custom_rules_go",
    )
    asserts.equals(env, {"@rules_go": "@custom_rules_go"}, specs[0]["attrs"]["repo_mapping"])
    asserts.equals(env, "custom_rules_go", specs[1]["attrs"]["name"])
    return unittest.end(env)

custom_rules_go_repo_name_test = unittest.make(_custom_rules_go_repo_name_test)

def _invalid_variant_target_impl(ctx):
    """Create a target that fails during analysis for an invalid variant."""
    build_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        rules_go_variant = "custom",
    )
    return []

invalid_variant_target_rule = rule(implementation = _invalid_variant_target_impl)

def _missing_archive_target_impl(ctx):
    """Create a target that fails during analysis for missing archive inputs."""
    build_workspace_repository_specs_for_tests(
        rto_commit = "",
        datadog_fetch = "archive",
        rules_go_fetch = "archive",
        rto_archive_url = "file:///tmp/rto.tar.gz",
    )
    return []

missing_archive_target_rule = rule(implementation = _missing_archive_target_impl)

def _existing_repo_target_impl(ctx):
    """Create a target that fails during analysis for repository collisions."""
    build_workspace_repository_specs_for_tests(
        rto_commit = "abc123",
        existing_repositories = {"io_bazel_rules_go": {}},
    )
    return []

existing_repo_target_rule = rule(implementation = _existing_repo_target_impl)

def _invalid_variant_failure_test_impl(ctx):
    """Assert invalid variant failures remain actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "rules_go_variant must be one of")
    return analysistest.end(env)

invalid_variant_failure_test = analysistest.make(
    _invalid_variant_failure_test_impl,
    expect_failure = True,
)

def _missing_archive_failure_test_impl(ctx):
    """Assert archive mode reports all missing archive inputs."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "archive fetch mode requires")
    asserts.expect_failure(env, "rto_archive_sha256")
    asserts.expect_failure(env, "rto_archive_prefix")
    return analysistest.end(env)

missing_archive_failure_test = analysistest.make(
    _missing_archive_failure_test_impl,
    expect_failure = True,
)

def _existing_repo_failure_test_impl(ctx):
    """Assert repository collision failures include a correction snippet."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "repository 'io_bazel_rules_go' is already declared")
    asserts.expect_failure(env, "rules_go_repo_name")
    return analysistest.end(env)

existing_repo_failure_test = analysistest.make(
    _existing_repo_failure_test_impl,
    expect_failure = True,
)
