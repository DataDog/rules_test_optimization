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
    """Return the wrapper-owned sibling executable name used on Unix."""
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

def _windows_wrapper_content(actual_runfile, metadata_runfile):
    """Render the Windows launcher used by wrapped non-Go test targets."""
    return """@echo off
setlocal
set "SCRIPT_DIR=%%~dp0"
set "ACTUAL_RLOC=%s"
set "META_RLOC=%s"
set "META_BASENAME=%%DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME%%"
set "UNDECLARED_DIR=%%TEST_UNDECLARED_OUTPUTS_DIR%%"

call :resolve_runfile "%%ACTUAL_RLOC%%"
if not defined ACTUAL (
  echo topt_test_wrapper: wrapped test executable not found: %%ACTUAL_RLOC%% 1>&2
  exit /b 1
)

if "%%META_BASENAME%%"=="" goto :skip_metadata_copy
if "%%UNDECLARED_DIR%%"=="" goto :skip_metadata_copy
call :resolve_metadata "%%META_RLOC%%"
if not defined META_SOURCE set "META_SOURCE=%%SCRIPT_DIR%%%%META_BASENAME%%"
if exist "%%META_SOURCE%%" copy /Y "%%META_SOURCE%%" "%%UNDECLARED_DIR%%\\%s" >nul
:skip_metadata_copy

rem rules_dotnet uses batch launchers on Windows, which must be invoked via
rem CALL so control returns here and Bazel sees the real exit code.
for %%%%I in ("%%ACTUAL%%") do set "ACTUAL_EXT=%%%%~xI"
if /I "%%ACTUAL_EXT%%"==".bat" goto :run_batch
if /I "%%ACTUAL_EXT%%"==".cmd" goto :run_batch

"%%ACTUAL%%" %%*
set "EXITCODE=%%ERRORLEVEL%%"
exit /b %%EXITCODE%%

:run_batch
call "%%ACTUAL%%" %%*
set "EXITCODE=%%ERRORLEVEL%%"
exit /b %%EXITCODE%%

:resolve_runfile
set "ACTUAL="
set "INPUT=%%~1"
if "%%INPUT%%"=="" goto :eof
call :try_runfile "%%INPUT%%"
if defined ACTUAL goto :eof

if /I "%%INPUT:~0,9%%"=="external/" (
  set "ALT=%%INPUT:~9%%"
  call :try_runfile "%%ALT%%"
  if defined ACTUAL goto :eof
) else (
  call :try_runfile "external/%%INPUT%%"
  if defined ACTUAL goto :eof
)

if /I not "%%INPUT:~0,6%%"=="_main/" (
  call :try_runfile "_main/%%INPUT%%"
)
goto :eof

:try_runfile
set "CAND=%%~1"
if "%%CAND%%"=="" goto :eof
set "CAND_PATH=%%CAND:/=\\%%"

if not "%%RUNFILES_DIR%%"=="" if exist "%%RUNFILES_DIR%%\\%%CAND_PATH%%" (
  set "ACTUAL=%%RUNFILES_DIR%%\\%%CAND_PATH%%"
  goto :eof
)

if exist "%%~f0.runfiles\\%%CAND_PATH%%" (
  set "ACTUAL=%%~f0.runfiles\\%%CAND_PATH%%"
  goto :eof
)

if not "%%RUNFILES_MANIFEST_FILE%%"=="" if exist "%%RUNFILES_MANIFEST_FILE%%" (
  for /f "usebackq tokens=1,* delims= " %%%%A in ("%%RUNFILES_MANIFEST_FILE%%") do (
    if "%%%%A"=="%%CAND%%" (
      set "ACTUAL=%%%%B"
      goto :eof
    )
  )
)
goto :eof

:resolve_metadata
set "META_SOURCE="
set "INPUT=%%~1"
if "%%INPUT%%"=="" goto :eof
call :try_metadata "%%INPUT%%"
if defined META_SOURCE goto :eof

if /I "%%INPUT:~0,9%%"=="external/" (
  set "ALT=%%INPUT:~9%%"
  call :try_metadata "%%ALT%%"
  if defined META_SOURCE goto :eof
) else (
  call :try_metadata "external/%%INPUT%%"
  if defined META_SOURCE goto :eof
)

if /I not "%%INPUT:~0,6%%"=="_main/" (
  call :try_metadata "_main/%%INPUT%%"
)
goto :eof

:try_metadata
set "CAND=%%~1"
if "%%CAND%%"=="" goto :eof
set "CAND_PATH=%%CAND:/=\\%%"

if not "%%RUNFILES_DIR%%"=="" if exist "%%RUNFILES_DIR%%\\%%CAND_PATH%%" (
  set "META_SOURCE=%%RUNFILES_DIR%%\\%%CAND_PATH%%"
  goto :eof
)

if exist "%%~f0.runfiles\\%%CAND_PATH%%" (
  set "META_SOURCE=%%~f0.runfiles\\%%CAND_PATH%%"
  goto :eof
)

if not "%%RUNFILES_MANIFEST_FILE%%"=="" if exist "%%RUNFILES_MANIFEST_FILE%%" (
  for /f "usebackq tokens=1,* delims= " %%%%A in ("%%RUNFILES_MANIFEST_FILE%%") do (
    if "%%%%A"=="%%CAND%%" (
      set "META_SOURCE=%%%%B"
      goto :eof
    )
  )
)
goto :eof
""" % (
        actual_runfile.replace("\\", "/"),
        metadata_runfile.replace("\\", "/"),
        _BAZEL_TARGET_METADATA_OUTPUT,
    )

def _topt_test_wrapper_impl(ctx):
    """Expose a raw test executable through a metadata-copying public wrapper."""
    dep_exe, dep_runfiles = _dep_exec_and_runfiles(ctx.attr.actual)
    dep_run_environment = _dep_run_environment_info(ctx.attr.actual)
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    out = ctx.actions.declare_file(_select_wrapper_output_name(ctx.label.name, dep_exe.basename, is_windows))
    actual_files = []
    wrapper_runfiles = ctx.runfiles(files = [ctx.file.metadata])

    if is_windows:
        actual_filename = dep_exe.short_path
    else:
        actual_out = ctx.actions.declare_file(_wrapped_actual_output_name(ctx.label.name, dep_exe.basename), sibling = out)

        # Materialize the raw executable inside the wrapper runfiles tree so
        # Unix launchers can execute a stable sibling path from TEST_SRCDIR.
        ctx.actions.symlink(output = actual_out, target_file = dep_exe)
        actual_filename = actual_out.basename
        actual_files.append(actual_out)
        wrapper_runfiles = wrapper_runfiles.merge(ctx.runfiles(files = [actual_out]))

    ctx.actions.write(
        output = out,
        # Windows Python launchers require the executable basename to stay
        # aligned with their sibling zip file, while Unix launchers need a
        # wrapper-owned runfiles sibling to avoid execroot path guessing.
        content = _windows_wrapper_content(actual_filename, ctx.file.metadata.short_path) if is_windows else _unix_wrapper_content(actual_filename),
        is_executable = True,
    )

    providers = [DefaultInfo(
        files = depset([out] + actual_files),
        runfiles = dep_runfiles.merge(wrapper_runfiles),
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
render_windows_wrapper_content_for_tests = _windows_wrapper_content
