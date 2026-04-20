# Clean Orchestrion Base With Optional External `rules_go` Patch Bundles

## Summary

This work splits the current vendored `rules_go` state into three explicit
layers:

- `third_party/rules_go_orchestrion/`:
  the clean Orchestrion-enabled base fork
- `third_party/rules_go_patches/`:
  the canonical optional external `dd-source` patch series
- `tools/tests/rules_go_patch_regressions/`:
  maintainer-only proof fixtures that strengthen local regression coverage but
  are not exported to consumers

The goal is to make the current fork easier to reason about and prove
mechanically:

- the checked-in vendored subtree becomes a real clean base
- the optional patch bundle becomes a real consumer-visible artifact
- the extra local-only regression fixtures stop pretending to be part of the
  consumer bundle

Public Starlark APIs do not change in this work. `dd_topt_go_test`,
`go_orchestrion_tool_repo(...)`, and the existing bootstrap and sync entrypoints
keep their current public contracts.

## Contract And File Placement

### Canonical Manifest

The source of truth for the split is `third_party/rules_go_patch_series.json`.
It records:

- the clean base subtree path
- the canonical patch directory
- the clean-base commit
- the exact-tree manifest path
- the proof-overlay directory
- the named bundles
- the per-patch filename, commit, ordering, summary, prerequisites, and
  `touches_module_files` flag

The current nine patch filenames and their ordering stay unchanged.

### Exact-Tree Manifest

`third_party/rules_go_patched_tree_manifest.json` records the canonical
full-patched fork that consumers should get when they apply
`dd_source_full`.

It records only:

- regular files: relative path, `kind = "file"`, executable bit, and SHA-256
- symlinks: relative path, `kind = "symlink"`, and link target

Directories are not recorded. They are derived from file and symlink paths.

The manifest intentionally excludes:

- the old vendored `patches/**` artifact directory
- `tests/core/cgo/asm_cflags/**`
- `tests/core/go_proto_library/BUILD.bazel`

Those last two surfaces now live in the maintainer-only proof overlay.

### File Placement Rules

Future files must follow this rule:

- if a consumer must get the file or behavior by applying the external patch
  bundle, it belongs in `third_party/rules_go_patches/` and in the exact-tree
  proof
- if the file only strengthens maintainer-local regression coverage and is not
  required by the consumer patch flow, it belongs in
  `tools/tests/rules_go_patch_regressions/`

The proof overlay must not carry consumer-visible behavior.

## Repository Layout Changes

### Clean Base Fork

`third_party/rules_go_orchestrion/` is reset to the subtree recorded by
`base_commit` in the manifest.

After this reset:

- no `dd-source` patch artifacts remain under the vendored subtree
- no maintainer-only proof fixtures remain under the vendored subtree
- the checked-in subtree represents the clean Orchestrion-enabled base fork

The root `MODULE.bazel` and `modules/go/MODULE.bazel` keep pointing at this
clean base through `local_path_override(...)`.

### Canonical Patch Bundle

The checked-in patch files move from the vendored subtree into
`third_party/rules_go_patches/`.

This directory is:

- the canonical maintainer-owned patch source
- the place `export_rules_go_patch_series.py` rewrites from the manifest
- the source material `export_rules_go_patch_bundle.py` copies into
  consumer-owned workspaces

Consumers must not reference
`@datadog-rules-test-optimization//third_party/rules_go_patches` directly.
They must use their own exported copy.

### Proof Overlay

The local-only regression fixtures move to
`tools/tests/rules_go_patch_regressions/`, using the same relative paths they
had under the vendored subtree.

Current overlay contents:

- `tests/core/cgo/asm_cflags/**`
- `tests/core/go_proto_library/BUILD.bazel`

Overlay semantics are fixed:

- copy by relative path into the materialized temp tree
- create parent directories as needed
- replace files or symlinks at the same path
- preserve executable bits and symlink targets
- never delete paths

