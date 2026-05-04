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
            '  "context_manifest_short_path": %s,' % json.encode(context_manifest.short_path),
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

RUNFILES_WORKSPACE="%s"

runfile_candidates() {
  local raw="$1"
  local stripped="$raw"

  printf '%%s\\n' "$raw"

  while [[ "$stripped" == ../* ]]; do
    stripped="${stripped#../}"
    printf '%%s\\n' "$stripped"
  done

  if [[ "$raw" == external/* ]]; then
    printf '%%s\\n' "${raw#external/}"
  fi
  if [[ "$stripped" == external/* ]]; then
    printf '%%s\\n' "${stripped#external/}"
  fi
}

resolve_runfile() {
  local raw candidate manifest_key manifest_path
  local all_candidates=()

  for raw in "$@"; do
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      all_candidates+=("$candidate")

      if [[ -f "$candidate" ]]; then
        printf '%%s\\n' "$candidate"
        return 0
      fi
      if [[ -n "${RUNFILES_DIR:-}" && -f "$RUNFILES_DIR/$candidate" ]]; then
        printf '%%s\\n' "$RUNFILES_DIR/$candidate"
        return 0
      fi
      if [[ -n "${RUNFILES_DIR:-}" && -n "$RUNFILES_WORKSPACE" && -f "$RUNFILES_DIR/$RUNFILES_WORKSPACE/$candidate" ]]; then
        printf '%%s\\n' "$RUNFILES_DIR/$RUNFILES_WORKSPACE/$candidate"
        return 0
      fi
      if [[ -f "$0.runfiles/$candidate" ]]; then
        printf '%%s\\n' "$0.runfiles/$candidate"
        return 0
      fi
      if [[ -n "$RUNFILES_WORKSPACE" && -f "$0.runfiles/$RUNFILES_WORKSPACE/$candidate" ]]; then
        printf '%%s\\n' "$0.runfiles/$RUNFILES_WORKSPACE/$candidate"
        return 0
      fi
    done < <(runfile_candidates "$raw")
  done

  if [[ -n "${RUNFILES_MANIFEST_FILE:-}" && -f "$RUNFILES_MANIFEST_FILE" ]]; then
    while IFS= read -r manifest_line; do
      manifest_key="${manifest_line%% *}"
      manifest_path="${manifest_line#* }"
      if [[ "$manifest_key" == "$manifest_line" ]]; then
        continue
      fi
      for candidate in "${all_candidates[@]}"; do
        if [[ "$manifest_key" == "$candidate" || ( -n "$RUNFILES_WORKSPACE" && "$manifest_key" == "$RUNFILES_WORKSPACE/$candidate" ) ]]; then
          printf '%%s\\n' "$manifest_path"
          return 0
        fi
      done
    done < "$RUNFILES_MANIFEST_FILE"
  fi

  return 1
}

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
RUNTIME_PATH="$(resolve_runfile "%s" "%s")" || {
  echo "[dd-test-optimization-doctor] could not resolve doctor runtime from runfiles" >&2
  exit 2
}
CONFIG_PATH="$(resolve_runfile "%s" "%s")" || {
  echo "[dd-test-optimization-doctor] could not resolve doctor config from runfiles" >&2
  exit 2
}
export DD_TEST_OPTIMIZATION_DOCTOR_RUNFILES_WORKSPACE="$RUNFILES_WORKSPACE"
exec "$PYTHON_BIN" "$RUNTIME_PATH" --config "$CONFIG_PATH"
""" % (ctx.workspace_name, ctx.file._runtime.path, ctx.file._runtime.short_path, config_file.path, config_file.short_path),
    )

    ps_file = ctx.actions.declare_file(ctx.label.name + ".ps1")
    ctx.actions.write(
        output = ps_file,
        content = """$ErrorActionPreference = "Stop"
$RunfilesWorkspace = "%s"

function Get-RunfileCandidates([string]$Raw) {
  $candidates = New-Object System.Collections.Generic.List[string]
  $candidates.Add($Raw)

  $stripped = $Raw
  while ($stripped.StartsWith("../")) {
    $stripped = $stripped.Substring(3)
    $candidates.Add($stripped)
  }

  if ($Raw.StartsWith("external/")) {
    $candidates.Add($Raw.Substring(9))
  }
  if ($stripped.StartsWith("external/")) {
    $candidates.Add($stripped.Substring(9))
  }

  return $candidates
}

function Resolve-Runfile([string[]]$RawPaths) {
  $allCandidates = New-Object System.Collections.Generic.List[string]
  $scriptRunfiles = "$PSCommandPath.runfiles"

  foreach ($raw in $RawPaths) {
    foreach ($candidate in Get-RunfileCandidates $raw) {
      if ([string]::IsNullOrWhiteSpace($candidate)) {
        continue
      }
      $allCandidates.Add($candidate)

      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
      }
      if ($env:RUNFILES_DIR) {
        $path = Join-Path $env:RUNFILES_DIR $candidate
        if (Test-Path -LiteralPath $path -PathType Leaf) {
          return (Resolve-Path -LiteralPath $path).Path
        }
        if ($RunfilesWorkspace) {
          $workspacePath = Join-Path (Join-Path $env:RUNFILES_DIR $RunfilesWorkspace) $candidate
          if (Test-Path -LiteralPath $workspacePath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $workspacePath).Path
          }
        }
      }
      if (Test-Path -LiteralPath $scriptRunfiles -PathType Container) {
        $path = Join-Path $scriptRunfiles $candidate
        if (Test-Path -LiteralPath $path -PathType Leaf) {
          return (Resolve-Path -LiteralPath $path).Path
        }
        if ($RunfilesWorkspace) {
          $workspacePath = Join-Path (Join-Path $scriptRunfiles $RunfilesWorkspace) $candidate
          if (Test-Path -LiteralPath $workspacePath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $workspacePath).Path
          }
        }
      }
    }
  }

  if ($env:RUNFILES_MANIFEST_FILE -and (Test-Path -LiteralPath $env:RUNFILES_MANIFEST_FILE -PathType Leaf)) {
    foreach ($line in Get-Content -LiteralPath $env:RUNFILES_MANIFEST_FILE) {
      $parts = $line -split " ", 2
      if ($parts.Length -ne 2) {
        continue
      }
      foreach ($candidate in $allCandidates) {
        if ($parts[0] -eq $candidate -or ($RunfilesWorkspace -and $parts[0] -eq "$RunfilesWorkspace/$candidate")) {
          return $parts[1]
        }
      }
    }
  }

  return $null
}

$PythonBin = $env:PYTHON
if (-not $PythonBin) {
  $cmd = Get-Command python -ErrorAction SilentlyContinue
  if (-not $cmd) {
    Write-Error "[dd-test-optimization-doctor] python is required to run the optional doctor"
    exit 2
  }
  $PythonBin = $cmd.Source
}
$RuntimePath = Resolve-Runfile @("%s", "%s")
if (-not $RuntimePath) {
  Write-Error "[dd-test-optimization-doctor] could not resolve doctor runtime from runfiles"
  exit 2
}
$ConfigPath = Resolve-Runfile @("%s", "%s")
if (-not $ConfigPath) {
  Write-Error "[dd-test-optimization-doctor] could not resolve doctor config from runfiles"
  exit 2
}
$env:DD_TEST_OPTIMIZATION_DOCTOR_RUNFILES_WORKSPACE = $RunfilesWorkspace
& $PythonBin $RuntimePath --config $ConfigPath
exit $LASTEXITCODE
""" % (
            ctx.workspace_name,
            ctx.file._runtime.path.replace("\\", "\\\\"),
            ctx.file._runtime.short_path.replace("\\", "\\\\"),
            config_file.path.replace("\\", "\\\\"),
            config_file.short_path.replace("\\", "\\\\"),
        ),
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
