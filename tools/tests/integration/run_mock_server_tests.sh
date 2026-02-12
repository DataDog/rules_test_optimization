#!/usr/bin/env bash
set -euo pipefail

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
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${TMP_WS:-}" && -d "$TMP_WS" && "${KEEP_TMP:-0}" != "1" ]]; then
    chmod -R u+w "$TMP_WS" 2>/dev/null || true
    rm -rf "$TMP_WS"
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

# JSON-escape REPO_ROOT for safe insertion into MODULE.bazel.
ESCAPED_REPO_ROOT=$("$PYTHON" - <<'PY'
import json
import os
print(json.dumps(os.environ["REPO_ROOT"]))
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
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load("@datadog-rules-test-optimization//tools:test_optimization_uploader.bzl", "dd_payload_uploader")

sh_test(
    name = "write_payloads_test",
    srcs = ["payload_writer.sh"],
    data = ["citestcycle_template.json"],
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

cat > CODEOWNERS <<'CODEOWNERS_EOF'
* @org/default
/tracer/test/test-applications/integrations/Samples.XUnitTests/[Tt]estSuite.cs @DataDog/ci-app-libraries-dotnet
CODEOWNERS_EOF

cat > payload_writer.sh <<'PAYLOAD_EOF'
#!/usr/bin/env bash
set -euo pipefail

out="${TEST_UNDECLARED_OUTPUTS_DIR:?}"
mkdir -p "$out/tests" "$out/coverage"
template=""
if [[ -n "${TEST_SRCDIR:-}" ]]; then
  for ws in "${TEST_WORKSPACE:-}" "_main"; do
    [[ -z "$ws" ]] && continue
    candidate="$TEST_SRCDIR/$ws/citestcycle_template.json"
    if [[ -f "$candidate" ]]; then
      template="$candidate"
      break
    fi
  done
  if [[ -z "$template" ]]; then
    candidate="$TEST_SRCDIR/citestcycle_template.json"
    [[ -f "$candidate" ]] && template="$candidate"
  fi
fi
if [[ -z "$template" || ! -f "$template" ]]; then
  template="$(dirname "$0")/citestcycle_template.json"
fi
if [[ ! -f "$template" ]]; then
  echo "error: fixture template not found: $template" >&2
  exit 1
fi

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
' "$template" > "$out/tests/test1.json"
echo '{}' > "$out/coverage/cov1.json"
PAYLOAD_EOF
chmod +x payload_writer.sh

BAZEL="$REPO_ROOT/bazelw"
OUT_BASE="$TMP_WS/.bazel_out"
BAZEL_FLAGS=(--output_base="$OUT_BASE")

# Provide deterministic repo metadata for fixtures + payload enrichment.
REPO_ENVS=(
  --repo_env=DD_API_KEY=mock
  --repo_env=DD_TOPT_API_BASE=http://127.0.0.1:$PORT
  --repo_env=DD_ENV=ci
  --repo_env=DD_GIT_REPOSITORY_URL=https://example.com/repo.git
  --repo_env=DD_GIT_BRANCH=main
  --repo_env=DD_GIT_COMMIT_SHA=1111111
  --repo_env=DD_GIT_HEAD_COMMIT=1111111
  --repo_env=DD_GIT_COMMIT_MESSAGE=Test_commit
  --repo_env=DD_GIT_HEAD_MESSAGE=Test_head
  --repo_env=DD_GIT_TAG=v1.0.0
)

"$BAZEL" "${BAZEL_FLAGS[@]}" build @test_optimization_data//:test_optimization_files \
  "${REPO_ENVS[@]}"

CQUERY_OUT=$("$BAZEL" "${BAZEL_FLAGS[@]}" cquery @test_optimization_data//:test_optimization_files --output=files \
  "${REPO_ENVS[@]}")
EXECROOT="$("$BAZEL" "${BAZEL_FLAGS[@]}" info execution_root "${REPO_ENVS[@]}" 2>/dev/null || true)"

# Resolve settings.json location from cquery output for validation.
# Depending on Bazel output mode/platform, the cquery path can be relative to
# output_base, execution_root, or workspace. Probe each base in order.
SETTINGS_PATH=$(echo "$CQUERY_OUT" | grep -E '[\\/]\.testoptimization[\\/]settings\.json$' | head -n1 || true)
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
  "${REPO_ENVS[@]}"

# Use Bazel's testlogs location to find payloads for the uploader.
TESTLOGS_DIR="$("$BAZEL" "${BAZEL_FLAGS[@]}" info bazel-testlogs)"

UPLOADER_LOG="$TMP_WS/uploader.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
DD_API_KEY=mock \
DD_TOPT_KEEP_PAYLOADS=1 \
DD_TOPT_INTAKE_BASE="http://127.0.0.1:$PORT" \
DD_TOPT_MAX_WAIT_SEC=30 \
DD_TOPT_QUIESCENT_SEC=1 \
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

"$PYTHON" - <<'PY'
import base64
import json
import os
import sys
from email.parser import BytesParser
from email.policy import default

log_path = os.environ["LOG_FILE"]
snapshot_dir = os.environ["SNAPSHOT_DIR"]
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
    # Keep full payload shape; the fixture snapshot already uses stable values.
    return payload

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
    for line in handle:
        try:
            records.append(json.loads(line))
        except Exception:
            continue

def find_last(path):
    for rec in reversed(records):
        if rec.get("path") == path:
            return rec
    return None

cycle = find_last("/api/v2/citestcycle")
cov = find_last("/api/v2/citestcov")
if not cycle or not cov:
    print("error: missing payload logs for snapshotting")
    sys.exit(1)

cycle_body = base64.b64decode(cycle.get("body_b64", ""))
cycle_json = json.loads(cycle_body.decode("utf-8"))
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

if parse_owners(event_codeowners("test", "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest")) != ["@DataDog/ci-app-libraries-dotnet"]:
    print("error: expected codeowners re-injection for test event")
    sys.exit(1)
if parse_owners(event_codeowners("test_suite_end", "Samples.XUnitTests.TestSuite")) != ["@DataDog/ci-app-libraries-dotnet"]:
    print("error: expected codeowners re-injection for test_suite_end event")
    sys.exit(1)
if parse_owners(event_codeowners("test", "Samples.XUnitTests.UnSkippableSuite.UnskippableTest")) != ["@DataDog/ci-app-libraries-dotnet"]:
    print("error: expected existing codeowners to be preserved for test event")
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
validator = os.path.join(repo_root, "tools", "validate_payload_schema.py")
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

CYCLE_COUNT_BEFORE_CONTEXT=$("$PYTHON" - <<'PY'
import json
import os

log_path = os.environ["LOG_FILE"]
count = 0
try:
    with open(log_path, "r", encoding="utf-8") as handle:
        for line in handle:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("path") == "/api/v2/citestcycle":
                count += 1
except FileNotFoundError:
    pass
print(count)
PY
)

# Capture current cycle count so we can isolate uploads produced specifically
# by the context-enriched uploader run below.
UPLOADER_CONTEXT_LOG="$TMP_WS/uploader_with_context.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
DD_API_KEY=mock \
DD_TOPT_KEEP_PAYLOADS=1 \
DD_TOPT_INTAKE_BASE="http://127.0.0.1:$PORT" \
DD_TOPT_MAX_WAIT_SEC=30 \
DD_TOPT_QUIESCENT_SEC=1 \
DD_TRACE_AGENT_URL= \
"$BAZEL" "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads_with_context \
  "${REPO_ENVS[@]}" >"$UPLOADER_CONTEXT_LOG" 2>&1; then
  echo "error: uploader command with context failed"
  cat "$UPLOADER_CONTEXT_LOG" || true
  exit 1
fi

export CYCLE_COUNT_BEFORE_CONTEXT

"$PYTHON" - <<'PY'
import base64
import json
import os
import sys

log_path = os.environ["LOG_FILE"]
start_count = int(os.environ.get("CYCLE_COUNT_BEFORE_CONTEXT", "0") or "0")
records = []
with open(log_path, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            records.append(json.loads(line))
        except Exception:
            continue

cycle_records = [rec for rec in records if rec.get("path") == "/api/v2/citestcycle"]
new_cycle_records = cycle_records[start_count:]
if len(new_cycle_records) < 1:
    print("error: expected at least one new /api/v2/citestcycle upload for context-enriched run")
    sys.exit(1)
cycle = None
for rec in reversed(new_cycle_records):
    try:
        obj = json.loads(base64.b64decode(rec.get("body_b64", "")).decode("utf-8"))
    except Exception:
        continue
    found_context_tag = False
    for evt in obj.get("events", []):
        if evt.get("type") != "test":
            continue
        meta = ((evt.get("content") or {}).get("meta") or {})
        if "test.bazel.rule_name" in meta and "test.bazel.rule_version" in meta:
            found_context_tag = True
            break
    if found_context_tag:
        cycle = rec
        break
if cycle is None:
    cycle = new_cycle_records[-1]
if not cycle:
    print("error: missing /api/v2/citestcycle upload after context run")
    sys.exit(1)

cycle_payload = json.loads(base64.b64decode(cycle.get("body_b64", "")).decode("utf-8"))
target_evt = None
for evt in cycle_payload.get("events", []):
    if evt.get("type") != "test":
        continue
    content = evt.get("content") or {}
    if content.get("resource") == "Samples.XUnitTests.TestSuite.SimpleErrorParameterizedTest":
        target_evt = evt
        break
if not target_evt:
    print("error: could not find target test event in context-enriched payload")
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
mv "$WORKSPACE/CODEOWNERS" "$WORKSPACE/CODEOWNERS.bak"
MANUAL_NO_CO="$TESTLOGS_DIR/manual_no_codeowners/test.outputs"
mkdir -p "$MANUAL_NO_CO/tests" "$MANUAL_NO_CO/coverage"
cat > "$MANUAL_NO_CO/tests/manual_no_codeowners.json" <<'JSON_EOF'
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
echo '{}' > "$MANUAL_NO_CO/coverage/manual_no_codeowners_cov.json"

UPLOADER_NO_CO_LOG="$TMP_WS/uploader_no_codeowners.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
DD_API_KEY=mock \
DD_TOPT_KEEP_PAYLOADS=1 \
DD_TOPT_INTAKE_BASE="http://127.0.0.1:$PORT" \
DD_TOPT_MAX_WAIT_SEC=30 \
DD_TOPT_QUIESCENT_SEC=1 \
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
cat > "$WORKSPACE/CODEOWNERS" <<'CODEOWNERS_EOF'
[CoreTeam]
[Core Team] @org/section-space
* @org/default
[Backend] @org/section-default
/manual/owned.cs @org/owned
/manual/unowned.cs
/manual/comment_only.cs # explicit empty-owner rule via inline comment
/manual/hash_owner.cs @org/team#chat
/manual/space\ owner.cs @org/space-owner
CODEOWNERS_EOF

MANUAL_EMPTY_OWNER="$TESTLOGS_DIR/manual_empty_owner/test.outputs"
mkdir -p "$MANUAL_EMPTY_OWNER/tests" "$MANUAL_EMPTY_OWNER/coverage"
cat > "$MANUAL_EMPTY_OWNER/tests/manual_empty_owner.json" <<'JSON_EOF'
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
        "resource": "Manual.SectionHeaderIgnored",
        "meta": {
          "test.source.file": "manual/b/file.cs"
        }
      }
    }
  ]
}
JSON_EOF
echo '{}' > "$MANUAL_EMPTY_OWNER/coverage/manual_empty_owner_cov.json"

