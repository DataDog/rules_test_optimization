#!/usr/bin/env bash
set -euo pipefail

# Run the slower vendored rules_go coverage from a selected published variant tree.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rules_go_variant_extended.XXXXXX")"
vendor_root="${tmp_root}/rules_go_orchestrion"
RULES_GO_VARIANT="${RULES_GO_VARIANT:-complete}"
BAZEL_VERSION="${BAZEL_VERSION:-$(tr -d '[:space:]' < "${repo_root}/.bazelversion")}"
BAZEL_JOBS="${BAZEL_JOBS:-1}"
BAZEL_EXTRA_ARGS=()
if [[ -n "${BAZEL_DISTDIR:-}" ]]; then
  BAZEL_EXTRA_ARGS+=(--distdir="${BAZEL_DISTDIR}")
fi

cleanup() {
  rm -rf "${tmp_root}"
}
trap cleanup EXIT INT TERM HUP

case "${RULES_GO_VARIANT}" in
  base|complete)
    ;;
  *)
    echo "error: RULES_GO_VARIANT must be 'base' or 'complete', got '${RULES_GO_VARIANT}'" >&2
    exit 1
    ;;
esac

python3 "${repo_root}/tools/dev/verify_rules_go_variants.py"
mkdir -p "${vendor_root}"
cp -R "${repo_root}/third_party/rules_go_orchestrion_${RULES_GO_VARIANT}/." "${vendor_root}/"
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
  run_vendor bazelisk test --jobs="${BAZEL_JOBS}" "${BAZEL_EXTRA_ARGS[@]}" "$@"
}

bazel_build() {
  run_vendor bazelisk build --jobs="${BAZEL_JOBS}" "${BAZEL_EXTRA_ARGS[@]}" "$@"
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
bazel_test //tests/core/c_linkmodes:c-archive_test //tests/core/c_linkmodes:c-shared_test
bazel_build //tests/core/c_linkmodes:go_with_cgo_dep_caller
