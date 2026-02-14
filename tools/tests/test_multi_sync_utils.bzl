# Unit tests for multi-service extension helper utilities.
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//tools:test_optimization_multi_sync.bzl",
    "compute_multi_repo_names_for_tests",
    "compute_multi_service_keys_for_tests",
    "render_multi_aggregate_bzl_for_tests",
)

def _compute_service_keys_dedups_collisions_test(ctx):
    """Validate sanitized-key collision deduping for multi-service inputs."""
    env = unittest.begin(ctx)
    keys = compute_multi_service_keys_for_tests([
        "go-service",
        "go_service",
        "Team.API",
    ])
    asserts.equals(env, ["go_service", "go_service_2", "team_api"], keys)
    return unittest.end(env)

def _compute_repo_names_test(ctx):
    """Validate deterministic per-service repository naming."""
    env = unittest.begin(ctx)
    repo_names = compute_multi_repo_names_for_tests(
        "test_optimization_data",
        ["go_service", "go_service_2"],
    )
    asserts.equals(
        env,
        ["test_optimization_data_go_service", "test_optimization_data_go_service_2"],
        repo_names,
    )
    return unittest.end(env)

def _render_multi_aggregate_bzl_contains_expected_targets_test(ctx):
    """Validate generated aggregate.bzl includes expected exports/targets."""
    env = unittest.begin(ctx)
    content = render_multi_aggregate_bzl_for_tests(
        ["go_service", "go_service_2"],
        ["test_optimization_data_go_service", "test_optimization_data_go_service_2"],
    )
    asserts.true(
        env,
        'load("@test_optimization_data_go_service//:export.bzl", svc_go_service = "topt_data")' in content,
    )
    asserts.true(env, '"go_service_2": svc_go_service_2,' in content)
    asserts.true(env, 'name = "test_optimization_files_go_service",' in content)
    asserts.true(env, 'name = "test_optimization_context_go_service_2",' in content)
    asserts.true(env, 'name = "module_go_service_" + _lab,' in content)
    return unittest.end(env)

def _render_multi_aggregate_bzl_mismatch_target_impl(_ctx):
    """Target expected to fail on keys/repos length mismatch."""
    render_multi_aggregate_bzl_for_tests(["go_service"], ["repo_a", "repo_b"])
    return []

render_multi_aggregate_bzl_mismatch_target_rule = rule(
    implementation = _render_multi_aggregate_bzl_mismatch_target_impl,
)

def _render_multi_aggregate_bzl_mismatch_failure_test_impl(ctx):
    """Assert mismatch failure message remains stable and actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "service_keys and repo_names length mismatch")
    return analysistest.end(env)

compute_service_keys_dedups_collisions_test = unittest.make(_compute_service_keys_dedups_collisions_test)
compute_repo_names_test = unittest.make(_compute_repo_names_test)
render_multi_aggregate_bzl_contains_expected_targets_test = unittest.make(_render_multi_aggregate_bzl_contains_expected_targets_test)
render_multi_aggregate_bzl_mismatch_failure_test = analysistest.make(
    _render_multi_aggregate_bzl_mismatch_failure_test_impl,
    expect_failure = True,
)
