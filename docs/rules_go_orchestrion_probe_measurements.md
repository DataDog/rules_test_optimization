# rules_go Orchestrion Probe Measurements

## Purpose

This note captures the first real timing pass for the vendored
`third_party/rules_go_orchestrion` fork using the probe instrumentation added
to the builder and Orchestrion extension paths.

Unlike
[rules_go_orchestrion_performance_analysis.md](./rules_go_orchestrion_performance_analysis.md),
this document is based on measured local runs, not just code reading.

Measurement date: `2026-03-26`

## Scope And Limits

These measurements came from a local consumer-style run in the sibling fixture
repository:

- workspace:
  `../rules_test_optimization_tests`
- target:
  `//src/go-project:hello_test`
- host Go:
  `1.24.0`
- platform:
  local macOS arm64 machine

This is a useful first baseline, but it is still one machine, one target, and
one cold-start-oriented scenario. The timings below should be treated as
representative local data, not universal constants.

## Probe Collection Setup

Two probe paths were involved:

- extension probes:
  enabled with `log_timing = True` in the local
  `orchestrion.from_source(...)` call in the fixture repo
- builder probes:
  enabled with `RULES_GO_ORCHESTRION_PROBE=1`

The builder probe plumbing also needed one fix before the measurements were
useful:

- the compile, link, and stdlib actions were constructing explicit action
  environments and were not forwarding the probe environment variables into the
  builder process
- after forwarding those variables, successful actions started surfacing probe
  lines in normal Bazel output and mirroring them into a shared probe file

## Commands Used

### Baseline cold run

```bash
GIT_CONFIG_GLOBAL=/dev/null \
GIT_TERMINAL_PROMPT=0 \
PATH=/Users/tony.redondo/sdk/go1.24.0/bin:$PATH \
RULES_GO_ORCHESTRION_PROBE=1 \
./bazelw \
  --output_base=/tmp/rto_phase12_cold/output_base \
  test //src/go-project:hello_test \
  --test_output=streamed \
  --sandbox_debug \
  --subcommands \
  --verbose_failures \
  --action_env=RULES_GO_ORCHESTRION_PROBE=1 \
  --action_env=RULES_GO_ORCHESTRION_PROBE_FILE=/tmp/rto_phase12_cold/builder-probes.log
```

### Phase 1/2 seed run

This run populated the shared helper-decision cache and the shared
module-export cache using the Phase 1/2 code.

```bash
GIT_CONFIG_GLOBAL=/dev/null \
GIT_TERMINAL_PROMPT=0 \
PATH=/Users/tony.redondo/sdk/go1.24.0/bin:$PATH \
RULES_GO_ORCHESTRION_PROBE=1 \
./bazelw \
  --output_base=/tmp/rto_phase12_post_export_seed/output_base \
  test //src/go-project:hello_test \
  --test_output=streamed \
  --sandbox_debug \
  --subcommands \
  --verbose_failures \
  --action_env=RULES_GO_ORCHESTRION_PROBE=1 \
  --action_env=RULES_GO_ORCHESTRION_PROBE_FILE=/tmp/rto_phase12_post_export_seed/builder-probes.log
```

### Phase 1/2 verification run

This is the important verification shape for the first implementation pass:

- keep the decision cache and shared module-export cache warm
- delete only the whole helper-archive bundle
- rerun with a fresh output base
- confirm that helper selection and export resolution are reused on the forced
  helper rebuild path

```bash
rm -rf \
  /var/folders/42/00hrt9gj3276cy8h0_d9nw480000gq/T/datadog-orchestrion-go-cache/cache/rules-go-orchestrion/synthetic-testmain-helpers/5c8037544d53d7ef

GIT_CONFIG_GLOBAL=/dev/null \
GIT_TERMINAL_PROMPT=0 \
PATH=/Users/tony.redondo/sdk/go1.24.0/bin:$PATH \
RULES_GO_ORCHESTRION_PROBE=1 \
./bazelw \
  --output_base=/tmp/rto_phase12_post_export_verify/output_base \
  test //src/go-project:hello_test \
  --test_output=streamed \
  --sandbox_debug \
  --subcommands \
  --verbose_failures \
  --action_env=RULES_GO_ORCHESTRION_PROBE=1 \
  --action_env=RULES_GO_ORCHESTRION_PROBE_FILE=/tmp/rto_phase12_post_export_verify/builder-probes.log
```

