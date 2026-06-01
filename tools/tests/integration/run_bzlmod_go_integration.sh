#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

set -euo pipefail

# -----------------------------------------------------------------------------
# Integration harness: Bzlmod Go companion verification
# -----------------------------------------------------------------------------
#
# This script creates a temporary Bzlmod consumer and validates the supported Go
# product path against the current checkout:
# - core repo and Go companion repo consumed via archive_override(...)
# - rules_go consumed from one published Orchestrion variant in this repository
# - Orchestrion extension wiring in the consumer root module
# - module-selected payload wiring through the example stub extension
#
# Debugging tips:
# - Set KEEP_TMP=1 to inspect the generated workspaces after a failure.
# - Override BAZEL=<path> to run with a different Bazel launcher locally.
# - Override GO_BIN=<path> to use a specific Go binary locally.
# - Set BAZEL_DISTDIR=<path> when local network mirrors cannot fetch release
#   assets directly; Bazel will reuse matching archive files from that directory.
#

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rules_topt_bzlmod_go.XXXXXX")"
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
ORCHESTRION_VERSION="${ORCHESTRION_VERSION:-v1.6.0}"
ORCHESTRION_MODE="${ORCHESTRION_MODE:-general}"
DD_TRACE_GO_VERSION="${DD_TRACE_GO_VERSION:-v2.9.0-rc.2}"
SERVICE_NAME="${SERVICE_NAME:-bzlmod-go-service}"
MODULE_IMPORTPATH="${MODULE_IMPORTPATH:-example.com/bzlmod-go-integration}"
MODULE_LABEL="${MODULE_LABEL:-example_com_bzlmod_go_integration}"
OUT_DIR="${OUT_DIR:-custom_topt}"
HELLO_TEST_TARGET="${HELLO_TEST_TARGET:-//app:hello_test}"
INTEGRATION_SCENARIO_MODE="${INTEGRATION_SCENARIO_MODE:-full}"
MEASURE_OUTPUT_PATH="${MEASURE_OUTPUT_PATH:-}"
ARCHIVE_SHA256=""
ARCHIVE_URL=""
RULES_GO_VARIANT="${RULES_GO_VARIANT:-base}"
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
BAZEL_EXTRA_ARGS=()
if [[ -n "${BAZEL_DISTDIR:-}" ]]; then
  BAZEL_EXTRA_ARGS+=(--distdir="$BAZEL_DISTDIR")
fi

cleanup() {
  USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" shutdown >/dev/null 2>&1 || true
  if [[ "${KEEP_TMP:-0}" == "1" ]]; then
    echo "KEEP_TMP=1: workspace fixtures left at $TMP_ROOT"
    return
  fi
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
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

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    PYTHON=python
  else
    echo "error: python interpreter not found (tried '$PYTHON' and 'python')" >&2
    exit 1
  fi
fi

require_command "$GO_BIN" "go binary not found (tried '$GO_BIN')"
require_command tar "tar is required for the Bzlmod archive fixture"

case "$RULES_GO_VARIANT" in
  base|complete)
    ;;
  *)
    echo "error: RULES_GO_VARIANT must be 'base' or 'complete', got '$RULES_GO_VARIANT'" >&2
    exit 1
    ;;
esac

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
    "mode": "bzlmod",
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
  ARCHIVE_URL="file://$ARCHIVE_PATH"
}

