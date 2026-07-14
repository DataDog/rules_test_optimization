# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

# Unit tests for multi-service extension helper utilities.
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//tools/core:test_optimization_multi_sync.bzl",
    "build_multi_sync_repo_specs_for_tests",
    "compute_multi_repo_names_for_tests",
    "compute_multi_service_keys_for_tests",
    "record_multi_repo_owner_or_fail_for_tests",
    "render_multi_aggregate_bzl_for_tests",
    "render_multi_aggregate_export_bzl_for_tests",
)

def _build_multi_sync_specs_propagates_non_default_enablement_test(ctx):
    env = unittest.begin(ctx)
    specs = build_multi_sync_repo_specs_for_tests(
        name = "test_optimization_data_go",
        services = ["service-a", "service-b"],
        runtime_name = "go",
        runtime_version = "1.25.9",
        runtime_module_path = "example.com/repo",
        enabled = False,
        enabled_by_env = True,
        flaky_tests = False,
    )
    asserts.equals(env, 2, len(specs))
    asserts.equals(env, False, specs[0]["enabled"])
    asserts.equals(env, True, specs[0]["enabled_by_env"])
    asserts.equals(env, False, specs[0]["flaky_tests"])
    asserts.equals(env, "test_optimization_data_go_service_a", specs[0]["repo"])
    asserts.equals(env, "service-a", specs[0]["service"])
    asserts.equals(env, "test_optimization_data_go_service_b", specs[1]["repo"])
    return unittest.end(env)

def _build_multi_sync_specs_deduplicates_sanitized_service_keys_test(ctx):
    env = unittest.begin(ctx)
    specs = build_multi_sync_repo_specs_for_tests(
        name = "test_optimization_data_go",
        services = ["service-a", "service.a", "service_a"],
        runtime_name = "go",
        runtime_version = "1.25.9",
        runtime_module_path = "example.com/repo",
        enabled_by_env = True,
    )
    repo_names = [spec["repo"] for spec in specs]
    asserts.equals(
        env,
        [
            "test_optimization_data_go_service_a",
            "test_optimization_data_go_service_a_2",
            "test_optimization_data_go_service_a_3",
        ],
        repo_names,
    )
    asserts.equals(env, 3, len({name: True for name in repo_names}))
    return unittest.end(env)

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

def _compute_service_keys_edge_cases_test(ctx):
    """Validate empty and single-service key generation edge cases."""
    env = unittest.begin(ctx)
    asserts.equals(env, [], compute_multi_service_keys_for_tests([]))
    asserts.equals(env, ["go_service"], compute_multi_service_keys_for_tests(["go-service"]))
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

def _record_multi_repo_owner_success_test(ctx):
    """Validate multi-sync repo owner tracking success path."""
    env = unittest.begin(ctx)
    seen = {}
    record_multi_repo_owner_or_fail_for_tests(seen, "repo_a", "module_a")
    record_multi_repo_owner_or_fail_for_tests(seen, "repo_b", "module_b")
    asserts.equals(env, "module_a", seen.get("repo_a"))
    asserts.equals(env, "module_b", seen.get("repo_b"))
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

def _render_multi_aggregate_export_bzl_reexports_mapping_test(ctx):
    """Validate export.bzl re-exports the aggregate service mapping."""
    env = unittest.begin(ctx)
    content = render_multi_aggregate_export_bzl_for_tests()
    asserts.true(
        env,
        'load(":aggregate.bzl", _topt_data_by_service = "topt_data_by_service")' in content,
    )
    asserts.true(env, "topt_data_by_service = _topt_data_by_service" in content)
    return unittest.end(env)

def _render_multi_aggregate_bzl_mismatch_target_impl(_ctx):
    """Target expected to fail on keys/repos length mismatch."""
    render_multi_aggregate_bzl_for_tests(["go_service"], ["repo_a", "repo_b"])
    return []

def _record_multi_repo_owner_duplicate_target_impl(_ctx):
    """Target expected to fail on duplicate multi-sync repo names."""
    seen = {}
    record_multi_repo_owner_or_fail_for_tests(seen, "repo_a", "module_a")
    record_multi_repo_owner_or_fail_for_tests(seen, "repo_a", "module_b")
    return []

render_multi_aggregate_bzl_mismatch_target_rule = rule(
    implementation = _render_multi_aggregate_bzl_mismatch_target_impl,
)
record_multi_repo_owner_duplicate_target_rule = rule(
    implementation = _record_multi_repo_owner_duplicate_target_impl,
)

def _render_multi_aggregate_bzl_mismatch_failure_test_impl(ctx):
    """Assert mismatch failure message remains stable and actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "service_keys and repo_names length mismatch")
    return analysistest.end(env)

def _record_multi_repo_owner_duplicate_failure_test_impl(ctx):
    """Assert duplicate multi-sync repo-name failures remain actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "duplicate repository name 'repo_a' generated")
    return analysistest.end(env)

compute_service_keys_dedups_collisions_test = unittest.make(_compute_service_keys_dedups_collisions_test)
compute_service_keys_edge_cases_test = unittest.make(_compute_service_keys_edge_cases_test)
compute_repo_names_test = unittest.make(_compute_repo_names_test)
build_multi_sync_specs_propagates_non_default_enablement_test = unittest.make(_build_multi_sync_specs_propagates_non_default_enablement_test)
build_multi_sync_specs_deduplicates_sanitized_service_keys_test = unittest.make(_build_multi_sync_specs_deduplicates_sanitized_service_keys_test)
record_multi_repo_owner_success_test = unittest.make(_record_multi_repo_owner_success_test)
render_multi_aggregate_bzl_contains_expected_targets_test = unittest.make(_render_multi_aggregate_bzl_contains_expected_targets_test)
render_multi_aggregate_export_bzl_reexports_mapping_test = unittest.make(_render_multi_aggregate_export_bzl_reexports_mapping_test)
render_multi_aggregate_bzl_mismatch_failure_test = analysistest.make(
    _render_multi_aggregate_bzl_mismatch_failure_test_impl,
    expect_failure = True,
)
record_multi_repo_owner_duplicate_failure_test = analysistest.make(
    _record_multi_repo_owner_duplicate_failure_test_impl,
    expect_failure = True,
)