### Builder probe log location

The builder now mirrors probe lines into the shared Orchestrion cache root.

On this machine, the measured run wrote to:

```text
/var/folders/42/00hrt9gj3276cy8h0_d9nw480000gq/T/datadog-orchestrion-go-cache/probes/builder-probes.log
```

That exact base path is machine-specific. The important invariant is that the
file lives under the shared `datadog-orchestrion-go-cache/probes/` directory.

## End-To-End Result

The baseline run and the Phase 1/2 verification run both completed
successfully.

Key top-level numbers from the measured runs:

- baseline cold run:
  `430.571s` elapsed, `219.60s` critical path
- Phase 1/2 seed run:
  `334.254s` elapsed, `169.85s` critical path
- Phase 1/2 verification run with helper archive removed:
  `341.734s` elapsed, `163.97s` critical path

The phase timings below are the meaningful comparison point. The Phase 1/2
verification run intentionally forced a helper-archive rebuild, but it kept the
new lower-layer caches available so their reuse behavior could be measured.

## Measured Extension Hotspots

From the cold extension setup pass:

- `extensions.validate_dd_trace_go_versions`:
  about `0.08s`
- `extensions.download_and_extract`:
  about `21-22s`
- `extensions.go_mod_edit`:
  about `8-9s`
- `extensions.go_mod_tidy`:
  about `96-104s`
- `extensions.go_build`:
  about `32-41s`
- `extensions.orchestrion_build_total`:
  about `160-176s`

### Extension Conclusion

The biggest startup cost before normal Bazel Go actions even begin is the
temporary Orchestrion module preparation and binary build.

The largest single measured phase in that area is `go mod tidy`.

## Bootstrap Cache Pass

The next optimization pass focused only on the Orchestrion bootstrap path in
`go/private/orchestrion/extensions.bzl`.

### What changed

This pass added:

- a host-side bootstrap artifact cache for the built Orchestrion binary and its
  `dd_trace_go_versions.json`
- stable host-side `GOMODCACHE` and `GOCACHE` roots under the shared
  `datadog-orchestrion-go-cache`
- a bootstrap cache key that includes:
  - Orchestrion version
  - normalized `dd_trace_go_versions`
  - host Go identity
  - cache ABI version
  - manual patchset identifier
- a fast path that reuses the cached bootstrap artifact on a cache hit
- a fallback path that still runs `go mod tidy` only when the first build says
  the module graph is not ready
- Starlark unit tests for the retry classifier and bootstrap cache-key
  stability

### Commands used for the bootstrap-only pass

Cold verification:

```bash
BASE=/tmp/rto_bootstrap_eval7
rm -rf "$BASE"
mkdir -p "$BASE/cold" "$BASE/warm" "$BASE/cache_home"

cd ../rules_test_optimization_tests
source "$HOME/ddtrace.sh" >/dev/null 2>&1 || true

PATH=/Users/tony.redondo/sdk/go1.24.0/bin:$PATH \
RULES_GO_ORCHESTRION_PROBE=1 \
XDG_CACHE_HOME="$BASE/cache_home" \
RULES_GO_ORCHESTRION_PROBE_FILE="$BASE/cold/builder-probes.log" \
./bazelw \
  --output_base="$BASE/cold/output_base" \
  build //src/go-project:hello_test \
  --subcommands \
  --verbose_failures \
  >"$BASE/cold/run.log" 2>&1
```

Warm verification:

```bash
cd ../rules_test_optimization_tests
source "$HOME/ddtrace.sh" >/dev/null 2>&1 || true

PATH=/Users/tony.redondo/sdk/go1.24.0/bin:$PATH \
RULES_GO_ORCHESTRION_PROBE=1 \
XDG_CACHE_HOME=/tmp/rto_bootstrap_eval7/cache_home \
RULES_GO_ORCHESTRION_PROBE_FILE=/tmp/rto_bootstrap_eval7/warm/builder-probes.log \
./bazelw \
  --output_base=/tmp/rto_bootstrap_eval7/warm/output_base \
  build //src/go-project:hello_test \
  --subcommands \
  --verbose_failures \
  >/tmp/rto_bootstrap_eval7/warm/run.log 2>&1
```

### Bootstrap cache result

The best measured bootstrap variant kept three things:

- the host-side bootstrap artifact cache
- the persistent host-side Go caches
- `go mod tidy` as a fallback instead of as an unconditional step

