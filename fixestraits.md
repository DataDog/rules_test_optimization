# Go Orchestrion Debugging Notes

## Goal

Make the Bazel-built Go test binary in the `_tests` repository run with Datadog CI Visibility instrumentation correctly applied through Orchestrion, with a particular focus on the `gotesting` integration around `testing.M.Run`.

Success criteria:

- the local `_tests` fast cycle passes
- the final linked test binary is internally consistent
- Datadog tracer debug logs appear at runtime
- ideally, `instrumentTestingM` is observable in runtime logs or otherwise proven to be active in the final binary

## Current Status

The issue is **locally fixed** on the warmed `_tests` cycle.

What is now true locally:

- Orchestrion is active in the Bazel path.
- The woven stdlib `testing.a` contains:
  - `instrumentTestingM`
  - `instrumentTestingTFunc`
  - `__dd_civisibility`
- The local `_tests` target `//src/go-project:hello_test` now:
  - builds successfully
  - links successfully
  - runs successfully with `DD_TRACE_DEBUG=true` and `DD_CIVISIBILITY_ENABLED=true`
  - emits Datadog tracer / CI Visibility runtime logs again
  - emits `instrumentTestingTFunc`
  - emits `instrumentTestingM: finished with exit code: 0`

The critical local runtime proof is now present.

## Cleanup Status

After the fix was proven locally and in CI, the vendored `rules_go` builders were cleaned up to remove investigation-only noise while preserving the structural synthetic-link fix.

Cleaned up in:

- `third_party/rules_go_orchestrion/go/tools/builders/builder.go`
- `third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go`
- `third_party/rules_go_orchestrion/go/tools/builders/filter_buildid.go`
- `third_party/rules_go_orchestrion/go/tools/builders/link.go`
- `third_party/rules_go_orchestrion/go/tools/builders/stdlib.go`

Cleanup changes:

- removed startup / argv / cwd debug spew from the top-level builder
- removed synthetic compile/link temp-file dumps and `/tmp/...` artifact copies
- removed synthetic-link forced debug tmpdir logic
- removed ad hoc importcfg tracing in `compilepkg` and `link`
- removed the standalone `/tmp/orchestrionfilterbuildid.log` logger and related testing-only tracing
- stopped forcing `goenv.verbose = true` for all Orchestrion stdlib builds

Post-cleanup validation still passes:

- `./bazelw test //modules/go/tools/dd_topt_go_bootstrap:bootstrap_test --test_output=errors`
- `./bazelw build //examples/single_service/src/go-project:hello_test`
- `_tests` local runtime flow still emits:
  - `Datadog Tracer ... DEBUG`
  - `instrumentTestingTFunc: instrumenting test function`
  - `instrumentTestingM: finished with exit code: 0`

Second cleanup pass was done in the vendored Orchestrion source patch layer:

- `third_party/rules_go_orchestrion/go/private/orchestrion/extensions.bzl`

Second-pass cleanup changes:

- removed the temporary source injection that logged missing package resolution results in `internal/toolexec/aspect/resolve.go`
- removed the temporary source injection that logged `toolexec` parse decisions in `internal/cmd/toolexec.go`
- removed the temporary source injection that logged package/file/aspect matching details in `internal/injector/injector.go`
- removed the extra stderr diagnostics around `oncompile` and `onlink` dependency resolution
- simplified the injected `fallbackLookup` helper to keep the archive-selection behavior without the debug spew
- kept the functional `extensions.bzl` patches that are still required for the integration to work

Second-pass runtime validation also passes:

- real `_tests` run forced without test cache:
  - `./bazelw test //src/go-project:hello_test --nocache_test_results ... --test_output=streamed`
- runtime output still emits:
  - `Datadog Tracer v2.6.0 DEBUG: ...`
  - `instrumentTestingTFunc: instrumenting test function`
  - `instrumentTestingM: finished with exit code: 0`

So the debug-only Orchestrion source injections are no longer needed.

## Root Cause We Ended Up Fixing

This turned out to be a two-part synthetic-link problem:

1. The synthetic `testmain` compile was persisting Datadog helper packagefile metadata inside the archive as `orchestrion.pack`.
   - Darwin external link treated that archive member as a real object and failed with:
     - `ld64.lld: ... 000000.o: unhandled file type`

2. After moving that metadata out of the archive, the final synthetic link still regenerated Datadog helper packagefiles from a different helper-export family than the one used during synthetic `testmain` compile.
   - compile-time `gotesting` / `integrations` came from one `.nolinkdeps` helper root
   - final link rebuilt `gotesting` / `integrations` / `tracer` / `profiler` from another root
   - that drift prevented the final binary from using the same instrumented helper closure that `testmain` compile had already proven

