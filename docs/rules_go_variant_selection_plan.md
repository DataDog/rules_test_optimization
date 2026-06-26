<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# rules_go Orchestrion Support Selection

This repository exposes one supported public `rules_go` tree variant, `base`.
Consumers that already own a private `rules_go` patch stack can also consume a
generated sparse patch profile as an input to a local rebase or merge inside
their own repository.

## Published Variant

- `base`: upstream `rules_go` plus the generic Orchestrion integration and
  correctness fixes maintained by this repository.

The base variant is a complete repository root. A consumer should point
`rules_go`, `io_bazel_rules_go`, or its equivalent repository name directly at
this subtree when it does not already maintain its own `rules_go` patch stack.

The default `rules_go_upstream` is currently `v0_60_0`, which preserves the
existing `third_party/rgo/v0_60_0/base` path. When multiple upstream
`rules_go` versions are supported, use `rules_go_upstream` to choose the upstream
support line. Omitting `rules_go_upstream` preserves the repository default.

## Selection Rule

- Use `base` for normal WORKSPACE and Bzlmod consumers.
- Use a generated consumer patch profile only when the consuming repository
  already applies its own private `rules_go` patch stack and needs to preserve
  that ownership model.

Public consumer patch profiles live under
`third_party/rules_go_orchestrion/profiles/` and are verified by:

```bash
python3 tools/dev/verify_rules_go_profiles.py --public-denylist tools/dev/private_leak_public_denylist.txt
```

## Maintainer Workflow

Maintainers track each supported upstream version with both:

- patch series under `third_party/rules_go_orchestrion/patches/<upstream>/`
- materialized base trees under the registry-selected `tree_path`

The patch series is the maintainer source for rebasing. The materialized tree is
the consumer artifact. CI verifies that they match.

When the generic Orchestrion integration changes, update the base tree for the
target upstream, regenerate the maintainer patch series, and verify that the
consumer patch profiles still round-trip against clean upstream `rules_go`.

After any variant change, regenerate the upstream delta reports:

```bash
python3 tools/dev/diff_rules_go_fork.py --all --write-report
python3 tools/dev/materialize_rules_go_fork.py check --all
python3 tools/dev/verify_rules_go_profiles.py --public-denylist tools/dev/private_leak_public_denylist.txt
```

Run the smoke lane before publishing:

```bash
RULES_GO_UPSTREAM=v0_60_0 RULES_GO_VARIANT=base tools/dev/run_rules_go_variant_smoke.sh
```

When adding a new upstream, run the same smoke commands with
`RULES_GO_UPSTREAM=<new_upstream>`.
