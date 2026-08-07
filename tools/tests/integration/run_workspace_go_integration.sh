#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

set -euo pipefail

# -----------------------------------------------------------------------------
# Integration harness: WORKSPACE Go companion verification
# -----------------------------------------------------------------------------
#
# This script creates temporary WORKSPACE-mode consumers and validates the
# supported Go product path:
# - core repo + Go companion repo as separate external repositories
# - repo_mapping from @rules_go to an Orchestrion-enabled @io_bazel_rules_go
# - public WORKSPACE helper for rules_go_orchestrion_tool
# - real dd_topt_go_test execution against a nested Go package
# - module-root Orchestrion pin files passed through orchestrion_pin_files
# - module-selected payload wiring and custom sync out_dir handling
# - mirror/archive packaging for the core repo, companion, and rules_go fork
# - invalid public helper inputs fail early with direct guidance
#
# Debugging tips:
# - Set KEEP_TMP=1 to inspect the generated workspaces after a failure.
# - Override BAZEL=<path> to run with a different Bazel launcher locally.
# - Override GO_BIN=<path> to use a specific Go binary locally.
#

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PIN_GRAPH_FIXTURE="$REPO_ROOT/tools/tests/integration/fixtures/orchestrion_pin_graph"
MISSING_PIN_MODULE_FIXTURE="$PIN_GRAPH_FIXTURE/missing_module"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rules_topt_workspace_go.XXXXXX")"
WORKSPACE_ROOT="$TMP_ROOT/workspaces"
ARCHIVE_ROOT="$TMP_ROOT/archive_root"
ARCHIVE_NAME="rules_test_optimization-fixture"
ARCHIVE_PATH="$TMP_ROOT/${ARCHIVE_NAME}.tar.gz"
PYTHON="${PYTHON:-python3}"
GO_BIN="${GO_BIN:-go}"
BAZEL="${BAZEL:-$REPO_ROOT/bazelw}"
BAZEL_VERSION="${BAZEL_VERSION:-$(tr -d '[:space:]' < "$REPO_ROOT/.bazelversion")}"
# Keep Bazel's output roots inside the fixture temp tree so each CI step can
# release downloaded SDKs, extracted repos, and sandbox outputs during cleanup.
BAZEL_OUTPUT_USER_ROOT="${BAZEL_OUTPUT_USER_ROOT:-$TMP_ROOT/bazel_output_user_root}"
GO_VERSION="${GO_VERSION:-1.25.0}"
ORCHESTRION_VERSION="${ORCHESTRION_VERSION:-v1.12.0}"
ORCHESTRION_MODE="${ORCHESTRION_MODE:-general}"
ORCHESTRION_DISABLED_SENTINEL="${ORCHESTRION_DISABLED_SENTINEL:-0}"
ORCHESTRION_DISABLED_SENTINEL_VERSION="v0.0.0-rto-disabled-fetch-sentinel"
WINDOWS_DISABLED_SMOKE_ONLY="${WINDOWS_DISABLED_SMOKE_ONLY:-0}"
WINDOWS_ENABLED_SMOKE_ONLY="${WINDOWS_ENABLED_SMOKE_ONLY:-0}"
WINDOWS_CONFIG_TRANSITION_ONLY="${WINDOWS_CONFIG_TRANSITION_ONLY:-0}"
CONFIG_TRANSITION_ONLY="${CONFIG_TRANSITION_ONLY:-$WINDOWS_CONFIG_TRANSITION_ONLY}"
FORBID_HOST_GO="${FORBID_HOST_GO:-0}"
EXPECTED_ORCHESTRION_CACHE_PHASE="${EXPECTED_ORCHESTRION_CACHE_PHASE:-}"
HOST_GO_SENTINEL_LOG=""
# Keep this aligned with the bootstrap helper's published default tracer pin so
# the WORKSPACE harness validates the same public Go path the docs describe.
DD_TRACE_GO_VERSION="${DD_TRACE_GO_VERSION:-v2.9.1}"
PIN_ROOT_VERSION="v2.9.1-rc.3"
PIN_HTTP_VERSION="v2.9.1-rc.3"
PIN_SLOG_VERSION="v2.3.0"
SERVICE_NAME="${SERVICE_NAME:-workspace-go-service}"
MODULE_IMPORTPATH="${MODULE_IMPORTPATH:-example.com/workspace-go-integration}"
MODULE_LABEL="${MODULE_LABEL:-example_com_workspace_go_integration}"
OUT_DIR="${OUT_DIR:-custom_topt}"
HELLO_TEST_TARGET="${HELLO_TEST_TARGET:-//app:hello_test}"
INTEGRATION_SCENARIO_MODE="${INTEGRATION_SCENARIO_MODE:-full}"
MEASURE_OUTPUT_PATH="${MEASURE_OUTPUT_PATH:-}"
ARCHIVE_SHA256=""
ARCHIVE_URL=""
RULES_GO_UPSTREAM="${RULES_GO_UPSTREAM:-default}"
RULES_GO_VARIANT="${RULES_GO_VARIANT:-base}"
FIXTURE_GIT_REPOSITORY_URL="${FIXTURE_GIT_REPOSITORY_URL:-https://github.com/DataDog/rules-test-optimization-fixture.git}"
FIXTURE_GIT_BRANCH="${FIXTURE_GIT_BRANCH:-main}"
FIXTURE_GIT_COMMIT_SHA="${FIXTURE_GIT_COMMIT_SHA:-1234567890abcdef1234567890abcdef12345678}"
BAZEL_EXTRA_ARGS=(
  "--repo_env=DD_GIT_REPOSITORY_URL=${FIXTURE_GIT_REPOSITORY_URL}"
  "--repo_env=DD_GIT_BRANCH=${FIXTURE_GIT_BRANCH}"
  "--repo_env=DD_GIT_COMMIT_SHA=${FIXTURE_GIT_COMMIT_SHA}"
)
HERMETIC_BUILD_FLAGS=(
  --spawn_strategy=sandboxed
  --incompatible_strict_action_env
  --sandbox_default_allow_network=false
  --enable_runfiles
)
HERMETIC_TEST_FLAGS=(
  --strategy=TestRunner=sandboxed
  --modify_execution_info=TestRunner=+block-network
  --test_env=TZ=UTC
  --test_env=LANG=C
  --test_env=LC_ALL=C
)

source "$REPO_ROOT/tools/tests/integration/go_integration_mock_server.sh"