In short:

- synthetic `testmain` needed a sidecar manifest, not an archive member
- final synthetic link needed that sidecar manifest as a declared Bazel input
- final synthetic link also needed to complete the Datadog helper closure from the same compile-time helper-export root instead of regenerating a second family

## Latest Proven Fix

The local fix that got runtime instrumentation working was:

- declare a sidecar manifest output for synthetic `~testmain.a`
- thread that sidecar through `GoArchiveData`
- add the sidecar as a declared input to the final `GoLink`
- teach link to load helper packagefile directives from the sidecar
- then append the broader Datadog helper closure from the same compile-time export root
- normalize helper-export root parsing so synthetic compile and final link agree on the root shape

After that:

- the synthetic final importcfg preserves the compile-time `.nolinkdeps` helper family
- final link succeeds
- runtime tracer / CI Visibility logs return
- the `testing.M.Run` hook is active enough to emit:
  - `instrumentTestingM: finished with exit code: 0`

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

### 11. Helper export family narrowing

Tried:

- dumping the final synthetic link importcfg into `/tmp/orchestrion-link-importcfg-synthetic-latest.txt`
- proving that `gotesting` / `integrations` and the broader Datadog closure still resolve from different helper-export roots
- changing synthetic `testmain` compile to warm the full Datadog closure, not only `gotesting` / `integrations`
- removing `go.sum` from the helper-export cache request key so module export families are not split by mutable sum-file churn during the same build
- adding explicit debug logs for:
  - helper-export request key
  - module dir
  - package set used by each helper-export resolve call

Result:

- this was the right direction, but not sufficient on its own
- the decisive missing piece was that synthetic compile metadata was not actually a declared link input
- once the helper-family narrowing work was combined with the sidecar-manifest wiring, the final synthetic link stopped drifting into a second Datadog helper family

### 12. Synthetic testmain manifest sidecar

Tried:

- declare a dedicated synthetic manifest sidecar next to `~testmain.a`
- stop relying on the archive-member `orchestrion.pack` for the Darwin synthetic link path
- carry the sidecar through `GoArchiveData`
- add it as an explicit `GoLink` input
- make final link load helper packagefiles from that sidecar first, then append any missing Datadog closure packages from the same root

Result:

- removed the Darwin `000000.o: unhandled file type` failure
- eliminated helper-root drift between synthetic `testmain` compile and final link
- restored runtime tracer logs
- restored runtime CI Visibility hooks in the final local `_tests` test execution

## Current Next Steps

The local issue is fixed enough to move back into the outer loop:

1. commit the current branch changes once the worktree is cleaned up
2. repin the `_tests` repo to this new main-repo commit
3. rerun the full PR matrix
4. check whether CI now shows:
   - Datadog tracer runtime logs
   - `instrumentTestingM` runtime signal on Linux/macOS
   - no regression on Windows

If CI differs from the warmed local cycle, the first thing to inspect should be whether the synthetic `~testmain.a.orchestrion.pack` sidecar is present and declared in the CI link sandbox the same way it is locally.

Latest local patch:

- synthetic `testmain` compile now prefers the real source module dir from `embedLookupDirs`
- only falls back to the older package-path guess if no source-module hint is available
- final synthetic link now detects any existing Datadog helper export root from the synthetic manifest importcfg and reuses that root when resolving additional Datadog helper packagefiles

Latest result:

- the final synthetic importcfg now carries a single helper-export family for `gotesting`, `integrations`, `tracer`, `profiler`, and the contrib helpers
- but the compile-time synthetic `main` archive is still being linked against a different `gotesting` archive than the one used at final link
- the final-link recomputation was no longer choosing a different root, it was rebuilding and replacing `gotesting` within the same root
- latest patch changes the final-link behavior again:
  - preserve the compile-time `gotesting` / `integrations` packagefiles when a helper root is already present
  - only append the missing Datadog helper packagefiles from that same root

### 12. Full synthetic helper manifest

Tried:

- persisting the full Datadog helper export map discovered during synthetic `testmain` compile into `orchestrion.pack`, not just the root alias packagefiles
- changing final synthetic link to skip `appendMissingModulePackagefiles(...)` when that manifest is present and instead trust the compile-time helper packagefiles entirely

Current hypothesis:

- the last remaining `gotesting -> internal` mismatch is caused by final-link helper recomputation mutating a reused helper-export root in place
- if final link uses the exact compile-time helper packagefiles from the synthetic manifest, helper archives should remain internally consistent and the final synthetic link should stop drifting

Validation target:

- rerun the local `_tests` fast cycle
- confirm final synthetic importcfg contains the compile-time helper packagefiles without any new helper resolution at link
- check whether the `github.com/DataDog/dd-trace-go/v2/internal` fingerprint mismatch disappears

### 13. Helper archive sanitization

Tried:

- comparing the synthetic helper-export archives against a plain `go list -export` tracer archive
- discovering that our helper-export archives carry an extra `link.deps` member while the plain Go archive does not
- adding a local sanitization step so module-export archives are copied to `.nolinkdeps` variants before they are injected into compile/link importcfgs

Current hypothesis:

- the latest Darwin linker failure (`ld64.lld: unhandled file type`) is caused by the extra `link.deps` member in the Datadog helper package archives
- stripping that member should leave a normal package archive layout closer to the plain `go list -export` result and let the final synthetic link proceed

Result:

- the old `gotesting -> internal` fingerprint mismatch stopped appearing
- final synthetic importcfg now shows one helper-export family plus sanitized Datadog helper archives
- but Darwin final link still fails with:
  - `ld64.lld: error: .../000000.o: unhandled file type`

### 14. Deterministic synthetic link tmpdir preservation

Tried:

- making synthetic final link log its detection loudly
- forcing a deterministic tmpdir under:
  - `/tmp/orchestrion-link-debug-synthetic`
- clearing and recreating that directory on each debug run
- keeping `-v` enabled for the synthetic `go tool link` path

Current result:

- the synthetic link path is definitely active
- the final log now proves `link.go` is executing, but the link action itself does **not** carry `ORCHESTRION_DEBUG_TRACE`
- because of that, the earlier tempdir-preservation block never triggered even though the synthetic link path was active
- because of that, the Darwin linker tempdir still disappears before we can inspect `000000.o`

Latest local patch:

- synthetic final-link tmpdir preservation is now unconditional for synthetic test binaries
- it no longer depends on `ORCHESTRION_DEBUG_TRACE`

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

The remaining bug is no longer package selection. It is the **shape of one object produced or selected during synthetic Darwin final link**.

Most likely candidates:

- one object emitted into the `go-link-*` tempdir is not a valid Darwin object for `ld64.lld`
- the bad object may be derived from one of the sanitized Datadog helper archives
- or the synthetic testmain plain-link path is still not using the exact builder binary we think it is, which would explain why the forced tmpdir diagnostics are missing

This is why:

- stdlib `testing.a` can already be correctly woven
- final synthetic importcfg already looks reasonable
- yet Darwin external link still fails before the final test binary is produced

## Likely Files To Fix Next

- [third_party/rules_go_orchestrion/go/tools/builders/link.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/link.go)
- [third_party/rules_go_orchestrion/go/tools/builders/ar.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/ar.go)
- [third_party/rules_go_orchestrion/go/tools/builders/importcfg.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/importcfg.go)

## Next Steps

### 1. Capture the Darwin synthetic link tmpdir for real

Concrete direction:

- rerun the fast local `_tests` cycle after forcing a deterministic synthetic tmpdir
- verify the new link builder binary actually logs:
  - `link: synthetic test binary detected ...`
  - `orchestrion link debug: forcing synthetic link tmpdir ...`
- inspect `/tmp/orchestrion-link-debug-synthetic` immediately after failure

### 2. Inspect the rejected `000000.o`

Concrete direction:

- once the tempdir is preserved, inspect:
  - `000000.o`
  - `go.o`
  - any neighboring numbered objects
- use:
  - `file`
  - `xxd`
  - `otool`
  - compare against `_go_.o` extracted from sanitized helper archives

### 3. If `000000.o` comes from sanitized helper archives, narrow or revert that sanitization

Concrete direction:

- if the rejected object is traced back to `.nolinkdeps` helper archives, stop mutating all helper archives
- instead, either:
  - preserve original helper archives and solve `link.deps` another way
  - or sanitize only the specific archives proven to be safe

### 4. Re-verify runtime once final link passes

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

## Latest Checkpoint

Two separate states now exist and should not be conflated:

1. The real `_tests` repo Go path is locally fixed.
   - Local `_tests` runs now show:
     - `Datadog Tracer ... DEBUG`
     - `instrumentTestingTFunc`
     - `instrumentTestingM: finished with exit code: 0`
   - That proves the core CI Visibility / Orchestrion runtime path works locally.

2. A separate repo-local regression remains in `//modules/go/tools/dd_topt_go_bootstrap:bootstrap_test`.
   - This is a plain synthetic test binary path with `orchestrion_enabled=false`.
   - The failure is not the original CI Visibility issue.
   - It currently fails because synthetic helper module preparation still tries to execute the Go SDK from a relative sandbox path:
     - `fork/exec .../external/rules_go++go_sdk+go_default_sdk/bin/go: no such file or directory`