If a future regression needs deletion semantics, that logic must move into the
canonical patch bundle or into an explicit pre-test cleanup step in the
maintainer script.

## Tooling Contract

### Shared Helper

`tools/dev/rules_go_patch_series_lib.py` owns the shared logic for:

- manifest loading and validation
- canonical bundle expansion
- prerequisite checking
- subtree extraction
- patch application
- tree normalization
- tree hashing and comparison
- optional proof-overlay application

### Export Tools

`tools/dev/export_rules_go_patch_series.py` rewrites the checked-in canonical
patch directory from the manifest’s per-patch commit list.

`tools/dev/export_rules_go_patch_bundle.py` exports a selected bundle or patch
subset into a consumer-owned `third_party/rules_go_patches/` directory and
writes an explicit `BUILD.bazel` with:

- `package(default_visibility = ["//visibility:public"])`
- one `exports_files([...])` entry for the selected patch filenames

It prints the canonical ordered patch labels in this exact form:

- `//third_party/rules_go_patches:<filename>.patch`

It must reject:

- unknown patches
- missing prerequisites
- unmanaged destination contents unless `--force` is set

It must never export the maintainer-only proof overlay.

### Verification Tool

`tools/dev/verify_rules_go_patch_series.py` supports four modes:

- `--bundle none`
  verifies that the checked-in clean base subtree matches the archived
  `base_commit` byte-for-byte
- `--bundle dd_source_full`
  materializes `base + dd_source_full`, normalizes it, and compares it to
  `third_party/rules_go_patched_tree_manifest.json`
- repeated `--patch <filename>`
  verifies canonical ordering, prerequisites, and clean `patch -p1`
  application for a subset
- `--write-full-tree-manifest`
  regenerates the exact-tree manifest for the canonical full bundle

`LOCAL_VALIDATION_ONLY_PATHS` is removed completely. The old excluded files
`go/private/context.bzl` and `tests/core/starlark/context_tests.bzl` are now
required outputs of `dd_source_full`.

### Temp-Tree Materialization

`tools/dev/materialize_rules_go_patch_tree.py` materializes:

- the clean base alone
- the clean base plus a named bundle
- the clean base plus an explicit patch subset

It can also apply the maintainer-only proof overlay when requested.

## Consumer Model

### Repository-Internal Wiring

The repository itself stays base-only:

- root `MODULE.bazel` keeps
  `local_path_override(module_name = "rules_go", path = "third_party/rules_go_orchestrion")`
- `modules/go/MODULE.bazel` keeps the matching base-only override

Optional patches are never part of the repository’s own default wiring.

Bootstrap also stays base-only. The bootstrap helper does not gain a
patch-selection flag in this change.

### WORKSPACE Consumers

The supported patched consumer model is:

- fetch the clean `third_party/rules_go_orchestrion` subtree as
  `@io_bazel_rules_go`
- export the patch bundle into a consumer-owned
  `third_party/rules_go_patches/`
- apply those patches via `http_archive(..., patch_tool = "patch",
  patch_args = ["-p1"], patches = [...])`

### Bzlmod Consumers

The supported patched consumer models are:

- `git_override(...)` with `patches = [...]` and `patch_strip = 1`
- `archive_override(...)` with `patches = [...]` and `patch_strip = 1`

The documented and tool-generated destination for Bzlmod patch files is always
`third_party/rules_go_patches/` in the root module source tree.

## Validation Model

### Exact-Tree Proof

The exact-tree proof is mandatory:

- `base + dd_source_full` must reproduce
  `third_party/rules_go_patched_tree_manifest.json`

This is the mechanical proof that the canonical patch bundle still describes the
expected full patched fork.

### Maintainer Overlay Proof

The maintainer overlay proof is also mandatory, but separate from the exact-tree
proof.

- `tools/dev/run_rules_go_patch_smoke.sh`
- `tools/dev/run_rules_go_patch_extended.sh`

