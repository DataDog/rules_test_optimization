#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

# Shared by the WORKSPACE and Bzlmod consumers. Check the supported range's
# endpoints; intermediate profiles retain their existing integration coverage.
nogo_regression_enabled() {
  [[ "$RULES_GO_VERSION" == "0.59.0" || "$RULES_GO_VERSION" == "0.65.0" || "$INTEGRATION_SCENARIO_MODE" == "nogo" ]]
}

write_nogo_fixture() {
  local ws_dir="$1"
  local rules_go_repo="$2"
  mkdir -p "$ws_dir/nogo_fixture"
  cat > "$ws_dir/nogo_fixture/BUILD.bazel" <<EOF
load("@${rules_go_repo}//go:def.bzl", "go_library", "go_test")
load("@${rules_go_repo}//go:def.bzl", "go_binary")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")
load(":probe.bzl", "settings_probe")

settings_probe(name = "probe", tags = ["manual"])

go_binary(name = "bad_data", srcs = ["bad_data.go"], tags = ["manual"])

go_test(
    name = "plain_settings_test",
    srcs = ["settings_test.go"],
    data = [":probe"],
    env = {"PROBE": "\$(rlocationpath :probe)"},
    deps = ["@${rules_go_repo}//go/runfiles"],
    tags = ["manual"],
)

go_library(
    name = "bad_library",
    srcs = ["bad.go"],
    importpath = "${MODULE_IMPORTPATH}/nogo_fixture",
    tags = ["manual"],
)

go_test(
    name = "plain_test",
    srcs = ["bad_test.go"],
    embed = [":bad_library"],
    tags = ["manual"],
)

dd_topt_go_test(
    name = "checked_test",
    srcs = ["bad_test.go"],
    embed = [":bad_library"],
    topt_data = topt_data,
    tags = ["manual"],
)

dd_topt_go_test(
    name = "unchecked_test",
    srcs = ["bad_test.go"],
    embed = [":bad_library"],
    nogo = False,
    topt_data = topt_data,
    tags = ["manual"],
)

dd_topt_go_test(
    name = "disabled_test",
    srcs = ["bad_test.go"],
    embed = [":bad_library"],
    nogo = False,
    restore_non_go_settings = True,
    topt_data = dict(topt_data, enabled = False),
    tags = ["manual"],
)

dd_topt_go_test(
    name = "restored_test",
    srcs = ["bad_test.go"],
    embed = [":bad_library"],
    nogo = False,
    restore_non_go_settings = True,
    topt_data = topt_data,
    tags = ["manual"],
)

dd_topt_go_test(
    name = "restored_settings_test",
    srcs = ["settings_test.go"],
    data = [":probe"],
    env = {"PROBE": "\$(rlocationpath :probe)"},
    deps = ["@${rules_go_repo}//go/runfiles"],
    nogo = False,
    restore_non_go_settings = True,
    topt_data = topt_data,
    tags = ["manual"],
)

dd_topt_go_test(
    name = "portable_settings_control_test",
    srcs = ["settings_test.go"],
    data = [":probe"],
    env = {"PROBE": "\$(rlocationpath :probe)"},
    deps = ["@${rules_go_repo}//go/runfiles"],
    nogo = False,
    topt_data = topt_data,
    tags = ["manual"],
)

dd_topt_go_test(
    name = "restored_data_test",
    srcs = ["bad_test.go"],
    data = [":bad_data"],
    nogo = False,
    restore_non_go_settings = True,
    topt_data = topt_data,
    tags = ["manual"],
)
EOF
  cat > "$ws_dir/nogo_fixture/bad.go" <<'EOF'
package fixture

import "fmt"

// Valid Go that the printf analyzer must reject, in a dependency of the test.
func diagnostic() { fmt.Printf("%d", "invalid") }
EOF
  cat > "$ws_dir/nogo_fixture/bad_test.go" <<'EOF'
package fixture

import "testing"

func TestNogoOptOut(t *testing.T) { t.Log("instrumented execution reached") }
EOF
  cat > "$ws_dir/nogo_fixture/bad_data.go" <<'EOF'
package main
import "fmt"
func main() { fmt.Printf("%d", "invalid") }
EOF
  cat > "$ws_dir/nogo_fixture/probe.bzl" <<EOF
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _probe(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, json.encode({key: dep[BuildSettingInfo].value for key, dep in {
        "sdk": ctx.attr._sdk,
        "skip": ctx.attr._skip,
        "original_sdk": ctx.attr._original_sdk,
        "original_skip": ctx.attr._original_skip,
    }.items()}))
    return [DefaultInfo(files = depset([out]))]

settings_probe = rule(implementation = _probe, attrs = {
    "_sdk": attr.label(default = "@${rules_go_repo}//go/toolchain:sdk_name"),
    "_skip": attr.label(default = "@${rules_go_repo}//go/private:bootstrap_nogo"),
    "_original_sdk": attr.label(default = "@${rules_go_repo}//go/toolchain:original_sdk_name"),
    "_original_skip": attr.label(default = "@${rules_go_repo}//go/private:original_bootstrap_nogo"),
})
EOF
  cat > "$ws_dir/nogo_fixture/settings_test.go" <<'EOF'
package fixture

import (
    "encoding/json"
    "os"
    "testing"
    "github.com/bazelbuild/rules_go/go/runfiles"
)

func TestCallerSettingsRestored(t *testing.T) {
    path, err := runfiles.Rlocation(os.Getenv("PROBE"))
    if err != nil { t.Fatal(err) }
    data, err := os.ReadFile(path)
    if err != nil { t.Fatal(err) }
    var got struct {
        SDK *string `json:"sdk"`
        Skip *bool `json:"skip"`
        OriginalSDK *string `json:"original_sdk"`
        OriginalSkip *string `json:"original_skip"`
    }
    if err = json.Unmarshal(data, &got); err != nil { t.Fatal(err) }
    if got.SDK == nil || got.Skip == nil || got.OriginalSDK == nil || got.OriginalSkip == nil {
        t.Fatalf("missing caller settings: %s", data)
    }
    if *got.SDK != os.Getenv("EXPECTED_SDK_NAME") || *got.Skip || *got.OriginalSDK != "" || *got.OriginalSkip != "" {
        t.Fatalf("caller settings not restored and cleared: %s", data)
    }
}
EOF
}

