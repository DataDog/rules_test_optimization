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
python3 tools/dev/generate_rules_go_fork_maps.py --check
python3 tools/dev/materialize_rules_go_fork.py check --all
python3 tools/dev/verify_rules_go_profiles.py --public-denylist tools/dev/private_leak_public_denylist.txt
python3 tools/dev/diff_rules_go_fork.py --all
```

Review the current patch series and checked-in reports before editing:

- `third_party/rules_go_orchestrion/registry.json`
- `third_party/rules_go_orchestrion/patches/<current-upstream>/`
- `third_party/rules_go_orchestrion/profiles/workspace_runtime.json`
- the current upstream's `*.METADATA.json`
- the current upstream's `*.CHANGED_FILES.md`

## 2. Materialize The New Upstream Tree

Add the new upstream to `third_party/rules_go_orchestrion/registry.json`, then
create metadata for that upstream. Download or check out the exact new upstream
`rules_go` tree outside the vendored directories
only when you need a manual comparison source while rebasing the Datadog delta.

The repository's diff helper downloads from upstream metadata, so do not rely
on hand-copied upstream files as proof. The final metadata and reports must be
generated from the exact upstream commit recorded in metadata.

## 3. Rebuild `base`

Create the target upstream's `base` patch series and materialized tree. For the
default upstream this may still be `third_party/rgo/v0_60_0/base`; for
additional upstreams it is the registry-selected
`third_party/rgo/<upstream>/base` tree.

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

Use the current base patch series as a map, not as an unquestioned patch. If
the new upstream moved or rewrote a surface, port the behavior to the new
upstream shape instead of forcing the old file layout.

After the base tree is coherent, regenerate the base patch from that tree so
`materialize_rules_go_fork.py check --upstream <upstream> --variant base`
recreates it exactly.

## 4. Verify Consumer Patch Profiles

Run the public profile generator against the migrated base tree. The generated
patch must apply to clean upstream `rules_go`, preserve included file modes and
symlinks, exclude profile-excluded files, and pass the public private-leak
denylist. Do not encode private repository names, paths, services, or target
labels in public profiles.

## 5. Regenerate Reports

Regenerate both upstream delta reports:

```bash
python3 tools/dev/generate_rules_go_fork_maps.py
python3 tools/dev/diff_rules_go_fork.py --upstream <upstream> --variant base --write-report
python3 tools/dev/materialize_rules_go_fork.py check --upstream <upstream> --variant base
python3 tools/dev/verify_rules_go_profiles.py --upstream <upstream> --public-denylist tools/dev/private_leak_public_denylist.txt
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
- whether `verify_rules_go_profiles.py` passed
- smoke and integration lanes run
- lanes skipped, with reasons
- behavior changes caused by upstream, if any
- remaining blockers or reviewer decisions
