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

if [[ "${KEEP_TMP:-0}" == "1" ]]; then
  echo "KEEP_TMP=1: temp workspace at $TMP_WS"
fi

cleanup() {
  # Best-effort teardown that prioritizes deterministic cleanup over strict
  # failures. Integration runs can leave transient Bazel/Java locks behind,
  # especially on Windows, so this helper is intentionally defensive.
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  # Bazel can keep files under output_base open on Windows for a short time.
  # Best-effort shutdown avoids cleanup flakiness from locked JVM logs.
  if [[ -n "${BAZEL:-}" && -x "${BAZEL:-}" ]]; then
    if [[ -n "${OUT_BASE:-}" ]]; then
      "$BAZEL" --output_base="$OUT_BASE" shutdown >/dev/null 2>&1 || true
    else
      "$BAZEL" shutdown >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${TMP_WS:-}" && -d "$TMP_WS" && "${KEEP_TMP:-0}" != "1" ]]; then
    chmod -R u+w "$TMP_WS" 2>/dev/null || true
    rm -rf "$TMP_WS" || true
  fi
}
trap cleanup EXIT

# Start a mock Datadog API server with fixture responses and request logging.
"$PYTHON" -u "$REPO_ROOT/tools/tests/integration/mock_dd_server.py" \
  --fixtures "$REPO_ROOT/tools/tests/integration/fixtures" \
  --log "$LOG_FILE" \
  --port 0 >"$SERVER_OUT" 2>&1 &
SERVER_PID=$!

# Wait for the server to bind to a random port and emit it.
PORT=""
# Keep this tunable because slower CI workers can need extra startup time.
MAX_WAIT_LOOPS="${MOCK_SERVER_MAX_WAIT_LOOPS:-200}"
for ((i = 1; i <= MAX_WAIT_LOOPS; i++)); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "error: mock server process died before binding"
    cat "$SERVER_OUT" || true
    exit 1
  fi
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

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for snapshot enrichment tests"
  exit 1
fi

# Create a throwaway Bazel workspace to exercise the rules as a consumer.
WORKSPACE="$TMP_WS/ws"
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

to_mixed_path() {
  # Convert a local path to mixed-style form (C:/...) when cygpath is
  # available. This keeps PowerShell + Git Bash path handoff predictable.
  local value="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$value" 2>/dev/null || printf '%s\n' "$value"
    return
  fi
  printf '%s\n' "$value"
}

log_line_count() {
  # Return current mock server log line count. Used as an offset marker so
  # per-scenario assertions only inspect newly produced request records.
  if [[ -f "$LOG_FILE" ]]; then
    wc -l < "$LOG_FILE" | tr -d '[:space:]'
  else
    echo 0
  fi
}

# Pass an explicit workspace path to uploader runs so CODEOWNERS lookup stays
# stable across platforms/runtimes (especially Bazel 9 on Windows).
WORKSPACE_FOR_UPLOADER="$(to_mixed_path "$WORKSPACE")"
HARNESS_UPLOADER_DEBUG="${HARNESS_UPLOADER_DEBUG:-}"
if [[ -z "$HARNESS_UPLOADER_DEBUG" ]]; then
  UNAME_LC="$(uname -s | tr 'A-Z' 'a-z')"
  if [[ "$UNAME_LC" == *mingw* || "$UNAME_LC" == *msys* || "$UNAME_LC" == *cygwin* ]]; then
    HARNESS_UPLOADER_DEBUG=1
  else
    HARNESS_UPLOADER_DEBUG=0
  fi
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

use_repo(test_optimization_sync, "test_optimization_data")
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
mkdir -p "$out/payloads/tests" "$out/payloads/coverage"
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
echo '{}' > "$out/payloads/coverage/cov1.json"
PAYLOAD_EOF
chmod +x payload_writer.sh

BAZEL="$REPO_ROOT/bazelw"
OUT_BASE="$TMP_WS/.bazel_out"
BAZEL_FLAGS=(--output_base="$OUT_BASE")