assert_pin_version_file() {
  local ws_dir="$1"
  local files_list="$2"
  shift 2
  local execution_root
  local output_base
  local version_file

  execution_root="$(
    cd "$ws_dir"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" info "$@" execution_root
  )"
  output_base="$(
    cd "$ws_dir"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" info "$@" output_base
  )"
  version_file="$(head -n 1 "$files_list")"
  if [[ "$version_file" != /* && ! "$version_file" =~ ^[A-Za-z]:[/\\] ]]; then
    if [[ "$version_file" == external/* ]]; then
      version_file="$output_base/$version_file"
    else
      version_file="$execution_root/$version_file"
    fi
  fi
  "$PYTHON" - "$version_file" "$PIN_ROOT_VERSION" "$PIN_HTTP_VERSION" "$PIN_SLOG_VERSION" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
versions = json.loads(path.read_text(encoding="utf-8"))["modules"]
expected = {
    "github.com/DataDog/dd-trace-go/v2": sys.argv[2],
    "github.com/DataDog/dd-trace-go/contrib/net/http/v2": sys.argv[3],
    "github.com/DataDog/dd-trace-go/contrib/log/slog/v2": sys.argv[4],
}
if versions != expected:
    raise SystemExit(f"resolved pin versions mismatch: got {versions!r}, expected {expected!r}")
PY
}

shutdown_bazel_workspace_servers() {
  local workspace_dir

  # Bazel owns one server per generated workspace. Windows cannot remove their
  # output bases until every server releases its files.
  if [[ -d "$WORKSPACE_ROOT" ]]; then
    for workspace_dir in "$WORKSPACE_ROOT"/*; do
      [[ -d "$workspace_dir" ]] || continue
      (
        cd "$workspace_dir"
        USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" shutdown
      ) >/dev/null 2>&1 || true
    done
  fi

  (
    cd "$REPO_ROOT"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" shutdown
  ) >/dev/null 2>&1 || true
}

cleanup() {
  local status=$?

  set +e
  stop_go_integration_mock_server
  shutdown_bazel_workspace_servers
  if [[ -n "$HOST_GO_SENTINEL_LOG" && -s "$HOST_GO_SENTINEL_LOG" ]]; then
    echo "error: the consumer path invoked the host Go sentinel" >&2
    cat "$HOST_GO_SENTINEL_LOG" >&2
    status=1
  fi
  if [[ "${KEEP_TMP:-0}" == "1" ]]; then
    echo "KEEP_TMP=1: workspace fixtures left at $TMP_ROOT"
    return "$status"
  fi
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  if ! rm -rf "$TMP_ROOT" 2>/dev/null; then
    sleep 2
    if ! rm -rf "$TMP_ROOT" 2>/dev/null; then
      echo "warning: unable to remove temporary workspace $TMP_ROOT" >&2
    fi
  fi
  return "$status"
}
trap cleanup EXIT INT TERM HUP

require_command() {
  local name="$1"
  local message="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "error: $message" >&2
    exit 1
  fi
}

enable_host_go_sentinel() {
  [[ "$FORBID_HOST_GO" == "1" ]] || return 0
  if [[ "${OS:-}" == "Windows_NT" ]]; then
    echo "error: FORBID_HOST_GO is currently supported only on Unix hosts" >&2
    exit 1
  fi

  local sentinel_root="$TMP_ROOT/host_go_sentinel"
  mkdir -p "$sentinel_root/bin"
  HOST_GO_SENTINEL_LOG="$sentinel_root/invocations.log"
  : > "$HOST_GO_SENTINEL_LOG"
  cat > "$sentinel_root/bin/go" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sentinel_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
printf '%s\n' "$*" >> "$sentinel_root/invocations.log"
echo "error: host Go must not be used by the Test Optimization consumer path" >&2
exit 97
EOF
  chmod +x "$sentinel_root/bin/go"
  PATH="$sentinel_root/bin:$PATH"
  export PATH
}

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON=python
  else
    echo "error: python interpreter not found (tried '$PYTHON' and 'python')" >&2
    exit 1
  fi
fi

require_command tar "tar is required for the WORKSPACE archive fixture"
enable_host_go_sentinel

resolve_rules_go_fork_path() {
  "$PYTHON" "$REPO_ROOT/tools/dev/materialize_rules_go_fork.py" resolve \
    --upstream "$RULES_GO_UPSTREAM" \
    --variant "$RULES_GO_VARIANT"
}

rules_go_fork_rel="$(resolve_rules_go_fork_path)"
rules_go_fork_abs="${REPO_ROOT}/${rules_go_fork_rel}"

bzl_quote() {
  "$PYTHON" - <<'PY' "$1"
import json
import sys

print(json.dumps(sys.argv[1]))
PY
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi
  echo "error: neither sha256sum nor shasum is available" >&2
  exit 1
}

file_uri() {
  local path="$1"

  if command -v cygpath >/dev/null 2>&1; then
    path="$(cygpath -m "$path")"
  fi
  "$PYTHON" - "$path" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve().as_uri())
PY
}

wall_time_ns() {
  "$PYTHON" - <<'PY'
import time
print(time.time_ns())
PY
}

module_proxy_size_bytes() {
  local output_base="$1"
  "$PYTHON" - <<'PY' "$output_base"
from pathlib import Path
import sys

external_root = Path(sys.argv[1]) / "external"
candidates = sorted(external_root.glob("*rules_go_orchestrion_tool*/module_proxy"))
if not candidates:
    print(0)
    raise SystemExit(0)
total = 0
for path in candidates[0].rglob("*"):
    if path.is_file():
        total += path.stat().st_size
print(total)
PY
}

write_measure_json() {
  local elapsed_seconds="$1"
  local module_proxy_size="$2"
  local output_path="$3"
  "$PYTHON" - <<'PY' "$elapsed_seconds" "$module_proxy_size" "$output_path"
import json
import sys

payload = {
    "mode": "workspace",
    "elapsed_seconds": float(sys.argv[1]),
    "module_proxy_size_bytes": int(sys.argv[2]),
}
with open(sys.argv[3], "w", encoding="utf-8") as fh:
    json.dump(payload, fh, sort_keys=True)
    fh.write("\n")
PY
}

assert_json_test_payloads() {
  local ws_dir="$1"
  local mode="$2"
  local payload_dir="$ws_dir/bazel-testlogs/app/hello_test/test.outputs/payloads/tests"

  if [[ ! -d "$payload_dir" ]]; then
    echo "error: $mode did not create test payload directory $payload_dir" >&2
    exit 1
  fi

  "$PYTHON" - <<'PY' "$payload_dir" "$mode"
import json
from pathlib import Path
import sys

payload_dir = Path(sys.argv[1])
mode = sys.argv[2]
json_files = sorted(payload_dir.glob("*.json"))
msgpack_files = sorted(payload_dir.glob("*.msgpack"))
if not json_files:
    raise SystemExit(f"error: {mode} did not emit JSON test payloads in {payload_dir}")
if msgpack_files:
    names = ", ".join(path.name for path in msgpack_files)
    raise SystemExit(f"error: {mode} emitted raw msgpack test payloads instead of RFC JSON files: {names}")
for path in json_files:
    with path.open(encoding="utf-8") as fh:
        json.load(fh)
PY
}

assert_log_contains() {
  local log_path="$1"
  local expected="$2"
  local description="$3"

  if ! grep -q "$expected" "$log_path"; then
    echo "error: $description" >&2
    cat "$log_path" >&2 || true
    exit 1
  fi
}

assert_log_matches() {
  local log_path="$1"
  local expected_re="$2"
  local description="$3"

  if ! grep -Eq "$expected_re" "$log_path"; then
    echo "error: $description" >&2
    cat "$log_path" >&2 || true
    exit 1
  fi
}

assert_log_not_contains() {
  local log_path="$1"
  local unexpected="$2"
  local description="$3"

  if grep -Fq "$unexpected" "$log_path"; then
    echo "error: $description" >&2
    cat "$log_path" >&2 || true
    exit 1
  fi
}

assert_bep_has_cached_test_result() {
  local bep_path="$1"
  "$PYTHON" - "$bep_path" <<'PY'
import json
import sys
from pathlib import Path

bep_path = Path(sys.argv[1])
for raw in bep_path.read_text(encoding="utf-8-sig").splitlines():
    if not raw.strip():
        continue
    event = json.loads(raw)
    if "testResult" not in event.get("id", {}) and "test_result" not in event.get("id", {}):
        continue
    result = event.get("testResult") or event.get("test_result") or {}
    execution_info = result.get("executionInfo") or result.get("execution_info") or {}
    if result.get("cachedLocally") or result.get("cached_locally") or execution_info.get("cachedRemotely") or execution_info.get("cached_remotely"):
        raise SystemExit(0)
raise SystemExit(f"error: {bep_path} did not contain a cached TestResult")
PY
}

simulate_bep_artifact_only_outputs() {
  local ws_dir="$1"
  local fresh_bep="$2"
  local original_source="$ws_dir/bazel-testlogs/app/hello_test/test.outputs"
  local simulated_testlogs="$ws_dir/.topt/simulated-local-testlogs"
  local source="$simulated_testlogs/app/hello_test/test.outputs"
  local artifact_root="$ws_dir/.topt/simulated-remote-artifacts"
  local staged_source="$artifact_root/app/hello_test/test.outputs"

  if [[ ! -d "$original_source" ]]; then
    echo "error: BEP artifact simulation source is missing: $original_source" >&2
    exit 1
  fi
  rm -rf "$artifact_root" "$simulated_testlogs"
  cp -R "$ws_dir/bazel-testlogs" "$simulated_testlogs"
  mkdir -p "$(dirname "$staged_source")"
  cp -R "$original_source" "$staged_source"
  chmod -R u+w "$simulated_testlogs" "$artifact_root" 2>/dev/null || true
  rm -rf "$source"

  "$PYTHON" - "$fresh_bep" "$staged_source" <<'PY'
from pathlib import Path
import json
import sys

bep = Path(sys.argv[1])
staged = Path(sys.argv[2]).resolve().as_uri()
canonical_prefix = ["bazel-out", "k8-fastbuild", "testlogs", "app", "hello_test"]
lines = []
rewritten = 0
uploadable = 0
for raw in bep.read_text(encoding="utf-8-sig").splitlines():
    if not raw.strip():
        continue
    event = json.loads(raw)
    result = event.get("testResult") or event.get("test_result")
    if isinstance(result, dict):
        outputs = result.get("testActionOutput") or result.get("test_action_output") or []
        if "testActionOutput" not in result and "test_action_output" not in result:
            result["testActionOutput"] = outputs
        replaced = False
        for output in outputs:
            if not isinstance(output, dict):
                continue
            if output.get("name") == "test.outputs":
                uploadable += 1
                if not replaced:
                    output["uri"] = staged
                    output["name"] = "test.outputs"
                    output["pathPrefix"] = canonical_prefix
                    output.pop("path", None)
                    rewritten += 1
                    replaced = True
        if not replaced:
            outputs.append({"name": "test.outputs", "uri": staged, "pathPrefix": canonical_prefix})
            rewritten += 1
            uploadable += 1
    lines.append(json.dumps(event, sort_keys=True))
if rewritten == 0:
    raise SystemExit("failed to rewrite any BEP TestResult output for staged artifact simulation")
if uploadable != 1:
    raise SystemExit(f"expected exactly one uploadable test.outputs carrier after rewrite, found {uploadable}")
bep.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

  if [[ -d "$source" ]]; then
    echo "error: BEP artifact simulation failed to remove local test.outputs from scan root: $source" >&2
    exit 1
  fi
  printf '%s\n' "$simulated_testlogs"
}

run_bep_freshness_scenario() {
  local ws_dir="$1"
  local mode="$2"
  local -a workspace_flags=("${BAZEL_EXTRA_ARGS[@]}" --noenable_bzlmod --enable_workspace --config=test-optimization)
  local bep_dir="$ws_dir/.topt/bep-${mode}"
  local fresh_bep="$bep_dir/fresh.bep.json"
  local cached_bep="$bep_dir/cached.bep.json"
  local fresh_log="$bep_dir/fresh.log"
  local staged_log="$bep_dir/staged-artifacts.log"
  local cached_log="$bep_dir/cached.log"
  local opt_out_log="$bep_dir/opt-out.log"

  mkdir -p "$bep_dir"
  rm -f "$fresh_bep" "$cached_bep" "$fresh_log" "$staged_log" "$cached_log" "$opt_out_log"

  (
    cd "$ws_dir"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
      "${workspace_flags[@]}" \
      --remote_download_minimal \
      --remote_download_regex=.*test[.]outputs.* \
      --cache_test_results=no \
      --build_event_json_file="$fresh_bep" \
      "$HELLO_TEST_TARGET"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" run \
      "${workspace_flags[@]}" \
      //:dd_test_optimization_doctor -- \
      --bep-json="$fresh_bep" \
      --freshness-source=bep \
      --freshness-mode=required
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" run \
      "${workspace_flags[@]}" \
      //:dd_upload_payloads -- \
      --bep-json="$fresh_bep" \
      --freshness-source=bep \
      --freshness-mode=required \
      --dry-run \
      --validate-enrichment \
      --expected-enriched-tag=bazel.go.payload_selection
  ) >"$fresh_log" 2>&1
  assert_log_contains "$fresh_log" "freshness filtering enabled: source=bep" "fresh BEP run did not select BEP freshness"
  assert_log_contains "$fresh_log" "dry-run validated enriched test payload" "fresh BEP run did not validate enrichment"
  assert_log_matches "$fresh_log" "dry-run validated [1-9][0-9]* test payloads" "fresh BEP run did not validate any payloads"

  simulated_testlogs="$(simulate_bep_artifact_only_outputs "$ws_dir" "$fresh_bep")"
  (
    cd "$ws_dir"
    TESTLOGS_DIR="$simulated_testlogs" \
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" run \
      "${workspace_flags[@]}" \
      //:dd_test_optimization_doctor -- \
      --bep-json "$fresh_bep" \
      --freshness-source=bep \
      --freshness-mode=required \
      --artifact-source=bep \
      --remote-artifacts=download \
      --artifact-staging-dir "$ws_dir/.topt/bep-artifacts"
    TESTLOGS_DIR="$simulated_testlogs" \
    DD_TEST_OPTIMIZATION_DEBUG=1 \
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" run \
      "${workspace_flags[@]}" \
      //:dd_upload_payloads -- \
      --dry-run \
      --validate-enrichment \
      --bep-json "$fresh_bep" \
      --freshness-source=bep \
      --freshness-mode=required \
      --artifact-source=bep \
      --remote-artifacts=download \
      --artifact-staging-dir "$ws_dir/.topt/bep-artifacts" \
      --expected-enriched-tag=bazel.go.payload_selection
  ) >"$staged_log" 2>&1
  assert_log_contains "$staged_log" "BEP artifact staging selected output key: app/hello_test/test.outputs" "staged BEP run did not keep the canonical output key"
  assert_log_not_contains "$staged_log" "simulated-remote-artifacts/app/hello_test/test.outputs" "staged BEP run derived an output key from the external artifact carrier"
  assert_log_matches "$staged_log" "dry-run validated [1-9][0-9]* test payloads" "staged BEP run did not validate any payloads"

  (
    cd "$ws_dir"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
      "${workspace_flags[@]}" \
      --remote_download_minimal \
      --remote_download_regex=.*test[.]outputs.* \
      --cache_test_results=yes \
      "$HELLO_TEST_TARGET"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
      "${workspace_flags[@]}" \
      --remote_download_minimal \
      --remote_download_regex=.*test[.]outputs.* \
      --cache_test_results=yes \
      --build_event_json_file="$cached_bep" \
      "$HELLO_TEST_TARGET"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" run \
      "${workspace_flags[@]}" \
      //:dd_upload_payloads -- \
      --bep-json="$cached_bep" \
      --freshness-source=bep \
      --freshness-mode=required \
      --dry-run \
      --validate-enrichment
  ) >"$cached_log" 2>&1
  assert_bep_has_cached_test_result "$cached_bep"
  assert_log_contains "$cached_log" "freshness filtering enabled: source=bep" "cached BEP run did not select BEP freshness"
  assert_log_contains "$cached_log" "dry-run validated 0 test payloads" "cached BEP run did not suppress cached payloads"
  assert_log_contains "$cached_log" "skipping cached or non-current test output" "cached BEP run did not log a cached-output skip"

  (
    cd "$ws_dir"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" run \
      "${workspace_flags[@]}" \
      //:dd_upload_payloads -- \
      --bep-json="$cached_bep" \
      --allow-cached-payload-uploads \
      --dry-run \
      --validate-enrichment \
      --expected-enriched-tag=bazel.go.payload_selection
  ) >"$opt_out_log" 2>&1
  assert_log_contains "$opt_out_log" "freshness filtering disabled" "BEP opt-out did not disable freshness filtering"
  assert_log_matches "$opt_out_log" "dry-run validated [1-9][0-9]* test payloads" "BEP opt-out did not preserve legacy payload discovery"
}

create_fixture_archive() {
  local root_dir="$ARCHIVE_ROOT/$ARCHIVE_NAME"

  rm -rf "$ARCHIVE_ROOT"
  mkdir -p "$root_dir/modules"
  cp "$REPO_ROOT/MODULE.bazel" "$root_dir/MODULE.bazel"
  cp "$REPO_ROOT/WORKSPACE" "$root_dir/WORKSPACE"
  cp -R "$REPO_ROOT/tools" "$root_dir/tools"
  cp -R "$REPO_ROOT/modules/go" "$root_dir/modules/go"
  cp -R "$REPO_ROOT/third_party" "$root_dir/third_party"
  (
    cd "$ARCHIVE_ROOT"
    tar -czf "$ARCHIVE_PATH" "$ARCHIVE_NAME"
  )
  ARCHIVE_SHA256="$(sha256_file "$ARCHIVE_PATH")"
  ARCHIVE_URL="$(file_uri "$ARCHIVE_PATH")"
}

write_fixture_bazelrc() {
  local ws_dir="$1"
  local rules_go_repo="$2"

  cat > "$ws_dir/.bazelrc" <<EOF
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
build:test-optimization --@${rules_go_repo}//go/private/orchestrion:enabled=true
EOF
}

write_shared_fixture_sources() {
  local ws_dir="$1"

  mkdir -p "$ws_dir/app" "$ws_dir/tools/build"

  cat > "$ws_dir/BUILD.bazel" <<'EOF'
load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

exports_files([
    "go.mod",
    "go.sum",
    "orchestrion.tool.go",
    "orchestrion.yml",
])

dd_test_optimization_targets(
    name = "test_optimization",
    sync_repo_name = "test_optimization_data",
    expected_targets = ["//app:hello_test"],
)
EOF

  cat > "$ws_dir/tools/build/BUILD.bazel" <<'EOF'
exports_files(["dd_go_test.bzl"])
EOF

  cat > "$ws_dir/tools/build/dd_go_test.bzl" <<EOF
load("@io_bazel_rules_go//go:def.bzl", _go_test = "go_test")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

_ORCHESTRION_PIN_FILES = [
    "//:go.mod",
    "//:go.sum",
    "//:orchestrion.tool.go",
    "//:orchestrion.yml",
]

def dd_go_test(name, **kwargs):
    dd_topt_go_test(
        name = name,
        go_test_rule = _go_test,
        topt_data = topt_data,
        orchestrion_mode = "${ORCHESTRION_MODE}",
        orchestrion_pin_files = _ORCHESTRION_PIN_FILES,
        **kwargs
    )
EOF

  cat > "$ws_dir/app/BUILD.bazel" <<EOF
load("@io_bazel_rules_go//go:def.bzl", "go_binary", "go_library")
load("@io_bazel_rules_go//go/private/rules:transition.bzl", "go_reset_target")
load("//tools/build:dd_go_test.bzl", "dd_go_test")

go_library(
    name = "hello_lib",
    srcs = ["hello.go"],
    importpath = "${MODULE_IMPORTPATH}",
)

go_binary(
    name = "fixture_tool",
    srcs = ["fixture_tool.go"],
    importpath = "${MODULE_IMPORTPATH}/fixture_tool",
)

go_reset_target(
    name = "fixture_tool_reset",
    dep = ":fixture_tool",
)

dd_go_test(
    name = "hello_test",
    srcs = [
        "hello_external_test.go",
        "hello_test.go",
    ],
    data = [":fixture_tool_reset"],
    embed = [":hello_lib"],
)

genquery(
    name = "hello_test_deps_query",
    expression = "deps(//app:hello_test)",
    scope = [":hello_test"],
)
EOF

  cat > "$ws_dir/app/hello.go" <<'EOF'
package main

func greeting() string {
	return "Hello, Workspace!"
}
EOF

  cat > "$ws_dir/app/fixture_tool.go" <<'EOF'
package main

func main() {}
EOF

  cat > "$ws_dir/app/hello_external_test.go" <<'EOF'
package main_test

import "testing"

func TestExternalPackageArchive(t *testing.T) {}
EOF

  cat > "$ws_dir/app/hello_test.go" <<EOF
package main

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	wantServiceName = "${SERVICE_NAME}"
	wantModuleLabel = "${MODULE_LABEL}"
	wantOutDir = "${OUT_DIR}"
	wantBazelPackage = "//app"
	wantBazelTarget = "//app:hello_test"
	wantModuleImportpath = "${MODULE_IMPORTPATH}"
	wantOrchestrionEnabled = true
	wantOrchestrionMode = "${ORCHESTRION_MODE}"
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
	if greeting() != "Hello, Workspace!" {
		t.Fatalf("unexpected greeting %q", greeting())
	}
}

func TestWorkspaceGoEnvWiring(t *testing.T) {
	if got := os.Getenv("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"); got != "true" {
		t.Fatalf("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES = %q, want true", got)
	}
	if got := os.Getenv("DD_TRACE_AGENT_URL"); got != "" {
		t.Fatalf("DD_TRACE_AGENT_URL = %q, want unset so Bazel file mode is not proxied", got)
	}
	if got := os.Getenv("DD_CIVISIBILITY_AGENTLESS_ENABLED"); got != "" {
		t.Fatalf("DD_CIVISIBILITY_AGENTLESS_ENABLED = %q, want unset so Bazel file mode is not proxied", got)
	}
	if got := os.Getenv("DD_CIVISIBILITY_AGENTLESS_URL"); got != "" {
		t.Fatalf("DD_CIVISIBILITY_AGENTLESS_URL = %q, want unset so Bazel file mode is not proxied", got)
	}
	if got := os.Getenv("DD_SERVICE"); got != wantServiceName {
		t.Fatalf("DD_SERVICE = %q, want %s", got, wantServiceName)
	}

	manifestRloc := os.Getenv("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
	if manifestRloc == "" {
		t.Fatal("DD_TEST_OPTIMIZATION_MANIFEST_FILE not set")
	}
	manifestPath, ok := resolveRlocation(manifestRloc)
	if !ok {
		t.Fatalf("failed to resolve manifest runfile %q", manifestRloc)
	}
	if !strings.HasSuffix(manifestRloc, wantOutDir+"/manifest.txt") {
		t.Fatalf("manifest runfile %q did not use custom out_dir %q", manifestRloc, wantOutDir)
	}
	manifestDir := filepath.Dir(manifestPath)

	settingsPath := filepath.Join(manifestDir, "cache", "http", "settings.json")
	settingsContent, err := os.ReadFile(settingsPath)
	if err != nil {
		t.Fatalf("read settings.json: %v", err)
	}
	if len(settingsContent) == 0 {
		t.Fatal("expected non-empty settings.json")
	}

	knownTestsPath := filepath.Join(manifestDir, "cache", "http", "known_tests.json")
	knownTestsContent, err := os.ReadFile(knownTestsPath)
	if err != nil {
		t.Fatalf("read known_tests.json: %v", err)
	}
	var knownTests struct {
		Data struct {
			Attributes struct {
				Tests map[string]json.RawMessage \`json:"tests"\`
			} \`json:"attributes"\`
		} \`json:"data"\`
	}
	if err := json.Unmarshal(knownTestsContent, &knownTests); err != nil {
		t.Fatalf("decode known_tests.json: %v", err)
	}
	if knownTests.Data.Attributes.Tests == nil {
		t.Fatalf("known_tests.json did not contain the canonical tests object: %s", string(knownTestsContent))
	}

	testManagementPath := filepath.Join(manifestDir, "cache", "http", "test_management.json")
	testManagementContent, err := os.ReadFile(testManagementPath)
	if err != nil {
		t.Fatalf("read test_management.json: %v", err)
	}
	var testManagement struct {
		Data struct {
			Attributes struct {
				Modules map[string]json.RawMessage \`json:"modules"\`
			} \`json:"attributes"\`
		} \`json:"data"\`
	}
	if err := json.Unmarshal(testManagementContent, &testManagement); err != nil {
		t.Fatalf("decode test_management.json: %v", err)
	}
	if testManagement.Data.Attributes.Modules == nil {
		t.Fatalf("test_management.json did not contain the canonical modules object: %s", string(testManagementContent))
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
	wantMetadataStrings := map[string]string{
		"bazel.package": wantBazelPackage,
		"bazel.target": wantBazelTarget,
		"bazel.test_optimization.repo_name": "test_optimization_data",
		"bazel.test_optimization.service_name": wantServiceName,
		"bazel.test_optimization.runtime_name": "go",
		"bazel.go.importpath": wantModuleImportpath,
		"bazel.go.importpath_source": "inferred",
		"bazel.go.attr.pure": "auto",
		"bazel.go.attr.race": "auto",
		"bazel.go.attr.msan": "auto",
		"bazel.go.attr.linkmode": "auto",
	}
	for key, want := range wantMetadataStrings {
		if got, _ := metadata[key].(string); got != want {
			t.Fatalf("%s = %v, want %q", key, metadata[key], want)
		}
	}
	selection, _ := metadata["bazel.go.payload_selection"].(string)
	moduleCachePath := filepath.Join(manifestDir, "cache", "http", "module_"+wantModuleLabel, "known_tests.json")
	if _, err := os.Stat(moduleCachePath); err != nil {
		t.Fatalf("matching physical module cache %s is required: %v", moduleCachePath, err)
	}
	if selection != "module" {
		t.Fatalf("bazel.go.payload_selection = %v with deterministic module metadata, want module", selection)
	}
	if got, _ := metadata["bazel.go.orchestrion.enabled"].(bool); got != wantOrchestrionEnabled {
		t.Fatalf("bazel.go.orchestrion.enabled = %v, want %v", metadata["bazel.go.orchestrion.enabled"], wantOrchestrionEnabled)
	}
	if got, _ := metadata["bazel.go.orchestrion.mode"].(string); got != wantOrchestrionMode {
		t.Fatalf("bazel.go.orchestrion.mode = %v, want %q", metadata["bazel.go.orchestrion.mode"], wantOrchestrionMode)
	}
	// This runtime lane uses Bazel's default fastbuild/strip=sometimes
	// configuration, where the macro does not add its own test-only linker flags.
	wantLinkerOptimization := false
	if got, _ := metadata["bazel.go.test_binary_linker_optimization"].(bool); got != wantLinkerOptimization {
		t.Fatalf("bazel.go.test_binary_linker_optimization = %v, want %v", metadata["bazel.go.test_binary_linker_optimization"], wantLinkerOptimization)
	}
	if got, _ := metadata["bazel.go.attr.cgo"].(bool); got {
		t.Fatalf("bazel.go.attr.cgo = %v, want false", metadata["bazel.go.attr.cgo"])
	}
}
EOF

  cp "$PIN_GRAPH_FIXTURE/go.mod" "$ws_dir/go.mod"
  cp "$PIN_GRAPH_FIXTURE/go.sum" "$ws_dir/go.sum"

  cat > "$ws_dir/orchestrion.tool.go" <<'EOF'
//go:build tools

package tools

import (
	_ "github.com/DataDog/orchestrion" // integration
	_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
	_ "github.com/DataDog/dd-trace-go/v2/orchestrion"      // integration
)
EOF

  cat > "$ws_dir/orchestrion.yml" <<'EOF'
# yaml-language-server: $schema=https://datadoghq.dev/orchestrion/schema.json
meta:
  name: workspace-go-integration
  description: Minimal WORKSPACE-mode Orchestrion fixture.

aspects: []
EOF
}

write_bootstrap_generated_wrapper() {
  local ws_dir="$1"
  local bootstrap_output_user_root="$TMP_ROOT/bootstrap_wrapper_output_user_root"

  (
    cd "$ws_dir"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$bootstrap_output_user_root" run \
      "${BAZEL_EXTRA_ARGS[@]}" \
      --noenable_bzlmod \
      --enable_workspace \
      @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
      --workspace "$ws_dir" \
      --workspace-mode \
      --sync-repo-name test_optimization_data \
      --wrapper-package tools/build \
      --wrapper-file dd_go_test.bzl \
      --plain-wrapper-name dd_go_test \
      --optimized-wrapper-name dd_topt_go_test \
      --write-wrapper-template \
      --force
  )
}

write_positive_workspace() {
  local ws_dir="$1"
  local repo_mode="$2"
  local repo_root_bzl
  local rules_go_fork_bzl
  local companion_root_bzl
  local archive_url_bzl

  repo_root_bzl="$(bzl_quote "$REPO_ROOT")"
  rules_go_fork_bzl="$(bzl_quote "$rules_go_fork_abs")"
  companion_root_bzl="$(bzl_quote "$REPO_ROOT/modules/go")"
  archive_url_bzl="$(bzl_quote "$ARCHIVE_URL")"

  cat > "$ws_dir/WORKSPACE" <<EOF
workspace(name = "workspace_go_integration_${repo_mode}")

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")
EOF

  if [[ "$repo_mode" == "local" ]]; then
    cat >> "$ws_dir/WORKSPACE" <<EOF

local_repository(
    name = "datadog-rules-test-optimization",
    path = ${repo_root_bzl},
)

local_repository(
    name = "io_bazel_rules_go",
    path = ${rules_go_fork_bzl},
)

local_repository(
    name = "datadog-rules-test-optimization-go",
    path = ${companion_root_bzl},
    repo_mapping = {
        "@rules_go": "@io_bazel_rules_go",
    },
)
EOF
  else
    cat >> "$ws_dir/WORKSPACE" <<EOF

http_archive(
    name = "datadog-rules-test-optimization",
    urls = [${archive_url_bzl}],
    sha256 = "${ARCHIVE_SHA256}",
    strip_prefix = "${ARCHIVE_NAME}",
)

load("@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl", "datadog_go_test_optimization_workspace_repositories")

datadog_go_test_optimization_workspace_repositories(
    rto_commit = "local-archive-fixture",
    datadog_fetch = "archive",
    rules_go_fetch = "archive",
    rules_go_repo_name = "io_bazel_rules_go",
    rules_go_upstream = "${RULES_GO_UPSTREAM}",
    rules_go_variant = "${RULES_GO_VARIANT}",
    rto_archive_url = ${archive_url_bzl},
    rto_archive_sha256 = "${ARCHIVE_SHA256}",
    rto_archive_prefix = "${ARCHIVE_NAME}",
)
EOF
  fi

  cat >> "$ws_dir/WORKSPACE" <<EOF

http_archive(
    name = "bazel_gazelle",
    sha256 = "b760f7fe75173886007f7c2e616a21241208f3d90e8657dc65d36a771e916b6a",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/bazel-gazelle/releases/download/v0.39.1/bazel-gazelle-v0.39.1.tar.gz",
        "https://github.com/bazelbuild/bazel-gazelle/releases/download/v0.39.1/bazel-gazelle-v0.39.1.tar.gz",
    ],
)

load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")
load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies")
load("@datadog-rules-test-optimization-go//:topt_go_orchestrion_repository.bzl", "dd_topt_go_orchestrion_tool_repo")
load("@datadog-rules-test-optimization-go//:topt_go_workspace.bzl", "dd_topt_go_workspace_sync_repositories")

dd_topt_go_orchestrion_tool_repo(
    version = "${ORCHESTRION_VERSION}",
    dd_trace_go_pin_files = [
        "@//:go.mod",
        "@//:go.sum",
    ],
    go_sdk_root = "@go_sdk//:ROOT",
    go_sdk_version = "${GO_VERSION}",
    log_timing = True,
)

go_rules_dependencies()
go_register_toolchains(version = "${GO_VERSION}")
gazelle_dependencies()

dd_topt_go_workspace_sync_repositories(
    name = "test_optimization_data",
    service = "${SERVICE_NAME}",
    module_path = "${MODULE_IMPORTPATH}",
    runtime_version = "${GO_VERSION}",
    out_dir = "${OUT_DIR}",
    require_git_metadata = True,
)
EOF
}

write_invalid_workspace() {
  local ws_dir="$1"
  local scenario="$2"
  local rules_go_fork_bzl

  rules_go_fork_bzl="$(bzl_quote "$rules_go_fork_abs")"

  cat > "$ws_dir/WORKSPACE" <<EOF
workspace(name = "workspace_go_invalid_${scenario}")

load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

local_repository(
    name = "io_bazel_rules_go",
    path = ${rules_go_fork_bzl},
)

load("@io_bazel_rules_go//go:orchestrion_workspace.bzl", "go_orchestrion_tool_repo")
EOF

  if [[ "$scenario" == "custom_name" ]]; then
    cat >> "$ws_dir/WORKSPACE" <<'EOF'
go_orchestrion_tool_repo(
    name = "custom_tool_repo",
    version = "v1.6.0",
)
EOF
  elif [[ "$scenario" == "conflicting_versions" ]]; then
    cat >> "$ws_dir/WORKSPACE" <<EOF
go_orchestrion_tool_repo(
    version = "${ORCHESTRION_VERSION}",
    dd_trace_go_version = "${DD_TRACE_GO_VERSION}",
    dd_trace_go_versions = {
        "github.com/DataDog/dd-trace-go/v2": "${DD_TRACE_GO_VERSION}",
    },
)
EOF
  elif [[ "$scenario" == "conflicting_pin_version" ]]; then
    cat >> "$ws_dir/WORKSPACE" <<EOF
go_orchestrion_tool_repo(
    version = "${ORCHESTRION_VERSION}",
    dd_trace_go_version = "${DD_TRACE_GO_VERSION}",
    dd_trace_go_pin_files = [
        "@//:go.mod",
        "@//:go.sum",
    ],
)
EOF
  else
    cat >> "$ws_dir/WORKSPACE" <<'EOF'
go_orchestrion_tool_repo()
EOF
  fi

  cat > "$ws_dir/BUILD.bazel" <<'EOF'
filegroup(
    name = "probe",
    srcs = [],
)
EOF
}

run_missing_pin_module_failure() {
  local ws_dir="$WORKSPACE_ROOT/missing_pin_module"
  local output_path="$ws_dir/missing_pin_module.log"
  local -a enabled_flags=("${BAZEL_EXTRA_ARGS[@]}" --noenable_bzlmod --enable_workspace --config=test-optimization)

  rm -rf "$ws_dir"
  mkdir -p "$ws_dir"
  write_positive_workspace "$ws_dir" "archive"
  cp "$MISSING_PIN_MODULE_FIXTURE/go.mod" "$ws_dir/go.mod"
  cp "$MISSING_PIN_MODULE_FIXTURE/go.sum" "$ws_dir/go.sum"
  cat > "$ws_dir/BUILD.bazel" <<'EOF'
exports_files([
    "go.mod",
    "go.sum",
])
EOF
  write_fixture_bazelrc "$ws_dir" "io_bazel_rules_go"

  set +e
  (
    cd "$ws_dir"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" cquery \
      "${enabled_flags[@]}" \
      "@io_bazel_rules_go//go/private/orchestrion:dd_trace_go_version_file" \
      --output=files
  ) >"$output_path" 2>&1
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    echo "error: expected absent tracer module resolution to fail" >&2
    cat "$output_path" >&2
    exit 1
  fi
  if ! grep -F "configure dd_trace_go_versions explicitly" "$output_path" >/dev/null 2>&1; then
    echo "error: absent tracer module failure did not explain the explicit version-map escape hatch" >&2
    cat "$output_path" >&2
    exit 1
  fi
}

run_positive_fixture() {
  local repo_mode="$1"
  local ws_dir="$WORKSPACE_ROOT/${repo_mode}"

  rm -rf "$ws_dir"
  mkdir -p "$ws_dir"
  write_positive_workspace "$ws_dir" "$repo_mode"
  write_shared_fixture_sources "$ws_dir"
  write_fixture_bazelrc "$ws_dir" "io_bazel_rules_go"
  if [[ "$INTEGRATION_SCENARIO_MODE" == "measure" ]]; then
    run_positive_subscenario "$ws_dir" "hermetic"
    return
  fi
  run_positive_subscenario "$ws_dir" "standard"
  run_positive_subscenario "$ws_dir" "hermetic"
}

# run_positive_subscenario executes the positive fixture in standard or hermetic
# mode. The hermetic lane also validates the declared action graph through
# aquery instead of relying on runtime effects alone.
run_positive_subscenario() {
  local ws_dir="$1"
  local mode="$2"
  local -a workspace_flags=("${BAZEL_EXTRA_ARGS[@]}" --noenable_bzlmod --enable_workspace --config=test-optimization)

  if [[ "$mode" == "standard" ]]; then
    (
      cd "$ws_dir"
      USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test "${workspace_flags[@]}" "$HELLO_TEST_TARGET"
    )
    assert_json_test_payloads "$ws_dir" "$mode"
    run_bep_freshness_scenario "$ws_dir" "$mode"
    return
  fi

  if [[ "$mode" != "hermetic" ]]; then
    echo "error: unsupported workspace-go subscenario mode=$mode" >&2
    exit 1
  fi

  local hermetic_root="$ws_dir/.hermetic"
  local hermetic_home="$hermetic_root/home"
  local hermetic_xdg="$hermetic_root/xdg-cache"
  local aquery_output="$hermetic_root/hello_test_aquery.textproto"
  local opt_aquery_output="$hermetic_root/hello_test_opt_aquery.textproto"
  local no_strip_aquery_output="$hermetic_root/hello_test_no_strip_aquery.textproto"
  local output_base=""
  local start_ns=""
  local end_ns=""
  local elapsed_seconds=""
  local proxy_size_bytes=""
  mkdir -p "$hermetic_home" "$hermetic_xdg"

  if [[ "$INTEGRATION_SCENARIO_MODE" == "measure" ]]; then
    (
      cd "$ws_dir"
      USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" aquery \
        "${workspace_flags[@]}" \
        "deps(${HELLO_TEST_TARGET})" \
        --output=textproto > /dev/null
    )
    (
      cd "$ws_dir"
      output_base="$(USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" info "${workspace_flags[@]}" output_base)"
      USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" shutdown
      start_ns="$(wall_time_ns)"
      HOME="$hermetic_home" \
      XDG_CACHE_HOME="$hermetic_xdg" \
      USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
        "${workspace_flags[@]}" \
        "${HERMETIC_BUILD_FLAGS[@]}" \
        "${HERMETIC_TEST_FLAGS[@]}" \
        "$HELLO_TEST_TARGET"
      end_ns="$(wall_time_ns)"
      elapsed_seconds="$("$PYTHON" - <<'PY' "$start_ns" "$end_ns"
import sys
start_ns = int(sys.argv[1])
end_ns = int(sys.argv[2])
print(f"{(end_ns - start_ns) / 1_000_000_000:.6f}")
PY
)"
      proxy_size_bytes="$(module_proxy_size_bytes "$output_base")"
      write_measure_json "$elapsed_seconds" "$proxy_size_bytes" "$MEASURE_OUTPUT_PATH"
    )
    return
  fi

  (
    cd "$ws_dir"
    HOME="$hermetic_home" \
    XDG_CACHE_HOME="$hermetic_xdg" \
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
      "${workspace_flags[@]}" \
      "${HERMETIC_BUILD_FLAGS[@]}" \
      "${HERMETIC_TEST_FLAGS[@]}" \
      "$HELLO_TEST_TARGET"
  )
  assert_json_test_payloads "$ws_dir" "$mode"

  (
    cd "$ws_dir"
    HOME="$hermetic_home" \
    XDG_CACHE_HOME="$hermetic_xdg" \
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" aquery \
      "${workspace_flags[@]}" \
      "${HERMETIC_BUILD_FLAGS[@]}" \
      "deps(${HELLO_TEST_TARGET})" \
      --output=textproto > "$aquery_output"
  )

  "$PYTHON" "$REPO_ROOT/tools/tests/integration/assert_orchestrion_module_proxy_aquery.py" \
    --expected-orchestrion-mode "$ORCHESTRION_MODE" \
    --required-test-optimization-pin-file go.mod \
    --required-test-optimization-pin-file orchestrion.yml \
    --require-plain-compile-in-test-optimization \
    --require-reduced-synthetic-testmain-link-inputs \
    --require-test-optimization-linker-flags \
    --expected-test-optimization-linker-flag-count 2 \
    "$aquery_output"

  (
    cd "$ws_dir"
    HOME="$hermetic_home" \
    XDG_CACHE_HOME="$hermetic_xdg" \
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" aquery \
      "${workspace_flags[@]}" \
      "${HERMETIC_BUILD_FLAGS[@]}" \
      --compilation_mode=opt \
      "deps(${HELLO_TEST_TARGET})" \
      --output=textproto > "$opt_aquery_output"
  )

  "$PYTHON" "$REPO_ROOT/tools/tests/integration/assert_orchestrion_module_proxy_aquery.py" \
    --expected-orchestrion-mode "$ORCHESTRION_MODE" \
    --required-test-optimization-pin-file go.mod \
    --required-test-optimization-pin-file orchestrion.yml \
    --require-plain-compile-in-test-optimization \
    --require-reduced-synthetic-testmain-link-inputs \
    --require-test-optimization-linker-flags \
    --expected-test-optimization-linker-flag-count 1 \
    "$opt_aquery_output"

  (
    cd "$ws_dir"
    HOME="$hermetic_home" \
    XDG_CACHE_HOME="$hermetic_xdg" \
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" aquery \
      "${workspace_flags[@]}" \
      "${HERMETIC_BUILD_FLAGS[@]}" \
      --strip=never \
      "deps(${HELLO_TEST_TARGET})" \
      --output=textproto > "$no_strip_aquery_output"
  )

  "$PYTHON" "$REPO_ROOT/tools/tests/integration/assert_orchestrion_module_proxy_aquery.py" \
    --expected-orchestrion-mode "$ORCHESTRION_MODE" \
    --required-test-optimization-pin-file go.mod \
    --required-test-optimization-pin-file orchestrion.yml \
    --require-plain-compile-in-test-optimization \
    --require-reduced-synthetic-testmain-link-inputs \
    --require-test-optimization-linker-flags \
    --expected-test-optimization-linker-flag-count 0 \
    "$no_strip_aquery_output"
}

write_disabled_fixture_test() {
  local ws_dir="$1"

  cat > "$ws_dir/app/hello_test.go" <<'EOF'
package main

import "testing"

func TestDisabledBootstrap(t *testing.T) {
	if greeting() != "Hello, Workspace!" {
		t.Fatalf("unexpected greeting %q", greeting())
	}
}
EOF
}

run_disabled_no_fetch_smoke() {
  local ws_dir="$WORKSPACE_ROOT/disabled"
  local resolved_repos="$TMP_ROOT/disabled-resolved-repositories.bzl"
  local alias_log="$TMP_ROOT/disabled-aliases.log"
  local genquery_log="$TMP_ROOT/disabled-genquery.log"
  local repository_files="$TMP_ROOT/disabled-orchestrion-repository.files"
  local test_log="$TMP_ROOT/disabled-test.log"
  local test_target_path="${HELLO_TEST_TARGET#//}"
  local test_package="${test_target_path%%:*}"
  local test_name="${test_target_path#*:}"
  local -a disabled_flags=(
    "${BAZEL_EXTRA_ARGS[@]}"
    --noenable_bzlmod
    --enable_workspace
  )
  local -a disabled_env=(
    env
    -u DD_API_KEY
    -u DD_SITE
    -u DD_TEST_OPTIMIZATION_ENABLED
  )
  local aliases=(
    tool_binary
    dd_trace_go_version_file
    dd_trace_go_module_proxy_files
    dd_trace_go_module_proxy_root_marker
    orchestrion_tool_version_file
  )

  rm -rf "$ws_dir"
  mkdir -p "$ws_dir"
  write_positive_workspace "$ws_dir" "archive"
  write_shared_fixture_sources "$ws_dir"
  write_fixture_bazelrc "$ws_dir" "io_bazel_rules_go"
  if [[ "$CONFIG_TRANSITION_ONLY" == "1" ]]; then
    write_bootstrap_generated_wrapper "$ws_dir"
  fi
  write_disabled_fixture_test "$ws_dir"

  : > "$alias_log"
  for alias in "${aliases[@]}"; do
    if ! (
      cd "$ws_dir"
      "${disabled_env[@]}" USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" cquery \
        "${disabled_flags[@]}" \
        --experimental_repository_resolved_file="$resolved_repos" \
        "@io_bazel_rules_go//go/private/orchestrion:$alias" --output=files \
        >"$TMP_ROOT/disabled-alias-$alias.out"
    ) 2>"$TMP_ROOT/disabled-alias-$alias.err"; then
      echo "error: disabled WORKSPACE alias query failed for $alias" >&2
      cat "$TMP_ROOT/disabled-alias-$alias.err" >&2
      exit 1
    fi
    cat "$TMP_ROOT/disabled-alias-$alias.out" >>"$alias_log"
  done
  if [[ -s "$alias_log" ]]; then
    echo "error: disabled WORKSPACE Orchestrion aliases exposed files" >&2
    cat "$alias_log" >&2
    exit 1
  fi

  if ! (
    # Avoid Git Bash converting //pkg:target into a Windows filesystem path.
    cd "$ws_dir/$test_package"
    "${disabled_env[@]}" USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" build \
      "${disabled_flags[@]}" \
      --experimental_repository_resolved_file="$resolved_repos" \
      ":${test_name}_deps_query"
  ) >"$genquery_log" 2>&1; then
    echo "error: disabled WORKSPACE genquery failed" >&2
    cat "$genquery_log" >&2
    exit 1
  fi

  if ! (
    cd "$ws_dir"
    "${disabled_env[@]}" USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" cquery \
      "${disabled_flags[@]}" \
      @rules_go_orchestrion_tool//:orchestrion --output=files
  ) >"$repository_files" 2>>"$genquery_log"; then
    echo "error: disabled WORKSPACE Orchestrion repository query failed" >&2
    cat "$genquery_log" >&2
    exit 1
  fi
  if [[ -s "$repository_files" ]]; then
    echo "error: disabled WORKSPACE Orchestrion repository exposed real files" >&2
    cat "$repository_files" >&2
    exit 1
  fi

  if ! (
    # Avoid Git Bash converting //pkg:target into a Windows filesystem path.
    cd "$ws_dir/$test_package"
    "${disabled_env[@]}" USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
      "${disabled_flags[@]}" \
      --experimental_repository_resolved_file="$resolved_repos" \
      ":$test_name"
  ) >"$test_log" 2>&1; then
    echo "error: disabled WORKSPACE test failed" >&2
    cat "$test_log" >&2
    exit 1
  fi

  if grep -Ein 'building orchestrion|downloading orchestrion|Could not find .go. binary' "$test_log"; then
    echo "error: disabled WORKSPACE smoke attempted the real Orchestrion bootstrap" >&2
    cat "$test_log" >&2
    exit 1
  fi
  if grep -En 'building orchestrion|downloading orchestrion|Could not find .go. binary' "$genquery_log"; then
    echo "error: disabled WORKSPACE genquery attempted the real Orchestrion bootstrap" >&2
    cat "$genquery_log" >&2
    exit 1
  fi

  local testlogs
  if ! testlogs="$(cd "$ws_dir" && "${disabled_env[@]}" USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" info "${disabled_flags[@]}" bazel-testlogs)"; then
    echo "error: unable to locate disabled WORKSPACE test logs" >&2
    exit 1
  fi
  if find "$testlogs" -path '*/test.outputs/payloads/tests/*.json' -print -quit | grep -q .; then
    echo "error: disabled WORKSPACE smoke emitted Test Optimization payloads" >&2
    exit 1
  fi

  local public_kind
  public_kind="$(
    cd "$ws_dir/$test_package"
    "${disabled_env[@]}" USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" query \
      "${disabled_flags[@]}" \
      ":$test_name" \
      --output=label_kind
  )"
  if [[ "$public_kind" != "go_test rule "* ]]; then
    echo "error: disabled WORKSPACE public target kind is '$public_kind', want raw go_test rule" >&2
    exit 1
  fi

  local hidden_name
  for hidden_name in \
    "${test_name}__raw_go_test" \
    "${test_name}_topt_payloads" \
    "${test_name}_topt_bazel_metadata" \
    "${test_name}_orchestrion_pin_files"; do
    if (
      cd "$ws_dir/$test_package"
      "${disabled_env[@]}" USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" query \
        "${disabled_flags[@]}" \
        ":$hidden_name"
    ) >/dev/null 2>&1; then
      echo "error: disabled WORKSPACE branch created enabled-only target :$hidden_name" >&2
      exit 1
    fi
  done
}

run_rules_go_default_stub_smoke() {
  local ws_dir="$WORKSPACE_ROOT/rules-go-default-stub"
  local rules_go_fork_bzl
  local output

  rules_go_fork_bzl="$(bzl_quote "$rules_go_fork_abs")"
  rm -rf "$ws_dir"
  mkdir -p "$ws_dir"
  cat > "$ws_dir/WORKSPACE" <<EOF
workspace(name = "rules_go_default_orchestrion_stub")

load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

local_repository(
    name = "io_bazel_rules_go",
    path = ${rules_go_fork_bzl},
)

load("@io_bazel_rules_go//go:deps.bzl", "go_rules_dependencies")

go_rules_dependencies()
EOF
  cat > "$ws_dir/BUILD.bazel" <<'EOF'
filegroup(
    name = "probe",
    srcs = [],
)
EOF

  output="$(
    (
    cd "$ws_dir"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" cquery \
      "${BAZEL_EXTRA_ARGS[@]}" \
      --noenable_bzlmod \
      --enable_workspace \
      @rules_go_orchestrion_tool//:orchestrion \
      --output=files
    )
  )"
  if [[ -n "$output" ]]; then
    echo "error: rules_go default Orchestrion stub exposed files" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

run_windows_enabled_smoke() {
  local reuse_disabled_workspace="${1:-0}"
  local ws_dir="$WORKSPACE_ROOT/windows-enabled"
  local resolved_repos="$TMP_ROOT/windows-enabled-resolved-repositories.bzl"
  local test_log="$TMP_ROOT/windows-enabled-test.log"
  local test_target_path="${HELLO_TEST_TARGET#//}"
  local test_package="${test_target_path%%:*}"
  local test_name="${test_target_path#*:}"
  local -a bazel_test_flags=()

  if [[ "$(uname -s)" == "Darwin" && "$BAZEL_VERSION" == "8.5.1" ]]; then
    bazel_test_flags+=(--noexperimental_split_xml_generation)
  fi

  if [[ "$reuse_disabled_workspace" == "1" ]]; then
    ws_dir="$WORKSPACE_ROOT/disabled"
  fi
  if [[ -z "$GO_INTEGRATION_MOCK_SERVER_PID" ]]; then
    start_go_integration_mock_server "$TMP_ROOT" "$MODULE_IMPORTPATH"
  fi

  local -a enabled_flags=(
    "${BAZEL_EXTRA_ARGS[@]}"
    "${GO_INTEGRATION_MOCK_REPO_ENVS[@]}"
    --noenable_bzlmod
    --enable_workspace
    --config=test-optimization
  )
  local aliases=(
    tool_binary
    dd_trace_go_version_file
    dd_trace_go_module_proxy_files
    dd_trace_go_module_proxy_root_marker
    orchestrion_tool_version_file
  )

  if [[ "$reuse_disabled_workspace" != "1" ]]; then
    rm -rf "$ws_dir"
    mkdir -p "$ws_dir"
    write_positive_workspace "$ws_dir" "archive"
    write_shared_fixture_sources "$ws_dir"
    write_fixture_bazelrc "$ws_dir" "io_bazel_rules_go"
  fi

  for alias in "${aliases[@]}"; do
    local alias_files="$TMP_ROOT/windows-enabled-workspace-$alias.files"
    local alias_log="$TMP_ROOT/windows-enabled-workspace-$alias.log"
    if ! (
      cd "$ws_dir"
      USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" cquery \
        "${enabled_flags[@]}" \
        --experimental_repository_resolved_file="$resolved_repos" \
        "@io_bazel_rules_go//go/private/orchestrion:$alias" --output=files
    ) >"$alias_files" 2>"$alias_log"; then
      echo "error: enabled WORKSPACE Orchestrion alias $alias failed analysis" >&2
      cat "$alias_log" >&2
      exit 1
    fi
    if [[ ! -s "$alias_files" ]]; then
      echo "error: enabled WORKSPACE Orchestrion alias $alias exposed no files" >&2
      cat "$alias_log" >&2
      exit 1
    fi
    if ! grep -Eq 'rules_go_orchestrion_tool' "$alias_files"; then
      echo "error: enabled WORKSPACE Orchestrion alias $alias did not expose real repository files" >&2
      cat "$alias_files" >&2
      cat "$alias_log" >&2
      exit 1
    fi
  done
  assert_pin_version_file \
    "$ws_dir" \
    "$TMP_ROOT/windows-enabled-workspace-dd_trace_go_version_file.files" \
    "${enabled_flags[@]}"

  if [[ -n "$EXPECTED_ORCHESTRION_CACHE_PHASE" ]]; then
    if ! grep -F "phase=\"$EXPECTED_ORCHESTRION_CACHE_PHASE\"" "$TMP_ROOT"/windows-enabled-workspace-*.log >/dev/null 2>&1; then
      echo "error: enabled WORKSPACE smoke did not emit expected Orchestrion cache phase '$EXPECTED_ORCHESTRION_CACHE_PHASE'" >&2
      cat "$TMP_ROOT"/windows-enabled-workspace-*.log >&2
      exit 1
    fi
  fi

  if ! (
    # Avoid Git Bash converting //pkg:target into a Windows filesystem path.
    cd "$ws_dir/$test_package"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
      "${enabled_flags[@]}" \
      --test_output=errors \
      --verbose_failures \
      "${bazel_test_flags[@]}" \
      --experimental_repository_resolved_file="$resolved_repos" \
      ":$test_name"
  ) >"$test_log" 2>&1; then
    echo "error: enabled WORKSPACE test failed" >&2
    cat "$test_log" >&2
    exit 1
  fi

  local testlogs
  testlogs="$(cd "$ws_dir" && USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" info "${enabled_flags[@]}" bazel-testlogs)"
  if ! find "$testlogs" -path '*/test.outputs/payloads/tests/*.json' -print -quit | grep -q .; then
    echo "error: enabled WORKSPACE smoke emitted no Test Optimization payloads" >&2
    cat "$test_log" >&2
    exit 1
  fi
  local public_kind
  public_kind="$(
    cd "$ws_dir/$test_package"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" query \
      "${enabled_flags[@]}" \
      ":$test_name" \
      --output=label_kind
  )"
  if [[ "$public_kind" != "orch_go_test rule "* ]]; then
    echo "error: enabled WORKSPACE public target kind is '$public_kind', want orch_go_test rule" >&2
    exit 1
  fi
  assert_go_integration_metadata_requests
}

run_expected_failure() {
  local scenario="$1"
  local expected_fragment="$2"
  local ws_dir="$WORKSPACE_ROOT/$scenario"
  local output_path="$ws_dir/${scenario}.log"

  rm -rf "$ws_dir"
  mkdir -p "$ws_dir"
  write_invalid_workspace "$ws_dir" "$scenario"

  set +e
  (
    cd "$ws_dir"
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" query --noenable_bzlmod --enable_workspace //:probe
  ) >"$output_path" 2>&1
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    echo "error: expected scenario '$scenario' to fail" >&2
    cat "$output_path" >&2
    exit 1
  fi

  if ! grep -F "$expected_fragment" "$output_path" >/dev/null 2>&1; then
    echo "error: scenario '$scenario' did not fail with expected text: $expected_fragment" >&2
    cat "$output_path" >&2
    exit 1
  fi
}

mkdir -p "$WORKSPACE_ROOT"
run_rules_go_default_stub_smoke

if [[ "$WINDOWS_DISABLED_SMOKE_ONLY" == "1" || "$ORCHESTRION_DISABLED_SENTINEL" == "1" ]]; then
  ORCHESTRION_VERSION="$ORCHESTRION_DISABLED_SENTINEL_VERSION"
  ORCHESTRION_MODE="test_optimization"
  create_fixture_archive
  run_disabled_no_fetch_smoke
  exit 0
fi

if [[ "$WINDOWS_ENABLED_SMOKE_ONLY" == "1" ]]; then
  ORCHESTRION_MODE="test_optimization"
  create_fixture_archive
  run_windows_enabled_smoke
  exit 0
fi

if [[ "$CONFIG_TRANSITION_ONLY" == "1" ]]; then
  ORCHESTRION_MODE="test_optimization"
  create_fixture_archive
  start_go_integration_mock_server "$TMP_ROOT" "$MODULE_IMPORTPATH"
  run_disabled_no_fetch_smoke
  if [[ -s "$GO_INTEGRATION_MOCK_SERVER_LOG" ]]; then
    echo "error: disabled WORKSPACE phase contacted the metadata server" >&2
    cat "$GO_INTEGRATION_MOCK_SERVER_LOG" >&2
    exit 1
  fi
  run_windows_enabled_smoke 1
  exit 0
fi

create_fixture_archive
start_go_integration_mock_server "$TMP_ROOT" "$MODULE_IMPORTPATH"
BAZEL_EXTRA_ARGS+=("${GO_INTEGRATION_MOCK_REPO_ENVS[@]}")

if [[ "$INTEGRATION_SCENARIO_MODE" == "measure" ]]; then
  if [[ -z "$MEASURE_OUTPUT_PATH" ]]; then
    echo "error: MEASURE_OUTPUT_PATH is required when INTEGRATION_SCENARIO_MODE=measure" >&2
    exit 1
  fi
  run_positive_fixture "archive"
  assert_go_integration_metadata_requests
  exit 0
fi

if [[ "$INTEGRATION_SCENARIO_MODE" != "full" ]]; then
  echo "error: unsupported INTEGRATION_SCENARIO_MODE=$INTEGRATION_SCENARIO_MODE" >&2
  exit 1
fi

run_positive_fixture "local"
run_positive_fixture "archive"
run_missing_pin_module_failure
run_expected_failure "custom_name" "name must be rules_go_orchestrion_tool"
run_expected_failure "missing_version" "version is required in WORKSPACE mode"
run_expected_failure "conflicting_versions" "dd_trace_go_version, dd_trace_go_versions, and dd_trace_go_pin_files are mutually exclusive"
run_expected_failure "conflicting_pin_version" "dd_trace_go_version, dd_trace_go_versions, and dd_trace_go_pin_files are mutually exclusive"
assert_go_integration_metadata_requests