UPLOADER_EMPTY_OWNER_LOG="$TMP_WS/uploader_empty_owner.log"
if ! TESTLOGS_DIR="$TESTLOGS_DIR" \
DD_API_KEY=mock \
DD_TOPT_KEEP_PAYLOADS=1 \
DD_TOPT_INTAKE_BASE="http://127.0.0.1:$PORT" \
DD_TOPT_MAX_WAIT_SEC=30 \
DD_TOPT_QUIESCENT_SEC=1 \
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

if owners_for("Manual.Owned") != ["@org/owned"]:
    print("error: Manual.Owned should resolve explicit owner rule")
    sys.exit(1)
if owners_for("Manual.Unowned") is not None:
    print("error: Manual.Unowned should not set test.codeowners when no owners resolve")
    sys.exit(1)
if owners_for("Manual.CommentOnly") is not None:
    print("error: Manual.CommentOnly should not set test.codeowners when owner segment is comment-only")
    sys.exit(1)
if owners_for("Manual.HashOwner") != ["@org/team#chat"]:
    print("error: Manual.HashOwner should preserve '#' inside owner token")
    sys.exit(1)
if owners_for("Manual.SpaceOwner") != ["@org/space-owner"]:
    print("error: Manual.SpaceOwner should resolve escaped-space CODEOWNERS pattern")
    sys.exit(1)
if owners_for("Manual.SectionHeaderIgnored") != ["@org/default"]:
    print("error: Manual.SectionHeaderIgnored should ignore GitLab section-owner headers")
    sys.exit(1)
if owners_for("Manual.SourceFallback") != ["@org/owned"]:
    print("error: Manual.SourceFallback should resolve through content.source.path fallback")
    sys.exit(1)
if owners_for("Manual.Default") != ["@org/default"]:
    print("error: Manual.Default should resolve fallback '*' rule")
    sys.exit(1)
PY

mv "$ORIG_CODEOWNERS" "$WORKSPACE/CODEOWNERS"
