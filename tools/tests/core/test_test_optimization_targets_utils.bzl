# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for the shared doctor/uploader target helper."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//tools/core:test_optimization_targets.bzl",
    "build_test_optimization_target_specs_for_tests",
)

def _default_context_data_test(ctx):
    """Validate that the default context data points at the sync repo."""
    env = unittest.begin(ctx)
    specs = build_test_optimization_target_specs_for_tests(
        name = "test_optimization",
        sync_repo_name = "test_optimization_data_python",
        doctor_name = "dd_test_optimization_doctor",
        uploader_name = "dd_upload_payloads",
        expected_targets = [],
        context_data = None,
        doctor_kwargs = None,
        uploader_kwargs = None,
    )
    asserts.equals(env, ["@test_optimization_data_python//:test_optimization_context"], specs.doctor_attrs["data"])
    asserts.equals(env, specs.doctor_attrs["data"], specs.uploader_attrs["data"])
    return unittest.end(env)

default_context_data_test = unittest.make(_default_context_data_test)

def _explicit_context_data_test(ctx):
    """Validate that explicit context data is preserved for both targets."""
    env = unittest.begin(ctx)
    context_data = ["@custom_sync//:test_optimization_context"]
    specs = build_test_optimization_target_specs_for_tests(
        name = "test_optimization",
        sync_repo_name = "ignored",
        doctor_name = "doctor",
        uploader_name = "uploader",
        expected_targets = [],
        context_data = context_data,
        doctor_kwargs = None,
        uploader_kwargs = None,
    )
    asserts.equals(env, context_data, specs.doctor_attrs["data"])
    asserts.equals(env, context_data, specs.uploader_attrs["data"])
    return unittest.end(env)

explicit_context_data_test = unittest.make(_explicit_context_data_test)

def _expected_targets_test(ctx):
    """Validate strict expected target labels are forwarded to the doctor."""
    env = unittest.begin(ctx)
    expected_targets = ["//app:unit_test", "//lib:integration_test"]
    specs = build_test_optimization_target_specs_for_tests(
        name = "test_optimization",
        sync_repo_name = "test_optimization_data",
        doctor_name = "doctor",
        uploader_name = "uploader",
        expected_targets = expected_targets,
        context_data = None,
        doctor_kwargs = None,
        uploader_kwargs = None,
    )
    asserts.equals(env, expected_targets, specs.doctor_attrs["expected_targets"])
    return unittest.end(env)

expected_targets_test = unittest.make(_expected_targets_test)

def _doctor_kwargs_test(ctx):
    """Validate allowed doctor kwargs are forwarded without overwriting controlled attrs."""
    env = unittest.begin(ctx)
    specs = build_test_optimization_target_specs_for_tests(
        name = "test_optimization",
        sync_repo_name = "test_optimization_data",
        doctor_name = "doctor",
        uploader_name = "uploader",
        expected_targets = [],
        context_data = None,
        doctor_kwargs = {
            "require_git_metadata": False,
            "forbid_full_bundle_no_match": False,
        },
        uploader_kwargs = None,
    )
    asserts.equals(env, False, specs.doctor_attrs["require_git_metadata"])
    asserts.equals(env, False, specs.doctor_attrs["forbid_full_bundle_no_match"])
    return unittest.end(env)

doctor_kwargs_test = unittest.make(_doctor_kwargs_test)

def _uploader_kwargs_test(ctx):
    """Validate allowed uploader kwargs are forwarded without overwriting controlled attrs."""
    env = unittest.begin(ctx)
    specs = build_test_optimization_target_specs_for_tests(
        name = "test_optimization",
        sync_repo_name = "test_optimization_data",
        doctor_name = "doctor",
        uploader_name = "uploader",
        expected_targets = [],
        context_data = None,
        doctor_kwargs = None,
        uploader_kwargs = {
            "max_wait_sec": 30,
            "quiescent_sec": 1,
        },
    )
    asserts.equals(env, 30, specs.uploader_attrs["max_wait_sec"])
    asserts.equals(env, 1, specs.uploader_attrs["quiescent_sec"])
    return unittest.end(env)

uploader_kwargs_test = unittest.make(_uploader_kwargs_test)

def _empty_name_target_impl(_ctx):
    """Create a target that fails for an empty helper name."""
    build_test_optimization_target_specs_for_tests(
        name = "",
        sync_repo_name = "test_optimization_data",
        doctor_name = "doctor",
        uploader_name = "uploader",
        expected_targets = [],
        context_data = None,
        doctor_kwargs = None,
        uploader_kwargs = None,
    )
    return []

empty_name_target_rule = rule(implementation = _empty_name_target_impl)

def _duplicate_names_target_impl(_ctx):
    """Create a target that fails for duplicate generated target names."""
    build_test_optimization_target_specs_for_tests(
        name = "test_optimization",
        sync_repo_name = "test_optimization_data",
        doctor_name = "same",
        uploader_name = "same",
        expected_targets = [],
        context_data = None,
        doctor_kwargs = None,
        uploader_kwargs = None,
    )
    return []

duplicate_names_target_rule = rule(implementation = _duplicate_names_target_impl)

def _doctor_controlled_attr_target_impl(_ctx):
    """Create a target that fails when doctor kwargs override controlled attrs."""
    build_test_optimization_target_specs_for_tests(
        name = "test_optimization",
        sync_repo_name = "test_optimization_data",
        doctor_name = "doctor",
        uploader_name = "uploader",
        expected_targets = [],
        context_data = None,
        doctor_kwargs = {"name": "bad"},
        uploader_kwargs = None,
    )
    return []

doctor_controlled_attr_target_rule = rule(implementation = _doctor_controlled_attr_target_impl)

def _uploader_controlled_attr_target_impl(_ctx):
    """Create a target that fails when uploader kwargs override controlled attrs."""
    build_test_optimization_target_specs_for_tests(
        name = "test_optimization",
        sync_repo_name = "test_optimization_data",
        doctor_name = "doctor",
        uploader_name = "uploader",
        expected_targets = [],
        context_data = None,
        doctor_kwargs = None,
        uploader_kwargs = {"data": [":bad"]},
    )
    return []

uploader_controlled_attr_target_rule = rule(implementation = _uploader_controlled_attr_target_impl)

def _empty_name_failure_test_impl(ctx):
    """Assert empty helper names fail with an actionable message."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "name must be a non-empty string")
    return analysistest.end(env)

empty_name_failure_test = analysistest.make(
    _empty_name_failure_test_impl,
    expect_failure = True,
)

def _duplicate_names_failure_test_impl(ctx):
    """Assert duplicate doctor/uploader names fail clearly."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "doctor_name and uploader_name must be different")
    return analysistest.end(env)

duplicate_names_failure_test = analysistest.make(
    _duplicate_names_failure_test_impl,
    expect_failure = True,
)

def _doctor_controlled_attr_failure_test_impl(ctx):
    """Assert controlled doctor attrs cannot be passed through kwargs."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "doctor_kwargs cannot override controlled attrs")
    return analysistest.end(env)

doctor_controlled_attr_failure_test = analysistest.make(
    _doctor_controlled_attr_failure_test_impl,
    expect_failure = True,
)

def _uploader_controlled_attr_failure_test_impl(ctx):
    """Assert controlled uploader attrs cannot be passed through kwargs."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "uploader_kwargs cannot override controlled attrs")
    return analysistest.end(env)

uploader_controlled_attr_failure_test = analysistest.make(
    _uploader_controlled_attr_failure_test_impl,
    expect_failure = True,
)