Measured result from that kept variant:

- cold bootstrap:
  - `extensions.download_and_extract`: `21.907s`
  - `extensions.go_mod_edit`: `9.831s`
  - `extensions.go_mod_download`: `53.575s`
  - `extensions.go_build_initial`: `55.091s` with fallback
  - `extensions.go_mod_tidy`: `30.131s`
  - `extensions.go_build_retry`: `37.981s`
  - `extensions.orchestrion_build_total`: `216.628s`
  - end-to-end build: `305.653s` elapsed
- warm bootstrap:
  - `extensions.bootstrap_cache_hit`: yes
  - `extensions.orchestrion_build_total`: `3.097s`
  - no `download_and_extract`, `go_mod_edit`, `go_mod_download`,
    `go_mod_tidy`, or `go_build` phases executed on the hit
  - end-to-end build: `91.957s` elapsed

### Bootstrap pass conclusion

This pass clearly improved warm bootstrap reuse. The host-side bootstrap cache
removes almost all of the repeated Orchestrion setup cost across fresh Bazel
output bases.

It did **not** achieve the hoped-for cold-start reduction yet. Several follow-up
experiments were measured locally, including:

- using `go build -mod=mod` on the first build
- skipping the explicit tracer-module download

Those experiments made the cold bootstrap slower on this machine, so they were
not kept.

The practical outcome is:

- warm bootstrap reuse is now real and large
- cold bootstrap is still expensive
- the next extension-focused pass should look for a better way to prepare the
  Orchestrion module graph without paying for both a large module download and a
  later rebuild

## Phase 0 Measurement Gates

The first implementation pass used these measured gates:

- `compilepkg.compile_synthetic_testmain_source_packages`
- `importcfg.resolve_module_exports_for_packages.go_list_export_deps`
- `builder.stdlib`
- `extensions.go_mod_tidy`

The target outcomes for this pass were:

- synthetic testmain cold path:
  major reduction
- export resolution:
  major reduction
- stdlib:
  moderate improvement if the cache-key cleanup also helped there
- extension bootstrap:
  observe, but do not optimize yet

## Measured Builder Hotspots

The Phase 1/2 verification builder probe log contained `3550` structured
timing lines.

### Baseline builder phases

- `builder.compilepkg` for the synthetic testmain action:
  `134179 ms`
- `compilepkg.compile_synthetic_testmain_source_packages`:
  `132384 ms`
- `importcfg.resolve_module_exports_for_packages.go_list_export_deps`:
  `18848 ms`
- `builder.stdlib`:
  `52907 ms`
- `extensions.go_mod_tidy`:
  `127946 ms`

### Phase 1/2 verification builder phases

- `builder.compilepkg` for the synthetic testmain action:
  `81538 ms`
- `compilepkg.compile_synthetic_testmain_source_packages`:
  `79321 ms`
- `builder.link`:
  `3582 ms`
- `builder.stdlib`:
  `45097 ms`
- `extensions.go_mod_tidy`:
  `98580 ms`

### Important synthetic testmain sub-phases after Phase 1/2

The synthetic testmain path is not slow because the final compile command is
slow. It is slow because a large amount of helper-package preparation happens
before the final compile is attempted.

Important measured phases from the testmain action:

- `compilepkg.synthetic_testmain_helper_cache_miss`:
  intentionally forced by deleting only the helper-archive bundle
- `compilepkg.synthetic_testmain_helper_decision_cache_hit`:
  confirmed reuse of the persisted helper decision graph
- `importcfg.resolve_module_exports_for_packages.cache_hit`:
  confirmed reuse of the shared module-export cache
- `importcfg.resolve_module_exports_for_packages.go_list_export_deps`:
  not executed on the verification run
- `compilepkg.compile_synthetic_testmain_source_packages`:
  `79321 ms`
- final `compilepkg.compile_go_action.run_command` for the main synthetic
  `testmain` package:
  `1343 ms`

### Builder Conclusion

The builder-side bottleneck is dominated by synthetic testmain helper
preparation, not by the final compile or link command.

The stdlib path is also expensive, but it is clearly smaller than the synthetic
testmain helper path in this measured scenario.

The important change from this first optimization pass is that the expensive
export-discovery work is no longer being repeated during a forced helper-bundle
rebuild. The remaining cost is mostly real source compilation for the selected
helper closure.

