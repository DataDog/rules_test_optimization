# rules_go fork delta

This file is generated. Do not edit by hand.

## Upstream base

- Repository: `https://github.com/bazel-contrib/rules_go.git`
- Commit: `4b05ddfe19b4d2afa8d7d5f4ba9e4e4c0037e9e5`
- Tag: `v0.61.1`
- Vendored fork: `third_party/rgo/v0_61_1/base`
- Regenerate: `python3 tools/dev/diff_rules_go_fork.py --upstream v0_61_1 --variant base --write-report`

## Summary

- Total changed paths: `54`
- Modified files: `30`
- Added files: `24`
- Removed files: `0`

## Modified files

- `BUILD.bazel`
- `MODULE.bazel`
- `MODULE.bazel.lock`
- `docs/doc_helpers.bzl`
- `go/extensions.bzl`
- `go/private/BUILD.bazel`
- `go/private/actions/archive.bzl`
- `go/private/actions/compilepkg.bzl`
- `go/private/actions/link.bzl`
- `go/private/actions/stdlib.bzl`
- `go/private/context.bzl`
- `go/private/repositories.bzl`
- `go/private/rules/library.bzl`
- `go/private/rules/stdlib.bzl`
- `go/private/rules/test.bzl`
- `go/private/rules/transition.bzl`
- `go/tools/builders/BUILD.bazel`
- `go/tools/builders/ar.go`
- `go/tools/builders/builder.go`
- `go/tools/builders/compilepkg.go`
- `go/tools/builders/env.go`
- `go/tools/builders/env_test.go`
- `go/tools/builders/filter_buildid.go`
- `go/tools/builders/importcfg.go`
- `go/tools/builders/link.go`
- `go/tools/builders/nogo.go`
- `go/tools/builders/stdlib.go`
- `go/tools/builders/stdliblist.go`
- `tests/core/starlark/BUILD.bazel`
- `tests/core/starlark/context_tests.bzl`

## Added files

- `go/orchestrion_workspace.bzl`
- `go/private/orchestrion/BUILD`
- `go/private/orchestrion/extensions.bzl`
- `go/private/orchestrion/pin_files.bzl`
- `go/tools/builders/compilepkg_test.go`
- `go/tools/builders/env_orchestrion.go`
- `go/tools/builders/importcfg_test.go`
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
- `tests/core/starlark/orchestrion_extension_tests.bzl`

## Removed files

- None

_Generated from `third_party/rgo/v0_61_1/base.METADATA.json` using `tools/dev/diff_rules_go_fork.py`._
