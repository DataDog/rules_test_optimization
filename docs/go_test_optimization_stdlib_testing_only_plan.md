<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Go Test Optimization Stdlib/Testing-Only Plan

## Objective

Prove a correctness-first Go Test Optimization mode where `test_optimization`
keeps Orchestrion out of customer package compiles while preserving the
stdlib/`testing`, synthetic `testmain`, Datadog helper packagefile, final link,
and importcfg support required to emit standard Go `testing` payloads.

The goal is to verify that standard Go `testing` payloads are still emitted
without applying Orchestrion to customer package compiles or external `_test`
package archives. Performance measurement and the final pure testing-only
stdlib/helper closure are intentionally out of scope for this first pass.

## Decisions

- D-1: Work starts from a clean branch based on `origin/main`:
  `feat/go-topt-stdlib-only-correctness`.
- D-2: In this branch, `experimental_orchestrion_mode = "test_optimization"`
  means the aggressive Test Optimization mode for correctness: customer package
  compiles stay plain, while stdlib/synthetic `testmain`/link keep the
  Orchestrion context needed for standard `testing` payloads. Do not add a
  second public optimized mode unless implementation evidence proves a separate
  mode is necessary.
- D-3: v1 supports standard Go `testing` only. Automatic `testify/suite`
  instrumentation is an explicit non-goal.
- D-4: Correctness is the only success criterion for this pass: tests must
  emit usable payloads, doctor must pass, and uploader dry-run enrichment must
  pass. Timing and performance benchmarking come later.
- D-5: Validate first in `dd-source` using the existing
  `code-workload-runner-pipelines-descriptor` Go pilot service.
- D-6: Preserve generic Orchestrion behavior outside `test_optimization`.
  `general` mode must continue to instrument normal customer code paths.

## Current Baseline

- `origin/main` does not yet have an Orchestrion mode setting. The wrapper
  transition in `modules/go/topt_go_orchestrion.bzl` only sets
  `@rules_go//go/private/orchestrion:enabled`.
- When Orchestrion is enabled today, `compilepkg.bzl` passes `-orchestrion` to
  every compile action. That is the behavior this plan changes only for
  `test_optimization`.
- Synthetic `testmain` support already has a distinct builder path: the builder
  augments synthetic `testmain` roots before compile and then disables actual
  compile toolexec for the synthetic `testmain` package itself.
- Stdlib weaving already persists woven stdlib exports and includes
  `testing`/`testing/internal/testdeps` in the persisted set.
- The prior `feat/go-topt-performance-mode` branch may be inspected as a
  reference for mode plumbing, helper closure reduction, and tests, but this
  branch should not blindly merge or cherry-pick it because the desired v1
  behavior is stricter: external `_test` archives should also compile without
  Orchestrion.

## Non-Goals

- NG-1: Do not benchmark or claim performance improvements in this pass.
- NG-2: Do not preserve automatic `testify/suite` weaving in
  `test_optimization` v1.
- NG-3: Do not remove generic Orchestrion support from `general`.
- NG-4: Do not broaden the `dd-source` pilot beyond the selected Go service
  until the small correctness proof passes.
- NG-5: Do not run a real upload during correctness validation; use uploader
  dry-run with enrichment validation.

## Implementation Plan

### S-1: Add Mode Plumbing

Add an Orchestrion mode build setting to both vendored variants:

- `third_party/rules_go_orchestrion_base/go/private/orchestrion/BUILD`
- `third_party/rules_go_orchestrion_complete/go/private/orchestrion/BUILD`

The setting must accept at least:

- `"general"`: current behavior.
- `"test_optimization"`: stdlib/`testing`-only behavior.

Propagate that setting through:

- `modules/go/topt_go_orchestrion.bzl`
  - add an `orchestrion_mode` attr to `orch_go_test`
  - have `orch_transition` set both `enabled = True` and `mode`
- `modules/go/topt_go_test.bzl`
  - add `experimental_orchestrion_mode = "general"`
  - validate allowed values
  - forward the selected mode to `orch_go_test`
  - require module-root Orchestrion pin files in `test_optimization` when the
    BUILD package is below the Go module root
- `modules/go/topt_go_infer.bzl`
  - include `bazel.go.orchestrion.mode` in generated Bazel metadata
- both vendored forks' `go/private/context.bzl` and transition plumbing
  - carry `orchestrion_mode` in the Go context so actions and builders can read
    it

Keep public defaults conservative: existing callers remain on `general` unless
they opt into `experimental_orchestrion_mode = "test_optimization"`.

### S-2: Gate Compile Orchestrion by Mode

