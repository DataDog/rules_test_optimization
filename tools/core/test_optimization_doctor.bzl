"""Doctor rule for validating Datadog Test Optimization Bazel outputs."""

load(
    "//tools/core:common_utils.bzl",
    "fail_with_prefix",
)
load(
    "//tools/core:test_optimization_context_utils.bzl",
    "context_manifest_content",
    "context_manifest_entries_or_fail",
)

_OWNER = "test_optimization_doctor"

def _json_bool(value):
    """Render a Starlark boolean as JSON."""
    return "true" if value else "false"

def _json_string_list(values):
    """Render a list of strings as JSON."""
    return json.encode(values)

def _validate_expected_targets(expected_targets):
    """Validate expected target labels while still at analysis time."""
    for label in expected_targets:
        if label.startswith("@"):
            fail_with_prefix(_OWNER, "expected_targets only supports local workspace labels, got %r" % label)
        if not label.startswith("//") or ":" not in label:
            fail_with_prefix(_OWNER, "expected_targets entries must look like //pkg:target or //:target, got %r" % label)

def _doctor_impl(ctx):
    """Generate cross-platform doctor launchers."""
    _validate_expected_targets(ctx.attr.expected_targets)

    context_entries = context_manifest_entries_or_fail(ctx.attr.data, ctx.files.data, _OWNER)
    context_manifest = ctx.actions.declare_file(ctx.label.name + ".context_manifest")
    ctx.actions.write(
        output = context_manifest,
        content = context_manifest_content(context_entries),
    )

    config_file = ctx.actions.declare_file(ctx.label.name + ".config.json")
    ctx.actions.write(
        output = config_file,
        content = "\n".join([
            "{",
            '  "context_manifest_path": %s,' % json.encode(context_manifest.path),
            '  "expected_targets": %s,' % _json_string_list(ctx.attr.expected_targets),
            '  "require_git_metadata": %s,' % _json_bool(ctx.attr.require_git_metadata),
            '  "require_bazel_metadata": %s,' % _json_bool(ctx.attr.require_bazel_metadata),
            '  "require_json_payloads": %s,' % _json_bool(ctx.attr.require_json_payloads),
            '  "forbid_full_bundle_no_match": %s,' % _json_bool(ctx.attr.forbid_full_bundle_no_match),
            '  "forbid_dd_git_test_env": %s' % _json_bool(ctx.attr.forbid_dd_git_test_env),
            "}",
            "",
        ]),
    )

    bash_file = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = bash_file,
        is_executable = True,
        content = """#!/usr/bin/env bash
set -euo pipefail
PYTHON_BIN="${PYTHON:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
  else
    echo "[dd-test-optimization-doctor] python3 or python is required to run the optional doctor" >&2
    exit 2
  fi
fi
exec "$PYTHON_BIN" "%s" --config "%s"
""" % (ctx.file._runtime.path, config_file.path),
    )

    ps_file = ctx.actions.declare_file(ctx.label.name + ".ps1")
    ctx.actions.write(
        output = ps_file,
        content = """$ErrorActionPreference = "Stop"
$PythonBin = $env:PYTHON
if (-not $PythonBin) {
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if (-not $cmd) {
    Write-Error "[dd-test-optimization-doctor] python is required to run the optional doctor"
    exit 2
  }
  $PythonBin = $cmd.Source
}
& $PythonBin "%s" --config "%s"
exit $LASTEXITCODE
""" % (ctx.file._runtime.path.replace("\\", "\\\\"), config_file.path.replace("\\", "\\\\")),
    )

    bat_file = ctx.actions.declare_file(ctx.label.name + ".bat")
    ctx.actions.write(
        output = bat_file,
        is_executable = True,
        content = """@echo off
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%s"
exit /b %%ERRORLEVEL%%
""" % ps_file.path,
    )

    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    executable = bat_file if is_windows else bash_file
    runfiles = ctx.runfiles(files = [ctx.file._runtime, context_manifest, config_file, ps_file, bat_file] + ctx.files.data)
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

dd_test_optimization_doctor = rule(
    implementation = _doctor_impl,
    executable = True,
    attrs = {
        "data": attr.label_list(allow_files = True, doc = "Context files, normally @test_optimization_data//:test_optimization_context."),
        "expected_targets": attr.string_list(default = [], doc = "Optional local labels whose bazel-testlogs outputs must be present."),
        "require_git_metadata": attr.bool(default = True, doc = "Require repository URL, commit SHA, and branch/tag in context.json."),
        "require_bazel_metadata": attr.bool(default = True, doc = "Require bazel_target_metadata.json next to payload outputs."),
        "require_json_payloads": attr.bool(default = True, doc = "Require parseable JSON payload files."),
        "forbid_full_bundle_no_match": attr.bool(default = True, doc = "Fail if Go payload selection fell back to full_bundle_no_match."),
        "forbid_dd_git_test_env": attr.bool(default = True, doc = "Fail when .bazelrc injects DD_GIT_* into test environments."),
        "_runtime": attr.label(default = "//tools/core:test_optimization_doctor.py", allow_single_file = True),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    doc = "Validate local Test Optimization payloads and metadata before running the uploader.",
)
