# `rules_go` Patch Port Folder Guide

This note explains why each folder changed in the `rules_go` patch-series port on
branch `feat/rules-go-patch-series-port`.

The goal of the port was not only to copy behavior from the internal
`dd-source` patch series. It also had to make that series reproducible in this
repository, compatible with the Orchestrion fork, and covered by local tests.

## How To Read This

There are three kinds of changes in this branch:

1. **Patch artifacts**
   These are the checked-in replacement patch files with the same names and
   ordering as the internal series.
2. **Fork implementation**
   These are the actual source changes inside `third_party/rules_go_orchestrion`
   that make the vendored fork behave like the patched internal fork.
3. **Local proof and maintenance support**
   These are files that do not exist in the internal patch set as-is, but are
   needed here to make the port testable, reproducible, and maintainable.

## Original Versus Local-Only Files

- The checked-in patch files under `third_party/rules_go_orchestrion/patches/`
  are the local 1:1 replacement series.
- Many production-code changes under `go/private`, `go/tools`, and `proto`
  correspond directly to the internal patch intent.
- The `tests/core/buildinfo` directory is mostly the local realization of the
  internal BuildInfo test shape, but some files there are local-only additions.
- The `tests/core/cgo/embed_chain_*` files are local-only regression fixtures.
  They were added here because the internal `0011` patch changed behavior in
  `context.bzl` but did not provide a self-contained regression fixture.

## Folder-By-Folder Explanation

### `third_party/rules_go_orchestrion/patches/`

Why it changed:
- This directory now holds the 9 replacement patch files.
- The requirement for this work was to keep the same patch filenames, ordering,
  and logical boundaries as the internal series.

Why it uses `patches/` instead of `third_party/`:
- The vendored fork already has its own upstream-facing `third_party/` package
  for dependency patching and helper tooling.
- Keeping the replacement series in `patches/` avoids mixing those two concerns
  together and removes the double-`third_party` path.

What lives here:
- `0002` through `0016` replacement patch files.

Why it matters:
- This is the auditable artifact set.
- Without these files, the port would only exist as source code, not as a
  checked-in replacement patch series.

### `third_party/rules_go_orchestrion.PATCH_SERIES.json`

Why it changed:
- This file records the structure of the local patch series.

What it does:
- Records the subtree path.
- Records the patch directory.
- Records the base commit.
- Records the series tip commit.
- Maps each patch filename to the exact commit that exports it.

Why it matters:
- It is the source of truth for regenerating and verifying the local patch
  artifacts.

### `tools/dev/`

Changed files:
- `export_rules_go_patch_series.py`
- `verify_rules_go_patch_series.py`

Why they were added:
- The port needed a reproducible export path for the patch files.
- It also needed a mechanical proof that applying the checked-in patch files
  recreates the vendored fork exactly.

Why it matters:
- These scripts turn the checked-in patch files from static blobs into
  reproducible artifacts with a verification loop.

### `third_party/rules_go_orchestrion/`

Changed files:
- `CHANGED_FILES.md`
- `MODULE.bazel`
- `MODULE.bazel.lock`

Why it changed:
- `CHANGED_FILES.md` had to be regenerated because the vendored fork changed.
- `MODULE.bazel` and `MODULE.bazel.lock` changed because the BuildInfo port
  needs `rules_license` in this repository.

Why it matters:
- The internal environment gets some metadata wiring elsewhere.
- This repository has to be self-contained, so the vendored fork needs its own
  dependency wiring.

### `third_party/rules_go_orchestrion/go/private/repositories.bzl`

Why it changed:
- This is the WORKSPACE-mode counterpart to the Bzlmod dependency wiring.

What changed:
- Added `rules_license` so WORKSPACE consumers of the vendored fork can resolve
  the BuildInfo metadata path too.

Why it matters:
- The fork must work in both Bzlmod and WORKSPACE paths.

### `third_party/rules_go_orchestrion/go/private/actions/`

Changed files:
- `binary.bzl`
- `link.bzl`

Why they changed:
- `link.bzl` is where the `0009`, `0013`, and `0015` link-layer behavior lives.
- `binary.bzl` was updated to carry BuildInfo metadata into link emission.

What changed:
- External linker behavior was merged into the existing Orchestrion linker path.
- GoLink `resource_set` support was added.
- BuildInfo input generation was added.

Why it matters:
- This is where the internal behavior had to be merged into code that already
  differed from upstream because of Orchestrion.

### `third_party/rules_go_orchestrion/go/private/rules/`

Changed files:
- `BUILD.bazel`
- `binary.bzl`
- `transition.bzl`

Why they changed:
- `transition.bzl` carries the transition behavior for the `0009` port.
- `binary.bzl` carries the Starlark-side BuildInfo provider wiring for `0013`.

Important local adaptation:
- The initial `0009` port had to be corrected so pure cross builds stay on
  non-cgo platforms.
- That is a fork-correctness fix, not a change in patch-series scope.

Why it matters:
- This is the main rule layer where analysis-time behavior had to stay
  compatible with the Orchestrion fork.

### `third_party/rules_go_orchestrion/go/private/context.bzl`

