# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Internal Orchestrion wrapper rule for Go tests."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

_BAZEL_TARGET_METADATA_OUTPUT = "bazel_target_metadata.json"
_ORCHESTRION_MODE_GENERAL = "general"
_ORCHESTRION_MODE_TEST_OPTIMIZATION = "test_optimization"

def _orch_transition_impl(_settings, _attr):
    return {
        "@rules_go//go/private/orchestrion:mode": _attr.orchestrion_mode,
    }

orch_transition_impl_for_tests = _orch_transition_impl

orch_transition = transition(
    implementation = _orch_transition_impl,
    inputs = [],
    outputs = ["@rules_go//go/private/orchestrion:mode"],
)

def _first_target(dep):
    if type(dep) == "list":
        if len(dep) == 0:
            fail("orch_go_test: actual produced no targets")
        return dep[0]
    return dep

def _dep_exec_and_runfiles(dep):
    target = _first_target(dep)
    default_info = target[DefaultInfo]
    return default_info.files_to_run.executable, default_info.default_runfiles.merge(default_info.data_runfiles)

def _dep_run_environment_info(dep):
    target = _first_target(dep)
    if RunEnvironmentInfo in target:
        return target[RunEnvironmentInfo]
    return None

def _select_wrapper_output_name(label_name, executable_basename, is_windows):
    if is_windows:
        return label_name + ".bat"
    return label_name

def _wrapped_actual_output_name(label_name, executable_basename):
    """Return the wrapper-owned sibling executable name used at test runtime."""
    return label_name + "__wrapped_" + executable_basename

def _unix_wrapper_content(actual_filename, metadata_filename):
    """Render the Unix launcher used by the Orchestrion wrapper target."""
    return """#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
actual="$script_dir/%s"
undeclared_dir="${TEST_UNDECLARED_OUTPUTS_DIR:-}"

if [[ ! -x "$actual" ]]; then
  echo "orch_go_test: wrapped test executable not found: $actual" >&2
  exit 1
fi

if [[ -n "$undeclared_dir" ]]; then
  metadata_source="$script_dir/%s"
  if [[ -f "$metadata_source" ]]; then
    cp "$metadata_source" "$undeclared_dir/%s"
  fi
fi

"$actual" "$@"
""" % (actual_filename, metadata_filename, _BAZEL_TARGET_METADATA_OUTPUT)

def _windows_wrapper_content(actual_filename, metadata_filename):
    """Render the Windows launcher used by the Orchestrion wrapper target."""
    return """@echo off
setlocal
set "SCRIPT_DIR=%%~dp0"
set "ACTUAL=%%SCRIPT_DIR%%%s"
set "UNDECLARED_DIR=%%TEST_UNDECLARED_OUTPUTS_DIR%%"

if not exist "%%ACTUAL%%" (
  echo orch_go_test: wrapped test executable not found: %%ACTUAL%% 1>&2
  exit /b 1
)

if not "%%UNDECLARED_DIR%%"=="" (
  if exist "%%SCRIPT_DIR%%%s" copy /Y "%%SCRIPT_DIR%%%s" "%%UNDECLARED_DIR%%\\%s" >nul
)

"%%ACTUAL%%" %%*
exit /b %%ERRORLEVEL%%
""" % (
        actual_filename.replace("/", "\\"),
        metadata_filename.replace("/", "\\"),
        metadata_filename.replace("/", "\\"),
        _BAZEL_TARGET_METADATA_OUTPUT,
    )

def _orch_go_test_impl(ctx):
    if ctx.attr.test_optimization_enabled and not ctx.attr._orchestrion_enabled[BuildSettingInfo].value:
        fail(
            "orch_go_test: Test Optimization metadata is enabled but Orchestrion is disabled; " +
            "run with --config=test-optimization. Consumers upgrading an existing setup should " +
            "rerun dd_topt_go_bootstrap with --write-bazelrc before building tests.",
        )

    dep_exe, dep_runfiles = _dep_exec_and_runfiles(ctx.attr.actual)
    dep_run_environment = _dep_run_environment_info(ctx.attr.actual)
    metadata_file = ctx.file.metadata
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    out = ctx.actions.declare_file(_select_wrapper_output_name(ctx.label.name, dep_exe.basename, is_windows))
    actual_out = ctx.actions.declare_file(_wrapped_actual_output_name(ctx.label.name, dep_exe.basename), sibling = out)

    # Materialize the raw test binary next to the wrapper so the launcher does
    # not have to guess which configuration-specific execroot path Bazel chose.
    ctx.actions.symlink(output = actual_out, target_file = dep_exe)

    ctx.actions.write(
        output = out,
        content = _windows_wrapper_content(actual_out.basename, metadata_file.basename) if is_windows else _unix_wrapper_content(actual_out.basename, metadata_file.basename),
        is_executable = True,
    )
    providers = [DefaultInfo(
        files = depset([out, actual_out, metadata_file]),
        runfiles = dep_runfiles.merge(ctx.runfiles(files = [actual_out, metadata_file])),
        executable = out,
    )]
    if dep_run_environment:
        providers.append(dep_run_environment)
    return providers

orch_go_test = rule(
    implementation = _orch_go_test_impl,
    attrs = {
        "actual": attr.label(
            mandatory = True,
            executable = True,
            cfg = orch_transition,
            doc = "The underlying raw go_test target built with Orchestrion enabled.",
        ),
        "metadata": attr.label(
            mandatory = True,
            allow_single_file = True,
            cfg = orch_transition,
            doc = "Bazel-owned target metadata copied next to emitted test payloads.",
        ),
        "orchestrion_mode": attr.string(
            default = _ORCHESTRION_MODE_GENERAL,
            values = [
                _ORCHESTRION_MODE_GENERAL,
                _ORCHESTRION_MODE_TEST_OPTIMIZATION,
            ],
            doc = "Internal Orchestrion mode forwarded to the raw go_test target.",
        ),
        "test_optimization_enabled": attr.bool(
            default = False,
            doc = "Whether the selected generated metadata repository is enabled.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
        "_orchestrion_enabled": attr.label(
            default = "@rules_go//go/private/orchestrion:enabled",
            providers = [BuildSettingInfo],
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    test = True,
)

select_wrapper_output_name_for_tests = _select_wrapper_output_name
windows_wrapper_content_for_tests = _windows_wrapper_content
