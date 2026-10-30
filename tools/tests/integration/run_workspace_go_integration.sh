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
# - core repo + Go companion repo as separate external repositories, from the
#   checkout (local) or from the release-style archive helper (archive)
# - upstream rules_go (RULES_GO_VERSION) as @io_bazel_rules_go
# - topt_go_ddtest_workspace_repositories instrumenting the registered @go_sdk
#   for the host's exec platform
# - real dd_topt_go_test execution against a nested Go package
# - module-selected payload wiring and custom sync out_dir handling
#
# Debugging tips:
# - Set KEEP_TMP=1 to inspect the generated workspaces after a failure.
# - Override BAZEL=<path> to run with a different Bazel launcher locally.
# - Override GO_BIN=<path> to use a specific Go binary locally.
#

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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
RULES_GO_VERSION="${RULES_GO_VERSION:-0.60.0}"
FORBID_HOST_GO="${FORBID_HOST_GO:-0}"
HOST_GO_SENTINEL_LOG=""
SERVICE_NAME="${SERVICE_NAME:-workspace-go-service}"
MODULE_IMPORTPATH="${MODULE_IMPORTPATH:-example.com/workspace-go-integration}"
MODULE_LABEL="${MODULE_LABEL:-example_com_workspace_go_integration}"
OUT_DIR="${OUT_DIR:-custom_topt}"
HELLO_TEST_TARGET="${HELLO_TEST_TARGET:-//app:hello_test}"
INTEGRATION_SCENARIO_MODE="${INTEGRATION_SCENARIO_MODE:-full}"
ARCHIVE_SHA256=""
ARCHIVE_URL=""
FIXTURE_GIT_REPOSITORY_URL="${FIXTURE_GIT_REPOSITORY_URL:-https://github.com/DataDog/rules-test-optimization-fixture.git}"
FIXTURE_GIT_BRANCH="${FIXTURE_GIT_BRANCH:-main}"
FIXTURE_GIT_COMMIT_SHA="${FIXTURE_GIT_COMMIT_SHA:-1234567890abcdef1234567890abcdef12345678}"
BAZEL_EXTRA_ARGS=(
  "--repo_env=DD_GIT_REPOSITORY_URL=${FIXTURE_GIT_REPOSITORY_URL}"
  "--repo_env=DD_GIT_BRANCH=${FIXTURE_GIT_BRANCH}"
  "--repo_env=DD_GIT_COMMIT_SHA=${FIXTURE_GIT_COMMIT_SHA}"
  "--repo_env=GITHUB_EVENT_PATH="
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
  # bazel-testlogs is a symlink. Copy its contents so staging cannot mutate
  # Bazel's read-only outputs through that symlink.
  cp -RL "$ws_dir/bazel-testlogs" "$simulated_testlogs"
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
  assert_log_contains "$cached_log" "freshness summary: skipped_cached_or_non_current_outputs=1" "cached BEP run did not report one cached-output skip"

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
  if [[ -n "${RTO_RELEASE_ARCHIVE:-}" ]]; then
    if [[ ! -f "$RTO_RELEASE_ARCHIVE" || ! "${RTO_RELEASE_PREFIX:-}" =~ ^rules_test_optimization-[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "error: release archive mode requires an existing RTO_RELEASE_ARCHIVE and versioned RTO_RELEASE_PREFIX" >&2
      exit 1
    fi
    ARCHIVE_PATH="$RTO_RELEASE_ARCHIVE"
    ARCHIVE_NAME="$RTO_RELEASE_PREFIX"
    ARCHIVE_SHA256="$(sha256_file "$ARCHIVE_PATH")"
    ARCHIVE_URL="$(file_uri "$ARCHIVE_PATH")"
    return
  fi
  local root_dir="$ARCHIVE_ROOT/$ARCHIVE_NAME"

  rm -rf "$ARCHIVE_ROOT"
  mkdir -p "$root_dir/modules"
  cp "$REPO_ROOT/MODULE.bazel" "$root_dir/MODULE.bazel"
  cp "$REPO_ROOT/WORKSPACE" "$root_dir/WORKSPACE"
  cp -R "$REPO_ROOT/tools" "$root_dir/tools"
  cp -R "$REPO_ROOT/modules/go" "$root_dir/modules/go"
  (
    cd "$ARCHIVE_ROOT"
    tar -czf "$ARCHIVE_PATH" "$ARCHIVE_NAME"
  )
  ARCHIVE_SHA256="$(sha256_file "$ARCHIVE_PATH")"
  ARCHIVE_URL="$(file_uri "$ARCHIVE_PATH")"
}

write_fixture_bazelrc() {
  local ws_dir="$1"

  cat > "$ws_dir/.bazelrc" <<'EOF'
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
common --incompatible_allow_tags_propagation
common --incompatible_disallow_empty_glob=false
EOF
}

write_shared_fixture_sources() {
  local ws_dir="$1"

  mkdir -p "$ws_dir/app" "$ws_dir/tools/build"

  cat > "$ws_dir/BUILD.bazel" <<'EOF'
load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

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

def dd_go_test(name, **kwargs):
    dd_topt_go_test(
        name = name,
        go_test_rule = _go_test,
        topt_data = topt_data,
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

go_binary(
    name = "fixture_testing_tool",
    srcs = ["fixture_testing_tool.go"],
    importpath = "${MODULE_IMPORTPATH}/fixture_testing_tool",
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
    data = [
        ":fixture_testing_tool",
        ":fixture_tool_reset",
    ],
    embed = [":hello_lib"],
    tags = ["no-remote-exec"],
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

  cat > "$ws_dir/app/fixture_testing_tool.go" <<'EOF'
package main

import "testing"

var _ = testing.Short

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
	if got, _ := metadata["bazel.go.instrumentation.backend"].(string); got != "ddtest" {
		t.Fatalf("bazel.go.instrumentation.backend = %v, want ddtest", metadata["bazel.go.instrumentation.backend"])
	}
	for _, key := range []string{
		"bazel.go.instrumentation.version",
		"bazel.go.instrumentation.release",
		"bazel.go.sdk.name",
		"bazel.go.sdk.version",
	} {
		if got, _ := metadata[key].(string); got == "" {
			t.Fatalf("%s = %v, want a non-empty string", key, metadata[key])
		}
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
}

write_positive_workspace() {
  local ws_dir="$1"
  local repo_mode="$2"
  local repo_root_bzl
  local companion_root_bzl
  local archive_url_bzl
  local rules_go_integrity_value
  local ddtest_platform

  repo_root_bzl="$(bzl_quote "$REPO_ROOT")"
  companion_root_bzl="$(bzl_quote "$REPO_ROOT/modules/go")"
  archive_url_bzl="$(bzl_quote "$ARCHIVE_URL")"
  rules_go_integrity_value="$(rules_go_integrity)"
  ddtest_platform="$(ddtest_host_platform)"

  cat > "$ws_dir/WORKSPACE" <<EOF
workspace(name = "workspace_go_integration_${repo_mode}")

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

http_archive(
    name = "io_bazel_rules_go",
    integrity = "${rules_go_integrity_value}",
    urls = ["https://github.com/bazel-contrib/rules_go/releases/download/v${RULES_GO_VERSION}/rules_go-v${RULES_GO_VERSION}.zip"],
)
EOF

  if [[ "$repo_mode" == "local" ]]; then
    cat >> "$ws_dir/WORKSPACE" <<EOF

local_repository(
    name = "datadog-rules-test-optimization",
    path = ${repo_root_bzl},
)

local_repository(
    name = "datadog-rules-test-optimization-go",
    path = ${companion_root_bzl},
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
load("@datadog-rules-test-optimization-go//:topt_go_workspace.bzl", "dd_topt_go_workspace_sync_repositories")

go_rules_dependencies()

# Bazel's collect_coverage helper needs a shell toolchain even for a plain
# go_test. Bzlmod registers it automatically; WORKSPACE consumers must do so.
load("@rules_shell//shell:repositories.bzl", "rules_shell_dependencies", "rules_shell_toolchains")

rules_shell_dependencies()
rules_shell_toolchains()

go_register_toolchains(version = "${GO_VERSION}")
gazelle_dependencies()

load("@datadog-rules-test-optimization-go//:topt_go_ddtest_repository.bzl", "topt_go_ddtest_workspace_repositories")

topt_go_ddtest_workspace_repositories(
    base_sdk_roots = {"${ddtest_platform}": "@go_sdk//:ROOT"},
    exec_platforms = ["${ddtest_platform}"],
)

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


# ddtest_host_platform prints the ddtest exec platform of this host.
ddtest_host_platform() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) echo "linux_amd64" ;;
    Linux/aarch64 | Linux/arm64) echo "linux_arm64" ;;
    Darwin/x86_64) echo "darwin_amd64" ;;
    Darwin/arm64) echo "darwin_arm64" ;;
    MINGW*/x86_64 | MSYS*/x86_64 | CYGWIN*/x86_64) echo "windows_amd64" ;;
    MINGW*/aarch64 | MINGW*/arm64 | MSYS*/aarch64 | MSYS*/arm64 | CYGWIN*/aarch64 | CYGWIN*/arm64) echo "windows_arm64" ;;
    *)
      echo "error: no ddtest exec platform for $(uname -s)/$(uname -m)" >&2
      return 1
      ;;
  esac
}