run_nogo_regression() {
  local ws_dir="$1"
  shift
  local -a flags=("$@")
  local target log
  local kinds
  kinds="$(cd "$ws_dir" && USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" query \
    "${flags[@]}" 'set(//nogo_fixture:checked_test //nogo_fixture:restored_test)' --output=label_kind)"
  if [[ "$(printf '%s\n' "$kinds" | grep -c '^ddtest_go_test rule ')" != "2" ]]; then
    echo "error: the restoration adapter changed Bazel's ddtest_go test language: $kinds" >&2
    exit 1
  fi
  for target in plain_test checked_test disabled_test; do
    log="$ws_dir/nogo-${target}.log"
    if (
      cd "$ws_dir" || exit 1
      USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" build \
        "${flags[@]}" --run_validations "//nogo_fixture:$target"
    ) >"$log" 2>&1; then
      echo "error: $target bypassed the configured nogo analyzer" >&2
      exit 1
    fi
    assert_log_matches "$log" 'format %d.*(string|wrong type)' "$target nogo rejection"
  done
  (
    cd "$ws_dir" || exit 1
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
      "${flags[@]}" --run_validations --nocache_test_results //nogo_fixture:unchecked_test
  )
  local testlogs
  testlogs="$(cd "$ws_dir" && USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" info "${flags[@]}" bazel-testlogs)"
  "$PYTHON" - "$testlogs/nogo_fixture/unchecked_test/test.outputs" <<'PY'
