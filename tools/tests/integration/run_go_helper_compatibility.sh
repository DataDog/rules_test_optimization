#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

# Use Bazel's actual wildcard expansion and compatibility checks, not just the
# macro attribute assertions. The fixture uses small executable capture rules;
# real Go instrumentation and uploads are covered by the consumer E2E harnesses.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
bazel="${BAZEL:-$repo_root/bazelw}"
cd "$repo_root/modules/go"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/rto-helper-compatibility.XXXXXX")"
trap 'rm -f "$scratch/output" "$scratch/error"; rmdir "$scratch"' EXIT
flags=(--override_module=datadog-rules-test-optimization=../.. --lockfile_mode=off)
configured_flags=("$@")
package="//tests/compatibility"

run_bazel() {
  local command="$1"
  shift
  if [[ "$command" == query ]]; then
    "$bazel" "$command" "${flags[@]}" "$@"
  else
    "$bazel" "$command" "${flags[@]}" "${configured_flags[@]}" "$@"
  fi
}

expect_failure() {
  local message="$1"
  shift
  if run_bazel "$@" >"$scratch/output" 2>"$scratch/error"; then
    echo "error: expected failure: $*" >&2
    exit 1
  fi
  if ! grep -q "$message" "$scratch/error"; then
    cat "$scratch/error" >&2
    echo "error: expected diagnostic: $message" >&2
    exit 1
  fi
}

# manual does not hide labels from query. Keep them discoverable.
run_bazel query "$package/..." >"$scratch/output"
for suffix in '' '__raw_go_test' '_topt_payloads' '_topt_bazel_metadata'; do
  grep -qx "$package:disabled_repository$suffix" "$scratch/output"
done

# All targets, including independently selected helpers, must be analyzable
# when their metadata repository is disabled. This is Andrew's reproduction.
run_bazel cquery "$package/..." >"$scratch/output"
run_bazel cquery \
  "filter(':(static_select|dynamic_select|disabled_repository)(__raw_go_test|_topt_payloads|_topt_bazel_metadata)?$', $package:all)" \
  --output=starlark \
  --starlark:expr='str(target.label) + " " + str("IncompatiblePlatformProvider" in providers(target))' >"$scratch/output"
test "$(awk '{print $1}' "$scratch/output" | sort -u | wc -l | tr -d ' ')" = 12
if grep -qv ' True$' "$scratch/output"; then
  cat "$scratch/output" >&2
  exit 1
fi

run_bazel build "$package/..."
run_bazel test "$package/..." --test_output=errors
expect_failure incompatible build "$package:disabled_repository"
expect_failure incompatible test "$package:disabled_repository"

# Opening the gate must make both exports' full target chains compatible.
enabled_targets=()
for target in static_select dynamic_select; do
  for suffix in '' '__raw_go_test' '_topt_payloads' '_topt_bazel_metadata'; do
    enabled_targets+=("$package:$target$suffix")
  done
done
run_bazel cquery \
  "set(${enabled_targets[*]})" \
  --define=helper_compatibility=enabled --output=starlark \
  --starlark:expr='str(target.label) + " " + str("IncompatiblePlatformProvider" in providers(target))' >"$scratch/output"
# The wrapper transition can expose a label in more than one configuration.
# Check every configured instance, while counting distinct requested labels.
test "$(awk '{print $1}' "$scratch/output" | sort -u | wc -l | tr -d ' ')" = 8
if grep -qv ' False$' "$scratch/output"; then
  cat "$scratch/output" >&2
  exit 1
fi
run_bazel build --define=helper_compatibility=enabled \
  "$package:static_select_topt_payloads" "$package:static_select_topt_bazel_metadata" \
  "$package:dynamic_select_topt_payloads" "$package:dynamic_select_topt_bazel_metadata"

# Compatibility must not weaken fail-closed metadata validation when selected.
expect_failure 'is disabled' cquery --define=helper_compatibility=enabled \
  "$package:disabled_repository_topt_payloads"
expect_failure 'is disabled' cquery --define=helper_compatibility=enabled \
  "$package:disabled_repository_topt_bazel_metadata"
echo "Go helper compatibility regression checks passed"
