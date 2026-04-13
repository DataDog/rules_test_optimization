#!/usr/bin/env bash
set -euo pipefail

# Run the slower vendored rules_go patch coverage from the fork's own workspace
# so nightly and manual runs catch drift without bloating the PR gate.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vendor_root="${repo_root}/third_party/rules_go_orchestrion"

run_vendor() {
  (
    cd "${vendor_root}"
    "$@"
  )
}

run_vendor bazelisk test //tests/core/go_test:xmlreport_test
run_vendor bazelisk test //tests/core/cross:cross_test
run_vendor bazelisk test //tests/core/c_linkmodes:all
run_vendor bazelisk test //tests/core/go_proto_library:proto_compat_smoke
run_vendor bazelisk test //tests/core/cgo/asm_conditional_cgo:asm_conditional_cgo_test //tests/core/cgo/asm_dep_conditional_cgo:asm_dep_conditional_cgo_test
