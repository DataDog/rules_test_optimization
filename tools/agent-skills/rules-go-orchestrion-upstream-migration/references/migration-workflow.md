<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Migration Workflow

Use this workflow to port the vendored Orchestrion-enabled `rules_go` fork to a
new upstream `rules_go` tag or commit.

Replace `NEW_RULES_GO_TAG_OR_COMMIT` with the exact upstream target. Prefer a
commit SHA in metadata even when the user names a tag, and keep the tag field
only when the upstream target is a real tag.

## 1. Capture The Current Baseline

Start from a clean understanding of the current fork:

```bash
git status --short
python3 tools/dev/verify_rules_go_variants.py
python3 tools/dev/diff_rules_go_fork.py --metadata third_party/rules_go_orchestrion_base.METADATA.json
python3 tools/dev/diff_rules_go_fork.py --metadata third_party/rules_go_orchestrion_complete.METADATA.json
```

Generate the current patches into temporary files for review:

```bash
mkdir -p /tmp/rules_go_orchestrion_migration
python3 tools/dev/diff_rules_go_fork.py \
  --metadata third_party/rules_go_orchestrion_base.METADATA.json \
  --patch > /tmp/rules_go_orchestrion_migration/base.patch
python3 tools/dev/diff_rules_go_fork.py \
  --metadata third_party/rules_go_orchestrion_complete.METADATA.json \
  --patch > /tmp/rules_go_orchestrion_migration/complete.patch
```

Review the checked-in reports before editing:

- `third_party/rules_go_orchestrion_base.CHANGED_FILES.md`
- `third_party/rules_go_orchestrion_complete.CHANGED_FILES.md`
- `third_party/rules_go_orchestrion_variants.json`

## 2. Materialize The New Upstream Tree

Download or check out the exact new upstream `rules_go` tree outside the
vendored directories first. Keep this copy as the comparison source while you
reapply the Datadog delta.

The repository's diff helper downloads from upstream metadata, so do not rely
on hand-copied upstream files as proof. The final metadata and reports must be
generated from the exact upstream commit recorded in metadata.

## 3. Rebuild `base`

Recreate `third_party/rules_go_orchestrion_base` from the new upstream tree,
then reapply the generic Orchestrion integration.

The base variant owns:

- Orchestrion extension and WORKSPACE entrypoints
- Orchestrion build repository and bootstrap cache behavior
- builder action changes for compile, archive, stdlib, link, nogo, and import
  configuration
- synthetic `testmain` behavior
- offline module proxy inputs
- `dd_trace_go_versions.json` validation
- tool-version validation
- generic regression tests that prove Orchestrion behavior

Use the current `base.patch` as a map, not as an unquestioned patch. If the new
upstream moved or rewrote a surface, port the behavior to the new upstream
shape instead of forcing the old file layout.

After the base tree is coherent, update
`third_party/rules_go_orchestrion_base.METADATA.json` to the new upstream
commit and tag.

## 4. Rebuild `complete`

Start `complete` from the migrated `base` behavior, then reapply only the
declared compatibility layer.

Use `third_party/rules_go_orchestrion_variants.json` as the allowlist for
intentional `complete`-only differences. If a new `complete`-only path is
required, add it to the allowlist with a precise reason. If an old allowlisted
path no longer differs, remove it from the allowlist.

Update `third_party/rules_go_orchestrion_complete.METADATA.json` to the same
upstream commit and tag as `base`.

## 5. Regenerate Reports

Regenerate both upstream delta reports:

```bash
python3 tools/dev/diff_rules_go_fork.py \
  --metadata third_party/rules_go_orchestrion_base.METADATA.json \
  --write-report
python3 tools/dev/diff_rules_go_fork.py \
  --metadata third_party/rules_go_orchestrion_complete.METADATA.json \
  --write-report
python3 tools/dev/verify_rules_go_variants.py
```

Read the regenerated reports. The changed-path counts may change, but every new
or removed path should be explainable by the upstream migration.

## 6. Validate Behavior

Run the required lanes from [validation-checklist.md](validation-checklist.md).
For Orchestrion migrations, build success alone is not enough. Runtime
validation must prove that instrumented tests start CI Visibility and write
payload files.

If validation fails, use [troubleshooting.md](troubleshooting.md). Do not hide
failures by weakening tests or deleting variant differences from metadata.

## 7. Final Report

The final report for a migration PR must include:

- old upstream tag or commit
- new upstream tag or commit
- base changed-path count
- complete changed-path count
- whether `verify_rules_go_variants.py` passed
- smoke and integration lanes run
- lanes skipped, with reasons
- behavior changes caused by upstream, if any
- remaining blockers or reviewer decisions
