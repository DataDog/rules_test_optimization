# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for the public WORKSPACE bootstrap helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "@datadog-rules-test-optimization-go//:topt_go_orchestrion_repository.bzl",
    "build_orchestrion_repo_call_for_tests",
)
load(
    "@datadog-rules-test-optimization-go//:topt_go_workspace.bzl",
    "build_go_workspace_sync_specs_for_tests",
)

def _assert_sync_spec(env, spec, name, service, expected_enabled_by_env):
    asserts.equals(env, name, spec["name"])
    asserts.equals(env, name, spec["repo_name"])
    asserts.equals(env, service, spec["service"])
    asserts.equals(env, "go", spec["runtime_name"])
    asserts.equals(env, "1.25.9", spec["runtime_version"])
    asserts.equals(env, "arm64", spec["runtime_arch"])
    asserts.equals(env, "example.com/workspace", spec["runtime_module_path"])
    asserts.equals(env, "custom_topt", spec["out_dir"])
    asserts.equals(env, False, spec["enabled"])
    asserts.equals(env, expected_enabled_by_env, spec["enabled_by_env"])
    asserts.equals(env, 11, spec["http_connect_timeout_seconds"])
    asserts.equals(env, 22, spec["http_max_time_seconds"])
    asserts.equals(env, 3, spec["http_retry_attempts"])
    asserts.equals(env, 4, spec["http_retry_delay_seconds"])
    asserts.equals(env, 5, spec["http_execute_timeout_buffer_seconds"])
    asserts.equals(env, False, spec["known_tests"])
    asserts.equals(env, False, spec["test_management"])
    asserts.equals(env, False, spec["flaky_tests"])
    asserts.equals(env, True, spec["require_git_metadata"])
    asserts.equals(env, True, spec["debug"])

def _go_workspace_single_specs_test(ctx):
    env = unittest.begin(ctx)
    result = build_go_workspace_sync_specs_for_tests(
        name = "test_optimization_data_go",
        service = "go-service",
        runtime_version = "1.25.9",
        module_path = "example.com/workspace",
        enabled = False,
        enabled_by_env = False,
        runtime_arch = "arm64",
        out_dir = "custom_topt",
        http_connect_timeout_seconds = 11,
        http_max_time_seconds = 22,
        http_retry_attempts = 3,
        http_retry_delay_seconds = 4,
        http_execute_timeout_buffer_seconds = 5,
        known_tests = False,
        test_management = False,
        flaky_tests = False,
        require_git_metadata = True,
        debug = True,
    )
    asserts.equals(env, 1, len(result["sync_specs"]))
    _assert_sync_spec(env, result["sync_specs"][0], "test_optimization_data_go", "go-service", False)
    asserts.equals(env, None, result["aggregate_spec"])
    return unittest.end(env)

def _go_workspace_multi_specs_test(ctx):
    env = unittest.begin(ctx)
    result = build_go_workspace_sync_specs_for_tests(
        name = "test_optimization_data_go",
        services = ["go-service-a", "go-service-a", "go-service-b"],
        runtime_version = "1.25.9",
        module_path = "example.com/workspace",
        enabled = False,
        enabled_by_env = False,
        runtime_arch = "arm64",
        out_dir = "custom_topt",
        http_connect_timeout_seconds = 11,
        http_max_time_seconds = 22,
        http_retry_attempts = 3,
        http_retry_delay_seconds = 4,
        http_execute_timeout_buffer_seconds = 5,
        known_tests = False,
        test_management = False,
        flaky_tests = False,
        require_git_metadata = True,
        debug = True,
    )
    asserts.equals(env, ["go_service_a", "go_service_a_2", "go_service_b"], result["aggregate_spec"]["service_keys"])
    asserts.equals(
        env,
        [
            "test_optimization_data_go_go_service_a",
            "test_optimization_data_go_go_service_a_2",
            "test_optimization_data_go_go_service_b",
        ],
        result["aggregate_spec"]["repo_names"],
    )
    for i in range(3):
        _assert_sync_spec(
            env,
            result["sync_specs"][i],
            result["aggregate_spec"]["repo_names"][i],
            ["go-service-a", "go-service-a", "go-service-b"][i],
            False,
        )
    return unittest.end(env)

def _go_workspace_specs_default_to_config_gated_test(ctx):
    env = unittest.begin(ctx)
    result = build_go_workspace_sync_specs_for_tests(
        name = "test_optimization_data_go",
        service = "go-service",
        runtime_version = "1.25.9",
        module_path = "example.com/workspace",
    )
    asserts.equals(env, True, result["sync_specs"][0]["enabled_by_env"])
    return unittest.end(env)

def _orchestrion_call_spec_test(ctx):
    env = unittest.begin(ctx)
    call = build_orchestrion_repo_call_for_tests(
        dd_trace_go_version = "v2.9.0",
        dd_trace_go_versions = {"example.com/service": "v2.8.0"},
        version = "v1.9.0",
        log_timing = True,
    )
    asserts.equals(
        env,
        {
            "name": "rules_go_orchestrion_tool",
            "dd_trace_go_version": "v2.9.0",
            "dd_trace_go_versions": {"example.com/service": "v2.8.0"},
            "enabled_by_env": True,
            "version": "v1.9.0",
            "log_timing": True,
        },
        call,
    )
    asserts.false(env, "enabled" in call)
    return unittest.end(env)

go_workspace_single_specs_test = unittest.make(_go_workspace_single_specs_test)
go_workspace_multi_specs_test = unittest.make(_go_workspace_multi_specs_test)
go_workspace_specs_default_to_config_gated_test = unittest.make(_go_workspace_specs_default_to_config_gated_test)
orchestrion_call_spec_test = unittest.make(_orchestrion_call_spec_test)
