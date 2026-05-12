<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# rules_go Orchestrion Fork Performance Analysis

> Scope note: this document analyzes the generic base variant under
> `third_party/rules_go_orchestrion_base`. Consumers that need the extended
> monorepo compatibility layer use `third_party/rules_go_orchestrion_complete`.

## Purpose

This document captures a code-reading analysis of the vendored
`third_party/rules_go_orchestrion_base` fork and explains:

- what was changed to make Orchestrion work under Bazel and `rules_go`
- which parts of the implementation are likely on the performance hot path
- which costs appear inherent to Orchestrion's design
- which extra costs appear to come from this fork's integration work
- which optimization directions look most promising

This is a maintainer note for future reference.

This document is intentionally historical. It reflects the code-reading view
from `2026-03-25`, before the later measured bootstrap changes on this branch.

For the current state:

- use [go_orchestrion_maintainer_state.md](./go_orchestrion_maintainer_state.md)
  for the maintained summary
- use [rules_go_orchestrion_probe_measurements.md](./rules_go_orchestrion_probe_measurements.md)
  for the measured results and later rollbacks

## Scope And Limits

This analysis is based on:

- the checked-in fork metadata and changed-files report
- the vendored fork source under `third_party/rules_go_orchestrion_base/`
- Datadog's public Orchestrion documentation
- the public Orchestrion source entrypoint

This analysis is not based on runtime benchmarking or profiling.

Any statements about likely bottlenecks are informed engineering inferences from
the code, not measured timings.

Analysis date: `2026-03-25`

## Primary References