## Phase 1 And Phase 2 Implementation Result

The first implementation pass did three concrete things:

1. It made the cache keys stable across fresh Bazel output bases.
2. It persisted the synthetic helper decision graph separately from the whole
   helper-archive bundle.
3. It persisted the resolved module-export map under a shared request-keyed
   cache so equivalent helper rebuilds can skip `go list -export -deps`.

The measured result is:

- synthetic helper source-package time dropped from `132.4s` to `79.3s`
  on the forced helper rebuild path
- that is about a `40.1%` reduction
- synthetic testmain `builder.compilepkg` time dropped from `134.2s` to
  `81.5s`
- that is about a `39.2%` reduction
- `importcfg.resolve_module_exports_for_packages.go_list_export_deps` went
  from `18.8s` in the baseline run to not executing at all in the verification
  run because the shared export cache hit
- `builder.stdlib` improved from `52.9s` to `45.1s`
  in the verification run, which is about a `14.8%` reduction

These numbers do not mean the whole build is solved. They do show that the
Phase 1/2 cache reuse is real and materially changes the synthetic helper
rebuild path.

## What The Measurements Changed

Before measuring, the likely hot paths were:

- Orchestrion bootstrap/setup
- stdlib weaving
- synthetic testmain handling
- repeated importcfg rewrites and export discovery

After the baseline pass, the priority order was:

1. synthetic testmain helper preparation
2. Orchestrion extension `go mod tidy`
3. stdlib install plus export persistence/sync
4. repeated export discovery through `go list -export -deps`

After the first implementation pass, the priority order is now:

1. remaining synthetic helper source compilation
2. Orchestrion extension `go mod tidy`
3. stdlib install plus export persistence/sync
4. repeated woven dependency probing

That means the next pass should continue on the synthetic helper source
compilation logic itself, not go back to export resolution for this path.

## First-Pass Answers

### Why are so many helper packages compiled on a cold miss?

Because the synthetic testmain path does not stop at the small fixed Datadog
root helper set.

The flow in
[compilepkg.go](../third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go)
starts from:

- `syntheticTestmainRootPackages`
- `orchestrionLinkClosurePackages`

Then `compileSyntheticTestmainSourcePackages(...)` expands that into a larger
source-compiled closure by:

- loading dependency metadata with `go list -deps -json`
- recursively classifying packages in
  `packageNeedsSyntheticSourceCompile(...)`
- recursively compiling selected packages in
  `compileSyntheticTestmainSourcePackage(...)`

The recursive selection rule is the key detail. A package is pulled into source
compilation when it:

- is already in the root set
- depends on another package that needs source compilation
- or imports certain stdlib packages such as `flag`, `log`, `log/slog`,
  `net/http`, `os`, `os/exec`, or `testing`

So the cold miss is not “compile a few helper packages”. It becomes “compile a
large transitive non-cgo helper ecosystem that must remain source-compatible in
the synthetic module”.

That matches the measured run: the expensive packages were not only the obvious
Datadog roots. They also included deeper transitive packages such as:

- `github.com/DataDog/dd-trace-go/v2/ddtrace/mocktracer`
- `github.com/DataDog/datadog-agent/pkg/trace/stats`
- `google.golang.org/protobuf/runtime/protoimpl`

### Which helper-package results can be reused more aggressively?

Some reuse already exists, but it is coarse.

The current persistent helper cache in
`compileSyntheticTestmainSourcePackages(...)` already stores:

- compiled helper interface archives
- compiled helper link archives
- helper link closures

That cache is shared across similar actions because its key depends on things
like:

- configured `dd-trace-go` versions
- SDK path
- install suffix
- woven stdlib key
- Orchestrion version

What is reused more aggressively after Phase 1/2:

- package metadata from `loadModulePackageMetadataBatch(...)`
- recursive source-compile decisions from
  `packageNeedsSyntheticSourceCompile(...)`
- external export resolution done during a helper-cache miss
- the whole helper bundle when its top-level cache key matches

What is still not reused aggressively enough today:

- individual helper package compile results outside the whole-bundle helper
  cache
- the remaining real source compilation work inside a forced helper-bundle
  rebuild

So the strongest reuse opportunities are:

- consider finer-grained per-helper-package reuse if the coarse whole-bundle
  cache is still too expensive on misses
- reduce how many packages need to be source-compiled in the first place

