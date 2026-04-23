# rules_go fork delta

This file is generated. Do not edit by hand.

## Upstream base

- Repository: `https://github.com/bazel-contrib/rules_go.git`
- Commit: `fbbafef6e737fe18d3cdedfff4f8f060ac71d5f3`
- Tag: `v0.60.0`
- Vendored fork: `third_party/rules_go_orchestrion`
- Regenerate: `python3 tools/dev/diff_rules_go_fork.py --write-report`

## Summary

- Total changed paths: `44`
- Modified files: `30`
- Added files: `14`
- Removed files: `0`

## Modified files

- `MODULE.bazel`
- `MODULE.bazel.lock`
- `docs/doc_helpers.bzl`
- `extras/gomock.bzl`
- `go/extensions.bzl`
- `go/private/actions/archive.bzl`
- `go/private/actions/compilepkg.bzl`
- `go/private/actions/link.bzl`
- `go/private/actions/stdlib.bzl`
- `go/private/context.bzl`
- `go/private/rules/info.bzl`
- `go/private/rules/library.bzl`
- `go/private/rules/nogo.bzl`
- `go/private/rules/source.bzl`
- `go/private/rules/stdlib.bzl`
- `go/private/rules/transition.bzl`
- `go/tools/builders/BUILD.bazel`
- `go/tools/builders/ar.go`
- `go/tools/builders/builder.go`
- `go/tools/builders/compilepkg.go`
- `go/tools/builders/env.go`
- `go/tools/builders/filter_buildid.go`
- `go/tools/builders/importcfg.go`
- `go/tools/builders/link.go`
- `go/tools/builders/nogo.go`
- `go/tools/builders/stdlib.go`
- `go/tools/builders/stdliblist.go`
- `proto/compiler.bzl`
- `proto/def.bzl`
- `tests/core/starlark/BUILD.bazel`

## Added files

- `go/orchestrion_workspace.bzl`
- `go/private/orchestrion/BUILD`
- `go/private/orchestrion/extensions.bzl`
- `go/tools/builders/compilepkg_test.go`
- `go/tools/builders/importcfg_test.go`
- `go/tools/builders/orchestrion.go`
- `go/tools/builders/orchestrion_cache.go`
- `go/tools/builders/orchestrion_cache_test.go`
- `go/tools/builders/orchestrion_test.go`
- `go/tools/builders/orchestrion_version.go`
- `go/tools/builders/orchestrion_version_test.go`
- `go/tools/builders/probe.go`
- `go/tools/builders/probe_test.go`
- `tests/core/starlark/orchestrion_extension_tests.bzl`

## Removed files

- None

_Generated from `third_party/rules_go_orchestrion.METADATA.json` using `tools/dev/diff_rules_go_fork.py`._
