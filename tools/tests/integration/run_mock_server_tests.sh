#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_WS="$(mktemp -d)"
LOG_FILE="$TMP_WS/mock.log"
SERVER_OUT="$TMP_WS/server.out"

export REPO_ROOT
export LOG_FILE

if [[ "${KEEP_TMP:-0}" == "1" ]]; then
  echo "KEEP_TMP=1: temp workspace at $TMP_WS"
fi

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${TMP_WS:-}" && -d "$TMP_WS" && "${KEEP_TMP:-0}" != "1" ]]; then
    chmod -R u+w "$TMP_WS" 2>/dev/null || true
    rm -rf "$TMP_WS"
  fi
}
trap cleanup EXIT

python3 -u "$REPO_ROOT/tools/tests/integration/mock_dd_server.py" \
  --fixtures "$REPO_ROOT/tools/tests/integration/fixtures" \
  --log "$LOG_FILE" \
  --port 0 >"$SERVER_OUT" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 50); do
  if grep -q "^PORT=" "$SERVER_OUT"; then
    PORT="$(grep '^PORT=' "$SERVER_OUT" | head -n1 | cut -d= -f2)"
    break
  fi
  sleep 0.1
done

if [[ -z "$PORT" ]]; then
  echo "error: mock server did not start"
  cat "$SERVER_OUT" || true
  exit 1
fi

WORKSPACE="$TMP_WS/ws"
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

ESCAPED_REPO_ROOT=$(python3 - <<'PY'
import json
import os
print(json.dumps(os.environ["REPO_ROOT"]))
PY
)

cat > MODULE.bazel <<MODULE_EOF
module(name = "topt-integration", version = "0.0.0")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = ${ESCAPED_REPO_ROOT},
)

test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
    service = "mock-service",
    runtime_name = "go",
    runtime_version = "1.2.3",
)

use_repo(test_optimization_sync, "test_optimization_data")
MODULE_EOF

cat > BUILD.bazel <<BUILD_EOF
load("@datadog-rules-test-optimization//tools:test_optimization_uploader.bzl", "dd_payload_uploader")

sh_test(
    name = "write_payloads_test",
    srcs = ["payload_writer.sh"],
    size = "small",
    timeout = "short",
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
BUILD_EOF

cat > payload_writer.sh <<'PAYLOAD_EOF'
#!/usr/bin/env bash
set -euo pipefail

out="${TEST_UNDECLARED_OUTPUTS_DIR:?}"
mkdir -p "$out/tests" "$out/coverage"
echo '{"test":true}' > "$out/tests/test1.json"
echo '{}' > "$out/coverage/cov1.json"
PAYLOAD_EOF
chmod +x payload_writer.sh

BAZEL="$REPO_ROOT/bazelw"
OUT_BASE="$TMP_WS/.bazel_out"
BAZEL_FLAGS=(--output_base="$OUT_BASE")

"$BAZEL" "${BAZEL_FLAGS[@]}" build @test_optimization_data//:test_optimization_files \
  --repo_env=DD_API_KEY=mock \
  --repo_env=DD_TOPT_API_BASE=http://127.0.0.1:$PORT

CQUERY_OUT=$("$BAZEL" "${BAZEL_FLAGS[@]}" cquery @test_optimization_data//:test_optimization_files --output=files \
  --repo_env=DD_API_KEY=mock \
  --repo_env=DD_TOPT_API_BASE=http://127.0.0.1:$PORT)

SETTINGS_PATH=$(echo "$CQUERY_OUT" | grep '/.testoptimization/settings.json$' | head -n1 || true)
if [[ -z "$SETTINGS_PATH" ]]; then
  echo "error: failed to resolve settings.json path"
  echo "$CQUERY_OUT"
  exit 1
fi

if [[ "$SETTINGS_PATH" != /* ]]; then
  if [[ -f "$OUT_BASE/$SETTINGS_PATH" ]]; then
    SETTINGS_PATH="$OUT_BASE/$SETTINGS_PATH"
  elif [[ -f "$WORKSPACE/$SETTINGS_PATH" ]]; then
    SETTINGS_PATH="$WORKSPACE/$SETTINGS_PATH"
  fi
fi

if [[ ! -f "$SETTINGS_PATH" ]]; then
  echo "error: settings.json not found at resolved path: $SETTINGS_PATH"
  echo "$CQUERY_OUT"
  exit 1
fi

TOPT_DIR="$(dirname "$SETTINGS_PATH")"
for name in settings.json known_tests.json test_management.json manifest.txt; do
  if [[ ! -f "$TOPT_DIR/$name" ]]; then
    echo "error: missing $name in $TOPT_DIR"
    exit 1
  fi
done

EXPORT_PATH="$(dirname "$TOPT_DIR")/export.bzl"
if [[ ! -f "$EXPORT_PATH" ]]; then
  echo "error: missing export.bzl at $EXPORT_PATH"
  exit 1
fi

unset DD_TRACE_AGENT_URL

"$BAZEL" "${BAZEL_FLAGS[@]}" test //:write_payloads_test \
  --repo_env=DD_API_KEY=mock \
  --repo_env=DD_TOPT_API_BASE=http://127.0.0.1:$PORT

TESTLOGS_DIR="$("$BAZEL" "${BAZEL_FLAGS[@]}" info bazel-testlogs)"

TESTLOGS_DIR="$TESTLOGS_DIR" \
DD_API_KEY=mock \
DD_TOPT_INTAKE_BASE="http://127.0.0.1:$PORT" \
DD_TOPT_MAX_WAIT_SEC=30 \
DD_TOPT_QUIESCENT_SEC=1 \
DD_TRACE_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  --repo_env=DD_API_KEY=mock \
  --repo_env=DD_TOPT_API_BASE=http://127.0.0.1:$PORT

python3 - <<'PY'
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
required = {
    "/api/v2/libraries/tests/services/setting",
    "/api/v2/ci/libraries/tests",
    "/api/v2/test/libraries/test-management/tests",
    "/api/v2/citestcycle",
    "/api/v2/citestcov",
}
seen = set()
with open(log_path, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            record = json.loads(line)
        except Exception:
            continue
        path = record.get("path")
        if path:
            seen.add(path)
missing = required - seen
if missing:
    print("error: missing endpoints:")
    for item in sorted(missing):
        print("  - %s" % item)
    sys.exit(1)
PY