write_shared_fixture_sources() {
  local ws_dir="$1"

  mkdir -p "$ws_dir/app"

  cat > "$ws_dir/BUILD.bazel" <<'EOF'
exports_files([
    "go.mod",
    "go.sum",
    "orchestrion.tool.go",
    "orchestrion.yml",
])
EOF

  cat > "$ws_dir/app/BUILD.bazel" <<EOF
load("@rules_go//go:def.bzl", "go_binary", "go_library")
load("@rules_go//go/private/rules:transition.bzl", "go_reset_target")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

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

dd_topt_go_test(
    name = "hello_test",
    srcs = [
        "hello_external_test.go",
        "hello_test.go",
    ],
    data = [":fixture_tool_reset"],
    embed = [":hello_lib"],
    orchestrion_pin_files = [
        "//:go.mod",
        "//:go.sum",
        "//:orchestrion.tool.go",
        "//:orchestrion.yml",
    ],
    orchestrion_mode = "${ORCHESTRION_MODE}",
    topt_data = topt_data,
)
EOF

  cat > "$ws_dir/app/hello.go" <<'EOF'
package main

func greeting() string {
	return "Hello, Bzlmod!"
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
	if greeting() != "Hello, Bzlmod!" {
		t.Fatalf("unexpected greeting %q", greeting())
	}
}

func TestBzlmodGoEnvWiring(t *testing.T) {
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
	if !strings.Contains(string(knownTestsContent), "module:"+wantModuleLabel) {
		t.Fatalf("known_tests.json did not contain module marker %q: %s", "module:"+wantModuleLabel, string(knownTestsContent))
	}

	testManagementPath := filepath.Join(manifestDir, "cache", "http", "test_management.json")
	testManagementContent, err := os.ReadFile(testManagementPath)
	if err != nil {
		t.Fatalf("read test_management.json: %v", err)
	}
	if !strings.Contains(string(testManagementContent), "\""+wantModuleLabel+"\"") {
		t.Fatalf("test_management.json did not contain module label %q: %s", wantModuleLabel, string(testManagementContent))
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
		"bazel.go.payload_selection": "module",
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
	if got, _ := metadata["bazel.go.payload_selection"].(string); got != "module" {
		t.Fatalf("bazel.go.payload_selection = %v, want module", metadata["bazel.go.payload_selection"])
	}
	if got, _ := metadata["bazel.go.orchestrion.enabled"].(bool); got != wantOrchestrionEnabled {
		t.Fatalf("bazel.go.orchestrion.enabled = %v, want %v", metadata["bazel.go.orchestrion.enabled"], wantOrchestrionEnabled)
	}
	if got, _ := metadata["bazel.go.orchestrion.mode"].(string); got != wantOrchestrionMode {
		t.Fatalf("bazel.go.orchestrion.mode = %v, want %q", metadata["bazel.go.orchestrion.mode"], wantOrchestrionMode)
	}
	wantLinkerOptimization := wantOrchestrionMode == "test_optimization"
	if got, _ := metadata["bazel.go.test_binary_linker_optimization"].(bool); got != wantLinkerOptimization {
		t.Fatalf("bazel.go.test_binary_linker_optimization = %v, want %v", metadata["bazel.go.test_binary_linker_optimization"], wantLinkerOptimization)
	}
	if got, _ := metadata["bazel.go.attr.cgo"].(bool); got {
		t.Fatalf("bazel.go.attr.cgo = %v, want false", metadata["bazel.go.attr.cgo"])
	}
}
EOF

  cat > "$ws_dir/go.mod" <<EOF
module ${MODULE_IMPORTPATH}

go ${GO_VERSION}

require (
	github.com/DataDog/dd-trace-go/contrib/log/slog/v2 ${DD_TRACE_GO_VERSION}
	github.com/DataDog/dd-trace-go/contrib/net/http/v2 ${DD_TRACE_GO_VERSION}
	github.com/DataDog/dd-trace-go/v2 ${DD_TRACE_GO_VERSION}
	github.com/DataDog/orchestrion ${ORCHESTRION_VERSION}
)
EOF
  write_orchestrion_go_sum "$ws_dir"

  cat > "$ws_dir/orchestrion.tool.go" <<'EOF'
//go:build tools

package tools

import (
	_ "github.com/DataDog/orchestrion" // integration
	_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration
	_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
	_ "github.com/DataDog/dd-trace-go/v2/orchestrion"      // integration
)
EOF

  cat > "$ws_dir/orchestrion.yml" <<'EOF'
# yaml-language-server: $schema=https://datadoghq.dev/orchestrion/schema.json
meta:
  name: bzlmod-go-integration
  description: Minimal Bzlmod-mode Orchestrion fixture.

aspects: []
EOF
}

# write_orchestrion_go_sum keeps the maintained fixture on a real checked-in
# style go.sum for the default tracer/tool versions. Only ad hoc version
# overrides fall back to generating go.sum dynamically.
write_orchestrion_go_sum() {
  local ws_dir="$1"

  if [[ "$DD_TRACE_GO_VERSION" == "v2.9.0-rc.2" && "$ORCHESTRION_VERSION" == "v1.6.0" ]]; then
    cat > "$ws_dir/go.sum" <<'EOF'
github.com/DataDog/dd-trace-go/contrib/log/slog/v2 v2.9.0-rc.2 h1:yK4ZuP8ZlX25JNCxqyIFWS0bo7uO/09PyUZQaBq8JOM=
github.com/DataDog/dd-trace-go/contrib/log/slog/v2 v2.9.0-rc.2/go.mod h1:DKz8vnMfTfi9rUUQ5Mzl1Gypl4yIgHNYt+RCXZGAX8k=
github.com/DataDog/dd-trace-go/contrib/net/http/v2 v2.9.0-rc.2 h1:C5LUnGTUVZBfUOnqElROZfAQ/vS0Efap3WEwdeg+imE=
github.com/DataDog/dd-trace-go/contrib/net/http/v2 v2.9.0-rc.2/go.mod h1:nlDaIbj9d4ZR5V/RKtzkj5Sr0iSmMY8uYnEOyJDA5XA=
github.com/DataDog/dd-trace-go/v2 v2.9.0-rc.2 h1:gSkZbKLPQzeON4TOqy6Cjo9N5zwpij2YJnypSQy+Bdg=
github.com/DataDog/dd-trace-go/v2 v2.9.0-rc.2/go.mod h1:ZFJoP0mJs9DJcUteQYmNApyDb6duhUTZBPlpvA1itF8=
github.com/DataDog/orchestrion v1.6.0 h1:vGlV16WhB8CWP26ehdsiDkVN09lslnG60utJ+wb9rS4=
github.com/DataDog/orchestrion v1.6.0/go.mod h1:CYY2VfaEQVr+gwKSlpUoHBF9JIO4eV3BfSeG0YAQwZE=
EOF
    return
  fi

  (
    cd "$ws_dir"
    GOWORK=off "$GO_BIN" mod download all
  )
}

write_module_file() {
  local ws_dir="$1"
  local archive_url_bzl

  archive_url_bzl="$(bzl_quote "$ARCHIVE_URL")"

  cat > "$ws_dir/MODULE.bazel" <<EOF
module(name = "bzlmod_go_integration")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
bazel_dep(name = "rules_go", version = "0.60.0")

archive_override(
    module_name = "datadog-rules-test-optimization",
    urls = [${archive_url_bzl}],
    sha256 = "${ARCHIVE_SHA256}",
    strip_prefix = "${ARCHIVE_NAME}",
)

archive_override(
    module_name = "datadog-rules-test-optimization-go",
    urls = [${archive_url_bzl}],
    sha256 = "${ARCHIVE_SHA256}",
    strip_prefix = "${ARCHIVE_NAME}/modules/go",
)

archive_override(
    module_name = "rules_go",
    urls = [${archive_url_bzl}],
    sha256 = "${ARCHIVE_SHA256}",
    strip_prefix = "${ARCHIVE_NAME}/third_party/rules_go_orchestrion_${RULES_GO_VARIANT}",
EOF
  cat >> "$ws_dir/MODULE.bazel" <<EOF
)

example_stub_repo = use_extension(
    "@datadog-rules-test-optimization//tools/tests:example_stub_repo.bzl",
    "example_stub_repo_extension",
)
example_stub_repo.example_stub_repo(
    name = "test_optimization_data",
    out_dir = "${OUT_DIR}",
    service_name = "${SERVICE_NAME}",
    service_keys = ["go_service"],
    labels = ["${MODULE_LABEL}"],
    go_module_path = "${MODULE_IMPORTPATH}",
    go_sanitized_module_path = "${MODULE_LABEL}",
    go_module_included = True,
)
use_repo(example_stub_repo, "test_optimization_data")

orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = "${ORCHESTRION_VERSION}",
    dd_trace_go_version = "${DD_TRACE_GO_VERSION}",
)
use_repo(orchestrion, "rules_go_orchestrion_tool")
EOF
}

