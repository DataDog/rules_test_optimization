#!/usr/bin/env bash
set -euo pipefail

# Run the slower vendored rules_go patch coverage from a materialized patched
# tree so the clean base fork stays separate from the optional patch bundle.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rules_go_patch_extended.XXXXXX")"
vendor_root="${tmp_root}/rules_go_orchestrion"
BAZEL_VERSION="${BAZEL_VERSION:-$(tr -d '[:space:]' < "${repo_root}/.bazelversion")}"

cleanup() {
  rm -rf "${tmp_root}"
}
trap cleanup EXIT INT TERM HUP

python3 "${repo_root}/tools/dev/materialize_rules_go_patch_tree.py" \
  --bundle dd_source_full \
  --destination "${vendor_root}" \
  --apply-proof-overlay

patch_vendor_module() {
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

patch_vendor_module

run_vendor() {
  (
    cd "${vendor_root}"
    USE_BAZEL_VERSION="${BAZEL_VERSION}" "$@"
  )
}

# The legacy extended lane used Bazel go_test/go_bazel_test and some slower
# proto/link targets that are already broken in the pre-split vendored fork for
# reasons unrelated to this patch split. Keep this maintainer lane on the
# stable, meaningful vendored checks that still exercise the split-sensitive
# surfaces end to end in the materialized tree.
run_vendor env GOWORK=off go test ./go/tools/bzltestutil -count=1
run_vendor bazelisk test //go/tools/builders:buildinfo_test
run_vendor bazelisk test //tests/core/buildinfo:metadata_test //tests/core/buildinfo:srcs_only_test
run_vendor bazelisk test //tests/core/starlark:context_tests_test_0 //tests/core/starlark:context_tests_test_1 //tests/core/starlark:link_tests_test_0 //tests/core/starlark:link_tests_test_1
run_vendor bazelisk test \
  //tests/extras/gomock/source:client_test \
  //tests/extras/gomock/source_with_importpath:client_test \
  //tests/core/go_proto_library:compilers_multi_suffix_test
if [[ "$(uname -s)" != "Windows_NT" ]]; then
  run_vendor bazelisk test //tests/extras/gomock/reflective:client_test
else
  echo "Skipping //tests/extras/gomock/reflective:client_test on Windows hosts." >&2
fi
run_vendor bazelisk test //tests/core/c_linkmodes:c-archive_test //tests/core/c_linkmodes:c-shared_test
run_vendor bazelisk build //tests/core/c_linkmodes:go_with_cgo_dep_caller //tests/core/cgo:embed_chain_bin
