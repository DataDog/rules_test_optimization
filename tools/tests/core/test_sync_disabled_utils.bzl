# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for disabled Test Optimization repository rendering."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//tools/core:common_utils.bzl", "RULES_VERSION")
load(
    "//tools/core:test_optimization_sync.bzl",
    "is_test_optimization_enabled_for_tests",
    "render_disabled_build_for_tests",
    "render_disabled_context_json_for_tests",
    "render_disabled_export_for_tests",
    "render_disabled_flaky_tests_json_for_tests",
    "render_disabled_known_tests_json_for_tests",
    "render_disabled_settings_json_for_tests",
    "render_disabled_telemetry_facts_json_for_tests",
    "render_disabled_test_management_json_for_tests",
    "repository_environ_for_tests",
    "resolve_service_and_environment_for_tests",
)

def _enabled_truthy_values_test(ctx):
    env = unittest.begin(ctx)
    for value in ["1", "true", "True", "TRUE", "yes", "Yes", "YES", "on", "ON"]:
        asserts.true(
            env,
            is_test_optimization_enabled_for_tests(True, True, value),
            "expected truthy value %s" % value,
        )
    return unittest.end(env)

def _enabled_false_values_test(ctx):
    env = unittest.begin(ctx)
    for value in ["", "0", "false", "False", "no", "off", "disabled"]:
        asserts.false(
            env,
            is_test_optimization_enabled_for_tests(True, True, value),
            "expected false value %s" % value,
        )
    asserts.false(env, is_test_optimization_enabled_for_tests(False, False, "1"))
    asserts.true(env, is_test_optimization_enabled_for_tests(True, False, ""))
    return unittest.end(env)

def _repository_environment_contains_bootstrap_inputs_test(ctx):
    env = unittest.begin(ctx)
    for key in [
        "DD_API_KEY",
        "DD_TEST_OPTIMIZATION_HTTP_MAX_TIME_SECONDS",
        "FETCH_SALT",
        "GO_MODULE_PATH",
        "OS",
        "DD_GIT_COMMIT_SHA",
        "DD_TEST_OPTIMIZATION_ENABLED",
    ]:
        asserts.true(env, key in repository_environ_for_tests, "missing repository environ key %s" % key)
    return unittest.end(env)

def _service_environment_resolution_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"service": "attr-service", "environment": "attr-env"},
        resolve_service_and_environment_for_tests("attr-service", {"DD_SERVICE": "env-service", "DD_ENV": "attr-env"}),
    )
    asserts.equals(
        env,
        {"service": "env-service", "environment": "env"},
        resolve_service_and_environment_for_tests("", {"DD_SERVICE": "env-service", "DD_ENV": "env"}),
    )
    asserts.equals(
        env,
        {"service": "unnamed-service", "environment": "CI"},
        resolve_service_and_environment_for_tests("", {}),
    )
    return unittest.end(env)

def _disabled_context_contract_test(ctx):
    env = unittest.begin(ctx)
    content = render_disabled_context_json_for_tests(
        "test_optimization_data",
        "custom_topt",
        {
            "service": "service-name",
            "environment": "test",
            "repository_url": "https://github.com/example/repo",
            "sha": "abc123",
        },
        runtime_name = "go",
        runtime_version = "1.25.0",
        runtime_arch = "amd64",
    )
    decoded = json.decode(content)
    asserts.equals(env, {
        "bazel.rule_name": "datadog-rules-test-optimization",
        "bazel.rule_version": RULES_VERSION,
        "env": "test",
        "git.commit.sha": "abc123",
        "git.repository_url": "https://github.com/example/repo",
        "runtime.architecture": "amd64",
        "runtime.name": "go",
        "runtime.version": "1.25.0",
        "service.name": "service-name",
        "topt.sync.enabled": False,
        "topt.sync.out_dir": "custom_topt",
        "topt.sync.repository_name": "test_optimization_data",
    }, decoded)

    without_runtime = json.decode(render_disabled_context_json_for_tests(
        "test_optimization_data",
        "custom_topt",
        {"service": "service-name", "environment": "test"},
    ))
    asserts.false(env, "runtime.name" in without_runtime)
    asserts.false(env, "runtime.version" in without_runtime)
    asserts.false(env, "runtime.architecture" in without_runtime)
    return unittest.end(env)

def _disabled_telemetry_contract_test(ctx):
    env = unittest.begin(ctx)
    decoded = json.decode(render_disabled_telemetry_facts_json_for_tests("service-name", "go", "CI"))
    asserts.equals(env, {
        "counts": [{"name": "sync.disabled", "value": 1, "tags": []}],
        "distributions": [],
        "env": "CI",
        "runtime_name": "go",
        "schema_version": 1,
        "service_name": "service-name",
    }, decoded)
    return unittest.end(env)

def _disabled_cache_payloads_contract_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, {
        "data": {
            "attributes": {
                "flaky_test_retries_enabled": False,
                "known_tests_enabled": False,
                "test_management": {"enabled": False},
            },
        },
    }, json.decode(render_disabled_settings_json_for_tests()))
    asserts.equals(
        env,
        {"data": {"attributes": {"tests": {}}}},
        json.decode(render_disabled_known_tests_json_for_tests()),
    )
    asserts.equals(
        env,
        {"data": {"attributes": {"modules": {}}}},
        json.decode(render_disabled_test_management_json_for_tests()),
    )
    asserts.equals(env, {"data": []}, json.decode(render_disabled_flaky_tests_json_for_tests()))
    return unittest.end(env)

def _disabled_export_and_build_shape_test(ctx):
    env = unittest.begin(ctx)
    export = render_disabled_export_for_tests(
        "test_optimization_data",
        "go-service",
        "go",
        "example.com/repo",
        "custom_topt",
    )
    asserts.true(env, '"repo_name": "test_optimization_data"' in export)
    asserts.true(env, '"service_name": "go-service"' in export)
    asserts.true(env, '"enabled": False' in export)
    asserts.true(env, '"manifest_path": "custom_topt/manifest.txt"' in export)
    asserts.true(env, '"module_path": "example.com/repo"' in export)

    build = render_disabled_build_for_tests(
        "custom_topt/cache/http/settings.json",
        "custom_topt/manifest.txt",
        "custom_topt/cache/http/known_tests.json",
        "custom_topt/cache/http/test_management.json",
        "custom_topt/cache/http/flaky_tests.json",
        "custom_topt/context.json",
        "custom_topt/telemetry_facts.json",
    )
    for fragment in [
        'name = "test_optimization_files"',
        'name = "test_optimization_context"',
        "custom_topt/cache/http/settings.json",
        "custom_topt/cache/http/known_tests.json",
        "custom_topt/cache/http/test_management.json",
        "custom_topt/cache/http/flaky_tests.json",
        "custom_topt/telemetry_facts.json",
    ]:
        asserts.true(env, fragment in build, "missing BUILD fragment %s" % fragment)
    return unittest.end(env)

enabled_truthy_values_test = unittest.make(_enabled_truthy_values_test)
enabled_false_values_test = unittest.make(_enabled_false_values_test)
repository_environment_contains_bootstrap_inputs_test = unittest.make(_repository_environment_contains_bootstrap_inputs_test)
service_environment_resolution_test = unittest.make(_service_environment_resolution_test)
disabled_context_contract_test = unittest.make(_disabled_context_contract_test)
disabled_cache_payloads_contract_test = unittest.make(_disabled_cache_payloads_contract_test)
disabled_telemetry_contract_test = unittest.make(_disabled_telemetry_contract_test)
disabled_export_and_build_shape_test = unittest.make(_disabled_export_and_build_shape_test)
