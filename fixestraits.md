# Go Orchestrion Debugging Notes

## Goal

Make the Bazel-built Go test binary in the `_tests` repository run with Datadog CI Visibility instrumentation correctly applied through Orchestrion, with a particular focus on the `gotesting` integration around `testing.M.Run`.

Success criteria:

- the local `_tests` fast cycle passes
- the final linked test binary is internally consistent
- Datadog tracer debug logs appear at runtime
- ideally, `instrumentTestingM` is observable in runtime logs or otherwise proven to be active in the final binary

## Current Status

The issue is **not fixed yet**.

What is already true:

- Orchestrion is active in the Bazel path.
- The woven stdlib `testing.a` contains:
  - `instrumentTestingM`
  - `instrumentTestingTFunc`
  - `__dd_civisibility`
- Earlier stdlib cache-family and build-setting issues were fixed.
- The remaining blocker is at **final synthetic link** in the local `_tests` fast cycle.

Current failure:

- final synthetic link fails with a Datadog helper archive fingerprint mismatch
- the mismatch is currently between helper archives from different export families, for example:
  - `github.com/DataDog/dd-trace-go/v2/internal`
  - imported from `github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting`

This strongly suggests we are still mixing two different helper-export roots in the final link importcfg.

## Repositories Involved

- Main repo:
  - `/Users/tony.redondo/repos/github/Datadog/rules_test_optimization`
- Consumer-like test repo:
  - `/Users/tony.redondo/repos/github/Datadog/rules_test_optimization_tests`

## Main Local Repro Loop

Fast local loop currently uses the `_tests` repo with local overrides back to this repository and the vendored `rules_go`.

Typical command shape:

```bash
cd /Users/tony.redondo/repos/github/Datadog/rules_test_optimization_tests

./bazelw --batch test //src/go-project:hello_test \
  --override_module=datadog-rules-test-optimization=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization \
  --override_module=datadog-rules-test-optimization-go=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go \
  --override_module=rules_go=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion \
  --override_repository=test_optimization_data_go=/tmp/topt_go_stub.HjGeKj \
  --override_repository=datadog-rules-test-optimization-go++test_optimization_go_extension+test_optimization_data_go=/tmp/topt_go_stub.HjGeKj \
  --test_output=streamed \
  --test_env=DD_TRACE_DEBUG=true \
  --test_env=DD_CIVISIBILITY_ENABLED=true \
  --action_env=ORCHESTRION_DEBUG_TRACE=1 \
  --action_env=ORCHESTRION_LOG_LEVEL=TRACE \
  --sandbox_debug \
  --verbose_failures
```

## Important Artifacts And Logs

- latest fast-loop log:
  - `/tmp/rto_trace_cycle_fast27.log`
- latest synthetic link importcfg dump:
  - `/tmp/orchestrion-link-importcfg-synthetic-latest.txt`

These artifacts are useful because they show the final synthetic link path and which packagefiles are being fed into the linker.

## What Has Been Tried Already

### 1. Basic Orchestrion wrapper integration

Tried:

- wrapping `go_test` with a transitioned Orchestrion-enabled target
- forwarding executable and runfiles through the wrapper
- preserving Windows `.exe` naming in the wrapper

Result:

- necessary and correct for target shape
- not sufficient to get CI Visibility `gotesting` behavior working

### 2. Bootstrap and module setup fixes

Tried:

- adding a Go bootstrap helper
- pinning Orchestrion in consumer repos
- patching `orchestrion.tool.go`
- making bootstrap add the `rules_go` Orchestrion extension wiring
- removing old `dd-trace-go.v1` references from bootstrap-generated files
- preserving the `all/v2` import path correctly

Result:

- fixed repo setup and several early failures
- did not by itself solve `testing.M.Run` instrumentation

### 3. Vendoring patched `rules_go`

Tried:

- vendoring the custom `rules_go` fork into `third_party/rules_go_orchestrion`
- making bootstrap and local development point at the vendored module

Result:

- removed dependency on a personal fork at runtime
- made it possible to patch the toolchain directly
- essential for deep debugging

### 4. Fixing broken generated Orchestrion tool repository

Tried:

- repairing the generated `rules_go_orchestrion_tool` repo
- fixing missing target definitions and malformed BUILD generation
- fixing the generated Orchestrion binary repo to produce a valid public target

Result:

- resolved early module/repo resolution failures

### 5. Compile-time synthetic module handling

Tried:

- making Orchestrion compile actions stage hidden pin files through `data`
- copying real `go.mod` / `go.sum` into synthetic temp modules
- warming module caches
- setting `GOPATH`, `GOMODCACHE`, `GOCACHE`
- aligning workdir/module-dir handoff

Result:

- removed earlier “missing package”, “module cache not found”, and synthetic module bootstrap failures

### 6. Fixing Orchestrion tool invocation identity

Tried:

- changing stdlib Orchestrion handoff so Orchestrion sees the real `compile` command instead of `builder filterbuildid`

Result:

- critical progress
- enabled stdlib `testing` weaving so `testing.a` now contains `instrumentTestingM`

### 7. Re-enabling synthetic Bazel `testmain` instrumentation

Tried:

- removing the temporary bypass that disabled Orchestrion for synthetic `testmain.go`
- validating with runtime tracer logs and local `_tests` runs

Result:

- necessary
- got synthetic `testmain` compiling through Orchestrion again

### 8. Stdlib cache-family fixes

Tried:

- ensuring Orchestrion subprocesses use Bazel’s stdlib cache instead of a separate shared cache
- preserving stdlib woven exports across compile and link
- stopping accidental `GOCACHE` overrides

Result:

- fixed earlier fingerprint mismatches around stdlib archives
- made `testing.a` and related stdlib artifacts more consistent

### 9. Link/importcfg rewrite experiments

Tried:

- rewriting final link importcfg entries for stdlib packages
- selectively rewriting only certain stdlib packages
- appending missing module packagefiles for synthetic final link
- augmenting helper roots for synthetic `testmain`
- forcing plain `go tool link` for the synthetic final link instead of Orchestrion link

Result:

- fixed several earlier issues
- but did not fully solve final-link archive consistency

### 10. Massive local diagnostics

Tried:

- enabling `ORCHESTRION_LOG_LEVEL=TRACE`
- enabling `ORCHESTRION_DEBUG_TRACE=1`
- dumping synthetic importcfg
- logging packagefile selections
- logging helper archive resolution
- inspecting final archive contents and symbols

Result:

- produced the current best signal:
  - the final synthetic link is still mixing helper archive families

## What We Know Now

### Proven

- Orchestrion is being invoked in the Bazel path.
- The standard library `testing` package is being woven.
- The woven `testing.a` archive contains the expected CI Visibility helper symbols.
- The current failure is **not** “Orchestrion is disabled”.

### Not Yet Proven

- that the final linked test binary uses one fully consistent helper/export family
- that runtime `testing.M.Run` is executing the woven path in the final linked binary
- that the final linked binary will always emit the expected `instrumentTestingM` runtime log

## Current Hypothesis

The remaining bug is in the synthetic final-link importcfg construction:

- compile-time helper resolution and final-link helper resolution are still using **different helper-export roots**
- `gotesting` / `integrations` packagefiles come from one helper-export family
- `tracer`, `profiler`, or related Datadog helper packagefiles come from another
- the final linker then sees incompatible fingerprints for transitive shared packages like:
  - `github.com/DataDog/dd-trace-go/v2/internal`

This is why:

- stdlib `testing.a` can already be correctly woven
- yet final synthetic link still fails

## Likely Files To Fix Next

- [third_party/rules_go_orchestrion/go/tools/builders/importcfg.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/importcfg.go)
- [third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go)
- [third_party/rules_go_orchestrion/go/tools/builders/link.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/link.go)
- [third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go)
- [third_party/rules_go_orchestrion/go/tools/builders/stdlib.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/stdlib.go)

## Next Steps

### 1. Unify helper export family end-to-end

Make synthetic `testmain` compile and final link use the exact same helper export family.

Concrete direction:

- inspect every path that resolves Datadog helper packagefiles
- ensure both compile-time and final-link helper injection call into one shared resolver path
- remove any remaining package-set-based divergence in helper export cache selection

### 2. Replace stale helper entries instead of only appending missing ones

If final synthetic link carries helper packagefiles from compile-time manifests, then simply appending missing entries is not enough.

Concrete direction:

- in final synthetic link importcfg generation, actively replace conflicting Datadog helper packagefile entries with the canonical family chosen for final link

### 3. Re-verify runtime once final link passes

Once the local `_tests` fast cycle passes:

- rerun with:
  - `DD_TRACE_DEBUG=true`
  - `DD_CIVISIBILITY_ENABLED=true`
  - `ORCHESTRION_LOG_LEVEL=TRACE`
- verify:
  - tracer logs appear
  - final binary links successfully
  - ideally, `instrumentTestingM` appears in runtime output or the final binary disassembly proves it is active

### 4. Only then commit and push

Do not commit or push until:

- the local `_tests` fast cycle is green
- final link no longer has fingerprint mismatches
- runtime tracer output is healthy again

## Notes

- The issue is now much narrower than at the start.
- We are no longer debugging general bootstrap or wrapper wiring.
- The main remaining problem is final synthetic link consistency for Datadog helper archives.