# rules_go_integrity prints the BCR integrity of RULES_GO_VERSION's release zip.
rules_go_integrity() {
  case "$RULES_GO_VERSION" in
    0.60.0) echo "sha256-htPcj1nSU1JPkzqvLzwFiWywtgX8NbRgwLSwOZlhJMY=" ;;
    0.61.1) echo "sha256-dj9KP2sDRp/bAKd6Mz3QtVRtPuH6Kds3MSjAj+5z4Og=" ;;
    0.62.0) echo "sha256-C4BclPs3MNwj3zKSXtR3s/TtN7VgddysbyGMPqe0q0I=" ;;
    0.63.0) echo "sha256-w+JTI3EJqy4qjTywdWiLmKbm/OQ9hJhJZI6OOoTyDW8=" ;;
    0.64.2) echo "sha256-1cLJU78kaXsgnCHz/07fRv7eqYUU7DWLEMDnj8NdNj4=" ;;
    0.65.0) echo "sha256-1KbpPcY5RBcrw7kVoRv6jXORyfH9wR1+Q3JPSXYX8OU=" ;;
    *)
      echo "error: no integrity for rules_go $RULES_GO_VERSION; add it to rules_go_integrity" >&2
      return 1
      ;;
  esac
}

run_positive_fixture() {
  local repo_mode="$1"
  local ws_dir="$WORKSPACE_ROOT/${repo_mode}"

  rm -rf "$ws_dir"
  mkdir -p "$ws_dir"
  write_positive_workspace "$ws_dir" "$repo_mode"
  write_shared_fixture_sources "$ws_dir"
  write_fixture_bazelrc "$ws_dir"
  run_positive_subscenario "$ws_dir" "standard"
  run_positive_subscenario "$ws_dir" "hermetic"
}

