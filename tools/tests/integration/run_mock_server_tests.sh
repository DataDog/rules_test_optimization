#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Integration harness: sync + uploader end-to-end verification
# -----------------------------------------------------------------------------
#
# This script intentionally exercises the repository as a *consumer* by creating
# a temporary Bazel workspace, wiring `local_path_override` to this repo, and
# executing real Bazel targets.
#
# Scenario phases:
# 1) Start local mock Datadog server and collect all requests.
# 2) Generate ephemeral MODULE/BUILD files in a temp workspace.
# 3) Run sync + writer test + uploader and verify API coverage/snapshots.
# 4) Validate malformed sync responses fail with actionable diagnostics.
# 5) Validate multi-service extension wiring + macro service-key resolution.
# 6) Validate CODEOWNERS enrichment behavior (injection, preservation, edge
#    cases, runfiles/execroot normalization).
# 7) Validate EVP-mode uploads (evp_proxy endpoints + EVP headers).
# 8) Force manifest-only runfile fallback and verify context/schema resolution.
#
# Debugging tips:
# - Set KEEP_TMP=1 to inspect the generated temp workspace after failures.
# - Set HARNESS_UPLOADER_DEBUG=1 to force verbose uploader diagnostics.
# - Snapshot updates are opt-in via UPDATE_SNAPSHOTS=1.
#
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_WS="$(mktemp -d "${TMPDIR:-/tmp}/rules_topt_test.XXXXXX")"
# Store server logs + request bodies outside the repo tree for easy cleanup.
LOG_FILE="$TMP_WS/mock.log"
SERVER_OUT="$TMP_WS/server.out"
SNAPSHOT_DIR="$REPO_ROOT/tools/tests/integration/snapshots"
PYTHON="${PYTHON:-python3}"
# Keep the mock-server harness aligned with the supported Orchestrion version
# under test instead of relying on the old hardcoded bootstrap tag.
ORCHESTRION_VERSION="${ORCHESTRION_VERSION:-v1.9.0}"
export ORCHESTRION_VERSION
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON=python
  else
    echo "error: python interpreter not found (tried '$PYTHON' and 'python')"
    exit 1
  fi
fi

export REPO_ROOT
export LOG_FILE
export SNAPSHOT_DIR

REAL_GO_BIN_HOST="${REAL_GO_BIN_HOST:-$(command -v go || true)}"
if [[ -z "$REAL_GO_BIN_HOST" ]]; then
  echo "error: go binary not found for bootstrap integration harness"
  exit 1
fi

RULES_GO_OVERRIDE_REMOTE="$("$PYTHON" - <<'PY' "$REPO_ROOT"
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve().as_uri())
PY
)"
RULES_GO_OVERRIDE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"

if [[ "${KEEP_TMP:-0}" == "1" ]]; then
  echo "KEEP_TMP=1: temp workspace at $TMP_WS"
fi

source "$REPO_ROOT/tools/tests/integration/run_mock_server_tests_lib.sh"
trap cleanup EXIT INT TERM HUP

# Reserve an ephemeral localhost port up front, then start the mock server on it.
# This avoids relying on startup stdout parsing for port discovery.
PORT="$("$PYTHON" - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
if [[ -z "$PORT" ]]; then
  echo "error: failed to reserve a local port for mock server startup"
  exit 1
fi

# Start a mock Datadog API server with fixture responses and request logging.
"$PYTHON" -u "$REPO_ROOT/tools/tests/integration/mock_dd_server.py" \
  --fixtures "$REPO_ROOT/tools/tests/integration/fixtures" \
  --log "$LOG_FILE" \
  --port "$PORT" >"$SERVER_OUT" 2>&1 &
SERVER_PID=$!
SERVER_PID_FILE="$TMP_WS/mock_server.pid"
printf '%s\n' "$SERVER_PID" >"$SERVER_PID_FILE"

# Wait for the server to bind and accept localhost connections.
# Keep this tunable because slower CI workers can need extra startup time.
START_TIMEOUT_SECONDS="${MOCK_SERVER_START_TIMEOUT_SECONDS:-30}"
POLL_INTERVAL_SECONDS="${MOCK_SERVER_POLL_INTERVAL_SECONDS:-0.1}"
START_TS="$(date +%s)"
mock_server_listening() {
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1
    return $?
  fi
  "$PYTHON" - "$PORT" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.2)
try:
    sock.connect(("127.0.0.1", port))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}
while true; do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "error: mock server process died before binding"
    cat "$SERVER_OUT" || true
    exit 1
  fi
  if mock_server_listening; then
    break
  fi
  if (( "$(date +%s)" - START_TS >= START_TIMEOUT_SECONDS )); then
    break
  fi
  sleep "$POLL_INTERVAL_SECONDS"
done

if ! mock_server_listening; then
  echo "error: mock server did not start on port $PORT"
  ps -p "$SERVER_PID" -o pid=,ppid=,stat=,comm=,args= 2>/dev/null || true
  cat "$SERVER_OUT" || true
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for this integration harness (snapshot enrichment assertions)"
  exit 1
fi

# Create a throwaway Bazel workspace to exercise the rules as a consumer.
WORKSPACE="$TMP_WS/ws"
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# Pass an explicit workspace path to uploader runs so CODEOWNERS lookup stays
# stable across platforms/runtimes (especially Bazel 9 on Windows).
WORKSPACE_FOR_UPLOADER="$(to_mixed_path "$WORKSPACE")"
HARNESS_UPLOADER_DEBUG="${HARNESS_UPLOADER_DEBUG:-}"
if [[ -z "$HARNESS_UPLOADER_DEBUG" ]]; then
  HARNESS_UPLOADER_DEBUG=0
fi

# JSON-escape REPO_ROOT for safe insertion into MODULE.bazel.
ESCAPED_REPO_ROOT=$("$PYTHON" - <<'PY'
import json
import os
print(json.dumps(os.environ["REPO_ROOT"]))
PY
)
ESCAPED_MODULES_GO=$("$PYTHON" - <<'PY'
import json
import os
path = os.path.normpath(os.path.join(os.environ["REPO_ROOT"], "modules", "go"))
print(json.dumps(path.replace("\\\\", "/")))
PY
)
ESCAPED_RULES_GO_VENDOR=$("$PYTHON" - <<'PY'
import json
import os
path = os.path.normpath(os.path.join(os.environ["REPO_ROOT"], "third_party", "rules_go_orchestrion_base"))
print(json.dumps(path.replace("\\\\", "/")))
PY
)

# Build a throwaway Bazel workspace in a temp dir so we exercise the rules
# like a real consumer (bzlmod deps + BUILD targets), without adding files
# to this repo.
cat > MODULE.bazel <<MODULE_EOF
module(name = "topt-integration", version = "0.0.0")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "rules_shell", version = "0.6.1")

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = ${ESCAPED_REPO_ROOT},
)

test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
    service = "mock-service",
    runtime_name = "go",
    runtime_version = "1.2.3",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data_nodejs",
    service = "mock-service-nodejs",
    runtime_name = "nodejs",
    runtime_version = "1.2.3",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data_dotnet",
    service = "mock-service-dotnet",
    runtime_name = "dotnet",
    runtime_version = "1.2.3",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data_ruby",
    service = "mock-service-ruby",
    runtime_name = "ruby",
    runtime_version = "1.2.3",
)

use_repo(
    test_optimization_sync,
    "test_optimization_data",
    "test_optimization_data_nodejs",
    "test_optimization_data_dotnet",
    "test_optimization_data_ruby",
)
MODULE_EOF

cat > BUILD.bazel <<BUILD_EOF
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

sh_test(
    name = "write_payloads_test",
    srcs = ["payload_writer.sh"],
    data = ["citestcycle_payload.json"],
    size = "small",
    timeout = "short",
)

dd_payload_uploader(
    name = "dd_upload_payloads",
)

dd_payload_uploader(
    name = "dd_upload_payloads_with_context",
    data = ["@test_optimization_data//:test_optimization_context"],
)

dd_payload_uploader(
    name = "dd_upload_payloads_multi_context",
    data = [
        "@test_optimization_data//:test_optimization_context",
        "@test_optimization_data_nodejs//:test_optimization_context",
    ],
)
BUILD_EOF