import json
import sys
from pathlib import Path

events = []
for path in Path(sys.argv[1]).rglob("*.json"):
    document = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(document, dict):
        events.extend(document.get("events", []))
tests = [e["content"] for e in events if e.get("type") == "test"]
matching = [e for e in tests if e.get("meta", {}).get("test.name") == "TestNogoOptOut"]
assert len(matching) == 1 and matching[0].get("meta", {}).get("test.status") == "pass", tests
print("Verified nogo opt-out dependency closure, ordinary/disabled controls and instrumented payload")
PY
  log="$ws_dir/nogo-restoration-unavailable.log"
  if (
    cd "$ws_dir" || exit 1
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" build \
      "${flags[@]}" //nogo_fixture:restored_test
  ) >"$log" 2>&1; then
    echo "error: restoration silently accepted an upstream rules_go without the required settings" >&2
    exit 1
  fi
  assert_log_matches "$log" 'original_(sdk_name|bootstrap_nogo)' "restoration prerequisite diagnostic"
}

# Positive adapter proof for a caller-provided rules_go that implements the
# documented restoration contract. No upstream patch is installed by this helper.
run_restored_settings_regression() {
  local ws_dir="$1"
  shift
  local -a flags=("$@")
  (
    cd "$ws_dir" || exit 1
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
      "${flags[@]}" --run_validations --nocache_test_results --test_output=errors \
      //nogo_fixture:plain_settings_test //nogo_fixture:restored_settings_test
  )
  local log="$ws_dir/portable-settings-control.log"
  if (
    cd "$ws_dir" || exit 1
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" test \
      "${flags[@]}" --nocache_test_results --test_output=errors //nogo_fixture:portable_settings_control_test
  ) >"$log" 2>&1; then
    echo "error: the missing-adapter control unexpectedly restored caller settings" >&2
    exit 1
  fi
  assert_log_contains "$log" 'caller settings not restored and cleared' "missing-adapter negative control"
  # Import-path helpers reached through a restored data edge may request the
  # ordinary embedded Go library. Its caller-owned analysis must remain active.
  log="$ws_dir/restored-metadata-nogo.log"
  if (
    cd "$ws_dir" || exit 1
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" build \
      "${flags[@]}" --run_validations //nogo_fixture:restored_test
  ) >"$log" 2>&1; then
    echo "error: nogo was disabled on the ordinary metadata helper dependency" >&2
    exit 1
  fi
  assert_log_matches "$log" 'bad.go:.*format %d' "restored metadata dependency analysis"
  log="$ws_dir/restored-data-nogo.log"
  if (
    cd "$ws_dir" || exit 1
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" build \
      "${flags[@]}" --run_validations //nogo_fixture:restored_data_test
  ) >"$log" 2>&1; then
    echo "error: nogo was disabled on an unrelated Go data binary" >&2
    exit 1
  fi
  assert_log_matches "$log" 'bad_data.go:.*format %d' "restored Go data dependency analysis"
  (
    cd "$ws_dir" || exit 1
    USE_BAZEL_VERSION="$BAZEL_VERSION" "$BAZEL" --output_user_root="$BAZEL_OUTPUT_USER_ROOT" cquery \
      "${flags[@]}" 'filter("//nogo_fixture:probe$", deps(set(//nogo_fixture:plain_settings_test //nogo_fixture:restored_settings_test)))' \
      --output=label > "$ws_dir/restored-configurations.txt"
  )
  if [[ "$(grep -c '^//nogo_fixture:probe ' "$ws_dir/restored-configurations.txt")" != "1" ]]; then
    echo "error: ordinary and restored tests do not share their data dependency configuration" >&2
    cat "$ws_dir/restored-configurations.txt" >&2
    exit 1
  fi
  echo "Verified real non-Go edge restoration, cleared records, shared configuration and Go data nogo enforcement"
}
