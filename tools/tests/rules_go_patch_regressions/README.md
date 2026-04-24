# rules_go Patch Regression Overlay

This directory contains maintainer-only regression fixtures for the vendored
`rules_go` patch workflow.

These files are intentionally separate from the canonical external patch bundle:

- they are not exported to consumers
- they are not part of `third_party/rules_go_patches/`
- they are not part of the exact-tree proof in
  `third_party/rules_go_patched_tree_manifest.json`

The shell harnesses in `tools/dev/run_rules_go_patch_smoke.sh` and
`tools/dev/run_rules_go_patch_extended.sh` materialize `base + all_patches`
first, then copy this overlay into the temporary tree before running the local
maintainer regression targets.
