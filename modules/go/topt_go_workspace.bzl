# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""WORKSPACE metadata bootstrap for Go consumers."""

load(
    "@datadog-rules-test-optimization//tools/core:common_utils.bzl",
    "dedup_keys",
    "sanitize_label_fragment",
)
load(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_aggregate",
)
load(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync",
)

def _service_keys(services):
    return dedup_keys([sanitize_label_fragment(service) for service in services])

def _build_go_workspace_sync_specs(
        name,
        runtime_version,
        module_path,
        service = None,
        services = [],
        enabled = True,
        enabled_by_env = False,
        runtime_arch = "",
        out_dir = "",
        http_connect_timeout_seconds = -1,
        http_max_time_seconds = -1,
        http_retry_attempts = -1,
        http_retry_delay_seconds = -1,
        http_execute_timeout_buffer_seconds = -1,
        known_tests = True,
        test_management = True,
        flaky_tests = True,
        require_git_metadata = False,
        debug = False):
    """Build metadata sync calls and the optional aggregate call."""
    if service and services:
        fail("set either service or services, not both")
    if not service and not services:
        fail("one of service or services is required")

    service_values = [service] if service else services
    keys = [] if service else _service_keys(services)
    repo_names = [name] if service else ["%s_%s" % (name, key) for key in keys]
    sync_specs = []
    for i in range(len(service_values)):
        sync_specs.append({
            "name": repo_names[i],
            "repo_name": repo_names[i],
            "service": service_values[i],
            "runtime_name": "go",
            "runtime_version": runtime_version,
            "runtime_arch": runtime_arch,
            "runtime_module_path": module_path,
            "out_dir": out_dir,
            "enabled": enabled,
            "enabled_by_env": enabled_by_env,
            "http_connect_timeout_seconds": http_connect_timeout_seconds,
            "http_max_time_seconds": http_max_time_seconds,
            "http_retry_attempts": http_retry_attempts,
            "http_retry_delay_seconds": http_retry_delay_seconds,
            "http_execute_timeout_buffer_seconds": http_execute_timeout_buffer_seconds,
            "known_tests": known_tests,
            "test_management": test_management,
            "flaky_tests": flaky_tests,
            "require_git_metadata": require_git_metadata,
            "debug": debug,
        })
    aggregate_spec = None
    if not service:
        aggregate_spec = {
            "name": name,
            "service_keys": keys,
            "repo_names": repo_names,
            "debug": debug,
        }
    return {
        "sync_specs": sync_specs,
        "aggregate_spec": aggregate_spec,
    }

build_go_workspace_sync_specs_for_tests = _build_go_workspace_sync_specs

def dd_topt_go_workspace_sync_repositories(
        name,
        runtime_version,
        module_path = "",
        service = None,
        services = [],
        enabled = True,
        enabled_by_env = False,
        runtime_arch = "",
        out_dir = "",
        http_connect_timeout_seconds = -1,
        http_max_time_seconds = -1,
        http_retry_attempts = -1,
        http_retry_delay_seconds = -1,
        http_execute_timeout_buffer_seconds = -1,
        known_tests = True,
        test_management = True,
        flaky_tests = True,
        require_git_metadata = False,
        debug = False):
    specs = _build_go_workspace_sync_specs(
        name = name,
        runtime_version = runtime_version,
        module_path = module_path,
        service = service,
        services = services,
        enabled = enabled,
        enabled_by_env = enabled_by_env,
        runtime_arch = runtime_arch,
        out_dir = out_dir,
        http_connect_timeout_seconds = http_connect_timeout_seconds,
        http_max_time_seconds = http_max_time_seconds,
        http_retry_attempts = http_retry_attempts,
        http_retry_delay_seconds = http_retry_delay_seconds,
        http_execute_timeout_buffer_seconds = http_execute_timeout_buffer_seconds,
        known_tests = known_tests,
        test_management = test_management,
        flaky_tests = flaky_tests,
        require_git_metadata = require_git_metadata,
        debug = debug,
    )
    for sync_spec in specs["sync_specs"]:
        test_optimization_sync(**sync_spec)
    aggregate_spec = specs["aggregate_spec"]
    if aggregate_spec:
        test_optimization_multi_aggregate(**aggregate_spec)