- [third_party/rules_go_orchestrion_base.METADATA.json](../third_party/rules_go_orchestrion_base.METADATA.json)
- [third_party/rules_go_orchestrion_base.CHANGED_FILES.md](../third_party/rules_go_orchestrion_base.CHANGED_FILES.md)
- [third_party/rules_go_orchestrion_base/go/private/orchestrion/extensions.bzl](../third_party/rules_go_orchestrion_base/go/private/orchestrion/extensions.bzl)
- [third_party/rules_go_orchestrion_base/go/private/context.bzl](../third_party/rules_go_orchestrion_base/go/private/context.bzl)
- [third_party/rules_go_orchestrion_base/go/private/actions/compilepkg.bzl](../third_party/rules_go_orchestrion_base/go/private/actions/compilepkg.bzl)
- [third_party/rules_go_orchestrion_base/go/private/actions/link.bzl](../third_party/rules_go_orchestrion_base/go/private/actions/link.bzl)
- [third_party/rules_go_orchestrion_base/go/private/actions/stdlib.bzl](../third_party/rules_go_orchestrion_base/go/private/actions/stdlib.bzl)
- [third_party/rules_go_orchestrion_base/go/tools/builders/orchestrion.go](../third_party/rules_go_orchestrion_base/go/tools/builders/orchestrion.go)
- [third_party/rules_go_orchestrion_base/go/tools/builders/compilepkg.go](../third_party/rules_go_orchestrion_base/go/tools/builders/compilepkg.go)
- [third_party/rules_go_orchestrion_base/go/tools/builders/importcfg.go](../third_party/rules_go_orchestrion_base/go/tools/builders/importcfg.go)
- [third_party/rules_go_orchestrion_base/go/tools/builders/link.go](../third_party/rules_go_orchestrion_base/go/tools/builders/link.go)
- [third_party/rules_go_orchestrion_base/go/tools/builders/stdlib.go](../third_party/rules_go_orchestrion_base/go/tools/builders/stdlib.go)
- [Orchestrion docs](https://datadoghq.dev/orchestrion/)
- [Orchestrion contributor guide](https://datadoghq.dev/orchestrion/contributing/)
- [Orchestrion main.go](https://github.com/DataDog/orchestrion/blob/main/main.go)

## High-Level Conclusion

The fork is deep, not a thin wrapper.

At the time of this analysis, the fork was already deep and touched dozens of
paths against upstream `rules_go v0.60.0`, including:

- module extension setup for Orchestrion
- `rules_go` analysis-time context wiring
- compile, link, and stdlib action definitions
- the Go builder implementation used by those actions
- synthetic `testmain` handling
- stdlib cache handling

That means performance issues are very likely coming from the normal build hot
path, not from one isolated bootstrap helper.

## What Changed To Make Orchestrion Work

### 1. A custom Orchestrion binary is built during module/repository resolution

The fork adds a dedicated module-extension layer in
[go/private/orchestrion/extensions.bzl](../third_party/rules_go_orchestrion_base/go/private/orchestrion/extensions.bzl).

At the time of this analysis, that layer:

- validates the configured `dd-trace-go` versions
- resolves package/module versions up front
- downloads the Orchestrion source
- patches upstream files for Bazel compatibility
- builds the Orchestrion binary used later by the toolchain

This is a fetch-time cost, not a per-compile cost, but it is part of the total
integration overhead.

Later work on this branch removed the extension/bootstrap rewrite and tidy of
the downloaded Orchestrion repo's own `go.mod`. See the maintainer-state and
probe measurement docs for that newer design and for the remaining builder-side
synthetic-module work.

### 2. Orchestrion is threaded through `rules_go` itself

The fork does not treat Orchestrion as an external post-process.

Instead, it modifies `rules_go` internals so the toolchain knows about:

- the Orchestrion binary
- the Orchestrion version file
- when compile, link, and stdlib actions should pass `-orchestrion`
- which extra inputs must be staged for Orchestrion to work in a Bazel sandbox

This starts in
[go/private/context.bzl](../third_party/rules_go_orchestrion_base/go/private/context.bzl#L705)
where `GoContextInfo` gains Orchestrion-related fields that become available to
common Go actions.

### 3. Compile, link, and stdlib actions are widened

When Orchestrion is enabled, the action wrappers add:

- the Orchestrion binary
- the Orchestrion version file
- the `go` binary
- the Go SDK source tree
- staged rule `data` files such as `go.mod`, `go.sum`, `orchestrion.tool.go`,
  and `orchestrion.yml`

Relevant entry points:

- [compilepkg.bzl](../third_party/rules_go_orchestrion_base/go/private/actions/compilepkg.bzl#L215)
- [link.bzl](../third_party/rules_go_orchestrion_base/go/private/actions/link.bzl#L204)
- [stdlib.bzl](../third_party/rules_go_orchestrion_base/go/private/actions/stdlib.bzl#L179)

This is necessary because Orchestrion shells out to `go` and expects a Go
module-shaped environment, even under Bazel sandboxing.

### 4. The builder wraps real Go tools with `orchestrion toolexec`

The builder runtime in
[env.go](../third_party/rules_go_orchestrion_base/go/tools/builders/env.go#L144)
switches from direct tool execution to:

```text
orchestrion toolexec <go-tool> ...
```

It also injects:

- `TOOLEXEC_IMPORTPATH`
- jobserver state
- compatible cache-related environment variables

This matches Orchestrion's own public model: its CLI documentation says it
instruments code by interfacing with the Go toolchain through `-toolexec`.

### 5. The fork adds Bazel-specific support for synthetic testmain and stdlib weaving

Two areas clearly required extra integration work:

- synthetic Bazel `testmain` archives must include Datadog helper packages and
  their transitive link closure
- stdlib weaving must produce cacheable, importcfg-compatible archives that
  later compile and link actions can consume consistently

Those behaviors live mostly in:

- [compilepkg.go](../third_party/rules_go_orchestrion_base/go/tools/builders/compilepkg.go#L596)
- [link.go](../third_party/rules_go_orchestrion_base/go/tools/builders/link.go#L123)
- [stdlib.go](../third_party/rules_go_orchestrion_base/go/tools/builders/stdlib.go#L43)
- [importcfg.go](../third_party/rules_go_orchestrion_base/go/tools/builders/importcfg.go)

## Likely Performance Hot Paths

### 1. Per-action jobserver startup and dependency warmup

The strongest suspected hot path is repeated jobserver and dependency setup in
[orchestrion.go](../third_party/rules_go_orchestrion_base/go/tools/builders/orchestrion.go).

The relevant behavior is:

- compile actions start an Orchestrion jobserver
- most link actions do the same
- stdlib weaving does the same
- startup may call `ensureWovenPackagesAvailable(...)`
- that helper may run `go list`, then `go mod download`, then `go list` again

This suggests real work may happen before the actual compile or link step
starts.

The code does not obviously show a long-lived shared jobserver across Bazel
actions. If each action pays startup and warmup costs independently, that can
be expensive.

### 2. Repeated temporary module preparation

The next likely hotspot is `ensureGoModExists(...)` in
[orchestrion.go](../third_party/rules_go_orchestrion_base/go/tools/builders/orchestrion.go#L268).

It may:

- copy `go.mod` and `go.sum` into the current working directory
- copy or synthesize `orchestrion.tool.go`
- copy `orchestrion.yml`
- validate resolved `dd-trace-go` versions
- restore or prepare a synthetic module state
- run module-resolution-related commands on cache miss

This logic is touched by compile, link, and stdlib paths, so repeated setup
cost here can become multiplicative.

### 3. Importcfg rewriting and export discovery

The importcfg path in
[importcfg.go](../third_party/rules_go_orchestrion_base/go/tools/builders/importcfg.go#L565)
looks expensive because it repeatedly resolves export archives through
`go list -export -deps`.

The code suggests multiple layers of work:

- resolve exports for Datadog helper/module packages
- rewrite stdlib entries toward Orchestrion-aware caches
- sanitize archives that contain `link.deps`
- use closure-driven cache rewrites that may resolve overlapping package sets

This area is especially suspicious because repeated `go list -export -deps`
calls can be costly even if compilation itself is cached.

### 4. Synthetic testmain cold-miss behavior

Synthetic testmain support in
[compilepkg.go](../third_party/rules_go_orchestrion_base/go/tools/builders/compilepkg.go#L596)
looks like a major cold-path cost.

When cache misses happen, the code may:

- prepare a synthetic module
- run `go list -deps -json`
- decide which helper packages need source compilation
- resolve external exports
- compile helper packages one by one
- write manifests and sanitized helper archives

There is persistent caching here, but cold misses are likely expensive enough
to deserve separate attention from ordinary package compilation.

### 5. Stdlib weaving cache sync and duplicate archive copying

The stdlib path appears to have the largest I/O footprint.

After weaving, `persistOrchestrionStdlibExports(...)` and related helpers in
[stdlib.go](../third_party/rules_go_orchestrion_base/go/tools/builders/stdlib.go#L338):

- walk the stdlib archive tree
- copy archives into a persisted export tree
- write a manifest
- copy them back or sync them into other cache locations

That is a lot of duplicate file traffic and is a strong candidate for both
wall-clock time and cache churn.

### 6. Action input expansion and sandbox materialization

The Starlark action wrappers now add `sdk.srcs` plus staged module files for
Orchestrion-enabled actions.

That likely increases:

- sandbox input materialization cost
- action invalidation surface
- remote cache key sensitivity

This may not be the biggest cost by itself, but it broadens the amount of work
each action has to carry.

## Costs That Look Inherent Versus Integration-Specific

### Costs that appear inherent to Orchestrion's model

- Using `-toolexec` to intercept compile-time tool execution
- AST rewrite work done by Orchestrion itself
- some level of module-aware configuration discovery
- some stdlib weaving cost when instrumentation requires woven stdlib packages

These are part of how Orchestrion works, based on its public documentation.

### Costs that appear to come from this fork's integration strategy

- repeated synthetic module setup inside Bazel actions
- repeated `go list` / `go mod download` warmup before actions
- repeated export discovery through importcfg rewrite helpers
- synthetic testmain helper compilation and manifest plumbing
- duplicate stdlib archive copying across cache layers
- widened action inputs to support sandboxed Orchestrion execution

These are the first places to look for optimization because they may be
reducible without changing Orchestrion's core functionality.

## Most Promising Optimization Directions

### 1. Measure setup costs separately from rewrite costs

The first profiling target should be the code we add around Orchestrion, not
just Orchestrion itself.

The most useful timings to collect are:

- jobserver startup time
- woven-package warmup time
- synthetic module restore/prepare time
- importcfg export-resolution time
- synthetic testmain helper build time
- stdlib cache persistence/sync time

Without that separation, it will be too easy to blame Orchestrion broadly for
costs that actually come from the fork.

### 2. Reduce repeated module/export discovery

The importcfg and synthetic-module helpers appear to repeat similar discovery
work.

The best medium-term opportunity may be:

- batch export resolution more aggressively
- reduce repeated `go list -export -deps` calls
- share more prepared module state across actions

### 3. Treat synthetic testmain as its own optimization problem

Synthetic testmain support is specialized enough that it should probably be
optimized separately.

Its cold path is complex and may dominate test builds even if ordinary package
compilation is reasonably cached.

### 4. Reduce duplicate stdlib archive copying

If the cache layout can be simplified without breaking correctness, the stdlib
path looks like a good place to remove unnecessary I/O.

### 5. Narrow Orchestrion action inputs where possible

If the builder does not actually need the full SDK source tree or all staged
module files for every action, tightening those inputs could reduce sandbox and
cache pressure.

## Practical Takeaway

The strongest current hypothesis is:

1. Orchestrion itself is not the only reason the fork is slow.
2. The fork is paying substantial repeated setup cost outside the actual source
   rewriting phase.
3. The highest-probability bottlenecks are jobserver bootstrap, synthetic
   module preparation, export discovery, synthetic testmain cold misses, and
   stdlib cache synchronization.

That means the next step should not be a blind rewrite.

It should be a focused profiling pass that instruments these specific fork-side
helpers so measured time can be assigned to:

- Orchestrion proper
- our builder/setup code
- synthetic testmain support
- stdlib weaving/cache sync

## Verification

This document was produced by:

- reading the checked-in fork metadata and changed-files report
- reading the Starlark action wiring
- reading the builder/runtime implementation in the vendored fork
- checking Datadog's public Orchestrion docs and public source entrypoint

This document was not produced by:

- benchmarking the fork
- capturing CPU profiles
- measuring Bazel action timing
- comparing live timings against upstream `rules_go`

Use this as a map for profiling and optimization work, not as proof of actual
runtime percentages.
