<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Troubleshooting Upstream Migrations

Use this reference when a `rules_go` upstream migration fails validation or the
new upstream shape no longer matches the existing Orchestrion delta cleanly.

## Patch Does Not Apply Cleanly

Symptoms:

- the current `base.patch` fails on the new upstream tree
- upstream moved or rewrote one of the sensitive surfaces
- conflicts appear in compile, stdlib, link, or transition files

Checks:

- Compare old upstream, old `base`, new upstream, and the partial migrated tree.
- Identify the behavior being carried, not only the line-level patch.
- Read the new upstream implementation before deciding where to insert the
  Orchestrion behavior.
- Re-run the changed-files diff after each coherent chunk.

Do not force old file structure into the new upstream tree. Port the behavior
to the new upstream design.

## Variant Verification Fails

Symptoms:

- `python3 tools/dev/verify_rules_go_variants.py` reports unexpected
  differences
- declared differences are no longer present

Checks:

- If the difference is generic Orchestrion behavior, copy or reapply it to both
  `base` and `complete`.
- If the difference is compatibility-only behavior, keep it only in `complete`
  and add or update the entry in
  `third_party/rules_go_orchestrion_variants.json`.
- If an allowlisted path no longer differs, remove it from the allowlist.
- Re-run the verifier after every metadata edit.

Do not remove verifier failures by deleting behavior from one variant without
understanding which variant owns it.

## Changed-File Counts Look Wrong

Symptoms:

- regenerated `*.CHANGED_FILES.md` counts are much larger than expected
- reports list unrelated upstream files
- reports still show the old upstream tag or commit

Checks:

- Verify both `*.METADATA.json` files point at the new upstream commit.
- Confirm the vendored tree was rebuilt from the same upstream commit recorded
  in metadata.
- Check for generated files, local caches, or editor artifacts accidentally
  copied into the vendored tree.
- Use `python3 tools/dev/diff_rules_go_fork.py --list` to inspect path classes.

Do not hand-edit the report to make counts look right.

## Build Passes But Runtime Instrumentation Is Missing

Symptoms:

- Bazel tests pass
- CI Visibility does not start
- no payload files are written
- tracer startup logs disappear

Checks:

- Inspect stdlib weaving behavior and archive persistence.
- Verify Orchestrion `toolexec` is present in compile and stdlib actions.
- Verify the offline module proxy is available as an action input.
- Verify `dd_trace_go_versions.json` is present and read by builder actions.
- Run the consumer integration harnesses, not only vendored `rules_go` tests.

Build success alone is not proof for stdlib or runtime weaving changes.

## Module Proxy Or Network Failures

Symptoms:

- hermetic integration fails
- `go list` or Orchestrion tries to fetch dependencies from the network
- structural `aquery` checks fail

Checks:

- Verify `go/tools/builders/module_proxy.go` was ported correctly.
- Verify compile actions include `orchestrion_module_proxy_files`.
- Verify the root marker is declared as an action input.
- Run the Bzlmod and WORKSPACE integration harnesses in hermetic mode.

Do not solve hermetic failures by allowing network in the test sandbox.

## Tool Version Or Tracer Version Failures

Symptoms:

- builder actions reject the Orchestrion tool version
- runtime uses an unexpected Datadog tracer version
- `dd_trace_go_versions.json` is missing or stale

Checks:

- Verify the Orchestrion extension writes the tool version file.
- Verify builder actions receive the tool version file and tracer-version file.
- Verify the target Go module can resolve the configured Datadog tracer module
  versions.
- Keep tool bootstrap module dependencies separate from target runtime tracer
  resolution.

Do not restore broad tool-side `go.mod` rewriting unless there is a deliberate
design decision to change the current model.

## Local Results Differ From CI

Symptoms:

- local macOS behavior diverges from Linux CI
- stale caches affect Orchestrion or Go module behavior
- nested Bazel invocations behave differently across hosts

Checks:

- Run `./bazelw shutdown`.
- Clear only relevant Orchestrion caches when local state is suspect.
- Match CI's Bazel version with `USE_BAZEL_VERSION`.
- Check global Git URL rewrites and private Go proxy settings.
- Reproduce from a fresh worktree when long-lived Bazel state is suspicious.

Treat environment-only failures as blockers only after a clean local retry or a
CI comparison shows they are not caused by stale host state.