# Provide deterministic repo metadata for fixtures + payload enrichment.
REPO_ENVS=(
  --repo_env=DD_API_KEY=mock
  --repo_env=DD_TEST_OPTIMIZATION_API_BASE=http://127.0.0.1:$PORT
  --repo_env=DD_ENV=ci
  --repo_env=DD_GIT_REPOSITORY_URL=https://example.com/repo.git
  --repo_env=DD_GIT_BRANCH=main
  --repo_env=DD_GIT_COMMIT_SHA=1111111
  --repo_env=DD_GIT_HEAD_COMMIT=1111111
  --repo_env=DD_GIT_COMMIT_MESSAGE=Test_commit
  --repo_env=DD_GIT_HEAD_MESSAGE=Test_head
  --repo_env=DD_GIT_TAG=v1.0.0
)

# ---------------------------------------------------------------------------
# Scenario: baseline sync + uploader run (agentless) with fixture assertions.
# ---------------------------------------------------------------------------
# This is the "known-good" path. Later scenarios intentionally mutate one
# variable at a time and reuse these repo env defaults.
"$BAZEL" "${BAZEL_FLAGS[@]}" build @test_optimization_data//:test_optimization_files \
  "${REPO_ENVS[@]}"

CQUERY_OUT=$("$BAZEL" "${BAZEL_FLAGS[@]}" cquery @test_optimization_data//:test_optimization_files --output=files \
  "${REPO_ENVS[@]}")
EXECROOT="$("$BAZEL" "${BAZEL_FLAGS[@]}" info execution_root "${REPO_ENVS[@]}" 2>/dev/null || true)"

# Resolve settings.json location from cquery output for validation.
# Depending on Bazel output mode/platform, the cquery path can be relative to
# output_base, execution_root, or workspace. Probe each base in order.
SETTINGS_PATH=$(echo "$CQUERY_OUT" | grep -E '[\\/]\.testoptimization[\\/]cache[\\/]http[\\/]settings\.json$' | head -n1 || true)
if [[ -z "$SETTINGS_PATH" ]]; then
  echo "error: failed to resolve settings.json path"
  echo "$CQUERY_OUT"
  exit 1
fi