Both scripts:

1. materialize `base + dd_source_full` in a temp tree
2. apply the maintainer-only proof overlay
3. run vendored-fork regression targets from that temp tree

A failure that reproduces only here is a maintainer regression, not a generic
consumer patch-layer defect.

### Generic Consumer Proof

The generic consumer proof uses only two named public-consumer lanes:

- `tools/tests/integration/run_workspace_go_integration.sh`
- `tools/tests/integration/run_bzlmod_go_patch_integration.sh`

Each supports:

- base-only mode
- `RULES_GO_PATCH_BUNDLE=dd_source_full`

These are the only canonical generic patch-layer repro lanes. If a bug is
described as a generic consumer defect, it must reproduce in at least one of
them.

### Cross-Repo Validation

`../rules_test_optimization_tests` remains the sibling base-only consumer check
in this change.

During local validation:

- enable the documented `local_path_override(...)` entries there for this repo
  and any affected companion modules
- if the change touches the vendored fork or Go bootstrap/orchestrion wiring,
  also add a temporary local `rules_go` override pointing back to this
  checkout’s `third_party/rules_go_orchestrion`
- keep those sibling-repo edits validation-only; do not commit them

Permanent patched fixtures in the sibling repo are intentionally deferred to
follow-up work.

## Documentation Changes

This work updates:

- `README.md`
- `CONTRIBUTING.md`
- `docs/Installation_Reference.md`
- `docs/rules_go_patch_port_folder_guide.md`

It also adds a superseded note to:

- `docs/internal_monorepo_go_rollout_plan.md`

And it audits the deeper maintainer docs that refer to vendored-fork internals
so they either describe the clean-base model correctly or are marked
historical.

## Non-Blocking Follow-up Work

This change intentionally does not add permanent patched fixtures to
`../rules_test_optimization_tests`, because the repo-local WORKSPACE and Bzlmod
integration harnesses already provide the required patched-consumer proof.

Planned follow-up:

- add `../rules_test_optimization_tests/fixtures/workspace-go-patched/`
- add `../rules_test_optimization_tests/fixtures/bzlmod-go-patched/`
- check in exported `third_party/rules_go_patches/` fixtures there
- add a sibling-repo refresh script that re-exports those fixtures from this
  repository’s canonical bundle
- document pinned fixture refresh and local unpublished validation in the
  sibling repo’s `README.md`

## Acceptance

Done means all of these pass:

- `./bazelw test //...`
- `python3 tools/dev/verify_rules_go_patch_series.py --bundle none`
- `python3 tools/dev/verify_rules_go_patch_series.py --bundle dd_source_full`
- `./tools/dev/run_rules_go_patch_smoke.sh`
- `./tools/dev/run_rules_go_patch_extended.sh`
- `./tools/tests/integration/run_workspace_go_integration.sh`
- `RULES_GO_PATCH_BUNDLE=dd_source_full ./tools/tests/integration/run_workspace_go_integration.sh`
- `./tools/tests/integration/run_bzlmod_go_patch_integration.sh`
- `RULES_GO_PATCH_BUNDLE=dd_source_full ./tools/tests/integration/run_bzlmod_go_patch_integration.sh`
- `cd ../rules_test_optimization_tests && ./runtests && ./runtests-hermetic`
- `cd ../rules_test_optimization_tests/fixtures/workspace-go && ./runtests && ./runtests-hermetic`

## Maintainer Refresh Order

For any intentional canonical full-bundle change:

1. update the vendored fork and the patch-bearing commits
2. re-export `third_party/rules_go_patches/`
3. regenerate `third_party/rules_go_patched_tree_manifest.json`
4. rerun verifier, smoke, extended, and consumer integration lanes
5. regenerate `third_party/rules_go_orchestrion.METADATA.json` and
   `third_party/rules_go_orchestrion.CHANGED_FILES.md`
6. refresh docs that describe the fork split and validation model
