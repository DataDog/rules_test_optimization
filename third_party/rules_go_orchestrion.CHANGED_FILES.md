# rules_go fork delta

This file is generated. Do not edit by hand.

## Upstream base

- Repository: `https://github.com/bazel-contrib/rules_go.git`
- Commit: `fbbafef6e737fe18d3cdedfff4f8f060ac71d5f3`
- Tag: `v0.60.0`
- Vendored fork: `third_party/rules_go_orchestrion`
- Regenerate: `python3 tools/dev/diff_rules_go_fork.py --write-report`

## Summary

- Total changed paths: `93`
- Modified files: `39`
- Added files: `54`
- Removed files: `0`

## Modified files

- `MODULE.bazel`
- `MODULE.bazel.lock`
- `docs/doc_helpers.bzl`
- `go/BUILD.bazel`
- `go/extensions.bzl`
- `go/private/actions/archive.bzl`
- `go/private/actions/binary.bzl`
- `go/private/actions/compilepkg.bzl`
- `go/private/actions/link.bzl`
- `go/private/actions/stdlib.bzl`
- `go/private/context.bzl`
- `go/private/repositories.bzl`
- `go/private/rules/BUILD.bazel`
- `go/private/rules/binary.bzl`
- `go/private/rules/library.bzl`
- `go/private/rules/stdlib.bzl`
- `go/private/rules/transition.bzl`
- `go/tools/builders/BUILD.bazel`
- `go/tools/builders/ar.go`
- `go/tools/builders/builder.go`
- `go/tools/builders/cgo2.go`
- `go/tools/builders/compilepkg.go`
- `go/tools/builders/env.go`
- `go/tools/builders/filter_buildid.go`
- `go/tools/builders/importcfg.go`
- `go/tools/builders/link.go`
- `go/tools/builders/nogo.go`
- `go/tools/builders/stdlib.go`
- `go/tools/builders/stdliblist.go`
- `go/tools/bzltestutil/testdata/report.xml`
- `go/tools/bzltestutil/testdata/timeout.xml`
- `go/tools/bzltestutil/xml.go`
- `proto/compiler.bzl`
- `proto/def.bzl`
- `proto/private/toolchain.bzl`
- `tests/core/cgo/BUILD.bazel`
- `tests/core/go_test/xmlreport_test.go`
- `tests/core/starlark/BUILD.bazel`
- `tests/core/starlark/context_tests.bzl`

## Added files

- `go/orchestrion_workspace.bzl`
- `go/private/aspects/BUILD.bazel`
- `go/private/aspects/buildinfo_aspect.bzl`
- `go/private/context.bzl.orig`
- `go/private/orchestrion/BUILD`
- `go/private/orchestrion/extensions.bzl`
- `go/tools/builders/buildinfo.go`
- `go/tools/builders/buildinfo_test.go`
- `go/tools/builders/compilepkg_test.go`
- `go/tools/builders/importcfg_test.go`
- `go/tools/builders/modinfo.go`
- `go/tools/builders/orchestrion.go`
- `go/tools/builders/orchestrion_cache.go`
- `go/tools/builders/orchestrion_cache_test.go`
- `go/tools/builders/orchestrion_test.go`
- `go/tools/builders/orchestrion_version.go`
- `go/tools/builders/orchestrion_version_test.go`
- `go/tools/builders/probe.go`
- `go/tools/builders/probe_test.go`
- `patches/0002-Include-logs-for-test-reports-regardless-of-failure-.patch`
- `patches/0008-Pass-through-cflags-to-the-assembler-in-cgo-mode.patch`
- `patches/0009-Use-LLVM-for-all-linking.patch`
- `patches/0011-fix-cdeps-propagation.patch`
- `patches/0013-Add-buildInfo-metadata-support.patch`
- `patches/0014-Fix-protobuf-compatibility-use-rules_proto-for-Proto.patch`
- `patches/0015-Optimize-_filter_options-use-O1-dict-lookup-for-exac.patch`
- `patches/0015-Set-GoLink-resource_set-to-match-lld-thread-count.patch`
- `patches/0016-Fix-go_context-check-cached-CgoContextInfo-provider-b.patch`
- `patches/BUILD.bazel`
- `tests/core/buildinfo/BUILD.bazel`
- `tests/core/buildinfo/README.md`
- `tests/core/buildinfo/external_deps_bin_unix.go`
- `tests/core/buildinfo/external_deps_bin_windows.go`
- `tests/core/buildinfo/external_deps_test.go`
- `tests/core/buildinfo/leaf_lib.go`
- `tests/core/buildinfo/metadata_bin.go`
- `tests/core/buildinfo/metadata_test.go`
- `tests/core/buildinfo/mid_lib.go`
- `tests/core/buildinfo/srcs_only_bin.go`
- `tests/core/buildinfo/srcs_only_test.go`
- `tests/core/buildinfo/top_lib.go`
- `tests/core/buildinfo/x_sys_unix_wrapper.go`
- `tests/core/buildinfo/x_sys_windows_wrapper.go`
- `tests/core/cgo/embed_chain_leaf.c`
- `tests/core/cgo/embed_chain_leaf.go`
- `tests/core/cgo/embed_chain_leaf.h`
- `tests/core/cgo/embed_chain_leaf_dep.cc`
- `tests/core/cgo/embed_chain_main.go`
- `tests/core/cgo/embed_chain_mid.cc`
- `tests/core/cgo/embed_chain_mid.go`
- `tests/core/cgo/embed_chain_top.cc`
- `tests/core/cgo/embed_chain_top_lib.go`
- `tests/core/starlark/link_tests.bzl`
- `tests/core/starlark/orchestrion_extension_tests.bzl`

## Removed files

- None

_Generated from `third_party/rules_go_orchestrion.METADATA.json` using `tools/dev/diff_rules_go_fork.py`._