Why it changed:
- This file carries three internal patch behaviors:
  - `0011` cdeps propagation
  - `0015` `_filter_options` optimization
  - `0016` cached `CgoContextInfo`

Why it matters:
- These changes are analysis-context behavior, not runtime behavior.
- They had to be implemented in the forked context path, not in tests or docs.

### `third_party/rules_go_orchestrion/go/private/aspects/`

Changed files:
- `BUILD.bazel`
- `buildinfo_aspect.bzl`

Why they were added:
- BuildInfo support needs an aspect to traverse Go dependencies and collect
  version metadata.

Why it matters:
- This is the core analysis-time metadata collector for the `0013` port.

### `third_party/rules_go_orchestrion/go/tools/builders/`

Changed files:
- `BUILD.bazel`
- `buildinfo.go`
- `buildinfo_test.go`
- `cgo2.go`
- `importcfg.go`
- `link.go`
- `modinfo.go`

Why they changed:
- `cgo2.go` implements `0008`.
- `buildinfo.go`, `modinfo.go`, `importcfg.go`, and `link.go` implement the
  actual Go-side BuildInfo behavior for `0013`.
- `buildinfo_test.go` proves that logic directly.

Why it matters:
- The Starlark layer alone is not enough.
- The builder code is what actually writes BuildInfo and modinfo into linked
  binaries.

### `third_party/rules_go_orchestrion/go/tools/bzltestutil/`

Changed files:
- `xml.go`
- `testdata/report.xml`
- `testdata/timeout.xml`

Why they changed:
- This is the implementation and golden-data update for `0002`.

Why it matters:
- The patch changes observable XML output, so both the implementation and the
  expected outputs had to move together.

### `third_party/rules_go_orchestrion/proto/`

Changed files:
- `compiler.bzl`
- `def.bzl`
- `private/toolchain.bzl`

Why they changed:
- This is the `0014` compatibility port from protobuf-internal loads to
  `@rules_proto`.

Why it matters:
- The proto compatibility change belongs in the proto rule layer, not in Go
  code or test fixtures.

### `third_party/rules_go_orchestrion/tests/core/buildinfo/`

Why it changed:
- This folder is the local proof harness for `0013`.

What came from the internal patch shape:
- `BUILD.bazel`
- `README.md`
- `external_deps_bin_unix.go`
- `external_deps_bin_windows.go`
- `external_deps_test.go`
- `leaf_lib.go`
- `metadata_bin.go`
- `metadata_test.go`
- `mid_lib.go`
- `top_lib.go`

What is local-only here:
- `x_sys_unix_wrapper.go`
- `x_sys_windows_wrapper.go`
- `srcs_only_bin.go`
- `srcs_only_test.go`

Why those local-only files were added:
- The `x_sys_*` wrappers let this fork attach `package_info(...)` metadata
  cleanly for the external dependency case.
- The `srcs_only_*` files were added after review to prove that BuildInfo is
  still emitted when a binary has no explicit deps or embed targets.

Why it matters:
- BuildInfo is only credible if it is proven through real runtime behavior.

### `third_party/rules_go_orchestrion/tests/core/cgo/`

Why it changed:
- This folder contains the local regression fixture for `0011`.

What is local-only here:
- `embed_chain_leaf.c`
- `embed_chain_leaf.go`
- `embed_chain_leaf.h`
- `embed_chain_leaf_dep.cc`
- `embed_chain_main.go`
- `embed_chain_mid.cc`
- `embed_chain_mid.go`
- `embed_chain_top.cc`
- `embed_chain_top_lib.go`
- plus the `BUILD.bazel` wiring for that fixture

Why these files were added:
- The internal patch changes cdeps propagation logic.
- That logic is easy to claim and easy to get subtly wrong.
- The fixture creates a real multi-step Go/C/C++ embed chain that only works if
  cdeps propagate correctly.

Why it matters:
- This is the proof that the `0011` port works in this fork, not just on paper.

### `third_party/rules_go_orchestrion/tests/core/go_test/`

Changed file:
- `xmlreport_test.go`

Why it changed:
- This is the direct behavior test for `0002`.

Why it matters:
- The JUnit XML change needs a test that asserts the new passing-log behavior
  explicitly.

### `third_party/rules_go_orchestrion/tests/core/starlark/`

Changed files:
- `BUILD.bazel`
- `context_tests.bzl`
- `link_tests.bzl`

Why they changed:
- This is the direct proof layer for helper behavior that is easiest to test in
  Starlark.

What is covered here:
- `_filter_options` behavior from `0015`
- GoLink `resource_set` behavior from `0015`

Why it matters:
- These helpers are important enough to test directly, and Starlark tests keep
  the proof small and targeted.

## Bottom Line

The changed folders are not all doing the same job.

- The `go/private`, `go/tools`, and `proto` folders hold the real product
  changes.
- The `tests/core/*` folders prove those changes in this repository.
- The `third_party/*.patch`, manifest, and export/verify scripts make the
  1:1 replacement series reproducible and reviewable.

That is why the branch contains both source changes and what looks like extra
test/support material. The extra material is there to make the port provable,
not just plausible.
