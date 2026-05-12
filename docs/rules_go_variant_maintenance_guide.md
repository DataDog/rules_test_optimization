<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# rules_go Orchestrion Variant Folder Guide

This guide describes the maintained folder layout for the vendored
Orchestrion-enabled `rules_go` variants.

## Folders

### `third_party/rules_go_orchestrion_base/`

The default public variant. It contains upstream `rules_go` v0.60.0 plus the
generic Orchestrion support maintained by this repository. Bugs in our
integration are fixed here directly.

### `third_party/rules_go_orchestrion_complete/`

The extended public variant. It contains the base behavior plus declared
historical monorepo compatibility differences. Do not add differences here
silently; every difference must be listed in
`third_party/rules_go_orchestrion_variants.json`.

### `tools/tests/rules_go_variant_regressions/`

Maintainer-only proof fixtures copied into temporary variant trees by the smoke
and extended scripts. These files are not part of either published consumer
variant.

## Metadata

- `third_party/rules_go_orchestrion_base.METADATA.json`
- `third_party/rules_go_orchestrion_base.CHANGED_FILES.md`
- `third_party/rules_go_orchestrion_complete.METADATA.json`
- `third_party/rules_go_orchestrion_complete.CHANGED_FILES.md`
- `third_party/rules_go_orchestrion_variants.json`

Use `tools/dev/diff_rules_go_fork.py` to regenerate each changed-files report.
Use `tools/dev/verify_rules_go_variants.py` to verify that base and complete
differ only by declared paths.

## Consumer Contract

A consumer fetches one complete variant tree. Example:

```bzl
http_archive(
    name = "io_bazel_rules_go",
    urls = ["https://example.invalid/rules_test_optimization/<commit>.tar.gz"],
    sha256 = "<sha256>",
    strip_prefix = "rules_test_optimization-<commit>/third_party/rules_go_orchestrion_base",
)
```

For the extended monorepo variant, change only the final path component to
`rules_go_orchestrion_complete`.

Consumers should not apply additional Datadog-managed Bazel patch files for
this integration.
