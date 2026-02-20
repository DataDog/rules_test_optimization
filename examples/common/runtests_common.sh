#!/usr/bin/env bash
set -euo pipefail

# Handle run example runtests behavior.
run_example_runtests() {
  local script_dir="$1"
  local bazelw
  local test_status=0
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

  echo "--- uploading payloads"
  # Requires DD_API_KEY and DD_SITE environment variables.
  if ! DD_API_KEY="${DD_API_KEY:-}" DD_SITE="${DD_SITE:-datadoghq.com}" run_cmd "${bazelw}" run //:dd_upload_payloads; then
    echo "warning: payload upload failed; preserving test exit code (${test_status})." >&2
  fi

  # Preserve the test exit code even if uploads fail.
  return "$test_status"
}
