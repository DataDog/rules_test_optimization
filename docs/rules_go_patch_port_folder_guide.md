# `rules_go` Patch Split Folder Guide

This note explains the current `rules_go` split in plain maintainer terms.

The repository no longer keeps one mixed vendored tree that tries to represent:

- the clean Orchestrion-enabled base fork
- the optional `dd-source` patch stack
- extra local-only regression fixtures

Those concerns now live in separate places so the resulting model is easier to
verify and easier to maintain.

## The Three Layers

### `third_party/rules_go_orchestrion/`

This is the clean Orchestrion-enabled base fork.

What belongs here:

- the vendored `rules_go` fork used by repo-root dev wiring
- the Orchestrion-specific base behavior that is part of this fork
- no optional consumer patch artifacts
- no maintainer-only local proof fixtures

Why it matters:

- the repository root and `modules/go/MODULE.bazel` both point here directly
- `verify_rules_go_patch_series.py --bundle none` proves this subtree matches
  the manifest's clean-base ref; it is `HEAD` so this proof still works after a
  squash merge
- `diff_rules_go_fork.py` now reports the clean-base delta against upstream,
  not a mixed base-plus-patches tree

### `third_party/rules_go_patches/`

This is the canonical optional external patch bundle.

What belongs here:

- the checked-in 1:1 replacement patch files
- the canonical patch ordering and filenames
- the explicit `BUILD.bazel` used for public file labels

What does not belong here:

- maintainer-only local regression fixtures
- generated exact-tree manifests
- consumer-visible behavior that only exists in local temp trees

Why it matters:

- this is the artifact set `export_rules_go_patch_bundle.py` copies into
  consumer-owned workspaces
- this is the bundle `verify_rules_go_patch_series.py --bundle dd_source_full`
  applies on top of the clean base
- consumers must export their own copy of this directory; they must not point at
  the checked-in copy through
  `@datadog-rules-test-optimization//third_party/rules_go_patches`

### `tools/tests/rules_go_patch_regressions/`

This is the maintainer-only proof overlay.

Current contents:

- `tests/core/cgo/asm_cflags/**`
- `tests/core/go_proto_library/BUILD.bazel`

Why these files moved here:

- they strengthen local regression coverage
- they are not part of the canonical consumer patch bundle contract
- forcing them back into the patch bundle would blur the line between
  consumer-visible behavior and maintainer-only proof material

Why it matters:

- smoke and extended vendored-fork regression runs still keep this extra proof
- the exact-tree manifest does not pretend these files are part of the canonical
  consumer-applied patch result

## The Contract Files

### `third_party/rules_go_patch_series.json`

This manifest is the source of truth for the split.

It records:

- the clean base subtree path
- the canonical patch directory
- the clean-base commit
- the exact-tree manifest path
- the proof-overlay directory
- the named bundles
- the per-patch commit, order, prerequisites, and metadata

This replaced the old `third_party/rules_go_orchestrion.PATCH_SERIES.json`.

### `third_party/rules_go_patched_tree_manifest.json`

This is the exact-tree reference for the canonical full patched fork.

It records only:

- regular files with relative path, executable bit, and SHA-256
- symlinks with relative path and target

It does not record directories.

It intentionally excludes:

- the relocated patch artifacts
- the maintainer-only proof overlay files

Why it matters:

- `verify_rules_go_patch_series.py --bundle dd_source_full` proves that
  `base + dd_source_full` reproduces this manifest exactly

## The Tooling Layout

### `tools/dev/export_rules_go_patch_series.py`

Regenerates the checked-in canonical patch files from the manifest’s commit
mapping and rewrites `third_party/rules_go_patches/BUILD.bazel`.

Use this when the canonical patch series itself changes.

### `tools/dev/export_rules_go_patch_bundle.py`

Exports a selected bundle or subset into a consumer-owned
`third_party/rules_go_patches/` directory.

It writes:

- a public `BUILD.bazel`
- the selected patch files
- the canonical ordered patch labels on stdout

Use this when validating real consumer patch application.

### `tools/dev/materialize_rules_go_patch_tree.py`

Creates a standalone temp tree containing:

- the clean base alone
- or the clean base plus a named bundle
- or the clean base plus an explicit subset

It can optionally apply the proof overlay on top of that temp tree.

Use this when running vendored-fork regression targets outside the checked-in
vendored subtree.

### `tools/dev/verify_rules_go_patch_series.py`

Verifies:

- clean base identity with `--bundle none`
- canonical full bundle exact-tree reproduction with `--bundle dd_source_full`
- subset ordering, prerequisites, and clean `patch -p1` application with
  repeated `--patch`

The old `LOCAL_VALIDATION_ONLY_PATHS` escape hatch is gone.

## Validation Surfaces

### Exact-Tree Proof

The exact-tree proof answers:

“Does the canonical patch bundle still reconstruct the expected full patched
fork?”

That proof is:

- `python3 tools/dev/verify_rules_go_patch_series.py --bundle dd_source_full`

### Maintainer Regression Proof

The maintainer regression proof answers:

“Do the extra local-only proof fixtures still behave correctly on top of the
canonical full patch bundle?”

That proof lives in:

- `tools/dev/run_rules_go_patch_smoke.sh`
- `tools/dev/run_rules_go_patch_extended.sh`

Both scripts materialize a temp tree from the clean base, apply
`dd_source_full`, overlay the maintainer-only regressions, and run the vendored
fork test targets there.

### Consumer Repro Proof

The consumer proof answers:

“Does the clean base work for consumers, and does the optional full patch bundle
also work when applied through real consumer mechanisms?”

That proof lives in:

- `tools/tests/integration/run_workspace_go_integration.sh`
- `tools/tests/integration/run_bzlmod_go_patch_integration.sh`

Those scripts are the canonical generic consumer repro lanes.

## Future Placement Rule

When deciding where a future file belongs, use this rule:

- if a consumer must receive it from the optional patch flow, it belongs in
  `third_party/rules_go_patches/`
- if it only improves maintainer-local proof, it belongs in
  `tools/tests/rules_go_patch_regressions/`

Do not let the proof overlay become a back door for consumer-visible behavior.
