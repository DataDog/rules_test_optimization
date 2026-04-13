#!/usr/bin/env bash
set -euo pipefail

# Run the fast vendored rules_go patch checks from the fork's own workspace so
# the targets resolve exactly as they do for maintainers and CI.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vendor_root="${repo_root}/third_party/rules_go_orchestrion"

run_vendor() {
  (
    cd "${vendor_root}"
    "$@"
  )
}

cd "${repo_root}"
python3 tools/dev/verify_rules_go_patch_series.py
run_vendor env GOWORK=off go test ./go/tools/bzltestutil -count=1
run_vendor bazelisk test //go/tools/builders:buildinfo_test
run_vendor bazelisk test //tests/core/buildinfo:buildinfo
run_vendor bazelisk test //tests/core/starlark:all
run_vendor bazelisk test //tests/core/cross:go_cross_binary_test
run_vendor bazelisk test //tests/core/c_linkmodes:c-archive_test //tests/core/c_linkmodes:c-shared_test
run_vendor bazelisk build //tests/core/c_linkmodes:go_with_cgo_dep_caller
run_vendor bazelisk build //tests/core/cgo:embed_chain_bin
run_vendor bazelisk test //tests/core/cgo/asm_cflags:asm_cflags_test
