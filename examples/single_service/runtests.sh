#!/usr/bin/env bash
set -euo pipefail

echo "--- non-hermetic run"
bazel test //src/go-project/... --test_output=streamed --test_arg=-test.v --sandbox_debug

echo "--- hermetic run"
bazel test //src/go-project/... --test_output=streamed --test_arg=-test.v --sandbox_debug --config=hermetic

