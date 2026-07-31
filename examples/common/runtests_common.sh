#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

set -euo pipefail

# This helper currently exercises Go example targets only.
# Use `bazel test //examples/...` to run the full multi-language examples matrix.

# Handle run example runtests behavior.
run_example_runtests() {
  local script_dir="$1"
  local bazelw
  local test_status=0
  local doctor_status=0
  local dry_run_status=0
  local upload_status=0
  local tmp_root
  local artifact_staging_dir
  bazelw="${script_dir}/../../bazelw"

  cd "$script_dir"
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/dd-topt-example.XXXXXX")"
  artifact_staging_dir="${tmp_root}/bep-artifacts"
  mkdir -p "$artifact_staging_dir"
  local non_hermetic_bep="${tmp_root}/non-hermetic.bep.json"
  local hermetic_bep="${tmp_root}/hermetic.bep.json"
  local bep_args=(
    "--bep-json=${non_hermetic_bep}"
    "--bep-json=${hermetic_bep}"
    "--freshness-source=bep"
    "--freshness-mode=required"
    "--artifact-source=bep"
    "--artifact-staging-dir=${artifact_staging_dir}"
  )
  trap "rm -rf $(printf '%q' "$tmp_root")" EXIT

  # Handle run cmd behavior.
  run_cmd() {
    if [[ "${RUNTESTS_DRY_RUN:-0}" == "1" ]]; then
      local arg
      local has_test_optimization_config=0
      for arg in "$@"; do
        if [[ "$arg" == "--config=test-optimization" ]]; then
          has_test_optimization_config=1
          break
        fi
      done
      if [[ "$has_test_optimization_config" -ne 1 ]]; then
        echo "error: dry-run command is missing --config=test-optimization: $*" >&2
        return 1
      fi
      echo "[dry-run] $*"
      return 0
    fi
    "$@"
  }

  echo "--- non-hermetic run"
  run_cmd "${bazelw}" test --config=test-optimization //src/go-project/... --test_output=streamed --test_arg=-test.v --sandbox_debug --remote_download_minimal --remote_download_regex=.*test[.]outputs.* --zip_undeclared_test_outputs --build_event_json_file="$non_hermetic_bep" || test_status=$?

  echo "--- hermetic run"
  run_cmd "${bazelw}" test --config=test-optimization --config=hermetic //src/go-project/... --test_output=streamed --test_arg=-test.v --sandbox_debug --remote_download_minimal --remote_download_regex=.*test[.]outputs.* --zip_undeclared_test_outputs --build_event_json_file="$hermetic_bep" || test_status=$?

  echo "--- validating payloads"
  run_cmd "${bazelw}" run --config=test-optimization //:dd_test_optimization_doctor -- "${bep_args[@]}" || doctor_status=$?
  if [[ "$doctor_status" -ne 0 ]]; then
    if [[ "$test_status" -ne 0 ]]; then
      return "$test_status"
    fi
    return "$doctor_status"
  fi

  echo "--- validating upload enrichment"
  run_cmd "${bazelw}" run --config=test-optimization //:dd_upload_payloads -- "${bep_args[@]}" --dry-run --validate-enrichment || dry_run_status=$?
  if [[ "$dry_run_status" -ne 0 ]]; then
    if [[ "$test_status" -ne 0 ]]; then
      return "$test_status"
    fi
    return "$dry_run_status"
  fi

  echo "--- uploading payloads"
  # Requires DD_API_KEY and DD_SITE environment variables.
  DD_API_KEY="${DD_API_KEY:-}" DD_SITE="${DD_SITE:-datadoghq.com}" run_cmd "${bazelw}" run --config=test-optimization //:dd_upload_payloads -- "${bep_args[@]}" || upload_status=$?

  if [[ "$test_status" -ne 0 ]]; then
    return "$test_status"
  fi
  return "$upload_status"
}