# assert_ddtest_action_graph checks with aquery that the test is built by
# ddtest instrument, in the default, opt and no-strip modes, whose linker flag
# counts differ.
assert_ddtest_action_graph() {
  local ws_dir="$1"
  local hermetic_home="$2"
  local hermetic_xdg="$3"
  shift 3
  local -a workspace_flags=("$@")
  local -a modes=("default:2" "opt:1" "no_strip:0")
  local entry name count aquery_output
  local -a mode_flags

  for entry in "${modes[@]}"; do
    name="${entry%%:*}"
    count="${entry##*:}"
    mode_flags=()
    case "$name" in
      opt) mode_flags=(--compilation_mode=opt) ;;
      no_strip) mode_flags=(--strip=never) ;;
    esac
    aquery_output="$ws_dir/.hermetic/hello_test_${name}_aquery.json"
    (
      cd "$ws_dir"
      HOME="$hermetic_home" \
      XDG_CACHE_HOME="$hermetic_xdg" \
      USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" aquery \
        "${workspace_flags[@]}" \
        "${HERMETIC_BUILD_FLAGS[@]}" \
        ${mode_flags[@]+"${mode_flags[@]}"} \
        "deps(${HELLO_TEST_TARGET})" \
        --output=jsonproto > "$aquery_output"
    )
    "$PYTHON" "$REPO_ROOT/tools/tests/integration/assert_ddtest_aquery.py" \
      --test-label "$HELLO_TEST_TARGET" \
      --expected-linker-flag-count "$count" \
      --require-test-runner-only-no-remote-exec \
      "$aquery_output"
  done
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
  mkdir -p "$hermetic_home" "$hermetic_xdg"

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
  assert_ddtest_action_graph "$ws_dir" "$hermetic_home" "$hermetic_xdg" "${workspace_flags[@]}"
}

mkdir -p "$WORKSPACE_ROOT"
create_fixture_archive
start_go_integration_mock_server "$TMP_ROOT" "$MODULE_IMPORTPATH"
BAZEL_EXTRA_ARGS+=("${GO_INTEGRATION_MOCK_REPO_ENVS[@]}")

case "$INTEGRATION_SCENARIO_MODE" in
  release)
    run_positive_fixture "archive"
    ;;
  full)
    run_positive_fixture "local"
    run_positive_fixture "archive"
    ;;
  *)
    echo "error: unsupported INTEGRATION_SCENARIO_MODE=$INTEGRATION_SCENARIO_MODE" >&2
    exit 1
    ;;
esac
assert_go_integration_metadata_requests
