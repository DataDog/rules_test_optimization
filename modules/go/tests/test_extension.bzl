# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for the Go Bzlmod extension sync-spec builders."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "build_go_multi_repo_specs_for_tests",
    "build_go_single_repo_spec_for_tests",
)

def _go_single_spec_propagates_non_default_enablement_and_flaky_tests_test(ctx):
    env = unittest.begin(ctx)
    spec = build_go_single_repo_spec_for_tests(
        name = "test_optimization_data_go",
        service = "go-service",
        module_path = "example.com/repo",
        runtime_version = "1.25.9",
        enabled = False,
        enabled_by_env = False,
        flaky_tests = False,
    )
    asserts.equals(env, False, spec["enabled"])
    asserts.equals(env, False, spec["enabled_by_env"])
    asserts.equals(env, False, spec["flaky_tests"])
    asserts.equals(env, "go", spec["runtime_name"])
    return unittest.end(env)

def _go_multi_specs_propagate_non_default_enablement_and_flaky_tests_test(ctx):
    env = unittest.begin(ctx)
    specs = build_go_multi_repo_specs_for_tests(
        name = "test_optimization_data_go",
        services = ["go-service-a"],
        module_path = "example.com/repo",
        runtime_version = "1.25.9",
        enabled = False,
        enabled_by_env = False,
        flaky_tests = False,
    )
    asserts.equals(env, 1, len(specs))
    asserts.equals(env, False, specs[0]["enabled"])
    asserts.equals(env, False, specs[0]["enabled_by_env"])
    asserts.equals(env, False, specs[0]["flaky_tests"])
    asserts.equals(env, "go", specs[0]["runtime_name"])
    return unittest.end(env)

def _go_specs_preserve_legacy_always_enabled_default_test(ctx):
    env = unittest.begin(ctx)
    single = build_go_single_repo_spec_for_tests(
        name = "test_optimization_data_go",
        service = "go-service",
    )
    multi = build_go_multi_repo_specs_for_tests(
        name = "test_optimization_data_go",
        services = ["go-service"],
    )
    asserts.equals(env, False, single["enabled_by_env"])
    asserts.equals(env, False, multi[0]["enabled_by_env"])
    return unittest.end(env)

go_single_spec_propagates_non_default_enablement_and_flaky_tests_test = unittest.make(
    _go_single_spec_propagates_non_default_enablement_and_flaky_tests_test,
)

go_multi_specs_propagate_non_default_enablement_and_flaky_tests_test = unittest.make(
    _go_multi_specs_propagate_non_default_enablement_and_flaky_tests_test,
)

go_specs_preserve_legacy_always_enabled_default_test = unittest.make(
    _go_specs_preserve_legacy_always_enabled_default_test,
)
