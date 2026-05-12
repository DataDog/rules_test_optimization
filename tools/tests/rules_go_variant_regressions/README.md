<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# rules_go Variant Regression Overlay

This directory contains maintainer-only regression fixtures for the vendored
`rules_go` variant workflow.

These files are intentionally separate from the published variant trees:

- they are not exported to consumers
- they are not part of `third_party/rules_go_orchestrion_base`
- they are not part of `third_party/rules_go_orchestrion_complete`

The shell harnesses in `tools/dev/run_rules_go_variant_smoke.sh` and
`tools/dev/run_rules_go_variant_extended.sh` copy the selected variant first,
then copy this overlay into the temporary tree before running the local
maintainer-only regression targets.