In both vendored variants, update compile action wiring so:

- `general`: preserve existing behavior.
- `test_optimization`: do not pass `-orchestrion` to customer package compiles.
- `test_optimization`: do not pass `-orchestrion` to external `_test` package
  archives (`testfilter == "only"`).
- `test_optimization`: preserve the synthetic `testmain` augmentation path so
  helper imports and `orchestrion.pack` are still produced.

Likely files:

- `third_party/rules_go_orchestrion_base/go/private/actions/compilepkg.bzl`
- `third_party/rules_go_orchestrion_complete/go/private/actions/compilepkg.bzl`
- `third_party/rules_go_orchestrion_base/go/tools/builders/compilepkg.go`
- `third_party/rules_go_orchestrion_complete/go/tools/builders/compilepkg.go`

The key rule is: disabling compile toolexec must not disable synthetic
`testmain` helper/root resolution. If necessary, separate "action has
Orchestrion context for helper/testmain work" from "run the compiler through
Orchestrion toolexec".

### S-3: Preserve Stdlib Weaving

Keep `GoStdlib` Orchestrion-enabled in `test_optimization`.

Narrow the stdlib closure only to packages required for standard `testing`
payload correctness. The initial candidate closure is:

- `testing`
- `testing/internal/testdeps`
- `flag`
- `fmt`
- `log`
- `os`
- `os/exec`
- `runtime`
- `io/ioutil` where still required by helper dependency resolution

Validated implementation note: the first correctness cut still keeps `net/http`,
`log/slog`, and the matching Datadog contrib helper roots in the
`test_optimization` helper/link closure because the woven stdlib can still
reference those helper symbols. The pure testing-only closure remains a follow-up
optimization after correctness is proven in the pilot services.

Likely files:

- `third_party/rules_go_orchestrion_base/go/private/actions/stdlib.bzl`
- `third_party/rules_go_orchestrion_complete/go/private/actions/stdlib.bzl`
- `third_party/rules_go_orchestrion_base/go/tools/builders/stdlib.go`
- `third_party/rules_go_orchestrion_complete/go/tools/builders/stdlib.go`
- `third_party/rules_go_orchestrion_base/go/tools/builders/importcfg.go`
- `third_party/rules_go_orchestrion_complete/go/tools/builders/importcfg.go`

### S-4: Preserve Synthetic Testmain And Helper Packagefiles

Keep synthetic `testmain` as the bridge that forces Datadog helper packages
into the final test binary.

In `test_optimization`, reduce helper roots to standard `testing` support where
the current Orchestrion/stdlib closure permits it:

- keep `github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting`
- keep `github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations`
- keep `github.com/DataDog/dd-trace-go/v2/ddtrace/tracer`
- keep `github.com/DataDog/dd-trace-go/v2/internal` only if validation proves it
  is still required by the selected helper closure
- keep gotesting coverage helpers if coverage validation requires them
- target follow-up: remove generic contrib roots from this mode once validation
  proves the woven stdlib no longer references them:
  - `github.com/DataDog/dd-trace-go/contrib/net/http/v2`
  - `github.com/DataDog/dd-trace-go/contrib/net/http/v2/internal/orchestrion`
  - `github.com/DataDog/dd-trace-go/contrib/log/slog/v2`
  - profiler unless standard `testing` payload validation requires it

Likely files:

- `third_party/rules_go_orchestrion_base/go/tools/builders/compilepkg.go`
- `third_party/rules_go_orchestrion_complete/go/tools/builders/compilepkg.go`
- `third_party/rules_go_orchestrion_base/go/tools/builders/link.go`
- `third_party/rules_go_orchestrion_complete/go/tools/builders/link.go`
- `third_party/rules_go_orchestrion_base/go/tools/builders/orchestrion_synthetic_tool.go`
- `third_party/rules_go_orchestrion_complete/go/tools/builders/orchestrion_synthetic_tool.go`
- `third_party/rules_go_orchestrion_base/go/tools/builders/orchestrion_version.go`
- `third_party/rules_go_orchestrion_complete/go/tools/builders/orchestrion_version.go`

### S-5: Preserve Link And Importcfg Coherence

Final test binary links must still receive:

- the synthetic `testmain` packagefile manifest
- Datadog helper packagefiles needed by the selected helper closure
- woven stdlib packagefiles for `testing` and its selected closure
- the reduced module/proxy inputs needed to resolve helper packages offline

Do not interpret "remove Orchestrion from customer/test compiles" as "remove
all link/importcfg Orchestrion support". A build can pass while runtime
CI Visibility silently fails if the link step falls back to unwoven stdlib or
misses helper packagefiles.

