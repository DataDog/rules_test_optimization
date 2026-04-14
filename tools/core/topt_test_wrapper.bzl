"""Internal helpers for companion test wrappers and Bazel metadata sidecars.

These rules are core-owned infrastructure used by language companion macros to:
- preserve native test execution behavior through a thin wrapper target
- copy Bazel-owned target metadata into TEST_UNDECLARED_OUTPUTS_DIR
- keep uploader-side payload enrichment consistent across runtimes
"""

_BAZEL_TARGET_METADATA_OUTPUT = "bazel_target_metadata.json"

def _first_target(dep):
    """Return the first configured target when a select() expands to a list."""
    if type(dep) == "list":
        if len(dep) == 0:
            fail("topt_test_wrapper: actual produced no targets")
        return dep[0]
    return dep

def _dep_exec_and_runfiles(dep):
    """Return executable and merged runfiles for a wrapped raw test target."""
    target = _first_target(dep)
    default_info = target[DefaultInfo]
    return default_info.files_to_run.executable, default_info.default_runfiles.merge(default_info.data_runfiles)

def _dep_run_environment_info(dep):
    """Return propagated RunEnvironmentInfo when the raw target defines one."""
    target = _first_target(dep)
    if RunEnvironmentInfo in target:
        return target[RunEnvironmentInfo]
    return None

def _select_wrapper_output_name(label_name, executable_basename, is_windows):
    """Return the public wrapper launcher file name for the current platform."""
    _ = executable_basename
    if is_windows:
        return label_name + ".bat"
    return label_name

def _wrapped_actual_output_name(label_name, executable_basename):
    """Return the sibling executable name materialized next to the wrapper."""
    return label_name + "__wrapped_" + executable_basename

def _unix_wrapper_content(actual_filename):
    """Render the Unix launcher used by wrapped non-Go test targets."""
    return """#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
actual="$script_dir/%s"
metadata_basename="${DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME:-}"
undeclared_dir="${TEST_UNDECLARED_OUTPUTS_DIR:-}"

if [[ ! -x "$actual" ]]; then
  echo "topt_test_wrapper: wrapped test executable not found: $actual" >&2
  exit 1
fi

if [[ -n "$metadata_basename" && -n "$undeclared_dir" ]]; then
  metadata_source="$script_dir/$metadata_basename"
  if [[ -f "$metadata_source" ]]; then
    cp "$metadata_source" "$undeclared_dir/%s"
  fi
fi

exec "$actual" "$@"
""" % (actual_filename, _BAZEL_TARGET_METADATA_OUTPUT)

def _windows_wrapper_content(actual_filename):
    """Render the Windows launcher used by wrapped non-Go test targets."""
    return """@echo off
setlocal
set "SCRIPT_DIR=%%~dp0"
set "ACTUAL=%%SCRIPT_DIR%%%s"
set "META_BASENAME=%%DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME%%"
set "UNDECLARED_DIR=%%TEST_UNDECLARED_OUTPUTS_DIR%%"

if not exist "%%ACTUAL%%" (
  echo topt_test_wrapper: wrapped test executable not found: %%ACTUAL%% 1>&2
  exit /b 1
)

if not "%%META_BASENAME%%"=="" if not "%%UNDECLARED_DIR%%"=="" (
  set "META_SOURCE=%%SCRIPT_DIR%%%%META_BASENAME%%"
  if exist "%%META_SOURCE%%" copy /Y "%%META_SOURCE%%" "%%UNDECLARED_DIR%%\\%s" >nul
)

"%%ACTUAL%%" %%*
set "EXITCODE=%%ERRORLEVEL%%"
exit /b %%EXITCODE%%
""" % (
        actual_filename.replace("/", "\\"),
        _BAZEL_TARGET_METADATA_OUTPUT,
    )

def _topt_test_wrapper_impl(ctx):
    """Expose a raw test executable through a metadata-copying public wrapper."""
    dep_exe, dep_runfiles = _dep_exec_and_runfiles(ctx.attr.actual)
    dep_run_environment = _dep_run_environment_info(ctx.attr.actual)
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    out = ctx.actions.declare_file(_select_wrapper_output_name(ctx.label.name, dep_exe.basename, is_windows))
    actual_out = ctx.actions.declare_file(_wrapped_actual_output_name(ctx.label.name, dep_exe.basename), sibling = out)

    # Materialize the raw executable next to the wrapper so the launcher does
    # not depend on configuration-specific execroot lookup at runtime.
    ctx.actions.symlink(output = actual_out, target_file = dep_exe)
    ctx.actions.write(
        output = out,
        content = _windows_wrapper_content(actual_out.basename) if is_windows else _unix_wrapper_content(actual_out.basename),
        is_executable = True,
    )

    providers = [DefaultInfo(
        files = depset([out, actual_out]),
        runfiles = dep_runfiles.merge(ctx.runfiles(files = [actual_out, ctx.file.metadata])),
        executable = out,
    )]
    if dep_run_environment:
        providers.append(dep_run_environment)
    return providers

topt_test_wrapper_test = rule(
    implementation = _topt_test_wrapper_impl,
    attrs = {
        "actual": attr.label(
            mandatory = True,
            executable = True,
            cfg = "target",
            doc = "The hidden raw test target executed by the public wrapper.",
        ),
        "metadata": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The Bazel metadata sidecar copied into test.outputs before execution.",
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    test = True,
)

def topt_test_wrapper(name, actual, metadata, **kwargs):
    """Expose the wrapped test rule through a stable helper name."""
    topt_test_wrapper_test(
        name = name,
        actual = actual,
        metadata = metadata,
        **kwargs
    )

def _topt_bazel_metadata_impl(ctx):
    """Emit a runtime-agnostic Bazel metadata sidecar for uploader selection."""
    out = ctx.actions.declare_file(ctx.label.name + ".json")
    metadata = {
        "bazel.package": ctx.attr.bazel_package,
        "bazel.target": ctx.attr.bazel_target,
        "bazel.test_optimization.repo_name": ctx.attr.repo_name,
        "bazel.test_optimization.service_name": ctx.attr.service_name,
        "bazel.test_optimization.runtime_name": ctx.attr.runtime_name,
    }
    ctx.actions.write(
        output = out,
        content = json.encode(metadata) + "\n",
    )
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out]))]

topt_bazel_metadata = rule(
    implementation = _topt_bazel_metadata_impl,
    attrs = {
        "bazel_package": attr.string(mandatory = True),
        "bazel_target": attr.string(mandatory = True),
        "repo_name": attr.string(mandatory = True),
        "service_name": attr.string(mandatory = True),
        "runtime_name": attr.string(mandatory = True),
    },
)

select_test_wrapper_output_name_for_tests = _select_wrapper_output_name