if [[ "$SETTINGS_PATH" != /* && ! "$SETTINGS_PATH" =~ ^[A-Za-z]:[\\/] ]]; then
  for base in "$OUT_BASE" "$EXECROOT" "$WORKSPACE"; do
    [[ -z "$base" ]] && continue
    if [[ -f "$base/$SETTINGS_PATH" ]]; then
      SETTINGS_PATH="$base/$SETTINGS_PATH"
      break
    fi
  done
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

unset DD_TRACE_AGENT_URL

"$BAZEL" "${BAZEL_FLAGS[@]}" test //:write_payloads_test \
  "${REPO_ENVS[@]}"

# Use Bazel's testlogs location to find payloads for the uploader.
TESTLOGS_DIR="$("$BAZEL" "${BAZEL_FLAGS[@]}" info bazel-testlogs)"

BASE_UPLOAD_LOG_START="$(log_line_count)"
UPLOADER_LOG="$TMP_WS/uploader.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_DEBUG="$HARNESS_UPLOADER_DEBUG" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_INTAKE_BASE="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TRACE_AGENT_URL= \
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
        except Exception:
            continue

def find_latest_cycle_for_resource(resource):
    for rec in reversed(records):
        if rec.get("path") != "/api/v2/citestcycle":
            continue
        try:
            payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
        except Exception:
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
    except Exception:
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
bazel_dep(name = "rules_go", version = "0.59.0")

local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = ${ESCAPED_REPO_ROOT},
)
local_path_override(
    module_name = "datadog-rules-test-optimization-go",
    path = ${ESCAPED_MODULES_GO},
)

topt_multi = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt_multi.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["go-service", "go_service"],
    out_dir = "custom_topt",
    runtime_name = "go",
    runtime_version = "1.2.3",
)

use_repo(
    topt_multi,
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
def fake_go_test(name, data = [], env = {}, **kwargs):
    _ = env
    _ = kwargs
    native.filegroup(
        name = name,
        srcs = data,
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
  "$BAZEL" "${BAZEL_FLAGS[@]}" cquery //:macro_service_probe --output=build "${REPO_ENVS[@]}"
)
# The selected manifest label is the strongest end-to-end macro assertion:
# it proves the chosen service mapping and out_dir propagation simultaneously.
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
        except Exception:
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
    except Exception:
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

# Capture current log offset so we can isolate uploads produced specifically
# by the context-enriched uploader run below.
LOG_LINES_BEFORE_CONTEXT="$(log_line_count)"
UPLOADER_CONTEXT_LOG="$TMP_WS/uploader_with_context.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
BUILD_WORKSPACE_DIRECTORY="$WORKSPACE_FOR_UPLOADER" \
DD_TEST_OPTIMIZATION_CODEOWNERS_FILE="$CODEOWNERS_FOR_UPLOADER" \
DD_API_KEY=mock \
DD_TEST_OPTIMIZATION_KEEP_PAYLOADS=1 \
DD_TEST_OPTIMIZATION_INTAKE_BASE="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TRACE_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads_with_context \
  "${REPO_ENVS[@]}" >"$UPLOADER_CONTEXT_LOG" 2>&1; then
  echo "error: uploader command with context failed"
  cat "$UPLOADER_CONTEXT_LOG" || true
  exit 1
fi

LOG_LINES_BEFORE_CONTEXT="$LOG_LINES_BEFORE_CONTEXT" "$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_line = int(os.environ.get("LOG_LINES_BEFORE_CONTEXT", "0") or "0")
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for idx, line in enumerate(handle):
        if idx < start_line:
            continue
        try:
            records.append(json.loads(line))
        except Exception:
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
    except Exception:
        continue
    for evt in cycle_payload.get("events", []):
        if evt.get("type") != "test":
            continue
        content = evt.get("content") or {}
        if content.get("resource") != target_resource:
            continue
        evt_meta = content.get("meta") or {}
        if "test.bazel.rule_name" in evt_meta and "test.bazel.rule_version" in evt_meta:
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
except Exception:
    owners = "__invalid__"
if owners != ["@DataDog/ci-app-libraries-dotnet"]:
    print("error: expected CODEOWNERS value missing in context-enriched payload")
    sys.exit(1)
for key in ("test.bazel.rule_name", "test.bazel.rule_version"):
    if key not in meta:
        print(f"error: expected context tag missing in context-enriched payload: {key}")
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
DD_TEST_OPTIMIZATION_INTAKE_BASE="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TRACE_AGENT_URL= \
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
        except Exception:
            continue

for rec in reversed(rows):
    if rec.get("path") != "/api/v2/citestcycle":
        continue
    try:
        body = base64.b64decode(rec.get("body_b64", ""))
        obj = json.loads(body.decode("utf-8"))
    except Exception:
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
DD_TEST_OPTIMIZATION_INTAKE_BASE="http://127.0.0.1:$PORT" \
DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
DD_TRACE_AGENT_URL= \
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
        except Exception:
            continue

for rec in reversed(records):
    if rec.get("path") != "/api/v2/citestcycle":
        continue
    try:
        obj = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except Exception:
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
        except Exception:
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

# Scenario: EVP mode should use evp_proxy endpoints + EVP subdomain headers.
# This validates mode switching behavior: EVP must use evp_proxy routes and
# EVP subdomain headers, and must not send DD-API-KEY.
MANUAL_EVP="$TESTLOGS_DIR/manual_evp_mode/test.outputs"
mkdir -p "$MANUAL_EVP/payloads/tests" "$MANUAL_EVP/payloads/coverage"
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
DD_TRACE_AGENT_URL="http://127.0.0.1:$PORT" \
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
        except Exception:
            continue

def lower_headers(record):
    return {str(k).lower(): v for k, v in ((record.get("headers") or {}).items())}

cycle_record = None
for rec in reversed(records):
    if rec.get("path") != "/evp_proxy/v2/api/v2/citestcycle":
        continue
    try:
        payload = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except Exception:
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
  DD_TEST_OPTIMIZATION_INTAKE_BASE="http://127.0.0.1:$PORT" \
  DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=30 \
  DD_TEST_OPTIMIZATION_QUIESCENT_SEC=1 \
  DD_TRACE_AGENT_URL= \
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
"$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            records.append(json.loads(line))
        except Exception:
            continue

def owners_for(meta):
    raw = meta.get("test.codeowners")
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except Exception:
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
        except Exception:
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
    for key in ("test.bazel.rule_name", "test.bazel.rule_version"):
        if key not in meta:
            print(f"error: manifest fallback run missing context tag {key} for {resource}")
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
