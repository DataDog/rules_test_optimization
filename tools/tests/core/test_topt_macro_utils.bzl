# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for shared macro helper utilities."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//tools/core:topt_macro_utils.bzl",
    "merge_optional_env_defaults",
    "split_test_wrapper_kwargs_for_tests",
)

def _merge_optional_env_defaults_none_env_test(ctx):
    """Validate defaults are injected when callers do not pass env."""
    env = unittest.begin(ctx)
    merged = merge_optional_env_defaults(
        None,
        {"DD_SERVICE": "go-service", "EMPTY": ""},
        macro_name = "macro_for_tests",
    )
    asserts.equals(env, {"DD_SERVICE": "go-service"}, merged)
    return unittest.end(env)

def _merge_optional_env_defaults_injects_missing_key_test(ctx):
    """Validate missing keys are added without disturbing existing env."""
    env = unittest.begin(ctx)
    merged = merge_optional_env_defaults(
        {"CUSTOM_ENV": "1"},
        {"DD_SERVICE": "go-service"},
        macro_name = "macro_for_tests",
    )
    asserts.equals(env, {"CUSTOM_ENV": "1", "DD_SERVICE": "go-service"}, merged)
    return unittest.end(env)

def _merge_optional_env_defaults_preserves_explicit_value_test(ctx):
    """Validate explicit caller DD_SERVICE wins over defaults."""
    env = unittest.begin(ctx)
    merged = merge_optional_env_defaults(
        {"DD_SERVICE": "caller-service", "CUSTOM_ENV": "1"},
        {"DD_SERVICE": "default-service"},
        macro_name = "macro_for_tests",
    )
    asserts.equals(env, {"DD_SERVICE": "caller-service", "CUSTOM_ENV": "1"}, merged)
    return unittest.end(env)

def _merge_optional_env_defaults_select_passthrough_test(ctx):
    """Validate configurable env values are left unchanged for safety."""
    env = unittest.begin(ctx)
    caller_env = select({
        "//conditions:default": {
            "CUSTOM_ENV": "from_select",
        },
    })
    merged = merge_optional_env_defaults(
        caller_env,
        {"DD_SERVICE": "go-service"},
        macro_name = "macro_for_tests",
    )
    asserts.equals(env, "select", type(merged))
    return unittest.end(env)

def _merge_optional_env_defaults_ignores_empty_defaults_test(ctx):
    """Validate empty defaults do not create placeholder env entries."""
    env = unittest.begin(ctx)
    merged = merge_optional_env_defaults(
        {"CUSTOM_ENV": "1"},
        {"DD_SERVICE": "", "EMPTY": None},
        macro_name = "macro_for_tests",
    )
    asserts.equals(env, {"CUSTOM_ENV": "1"}, merged)
    return unittest.end(env)

def _split_test_wrapper_kwargs_routes_args_to_wrapper_test(ctx):
    """Validate runtime test args stay on the public wrapper target."""
    env = unittest.begin(ctx)
    kwargs = {
        "args": ["--flag", "value"],
        "timeout": "short",
        "compatible_with": ["//platforms:demo"],
        "deps": ["//demo:dep"],
    }
    wrapper_kwargs, raw_passthrough = split_test_wrapper_kwargs_for_tests(kwargs)
    asserts.equals(env, ["--flag", "value"], wrapper_kwargs.get("args"))
    asserts.equals(env, "short", wrapper_kwargs.get("timeout"))
    asserts.equals(env, ["//platforms:demo"], wrapper_kwargs.get("compatible_with"))
    asserts.equals(env, {"compatible_with": ["//platforms:demo"]}, raw_passthrough)
    asserts.equals(env, ["//demo:dep"], kwargs.get("deps"))
    asserts.equals(env, None, kwargs.get("args"))
    return unittest.end(env)

merge_optional_env_defaults_none_env_test = unittest.make(_merge_optional_env_defaults_none_env_test)
merge_optional_env_defaults_injects_missing_key_test = unittest.make(_merge_optional_env_defaults_injects_missing_key_test)
merge_optional_env_defaults_preserves_explicit_value_test = unittest.make(_merge_optional_env_defaults_preserves_explicit_value_test)
merge_optional_env_defaults_select_passthrough_test = unittest.make(_merge_optional_env_defaults_select_passthrough_test)
merge_optional_env_defaults_ignores_empty_defaults_test = unittest.make(_merge_optional_env_defaults_ignores_empty_defaults_test)
split_test_wrapper_kwargs_routes_args_to_wrapper_test = unittest.make(_split_test_wrapper_kwargs_routes_args_to_wrapper_test)