run_fixture() {
  local ws_dir="$WORKSPACE_ROOT/main"

  rm -rf "$ws_dir"
  mkdir -p "$ws_dir"
  write_module_file "$ws_dir"
  write_shared_fixture_sources "$ws_dir"
  if [[ "$INTEGRATION_SCENARIO_MODE" == "measure" ]]; then
    run_fixture_subscenario "$ws_dir" "hermetic"
    return
  fi
  run_fixture_subscenario "$ws_dir" "standard"
  run_fixture_subscenario "$ws_dir" "hermetic"
}

# run_fixture_subscenario executes the positive Bzlmod fixture in standard or
# hermetic mode and uses aquery in the hermetic lane to verify the declared
# action graph.
run_fixture_subscenario() {
  local ws_dir="$1"
  local mode="$2"
  local -a bzlmod_flags=(--enable_bzlmod)

  if [[ "$mode" == "standard" ]]; then
    (
      cd "$ws_dir"
      USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
        "${BAZEL_EXTRA_ARGS[@]}" \
        "${bzlmod_flags[@]}" \
        "$HELLO_TEST_TARGET"
    )
    assert_json_test_payloads "$ws_dir" "$mode"
    return
  fi

  if [[ "$mode" != "hermetic" ]]; then
    echo "error: unsupported bzlmod-go subscenario mode=$mode" >&2
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
        "${BAZEL_EXTRA_ARGS[@]}" \
        "${bzlmod_flags[@]}" \
        "deps(${HELLO_TEST_TARGET})" \
        --output=textproto > /dev/null
    )
    (
      cd "$ws_dir"
      output_base="$(USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" info "${bzlmod_flags[@]}" output_base)"
      USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" shutdown
      start_ns="$(wall_time_ns)"
      HOME="$hermetic_home" \
      XDG_CACHE_HOME="$hermetic_xdg" \
      USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
        "${BAZEL_EXTRA_ARGS[@]}" \
        "${bzlmod_flags[@]}" \
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
      "${BAZEL_EXTRA_ARGS[@]}" \
      "${bzlmod_flags[@]}" \
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
      "${BAZEL_EXTRA_ARGS[@]}" \
      "${bzlmod_flags[@]}" \
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
      "${BAZEL_EXTRA_ARGS[@]}" \
      "${bzlmod_flags[@]}" \
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
      "${BAZEL_EXTRA_ARGS[@]}" \
      "${bzlmod_flags[@]}" \
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

mkdir -p "$WORKSPACE_ROOT"
create_fixture_archive

if [[ "$INTEGRATION_SCENARIO_MODE" == "measure" ]]; then
  if [[ -z "$MEASURE_OUTPUT_PATH" ]]; then
    echo "error: MEASURE_OUTPUT_PATH is required when INTEGRATION_SCENARIO_MODE=measure" >&2
    exit 1
  fi
  run_fixture
  exit 0
fi

if [[ "$INTEGRATION_SCENARIO_MODE" != "full" ]]; then
  echo "error: unsupported INTEGRATION_SCENARIO_MODE=$INTEGRATION_SCENARIO_MODE" >&2
  exit 1
fi

run_fixture