Likely files:

- `third_party/rules_go_orchestrion_base/go/private/actions/link.bzl`
- `third_party/rules_go_orchestrion_complete/go/private/actions/link.bzl`
- `third_party/rules_go_orchestrion_base/go/tools/builders/link.go`
- `third_party/rules_go_orchestrion_complete/go/tools/builders/link.go`
- `third_party/rules_go_orchestrion_base/go/tools/builders/importcfg.go`
- `third_party/rules_go_orchestrion_complete/go/tools/builders/importcfg.go`

### S-6: Update Tests And Docs

Add or update tests that prove the new shape:

- macro analysis tests in `modules/go/tests/test_macro.bzl`
  - `experimental_orchestrion_mode = "test_optimization"` is accepted
  - selected mode is forwarded to the wrapper
  - module-root pin files are required for nested packages in this mode
  - runtime payload data remains in runfiles
- builder unit tests in both vendored variants
  - mode validation
  - mode-aware helper closure
  - stdlib package list reduction
  - synthetic helper cache keys include mode
  - `test_optimization` keeps only the generic contrib roots still required by
    woven stdlib/link correctness
- integration/aquery tests
  - `GoStdlib` remains Orchestrion-enabled
  - ordinary customer `GoCompilePkg` actions do not contain `-orchestrion`
  - external `_test` `GoCompilePkgExternal` actions do not contain
    `-orchestrion`
  - synthetic `testmain` still produces and consumes `orchestrion.pack`
  - final `GoLink` still has the manifest/importcfg/helper packagefile support

Update docs:

- `README.md`
- `docs/Configuration_Reference.md`
- `docs/go_orchestrion_bazel_deep_dive.md`
- `docs/go_orchestrion_maintainer_state.md`

Docs must state that `test_optimization` v1 is standard Go `testing` only and
does not support automatic `testify/suite` instrumentation.

### S-7: Keep Fork Variants In Sync

Apply semantic changes to both:

- `third_party/rules_go_orchestrion_base`
- `third_party/rules_go_orchestrion_complete`

Then refresh and verify fork metadata:

```bash
python3 tools/dev/diff_rules_go_fork.py --metadata third_party/rules_go_orchestrion_base.METADATA.json --write-report
python3 tools/dev/diff_rules_go_fork.py --metadata third_party/rules_go_orchestrion_complete.METADATA.json --write-report
python3 tools/dev/verify_rules_go_variants.py
```

## Local Validation

Run narrow checks first:

```bash
./bazelw test //modules/go/tests:all
```

Run vendored builder tests for both variants. If root labels do not expose the
vendored fork tests directly, use the existing variant smoke scripts:

```bash
RULES_GO_VARIANT=base tools/dev/run_rules_go_variant_smoke.sh
RULES_GO_VARIANT=complete tools/dev/run_rules_go_variant_smoke.sh
```

Then run Go consumer integration harnesses:

```bash
USE_BAZEL_VERSION=8.4.1 RULES_GO_VARIANT=base tools/tests/integration/run_workspace_go_integration.sh
USE_BAZEL_VERSION=8.4.1 RULES_GO_VARIANT=complete tools/tests/integration/run_workspace_go_integration.sh
USE_BAZEL_VERSION=8.4.1 RULES_GO_VARIANT=base tools/tests/integration/run_bzlmod_go_integration.sh
USE_BAZEL_VERSION=8.4.1 RULES_GO_VARIANT=complete tools/tests/integration/run_bzlmod_go_integration.sh
```

Run full repo validation only after focused checks pass:

```bash
./bazelw test //...
```

## dd-source Pilot Validation

Use the local `dd-source` checkout at:

```text
/Users/tony.redondo/dd/dd-source
```

Current pilot service:

- service key: `code_workload_runner_pipelines_descriptor`
- service name: `code-workload-runner-pipelines-descriptor`
- Go sync repo:
  `test_optimization_data_go_code_workload_runner_pipelines_descriptor`
- pilot targets:
  - `//domains/ci-app/apps/apis/code-workload-runner-pipelines-descriptor/internal/inspector:go_default_test`
  - `//domains/ci-app/apps/apis/code-workload-runner-pipelines-descriptor/internal/finder:go_default_test`

The current `dd-source` target
`//tools/test_optimization:dd_test_optimization_doctor` also expects the Python
`query_validator` target. For a Go-only proof, either temporarily narrow that
doctor target in a separate `dd-source` validation branch/worktree, or also run:

```bash
bin/bzl test --config=test-optimization \
  //domains/ffe/apps/apis/query_validator/internal/validator/tests:test_sql_validator
```