cp "$REPO_ROOT/tools/tests/integration/snapshots/citestcycle.json" "$WORKSPACE/citestcycle_template.json"
jq '
  .events |= map(
    if (
      (.type == "test" and ((.content.resource // "") == "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest"))
      or
      (.type == "test_suite_end" and ((.content.resource // "") == "Samples.XUnitTests.TestSuite"))
    ) then
      .content.meta |= (if type == "object" then del(."test.codeowners") else . end)
    else
      .
    end
  )
' "$WORKSPACE/citestcycle_template.json" > "$WORKSPACE/citestcycle_payload.json"

cat > CODEOWNERS <<'CODEOWNERS_EOF'
* @org/default
/tracer/test/test-applications/integrations/Samples.XUnitTests/[Tt]estSuite.cs @DataDog/ci-app-libraries-dotnet
CODEOWNERS_EOF
CODEOWNERS_FOR_UPLOADER="$WORKSPACE/CODEOWNERS"
CODEOWNERS_FOR_UPLOADER="$(to_mixed_path "$CODEOWNERS_FOR_UPLOADER")"

cat > payload_writer.sh <<'PAYLOAD_EOF'
#!/usr/bin/env bash
set -euo pipefail

out="${TEST_UNDECLARED_OUTPUTS_DIR:?}"
mkdir -p "$out/payloads/tests" "$out/payloads/coverage" "$out/payloads/telemetry"
fixture_name="citestcycle_payload.json"

resolve_from_manifest() {
  # Resolve a runfile from RUNFILES_MANIFEST_FILE using:
  # 1) exact key match
  # 2) suffix-key match ("repo-prefix/<key>")
  # and UTF-8 BOM stripping parity with uploader logic.
  local key="$1"
  local manifest="${RUNFILES_MANIFEST_FILE:-}"
  [[ -z "$manifest" || ! -f "$manifest" ]] && return 1
  local path
  path=$(awk -v key="$key" '
    BEGIN { bom = sprintf("%c%c%c", 239, 187, 191) }
    {
      k = $1
      if (NR == 1 && index(k, bom) == 1) {
        k = substr(k, 4)
      }
      if (k == key) {
        print substr($0, length($1) + 2)
        exit
      }
    }
  ' "$manifest")
  if [[ -n "$path" && -f "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  path=$(awk -v key="$key" '
    BEGIN { bom = sprintf("%c%c%c", 239, 187, 191) }
    {
      k = $1
      if (NR == 1 && index(k, bom) == 1) {
        k = substr(k, 4)
      }
      if (length(k) > length(key) && substr(k, length(k) - length(key) + 1) == key) {
        sep = substr(k, length(k) - length(key), 1)
        if (sep == "/" || sep == "\\") {
          print substr($0, length($1) + 2)
          exit
        }
      }
    }
  ' "$manifest")
  if [[ -n "$path" && -f "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  return 1
}

template=""
if [[ -n "${TEST_SRCDIR:-}" ]]; then
  for ws in "${TEST_WORKSPACE:-}" "_main"; do
    [[ -z "$ws" ]] && continue
    candidate="$TEST_SRCDIR/$ws/$fixture_name"
    if [[ -f "$candidate" ]]; then
      template="$candidate"
      break
    fi
  done
  if [[ -z "$template" ]]; then
    candidate="$TEST_SRCDIR/$fixture_name"
    [[ -f "$candidate" ]] && template="$candidate"
  fi
fi

if [[ -z "$template" ]]; then
  for key in "${TEST_WORKSPACE:-}/$fixture_name" "_main/$fixture_name" "$fixture_name"; do
    [[ "$key" == "/$fixture_name" ]] && continue
    candidate=$(resolve_from_manifest "$key" || true)
    if [[ -n "$candidate" ]]; then
      template="$candidate"
      break
    fi
  done
fi

if [[ -z "$template" || ! -f "$template" ]]; then
  template="$(dirname "$0")/$fixture_name"
fi
if [[ ! -f "$template" ]]; then
  echo "error: fixture template not found: $template" >&2
  exit 1
fi

cp "$template" "$out/payloads/tests/test1.json"
cat > "$out/payloads/coverage/cov1.json" <<'JSON_EOF'
{
  "version": "1",
  "files": [
    {
      "filename": "tracer/test/test-applications/integrations/Samples.XUnitTests/TestSuite.cs",
      "segments": [[1, 0, 1, 0, 0]]
    }
  ]
}
JSON_EOF
cat > "$out/payloads/telemetry/telemetry_writer_010.json" <<'JSON_EOF'
{
  "api_version": "v2",
  "request_type": "app-started",
  "runtime_id": "writer-runtime-telemetry",
  "application": {
    "language_name": "go",
    "tracer_version": "1.72.1"
  },
  "payload": {
    "marker": "writer"
  }
}
JSON_EOF
PAYLOAD_EOF
chmod +x payload_writer.sh

BAZEL="$REPO_ROOT/bazelw"
OUT_BASE="$TMP_WS/.bazel_out"
BAZEL_FLAGS=(--output_base="$OUT_BASE")

# Provide deterministic repo metadata for fixtures + payload enrichment.
REPO_ENVS=(
  --repo_env=DD_API_KEY=mock
  --repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL=http://127.0.0.1:$PORT
  --repo_env=DD_ENV=ci
  --repo_env=DD_GIT_REPOSITORY_URL=https://example.com/repo.git
  --repo_env=DD_GIT_BRANCH=main
  --repo_env=DD_GIT_COMMIT_SHA=1111111
  --repo_env=DD_GIT_HEAD_COMMIT=1111111
  --repo_env=DD_GIT_COMMIT_MESSAGE=Test_commit
  --repo_env=DD_GIT_HEAD_MESSAGE=Test_head
  --repo_env=DD_GIT_TAG=v1.0.0
  # Keep the sync preflight bound to the explicit DD_GIT_* fixture metadata.
  --repo_env=GITHUB_SHA=
  --repo_env=GITHUB_EVENT_PATH=
)

# ---------------------------------------------------------------------------
# Scenario: baseline sync + uploader run (agentless) with fixture assertions.
# ---------------------------------------------------------------------------
# This is the "known-good" path. Later scenarios intentionally mutate one
# variable at a time and reuse these repo env defaults.
# Dedicated sync smoke: force a fresh repository-rule sync and verify generated
# labels resolve before any build/test actions consume them.
SYNC_SALT_VALUE="integration-sync-${RANDOM}-$(date +%s)"
"$BAZEL" "${BAZEL_FLAGS[@]}" fetch @test_optimization_data//:test_optimization_files \
  --repo_env=FETCH_SALT="$SYNC_SALT_VALUE" \
  "${REPO_ENVS[@]}"

# Canonical runtime-name preflight for newly supported runtimes.
for runtime in nodejs dotnet ruby; do
  "$BAZEL" "${BAZEL_FLAGS[@]}" fetch "@test_optimization_data_${runtime}//:test_optimization_files" \
    --repo_env=FETCH_SALT="$SYNC_SALT_VALUE" \
    "${REPO_ENVS[@]}"
done

"$BAZEL" "${BAZEL_FLAGS[@]}" query @test_optimization_data//:test_optimization_context \
  "${REPO_ENVS[@]}" >/dev/null

"$BAZEL" "${BAZEL_FLAGS[@]}" build @test_optimization_data//:test_optimization_files \
  "${REPO_ENVS[@]}"

for runtime in nodejs dotnet ruby; do
  "$BAZEL" "${BAZEL_FLAGS[@]}" build "@test_optimization_data_${runtime}//:test_optimization_files" \
    "${REPO_ENVS[@]}"
done

CQUERY_OUT=$("$BAZEL" "${BAZEL_FLAGS[@]}" cquery @test_optimization_data//:test_optimization_files --output=files \
  "${REPO_ENVS[@]}")
EXECROOT="$("$BAZEL" "${BAZEL_FLAGS[@]}" info execution_root "${REPO_ENVS[@]}" 2>/dev/null || true)"
EXECROOT="${EXECROOT//$'\r'/}"

# Resolve settings.json location from cquery output for validation.
# Depending on Bazel output mode/platform, the cquery path can be relative to
# output_base, execution_root, or workspace. Probe each base in order.
SETTINGS_PATH=""
while IFS= read -r candidate; do
  candidate="${candidate//$'\r'/}"
  [[ -z "$candidate" ]] && continue
  if [[ "$candidate" == /* || "$candidate" =~ ^[A-Za-z]:[\\/] ]]; then
    if resolved="$(path_exists "$candidate" 2>/dev/null)"; then
      SETTINGS_PATH="$resolved"
      break
    fi
    continue
  fi
  for base in "$OUT_BASE" "$OUT_BASE/execroot/_main" "$EXECROOT" "$WORKSPACE"; do
    [[ -z "$base" ]] && continue
    base_clean="${base//$'\r'/}"
    joined="${base_clean%/}/$candidate"
    if resolved="$(path_exists "$joined" 2>/dev/null)"; then
      SETTINGS_PATH="$resolved"
      break
    fi
  done
  [[ -n "$SETTINGS_PATH" ]] && break
done < <(printf "%s\n" "$CQUERY_OUT" | "$PYTHON" -c '
import sys

for line in sys.stdin.read().splitlines():
    normalized = line.replace("\\\\", "/")
    if normalized.endswith("/.testoptimization/cache/http/settings.json"):
        print(line)
')

if [[ -z "$SETTINGS_PATH" ]]; then
  echo "error: failed to resolve settings.json path"
  echo "resolution bases:"
  printf '  - %s\n' "$OUT_BASE" "$OUT_BASE/execroot/_main" "$EXECROOT" "$WORKSPACE"
  echo "$CQUERY_OUT"
  exit 1
fi

if [[ ! -f "$SETTINGS_PATH" ]]; then
  echo "error: settings.json not found at resolved path: $SETTINGS_PATH"
  echo "$CQUERY_OUT"
  exit 1
fi

TOPT_HTTP_DIR="$(dirname "$SETTINGS_PATH")"
TOPT_CACHE_DIR="$(dirname "$TOPT_HTTP_DIR")"
TOPT_DIR="$(dirname "$TOPT_CACHE_DIR")"
for name in settings.json known_tests.json test_management.json; do
  if [[ ! -f "$TOPT_HTTP_DIR/$name" ]]; then
    echo "error: missing $name in $TOPT_HTTP_DIR"
    exit 1
  fi
done
for name in manifest.txt context.json; do
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

for runtime in go python java nodejs dotnet ruby; do
  if ! grep -q "\"$runtime\": {" "$EXPORT_PATH"; then
    echo "error: export.bzl missing runtime key '$runtime'"
    exit 1
  fi
done

unset DD_TEST_OPTIMIZATION_AGENT_URL

"$BAZEL" "${BAZEL_FLAGS[@]}" test //:write_payloads_test \
  "${REPO_ENVS[@]}"

# Use Bazel's testlogs location to find payloads for the uploader.
TESTLOGS_DIR="$("$BAZEL" "${BAZEL_FLAGS[@]}" info bazel-testlogs)"

# Scenario: max_wait_sec=0 should skip waiting when no payloads are present.
EMPTY_TESTLOGS_DIR="$TMP_WS/empty_testlogs_nowait"
mkdir -p "$EMPTY_TESTLOGS_DIR"
UPLOADER_NOWAIT_LOG="$TMP_WS/uploader_nowait.log"
NOWAIT_START_EPOCH="$(date +%s)"
if ! TESTLOGS_DIR="$EMPTY_TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_DEBUG="$HARNESS_UPLOADER_DEBUG" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=0 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_NOWAIT_LOG" 2>&1; then
  echo "error: uploader max_wait_sec=0 scenario failed"
  cat "$UPLOADER_NOWAIT_LOG" || true
  exit 1
fi
NOWAIT_ELAPSED_SEC="$(( $(date +%s) - NOWAIT_START_EPOCH ))"
if (( NOWAIT_ELAPSED_SEC > 12 )); then
  echo "error: max_wait_sec=0 scenario exceeded expected duration ($NOWAIT_ELAPSED_SEC s)"
  cat "$UPLOADER_NOWAIT_LOG" || true
  exit 1
fi
if ! grep -q "no payload files found and no test execution detected; nothing to upload" "$UPLOADER_NOWAIT_LOG"; then
  echo "error: max_wait_sec=0 scenario missing expected no-payload message"
  cat "$UPLOADER_NOWAIT_LOG" || true
  exit 1
fi

BASE_UPLOAD_LOG_START="$(log_line_count)"
UPLOADER_LOG="$TMP_WS/uploader.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_DEBUG="$HARNESS_UPLOADER_DEBUG" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_LOG" 2>&1; then
  echo "error: uploader command failed"
  cat "$UPLOADER_LOG" || true
  exit 1
fi

if grep -qiE "DD_API_KEY mismatch|API[ _-]?key mismatch" "$UPLOADER_LOG"; then
  echo "error: unexpected DD_API_KEY mismatch warning with matching credentials"
  cat "$UPLOADER_LOG" || true
  exit 1
fi

"$PYTHON" - <<'PY'
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
# Endpoint coverage check: this validates the uploader hit every expected
# Datadog endpoint at least once during the integration scenario.
required = {
    "/api/v2/libraries/tests/services/setting",
    "/api/v2/ci/libraries/tests",
    "/api/v2/test/libraries/test-management/tests",
    "/api/v2/citestcycle",
    "/api/v2/citestcov",
    "/api/v2/apmtelemetry",
}
seen = set()
with open(log_path, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
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

UPLOADER_LOG="$UPLOADER_LOG" BASE_UPLOAD_LOG_START="$BASE_UPLOAD_LOG_START" "$PYTHON" - <<'PY'
import base64
import json
import os
import re
import sys
from email.parser import BytesParser
from email.policy import default

log_path = os.environ["LOG_FILE"]
snapshot_dir = os.environ["SNAPSHOT_DIR"]
base_upload_log_start = int(os.environ.get("BASE_UPLOAD_LOG_START", "0") or "0")
# When set, snapshot files are rewritten instead of compared.
update = os.environ.get("UPDATE_SNAPSHOTS") == "1"

def parse_multipart(body, content_type):
    # Extract multipart parts (event + coverage) from the upload body.
    if "boundary=" not in content_type:
        return {}
    header = f"Content-Type: {content_type}\r\n\r\n".encode("utf-8")
    msg = BytesParser(policy=default).parsebytes(header + body)
    parts = {}
    for part in msg.iter_parts():
        name = part.get_param("name", header="Content-Disposition")
        if name:
            parts[name] = part.get_payload(decode=True)
    return parts

def normalize_citestcycle(payload):
    # Keep full payload shape while removing user/machine-specific path context.
    def sanitize_value(value):
        if isinstance(value, dict):
            out = {}
            for k, v in value.items():
                if k == "env" and isinstance(v, str):
                    out[k] = "test-env"
                else:
                    out[k] = sanitize_value(v)
            return out
        if isinstance(value, list):
            return [sanitize_value(v) for v in value]
        if isinstance(value, str):
            value = re.sub(r"/Users/[^/]+", "/Users/<user>", value)
            value = re.sub(r"/home/[^/]+", "/home/<user>", value)
            value = re.sub(r"[A-Za-z]:/Users/[^/]+", "C:/Users/<user>", value)
            value = re.sub(r"[A-Za-z]:\\\\Users\\\\[^\\\\]+", r"C:\\Users\\<user>", value)
            return value
        return value

    return sanitize_value(payload)

def load_snap(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)

def write_snap(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)

# Load request log entries emitted by the mock server.
# Keep all records so later checks can inspect both first and subsequent runs.
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < base_upload_log_start:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

def find_latest_cycle_for_resource(resource):
    for rec in reversed(records):
        if rec.get("path") != "/api/v2/citestcycle":
            continue
        try:
            payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
        except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
            continue
        for evt in payload.get("events", []):
            content = evt.get("content") or {}
            if content.get("resource") == resource:
                return rec, payload
    return None, None

cycle, cycle_json = find_latest_cycle_for_resource("Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest")
cov = next((rec for rec in reversed(records) if rec.get("path") == "/api/v2/citestcov"), None)
if not cycle or cycle_json is None or not cov:
    print("error: missing payload logs for snapshotting")
    sys.exit(1)

cycle_norm = normalize_citestcycle(cycle_json)

def find_event(event_type, resource = None):
    for evt in reversed(cycle_json.get("events", [])):
        if evt.get("type") != event_type:
            continue
        content = evt.get("content") or {}
        if resource is not None and content.get("resource") != resource:
            continue
        return evt
    return None

def event_codeowners(event_type, resource):
    evt = find_event(event_type, resource)
    if not evt:
        return None
    content = evt.get("content") or {}
    meta = content.get("meta") or {}
    return meta.get("test.codeowners")

# Integration assertions for CODEOWNERS behavior:
# - missing tag gets added
# - existing tag is preserved
# - events without source fields are not force-tagged
def parse_owners(value):
    if value is None:
        return None
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return "__invalid__"

def print_uploader_log_tail():
    uploader_log = os.environ.get("UPLOADER_LOG")
    if not uploader_log:
        return
    if not os.path.exists(uploader_log):
        print(f"debug: uploader log not found at {uploader_log}")
        return
    with open(uploader_log, "r", encoding="utf-8", errors="replace") as handle:
        lines = handle.readlines()
    codeowners_lines = [
        line.rstrip("\n")
        for line in lines
        if "[dd-uploader][dbg] codeowners" in line
    ]
    if codeowners_lines:
        print("debug: uploader CODEOWNERS diagnostics follows")
        for line in codeowners_lines[-120:]:
            print(line)
        print("debug: end uploader CODEOWNERS diagnostics")
    else:
        print("debug: uploader CODEOWNERS diagnostics not present in log")
    print("debug: uploader log tail follows")
    for line in lines[-120:]:
        print(line.rstrip("\n"))
    print("debug: end uploader log tail")

test_event_owners = parse_owners(event_codeowners("test", "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest"))
if test_event_owners != ["@DataDog/ci-app-libraries-dotnet"]:
    print(f"error: expected codeowners re-injection for test event (got={test_event_owners!r})")
    evt = find_event("test", "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest")
    if evt is None:
        print("debug: target test event not found in latest citestcycle payload")
    else:
        meta = ((evt.get("content") or {}).get("meta") or {})
        print(f"debug: target event source={meta.get('test.source.file')!r} has_codeowners={'test.codeowners' in meta}")
    print_uploader_log_tail()
    sys.exit(1)
suite_event_owners = parse_owners(event_codeowners("test_suite_end", "Samples.XUnitTests.TestSuite"))
if suite_event_owners != ["@DataDog/ci-app-libraries-dotnet"]:
    print(f"error: expected codeowners re-injection for test_suite_end event (got={suite_event_owners!r})")
    evt = find_event("test_suite_end", "Samples.XUnitTests.TestSuite")
    if evt is None:
        print("debug: target test_suite_end event not found in latest citestcycle payload")
    else:
        meta = ((evt.get("content") or {}).get("meta") or {})
        print(f"debug: target suite source={meta.get('test.source.file')!r} has_codeowners={'test.codeowners' in meta}")
    print_uploader_log_tail()
    sys.exit(1)
existing_event_owners = parse_owners(event_codeowners("test", "Samples.XUnitTests.UnSkippableSuite.UnskippableTest"))
if existing_event_owners != ["@DataDog/ci-app-libraries-dotnet"]:
    print(f"error: expected existing codeowners to be preserved for test event (got={existing_event_owners!r})")
    print_uploader_log_tail()
    sys.exit(1)

session_evt = find_event("test_session_end")
if not session_evt:
    print("error: expected test_session_end event")
    sys.exit(1)
session_meta = ((session_evt.get("content") or {}).get("meta") or {})
if "test.codeowners" in session_meta:
    print("error: test_session_end unexpectedly contains codeowners")
    sys.exit(1)

cov_body = base64.b64decode(cov.get("body_b64", ""))
cov_headers = (cov.get("headers") or {})
cov_ct = ""
for key, value in cov_headers.items():
    if str(key).lower() == "content-type":
        cov_ct = value
        break
parts = parse_multipart(cov_body, cov_ct)
missing_parts = {"event", "coveragex"} - set(parts.keys())
if missing_parts:
    print(f"error: coverage multipart missing expected parts: {sorted(missing_parts)}")
    sys.exit(1)
event_json = json.loads(parts.get("event", b"{}").decode("utf-8"))
coverage_json = json.loads(parts.get("coveragex", b"{}").decode("utf-8"))

if event_json != {"dummy": True}:
    print("error: coverage multipart event payload drifted from expected uploader contract")
    print(json.dumps(event_json, indent=2, sort_keys=True))
    sys.exit(1)
if not isinstance(coverage_json, dict):
    print("error: coverage multipart payload must decode to an object")
    sys.exit(1)
files = coverage_json.get("files")
if not isinstance(files, list) or not files:
    print("error: coverage payload is missing non-empty files list")
    print(json.dumps(coverage_json, indent=2, sort_keys=True))
    sys.exit(1)
first = files[0] if files else {}
if not isinstance(first, dict) or not isinstance(first.get("filename"), str):
    print("error: coverage payload first file entry missing filename")
    print(json.dumps(coverage_json, indent=2, sort_keys=True))
    sys.exit(1)

snapshots = {
    "citestcycle.json": cycle_norm,
    "citestcov_event.json": event_json,
    "citestcov_coverage.json": coverage_json,
}

for name, data in snapshots.items():
    path = os.path.join(snapshot_dir, name)
    if update:
        write_snap(path, data)
        continue
    if not os.path.exists(path):
        print(f"error: snapshot missing: {path} (set UPDATE_SNAPSHOTS=1 to create)")
        sys.exit(1)
    existing = load_snap(path)
    if existing != data:
        print(f"error: snapshot mismatch for {name}")
        print("expected:")
        print(json.dumps(existing, indent=2, sort_keys=True))
        print("got:")
        print(json.dumps(data, indent=2, sort_keys=True))
        sys.exit(1)
PY

"$PYTHON" - <<'PY'
import json
import os
import subprocess
import sys
import tempfile

repo_root = os.environ["REPO_ROOT"]
validator = os.path.join(repo_root, "tools", "core", "validate_payload_schema.py")
if not os.path.exists(validator):
    print(f"error: schema validator not found: {validator}")
    sys.exit(1)

schema = {
    "$defs": {
        "variants": [
            {
                "type": "object",
                "required": ["ok"],
                "properties": {
                    "ok": {"type": "boolean"},
                },
            },
        ],
    },
    "$ref": "#/$defs/variants/0",
}
payload = {"ok": True}

with tempfile.TemporaryDirectory() as td:
    schema_path = os.path.join(td, "schema.json")
    payload_path = os.path.join(td, "payload.json")
    with open(schema_path, "w", encoding="utf-8") as f:
        json.dump(schema, f)
    with open(payload_path, "w", encoding="utf-8") as f:
        json.dump(payload, f)

    proc = subprocess.run(
        [sys.executable, validator, schema_path, payload_path],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print("error: schema validator failed array-index $ref regression check")
        if proc.stdout:
            print("stdout:")
            print(proc.stdout)
        if proc.stderr:
            print("stderr:")
            print(proc.stderr)
        sys.exit(1)

    # Negative regression check: invalid payload must be rejected.
    with open(payload_path, "w", encoding="utf-8") as f:
        json.dump({"invalid": "missing ok"}, f)
    proc_invalid = subprocess.run(
        [sys.executable, validator, schema_path, payload_path],
        capture_output=True,
        text=True,
    )
    if proc_invalid.returncode == 0:
        print("error: schema validator unexpectedly accepted invalid payload")
        if proc_invalid.stdout:
            print("stdout:")
            print(proc_invalid.stdout)
        if proc_invalid.stderr:
            print("stderr:")
            print(proc_invalid.stderr)
        sys.exit(1)

    # Tuple-style `items` regression checks.
    tuple_schema = {
        "type": "array",
        "items": [
            {"type": "string"},
            {"type": "integer"},
        ],
        "additionalItems": False,
    }
    with open(schema_path, "w", encoding="utf-8") as f:
        json.dump(tuple_schema, f)

    with open(payload_path, "w", encoding="utf-8") as f:
        json.dump(["ok", 42], f)
    tuple_ok = subprocess.run(
        [sys.executable, validator, schema_path, payload_path],
        capture_output=True,
        text=True,
    )
    if tuple_ok.returncode != 0:
        print("error: schema validator rejected valid tuple-style items payload")
        if tuple_ok.stdout:
            print("stdout:")
            print(tuple_ok.stdout)
        if tuple_ok.stderr:
            print("stderr:")
            print(tuple_ok.stderr)
        sys.exit(1)

    with open(payload_path, "w", encoding="utf-8") as f:
        json.dump(["ok", 42, True], f)
    tuple_extra = subprocess.run(
        [sys.executable, validator, schema_path, payload_path],
        capture_output=True,
        text=True,
    )
    if tuple_extra.returncode == 0:
        print("error: schema validator accepted tuple payload with additional items")
        sys.exit(1)

    with open(payload_path, "w", encoding="utf-8") as f:
        json.dump(["ok", "wrong"], f)
    tuple_wrong_type = subprocess.run(
        [sys.executable, validator, schema_path, payload_path],
        capture_output=True,
        text=True,
    )
    if tuple_wrong_type.returncode == 0:
        print("error: schema validator accepted tuple payload with wrong item type")
        sys.exit(1)

    # Snapshot contract checks: validate checked-in integration snapshots using
    # endpoint-shaped schemas to catch accidental drift.
    snapshot_schemas = {
        "citestcycle.json": {
            "type": "object",
            "required": ["events"],
            "properties": {
                "events": {"type": "array"},
            },
        },
        "citestcov_event.json": {
            "type": "object",
            "required": ["dummy"],
            "properties": {
                "dummy": {"type": "boolean"},
            },
        },
        "citestcov_coverage.json": {
            "type": "object",
            "required": ["version", "files"],
            "properties": {
                "version": {"type": "string"},
                "files": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["filename", "segments"],
                        "properties": {
                            "filename": {"type": "string"},
                            "segments": {"type": "array"},
                        },
                    },
                },
            },
        },
    }
    snapshot_dir = os.environ["SNAPSHOT_DIR"]
    for snapshot_name, snapshot_schema in snapshot_schemas.items():
        snapshot_path = os.path.join(snapshot_dir, snapshot_name)
        if not os.path.exists(snapshot_path):
            print(f"error: expected snapshot not found: {snapshot_path}")
            sys.exit(1)
        with open(schema_path, "w", encoding="utf-8") as f:
            json.dump(snapshot_schema, f)
        schema_check = subprocess.run(
            [sys.executable, validator, schema_path, snapshot_path],
            capture_output=True,
            text=True,
        )
        if schema_check.returncode != 0:
            print(f"error: snapshot failed schema check: {snapshot_name}")
            if schema_check.stdout:
                print("stdout:")
                print(schema_check.stdout)
            if schema_check.stderr:
                print("stderr:")
                print(schema_check.stderr)
            sys.exit(1)
PY

# Scenario: malformed/empty sync responses should fail with actionable diagnostics.
run_malformed_sync_case() {
  # Execute a failing sync scenario in an isolated workspace and assert both:
  # - a stable context hint (for example settings/known_tests/test_management)
  # - an actionable error substring
  #
  # Params:
  #   $1 ws_name
  #   $2 repo_name
  #   $3 service_name
  #   $4 expected_context_substring
  #   $5 expected_error_substring
  #   $6+ optional extra --repo_env flags
  local ws_name="$1"
  local repo_name="$2"
  local service_name="$3"
  local expected_context="$4"
  local expected_error="$5"
  shift 5
  local extra_repo_envs=("$@")

  local ws_path="$TMP_WS/$ws_name"
  local log_path="$TMP_WS/${ws_name}.log"
  mkdir -p "$ws_path"

  cat > "$ws_path/MODULE.bazel" <<MODULE_MALFORMED_EOF
module(name = "topt-${ws_name}", version = "0.0.0")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = ${ESCAPED_REPO_ROOT},
)

test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

test_optimization_sync.test_optimization_sync(
    name = "${repo_name}",
    service = "${service_name}",
    runtime_name = "go",
    runtime_version = "1.2.3",
)

use_repo(test_optimization_sync, "${repo_name}")
MODULE_MALFORMED_EOF

  cat > "$ws_path/BUILD.bazel" <<'BUILD_MALFORMED_EOF'
filegroup(
    name = "noop",
    srcs = [],
)
BUILD_MALFORMED_EOF

  local cmd=("$BAZEL" "${BAZEL_FLAGS[@]}" build "@${repo_name}//:test_optimization_files" "${REPO_ENVS[@]}")
  if (( ${#extra_repo_envs[@]} )); then
    cmd+=("${extra_repo_envs[@]}")
  fi
  if (
    cd "$ws_path" && \
    "${cmd[@]}" >"$log_path" 2>&1
  ); then
    echo "error: malformed sync scenario unexpectedly succeeded for $ws_name"
    cat "$log_path" || true
    exit 1
  fi

  # Assert both content and context fragments so errors stay actionable
  # even when surrounding wording changes.
  if ! grep -q "$expected_error" "$log_path"; then
    echo "error: malformed sync scenario missing expected error '$expected_error' for $ws_name"
    cat "$log_path" || true
    exit 1
  fi
  if ! grep -q "$expected_context" "$log_path"; then
    echo "error: malformed sync scenario missing expected context '$expected_context' for $ws_name"
    cat "$log_path" || true
    exit 1
  fi
}

run_malformed_sync_case \
  "ws_malformed_settings" \
  "test_optimization_data_bad_settings" \
  "malformed-settings-service" \
  "settings.json" \
  "response is not JSON"

run_malformed_sync_case \
  "ws_empty_settings" \
  "test_optimization_data_empty_settings" \
  "empty-settings-service" \
  "settings.json" \
  "response is empty; expected JSON object"

run_malformed_sync_case \
  "ws_malformed_known_tests" \
  "test_optimization_data_bad_known_tests" \
  "malformed-known-tests-service" \
  "known_tests.json" \
  "response is not JSON"

run_malformed_sync_case \
  "ws_malformed_test_management" \
  "test_optimization_data_bad_test_management" \
  "mock-service" \
  "test_management.json" \
  "response is not JSON" \
  "--repo_env=DD_GIT_COMMIT_MESSAGE=malformed-test-management-commit-message" \
  "--repo_env=DD_GIT_HEAD_MESSAGE=malformed-test-management-commit-message"

# Scenario: retry/backoff sync behavior for transient delay/rate-limit/status errors.
run_retry_sync_case() {
  # Execute a successful sync scenario in an isolated workspace and assert that
  # a specific endpoint was hit the expected number of times for a filtered
  # attribute value (used to prove retry/backoff behavior).
  #
  # Params:
  #   $1 ws_name
  #   $2 repo_name
  #   $3 service_name
  #   $4 expected_path
  #   $5 filter_attr
  #   $6 filter_value
  #   $7 min_count
  #   $8+ optional extra --repo_env flags
  local ws_name="$1"
  local repo_name="$2"
  local service_name="$3"
  local expected_path="$4"
  local filter_attr="$5"
  local filter_value="$6"
  local min_count="$7"
  shift 7
  local extra_repo_envs=("$@")

  local ws_path="$TMP_WS/$ws_name"
  local build_log_path="$TMP_WS/${ws_name}.log"
  local log_start
  log_start="$(log_line_count)"
  mkdir -p "$ws_path"

  cat > "$ws_path/MODULE.bazel" <<MODULE_RETRY_EOF
module(name = "topt-${ws_name}", version = "0.0.0")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = ${ESCAPED_REPO_ROOT},
)

test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

test_optimization_sync.test_optimization_sync(
    name = "${repo_name}",
    service = "${service_name}",
    runtime_name = "go",
    runtime_version = "1.2.3",
)

use_repo(test_optimization_sync, "${repo_name}")
MODULE_RETRY_EOF

  cat > "$ws_path/BUILD.bazel" <<'BUILD_RETRY_EOF'
filegroup(
    name = "noop",
    srcs = [],
)
BUILD_RETRY_EOF

  local cmd=("$BAZEL" "${BAZEL_FLAGS[@]}" build "@${repo_name}//:test_optimization_files" "${REPO_ENVS[@]}")
  if (( ${#extra_repo_envs[@]} )); then
    cmd+=("${extra_repo_envs[@]}")
  fi
  if ! (
    cd "$ws_path" && \
    "${cmd[@]}" >"$build_log_path" 2>&1
  ); then
    echo "error: retry sync scenario failed unexpectedly for $ws_name"
    cat "$build_log_path" || true
    exit 1
  fi

  # Prevent MSYS path/env conversion from rewriting "/api/..." into a host
  # path when running the inline Python checker on Windows (Git Bash).
  MSYS2_ARG_CONV_EXCL="*" MSYS2_ENV_CONV_EXCL="EXPECTED_PATH" LOG_FILE="$LOG_FILE" LOG_START="$log_start" EXPECTED_PATH="$expected_path" FILTER_ATTR="$filter_attr" FILTER_VALUE="$filter_value" MIN_COUNT="$min_count" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start = int(os.environ["LOG_START"])
expected_path = os.environ["EXPECTED_PATH"]
filter_attr = os.environ["FILTER_ATTR"]
filter_value = os.environ["FILTER_VALUE"]
min_count = int(os.environ["MIN_COUNT"])

count = 0
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("path") != expected_path:
            continue
        try:
            payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
        except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
            continue
        attrs = ((payload.get("data") or {}).get("attributes") or {})
        if attrs.get(filter_attr) != filter_value:
            continue
        count += 1

if count < min_count:
    print(
        f"error: expected at least {min_count} requests for path={expected_path}, "
        f"{filter_attr}={filter_value}; got {count}"
    )
    sys.exit(1)
PY
}

run_retry_sync_case \
  "ws_delay_settings" \
  "test_optimization_data_delay_settings" \
  "delay-settings-service" \
  "/api/v2/libraries/tests/services/setting" \
  "service" \
  "delay-settings-service" \
  1

run_retry_sync_case \
  "ws_retry_settings" \
  "test_optimization_data_retry_settings" \
  "retry-settings-service" \
  "/api/v2/libraries/tests/services/setting" \
  "service" \
  "retry-settings-service" \
  2

run_retry_sync_case \
  "ws_retry_known_tests" \
  "test_optimization_data_retry_known_tests" \
  "retry-known-tests-service" \
  "/api/v2/ci/libraries/tests" \
  "service" \
  "retry-known-tests-service" \
  2

run_retry_sync_case \
  "ws_retry_test_management" \
  "test_optimization_data_retry_test_management" \
  "mock-service" \
  "/api/v2/test/libraries/test-management/tests" \
  "commit_message" \
  "retry-test-management-commit-message" \
  2 \
  "--repo_env=DD_GIT_COMMIT_MESSAGE=retry-test-management-commit-message" \
  "--repo_env=DD_GIT_HEAD_MESSAGE=retry-test-management-commit-message"

# Scenario: multi-service extension wiring + deduped sanitized service keys.
# This block verifies both repository-rule fanout and macro-level service key
# resolution semantics (including collision-safe explicit key selection).
# Maintainers: keep these go-macro scenarios explicitly dual-module aware:
# - core module + go companion module + rules_go
# - dual local_path_override (repo root + modules/go)
MULTI_WS="$TMP_WS/ws_multi"
mkdir -p "$MULTI_WS"
cat > "$MULTI_WS/MODULE.bazel" <<MODULE_MULTI_EOF
module(name = "topt-multi-integration", version = "0.0.0")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
bazel_dep(name = "rules_go", version = "0.60.0")

local_path_override(
    module_name = "rules_go",
    path = ${ESCAPED_RULES_GO_VENDOR},
)

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = ${ESCAPED_REPO_ROOT},
)
local_path_override(
    module_name = "datadog-rules-test-optimization-go",
    path = ${ESCAPED_MODULES_GO},
)

orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(version = "${ORCHESTRION_VERSION}")

go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

go_topt.test_optimization_go(
    name = "test_optimization_data",
    services = ["go-service", "go_service"],
    out_dir = "custom_topt",
    runtime_version = "1.2.3",
)

use_repo(
    orchestrion,
    "rules_go_orchestrion_tool",
)

use_repo(
    go_topt,
    "test_optimization_data",
    "test_optimization_data_go_service",
    "test_optimization_data_go_service_2",
)
MODULE_MULTI_EOF

cat > "$MULTI_WS/BUILD.bazel" <<'BUILD_MULTI_EOF'
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data_go_service//:export.bzl", topt_data_go_service = "topt_data")
load("@test_optimization_data_go_service_2//:export.bzl", topt_data_go_service_2 = "topt_data")
load("//:macro_probe.bzl", "fake_go_test")

filegroup(
    name = "multi_sync_smoke",
    srcs = [
        "@test_optimization_data//:test_optimization_files_go_service",
        "@test_optimization_data//:test_optimization_files_go_service_2",
        "@test_optimization_data//:module_go_service_modulea",
        "@test_optimization_data//:module_go_service_2_modulea",
        "@test_optimization_data_go_service//:test_optimization_files",
        "@test_optimization_data_go_service_2//:test_optimization_files",
    ],
)

dd_topt_go_test(
    name = "macro_service_probe",
    go_test_rule = fake_go_test,
    topt_data = {
        "go_service": topt_data_go_service,
        "go_service_2": topt_data_go_service_2,
    },
    topt_service = "go_service_2",
)

dd_topt_go_test(
    name = "macro_data_none_probe",
    go_test_rule = fake_go_test,
    topt_data = {
        "go_service": topt_data_go_service,
        "go_service_2": topt_data_go_service_2,
    },
    topt_service = "go_service",
    data = None,
)
BUILD_MULTI_EOF

cat > "$MULTI_WS/macro_probe.bzl" <<'MACRO_PROBE_EOF'
def _fake_go_test_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(out, "#!/bin/sh\nexit 0\n", is_executable = True)
    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]),
        executable = out,
    )]

_fake_go_test = rule(
    implementation = _fake_go_test_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "embed": attr.label_list(),
        "env": attr.string_dict(),
        "importpath": attr.string(),
        "rundir": attr.string(),
    },
    executable = True,
    test = True,
)

def fake_go_test(name, data = [], env = {}, **kwargs):
    _fake_go_test(
        name = name,
        data = data,
        env = env,
        **kwargs
    )
MACRO_PROBE_EOF

mkdir -p "$MULTI_WS/invalid"
cat > "$MULTI_WS/invalid/BUILD.bazel" <<'BUILD_MULTI_INVALID_EOF'
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data_go_service//:export.bzl", topt_data_go_service = "topt_data")
load("@test_optimization_data_go_service_2//:export.bzl", topt_data_go_service_2 = "topt_data")
load("//:macro_probe.bzl", "fake_go_test")

dd_topt_go_test(
    name = "macro_service_probe_invalid",
    go_test_rule = fake_go_test,
    topt_data = {
        "go_service": topt_data_go_service,
        "go_service_2": topt_data_go_service_2,
    },
    topt_service = "missing_service",
)
BUILD_MULTI_INVALID_EOF

MULTI_LOG_START="$(log_line_count)"
(
  cd "$MULTI_WS"
  "$BAZEL" "${BAZEL_FLAGS[@]}" build //:multi_sync_smoke //:macro_service_probe //:macro_data_none_probe \
    "${REPO_ENVS[@]}"
)

MULTI_MACRO_CQUERY=$(
  cd "$MULTI_WS" && \
  "$BAZEL" "${BAZEL_FLAGS[@]}" cquery //:macro_service_probe__raw_go_test --output=build "${REPO_ENVS[@]}"
)
# The manifest/data wiring lives on the hidden raw go_test target. Querying the
# wrapper target only verifies the public wrapper exists, not which payload set
# the macro selected underneath it.
if ! printf '%s\n' "$MULTI_MACRO_CQUERY" | grep -q "_go_service_2//:custom_topt/manifest.txt"; then
  echo "error: dd_topt_go_test multi-service probe did not resolve to go_service_2 custom out_dir manifest"
  echo "$MULTI_MACRO_CQUERY"
  exit 1
fi
if printf '%s\n' "$MULTI_MACRO_CQUERY" | grep -q "_go_service//:custom_topt/manifest.txt"; then
  echo "error: dd_topt_go_test multi-service probe unexpectedly resolved to go_service custom out_dir manifest"
  echo "$MULTI_MACRO_CQUERY"
  exit 1
fi

MULTI_INVALID_LOG="$TMP_WS/multi_invalid_service.log"
if (
  # Build from the package directory to avoid //pkg:label path conversion
  # quirks under Git Bash on Windows.
  cd "$MULTI_WS/invalid" && \
  "$BAZEL" "${BAZEL_FLAGS[@]}" build :macro_service_probe_invalid "${REPO_ENVS[@]}" >"$MULTI_INVALID_LOG" 2>&1
); then
  echo "error: dd_topt_go_test invalid-service scenario unexpectedly succeeded"
  cat "$MULTI_INVALID_LOG" || true
  exit 1
fi
if ! grep -q "topt_service 'missing_service' not found" "$MULTI_INVALID_LOG"; then
  echo "error: invalid-service scenario missing topt_service not found message"
  cat "$MULTI_INVALID_LOG" || true
  exit 1
fi
if ! grep -q "Available:" "$MULTI_INVALID_LOG"; then
  echo "error: invalid-service scenario missing available-services hint"
  cat "$MULTI_INVALID_LOG" || true
  exit 1
fi
if ! grep -q "go_service" "$MULTI_INVALID_LOG"; then
  echo "error: invalid-service scenario missing go_service key in message"
  cat "$MULTI_INVALID_LOG" || true
  exit 1
fi
if ! grep -q "go_service_2" "$MULTI_INVALID_LOG"; then
  echo "error: invalid-service scenario missing go_service_2 key in message"
  cat "$MULTI_INVALID_LOG" || true
  exit 1
fi

# Scenario: bootstrap helper patches MODULE.bazel and runs an idempotent
# Orchestrion pin flow without requiring a second extension in consumer setup.
BOOT_WS="$TMP_WS/ws_bootstrap"
mkdir -p "$BOOT_WS/bin"
cat > "$BOOT_WS/MODULE.bazel" <<MODULE_BOOT_EOF
module(name = "topt-bootstrap-integration", version = "0.0.0")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = ${ESCAPED_REPO_ROOT},
)
local_path_override(
    module_name = "datadog-rules-test-optimization-go",
    path = ${ESCAPED_MODULES_GO},
)

go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

go_topt.test_optimization_go(
    name = "test_optimization_data",
    service = "go-service",
    runtime_version = "1.2.3",
)

use_repo(go_topt, "test_optimization_data")
MODULE_BOOT_EOF

cat > "$BOOT_WS/go.mod" <<'GOMOD_BOOT_EOF'
module example.com/bootstrap-go

go 1.24.0
GOMOD_BOOT_EOF

cat > "$BOOT_WS/bin/go" <<'FAKE_GO_EOF'
#!/bin/sh
set -eu

ORCH_VERSION="${ORCHESTRION_VERSION:-v1.9.0}"

# The plain bootstrap scenario still validates file edits, but deterministic
# proxy generation now resolves real modules during repository bootstrap. Keep
# the orchestration paths stubbed while delegating the module-resolution work to
# the host Go binary through scenario-local caches.
ensure_require() {
  module_path="$1"
  version="$2"
  require_line="require ${module_path} ${version}"
  if ! grep -Fqx "$require_line" go.mod; then
    printf '%s\n' "$require_line" >> go.mod
  fi
}

runtime_root() {
  printf '%s/%s\n' "$PWD" ".fake_go_runtime"
}

run_real_go() {
  if [ -z "${REAL_GO_BIN:-}" ] || [ ! -x "${REAL_GO_BIN}" ]; then
    echo "missing REAL_GO_BIN for bootstrap integration harness" >&2
    exit 1
  fi
  runtime_dir="$(runtime_root)"
  go_path="${GOPATH:-${runtime_dir}/gopath}"
  go_mod_cache="${GOMODCACHE:-${go_path}/pkg/mod}"
  go_build_cache="${GOCACHE:-${go_path}/cache}"
  home_dir="${runtime_dir}/home"
  xdg_cache_home="${runtime_dir}/xdg-cache"
  go_proxy="${GOPROXY:-https://proxy.golang.org,direct}"
  go_sumdb="${GOSUMDB:-sum.golang.org}"
  mkdir -p "$go_mod_cache" "$go_build_cache" "$home_dir" "$xdg_cache_home"
  GO111MODULE=on \
  GOWORK=off \
  GOPATH="$go_path" \
  GOMODCACHE="$go_mod_cache" \
  GOCACHE="$go_build_cache" \
  HOME="$home_dir" \
  XDG_CACHE_HOME="$xdg_cache_home" \
  GOPROXY="$go_proxy" \
  GOSUMDB="$go_sumdb" \
  "$REAL_GO_BIN" "$@"
}

if [ "${1:-}" = "-C" ] && [ "$#" -ge 3 ]; then
  cd "$2"
  shift 2
fi

if [ "${1:-}" = "run" ] && [ "${3:-}" = "pin" ]; then
  case "${2:-}" in
    github.com/DataDog/orchestrion@v*)
      cat > orchestrion.tool.go <<'PIN_TOOL_EOF'
//go:build tools

package tools

import (
  _ "github.com/DataDog/orchestrion" // integration
  _ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration
  _ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
  _ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration
)
PIN_TOOL_EOF
      : > go.sum
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "download" ] && [ "${3:-}" = "all" ]; then
  run_real_go "$@"
  exit 0
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "download" ] && [ "${3:-}" = "github.com/DataDog/dd-trace-go/v2" ]; then
  run_real_go "$@"
  exit 0
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "download" ]; then
  case "${3:-}" in
    github.com/DataDog/dd-trace-go/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    github.com/DataDog/dd-trace-go/contrib/net/http/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    github.com/DataDog/dd-trace-go/contrib/log/slog/v2@v2.9.0-dev.0.20260416093245-194346a71c51)
      run_real_go "$@"
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "download" ]; then
  exit 1
fi

if [ "${1:-}" = "run" ]; then
  exit 1
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "edit" ]; then
  case "${3:-}" in
    -require=github.com/DataDog/orchestrion@${ORCH_VERSION})
      ensure_require "github.com/DataDog/orchestrion" "${ORCH_VERSION}"
      exit 0
      ;;
    -require=github.com/DataDog/dd-trace-go/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    -require=github.com/DataDog/dd-trace-go/contrib/net/http/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    -require=github.com/DataDog/dd-trace-go/contrib/log/slog/v2@v2.9.0-dev.0.20260416093245-194346a71c51)
      module_and_version="${3#-require=}"
      module_path="${module_and_version%@*}"
      version="${module_and_version##*@}"
      ensure_require "$module_path" "$version"
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "get" ] && [ "${2:-}" = "github.com/DataDog/dd-trace-go/v2/orchestrion@v2.9.0-dev.0.20260416093245-194346a71c51" ]; then
  ensure_require "github.com/DataDog/dd-trace-go/v2" "v2.9.0-dev.0.20260416093245-194346a71c51"
  exit 0
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "tidy" ]; then
  : > go.sum
  exit 0
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "-m" ] && [ "${3:-}" = "-f" ] && [ "${4:-}" = "{{.Version}}" ]; then
  case "${5:-}" in
    github.com/DataDog/dd-trace-go/v2|\
    github.com/DataDog/dd-trace-go/contrib/net/http/v2|\
    github.com/DataDog/dd-trace-go/contrib/log/slog/v2)
      printf 'v2.9.0-dev.0.20260416093245-194346a71c51\n'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "-m" ] && [ "${3:-}" = "-json" ]; then
  case "${4:-}" in
    github.com/DataDog/dd-trace-go/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    github.com/DataDog/dd-trace-go/contrib/net/http/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    github.com/DataDog/dd-trace-go/contrib/log/slog/v2@v2.9.0-dev.0.20260416093245-194346a71c51)
      printf '{"Version":"v2.9.0-dev.0.20260416093245-194346a71c51"}\n'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "-mod=mod" ] && [ "${3:-}" = "-m" ] && [ "${4:-}" = "-json" ]; then
  case "${5:-}" in
    github.com/DataDog/orchestrion)
      printf '{"Version":"%s"}\n' "$ORCH_VERSION"
      exit 0
      ;;
    github.com/DataDog/dd-trace-go/v2|\
    github.com/DataDog/dd-trace-go/contrib/net/http/v2|\
    github.com/DataDog/dd-trace-go/contrib/log/slog/v2)
      printf '{"Version":"v2.9.0-dev.0.20260416093245-194346a71c51"}\n'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "build" ]; then
  out=""
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ] && [ "$#" -ge 2 ]; then
      out="$2"
      break
    fi
    shift
  done
  if [ -n "$out" ]; then
    cat > "$out" <<'ORCH_STUB_EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = "server" ]; then
  for arg in "$@"; do
    case "$arg" in
      -url-file=*)
        url_file="${arg#-url-file=}"
        printf 'http://127.0.0.1:43123\n' > "$url_file"
        while :; do sleep 3600; done
        ;;
    esac
  done
  exit 0
fi

if [ "${1:-}" = "pin" ]; then
  cat > orchestrion.tool.go <<'PIN_TOOL_EOF'
//go:build tools

package tools

import (
  _ "github.com/DataDog/orchestrion" // integration
  _ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration
  _ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
  _ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration
)
PIN_TOOL_EOF
  : > go.sum
  exit 0
fi

if [ "${1:-}" = "toolexec" ]; then
  shift
  exec "$@"
fi

exit 0
ORCH_STUB_EOF
    chmod +x "$out"
    exit 0
  fi
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "-mod=mod" ] && [ "${3:-}" = "-m" ] && [ "${4:-}" = "-json" ] && [ "${5:-}" = "all" ]; then
  run_real_go "$@"
  exit 0
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "-mod=mod" ]; then
  for arg in "$@"; do
    case "$arg" in
      github.com/DataDog/dd-trace-go/v2/orchestrion|\
      github.com/DataDog/dd-trace-go/contrib/net/http/v2|\
      github.com/DataDog/dd-trace-go/contrib/log/slog/v2|\
      github.com/DataDog/dd-trace-go/v2/ddtrace/tracer|\
      github.com/DataDog/dd-trace-go/v2/profiler|\
      github.com/DataDog/dd-trace-go/v2/instrumentation/env)
        run_real_go "$@"
        exit 0
        ;;
    esac
  done
fi

echo "unexpected go invocation: $*" >&2
exit 1
FAKE_GO_EOF
chmod +x "$BOOT_WS/bin/go"

(
  cd "$BOOT_WS"
  REAL_GO_BIN="$REAL_GO_BIN_HOST" PATH="$BOOT_WS/bin:$PATH" "$BAZEL" "${BAZEL_FLAGS[@]}" run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
    --workspace "$BOOT_WS" \
    --rules-go-remote "$RULES_GO_OVERRIDE_REMOTE" \
    --rules-go-commit "$RULES_GO_OVERRIDE_COMMIT"
)

if ! grep -q 'git_override(' "$BOOT_WS/MODULE.bazel"; then
  echo "error: bootstrap helper did not add rules_go git_override"
  cat "$BOOT_WS/MODULE.bazel" || true
  exit 1
fi
if ! grep -q 'strip_prefix = "third_party/rules_go_orchestrion_base"' "$BOOT_WS/MODULE.bazel"; then
  echo "error: bootstrap helper did not add vendored rules_go strip_prefix"
  cat "$BOOT_WS/MODULE.bazel" || true
  exit 1
fi
if ! grep -q '@rules_go//go:extensions.bzl", "orchestrion"' "$BOOT_WS/MODULE.bazel"; then
  echo "error: bootstrap helper did not add rules_go orchestrion extension"
  cat "$BOOT_WS/MODULE.bazel" || true
  exit 1
fi
if [ ! -f "$BOOT_WS/orchestrion.tool.go" ]; then
  echo "error: bootstrap helper did not create orchestrion.tool.go"
  exit 1
fi
if [ ! -f "$BOOT_WS/orchestrion.yml" ]; then
  echo "error: bootstrap helper did not create orchestrion.yml"
  exit 1
fi

printf 'custom: true\n' > "$BOOT_WS/orchestrion.yml"
(
  cd "$BOOT_WS"
  REAL_GO_BIN="$REAL_GO_BIN_HOST" PATH="$BOOT_WS/bin:$PATH" "$BAZEL" "${BAZEL_FLAGS[@]}" run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
    --workspace "$BOOT_WS" \
    --rules-go-remote "$RULES_GO_OVERRIDE_REMOTE" \
    --rules-go-commit "$RULES_GO_OVERRIDE_COMMIT"
)

if ! grep -q 'custom: true' "$BOOT_WS/orchestrion.yml"; then
  echo "error: bootstrap helper overwrote an existing orchestrion.yml without --force"
  cat "$BOOT_WS/orchestrion.yml" || true
  exit 1
fi

# Scenario: guided bootstrap creates the Go sync wiring, root uploader target,
# and local dd_go_test wrapper for a fresh single-service Go workspace.
GUIDED_BOOT_WS="$TMP_WS/ws_bootstrap_guided"
mkdir -p "$GUIDED_BOOT_WS/bin" "$GUIDED_BOOT_WS/src/go-project"
cat > "$GUIDED_BOOT_WS/MODULE.bazel" <<MODULE_GUIDED_BOOT_EOF
module(name = "topt-guided-bootstrap-integration", version = "0.0.0")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = ${ESCAPED_REPO_ROOT},
)
local_path_override(
    module_name = "datadog-rules-test-optimization-go",
    path = ${ESCAPED_MODULES_GO},
)
MODULE_GUIDED_BOOT_EOF

cat > "$GUIDED_BOOT_WS/go.mod" <<'GOMOD_GUIDED_BOOT_EOF'
module example.com/guided-bootstrap-go

go 1.24.0
GOMOD_GUIDED_BOOT_EOF

cat > "$GUIDED_BOOT_WS/bin/go" <<'FAKE_GO_GUIDED_EOF'
#!/bin/sh
set -eu

ORCH_VERSION="${ORCHESTRION_VERSION:-v1.9.0}"

# The guided bootstrap scenario later builds a real Go test, so the fake Go
# tool delegates the download-heavy paths to the host Go binary using temporary
# scenario-local caches instead of any persistent host cache.
ensure_require() {
  module_path="$1"
  version="$2"
  require_line="require ${module_path} ${version}"
  if ! grep -Fqx "$require_line" go.mod; then
    printf '%s\n' "$require_line" >> go.mod
  fi
}

runtime_root() {
  printf '%s/%s\n' "$PWD" ".fake_go_runtime"
}

run_real_go() {
  if [ -z "${REAL_GO_BIN:-}" ] || [ ! -x "${REAL_GO_BIN}" ]; then
    echo "missing REAL_GO_BIN for bootstrap integration harness" >&2
    exit 1
  fi
  runtime_dir="$(runtime_root)"
  go_path="${GOPATH:-${runtime_dir}/gopath}"
  go_mod_cache="${GOMODCACHE:-${go_path}/pkg/mod}"
  go_build_cache="${GOCACHE:-${go_path}/cache}"
  home_dir="${runtime_dir}/home"
  xdg_cache_home="${runtime_dir}/xdg-cache"
  go_proxy="${GOPROXY:-https://proxy.golang.org,direct}"
  go_sumdb="${GOSUMDB:-sum.golang.org}"
  mkdir -p "$go_mod_cache" "$go_build_cache" "$home_dir" "$xdg_cache_home"
  GO111MODULE=on \
  GOWORK=off \
  GOPATH="$go_path" \
  GOMODCACHE="$go_mod_cache" \
  GOCACHE="$go_build_cache" \
  HOME="$home_dir" \
  XDG_CACHE_HOME="$xdg_cache_home" \
  GOPROXY="$go_proxy" \
  GOSUMDB="$go_sumdb" \
  "$REAL_GO_BIN" "$@"
}

if [ "${1:-}" = "-C" ] && [ "$#" -ge 3 ]; then
  cd "$2"
  shift 2
fi

if [ "${1:-}" = "run" ] && [ "${3:-}" = "pin" ]; then
  case "${2:-}" in
    github.com/DataDog/orchestrion@v*)
      cat > orchestrion.tool.go <<'PIN_TOOL_EOF'
//go:build tools

package tools

import (
  _ "github.com/DataDog/orchestrion" // integration
  _ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration
  _ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
  _ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration
)
PIN_TOOL_EOF
      : > go.sum
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "download" ] && [ "${3:-}" = "all" ]; then
  run_real_go "$@"
  exit 0
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "download" ] && [ "${3:-}" = "github.com/DataDog/dd-trace-go/v2" ]; then
  run_real_go "$@"
  exit 0
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "download" ]; then
  case "${3:-}" in
    github.com/DataDog/dd-trace-go/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    github.com/DataDog/dd-trace-go/contrib/net/http/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    github.com/DataDog/dd-trace-go/contrib/log/slog/v2@v2.9.0-dev.0.20260416093245-194346a71c51)
      run_real_go "$@"
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "edit" ]; then
  case "${3:-}" in
    -require=github.com/DataDog/orchestrion@${ORCH_VERSION})
      ensure_require "github.com/DataDog/orchestrion" "${ORCH_VERSION}"
      exit 0
      ;;
    -require=github.com/DataDog/dd-trace-go/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    -require=github.com/DataDog/dd-trace-go/contrib/net/http/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    -require=github.com/DataDog/dd-trace-go/contrib/log/slog/v2@v2.9.0-dev.0.20260416093245-194346a71c51)
      module_and_version="${3#-require=}"
      module_path="${module_and_version%@*}"
      version="${module_and_version##*@}"
      ensure_require "$module_path" "$version"
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "get" ] && [ "${2:-}" = "github.com/DataDog/dd-trace-go/v2/orchestrion@v2.9.0-dev.0.20260416093245-194346a71c51" ]; then
  ensure_require "github.com/DataDog/dd-trace-go/v2" "v2.9.0-dev.0.20260416093245-194346a71c51"
  exit 0
fi

if [ "${1:-}" = "mod" ] && [ "${2:-}" = "tidy" ]; then
  : > go.sum
  exit 0
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "-m" ] && [ "${3:-}" = "-f" ] && [ "${4:-}" = "{{.Version}}" ]; then
  case "${5:-}" in
    github.com/DataDog/dd-trace-go/v2|\
    github.com/DataDog/dd-trace-go/contrib/net/http/v2|\
    github.com/DataDog/dd-trace-go/contrib/log/slog/v2)
      printf 'v2.9.0-dev.0.20260416093245-194346a71c51\n'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "-m" ] && [ "${3:-}" = "-json" ]; then
  case "${4:-}" in
    github.com/DataDog/dd-trace-go/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    github.com/DataDog/dd-trace-go/contrib/net/http/v2@v2.9.0-dev.0.20260416093245-194346a71c51|\
    github.com/DataDog/dd-trace-go/contrib/log/slog/v2@v2.9.0-dev.0.20260416093245-194346a71c51)
      printf '{"Version":"v2.9.0-dev.0.20260416093245-194346a71c51"}\n'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "-mod=mod" ] && [ "${3:-}" = "-m" ] && [ "${4:-}" = "-json" ]; then
  case "${5:-}" in
    github.com/DataDog/orchestrion)
      printf '{"Version":"%s"}\n' "$ORCH_VERSION"
      exit 0
      ;;
    github.com/DataDog/dd-trace-go/v2|\
    github.com/DataDog/dd-trace-go/contrib/net/http/v2|\
    github.com/DataDog/dd-trace-go/contrib/log/slog/v2)
      printf '{"Version":"v2.9.0-dev.0.20260416093245-194346a71c51"}\n'
      exit 0
      ;;
  esac
fi

if [ "${1:-}" = "build" ]; then
  out=""
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ] && [ "$#" -ge 2 ]; then
      out="$2"
      break
    fi
    shift
  done
  if [ -n "$out" ]; then
    cat > "$out" <<'ORCH_STUB_EOF'
#!/bin/sh
set -eu

if [ "${1:-}" = "server" ]; then
  for arg in "$@"; do
    case "$arg" in
      -url-file=*)
        url_file="${arg#-url-file=}"
        printf 'http://127.0.0.1:43123\n' > "$url_file"
        while :; do sleep 3600; done
        ;;
    esac
  done
  exit 0
fi

if [ "${1:-}" = "pin" ]; then
  cat > orchestrion.tool.go <<'PIN_TOOL_EOF'
//go:build tools

package tools

import (
  _ "github.com/DataDog/orchestrion" // integration
  _ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration
  _ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
  _ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration
)
PIN_TOOL_EOF
  : > go.sum
  exit 0
fi

if [ "${1:-}" = "toolexec" ]; then
  shift
  exec "$@"
fi

exit 0
ORCH_STUB_EOF
    chmod +x "$out"
    exit 0
  fi
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "-mod=mod" ] && [ "${3:-}" = "-m" ] && [ "${4:-}" = "-json" ] && [ "${5:-}" = "all" ]; then
  run_real_go "$@"
  exit 0
fi

if [ "${1:-}" = "list" ] && [ "${2:-}" = "-mod=mod" ]; then
  # The guided bootstrap path passes extra flags such as -tags=tools before the
  # package arguments. Scan the full argv instead of assuming the first package
  # is always the third argument.
  for arg in "$@"; do
    case "$arg" in
      github.com/DataDog/dd-trace-go/v2/orchestrion|\
      github.com/DataDog/dd-trace-go/contrib/net/http/v2|\
      github.com/DataDog/dd-trace-go/contrib/log/slog/v2|\
      github.com/DataDog/dd-trace-go/v2/ddtrace/tracer|\
      github.com/DataDog/dd-trace-go/v2/profiler|\
      github.com/DataDog/dd-trace-go/v2/instrumentation/env)
        run_real_go "$@"
        exit 0
        ;;
    esac
  done
fi

echo "unexpected go invocation: $*" >&2
exit 1
FAKE_GO_GUIDED_EOF
chmod +x "$GUIDED_BOOT_WS/bin/go"

cat > "$GUIDED_BOOT_WS/src/go-project/main.go" <<'GO_MAIN_GUIDED_EOF'
package main

func Greeting() string {
	return "Hello World from Go"
}
GO_MAIN_GUIDED_EOF

cat > "$GUIDED_BOOT_WS/src/go-project/main_test.go" <<'GO_TEST_GUIDED_EOF'
package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func resolveRlocation(p string) (string, bool) {
	if _, err := os.Stat(p); err == nil {
		return p, true
	}
	if d := os.Getenv("RUNFILES_DIR"); d != "" {
		cand := filepath.Join(d, p)
		if _, err := os.Stat(cand); err == nil {
			return cand, true
		}
	}
	if mf := os.Getenv("RUNFILES_MANIFEST_FILE"); mf != "" {
		if f, err := os.Open(mf); err == nil {
			defer f.Close()
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				line := sc.Text()
				i := strings.IndexByte(line, ' ')
				if i > 0 && line[:i] == p {
					return line[i+1:], true
				}
			}
		}
	}
	if s := os.Getenv("TEST_SRCDIR"); s != "" {
		cand := filepath.Join(s, p)
		if _, err := os.Stat(cand); err == nil {
			return cand, true
		}
	}
	return p, false
}

func TestGreeting(t *testing.T) {
	if Greeting() != "Hello World from Go" {
		t.Fatalf("unexpected greeting")
	}
}

func TestStageSourcesEnablesRepoRelativeAstLookup(t *testing.T) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "src/go-project/main_test.go", nil, 0)
	if err != nil {
		t.Fatalf("parse repo-relative source file: %v", err)
	}

	endLine := 0
	ast.Inspect(file, func(node ast.Node) bool {
		fn, ok := node.(*ast.FuncDecl)
		if !ok || fn.Name == nil || fn.Name.Name != "TestGreeting" {
			return true
		}
		endLine = fset.Position(fn.End()).Line
		return false
	})

	if endLine <= 0 {
		t.Fatalf("failed to resolve TestGreeting end line from AST")
	}
}

func TestGuidedGoRuntimeWiring(t *testing.T) {
	if got := os.Getenv("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"); got != "true" {
		t.Fatalf("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES = %q, want true", got)
	}
	if got := os.Getenv("DD_TRACE_AGENT_URL"); got != "" {
		t.Fatalf("DD_TRACE_AGENT_URL = %q, want unset so Bazel file mode is not proxied", got)
	}
	if got := os.Getenv("DD_CIVISIBILITY_AGENTLESS_ENABLED"); got != "" {
		t.Fatalf("DD_CIVISIBILITY_AGENTLESS_ENABLED = %q, want unset so Bazel file mode is not proxied", got)
	}

	manifestPath := os.Getenv("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
	if manifestPath == "" {
		t.Fatal("DD_TEST_OPTIMIZATION_MANIFEST_FILE not set")
	}
	if resolved, ok := resolveRlocation(manifestPath); !ok {
		t.Fatalf("failed to resolve manifest runfile %q", manifestPath)
	} else if _, err := os.Stat(resolved); err != nil {
		t.Fatalf("manifest file is not readable: %v", err)
	}

	undeclaredDir := os.Getenv("TEST_UNDECLARED_OUTPUTS_DIR")
	if undeclaredDir == "" {
		t.Fatal("TEST_UNDECLARED_OUTPUTS_DIR not set")
	}
	metadataPath := filepath.Join(undeclaredDir, "bazel_target_metadata.json")
	metadataContent, err := os.ReadFile(metadataPath)
	if err != nil {
		t.Fatalf("read bazel_target_metadata.json: %v", err)
	}

	var metadata map[string]any
	if err := json.Unmarshal(metadataContent, &metadata); err != nil {
		t.Fatalf("decode bazel_target_metadata.json: %v", err)
	}
	if got, _ := metadata["bazel.target"].(string); got != "//src/go-project:hello_test" {
		t.Fatalf("bazel.target = %v, want //src/go-project:hello_test", metadata["bazel.target"])
	}
}
GO_TEST_GUIDED_EOF

cat > "$GUIDED_BOOT_WS/src/go-project/BUILD.bazel" <<'BUILD_GUIDED_EOF'
load("@rules_go//go:def.bzl", "go_library")
load("//tools/build:dd_go_test.bzl", "dd_go_test")

go_library(
    name = "hello_lib",
    srcs = ["main.go"],
    importpath = "example.com/guided-bootstrap-go",
)

dd_go_test(
    name = "hello_test",
    srcs = ["main_test.go"],
    embed = [":hello_lib"],
    stage_sources = True,
)
BUILD_GUIDED_EOF

(
  cd "$GUIDED_BOOT_WS"
  REAL_GO_BIN="$REAL_GO_BIN_HOST" PATH="$GUIDED_BOOT_WS/bin:$PATH" "$BAZEL" "${BAZEL_FLAGS[@]}" run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
    --workspace "$GUIDED_BOOT_WS" \
    --rules-go-remote "$RULES_GO_OVERRIDE_REMOTE" \
    --rules-go-commit "$RULES_GO_OVERRIDE_COMMIT" \
    --guided \
    --service "go-service" \
    --runtime-version "1.2.3"
)

if ! grep -q '# BEGIN Datadog Go Guided Setup' "$GUIDED_BOOT_WS/MODULE.bazel"; then
  echo "error: guided bootstrap did not add the managed Go guided setup block"
  cat "$GUIDED_BOOT_WS/MODULE.bazel" || true
  exit 1
fi
if ! grep -q 'test_optimization_go_extension' "$GUIDED_BOOT_WS/MODULE.bazel"; then
  echo "error: guided bootstrap did not add Go sync extension wiring"
  cat "$GUIDED_BOOT_WS/MODULE.bazel" || true
  exit 1
fi
if ! grep -q 'module_path = "example.com/guided-bootstrap-go"' "$GUIDED_BOOT_WS/MODULE.bazel"; then
  echo "error: guided bootstrap did not persist the Go module path in sync wiring"
  cat "$GUIDED_BOOT_WS/MODULE.bazel" || true
  exit 1
fi
if [ ! -f "$GUIDED_BOOT_WS/BUILD.bazel" ]; then
  echo "error: guided bootstrap did not create root BUILD.bazel"
  exit 1
fi
if ! grep -q '# BEGIN Datadog Go Uploader' "$GUIDED_BOOT_WS/BUILD.bazel"; then
  echo "error: guided bootstrap did not create the managed uploader block"
  cat "$GUIDED_BOOT_WS/BUILD.bazel" || true
  exit 1
fi
if [ ! -f "$GUIDED_BOOT_WS/tools/build/BUILD.bazel" ]; then
  echo "error: guided bootstrap did not create tools/build/BUILD.bazel"
  exit 1
fi
if [ ! -f "$GUIDED_BOOT_WS/tools/build/dd_go_test.bzl" ]; then
  echo "error: guided bootstrap did not create tools/build/dd_go_test.bzl"
  exit 1
fi
if ! grep -q '# BEGIN Datadog Go Wrapper' "$GUIDED_BOOT_WS/tools/build/dd_go_test.bzl"; then
  echo "error: guided bootstrap did not mark dd_go_test.bzl as Datadog-managed"
  cat "$GUIDED_BOOT_WS/tools/build/dd_go_test.bzl" || true
  exit 1
fi

(
  cd "$GUIDED_BOOT_WS"
  "$BAZEL" "${BAZEL_FLAGS[@]}" test //src/go-project:hello_test "${REPO_ENVS[@]}"
)

GUIDED_TESTLOGS_DIR="$(
  cd "$GUIDED_BOOT_WS"
  "$BAZEL" "${BAZEL_FLAGS[@]}" info bazel-testlogs "${REPO_ENVS[@]}"
)"
GUIDED_BAZEL_METADATA_PATH="$GUIDED_TESTLOGS_DIR/src/go-project/hello_test/test.outputs/bazel_target_metadata.json"
if [[ ! -f "$GUIDED_BAZEL_METADATA_PATH" ]]; then
  echo "error: guided bootstrap go test did not emit bazel_target_metadata.json"
  find "$GUIDED_TESTLOGS_DIR/src/go-project/hello_test" -maxdepth 3 -type f 2>/dev/null | sort || true
  exit 1
fi

GUIDED_BAZEL_METADATA_PATH="$GUIDED_BAZEL_METADATA_PATH" "$PYTHON" - <<'PY'
import json
import os
import sys

path = os.environ["GUIDED_BAZEL_METADATA_PATH"]
with open(path, "r", encoding = "utf-8") as handle:
    payload = json.load(handle)

required_keys = [
    "bazel.package",
    "bazel.target",
    "bazel.go.importpath",
    "bazel.go.importpath_source",
    "bazel.go.payload_selection",
    "bazel.go.orchestrion.enabled",
    "bazel.go.attr.cgo",
    "bazel.go.attr.pure",
    "bazel.go.attr.race",
    "bazel.go.attr.msan",
    "bazel.go.attr.linkmode",
]

missing = [key for key in required_keys if key not in payload]
if missing:
    print("error: guided bootstrap go test metadata is missing keys: %s" % ", ".join(missing))
    sys.exit(1)
PY

MULTI_LOG_START="$MULTI_LOG_START" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("MULTI_LOG_START", "0") or "0")
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

setting_requests = [rec for rec in records if rec.get("path") == "/api/v2/libraries/tests/services/setting"]
if len(setting_requests) < 2:
    print("error: multi-service scenario expected at least two settings requests")
    sys.exit(1)

services = set()
for rec in setting_requests:
    try:
        body = base64.b64decode(rec.get("body_b64", "")).decode("utf-8")
        payload = json.loads(body)
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    attrs = ((payload.get("data") or {}).get("attributes") or {})
    service = attrs.get("service")
    if isinstance(service, str) and service:
        services.add(service)

missing = {"go-service", "go_service"} - services
if missing:
    print("error: multi-service scenario missing expected service settings requests")
    print("missing:", sorted(missing))
    print("seen:", sorted(services))
    sys.exit(1)
PY

# Refresh the active bazel-testlogs path before the context-oriented uploader
# scenarios so they all read the same payload tree produced earlier in this
# workspace, even after other workspaces reuse the shared output base.
CONTEXT_SCENARIO_TESTLOGS_DIR="$("$BAZEL" "${BAZEL_FLAGS[@]}" info bazel-testlogs)"
if [[ ! -d "$CONTEXT_SCENARIO_TESTLOGS_DIR/write_payloads_test/test.outputs/payloads/tests" ]]; then
  echo "error: expected write_payloads_test payloads under refreshed bazel-testlogs path"
  echo "refreshed bazel-testlogs: $CONTEXT_SCENARIO_TESTLOGS_DIR"
  find "$CONTEXT_SCENARIO_TESTLOGS_DIR" -maxdepth 3 -type d 2>/dev/null | sort || true
  exit 1
fi

# Capture current log offset so we can isolate uploads produced specifically
# by the context-enriched uploader run below.
LOG_LINES_BEFORE_CONTEXT="$(log_line_count)"
UPLOADER_CONTEXT_LOG="$TMP_WS/uploader_with_context.log"
if ! TESTLOGS_DIR="$CONTEXT_SCENARIO_TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads_with_context \
  "${REPO_ENVS[@]}" >"$UPLOADER_CONTEXT_LOG" 2>&1; then
  echo "error: uploader command with context failed"
  cat "$UPLOADER_CONTEXT_LOG" || true
  exit 1
fi

LOG_LINES_BEFORE_CONTEXT="$LOG_LINES_BEFORE_CONTEXT" CONTEXT_JSON_PATH="$TOPT_DIR/context.json" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
context_path = os.environ["CONTEXT_JSON_PATH"]
start_line = int(os.environ.get("LOG_LINES_BEFORE_CONTEXT", "0") or "0")
with open(context_path, "r", encoding="utf-8") as handle:
    expected_context = json.load(handle)
expected_tags = {
    key: expected_context.get(key)
    for key in ("bazel.rule_name", "bazel.rule_version", "bazel.os", "bazel.arch")
}
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not records:
    print("error: expected context-enriched uploader run to add log records")
    sys.exit(1)

target_resource = "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest"
target_evt = None
for rec in reversed(records):
    if rec.get("path") != "/api/v2/citestcycle":
        continue
    try:
        cycle_payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    for evt in cycle_payload.get("events", []):
        if evt.get("type") != "test":
            continue
        content = evt.get("content") or {}
        if content.get("resource") != target_resource:
            continue
        target_evt = evt
        break
    if target_evt is not None:
        break
if target_evt is None:
    print("error: missing context-enriched test event after context run")
    sys.exit(1)

meta = ((target_evt.get("content") or {}).get("meta") or {})
owners_raw = meta.get("test.codeowners")
try:
    owners = json.loads(owners_raw) if owners_raw is not None else None
except json.JSONDecodeError:
    owners = "__invalid__"
if owners != ["@DataDog/ci-app-libraries-dotnet"]:
    print("error: expected CODEOWNERS value missing in context-enriched payload")
    sys.exit(1)
for key, value in expected_tags.items():
    if meta.get(key) != value:
        print(f"error: expected context tag mismatch in context-enriched payload: {key} -> {meta.get(key)!r} != {value!r}")
        sys.exit(1)
for key in ("test.bazel.rule_name", "test.bazel.rule_version"):
    if key in meta:
        print(f"error: legacy context tag unexpectedly present in context-enriched payload: {key}")
        sys.exit(1)
PY

# Scenario: runtime context override enriches uploads without re-running sync.
# This proves the uploader can reuse a previously-fetched context.json file
# while avoiding extra settings/test-management requests during `bazel run`.
CONTEXT_CQUERY_FAST_PATH=$("$BAZEL" "${BAZEL_FLAGS[@]}" cquery @test_optimization_data//:test_optimization_context --output=files \
  "${REPO_ENVS[@]}")
CONTEXT_JSON_FAST_PATH=$(echo "$CONTEXT_CQUERY_FAST_PATH" | awk 'NF { print; exit }')
if [[ -z "$CONTEXT_JSON_FAST_PATH" ]]; then
  echo "error: failed to resolve context.json for runtime override scenario"
  echo "$CONTEXT_CQUERY_FAST_PATH"
  exit 1
fi
if [[ "$CONTEXT_JSON_FAST_PATH" != /* && ! "$CONTEXT_JSON_FAST_PATH" =~ ^[A-Za-z]:[\\/] ]]; then
  for base in "$OUT_BASE" "$EXECROOT" "$WORKSPACE"; do
    [[ -z "$base" ]] && continue
    if [[ -f "$base/$CONTEXT_JSON_FAST_PATH" ]]; then
      CONTEXT_JSON_FAST_PATH="$base/$CONTEXT_JSON_FAST_PATH"
      break
    fi
  done
fi
if [[ ! -f "$CONTEXT_JSON_FAST_PATH" ]]; then
  echo "error: runtime override context.json not found: $CONTEXT_JSON_FAST_PATH"
  echo "$CONTEXT_CQUERY_FAST_PATH"
  exit 1
fi

LOG_LINES_BEFORE_CONTEXT_OVERRIDE="$(log_line_count)"
UPLOADER_CONTEXT_OVERRIDE_LOG="$TMP_WS/uploader_context_override.log"
if ! TESTLOGS_DIR="$CONTEXT_SCENARIO_TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CONTEXT_JSON="$CONTEXT_JSON_FAST_PATH" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_CONTEXT_OVERRIDE_LOG" 2>&1; then
  echo "error: uploader command with runtime context override failed"
  cat "$UPLOADER_CONTEXT_OVERRIDE_LOG" || true
  exit 1
fi

LOG_LINES_BEFORE_CONTEXT_OVERRIDE="$LOG_LINES_BEFORE_CONTEXT_OVERRIDE" CONTEXT_JSON_PATH="$TOPT_DIR/context.json" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
context_path = os.environ["CONTEXT_JSON_PATH"]
start_line = int(os.environ.get("LOG_LINES_BEFORE_CONTEXT_OVERRIDE", "0") or "0")
with open(context_path, "r", encoding="utf-8") as handle:
    expected_context = json.load(handle)
expected_tags = {
    key: expected_context.get(key)
    for key in ("bazel.rule_name", "bazel.rule_version", "bazel.os", "bazel.arch")
}
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not records:
    print("error: expected runtime-context uploader run to add log records")
    sys.exit(1)

setting_requests = [rec for rec in records if rec.get("path") == "/api/v2/libraries/tests/services/setting"]
if setting_requests:
    print("error: runtime-context uploader run unexpectedly reissued settings requests")
    sys.exit(1)

tm_requests = [rec for rec in records if rec.get("path") == "/api/v2/test/libraries/test-management/tests"]
if tm_requests:
    print("error: runtime-context uploader run unexpectedly reissued test-management requests")
    sys.exit(1)

target_resource = "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest"
target_evt = None
for rec in reversed(records):
    if rec.get("path") != "/api/v2/citestcycle":
        continue
    try:
        cycle_payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    for evt in cycle_payload.get("events", []):
        if evt.get("type") != "test":
            continue
        content = evt.get("content") or {}
        if content.get("resource") != target_resource:
            continue
        target_evt = evt
        break
    if target_evt is not None:
        break
if target_evt is None:
    print("error: missing context-enriched test event after runtime-context uploader run")
    sys.exit(1)
meta = ((target_evt.get("content") or {}).get("meta") or {})
for key, value in expected_tags.items():
    if meta.get(key) != value:
        print(f"error: runtime-context uploader run missing expected context tag {key}: {meta.get(key)!r} != {value!r}")
        sys.exit(1)
for key in ("test.bazel.rule_name", "test.bazel.rule_version"):
    if key in meta:
        print(f"error: runtime-context uploader run still contains legacy context tag: {key}")
        sys.exit(1)
PY

# Scenario: per-target Bazel metadata sidecars are merged into uploaded events.
# The guided bootstrap scenario above verifies the real wrapper emits this file.
# This focused scenario keeps the uploader merge contract isolated from the test
# execution path by writing the same sidecar into test.outputs directly.
BAZEL_TARGET_METADATA_PATH="$CONTEXT_SCENARIO_TESTLOGS_DIR/write_payloads_test/test.outputs/bazel_target_metadata.json"
chmod -R u+w "$CONTEXT_SCENARIO_TESTLOGS_DIR/write_payloads_test/test.outputs" 2>/dev/null || true
cat > "$BAZEL_TARGET_METADATA_PATH" <<'JSON_EOF'
{
  "bazel.package": "//src/go-project",
  "bazel.target": "//src/go-project:hello_test",
  "bazel.test_optimization.repo_name": "test_optimization_data",
  "bazel.go.importpath": "example.com/sidecar/pkg",
  "bazel.go.importpath_source": "inferred",
  "bazel.go.payload_selection": "module",
  "bazel.go.orchestrion.enabled": true,
  "bazel.go.attr.cgo": false,
  "bazel.go.attr.pure": "auto",
  "bazel.go.attr.race": "auto",
  "bazel.go.attr.msan": "auto",
  "bazel.go.attr.linkmode": "auto",
  "bazel.go.attr.goos": "linux",
  "bazel.go.attr.goarch": "amd64"
}
JSON_EOF

LOG_LINES_BEFORE_BAZEL_SIDECAR="$(log_line_count)"
UPLOADER_BAZEL_SIDECAR_LOG="$TMP_WS/uploader_bazel_sidecar.log"
if ! TESTLOGS_DIR="$CONTEXT_SCENARIO_TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads_with_context \
  "${REPO_ENVS[@]}" >"$UPLOADER_BAZEL_SIDECAR_LOG" 2>&1; then
  echo "error: uploader command with Bazel sidecar metadata failed"
  cat "$UPLOADER_BAZEL_SIDECAR_LOG" || true
  exit 1
fi

LOG_LINES_BEFORE_BAZEL_SIDECAR="$LOG_LINES_BEFORE_BAZEL_SIDECAR" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("LOG_LINES_BEFORE_BAZEL_SIDECAR", "0") or "0")
expected_tags = {
    "bazel.package": "//src/go-project",
    "bazel.target": "//src/go-project:hello_test",
    "bazel.test_optimization.repo_name": "test_optimization_data",
    "bazel.go.importpath": "example.com/sidecar/pkg",
    "bazel.go.importpath_source": "inferred",
    "bazel.go.payload_selection": "module",
    "bazel.go.orchestrion.enabled": "true",
    "bazel.go.attr.cgo": "false",
    "bazel.go.attr.pure": "auto",
    "bazel.go.attr.race": "auto",
    "bazel.go.attr.msan": "auto",
    "bazel.go.attr.linkmode": "auto",
    "bazel.go.attr.goos": "linux",
    "bazel.go.attr.goarch": "amd64",
}

records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

target_resource = "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest"
target_evt = None
for rec in reversed(records):
    if rec.get("path") != "/api/v2/citestcycle":
        continue
    try:
        cycle_payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    for evt in cycle_payload.get("events", []):
        if evt.get("type") != "test":
            continue
        content = evt.get("content") or {}
        if content.get("resource") != target_resource:
            continue
        target_evt = evt
        break
    if target_evt is not None:
        break

if target_evt is None:
    print("error: missing test event after Bazel sidecar uploader run")
    sys.exit(1)

meta = ((target_evt.get("content") or {}).get("meta") or {})
for key, value in expected_tags.items():
    if meta.get(key) != value:
        print(f"error: Bazel sidecar tag mismatch for {key}: {meta.get(key)!r} != {value!r}")
        sys.exit(1)
PY

rm -f "$BAZEL_TARGET_METADATA_PATH"

# Scenario: when multiple bundled contexts are present, the uploader must
# select the context that matches the payload-side repo selector.
cat > "$BAZEL_TARGET_METADATA_PATH" <<'JSON_EOF'
{
  "bazel.package": "//src/nodejs-project",
  "bazel.target": "//src/nodejs-project:hello_test",
  "bazel.test_optimization.repo_name": "test_optimization_data_nodejs",
  "bazel.test_optimization.service_name": "mock-service-nodejs",
  "bazel.test_optimization.runtime_name": "nodejs"
}
JSON_EOF

LOG_LINES_BEFORE_MULTI_CONTEXT="$(log_line_count)"
UPLOADER_MULTI_CONTEXT_LOG="$TMP_WS/uploader_multi_context.log"
if ! TESTLOGS_DIR="$CONTEXT_SCENARIO_TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads_multi_context \
  "${REPO_ENVS[@]}" >"$UPLOADER_MULTI_CONTEXT_LOG" 2>&1; then
  echo "error: uploader command with multiple bundled contexts failed"
  cat "$UPLOADER_MULTI_CONTEXT_LOG" || true
  exit 1
fi

LOG_LINES_BEFORE_MULTI_CONTEXT="$LOG_LINES_BEFORE_MULTI_CONTEXT" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("LOG_LINES_BEFORE_MULTI_CONTEXT", "0") or "0")
target_package = "//src/nodejs-project"

records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

target_resource = "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest"
target_evt = None
for rec in reversed(records):
    if rec.get("path") != "/api/v2/citestcycle":
        continue
    try:
        cycle_payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    for evt in cycle_payload.get("events", []):
        if evt.get("type") != "test":
            continue
        content = evt.get("content") or {}
        if content.get("resource") != target_resource:
            continue
        meta = content.get("meta") or {}
        if meta.get("bazel.package") != target_package:
            continue
        target_evt = evt
        break
    if target_evt is not None:
        break

if target_evt is None:
    print("error: missing test event after multi-context uploader run")
    sys.exit(1)

meta = ((target_evt.get("content") or {}).get("meta") or {})
expected_tags = {
    "bazel.package": "//src/nodejs-project",
    "bazel.target": "//src/nodejs-project:hello_test",
    "bazel.test_optimization.repo_name": "test_optimization_data_nodejs",
    "bazel.test_optimization.service_name": "mock-service-nodejs",
    "bazel.test_optimization.runtime_name": "nodejs",
    "runtime.name": "nodejs",
    "runtime.version": "1.2.3",
    "service.name": "mock-service-nodejs",
}
for key, value in expected_tags.items():
    if meta.get(key) != value:
        print(f"error: multi-context uploader tag mismatch for {key}: {meta.get(key)!r} != {value!r}")
        sys.exit(1)

for key, expected in {
    "runtime.name": "go",
    "service.name": "mock-service",
}.items():
    if meta.get(key) == expected:
        print(f"error: multi-context uploader reused the wrong context tag {key}: {meta.get(key)!r}")
        sys.exit(1)
PY

# Scenario: when no bundled context matches the payload selector, uploader
# continues with Bazel sidecar tags only and skips bundled-context enrichment.
cat > "$BAZEL_TARGET_METADATA_PATH" <<'JSON_EOF'
{
  "bazel.package": "//src/python-project",
  "bazel.target": "//src/python-project:hello_test",
  "bazel.test_optimization.repo_name": "missing_runtime_repo"
}
JSON_EOF

LOG_LINES_BEFORE_MULTI_CONTEXT_MISS="$(log_line_count)"
UPLOADER_MULTI_CONTEXT_MISS_LOG="$TMP_WS/uploader_multi_context_missing_repo.log"
if ! TESTLOGS_DIR="$CONTEXT_SCENARIO_TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads_multi_context \
  "${REPO_ENVS[@]}" >"$UPLOADER_MULTI_CONTEXT_MISS_LOG" 2>&1; then
  echo "error: uploader command with missing multi-context match failed"
  cat "$UPLOADER_MULTI_CONTEXT_MISS_LOG" || true
  exit 1
fi

if ! grep -q "no bundled context matched repo 'missing_runtime_repo'" "$UPLOADER_MULTI_CONTEXT_MISS_LOG"; then
  echo "error: missing expected warning for unmatched multi-context payload"
  cat "$UPLOADER_MULTI_CONTEXT_MISS_LOG" || true
  exit 1
fi

LOG_LINES_BEFORE_MULTI_CONTEXT_MISS="$LOG_LINES_BEFORE_MULTI_CONTEXT_MISS" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("LOG_LINES_BEFORE_MULTI_CONTEXT_MISS", "0") or "0")

records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

target_resource = "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest"
target_package = "//src/python-project"
target_evt = None
for rec in reversed(records):
    if rec.get("path") != "/api/v2/citestcycle":
        continue
    try:
        cycle_payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    for evt in cycle_payload.get("events", []):
        if evt.get("type") != "test":
            continue
        content = evt.get("content") or {}
        if content.get("resource") != target_resource:
            continue
        meta = content.get("meta") or {}
        if meta.get("bazel.package") != target_package:
            continue
        target_evt = evt
        break
    if target_evt is not None:
        break

if target_evt is None:
    print("error: missing test event after unmatched multi-context uploader run")
    sys.exit(1)

meta = ((target_evt.get("content") or {}).get("meta") or {})
expected_tags = {
    "bazel.package": "//src/python-project",
    "bazel.target": "//src/python-project:hello_test",
    "bazel.test_optimization.repo_name": "missing_runtime_repo",
}
for key, value in expected_tags.items():
    if meta.get(key) != value:
        print(f"error: unmatched multi-context Bazel tag mismatch for {key}: {meta.get(key)!r} != {value!r}")
        sys.exit(1)

for key, forbidden in {
    "runtime.name": {"go", "nodejs"},
    "runtime.version": {"1.2.3"},
    "service.name": {"mock-service", "mock-service-nodejs"},
}.items():
    if meta.get(key) in forbidden:
        print(f"error: unmatched multi-context run unexpectedly injected bundled context tag {key}: {meta.get(key)!r}")
        sys.exit(1)
PY

rm -f "$BAZEL_TARGET_METADATA_PATH"

# Scenario: an unreadable runtime override must fall back to bundled context
# data instead of disabling enrichment entirely.
LOG_LINES_BEFORE_BAD_OVERRIDE="$(log_line_count)"
UPLOADER_BAD_OVERRIDE_LOG="$TMP_WS/uploader_bad_context_override.log"
if ! TESTLOGS_DIR="$CONTEXT_SCENARIO_TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CONTEXT_JSON="$TMP_WS/does-not-exist/context.json" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads_with_context \
  "${REPO_ENVS[@]}" >"$UPLOADER_BAD_OVERRIDE_LOG" 2>&1; then
  echo "error: uploader command with invalid runtime context override failed"
  cat "$UPLOADER_BAD_OVERRIDE_LOG" || true
  exit 1
fi

LOG_LINES_BEFORE_BAD_OVERRIDE="$LOG_LINES_BEFORE_BAD_OVERRIDE" CONTEXT_JSON_PATH="$TOPT_DIR/context.json" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
context_path = os.environ["CONTEXT_JSON_PATH"]
start_line = int(os.environ.get("LOG_LINES_BEFORE_BAD_OVERRIDE", "0") or "0")
with open(context_path, "r", encoding="utf-8") as handle:
    expected_context = json.load(handle)
expected_tags = {
    key: expected_context.get(key)
    for key in ("bazel.rule_name", "bazel.rule_version", "bazel.os", "bazel.arch")
}
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

target_resource = "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest"
target_evt = None
for rec in reversed(records):
    if rec.get("path") != "/api/v2/citestcycle":
        continue
    try:
        cycle_payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    for evt in cycle_payload.get("events", []):
        if evt.get("type") != "test":
            continue
        content = evt.get("content") or {}
        if content.get("resource") != target_resource:
            continue
        target_evt = evt
        break
    if target_evt is not None:
        break

if target_evt is None:
    print("error: invalid runtime override did not fall back to bundled context enrichment")
    sys.exit(1)
meta = ((target_evt.get("content") or {}).get("meta") or {})
for key, value in expected_tags.items():
    if meta.get(key) != value:
        print(f"error: invalid runtime override fallback missing expected context tag {key}: {meta.get(key)!r} != {value!r}")
        sys.exit(1)
for key in ("test.bazel.rule_name", "test.bazel.rule_version"):
    if key in meta:
        print(f"error: invalid runtime override fallback still contains legacy context tag: {key}")
        sys.exit(1)
PY

ORIG_CODEOWNERS="$WORKSPACE/CODEOWNERS.orig"
cp "$WORKSPACE/CODEOWNERS" "$ORIG_CODEOWNERS"

# Scenario: missing CODEOWNERS file must not fail uploads and must not inject new owners.
# This guards the "best effort enrichment" contract: uploader success must not
# depend on CODEOWNERS availability.
mv "$WORKSPACE/CODEOWNERS" "$WORKSPACE/CODEOWNERS.bak"
MANUAL_NO_CO="$TESTLOGS_DIR/manual_no_codeowners/test.outputs"
mkdir -p "$MANUAL_NO_CO/payloads/tests" "$MANUAL_NO_CO/payloads/coverage"
cat > "$MANUAL_NO_CO/payloads/tests/manual_no_codeowners.json" <<'JSON_EOF'
{
  "metadata": {
    "*": {
      "language": "go",
      "library_version": "1.0.0"
    }
  },
  "events": [
    {
      "type": "test",
      "content": {
        "resource": "Manual.NoCodeowners",
        "meta": {
          "test.source.file": "manual/no_codeowners.cs"
        }
      }
    }
  ]
}
JSON_EOF
echo '{}' > "$MANUAL_NO_CO/payloads/coverage/manual_no_codeowners_cov.json"

UPLOADER_NO_CO_LOG="$TMP_WS/uploader_no_codeowners.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_NO_CO_LOG" 2>&1; then
  echo "error: uploader command without CODEOWNERS failed"
  cat "$UPLOADER_NO_CO_LOG" || true
  exit 1
fi

"$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
target = "Manual.NoCodeowners"
payload = None

with open(log_path, "r", encoding="utf-8") as handle:
    rows = []
    for line in handle:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue

for rec in reversed(rows):
    if rec.get("path") != "/api/v2/citestcycle":
        continue
    try:
        body = base64.b64decode(rec.get("body_b64", ""))
        obj = json.loads(body.decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    for evt in obj.get("events", []):
        content = evt.get("content") or {}
        if content.get("resource") == target:
            payload = obj
            break
    if payload is not None:
        break

if payload is None:
    print("error: missing Manual.NoCodeowners upload")
    sys.exit(1)

target_evt = None
for evt in payload.get("events", []):
    if (evt.get("content") or {}).get("resource") == target:
        target_evt = evt
        break
if target_evt is None:
    print("error: Manual.NoCodeowners event not found")
    sys.exit(1)
meta = ((target_evt.get("content") or {}).get("meta") or {})
if "test.codeowners" in meta:
    print("error: test.codeowners unexpectedly injected when CODEOWNERS file is missing")
    sys.exit(1)
PY

mv "$WORKSPACE/CODEOWNERS.bak" "$WORKSPACE/CODEOWNERS"

# Scenario: empty-owner rule should not set test.codeowners while preserving fallback/source-key behavior.
# This is intentionally broad and table-driven: each synthetic resource maps to
# one parser/normalization edge case so regressions are easy to localize.
cat > "$WORKSPACE/CODEOWNERS" <<'CODEOWNERS_EOF'
[CoreTeam]
[Core Team] @org/section-space
* @org/default
[xy] @org/class-owner
[abc] @org/class-owner-abc
[A1B2C3] @org/class-owner-alnum-long
[ABCD] @org/class-owner-upper-long
[ABC] @org/class-owner-upper
[Abc] @org/class-owner-mixed
[Backend] @org/section-default
/manual/owned.cs @org/owned
/manual/unowned.cs
/manual/comment_only.cs # explicit empty-owner rule via inline comment
/manual/hash_owner.cs @org/team#chat
/manual/space\ owner.cs @org/space-owner
/manual/dir/ @org/dir-owner
/manual/literal\*.cs @org/literal-star
/manual/literal\?.cs @org/literal-question
/manual/literal\[ab\].cs @org/literal-brackets
/manual/duplicate_owners.cs @org/dedupe @org/dedupe @org/extra
/manual/last_match.cs @org/first
/manual/last_match.cs @org/second
/manual/override_empty.cs @org/will-be-overridden
/manual/override_empty.cs
/manual/file_scheme.cs @org/file-scheme
/manual/percent_slash.cs @org/percent-slash
/manual/dotnorm.cs @org/dotnorm
/external/local/file.cs @org/repo-external
# Intentionally malformed range class. This line exercises "best effort"
# behavior: parser/matcher must ignore invalid regex outputs and still allow
# later processing/fallback ownership resolution for unrelated files.
/manual/[z-a].cs @org/invalid-range
CODEOWNERS_EOF
# Validate first-unescaped-whitespace splitting with a TAB separator too.
# This catches parser regressions where "\t" delimiters are ignored.
printf '/manual/tab_sep.cs\t@org/tab-owner\n' >> "$WORKSPACE/CODEOWNERS"

MANUAL_EMPTY_OWNER="$TESTLOGS_DIR/manual_empty_owner/test.outputs"
mkdir -p "$MANUAL_EMPTY_OWNER/payloads/tests" "$MANUAL_EMPTY_OWNER/payloads/coverage"
cat > "$MANUAL_EMPTY_OWNER/payloads/tests/manual_empty_owner.json" <<'JSON_EOF'
{
  "metadata": {
    "*": {
      "language": "go",
      "library_version": "1.0.0"
    }
  },
  "events": [
    {
      "type": "test",
      "content": {
        "resource": "Manual.Owned",
        "meta": {
          "test.source.file": "manual/owned.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.Unowned",
        "meta": {
          "test.source.path": "manual/unowned.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.SourceFallback",
        "source": {
          "path": "manual/owned.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.Default",
        "meta": {
          "source.file": "manual/default.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.CommentOnly",
        "meta": {
          "test.source.file": "manual/comment_only.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.HashOwner",
        "meta": {
          "test.source.file": "manual/hash_owner.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.SpaceOwner",
        "meta": {
          "test.source.file": "manual/space owner.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.DirectoryRule",
        "meta": {
          "test.source.file": "manual/dir/sub/file.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.LiteralStar",
        "meta": {
          "test.source.file": "manual/literal*.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.LiteralQuestion",
        "meta": {
          "test.source.file": "manual/literal?.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.LiteralBrackets",
        "meta": {
          "test.source.file": "manual/literal[ab].cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.DuplicateOwners",
        "meta": {
          "test.source.file": "manual/duplicate_owners.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.LastMatchWins",
        "meta": {
          "test.source.file": "manual/last_match.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.OverrideEmpty",
        "meta": {
          "test.source.file": "manual/override_empty.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.FileScheme",
        "meta": {
          "test.source.file": "file://manual/file_scheme.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.PercentSlash",
        "meta": {
          "test.source.file": "manual%2Fpercent_slash.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.DotNormalization",
        "meta": {
          "test.source.file": "./manual/sub/../dotnorm.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.PathTraversalRejected",
        "meta": {
          "test.source.file": "../manual/owned.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.NullEscapeNoDecode",
        "meta": {
          "test.source.file": "manual%00owned.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.MalformedPercent",
        "meta": {
          "test.source.file": "manual%2Gbad.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.RunfilesMain",
        "meta": {
          "test.source.file": "/tmp/mock.runfiles/_main/manual/owned.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.RunfilesExternal",
        "meta": {
          "test.source.file": "/tmp/mock.runfiles/_main/external/rules_go/pkg/file.go"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.ExecrootMain",
        "meta": {
          "test.source.file": "/tmp/execroot/mock_ws/_main/manual/owned.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.TabOwner",
        "meta": {
          "test.source.file": "manual/tab_sep.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.CharClass",
        "meta": {
          "test.source.file": "x"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.CharClassLong",
        "meta": {
          "test.source.file": "a"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.CharClassUpper",
        "meta": {
          "test.source.file": "B"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.CharClassUpperLong",
        "meta": {
          "test.source.file": "D"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.CharClassAlnumLong",
        "meta": {
          "test.source.file": "2"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.CharClassMixed",
        "meta": {
          "test.source.file": "b"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.SectionHeaderWithSpaceIgnored",
        "meta": {
          "test.source.file": "[Core"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.InvalidRange",
        "meta": {
          "test.source.file": "manual/invalid_range.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.EncodedBackslash",
        "meta": {
          "test.source.file": "manual%5Cowned.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.ExternalAbsolutePath",
        "meta": {
          "test.source.file": "/tmp/not-in-workspace/manual_external.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.ExecrootExternalPath",
        "meta": {
          "test.source.file": "/tmp/execroot/mock_ws/external/rules_go/pkg/file.go"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.RepoRelativeExternalPath",
        "meta": {
          "test.source.file": "external/local/file.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.PreservedExisting",
        "meta": {
          "test.source.file": "manual/owned.cs",
          "test.codeowners": "[\"@org/preexisting\"]"
        }
      }
    },
    {
      "type": "test_suite_end",
      "content": {
        "resource": "Manual.PreservedSuiteEnd",
        "meta": {
          "test.source.file": "manual/owned.cs",
          "test.codeowners": "[\"@org/preexisting-suite\"]"
        }
      }
    },
    {
      "type": "test_module_end",
      "content": {
        "resource": "Manual.PreservedModuleEnd",
        "meta": {
          "test.source.file": "manual/owned.cs",
          "test.codeowners": "[\"@org/preexisting-module\"]"
        }
      }
    },
    {
      "type": "test_session_end",
      "content": {
        "resource": "Manual.PreservedSessionEnd",
        "meta": {
          "test.source.file": "manual/owned.cs",
          "test.codeowners": "[\"@org/preexisting-session\"]"
        }
      }
    },
    {
      "type": "span",
      "content": {
        "resource": "Manual.SpanSkipped",
        "meta": {
          "test.source.file": "manual/owned.cs"
        }
      }
    },
    {
      "type": "test_module_end",
      "content": {
        "resource": "Manual.ModuleEndOwned",
        "meta": {
          "test.source.file": "manual/owned.cs"
        }
      }
    },
    {
      "type": "test",
      "content": {
        "resource": "Manual.SectionHeaderIgnored",
        "meta": {
          "test.source.file": "manual/z/file.cs"
        }
      }
    }
  ]
}
JSON_EOF
echo '{}' > "$MANUAL_EMPTY_OWNER/payloads/coverage/manual_empty_owner_cov.json"

UPLOADER_EMPTY_OWNER_LOG="$TMP_WS/uploader_empty_owner.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_EMPTY_OWNER_LOG" 2>&1; then
  echo "error: uploader command for empty-owner scenario failed"
  cat "$UPLOADER_EMPTY_OWNER_LOG" || true
  exit 1
fi

"$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
target_resource = "Manual.Unowned"
payload = None
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

for rec in reversed(records):
    if rec.get("path") != "/api/v2/citestcycle":
        continue
    try:
        obj = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    for evt in obj.get("events", []):
        if (evt.get("content") or {}).get("resource") == target_resource:
            payload = obj
            break
    if payload is not None:
        break

if payload is None:
    print("error: missing empty-owner scenario upload")
    sys.exit(1)

def owners_for(resource):
    for evt in payload.get("events", []):
        if (evt.get("content") or {}).get("resource") != resource:
            continue
        meta = ((evt.get("content") or {}).get("meta") or {})
        raw = meta.get("test.codeowners")
        if raw is None:
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return "__invalid__"
    return None

# Keep this scenario table-driven so new CODEOWNERS edge cases are easy to add
# without duplicating assertion boilerplate.
checks = [
    ("Manual.Owned", ["@org/owned"], "should resolve explicit owner rule"),
    ("Manual.Unowned", None, "should not set test.codeowners when no owners resolve"),
    ("Manual.CommentOnly", None, "should not set test.codeowners when owner segment is comment-only"),
    ("Manual.HashOwner", ["@org/team#chat"], "should preserve '#' inside owner token"),
    ("Manual.SpaceOwner", ["@org/space-owner"], "should resolve escaped-space CODEOWNERS pattern"),
    ("Manual.DirectoryRule", ["@org/dir-owner"], "should resolve trailing-slash directory CODEOWNERS rule"),
    ("Manual.LiteralStar", ["@org/literal-star"], "should resolve escaped '*' CODEOWNERS pattern"),
    ("Manual.LiteralQuestion", ["@org/literal-question"], "should resolve escaped '?' CODEOWNERS pattern"),
    ("Manual.LiteralBrackets", ["@org/literal-brackets"], "should resolve escaped bracket CODEOWNERS pattern"),
    ("Manual.DuplicateOwners", ["@org/dedupe", "@org/extra"], "should dedupe owners while preserving order"),
    ("Manual.LastMatchWins", ["@org/second"], "should honor last matching CODEOWNERS rule"),
    ("Manual.OverrideEmpty", None, "should not set owners when final matching rule has no owners"),
    ("Manual.FileScheme", ["@org/file-scheme"], "should resolve file:// source paths"),
    ("Manual.PercentSlash", ["@org/percent-slash"], "should decode %2F before matching"),
    ("Manual.DotNormalization", ["@org/dotnorm"], "should normalize dot-segment source paths"),
    ("Manual.PathTraversalRejected", None, "should ignore source paths escaping repository root"),
    ("Manual.NullEscapeNoDecode", ["@org/default"], "should avoid decoding %00 and fall back safely"),
    ("Manual.MalformedPercent", ["@org/default"], "should keep malformed percent encoding and fall back safely"),
    ("Manual.RunfilesMain", ["@org/owned"], "should resolve runfiles _main source paths"),
    ("Manual.RunfilesExternal", None, "should not inherit repo owners for runfiles external dependency paths"),
    ("Manual.ExecrootMain", ["@org/owned"], "should resolve execroot _main source paths"),
    ("Manual.TabOwner", ["@org/tab-owner"], "should resolve tab-separated CODEOWNERS owner list"),
    ("Manual.CharClass", ["@org/class-owner"], "should resolve bracket-only class CODEOWNERS pattern"),
    ("Manual.CharClassLong", ["@org/class-owner-abc"], "should resolve longer bracket-only class CODEOWNERS pattern"),
    ("Manual.CharClassUpper", ["@org/class-owner-upper"], "should resolve uppercase bracket-only class CODEOWNERS pattern"),
    ("Manual.CharClassUpperLong", ["@org/class-owner-upper-long"], "should resolve long uppercase bracket-only class CODEOWNERS pattern"),
    ("Manual.CharClassAlnumLong", ["@org/class-owner-alnum-long"], "should resolve long uppercase-alnum bracket-only class CODEOWNERS pattern"),
    ("Manual.CharClassMixed", ["@org/class-owner-mixed"], "should resolve mixed-case bracket-only class CODEOWNERS pattern"),
    ("Manual.SectionHeaderWithSpaceIgnored", ["@org/default"], "should ignore spaced GitLab section headers"),
    ("Manual.InvalidRange", ["@org/default"], "should ignore malformed regex rule and keep fallback owner"),
    ("Manual.EncodedBackslash", ["@org/owned"], "should normalize %5C separators before matching"),
    ("Manual.ExternalAbsolutePath", None, "should not inherit repo CODEOWNERS from absolute non-repo paths"),
    ("Manual.ExecrootExternalPath", None, "should not inherit repo CODEOWNERS from execroot external dependency paths"),
    ("Manual.RepoRelativeExternalPath", ["@org/repo-external"], "should still resolve repository-owned external/ paths"),
    ("Manual.PreservedExisting", ["@org/preexisting"], "should keep producer-provided test.codeowners value"),
    ("Manual.PreservedSuiteEnd", ["@org/preexisting-suite"], "should preserve producer-provided owners on test_suite_end events"),
    ("Manual.PreservedModuleEnd", ["@org/preexisting-module"], "should preserve producer-provided owners on test_module_end events"),
    ("Manual.PreservedSessionEnd", ["@org/preexisting-session"], "should preserve producer-provided owners on test_session_end events"),
    ("Manual.SpanSkipped", None, "should not enrich span events"),
    ("Manual.ModuleEndOwned", ["@org/owned"], "should enrich test_module_end events when source path resolves"),
    ("Manual.SectionHeaderIgnored", ["@org/default"], "should ignore GitLab section-owner headers"),
    ("Manual.SourceFallback", ["@org/owned"], "should resolve through content.source.path fallback"),
    ("Manual.Default", ["@org/default"], "should resolve fallback '*' rule"),
]

failures = []
for resource, expected, behavior in checks:
    actual = owners_for(resource)
    if actual != expected:
        failures.append(
            f"{resource}: {behavior} (expected={expected!r}, got={actual!r})",
        )

if failures:
    print("error: empty-owner scenario CODEOWNERS assertions failed")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
PY

# Scenario: filter_prefix + gzip should only upload prefixed files and send
# gzipped citestcycle bodies when gzip is available on the host.
MANUAL_FILTER_GZIP="$TESTLOGS_DIR/manual_filter_gzip/test.outputs"
mkdir -p "$MANUAL_FILTER_GZIP/payloads/tests" "$MANUAL_FILTER_GZIP/payloads/coverage"
SOURCE_TEST_PAYLOAD="$REPO_ROOT/tools/tests/integration/snapshots/citestcycle.json"
SOURCE_COVERAGE_PAYLOAD="$TESTLOGS_DIR/write_payloads_test/test.outputs/payloads/coverage/cov1.json"
if [[ ! -f "$SOURCE_TEST_PAYLOAD" || ! -f "$SOURCE_COVERAGE_PAYLOAD" ]]; then
  echo "error: missing source payload fixtures for filter/gzip scenario"
  echo "  test payload: $SOURCE_TEST_PAYLOAD"
  echo "  coverage payload: $SOURCE_COVERAGE_PAYLOAD"
  exit 1
fi
cp "$SOURCE_TEST_PAYLOAD" "$MANUAL_FILTER_GZIP/payloads/tests/span_events_manual_filter_keep.json"
cp "$SOURCE_TEST_PAYLOAD" "$MANUAL_FILTER_GZIP/payloads/tests/manual_filter_skip.json"
cp "$SOURCE_COVERAGE_PAYLOAD" "$MANUAL_FILTER_GZIP/payloads/coverage/coverage_manual_filter_keep.json"
cp "$SOURCE_COVERAGE_PAYLOAD" "$MANUAL_FILTER_GZIP/payloads/coverage/manual_filter_skip_cov.json"

FILTER_GZIP_LOG_START="$(log_line_count)"
UPLOADER_FILTER_GZIP_LOG="$TMP_WS/uploader_filter_gzip.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_DEBUG=1 \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_FILTER_PREFIX=1 \
DD_TEST_OPTIMIZATION_GZIP=1 \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_FILTER_GZIP_LOG" 2>&1; then
  echo "error: uploader filter/gzip scenario run failed"
  cat "$UPLOADER_FILTER_GZIP_LOG" || true
  exit 1
fi

FILTER_GZIP_LOG_START="$FILTER_GZIP_LOG_START" UPLOADER_FILTER_GZIP_LOG="$UPLOADER_FILTER_GZIP_LOG" "$PYTHON" - <<'PY'
import base64
import gzip
import json
import os
import platform
import re
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("FILTER_GZIP_LOG_START", "0") or "0")
uploader_log_path = os.environ.get("UPLOADER_FILTER_GZIP_LOG", "")
uploader_log = ""
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

if not records:
    print("error: expected filter/gzip scenario to add log records")
    sys.exit(1)

if uploader_log_path:
    with open(uploader_log_path, "r", encoding="utf-8", errors="replace") as handle:
        uploader_log = handle.read()

uploaded_test_keep = bool(re.search(r"uploaded test payload: .*span_events_manual_filter_keep\.json", uploader_log))
uploaded_cov_keep = bool(re.search(r"uploaded coverage payload: .*coverage_manual_filter_keep\.json", uploader_log))
uploaded_test_skip = bool(re.search(r"uploaded test payload: .*manual_filter_skip\.json", uploader_log))
uploaded_cov_skip = bool(re.search(r"uploaded coverage payload: .*manual_filter_skip_cov\.json", uploader_log))

if not uploaded_test_keep:
    print("error: expected uploader log to include uploaded span_events_manual_filter_keep.json")
    sys.exit(1)
if not uploaded_cov_keep:
    print("error: expected uploader log to include uploaded coverage_manual_filter_keep.json")
    sys.exit(1)
if uploaded_test_skip:
    print("error: expected uploader log to exclude uploaded manual_filter_skip.json")
    sys.exit(1)
if uploaded_cov_skip:
    print("error: expected uploader log to exclude uploaded manual_filter_skip_cov.json")
    sys.exit(1)

def lower_headers(record):
    return {str(k).lower(): str(v) for k, v in ((record.get("headers") or {}).items())}

def decode_body(record):
    body = base64.b64decode(record.get("body_b64", ""))
    headers = lower_headers(record)
    if "gzip" in headers.get("content-encoding", "").lower():
        body = gzip.decompress(body)
    return body, headers

gzip_header_seen = False
cycle_seen = False
coverage_seen = False
uploader_log_lower = uploader_log.lower()
gzip_hint_seen = (
    "content-encoding=gzip" in uploader_log_lower or
    "content-encoding: gzip" in uploader_log_lower
)
gzip_enabled_hint = (
    "gzip enabled: 1" in uploader_log_lower or
    "gzip enabled: true" in uploader_log_lower
)
gzip_disabled_hint = (
    "warning: dd_test_optimization_gzip=1 but gzip not found" in uploader_log_lower or
    "warning: gzip failed; sending uncompressed payload" in uploader_log_lower
)
is_windows = platform.system().lower().startswith("win")
expect_gzip = (gzip_enabled_hint and not gzip_disabled_hint) if is_windows else (not gzip_disabled_hint)
test_paths = {
    "/api/v2/citestcycle",
    "/evp_proxy/v2/api/v2/citestcycle",
}
coverage_paths = {
    "/api/v2/citestcov",
    "/evp_proxy/v2/api/v2/citestcov",
}

for rec in records:
    path = (rec.get("path") or "").rstrip("/")
    if path in coverage_paths:
        coverage_seen = True
    if path not in test_paths:
        continue
    cycle_seen = True
    try:
        body, headers = decode_body(rec)
        json.loads(body.decode("utf-8"))
    except (base64.binascii.Error, OSError, UnicodeDecodeError, json.JSONDecodeError):
        continue
    if "gzip" in headers.get("content-encoding", "").lower():
        gzip_header_seen = True

if expect_gzip and not (gzip_header_seen or gzip_hint_seen):
    # Windows CI invokes the harness through Git Bash while the uploader uses
    # a PowerShell HttpClient path. Header capture can be inconsistent there,
    # so accept explicit uploader gzip debug confirmation as evidence.
    if is_windows and gzip_enabled_hint:
        print("warn: windows gzip verification used uploader debug signal")
    else:
        print("error: gzip scenario expected at least one gzipped citestcycle upload")
        sys.exit(1)
PY

# Scenario: telemetry uploads should ignore prefix filtering, preserve
# lexicographic ordering across directories/files, reuse fallback session IDs,
# and fail malformed files individually without blocking later uploads.
TELEMETRY_TESTLOGS="$TMP_WS/telemetry_testlogs"
TELEMETRY_A="$TELEMETRY_TESTLOGS/manual_telemetry_a/test.outputs/payloads/telemetry"
TELEMETRY_B="$TELEMETRY_TESTLOGS/manual_telemetry_b/test.outputs/payloads/telemetry"
mkdir -p "$TELEMETRY_A" "$TELEMETRY_B"
cat > "$TELEMETRY_A/dynamicprefix_alpha_001.json" <<'JSON_EOF'
{
  "api_version": "v2",
  "request_type": "app-started",
  "application": {
    "language_name": "go",
    "tracer_version": "1.72.1"
  },
  "payload": {
    "marker": "a01"
  }
}
JSON_EOF
cat > "$TELEMETRY_A/dynamicprefix_zeta_010.json" <<'JSON_EOF'
{
  "api_version": "v2",
  "request_type": "app-closing",
  "runtime_id": "telemetry-runtime-a10",
  "application": {
    "language_name": "dotnet",
    "tracer_version": "3.40.0"
  },
  "payload": {
    "marker": "a10"
  }
}
JSON_EOF
cat > "$TELEMETRY_B/dynamicprefix_beta_002.json" <<'JSON_EOF'
{
  "api_version": "v2",
  "request_type": "generate-metrics",
  "application": {
    "language_name": "ruby",
    "tracer_version": "2.1.0"
  },
  "payload": {
    "marker": "b02"
  }
}
JSON_EOF
cat > "$TELEMETRY_B/dynamicprefix_invalid_020.json" <<'JSON_EOF'
{invalid-json
JSON_EOF
cat > "$TELEMETRY_B/dynamicprefix_non_object_021.json" <<'JSON_EOF'
[
  {
    "api_version": "v2"
  }
]
JSON_EOF
cat > "$TELEMETRY_B/dynamicprefix_missing_api_022.json" <<'JSON_EOF'
{
  "request_type": "app-started",
  "payload": {
    "marker": "missing-api"
  }
}
JSON_EOF
cat > "$TELEMETRY_B/dynamicprefix_missing_request_023.json" <<'JSON_EOF'
{
  "api_version": "v2",
  "payload": {
    "marker": "missing-request"
  }
}
JSON_EOF

TELEMETRY_LOG_START="$(log_line_count)"
UPLOADER_TELEMETRY_LOG="$TMP_WS/uploader_telemetry.log"
set +e
TESTLOGS_DIR="$TELEMETRY_TESTLOGS" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_FILTER_PREFIX=1 \
DD_TEST_OPTIMIZATION_GZIP=1 \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_API_KEY=mock \
DD_SITE=datadoghq.com \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_TELEMETRY_LOG" 2>&1
TELEMETRY_STATUS=$?
set -e
if [[ "$TELEMETRY_STATUS" -ne 1 ]]; then
  echo "error: telemetry scenario expected uploader exit code 1, got $TELEMETRY_STATUS"
  cat "$UPLOADER_TELEMETRY_LOG" || true
  exit 1
fi

TELEMETRY_LOG_START="$TELEMETRY_LOG_START" UPLOADER_TELEMETRY_LOG="$UPLOADER_TELEMETRY_LOG" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("TELEMETRY_LOG_START", "0") or "0")
uploader_log_path = os.environ["UPLOADER_TELEMETRY_LOG"]

records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

telemetry_records = [rec for rec in records if rec.get("path") == "/api/v2/apmtelemetry"]
if len(telemetry_records) != 3:
    print(f"error: telemetry scenario expected 3 successful uploads, saw {len(telemetry_records)}")
    sys.exit(1)

markers = []
session_ids = {}
for rec in telemetry_records:
    headers = {str(k).lower(): str(v) for k, v in ((rec.get("headers") or {}).items())}
    if headers.get("content-type") != "application/json":
        print("error: telemetry upload missing application/json content type")
        sys.exit(1)
    if "content-encoding" in headers:
        print("error: telemetry upload unexpectedly included Content-Encoding")
        sys.exit(1)
    if not headers.get("dd-api-key"):
        print("error: telemetry agentless upload missing DD-API-KEY")
        sys.exit(1)
    try:
        payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as exc:
        print(f"error: failed to decode telemetry payload from mock log: {exc}")
        sys.exit(1)
    marker = ((payload.get("payload") or {}).get("marker"))
    markers.append(marker)
    session_ids[marker] = headers.get("dd-session-id", "")
    if headers.get("dd-telemetry-api-version") != payload.get("api_version"):
        print("error: telemetry api version header/body mismatch in mock log")
        sys.exit(1)
    if headers.get("dd-telemetry-request-type") != payload.get("request_type"):
        print("error: telemetry request type header/body mismatch in mock log")
        sys.exit(1)

if markers != ["a01", "a10", "b02"]:
    print(f"error: telemetry upload ordering mismatch: {markers!r}")
    sys.exit(1)

if session_ids["a10"] != "telemetry-runtime-a10":
    print("error: telemetry runtime_id should map directly to DD-Session-ID")
    sys.exit(1)
if not session_ids["a01"] or not session_ids["b02"]:
    print("error: telemetry fallback DD-Session-ID should be present for missing runtime_id")
    sys.exit(1)
if session_ids["a01"] != session_ids["b02"]:
    print("error: telemetry fallback DD-Session-ID should be reused across missing-runtime files")
    sys.exit(1)

with open(uploader_log_path, "r", encoding="utf-8", errors="replace") as handle:
    uploader_log = handle.read()

expected_failures = [
    "dynamicprefix_invalid_020.json",
    "dynamicprefix_non_object_021.json",
    "dynamicprefix_missing_api_022.json",
    "dynamicprefix_missing_request_023.json",
]
for name in expected_failures:
    if name not in uploader_log:
        print(f"error: uploader log missing telemetry failure reference for {name}")
        sys.exit(1)
PY

# Scenario: sync telemetry facts should append missing rule metrics into an
# existing tracer message-batch while preserving tracer identity, and should
# normalize outbound application.env across every matched tracer runtime.
TELEMETRY_AUG_TESTLOGS="$TMP_WS/telemetry_aug_testlogs"
TELEMETRY_AUG_DIR="$TELEMETRY_AUG_TESTLOGS/manual_telemetry_aug/test.outputs/payloads/telemetry"
mkdir -p "$TELEMETRY_AUG_DIR"
TELEMETRY_AUG_FILE="$TELEMETRY_AUG_DIR/telemetry_anchor_010.json"
cat > "$TELEMETRY_AUG_FILE" <<'JSON_EOF'
{
  "api_version": "v2",
  "request_type": "message-batch",
  "runtime_id": "augment-runtime",
  "seq_id": 41,
  "tracer_time": 1710000000,
  "application": {
    "service_name": "mock-service",
    "env": "none",
    "language_name": "go",
    "tracer_version": "2.9.0-dev"
  },
  "host": {
    "hostname": "mock-host"
  },
  "payload": [
    {
      "request_type": "generate-metrics",
      "payload": {
        "namespace": "civisibility",
        "series": [
          {
            "metric": "existing.metric",
            "points": [[1710000000, 1]],
            "type": "count",
            "tags": ["marker:existing", "provider:bazel"],
            "common": true,
            "namespace": "civisibility"
          }
        ]
      }
    }
  ]
}
JSON_EOF
TELEMETRY_AUG_PEER="$TELEMETRY_AUG_DIR/telemetry_peer_011.json"
cat > "$TELEMETRY_AUG_PEER" <<'JSON_EOF'
{
  "api_version": "v2",
  "request_type": "app-started",
  "runtime_id": "augment-runtime-peer",
  "seq_id": 5,
  "tracer_time": 1710000100,
  "application": {
    "service_name": "mock-service",
    "env": "none",
    "language_name": "go",
    "tracer_version": "2.9.0-dev"
  },
  "host": {
    "hostname": "mock-host"
  },
  "payload": {
    "marker": "peer"
  }
}
JSON_EOF
TELEMETRY_AUG_CONTEXT_DIR="$TMP_WS/telemetry_aug_context"
mkdir -p "$TELEMETRY_AUG_CONTEXT_DIR"
cp "$TOPT_DIR/context.json" "$TELEMETRY_AUG_CONTEXT_DIR/context.json"
TELEMETRY_AUG_CONTEXT_JSON="$TELEMETRY_AUG_CONTEXT_DIR/context.json"
TELEMETRY_AUG_CONTEXT_JSON="$TELEMETRY_AUG_CONTEXT_JSON" "$PYTHON" - <<'PY'
import json
import os

path = os.environ["TELEMETRY_AUG_CONTEXT_JSON"]
with open(path, "r", encoding = "utf-8-sig") as handle:
    payload = json.load(handle)
payload["ci.provider.name"] = "github"
with open(path, "w", encoding = "utf-8", newline = "\n") as handle:
    json.dump(payload, handle, separators = (",", ":"), ensure_ascii = False)
    handle.write("\n")
PY

TELEMETRY_AUG_LOG_START="$(log_line_count)"
UPLOADER_TELEMETRY_AUG_LOG="$TMP_WS/uploader_telemetry_aug.log"
if ! TESTLOGS_DIR="$TELEMETRY_AUG_TESTLOGS" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CONTEXT_JSON="$TELEMETRY_AUG_CONTEXT_JSON" \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_API_KEY=mock \
DD_SITE=datadoghq.com \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads_with_context \
  "${REPO_ENVS[@]}" >"$UPLOADER_TELEMETRY_AUG_LOG" 2>&1; then
  echo "error: telemetry augmentation scenario failed"
  cat "$UPLOADER_TELEMETRY_AUG_LOG" || true
  exit 1
fi

TELEMETRY_AUG_LOG_START="$TELEMETRY_AUG_LOG_START" TELEMETRY_AUG_FILE="$TELEMETRY_AUG_FILE" TELEMETRY_AUG_PEER="$TELEMETRY_AUG_PEER" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("TELEMETRY_AUG_LOG_START", "0") or "0")
anchor_file = os.environ["TELEMETRY_AUG_FILE"]
peer_file = os.environ["TELEMETRY_AUG_PEER"]

records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

telemetry_records = [rec for rec in records if rec.get("path") == "/api/v2/apmtelemetry"]
if len(telemetry_records) != 2:
    print(f"error: augmentation scenario expected 2 telemetry uploads, saw {len(telemetry_records)}")
    sys.exit(1)

decoded = [json.loads(base64.b64decode(rec["body_b64"]).decode("utf-8")) for rec in telemetry_records]
peer_payload = next((payload for payload in decoded if payload.get("request_type") == "app-started"), None)
payload = next((payload for payload in decoded if payload.get("request_type") == "message-batch"), None)
if payload is None:
    print("error: augmented telemetry should stay a message-batch")
    sys.exit(1)
if peer_payload is None:
    print("error: augmentation scenario should keep the non-anchor tracer payload")
    sys.exit(1)
if payload.get("runtime_id") != "augment-runtime":
    print("error: augmented telemetry should preserve runtime_id")
    sys.exit(1)
if payload.get("seq_id") != 41:
    print("error: augmented telemetry should preserve original seq_id")
    sys.exit(1)
app = payload.get("application") or {}
if app.get("service_name") != "mock-service" or app.get("language_name") != "go":
    print("error: augmented telemetry should preserve tracer application identity")
    sys.exit(1)
if app.get("env") != "ci":
    print(f"error: augmented telemetry should rewrite application.env from facts, saw {app.get('env')!r}")
    sys.exit(1)

peer_app = peer_payload.get("application") or {}
if peer_app.get("env") != "ci":
    print(f"error: peer tracer payload should also rewrite application.env from facts, saw {peer_app.get('env')!r}")
    sys.exit(1)

existing_seen = False
count_metrics = {}
distribution_metrics = {}
for message in payload.get("payload", []):
    body = message.get("payload") or {}
    for series in body.get("series", []):
        metric = series.get("metric")
        if metric == "existing.metric":
            existing_seen = True
        if message.get("request_type") == "generate-metrics":
            count_metrics[metric] = series
        elif message.get("request_type") == "distributions":
            distribution_metrics[metric] = series

if not existing_seen:
    print("error: augmented telemetry should keep original tracer metric messages")
    sys.exit(1)
existing_tags = count_metrics["existing.metric"].get("tags") or []
if "provider:bazel/github" not in existing_tags:
    print(f"error: augmented telemetry should rewrite provider:bazel using detected provider, saw {existing_tags!r}")
    sys.exit(1)
if "provider:bazel" in existing_tags:
    print(f"error: augmented telemetry should not keep the bare provider:bazel tag when a provider is detected: {existing_tags!r}")
    sys.exit(1)

expected_counts = {
    "git_requests.settings",
    "git_requests.settings_response",
    "known_tests.request",
    "test_management_tests.request",
}
missing_counts = sorted(expected_counts.difference(count_metrics))
if missing_counts:
    print(f"error: augmented telemetry missing count metrics: {missing_counts!r}")
    sys.exit(1)

expected_distributions = {
    "git_requests.settings_ms",
    "known_tests.request_ms",
    "known_tests.response_bytes",
    "known_tests.response_tests",
    "test_management_tests.request_ms",
    "test_management_tests.response_bytes",
    "test_management_tests.response_tests",
}
missing_distributions = sorted(expected_distributions.difference(distribution_metrics))
if missing_distributions:
    print(f"error: augmented telemetry missing distribution metrics: {missing_distributions!r}")
    sys.exit(1)

settings_tags = count_metrics["git_requests.settings_response"].get("tags") or []
if settings_tags != ["test_management_enabled:true"]:
    print(f"error: unexpected settings_response tags: {settings_tags!r}")
    sys.exit(1)

for metric_name in ("git_requests.settings", "known_tests.request", "test_management_tests.request"):
    tags = count_metrics[metric_name].get("tags") or []
    if tags != []:
        print(f"error: expected uncompressed count metric {metric_name} to be tagless, saw {tags!r}")
        sys.exit(1)

for metric_name in expected_distributions:
    tags = distribution_metrics[metric_name].get("tags") or []
    if tags != []:
        print(f"error: expected uncompressed distribution metric {metric_name} to be tagless, saw {tags!r}")
        sys.exit(1)

timestamps = set()
for metric_name in expected_counts:
    series = count_metrics[metric_name]
    points = series.get("points") or []
    if points and isinstance(points[0], list) and points[0]:
        timestamps.add(points[0][0])
if len(timestamps) != 1:
    print(f"error: expected one shared timestamp for appended count metrics, saw {timestamps!r}")
    sys.exit(1)

with open(anchor_file, "r", encoding="utf-8") as handle:
    raw_anchor = handle.read()
if "git_requests.settings" in raw_anchor:
    print("error: tracer telemetry file on disk should remain unchanged after augmentation")
    sys.exit(1)
if '"env": "none"' not in raw_anchor:
    print("error: tracer anchor file on disk should keep its original env")
    sys.exit(1)
with open(peer_file, "r", encoding="utf-8") as handle:
    raw_peer = handle.read()
if '"env": "none"' not in raw_peer:
    print("error: peer tracer file on disk should keep its original env")
    sys.exit(1)
PY

# Scenario: when no tracer message-batch exists, the uploader should keep the
# raw tracer telemetry files intact, normalize outbound env across the matched
# tracer set, and send one synthetic tracer-derived batch after the normal loop.
TELEMETRY_SYNTH_TESTLOGS="$TMP_WS/telemetry_synth_testlogs"
TELEMETRY_SYNTH_DIR="$TELEMETRY_SYNTH_TESTLOGS/manual_telemetry_synth/test.outputs/payloads/telemetry"
mkdir -p "$TELEMETRY_SYNTH_DIR"
cat > "$TELEMETRY_SYNTH_DIR/telemetry_alpha_001.json" <<'JSON_EOF'
{
  "api_version": "v2",
  "request_type": "app-started",
  "runtime_id": "synthetic-runtime",
  "seq_id": 7,
  "application": {
    "service_name": "mock-service",
    "env": "none",
    "language_name": "go",
    "tracer_version": "2.9.0-dev"
  },
  "payload": {
    "marker": "alpha"
  }
}
JSON_EOF
TELEMETRY_SYNTH_LAST="$TELEMETRY_SYNTH_DIR/telemetry_omega_010.json"
cat > "$TELEMETRY_SYNTH_LAST" <<'JSON_EOF'
{
  "api_version": "v2",
  "request_type": "app-closing",
  "runtime_id": "synthetic-runtime",
  "seq_id": 8,
  "application": {
    "service_name": "mock-service",
    "env": "none",
    "language_name": "go",
    "tracer_version": "2.9.0-dev"
  },
  "payload": {
    "marker": "omega"
  }
}
JSON_EOF

TELEMETRY_SYNTH_LOG_START="$(log_line_count)"
UPLOADER_TELEMETRY_SYNTH_LOG="$TMP_WS/uploader_telemetry_synth.log"
if ! TESTLOGS_DIR="$TELEMETRY_SYNTH_TESTLOGS" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_API_KEY=mock \
DD_SITE=datadoghq.com \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads_with_context \
  "${REPO_ENVS[@]}" >"$UPLOADER_TELEMETRY_SYNTH_LOG" 2>&1; then
  echo "error: synthetic telemetry scenario failed"
  cat "$UPLOADER_TELEMETRY_SYNTH_LOG" || true
  exit 1
fi

TELEMETRY_SYNTH_LOG_START="$TELEMETRY_SYNTH_LOG_START" TELEMETRY_SYNTH_LAST="$TELEMETRY_SYNTH_LAST" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("TELEMETRY_SYNTH_LOG_START", "0") or "0")
last_anchor_file = os.environ["TELEMETRY_SYNTH_LAST"]

records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

telemetry_records = [rec for rec in records if rec.get("path") == "/api/v2/apmtelemetry"]
if len(telemetry_records) != 3:
    print(f"error: synthetic scenario expected 3 telemetry uploads, saw {len(telemetry_records)}")
    sys.exit(1)

decoded = [json.loads(base64.b64decode(rec["body_b64"]).decode("utf-8")) for rec in telemetry_records]
request_types = [payload.get("request_type") for payload in decoded]
if request_types != ["app-started", "app-closing", "message-batch"]:
    print(f"error: synthetic scenario expected message-batch after raw tracer uploads, saw {request_types!r}")
    sys.exit(1)

synthetic = decoded[-1]
if synthetic.get("runtime_id") != "synthetic-runtime":
    print("error: synthetic telemetry should preserve runtime_id from tracer anchor")
    sys.exit(1)
if synthetic.get("seq_id") != 9:
    print(f"error: synthetic telemetry expected seq_id 9, got {synthetic.get('seq_id')!r}")
    sys.exit(1)
app = synthetic.get("application") or {}
if app.get("service_name") != "mock-service" or app.get("language_name") != "go":
    print("error: synthetic telemetry should preserve tracer application identity")
    sys.exit(1)
if app.get("env") != "ci":
    print(f"error: synthetic telemetry should rewrite application.env from facts, saw {app.get('env')!r}")
    sys.exit(1)
metric_names = []
for message in synthetic.get("payload", []):
    body = message.get("payload") or {}
    metric_names.extend(series.get("metric") for series in body.get("series", []))
if "git_requests.settings" not in metric_names or "known_tests.response_tests" not in metric_names:
    print(f"error: synthetic telemetry missing expected rule metrics: {metric_names!r}")
    sys.exit(1)
for raw_payload in decoded[:-1]:
    raw_app = raw_payload.get("application") or {}
    if raw_app.get("env") != "ci":
        print(f"error: raw tracer uploads should also rewrite application.env from facts, saw {raw_app.get('env')!r}")
        sys.exit(1)

with open(last_anchor_file, "r", encoding="utf-8") as handle:
    raw_anchor = handle.read()
if '"request_type": "message-batch"' in raw_anchor or "git_requests.settings" in raw_anchor:
    print("error: raw non-batch telemetry file should remain unchanged on disk")
    sys.exit(1)
if '"env": "none"' not in raw_anchor:
    print("error: raw non-batch telemetry file should keep its original env on disk")
    sys.exit(1)
PY

# Scenario: when no provider is present in the resolved context, telemetry tag
# rewriting must leave provider:bazel unchanged.
TELEMETRY_NOPROV_TESTLOGS="$TMP_WS/telemetry_no_provider_testlogs"
TELEMETRY_NOPROV_DIR="$TELEMETRY_NOPROV_TESTLOGS/manual_telemetry_no_provider/test.outputs/payloads/telemetry"
mkdir -p "$TELEMETRY_NOPROV_DIR"
cat > "$TELEMETRY_NOPROV_DIR/telemetry_no_provider_001.json" <<'JSON_EOF'
{
  "api_version": "v2",
  "request_type": "message-batch",
  "runtime_id": "no-provider-runtime",
  "seq_id": 13,
  "tracer_time": 1710000200,
  "application": {
    "service_name": "no-provider-service",
    "env": "none",
    "language_name": "go",
    "tracer_version": "2.9.0-dev"
  },
  "payload": [
    {
      "request_type": "generate-metrics",
      "payload": {
        "namespace": "civisibility",
        "series": [
          {
            "metric": "existing.no_provider.metric",
            "points": [[1710000200, 1]],
            "type": "count",
            "tags": ["provider:bazel", "marker:no-provider"],
            "common": true,
            "namespace": "civisibility"
          }
        ]
      }
    }
  ]
}
JSON_EOF
TELEMETRY_NOPROV_CONTEXT_DIR="$TMP_WS/telemetry_no_provider_context"
mkdir -p "$TELEMETRY_NOPROV_CONTEXT_DIR"
printf '{}\n' > "$TELEMETRY_NOPROV_CONTEXT_DIR/context.json"
TELEMETRY_NOPROV_LOG_START="$(log_line_count)"
UPLOADER_TELEMETRY_NOPROV_LOG="$TMP_WS/uploader_telemetry_no_provider.log"
if ! TESTLOGS_DIR="$TELEMETRY_NOPROV_TESTLOGS" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CONTEXT_JSON="$TELEMETRY_NOPROV_CONTEXT_DIR/context.json" \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_API_KEY=mock \
DD_SITE=datadoghq.com \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads_with_context \
  "${REPO_ENVS[@]}" >"$UPLOADER_TELEMETRY_NOPROV_LOG" 2>&1; then
  echo "error: telemetry no-provider scenario failed"
  cat "$UPLOADER_TELEMETRY_NOPROV_LOG" || true
  exit 1
fi

TELEMETRY_NOPROV_LOG_START="$TELEMETRY_NOPROV_LOG_START" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("TELEMETRY_NOPROV_LOG_START", "0") or "0")

records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

telemetry_records = [rec for rec in records if rec.get("path") == "/api/v2/apmtelemetry"]
if len(telemetry_records) != 1:
    print(f"error: no-provider scenario expected 1 telemetry upload, saw {len(telemetry_records)}")
    sys.exit(1)

payload = json.loads(base64.b64decode(telemetry_records[0]["body_b64"]).decode("utf-8"))
series = payload["payload"][0]["payload"]["series"][0]
tags = series.get("tags") or []
if "provider:bazel" not in tags:
    print(f"error: no-provider scenario should keep provider:bazel unchanged, saw {tags!r}")
    sys.exit(1)
if any(tag.startswith("provider:bazel/") for tag in tags):
    print(f"error: no-provider scenario should not append a provider suffix, saw {tags!r}")
    sys.exit(1)
PY

# Scenario: EVP mode should use evp_proxy endpoints + EVP subdomain headers.
# This validates mode switching behavior: EVP must use evp_proxy routes and
# EVP subdomain headers, and must not send DD-API-KEY.
MANUAL_EVP="$TESTLOGS_DIR/manual_evp_mode/test.outputs"
mkdir -p "$MANUAL_EVP/payloads/tests" "$MANUAL_EVP/payloads/coverage" "$MANUAL_EVP/payloads/telemetry"
cat > "$MANUAL_EVP/payloads/tests/manual_evp_mode.json" <<'JSON_EOF'
{
  "metadata": {
    "*": {
      "language": "go",
      "library_version": "1.0.0"
    }
  },
  "events": [
    {
      "type": "test",
      "content": {
        "resource": "Manual.EvpMode",
        "meta": {
          "test.source.file": "manual/owned.cs"
        }
      }
    }
  ]
}
JSON_EOF
echo '{}' > "$MANUAL_EVP/payloads/coverage/manual_evp_mode_cov.json"
cat > "$MANUAL_EVP/payloads/telemetry/manual_evp_mode_telemetry.json" <<'JSON_EOF'
{
  "api_version": "v2",
  "request_type": "app-started",
  "runtime_id": "telemetry-runtime-evp",
  "application": {
    "language_name": "dotnet",
    "tracer_version": "3.40.0"
  },
  "payload": {
    "marker": "evp"
  }
}
JSON_EOF

EVP_LOG_START="$(log_line_count)"
UPLOADER_EVP_LOG="$TMP_WS/uploader_evp.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_API_KEY= \
DD_SITE= \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL="http://127.0.0.1:$PORT" \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_EVP_LOG" 2>&1; then
  echo "error: uploader EVP-mode run failed"
  cat "$UPLOADER_EVP_LOG" || true
  exit 1
fi

EVP_LOG_START="$EVP_LOG_START" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("EVP_LOG_START", "0") or "0")
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

def lower_headers(record):
    return {str(k).lower(): v for k, v in ((record.get("headers") or {}).items())}

cycle_record = None
for rec in reversed(records):
    if rec.get("path") != "/evp_proxy/v2/api/v2/citestcycle":
        continue
    try:
        payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    for evt in payload.get("events", []):
        if (evt.get("content") or {}).get("resource") == "Manual.EvpMode":
            cycle_record = rec
            break
    if cycle_record is not None:
        break

if cycle_record is None:
    print("error: EVP-mode run missing Manual.EvpMode test upload")
    sys.exit(1)

cycle_headers = lower_headers(cycle_record)
if cycle_headers.get("x-datadog-evp-subdomain") != "citestcycle-intake":
    print("error: EVP-mode test upload missing expected X-Datadog-EVP-Subdomain header")
    sys.exit(1)
if "dd-api-key" in cycle_headers:
    print("error: EVP-mode test upload unexpectedly included DD-API-KEY header")
    sys.exit(1)

cov_record = next((rec for rec in reversed(records) if rec.get("path") == "/evp_proxy/v2/api/v2/citestcov"), None)
if cov_record is None:
    print("error: EVP-mode run missing coverage upload")
    sys.exit(1)

cov_headers = lower_headers(cov_record)
if cov_headers.get("x-datadog-evp-subdomain") != "citestcov-intake":
    print("error: EVP-mode coverage upload missing expected X-Datadog-EVP-Subdomain header")
    sys.exit(1)
if "dd-api-key" in cov_headers:
    print("error: EVP-mode coverage upload unexpectedly included DD-API-KEY header")
    sys.exit(1)

telemetry_record = None
for rec in reversed(records):
    if rec.get("path") != "/telemetry/proxy/api/v2/apmtelemetry":
        continue
    try:
        payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
        continue
    marker = ((payload.get("payload") or {}).get("marker"))
    if marker == "evp":
        telemetry_record = rec
        break

if telemetry_record is None:
    print("error: EVP-mode run missing telemetry upload")
    sys.exit(1)

telemetry_headers = lower_headers(telemetry_record)
if "dd-api-key" in telemetry_headers:
    print("error: EVP-mode telemetry upload unexpectedly included DD-API-KEY header")
    sys.exit(1)
if telemetry_headers.get("dd-session-id") != "telemetry-runtime-evp":
    print("error: EVP-mode telemetry upload missing expected DD-Session-ID header")
    sys.exit(1)
if telemetry_headers.get("dd-telemetry-request-type") != "app-started":
    print("error: EVP-mode telemetry upload missing expected DD-Telemetry-Request-Type header")
    sys.exit(1)
PY

# Scenario: force context.json resolution through RUNFILES_MANIFEST_FILE only.
# This validates BOM/tab exact-key matching and suffix-key fallback end-to-end.
# The manifest is intentionally constructed with both exact and suffix-key
# forms to cover both resolver branches deterministically.
UPLOADER_CQUERY=$("$BAZEL" "${BAZEL_FLAGS[@]}" cquery //:dd_upload_payloads_with_context --output=files \
  "${REPO_ENVS[@]}")
UPLOADER_SCRIPT_PATH=$(echo "$UPLOADER_CQUERY" | awk 'NF { print; exit }')
if [[ -z "$UPLOADER_SCRIPT_PATH" ]]; then
  echo "error: failed to resolve dd_upload_payloads script path"
  echo "$UPLOADER_CQUERY"
  exit 1
fi
UPLOADER_SCRIPT_CANDIDATES=()
if [[ "$UPLOADER_SCRIPT_PATH" == *.bat ]]; then
  # On Windows, cquery returns the executable (.bat). Prefer a sibling Bash
  # script when available, and otherwise fall back to sibling PowerShell.
  UPLOADER_SCRIPT_CANDIDATES+=("${UPLOADER_SCRIPT_PATH%.bat}.sh")
  UPLOADER_SCRIPT_CANDIDATES+=("${UPLOADER_SCRIPT_PATH%.bat}.ps1")
elif [[ "$UPLOADER_SCRIPT_PATH" == *.ps1 ]]; then
  UPLOADER_SCRIPT_CANDIDATES+=("$UPLOADER_SCRIPT_PATH")
  UPLOADER_SCRIPT_CANDIDATES+=("${UPLOADER_SCRIPT_PATH%.ps1}.sh")
elif [[ "$UPLOADER_SCRIPT_PATH" == *.sh ]]; then
  UPLOADER_SCRIPT_CANDIDATES+=("$UPLOADER_SCRIPT_PATH")
  UPLOADER_SCRIPT_CANDIDATES+=("${UPLOADER_SCRIPT_PATH%.sh}.ps1")
fi
UPLOADER_SCRIPT_CANDIDATES+=("$UPLOADER_SCRIPT_PATH")

RESOLVED_UPLOADER_SCRIPT_PATH=""
for candidate in "${UPLOADER_SCRIPT_CANDIDATES[@]}"; do
  [[ -z "$candidate" ]] && continue
  if [[ "$candidate" == /* || "$candidate" =~ ^[A-Za-z]:[\\/] ]]; then
    if [[ -f "$candidate" ]]; then
      RESOLVED_UPLOADER_SCRIPT_PATH="$candidate"
      break
    fi
    continue
  fi
  for base in "$OUT_BASE" "$EXECROOT" "$WORKSPACE"; do
    [[ -z "$base" ]] && continue
    if [[ -f "$base/$candidate" ]]; then
      RESOLVED_UPLOADER_SCRIPT_PATH="$base/$candidate"
      break
    fi
  done
  [[ -n "$RESOLVED_UPLOADER_SCRIPT_PATH" ]] && break
done
if [[ -z "$RESOLVED_UPLOADER_SCRIPT_PATH" ]]; then
  echo "error: resolved uploader script does not exist from candidates: ${UPLOADER_SCRIPT_CANDIDATES[*]}"
  echo "$UPLOADER_CQUERY"
  exit 1
fi
UPLOADER_SCRIPT_PATH="$RESOLVED_UPLOADER_SCRIPT_PATH"

# Verify generated Bash uploader keeps DD-API-KEY out of argv by using stdin
# header transport (`curl ... -H @-`).
if [[ "$UPLOADER_SCRIPT_PATH" == *.sh ]]; then
  UPLOADER_SCRIPT_PATH="$UPLOADER_SCRIPT_PATH" "$PYTHON" - <<'PY'
import os
import sys

path = os.environ["UPLOADER_SCRIPT_PATH"]
with open(path, "r", encoding="utf-8") as handle:
    content = handle.read()

required = [
    "curl_agentless() {",
    "curl \"$@\" -H @-",
]
for snippet in required:
    if snippet not in content:
        print(f"error: generated uploader script missing expected hardening snippet: {snippet!r}")
        sys.exit(1)

if "DD-API-KEY:" not in content:
    print("error: generated uploader script missing DD-API-KEY stdin-header materialization")
    sys.exit(1)

forbidden = 'COMMON_HDRS+=( -H "DD-API-KEY: $DD_API_KEY" )'
if forbidden in content:
    print("error: generated uploader script still adds DD-API-KEY directly to COMMON_HDRS")
    sys.exit(1)
PY
fi

MANIFEST_UPLOADER_KIND=""
MANIFEST_UPLOADER=""
if [[ "$UPLOADER_SCRIPT_PATH" == *.sh ]]; then
  MANIFEST_UPLOADER_KIND="bash"
  MANIFEST_UPLOADER="$TMP_WS/manifest_uploader.sh"
elif [[ "$UPLOADER_SCRIPT_PATH" == *.ps1 ]]; then
  MANIFEST_UPLOADER_KIND="powershell"
  MANIFEST_UPLOADER="$TMP_WS/manifest_uploader.ps1"
else
  echo "error: expected .sh or .ps1 uploader script for manifest patching, got: $UPLOADER_SCRIPT_PATH"
  echo "$UPLOADER_CQUERY"
  exit 1
fi

cp "$UPLOADER_SCRIPT_PATH" "$MANIFEST_UPLOADER"
chmod u+w,ugo+x "$MANIFEST_UPLOADER"

# Patch copied script so direct artifact resolution always misses and runfile
# manifest lookup is required for context/schema files.
MANIFEST_UPLOADER_PATH="$MANIFEST_UPLOADER" MANIFEST_UPLOADER_KIND="$MANIFEST_UPLOADER_KIND" "$PYTHON" - <<'PY'
import os
import re
import sys

path = os.environ["MANIFEST_UPLOADER_PATH"]
kind = os.environ["MANIFEST_UPLOADER_KIND"]
with open(path, "r", encoding="utf-8") as handle:
    content = handle.read()
if kind == "bash":
    for key in ("CONTEXT_JSON_PATH", "SCHEMA_JSON_PATH", "SCHEMA_VALIDATOR_PATH"):
        content, count = re.subn(
            rf'^{key}\s*=\s*"[^"]*"\r?$',
            f'{key}="__FORCE_RUNFILE_FALLBACK__"',
            content,
            flags=re.MULTILINE,
        )
        if count != 1:
            print(f"error: failed to patch {key} in copied uploader script")
            sys.exit(1)
elif kind == "powershell":
    replacements = (
        (r'^\$ContextJsonPath\s*=\s*"[^"]*"\r?$', '$ContextJsonPath = "__FORCE_RUNFILE_FALLBACK__"'),
        (r'^\$SchemaJsonPath\s*=\s*"[^"]*"\r?$', '$SchemaJsonPath = "__FORCE_RUNFILE_FALLBACK__"'),
        (r'^\$SchemaValidatorPath\s*=\s*"[^"]*"\r?$', '$SchemaValidatorPath = "__FORCE_RUNFILE_FALLBACK__"'),
    )
    for pattern, repl in replacements:
        content, count = re.subn(pattern, repl, content, flags=re.MULTILINE)
        if count != 1:
            print(f"error: failed to patch pattern {pattern!r} in copied uploader script")
            sys.exit(1)
else:
    print(f"error: unknown manifest uploader kind: {kind!r}")
    sys.exit(1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(content)
PY

CONTEXT_JSON_RLOC_MANIFEST=$(MANIFEST_UPLOADER_PATH="$MANIFEST_UPLOADER" MANIFEST_UPLOADER_KIND="$MANIFEST_UPLOADER_KIND" "$PYTHON" - <<'PY'
import os
import re
import sys

path = os.environ["MANIFEST_UPLOADER_PATH"]
kind = os.environ["MANIFEST_UPLOADER_KIND"]
with open(path, "r", encoding="utf-8") as handle:
    content = handle.read()
if kind == "bash":
    pattern = r'^CONTEXT_JSON_RLOC="([^"]*)"\r?$'
else:
    pattern = r'^\$ContextJsonRloc\s*=\s*"([^"]*)"\r?$'
match = re.search(pattern, content, flags=re.MULTILINE)
if not match:
    print("error: failed to locate CONTEXT_JSON_RLOC in copied uploader script")
    sys.exit(1)
print(match.group(1))
PY
)
if [[ -z "$CONTEXT_JSON_RLOC_MANIFEST" ]]; then
  echo "error: CONTEXT_JSON_RLOC from copied uploader is empty"
  exit 1
fi
MANIFEST_UPLOADER_CMD=()
MANIFEST_UPLOADER_FOR_CMD="$MANIFEST_UPLOADER"
if [[ "$MANIFEST_UPLOADER_KIND" == "bash" ]]; then
  MANIFEST_UPLOADER_CMD=("$MANIFEST_UPLOADER")
else
  MANIFEST_UPLOADER_FOR_CMD="$(to_mixed_path "$MANIFEST_UPLOADER")"
  MANIFEST_UPLOADER_CMD=(pwsh -NoLogo -NoProfile -File "$MANIFEST_UPLOADER_FOR_CMD")
fi

CONTEXT_CQUERY=$("$BAZEL" "${BAZEL_FLAGS[@]}" cquery @test_optimization_data//:test_optimization_context --output=files \
  "${REPO_ENVS[@]}")
CONTEXT_JSON_REAL_PATH=$(echo "$CONTEXT_CQUERY" | awk 'NF { print; exit }')
if [[ -z "$CONTEXT_JSON_REAL_PATH" ]]; then
  echo "error: failed to resolve context.json path from cquery"
  echo "$CONTEXT_CQUERY"
  exit 1
fi
if [[ "$CONTEXT_JSON_REAL_PATH" != /* && ! "$CONTEXT_JSON_REAL_PATH" =~ ^[A-Za-z]:[\\/] ]]; then
  for base in "$OUT_BASE" "$EXECROOT" "$WORKSPACE"; do
    [[ -z "$base" ]] && continue
    if [[ -f "$base/$CONTEXT_JSON_REAL_PATH" ]]; then
      CONTEXT_JSON_REAL_PATH="$base/$CONTEXT_JSON_REAL_PATH"
      break
    fi
  done
fi
if [[ ! -f "$CONTEXT_JSON_REAL_PATH" ]]; then
  echo "error: context.json not found for manifest fallback checks: $CONTEXT_JSON_REAL_PATH"
  echo "$CONTEXT_CQUERY"
  exit 1
fi
CONTEXT_JSON_REAL_PATH_MANIFEST="$CONTEXT_JSON_REAL_PATH"
TESTLOGS_DIR_FOR_MANIFEST="$TESTLOGS_DIR"
if [[ "$MANIFEST_UPLOADER_KIND" == "powershell" ]]; then
  CONTEXT_JSON_REAL_PATH_MANIFEST="$(to_mixed_path "$CONTEXT_JSON_REAL_PATH")"
  TESTLOGS_DIR_FOR_MANIFEST="$(to_mixed_path "$TESTLOGS_DIR")"
fi

write_manifest_payload() {
  # Create one test + one coverage payload for manifest-fallback uploader tests.
  local outputs_dir="$1"
  local resource_name="$2"
  mkdir -p "$outputs_dir/payloads/tests" "$outputs_dir/payloads/coverage"
  cat > "$outputs_dir/payloads/tests/${resource_name}.json" <<JSON_EOF
{
  "metadata": {
    "*": {
      "language": "go",
      "library_version": "1.0.0"
    }
  },
  "events": [
    {
      "type": "test",
      "content": {
        "resource": "$resource_name",
        "meta": {
          "test.source.file": "manual/owned.cs"
        }
      }
    }
  ]
}
JSON_EOF
  echo '{}' > "$outputs_dir/payloads/coverage/${resource_name}_cov.json"
}

run_manifest_uploader() {
  # Run uploader with RUNFILES_MANIFEST_FILE-only resolution enabled and fail
  # fast with captured logs when any manifest-key scenario regresses.
  local manifest_file="$1"
  local output_log="$2"
  local scenario_label="$3"
  if ! TESTLOGS_DIR="$TESTLOGS_DIR_FOR_MANIFEST" \
  BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
  DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
  RUNFILES_MANIFEST_FILE="$manifest_file" \
  RUNFILES_DIR= \
  DD_API_KEY=mock \
  DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=0 \
  DD_TEST_OPTIMIZATION_DEBUG="$HARNESS_UPLOADER_DEBUG" \
  DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
  DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
  DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
  DD_TEST_OPTIMIZATION_AGENT_URL= \
  "${MANIFEST_UPLOADER_CMD[@]}" >"$output_log" 2>&1; then
    echo "error: manifest $scenario_label uploader run failed"
    cat "$output_log" || true
    exit 1
  fi
}

MANIFEST_EXACT="$TMP_WS/runfiles_exact.manifest"
BOM=$'\xef\xbb\xbf'
printf '%s%s\t%s\n' "$BOM" "$CONTEXT_JSON_RLOC_MANIFEST" "$CONTEXT_JSON_REAL_PATH_MANIFEST" > "$MANIFEST_EXACT"
MANIFEST_EXACT_FOR_UPLOADER="$MANIFEST_EXACT"
if [[ "$MANIFEST_UPLOADER_KIND" == "powershell" ]]; then
  MANIFEST_EXACT_FOR_UPLOADER="$(to_mixed_path "$MANIFEST_EXACT")"
fi
MANIFEST_EXACT_OUT="$TESTLOGS_DIR/manual_manifest_exact/test.outputs"
write_manifest_payload "$MANIFEST_EXACT_OUT" "Manual.ManifestExactTabBom"

UPLOADER_MANIFEST_EXACT_LOG="$TMP_WS/uploader_manifest_exact.log"
run_manifest_uploader "$MANIFEST_EXACT_FOR_UPLOADER" "$UPLOADER_MANIFEST_EXACT_LOG" "exact-key"

MANIFEST_SUFFIX="$TMP_WS/runfiles_suffix.manifest"
printf 'repo-prefix/%s %s\n' "$CONTEXT_JSON_RLOC_MANIFEST" "$CONTEXT_JSON_REAL_PATH_MANIFEST" > "$MANIFEST_SUFFIX"
MANIFEST_SUFFIX_FOR_UPLOADER="$MANIFEST_SUFFIX"
if [[ "$MANIFEST_UPLOADER_KIND" == "powershell" ]]; then
  MANIFEST_SUFFIX_FOR_UPLOADER="$(to_mixed_path "$MANIFEST_SUFFIX")"
fi
MANIFEST_SUFFIX_OUT="$TESTLOGS_DIR/manual_manifest_suffix/test.outputs"
write_manifest_payload "$MANIFEST_SUFFIX_OUT" "Manual.ManifestSuffixKey"

UPLOADER_MANIFEST_SUFFIX_LOG="$TMP_WS/uploader_manifest_suffix.log"
run_manifest_uploader "$MANIFEST_SUFFIX_FOR_UPLOADER" "$UPLOADER_MANIFEST_SUFFIX_LOG" "suffix-key"

UPLOADER_MANIFEST_EXACT_LOG="$UPLOADER_MANIFEST_EXACT_LOG" \
UPLOADER_MANIFEST_SUFFIX_LOG="$UPLOADER_MANIFEST_SUFFIX_LOG" \
CONTEXT_JSON_PATH="$CONTEXT_JSON_REAL_PATH" \
"$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
context_path = os.environ["CONTEXT_JSON_PATH"]
with open(context_path, "r", encoding="utf-8") as handle:
    expected_context = json.load(handle)
expected_tags = {
    key: expected_context.get(key)
    for key in ("bazel.rule_name", "bazel.rule_version", "bazel.os", "bazel.arch")
}
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

def owners_for(meta):
    raw = meta.get("test.codeowners")
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return "__invalid__"

def print_manifest_logs():
    for label, env_key in (
        ("exact", "UPLOADER_MANIFEST_EXACT_LOG"),
        ("suffix", "UPLOADER_MANIFEST_SUFFIX_LOG"),
    ):
        path = os.environ.get(env_key)
        if not path:
            continue
        if not os.path.exists(path):
            print(f"debug: {label} manifest uploader log missing at {path}")
            continue
        print(f"debug: {label} manifest uploader log tail follows")
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
        for line in lines[-120:]:
            print(line.rstrip("\n"))
        print(f"debug: end {label} manifest uploader log tail")

def assert_manifest_resource(resource):
    payload = None
    for rec in reversed(records):
        if rec.get("path") != "/api/v2/citestcycle":
            continue
        try:
            obj = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
        except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
            continue
        for evt in obj.get("events", []):
            content = evt.get("content") or {}
            if content.get("resource") == resource:
                payload = obj
                break
        if payload is not None:
            break
    if payload is None:
        print(f"error: missing manifest resolution upload for {resource}")
        print_manifest_logs()
        sys.exit(1)
    target = None
    for evt in payload.get("events", []):
        if (evt.get("content") or {}).get("resource") == resource:
            target = evt
            break
    if target is None:
        print(f"error: missing event payload for {resource}")
        print_manifest_logs()
        sys.exit(1)
    meta = ((target.get("content") or {}).get("meta") or {})
    for key, value in expected_tags.items():
        if meta.get(key) != value:
            print(f"error: manifest fallback run missing context tag {key} for {resource}: {meta.get(key)!r} != {value!r}")
            print_manifest_logs()
            sys.exit(1)
    for key in ("test.bazel.rule_name", "test.bazel.rule_version"):
        if key in meta:
            print(f"error: manifest fallback run still contains legacy context tag {key} for {resource}")
            print_manifest_logs()
            sys.exit(1)
    if owners_for(meta) != ["@org/owned"]:
        print(f"error: manifest fallback run missing expected CODEOWNERS for {resource}")
        print_manifest_logs()
        sys.exit(1)

assert_manifest_resource("Manual.ManifestExactTabBom")
assert_manifest_resource("Manual.ManifestSuffixKey")
PY

mv "$ORIG_CODEOWNERS" "$WORKSPACE/CODEOWNERS"

write_manual_test_payload() {
  local outputs_dir="$1"
  local resource_name="$2"
  mkdir -p "$outputs_dir/payloads/tests" "$outputs_dir/payloads/coverage"
  cat > "$outputs_dir/payloads/tests/${resource_name}.json" <<JSON_EOF
{
  "metadata": {
    "*": {
      "language": "go",
      "library_version": "1.0.0"
    }
  },
  "events": [
    {
      "type": "test",
      "content": {
        "resource": "$resource_name",
        "name": "$resource_name",
        "status": "pass",
        "meta": {}
      }
    }
  ]
}
JSON_EOF
}

write_manual_coverage_payload() {
  local outputs_dir="$1"
  local file_name="$2"
  local mock_mode="${3:-}"
  mkdir -p "$outputs_dir/payloads/coverage"
  if [[ -z "$mock_mode" ]]; then
    cat > "$outputs_dir/payloads/coverage/${file_name}" <<'JSON_EOF'
{
  "version": "1",
  "files": [
    {
      "filename": "manual/coverage.cs",
      "segments": [[1, 0, 1, 0, 0]]
    }
  ]
}
JSON_EOF
    return
  fi
  cat > "$outputs_dir/payloads/coverage/${file_name}" <<JSON_EOF
{
  "version": "1",
  "mock_mode": "$mock_mode",
  "files": [
    {
      "filename": "manual/coverage.cs",
      "segments": [[1, 0, 1, 0, 0]]
    }
  ]
}
JSON_EOF
}

# Scenario: uploader retries transient test-upload failures and eventually succeeds.
reset_mock_retries
LOG_LINES_BEFORE_RETRY_UPLOADER="$(log_line_count)"
MANUAL_RETRY_AGENTLESS="$TESTLOGS_DIR/manual_retry_agentless/test.outputs"
write_manual_test_payload "$MANUAL_RETRY_AGENTLESS" "Manual.RetryAgentless"

UPLOADER_RETRY_AGENTLESS_LOG="$TMP_WS/uploader_retry_agentless.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_FILTER_PREFIX=0 \
DD_TEST_OPTIMIZATION_GZIP=0 \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_RETRY_AGENTLESS_LOG" 2>&1; then
  echo "error: uploader retry agentless scenario failed"
  cat "$UPLOADER_RETRY_AGENTLESS_LOG" || true
  exit 1
fi

LOG_FILE="$LOG_FILE" LOG_START="$LOG_LINES_BEFORE_RETRY_UPLOADER" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start = int(os.environ.get("LOG_START", "0") or "0")
target_resource = "Manual.RetryAgentless"
attempts = 0

with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("path") != "/api/v2/citestcycle":
            continue
        try:
            payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
        except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
            continue
        for evt in payload.get("events", []):
            content = evt.get("content") or {}
            if content.get("resource") == target_resource:
                attempts += 1
                break

if attempts < 2:
    print(f"error: expected retry uploader scenario to issue >=2 attempts, got {attempts}")
    sys.exit(1)
PY

# Scenario: sustained 5xx errors should fail uploader after retry budget.
reset_mock_retries
LOG_LINES_BEFORE_FAIL_503="$(log_line_count)"
FAIL_503_TESTLOGS="$TMP_WS/testlogs_fail_503"
MANUAL_FAIL_503="$FAIL_503_TESTLOGS/manual_fail_agentless_503/test.outputs"
write_manual_test_payload "$MANUAL_FAIL_503" "Manual.AlwaysFailAgentless"
UPLOADER_FAIL_503_LOG="$TMP_WS/uploader_fail_503.log"
if TESTLOGS_DIR="$FAIL_503_TESTLOGS" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_DEBUG=1 \
DD_TEST_OPTIMIZATION_FILTER_PREFIX=0 \
DD_TEST_OPTIMIZATION_GZIP=0 \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_FAIL_503_LOG" 2>&1; then
  echo "error: sustained 5xx scenario unexpectedly succeeded"
  cat "$UPLOADER_FAIL_503_LOG" || true
  exit 1
fi
LOG_FILE="$LOG_FILE" LOG_START="$LOG_LINES_BEFORE_FAIL_503" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start = int(os.environ.get("LOG_START", "0") or "0")
target_resource = "Manual.AlwaysFailAgentless"
attempts = 0
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("path") != "/api/v2/citestcycle":
            continue
        try:
            payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
        except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
            continue
        for evt in payload.get("events", []):
            content = evt.get("content") or {}
            if content.get("resource") == target_resource:
                attempts += 1
                break
if attempts < 2:
    print(f"error: sustained 5xx scenario expected retries, got attempts={attempts}")
    sys.exit(1)
PY

# Scenario: explicit 4xx intake errors should fail uploader.
reset_mock_retries
LOG_LINES_BEFORE_FAIL_400="$(log_line_count)"
FAIL_400_TESTLOGS="$TMP_WS/testlogs_fail_400"
MANUAL_FAIL_400="$FAIL_400_TESTLOGS/manual_fail_agentless_400/test.outputs"
write_manual_test_payload "$MANUAL_FAIL_400" "Manual.BadRequestAgentless"
UPLOADER_FAIL_400_LOG="$TMP_WS/uploader_fail_400.log"
if TESTLOGS_DIR="$FAIL_400_TESTLOGS" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_DEBUG=1 \
DD_TEST_OPTIMIZATION_FILTER_PREFIX=0 \
DD_TEST_OPTIMIZATION_GZIP=0 \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_FAIL_400_LOG" 2>&1; then
  echo "error: 4xx scenario unexpectedly succeeded"
  cat "$UPLOADER_FAIL_400_LOG" || true
  exit 1
fi
LOG_FILE="$LOG_FILE" LOG_START="$LOG_LINES_BEFORE_FAIL_400" UPLOADER_FAIL_400_LOG="$UPLOADER_FAIL_400_LOG" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start = int(os.environ.get("LOG_START", "0") or "0")
uploader_log = os.environ["UPLOADER_FAIL_400_LOG"]
target_resource = "Manual.BadRequestAgentless"
attempts = 0
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("path") != "/api/v2/citestcycle":
            continue
        try:
            payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
        except (base64.binascii.Error, UnicodeDecodeError, json.JSONDecodeError):
            continue
        for evt in payload.get("events", []):
            content = evt.get("content") or {}
            if content.get("resource") == target_resource:
                attempts += 1
                break
if attempts < 1:
    print("error: 4xx scenario did not issue any test upload attempts")
    sys.exit(1)
with open(uploader_log, "r", encoding="utf-8", errors="replace") as handle:
    content = handle.read()
if "HTTP 400" not in content and "http code 400" not in content.lower():
    print("error: uploader log does not expose HTTP 400 diagnostics in 4xx scenario")
    sys.exit(1)
PY

# Scenario: unreachable intake endpoint should fail with connection errors.
UNREACHABLE_TESTLOGS="$TMP_WS/testlogs_unreachable"
MANUAL_UNREACHABLE="$UNREACHABLE_TESTLOGS/manual_unreachable/test.outputs"
write_manual_test_payload "$MANUAL_UNREACHABLE" "Manual.UnreachableIntake"
UPLOADER_UNREACHABLE_LOG="$TMP_WS/uploader_unreachable.log"
if TESTLOGS_DIR="$UNREACHABLE_TESTLOGS" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:1" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_UNREACHABLE_LOG" 2>&1; then
  echo "error: unreachable intake scenario unexpectedly succeeded"
  cat "$UPLOADER_UNREACHABLE_LOG" || true
  exit 1
fi

# Scenario: coverage upload retries transient failures and eventually succeeds.
reset_mock_retries
LOG_LINES_BEFORE_COV_RETRY="$(log_line_count)"
COV_RETRY_TESTLOGS="$TMP_WS/testlogs_cov_retry"
MANUAL_COV_RETRY="$COV_RETRY_TESTLOGS/manual_cov_retry/test.outputs"
write_manual_test_payload "$MANUAL_COV_RETRY" "Manual.CoverageRetry"
write_manual_coverage_payload "$MANUAL_COV_RETRY" "manual_cov_retry.json" "retry_once"
UPLOADER_COV_RETRY_LOG="$TMP_WS/uploader_cov_retry.log"
if ! TESTLOGS_DIR="$COV_RETRY_TESTLOGS" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_COV_RETRY_LOG" 2>&1; then
  echo "error: coverage retry scenario failed"
  cat "$UPLOADER_COV_RETRY_LOG" || true
  exit 1
fi
LOG_FILE="$LOG_FILE" LOG_START="$LOG_LINES_BEFORE_COV_RETRY" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys
from email.parser import BytesParser
from email.policy import default

log_path = os.environ["LOG_FILE"]
start = int(os.environ.get("LOG_START", "0") or "0")
attempts = 0

def parse_marker(record):
    headers = {str(k).lower(): str(v) for k, v in ((record.get("headers") or {}).items())}
    ct = headers.get("content-type", "")
    if "boundary=" not in ct:
        return ""
    try:
        body = base64.b64decode(record.get("body_b64", ""))
    except base64.binascii.Error:
        return ""
    try:
        msg = BytesParser(policy=default).parsebytes(("Content-Type: %s\r\n\r\n" % ct).encode("utf-8") + body)
    except Exception:
        return ""
    for part in msg.iter_parts():
        name = part.get_param("name", header="Content-Disposition")
        if name != "coveragex":
            continue
        raw = part.get_payload(decode=True) or b""
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return ""
        val = payload.get("mock_mode") if isinstance(payload, dict) else ""
        return val if isinstance(val, str) else ""
    return ""

with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("path") != "/api/v2/citestcov":
            continue
        if parse_marker(rec) == "retry_once":
            attempts += 1

if attempts < 2:
    print(f"error: expected coverage retry scenario to issue >=2 attempts, got {attempts}")
    sys.exit(1)
PY

# Scenario: sustained coverage 5xx should fail uploader after retry budget.
reset_mock_retries
LOG_LINES_BEFORE_COV_FAIL="$(log_line_count)"
COV_FAIL_TESTLOGS="$TMP_WS/testlogs_cov_fail"
MANUAL_COV_FAIL="$COV_FAIL_TESTLOGS/manual_cov_fail/test.outputs"
write_manual_test_payload "$MANUAL_COV_FAIL" "Manual.CoverageAlwaysFail"
write_manual_coverage_payload "$MANUAL_COV_FAIL" "manual_cov_fail.json" "always_fail"
UPLOADER_COV_FAIL_LOG="$TMP_WS/uploader_cov_fail.log"
if TESTLOGS_DIR="$COV_FAIL_TESTLOGS" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_AGENTLESS_URL="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TEST_OPTIMIZATION_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads \
  "${REPO_ENVS[@]}" >"$UPLOADER_COV_FAIL_LOG" 2>&1; then
  echo "error: sustained coverage 5xx scenario unexpectedly succeeded"
  cat "$UPLOADER_COV_FAIL_LOG" || true
  exit 1
fi
LOG_FILE="$LOG_FILE" LOG_START="$LOG_LINES_BEFORE_COV_FAIL" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys
from email.parser import BytesParser
from email.policy import default

log_path = os.environ["LOG_FILE"]
start = int(os.environ.get("LOG_START", "0") or "0")
attempts = 0

def parse_marker(record):
    headers = {str(k).lower(): str(v) for k, v in ((record.get("headers") or {}).items())}
    ct = headers.get("content-type", "")
    if "boundary=" not in ct:
        return ""
    try:
        body = base64.b64decode(record.get("body_b64", ""))
    except base64.binascii.Error:
        return ""
    try:
        msg = BytesParser(policy=default).parsebytes(("Content-Type: %s\r\n\r\n" % ct).encode("utf-8") + body)
    except Exception:
        return ""
    for part in msg.iter_parts():
        name = part.get_param("name", header="Content-Disposition")
        if name != "coveragex":
            continue
        raw = part.get_payload(decode=True) or b""
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return ""
        val = payload.get("mock_mode") if isinstance(payload, dict) else ""
        return val if isinstance(val, str) else ""
    return ""

with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("path") != "/api/v2/citestcov":
            continue
        if parse_marker(rec) == "always_fail":
            attempts += 1
if attempts < 2:
    print(f"error: sustained coverage 5xx scenario expected retries, got attempts={attempts}")
    sys.exit(1)
PY
