#!/usr/bin/env bash
set -euo pipefail

echo "--- non-hermetic run"
bazel test //src/go-project/... --test_output=streamed --test_arg=-test.v --sandbox_debug || test_status=$?
test_status=${test_status:-0}

echo "--- hermetic run"
bazel test //src/go-project/... --test_output=streamed --test_arg=-test.v --sandbox_debug --config=hermetic || test_status=$?
test_status=${test_status:-0}

echo "--- uploading payloads"
# Requires DD_API_KEY and DD_SITE environment variables
DD_API_KEY="${DD_API_KEY:-}" DD_SITE="${DD_SITE:-datadoghq.com}" bazel run //:dd_upload_payloads

exit $test_status