### Root Cause Of The Separate Bootstrap Regression

The bad relative SDK path was not coming from `goCmd()`.

It was coming from:

- [third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go)

Specifically:

- `prepareSyntheticOrchestrionModule(goSdkPath, ...)`

was constructing:

- `filepath.Join(goSdkPath, "bin", "go")`

instead of:

- `filepath.Join(abs(goSdkPath), "bin", "go")`

This matters for sandboxed plain synthetic link paths such as `bootstrap_test`, where the working directory differs from the execroot-relative SDK path.

There turned out to be two separate offenders in `orchestrion.go`:

- `prepareSyntheticOrchestrionModule(...)`
- `ensureWovenPackagesAvailable(...)`

Both were constructing `.../bin/go` from the raw relative SDK path instead of `abs(goSdkPath)`.

### Latest Narrow Fix

Applied locally:

- `prepareSyntheticOrchestrionModule()` now absolutizes `goSdkPath` before constructing the `go` executable path.

This fix is intentionally narrow:

- it targets the separate `bootstrap_test` regression
- it does not change the already-working `_tests` Orchestrion runtime path

### Immediate Next Step

Re-run only:

```bash
./bazelw test //modules/go/tools/dd_topt_go_bootstrap:bootstrap_test --test_output=errors
```

If that goes green, then:

1. rerun the broader main-repo check
2. ensure the `_tests` local runtime path still shows `instrumentTestingM`
3. then commit/push this branch state

## Latest Local Result

Both local validations are green now:

1. Repo-local bootstrap regression:

```bash
./bazelw test //modules/go/tools/dd_topt_go_bootstrap:bootstrap_test --test_output=errors
```

Status:
- PASS

2. Real `_tests` runtime path:

```bash
cd /Users/tony.redondo/repos/github/Datadog/rules_test_optimization_tests
source ~/ddtrace.sh >/dev/null 2>&1 || true
./bazelw --batch --output_user_root=/tmp/rto_recheck_real_after_plainlink test //src/go-project:hello_test \
  --override_module=datadog-rules-test-optimization=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization \
  --override_module=datadog-rules-test-optimization-go=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go \
  --override_module=datadog-rules-test-optimization-python=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/python \
  --override_module=datadog-rules-test-optimization-java=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/java \
  --override_module=datadog-rules-test-optimization-nodejs=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/nodejs \
  --override_module=datadog-rules-test-optimization-dotnet=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/dotnet \
  --override_module=datadog-rules-test-optimization-ruby=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/ruby \
  --override_module=rules_go=/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion \
  --test_output=streamed \
  --test_env=DD_TRACE_DEBUG=true \
  --test_env=DD_CIVISIBILITY_ENABLED=true \
  --action_env=ORCHESTRION_DEBUG_TRACE=1 \
  --action_env=ORCHESTRION_LOG_LEVEL=TRACE \
  --sandbox_debug --verbose_failures
```

Status:
- PASS

Runtime proof in `/tmp/rto_recheck_real_after_plainlink.log`:
- `Datadog Tracer v2.6.0 DEBUG: ...`
- `instrumentTestingTFunc: instrumenting test function`
- `instrumentTestingM: finished with exit code: 0`

## Final Fixes From This Round

### 1. Plain synthetic final link now reuses the compile-time sidecar only

In:

- [third_party/rules_go_orchestrion/go/tools/builders/link.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/link.go)

Change:
- plain synthetic link (`linkOrchestrion == ""`) no longer calls `appendMissingModulePackagefiles(...)`
- it now relies only on the compile-time sidecar manifest

Why:
- the sidecar already carries the rooted Datadog helper packagefiles for the synthetic testmain path
- the extra helper download path was only causing a separate bootstrap regression

### 2. Plain synthetic helper preparation no longer tries to resolve the Go SDK from the wrong place

In:

- [third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go)

Changes:
- `prepareSyntheticOrchestrionModule()` now absolutizes `goSdkPath`
- `ensureWovenPackagesAvailable()` now absolutizes `goSdkPath`

Why:
- plain bootstrap/test paths were previously trying to execute `.../external/rules_go++go_sdk+go_default_sdk/bin/go` from the wrong synthetic working context

## Current Conclusion

At the local level, the issue is now fixed:

- repo-local bootstrap regression is fixed
- real `_tests` runtime path is fixed
- runtime CI Visibility instrumentation is confirmed with `instrumentTestingM`

## Next Outer-Loop Step

1. commit this latest round
2. repin the `_tests` repo if needed
3. rerun CI and verify the same runtime signals there