### Can `resolve_module_exports_for_packages` be cached across similar actions?

Yes.

The code already has most of the right key material through
`moduleExportRequestKey(...)` in
[importcfg.go](../third_party/rules_go_orchestrion/go/tools/builders/importcfg.go).

That key already includes:

- helper export cache ABI version
- Orchestrion version identity
- SDK path
- install suffix
- whether the module root is synthetic or real
- digests of `go.mod`, `go.sum`, `orchestrion.tool.go`, and `orchestrion.yml`
- a woven stdlib cache key

Before this pass, the synthetic cold-miss path did not reuse that aggressively
because it called `resolveModuleExportsForPackagesWithRoot(...)` with a forced
temporary export root under the helper-cache temp directory. That bypassed the
stable shared `module-exports/<requestKey>` cache root used by the normal path.

Yes, and this pass now proves it in the measured fixture run.

The verification run intentionally removed only the whole helper-archive bundle
and kept the lower-layer caches warm. The resulting probe lines showed:

- helper archive cache miss
- helper decision cache hit
- module export cache hit
- no `go list -export -deps` execution for
  `resolve_module_exports_for_packages`

So the direct answer is no longer theoretical. The result now survives across
similar synthetic testmain actions when the shared cache key matches.

## Next Ranked Optimization Plan

### 1. Keep attacking synthetic testmain helper preparation

This is the clearest builder hotspot.

Specific focus areas now:

- reduce the remaining real source compilation inside
  `compilepkg.compile_synthetic_testmain_source_packages`
- identify whether some helper packages can be precompiled or reused more
  granularly without changing behavior
- investigate whether the selected helper closure can be narrowed safely for
  common testmain shapes

### 2. Reduce extension-side `go mod tidy` cost

This is the largest measured startup phase before the Go actions even begin.

Specific focus areas:

- understand why `go mod tidy` does so much Git/network work on cold setup
- determine whether the temporary module can be prepared with less work than a
  full tidy
- investigate whether a more reusable cache layout can avoid paying this cost
  repeatedly in local runs

### 3. Reduce stdlib export persistence and cache sync work

The stdlib action is not just expensive because of installation. A large amount
of time is spent persisting and copying export data after the install.

Specific focus areas:

- `stdlib.persist_orchestrion_stdlib_exports`
- `stdlib.sync_persisted_exports_to_cache`
- `importcfg.resolve_cache_stdlib_exports_at.go_list_export_deps`

### 4. Reduce repeated woven dependency probing

Multiple phases repeatedly run `ensure_woven_packages_available` and related
`go list` probes.

The per-call cost is smaller than the biggest hotspots, but it appears in many
places and may add up significantly across larger builds.

## Verification Performed

The first implementation pass was verified with:

- the baseline fixture run in `../rules_test_optimization_tests`
- a seed run that populated the new caches
- a verification run that deleted only the helper-archive bundle and confirmed
  lower-layer cache reuse
- focused builder tests in this repo:
  `./bazelw test @rules_go//go/tools/builders:{compilepkg_test,importcfg_test,probe_test,orchestrion_test}`

All of those checks passed locally.

## Practical Next Steps

The next optimization pass should start with the synthetic testmain path in:

- `go/tools/builders/compilepkg.go`
- `go/tools/builders/importcfg.go`

The first concrete questions to answer are:

- why are so many helper packages being compiled on a cold miss?
- which of those helper package results can be reused more aggressively?
- can the `resolve_module_exports_for_packages` result be cached in a way that
  survives across similar testmain actions?

The second optimization pass should then focus on:

- `go/private/orchestrion/extensions.bzl`
- `go/tools/builders/stdlib.go`
- `go/tools/builders/orchestrion.go`

## Related References

- [docs/rules_go_orchestrion_performance_analysis.md](./rules_go_orchestrion_performance_analysis.md)
- [third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go](../third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go)
- [third_party/rules_go_orchestrion/go/tools/builders/importcfg.go](../third_party/rules_go_orchestrion/go/tools/builders/importcfg.go)
- [third_party/rules_go_orchestrion/go/tools/builders/stdlib.go](../third_party/rules_go_orchestrion/go/tools/builders/stdlib.go)
- [third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go](../third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go)
- [third_party/rules_go_orchestrion/go/private/orchestrion/extensions.bzl](../third_party/rules_go_orchestrion/go/private/orchestrion/extensions.bzl)
