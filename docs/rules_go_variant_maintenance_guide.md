<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# rules_go Orchestrion Support Folder Guide

This guide describes the maintained folder layout for the vendored
Orchestrion-enabled `rules_go` support lines and public consumer patch profiles.

## Folders

### `third_party/rgo/v0_60_0/base/`

The default public base variant for the current default upstream. It contains
upstream `rules_go` v0.60.0 plus the generic Orchestrion support maintained by
this repository. Bugs in our integration are fixed here directly.

### `third_party/rules_go_orchestrion/`

The registry-driven support area for multi-version maintenance:

- `registry.json` selects supported upstream lines and base tree paths.
- `patches/<upstream>/` stores the maintainer patch series for rebasing.
- `profiles/<profile>.json` declares public sparse-patch profiles for
  consumers that need to apply this repository's `rules_go` changes on top of
  a repository-owned patch stack.
- `versions/<upstream>/base/` stores materialized base trees for non-default
  upstream support lines.

The default `rules_go_upstream` is currently `v0_60_0`, which preserves the
existing `third_party/rgo/v0_60_0/base` path. When multiple upstream
`rules_go` versions are supported, use `rules_go_upstream` to choose the upstream
support line. Omitting `rules_go_upstream` preserves the repository default.

### `tools/tests/rules_go_variant_regressions/`

Maintainer-only proof fixtures copied into temporary variant trees by the smoke
and extended scripts. These files are not part of either published consumer
variant.

## Metadata

- `third_party/rgo/v0_60_0/base.METADATA.json`
- `third_party/rgo/v0_60_0/base.CHANGED_FILES.md`
- `third_party/rules_go_orchestrion/registry.json`
- `third_party/rules_go_orchestrion/profiles/<profile>.json`
- `third_party/rules_go_orchestrion/patches/<upstream>/`

Use `tools/dev/diff_rules_go_fork.py` to regenerate each changed-files report.
Use `tools/dev/materialize_rules_go_fork.py check --all` to verify that patch
series recreate the checked-in trees. Use
`tools/dev/verify_rules_go_profiles.py --public-denylist tools/dev/private_leak_public_denylist.txt`
to verify that public consumer patch profiles round-trip against clean upstream
`rules_go` without leaking private-only strings.

## Consumer Contract

A consumer fetches the complete base tree. Example:

```bzl
http_archive(
    name = "io_bazel_rules_go",
    urls = ["https://example.invalid/rules_test_optimization/<commit>.tar.gz"],
    sha256 = "<sha256>",
    strip_prefix = "rules_test_optimization-<commit>/third_party/rgo/v0_60_0/base",
)
```

For non-default support lines, use the registry-resolved base tree path, for
example `third_party/rgo/v0_61_1/base`.

Consumers should not apply additional Datadog-managed Bazel patch files when
they consume a complete base tree. Repositories that already own their
`rules_go` patch stack should instead use a generated public consumer patch
profile as a local rebase or merge input, then verify the regenerated private
patch in their private patch order.
