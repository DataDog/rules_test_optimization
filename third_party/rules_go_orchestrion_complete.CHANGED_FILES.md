# rules_go fork delta

This file is generated. Do not edit by hand.

## Upstream base

- Repository: `https://github.com/bazel-contrib/rules_go.git`
- Commit: `fbbafef6e737fe18d3cdedfff4f8f060ac71d5f3`
- Tag: `v0.60.0`
- Vendored fork: `third_party/rules_go_orchestrion_complete`
- Regenerate: `python3 tools/dev/diff_rules_go_fork.py --metadata third_party/rules_go_orchestrion_complete.METADATA.json --write-report`

## Summary

- Total changed paths: `80`
- Modified files: `42`
- Added files: `38`
- Removed files: `0`

## Modified files

- `MODULE.bazel`
- `MODULE.bazel.lock`
- `docs/doc_helpers.bzl`
- `extras/gomock.bzl`
- `go/BUILD.bazel`
- `go/extensions.bzl`
- `go/private/BUILD.bazel`
- `go/private/actions/archive.bzl`
- `go/private/actions/binary.bzl`
- `go/private/actions/compilepkg.bzl`
- `go/private/actions/link.bzl`
- `go/private/actions/stdlib.bzl`
- `go/private/context.bzl`
- `go/private/repositories.bzl`
- `go/private/rules/BUILD.bazel`
- `go/private/rules/binary.bzl`
- `go/private/rules/info.bzl`
- `go/private/rules/library.bzl`
- `go/private/rules/nogo.bzl`
- `go/private/rules/source.bzl`
- `go/private/rules/stdlib.bzl`
- `go/private/rules/test.bzl`
- `go/private/rules/transition.bzl`
- `go/tools/builders/BUILD.bazel`
- `go/tools/builders/ar.go`
- `go/tools/builders/builder.go`
- `go/tools/builders/cgo2.go`
- `go/tools/builders/compilepkg.go`
- `go/tools/builders/env.go`
- `go/tools/builders/env_test.go`
- `go/tools/builders/filter_buildid.go`
- `go/tools/builders/importcfg.go`
- `go/tools/builders/link.go`
- `go/tools/builders/nogo.go`
- `go/tools/builders/stdlib.go`
- `go/tools/builders/stdliblist.go`
- `go/tools/bzltestutil/xml.go`
- `proto/compiler.bzl`
- `proto/def.bzl`
- `proto/private/toolchain.bzl`
- `tests/core/starlark/BUILD.bazel`
- `tests/core/starlark/context_tests.bzl`

## Added files

- `go/orchestrion_workspace.bzl`
- `go/private/aspects/BUILD.bazel`
- `go/private/aspects/buildinfo_aspect.bzl`
- `go/private/orchestrion/BUILD`
- `go/private/orchestrion/extensions.bzl`
- `go/private/orchestrion/pin_files.bzl`
- `go/tools/builders/buildinfo.go`
- `go/tools/builders/compilepkg_test.go`
- `go/tools/builders/env_orchestrion.go`
- `go/tools/builders/importcfg_test.go`
- `go/tools/builders/modinfo.go`
- `go/tools/builders/module_proxy.go`
- `go/tools/builders/orchestrion.go`
- `go/tools/builders/orchestrion_cache.go`
- `go/tools/builders/orchestrion_cache_test.go`
- `go/tools/builders/orchestrion_mode.go`
- `go/tools/builders/orchestrion_mode_test.go`
- `go/tools/builders/orchestrion_skip_test.go`
- `go/tools/builders/orchestrion_synthetic_tool.go`
- `go/tools/builders/orchestrion_test.go`
- `go/tools/builders/orchestrion_test_helpers_test.go`
- `go/tools/builders/orchestrion_version.go`
- `go/tools/builders/orchestrion_version_test.go`
- `go/tools/builders/probe.go`
- `go/tools/builders/probe_test.go`
- `go/tools/builders/stdlib_test.go`
- `go/tools/builders/tool_version.go`
- `tests/core/buildinfo/BUILD.bazel`
- `tests/core/buildinfo/README.md`
- `tests/core/buildinfo/external_deps_bin_unix.go`
- `tests/core/buildinfo/external_deps_bin_windows.go`
- `tests/core/buildinfo/external_deps_test.go`
- `tests/core/buildinfo/leaf_lib.go`
- `tests/core/buildinfo/metadata_bin.go`
- `tests/core/buildinfo/metadata_test.go`
- `tests/core/buildinfo/mid_lib.go`
- `tests/core/buildinfo/top_lib.go`
- `tests/core/starlark/orchestrion_extension_tests.bzl`

## Removed files

- None

_Generated from `third_party/rules_go_orchestrion_complete.METADATA.json` using `tools/dev/diff_rules_go_fork.py`._
