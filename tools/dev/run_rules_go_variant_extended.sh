#!/usr/bin/env bash
# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

set -euo pipefail

# Run the slower vendored rules_go coverage from a selected published variant tree.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rules_go_variant_extended.XXXXXX")"
vendor_root="${tmp_root}/rules_go_orchestrion"
RULES_GO_UPSTREAM="${RULES_GO_UPSTREAM:-default}"
RULES_GO_VARIANT="${RULES_GO_VARIANT:-base}"
BAZEL_VERSION="${BAZEL_VERSION:-$(tr -d '[:space:]' < "${repo_root}/.bazelversion")}"
BAZEL_JOBS="${BAZEL_JOBS:-1}"
BAZEL_EXTRA_ARGS=()
if [[ -n "${BAZEL_DISTDIR:-}" ]]; then
  BAZEL_EXTRA_ARGS+=(--distdir="${BAZEL_DISTDIR}")
fi
host_os="$(uname -s)"
host_arch="$(uname -m)"

cleanup() {
  rm -rf "${tmp_root}"
}
trap cleanup EXIT INT TERM HUP

resolve_rules_go_fork_path() {
  python3 "${repo_root}/tools/dev/materialize_rules_go_fork.py" resolve \
    --upstream "${RULES_GO_UPSTREAM}" \
    --variant "${RULES_GO_VARIANT}"
}

rules_go_fork_rel="$(resolve_rules_go_fork_path)"
rules_go_fork_abs="${repo_root}/${rules_go_fork_rel}"

python3 "${repo_root}/tools/dev/materialize_rules_go_fork.py" check \
  --upstream "${RULES_GO_UPSTREAM}" \
  --variant "${RULES_GO_VARIANT}"
mkdir -p "${vendor_root}"
cp -R "${rules_go_fork_abs}/." "${vendor_root}/"
cp -R "${repo_root}/tools/tests/rules_go_variant_regressions/." "${vendor_root}/"

augment_vendor_module() {
  local module_file="${vendor_root}/MODULE.bazel"

  # The clean base keeps the recorded base MODULE unchanged, but the vendored
  # buildinfo and proto regression targets still need org_golang_x_sys exported
  # from the go_deps extension. Inject it only in the temp maintainer tree so
  # the checked-in clean base remains identical to the recorded base commit.
  python3 - "${module_file}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = '    "org_golang_x_net",\n'
if '"org_golang_x_sys",' in text:
    raise SystemExit(0)
if needle not in text:
    raise SystemExit(f"missing go_deps use_repo anchor in {path}")
path.write_text(
    text.replace(needle, needle + '    "org_golang_x_sys",\n', 1),
    encoding="utf-8",
)
PY
}

augment_vendor_module

run_vendor() {
  (
    cd "${vendor_root}"
    USE_BAZEL_VERSION="${BAZEL_VERSION}" "$@"
  )
}

bazel_test() {
  run_vendor bazelisk test --jobs="${BAZEL_JOBS}" ${BAZEL_EXTRA_ARGS[@]+"${BAZEL_EXTRA_ARGS[@]}"} "$@"
}

bazel_build() {
  run_vendor bazelisk build --jobs="${BAZEL_JOBS}" ${BAZEL_EXTRA_ARGS[@]+"${BAZEL_EXTRA_ARGS[@]}"} "$@"
}

# Keep this maintainer lane on stable, meaningful vendored checks that still
# exercise the split-sensitive surfaces end to end in the materialized tree.
run_vendor env GOWORK=off go test ./go/tools/bzltestutil -count=1
bazel_test //tests/core/starlark:context_tests_test_0
bazel_test \
  //tests/extras/gomock/source:client_test \
  //tests/extras/gomock/source_with_importpath:client_test \
  //tests/core/go_proto_library:compilers_multi_suffix_test
if [[ "$(uname -s)" != "Windows_NT" ]]; then
  bazel_test //tests/extras/gomock/reflective:client_test
else
  echo "Skipping //tests/extras/gomock/reflective:client_test on Windows hosts." >&2
fi
bazel_test //tests/core/c_linkmodes:c-archive_test
if [[ "${host_os}" == "Darwin" && "${host_arch}" == "arm64" ]]; then
  echo "Skipping //tests/core/c_linkmodes:c-shared_test on ${host_os}/${host_arch}; the upstream test currently segfaults on the local macOS arm64 host." >&2
else
  bazel_test //tests/core/c_linkmodes:c-shared_test
fi
bazel_build //tests/core/c_linkmodes:go_with_cgo_dep_caller
bazel_test //tests/core/cgo/transitive_mode_regression:transitive_cgo_mode_test
