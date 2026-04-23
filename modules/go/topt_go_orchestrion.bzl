"""Internal Orchestrion wrapper rule for Go tests."""

_BAZEL_TARGET_METADATA_OUTPUT = "bazel_target_metadata.json"

def _orch_transition_impl(_settings, _attr):
    return {
        "@rules_go//go/private/orchestrion:enabled": True,
    }

orch_transition = transition(
    implementation = _orch_transition_impl,
    inputs = [],
    outputs = [
        "@rules_go//go/private/orchestrion:enabled",
    ],
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

def _wrapped_helper_output_name(label_name, executable_basename):
    """Return the sibling helper executable name used for CI Visibility capture."""
    return label_name + "__" + executable_basename

def _unix_wrapper_content(actual_filename, helper_filename):
    """Render the Unix launcher used by the Orchestrion wrapper target."""
    return """#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
actual="$script_dir/%s"
capture_helper="$script_dir/%s"
metadata_basename="${DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME:-}"
undeclared_dir="${TEST_UNDECLARED_OUTPUTS_DIR:-}"
payloads_in_files="${DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES:-}"
test_exit=0
capture_pid=""
capture_port_file=""
capture_stop_file=""

cleanup() {
  local exitcode="${test_exit:-0}"
  if [[ -n "$capture_stop_file" ]]; then
    : > "$capture_stop_file" 2>/dev/null || true
  fi
  if [[ -n "$capture_pid" ]]; then
    wait "$capture_pid" 2>/dev/null || true
  fi
  if [[ -n "$capture_port_file" ]]; then
    rm -f "$capture_port_file" 2>/dev/null || true
  fi
  if [[ -n "$capture_stop_file" ]]; then
    rm -f "$capture_stop_file" 2>/dev/null || true
  fi
  exit "$exitcode"
}
trap cleanup EXIT

if [[ ! -x "$actual" ]]; then
  echo "orch_go_test: wrapped test executable not found: $actual" >&2
  exit 1
fi

if [[ -n "$metadata_basename" && -n "$undeclared_dir" ]]; then
  metadata_source="$script_dir/$metadata_basename"
  if [[ -f "$metadata_source" ]]; then
    cp "$metadata_source" "$undeclared_dir/%s"
  fi
fi

if [[ "$payloads_in_files" == "true" && -n "$undeclared_dir" ]]; then
  if [[ ! -x "$capture_helper" ]]; then
    echo "orch_go_test: CI Visibility capture helper not found: $capture_helper" >&2
    exit 1
  fi

  capture_runtime_dir="$undeclared_dir/.dd_topt_capture"
  mkdir -p "$capture_runtime_dir"
  capture_port_file="$capture_runtime_dir/capture_port_$$.txt"
  capture_stop_file="$capture_runtime_dir/capture_stop_$$.txt"
  upstream_url="${DD_TRACE_AGENT_URL:-http://localhost:8126}"

  "$capture_helper" \
    --port-file "$capture_port_file" \
    --stop-file "$capture_stop_file" \
    --output-dir "$undeclared_dir" \
    --upstream-url "$upstream_url" &
  capture_pid=$!

  for ((i = 0; i < 100; i++)); do
    if [[ -s "$capture_port_file" ]]; then
      break
    fi
    if ! kill -0 "$capture_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  if [[ ! -s "$capture_port_file" ]]; then
    echo "orch_go_test: CI Visibility capture helper failed to publish a port file" >&2
    exit 1
  fi

  capture_port="$(<"$capture_port_file")"
  export DD_TRACE_AGENT_URL="http://127.0.0.1:$capture_port"
  export DD_CIVISIBILITY_AGENTLESS_ENABLED="false"
  unset DD_CIVISIBILITY_AGENTLESS_URL || true
fi

set +e
"$actual" "$@"
test_exit=$?
set -e
""" % (actual_filename, helper_filename, _BAZEL_TARGET_METADATA_OUTPUT)

def _windows_wrapper_content(actual_filename, helper_filename):
    """Render the Windows launcher used by the Orchestrion wrapper target."""
    return """@echo off
setlocal
set "SCRIPT_DIR=%%~dp0"
set "ACTUAL=%%SCRIPT_DIR%%%s"
set "HELPER=%%SCRIPT_DIR%%%s"
set "META_BASENAME=%%DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME%%"
set "UNDECLARED_DIR=%%TEST_UNDECLARED_OUTPUTS_DIR%%"
set "PAYLOADS_IN_FILES=%%DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES%%"
set "CAPTURE_PORT_FILE="
set "CAPTURE_STOP_FILE="

if not exist "%%ACTUAL%%" (
  echo orch_go_test: wrapped test executable not found: %%ACTUAL%% 1>&2
  exit /b 1
)

if not "%%META_BASENAME%%"=="" if not "%%UNDECLARED_DIR%%"=="" (
  set "META_SOURCE=%%SCRIPT_DIR%%%%META_BASENAME%%"
  if exist "%%META_SOURCE%%" copy /Y "%%META_SOURCE%%" "%%UNDECLARED_DIR%%\\%s" >nul
)

if /I "%%PAYLOADS_IN_FILES%%"=="true" if not "%%UNDECLARED_DIR%%"=="" (
  if not exist "%%HELPER%%" (
    echo orch_go_test: CI Visibility capture helper not found: %%HELPER%% 1>&2
    exit /b 1
  )

  set "CAPTURE_DIR=%%UNDECLARED_DIR%%\\.dd_topt_capture"
  if not exist "%%CAPTURE_DIR%%" mkdir "%%CAPTURE_DIR%%" >nul 2>&1
  set "CAPTURE_PORT_FILE=%%CAPTURE_DIR%%\\capture_port_%%RANDOM%%_%%RANDOM%%.txt"
  set "CAPTURE_STOP_FILE=%%CAPTURE_DIR%%\\capture_stop_%%RANDOM%%_%%RANDOM%%.txt"
  set "UPSTREAM_URL=%%DD_TRACE_AGENT_URL%%"
  if "%%UPSTREAM_URL%%"=="" set "UPSTREAM_URL=http://localhost:8126"

  start "" /B "%%HELPER%%" --port-file "%%CAPTURE_PORT_FILE%%" --stop-file "%%CAPTURE_STOP_FILE%%" --output-dir "%%UNDECLARED_DIR%%" --upstream-url "%%UPSTREAM_URL%%" >nul
  powershell -NoProfile -Command "$portFile = [string]$env:CAPTURE_PORT_FILE; for ($i = 0; $i -lt 100; $i++) { if (Test-Path -LiteralPath $portFile -PathType Leaf) { exit 0 }; Start-Sleep -Milliseconds 100 }; exit 1" >nul
  if errorlevel 1 (
    echo orch_go_test: CI Visibility capture helper failed to publish a port file 1>&2
    exit /b 1
  )
  set /P CAPTURE_PORT=<"%%CAPTURE_PORT_FILE%%"
  set "DD_TRACE_AGENT_URL=http://127.0.0.1:%%CAPTURE_PORT%%"
  set "DD_CIVISIBILITY_AGENTLESS_ENABLED=false"
  set "DD_CIVISIBILITY_AGENTLESS_URL="
)

"%%ACTUAL%%" %%*
set "EXITCODE=%%ERRORLEVEL%%"
if not "%%CAPTURE_STOP_FILE%%"=="" (
  type nul > "%%CAPTURE_STOP_FILE%%" 2>nul
  powershell -NoProfile -Command "Start-Sleep -Milliseconds 500" >nul
)
if not "%%CAPTURE_PORT_FILE%%"=="" del /Q "%%CAPTURE_PORT_FILE%%" >nul 2>nul
if not "%%CAPTURE_STOP_FILE%%"=="" del /Q "%%CAPTURE_STOP_FILE%%" >nul 2>nul
exit /b %%EXITCODE%%
""" % (
        actual_filename.replace("/", "\\"),
        helper_filename.replace("/", "\\"),
        _BAZEL_TARGET_METADATA_OUTPUT,
    )

def _orch_go_test_impl(ctx):
    dep_exe, dep_runfiles = _dep_exec_and_runfiles(ctx.attr.actual)
    dep_run_environment = _dep_run_environment_info(ctx.attr.actual)
    helper_exe = ctx.executable._ci_visibility_capture
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    out = ctx.actions.declare_file(_select_wrapper_output_name(ctx.label.name, dep_exe.basename, is_windows))
    actual_out = ctx.actions.declare_file(_wrapped_actual_output_name(ctx.label.name, dep_exe.basename), sibling = out)
    helper_out = ctx.actions.declare_file(_wrapped_helper_output_name(ctx.label.name, helper_exe.basename), sibling = out)

    # Materialize the raw test binary next to the wrapper so the launcher does
    # not have to guess which configuration-specific execroot path Bazel chose.
    ctx.actions.symlink(output = actual_out, target_file = dep_exe)
    # Materialize the helper binary next to the wrapper so the launcher can
    # start CI Visibility capture without relying on runfile path probing.
    ctx.actions.symlink(output = helper_out, target_file = helper_exe)
    ctx.actions.write(
        output = out,
        content = _windows_wrapper_content(actual_out.basename, helper_out.basename) if is_windows else _unix_wrapper_content(actual_out.basename, helper_out.basename),
        is_executable = True,
    )
    providers = [DefaultInfo(
        files = depset([out, actual_out, helper_out]),
        runfiles = dep_runfiles.merge(ctx.runfiles(files = [actual_out, helper_out])),
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
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
        "_ci_visibility_capture": attr.label(
            default = "//tools/dd_topt_ci_visibility_capture:ci_visibility_capture",
            executable = True,
            cfg = "target",
            doc = "Helper binary that captures tracer CI Visibility uploads into Bazel test.outputs files.",
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    test = True,
)

select_wrapper_output_name_for_tests = _select_wrapper_output_name