Do not overwrite existing `dd-source` local changes. Before modifying that
checkout, inspect status with:

```bash
git -c core.fsmonitor=false status --short --branch
```

Point `dd-source` to this local rules checkout for validation. Because the
current `dd-source` WORKSPACE uses archive pins, use the least invasive local
override pattern available in that checkout. If no helper exists, patch the
validation worktree to use this checkout's `datadog-rules-test-optimization`
and matching local `rules_go` variant rather than the pinned archive.

Run the Go pilot:

```bash
bin/bzl sync --config=test-optimization \
  --only=test_optimization_data_go_code_workload_runner_pipelines_descriptor \
  --repo_env=FETCH_SALT="$(date +%s)"

bin/bzl test --config=test-optimization \
  //domains/ci-app/apps/apis/code-workload-runner-pipelines-descriptor/internal/inspector:go_default_test

bin/bzl test --config=test-optimization \
  //domains/ci-app/apps/apis/code-workload-runner-pipelines-descriptor/internal/finder:go_default_test
```

Run doctor and uploader dry-run:

```bash
bin/bzl run --config=test-optimization \
  //tools/test_optimization:dd_test_optimization_doctor

bin/bzl run --config=test-optimization \
  //tools/test_optimization:dd_upload_payloads -- \
  --dry-run \
  --validate-enrichment \
  --expected-enriched-tag=bazel.go.payload_selection
```

Evidence required from `dd-source`:

- both Go pilot tests pass
- each pilot has `bazel-testlogs/.../test.outputs/payloads/tests/*.json`
- each payload JSON is parseable and contains uploadable test events
- `bazel_target_metadata.json` exists beside each target's payloads
- metadata includes the exact `bazel.target`, `bazel.package`, service, and
  `bazel.go.payload_selection`
- doctor succeeds without `full_bundle_no_match`
- uploader dry-run enrichment succeeds
- logs or payloads prove CI Visibility initialized; test success alone is not
  sufficient

If possible, add one build-shape proof in `dd-source` with probes enabled:

```bash
RULES_GO_ORCHESTRION_PROBE=1 \
RULES_GO_ORCHESTRION_PROBE_FILE=/tmp/dd-source-topt-probes.log \
bin/bzl test --config=test-optimization \
  --action_env=RULES_GO_ORCHESTRION_PROBE=1 \
  --action_env=RULES_GO_ORCHESTRION_PROBE_FILE=/tmp/dd-source-topt-probes.log \
  //domains/ci-app/apps/apis/code-workload-runner-pipelines-descriptor/internal/inspector:go_default_test
```

The probe or aquery evidence must show:

- stdlib/`testing` path is Orchestrion-enabled
- ordinary app package compiles are not Orchestrion-enabled
- external `_test` package compiles are not Orchestrion-enabled
- final link/importcfg still has the synthetic manifest/helper support

## Risks

- R-1: Removing Orchestrion too broadly can leave synthetic `testmain` without
  Datadog helper packagefiles. Mitigation: split compile-toolexec gating from
  helper/testmain context.
- R-2: Builds can pass while runtime payloads are missing if link/importcfg
  falls back to unwoven stdlib. Mitigation: verify payload files, tracer
  initialization, doctor, and uploader dry-run enrichment.
- R-3: `testify/suite` users lose automatic suite instrumentation in
  `test_optimization` v1. Mitigation: document this explicitly and add a
  negative/unsupported fixture.
- R-4: Fork variants can drift. Mitigation: update base and complete together,
  refresh changed-files reports, and run variant verification.
- R-5: `dd-source` has local changes and environment-specific Bazel state.
  Mitigation: use `git -c core.fsmonitor=false`, avoid overwriting unrelated
  edits, validate in a separate worktree if needed, and run heavy commands
  serially.
- R-6: Local Bazel or Orchestrion caches can hide correctness problems.
  Mitigation: run at least one clean-ish validation after `bazel shutdown` and
  refresh sync data with `FETCH_SALT`.

## Done Criteria

The experiment is done only when all of these are true:

- `test_optimization` mode exists and is documented.
- Customer package compiles and external `_test` package compiles do not receive
  Orchestrion in `test_optimization`.
- Stdlib/`testing`, synthetic `testmain`, helper packagefiles, link, and
  importcfg remain coherent.
- Standard Go `testing` pilot targets in `dd-source` emit usable payloads.
- Doctor and uploader dry-run enrichment pass for the pilot.
- `testify/suite` automatic instrumentation is either documented as unsupported
  or covered by a negative fixture.
- Both vendored fork variants are updated and verified.
- No performance claims are made from this pass.
