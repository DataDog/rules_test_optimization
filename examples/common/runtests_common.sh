#!/usr/bin/env bash
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
  bazelw="${script_dir}/../../bazelw"

  cd "$script_dir"

  # Handle run cmd behavior.
  run_cmd() {
    if [[ "${RUNTESTS_DRY_RUN:-0}" == "1" ]]; then
      echo "[dry-run] $*"
      return 0
    fi
    "$@"
  }

  echo "--- non-hermetic run"
  run_cmd "${bazelw}" test //src/go-project/... --test_output=streamed --test_arg=-test.v --sandbox_debug || test_status=$?

  echo "--- hermetic run"
  run_cmd "${bazelw}" test //src/go-project/... --test_output=streamed --test_arg=-test.v --sandbox_debug --config=hermetic || test_status=$?

  echo "--- validating payloads"
  run_cmd "${bazelw}" run //:dd_test_optimization_doctor || doctor_status=$?
  if [[ "$doctor_status" -ne 0 ]]; then
    if [[ "$test_status" -ne 0 ]]; then
      return "$test_status"
    fi
    return "$doctor_status"
  fi

  echo "--- validating upload enrichment"
  run_cmd "${bazelw}" run //:dd_upload_payloads -- --dry-run --validate-enrichment || dry_run_status=$?
  if [[ "$dry_run_status" -ne 0 ]]; then
    if [[ "$test_status" -ne 0 ]]; then
      return "$test_status"
    fi
    return "$dry_run_status"
  fi

  echo "--- uploading payloads"
  # Requires DD_API_KEY and DD_SITE environment variables.
  DD_API_KEY="${DD_API_KEY:-}" DD_SITE="${DD_SITE:-datadoghq.com}" run_cmd "${bazelw}" run //:dd_upload_payloads || upload_status=$?

  if [[ "$test_status" -ne 0 ]]; then
    return "$test_status"
  fi
  return "$upload_status"
}
