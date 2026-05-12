#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

set -euo pipefail

# This helper measures cold hermetic action execution after the repository and
# bootstrap state has already been populated in the workspace output base.
# It does not measure first-time repository-rule bootstrap or toolchain download
# cost. The output is a small sentinel benchmark for regression detection, not a
# full characterization of large downstream targets.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MODE=""
BAZEL_VERSION="${BAZEL_VERSION:-$(tr -d '[:space:]' < "$REPO_ROOT/.bazelversion")}"

usage() {
  cat >&2 <<'EOF'
usage: measure_orchestrion_hello_test_perf.sh --mode=workspace|bzlmod
EOF
  exit 2
}

for arg in "$@"; do
  case "$arg" in
    --mode=workspace)
      MODE="workspace"
      ;;
    --mode=bzlmod)
      MODE="bzlmod"
      ;;
    *)
      usage
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  usage
fi

measure_json="$(mktemp "${TMPDIR:-/tmp}/orchestrion-measure.${MODE}.XXXXXX.json")"
cleanup() {
  rm -f "$measure_json"
}
trap cleanup EXIT INT TERM HUP

case "$MODE" in
  workspace)
    INTEGRATION_SCENARIO_MODE=measure \
    MEASURE_OUTPUT_PATH="$measure_json" \
    USE_BAZEL_VERSION="$BAZEL_VERSION" \
    "$REPO_ROOT/tools/tests/integration/run_workspace_go_integration.sh" >/dev/null
    ;;
  bzlmod)
    INTEGRATION_SCENARIO_MODE=measure \
    MEASURE_OUTPUT_PATH="$measure_json" \
    USE_BAZEL_VERSION="$BAZEL_VERSION" \
    "$REPO_ROOT/tools/tests/integration/run_bzlmod_go_integration.sh" >/dev/null
    ;;
esac

cat "$measure_json"
