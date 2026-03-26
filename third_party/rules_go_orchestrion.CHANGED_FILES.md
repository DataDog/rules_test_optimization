# rules_go fork delta

This file is generated. Do not edit by hand.

## Upstream base

- Repository: `https://github.com/bazel-contrib/rules_go.git`
- Commit: `b3e12d797150cdc36f27e72f52f6a5c752762641`
- Tag: `v0.59.0`
- Vendored fork: `third_party/rules_go_orchestrion`
- Regenerate: `python3 tools/dev/diff_rules_go_fork.py --write-report`

## Summary

- Total changed paths: `82`
- Modified files: `64`
- Added files: `15`
- Removed files: `3`

## Modified files

- `.bazelci/presubmit.yml`
- `.bazelrc`
- `MODULE.bazel`
- `MODULE.bazel.lock`
- `README.rst`
- `WORKSPACE`
- `docs/BUILD.bazel`
- `docs/doc_helpers.bzl`
- `docs/go/core/bzlmod.md`
- `docs/go/core/rules.md`
- `docs/go/extras/extras.md`
- `go.mod`
- `go.sum`
- `go/config/BUILD.bazel`
- `go/extensions.bzl`
- `go/modes.rst`
- `go/private/BUILD.sdk.bazel`
- `go/private/actions/archive.bzl`
- `go/private/actions/compilepkg.bzl`
- `go/private/actions/link.bzl`
- `go/private/actions/stdlib.bzl`
- `go/private/context.bzl`
- `go/private/extensions.bzl`
- `go/private/go_toolchain.bzl`
- `go/private/mode.bzl`
- `go/private/rules/binary.bzl`
- `go/private/rules/library.bzl`
- `go/private/rules/stdlib.bzl`
- `go/private/rules/test.bzl`
- `go/private/rules/transition.bzl`
- `go/private/sdk.bzl`
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
- `go/tools/builders/stdliblist_test.go`
- `go/tools/gopackagesdriver/BUILD.bazel`
- `go/tools/gopackagesdriver/flatpackage.go`
- `go/tools/gopackagesdriver/main.go`
- `proto/compiler.bzl`
- `tests/core/go_binary/BUILD.bazel`
- `tests/core/go_binary/pie_darwin_amd64_test.go`
- `tests/core/go_binary/pie_darwin_test.go`
- `tests/core/go_binary/pie_linux_test.go`
- `tests/core/starlark/BUILD.bazel`
- `tests/core/starlark/sdk_tests.bzl`
- `tests/core/stdlib/BUILD.bazel`
- `tests/core/stdlib/buildid_test.go`
- `tests/core/strip/strip_test.go`
- `tests/examples/executable_name/name_test.sh`
- `tests/extras/gomock/reflective/BUILD.bazel`
- `tests/extras/gomock/source/BUILD.bazel`
- `tests/extras/gomock/source_with_importpath/BUILD.bazel`
- `tests/integration/googleapis/BUILD.bazel`
- `tests/integration/popular_repos/BUILD.bazel`
- `tests/integration/popular_repos/README.rst`
- `tools.go`

## Added files

- `go/private/orchestrion/BUILD`
- `go/private/orchestrion/extensions.bzl`
- `go/tools/.DS_Store`
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
- `tests/core/runfiles/runfiles_remote_test/MODULE.bazel`
- `tests/core/starlark/orchestrion_extension_tests.bzl`

## Removed files

- `docs/rule_body.vm`
- `tests/core/runfiles/runfiles_remote_test/WORKSPACE`
- `tests/grpc_repos.bzl`

_Generated from `third_party/rules_go_orchestrion.METADATA.json` using `tools/dev/diff_rules_go_fork.py`._
