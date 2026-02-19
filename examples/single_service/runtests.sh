#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
BAZELW="${SCRIPT_DIR}/../../bazelw"

run_cmd() {
  if [[ "${RUNTESTS_DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] $*"
    return 0
  fi
  "$@"
}

test_status=0

echo "--- non-hermetic run"
run_cmd "${BAZELW}" test //src/go-project/... --test_output=streamed --test_arg=-test.v --sandbox_debug || test_status=$?

echo "--- hermetic run"
run_cmd "${BAZELW}" test //src/go-project/... --test_output=streamed --test_arg=-test.v --sandbox_debug --config=hermetic || test_status=$?

echo "--- uploading payloads"
# Requires DD_API_KEY and DD_SITE environment variables
if ! DD_API_KEY="${DD_API_KEY:-}" DD_SITE="${DD_SITE:-datadoghq.com}" run_cmd "${BAZELW}" run //:dd_upload_payloads; then
  echo "warning: payload upload failed; preserving test exit code (${test_status})." >&2
fi

# Preserve the test exit code even if uploads fail.
exit $test_status
