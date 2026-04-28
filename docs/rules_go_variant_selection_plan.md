# rules_go Orchestrion Variant Selection

This repository no longer exposes a public consumer flow based on applying
separate Bazel patches. Consumers choose one complete `rules_go` tree instead.

## Published Variants

- `third_party/rules_go_orchestrion_base`: `rules_go` v0.60.0 plus the generic
  Orchestrion integration and correctness fixes maintained by this repository.
- `third_party/rules_go_orchestrion_complete`: the base variant plus declared
  historical monorepo compatibility differences.

Both variants are complete repository roots. A consumer should point
`rules_go`, `io_bazel_rules_go`, or its equivalent repository name directly at
one of these subtrees. Consumers should not configure `patches`, `patch_tool`,
`patch_args`, or a consumer-owned patch directory for this integration.

## Selection Rule

- Use `base` for normal WORKSPACE and Bzlmod consumers.
- Use `complete` only when a large monorepo needs the declared extended
  compatibility layer.

The current declared difference is tracked in
`third_party/rules_go_orchestrion_variants.json` and verified by:

```bash
python3 tools/dev/verify_rules_go_variants.py
```

## Maintainer Workflow

When the generic Orchestrion integration changes, modify
`third_party/rules_go_orchestrion_base` directly and then copy or intentionally
reapply the same correctness change to `third_party/rules_go_orchestrion_complete`
if the file exists there.

When a change is specific to the extended compatibility layer, modify only
`third_party/rules_go_orchestrion_complete` and add the changed path to
`third_party/rules_go_orchestrion_variants.json` with a precise reason.

After any variant change, regenerate the upstream delta reports:

```bash
python3 tools/dev/diff_rules_go_fork.py --metadata third_party/rules_go_orchestrion_base.METADATA.json --write-report
python3 tools/dev/diff_rules_go_fork.py --metadata third_party/rules_go_orchestrion_complete.METADATA.json --write-report
python3 tools/dev/verify_rules_go_variants.py
```

Run both variant smoke lanes before publishing:

```bash
RULES_GO_VARIANT=base tools/dev/run_rules_go_variant_smoke.sh
RULES_GO_VARIANT=complete tools/dev/run_rules_go_variant_smoke.sh
```
