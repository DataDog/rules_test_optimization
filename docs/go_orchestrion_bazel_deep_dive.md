# Go + Orchestrion + Bazel Deep Dive

## Purpose

This document explains, in detail, how Go compile-time instrumentation works in this repository through:

- the Go companion module
- the vendored `rules_go` fork under `third_party/rules_go_orchestrion`
- Datadog Orchestrion
- Bazel test execution

It also explains the multi-day debugging effort that led to the final working implementation, which changes were essential, and why the final fix was harder than it initially looked.

This is the engineering record for the Orchestrion integration work.

## Executive Summary

We wanted `dd_topt_go_test` to behave like a normal `rules_go` test target while also enabling Datadog Orchestrion so that:

- application code is instrumented
- dependencies are instrumented
- the Go standard library is instrumented
- CI Visibility hooks around `testing` are active in the final Bazel-built test binary

The hard part was not merely enabling Orchestrion at compile time. We succeeded at that relatively early. The hard part was preserving a coherent archive/packagefile universe all the way through:

- stdlib compilation
- user package compilation
- synthetic Bazel `testmain` compilation
- final link

The final issue turned out to be a **synthetic link consistency problem**, not just “Orchestrion is disabled”.

The changes that ultimately fixed the integration were:

1. moving synthetic Datadog helper metadata out of the `~testmain.a` archive into a sidecar file
2. threading that sidecar through Bazel as a declared input to final `GoLink`
3. making final synthetic link reuse the **same helper-export family** created during synthetic `testmain` compile instead of regenerating a second one

That is what restored:

- runtime tracer logs
- `instrumentTestingTFunc`
- `instrumentTestingM`

in the real `_tests` repository flow and in CI.

## Scope

This document focuses on the Go integration path implemented across:

- [modules/go/topt_go_test.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/topt_go_test.bzl)
- [modules/go/topt_go_orchestrion.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/topt_go_orchestrion.bzl)
- [modules/go/tools/dd_topt_go_bootstrap/main.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/tools/dd_topt_go_bootstrap/main.go)
- [third_party/rules_go_orchestrion](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion)

It does not try to explain the entire repository. It assumes familiarity with:

- Bazel
- `rules_go`
- Starlark rules/macros
- Datadog CI Visibility at a high level

## Terminology

- **Core module**: `datadog-rules-test-optimization`
- **Go companion**: `datadog-rules-test-optimization-go`
- **Sync repo**: the generated repository containing Datadog metadata and exported labels such as `@test_optimization_data//:export.bzl`
- **Raw test target**: the hidden `go_test` emitted by `dd_topt_go_test`
- **Wrapper target**: the public transitioned test target emitted by `dd_topt_go_test`
- **Orchestrion**: Datadog compile-time instrumentation tool for Go
- **Synthetic testmain**: the Bazel-generated `testmain.go` package compiled for `rules_go` tests

## Repository Topology

### User-facing entry points

- [modules/go/topt_go_test.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/topt_go_test.bzl)
- [modules/go/topt_go_orchestrion.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/topt_go_orchestrion.bzl)
- [modules/go/tools/dd_topt_go_bootstrap/main.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/tools/dd_topt_go_bootstrap/main.go)

### Vendored toolchain implementation

- [third_party/rules_go_orchestrion/go/private/actions/archive.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/private/actions/archive.bzl)
- [third_party/rules_go_orchestrion/go/private/actions/compilepkg.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/private/actions/compilepkg.bzl)
- [third_party/rules_go_orchestrion/go/private/actions/link.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/private/actions/link.bzl)
- [third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go)
- [third_party/rules_go_orchestrion/go/tools/builders/importcfg.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/importcfg.go)
- [third_party/rules_go_orchestrion/go/tools/builders/link.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/link.go)
- [third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go)
- [third_party/rules_go_orchestrion/go/tools/builders/stdliblist.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/stdliblist.go)

## High-Level Architecture

### Design Intent

The public Go API remains a Bazel-native macro:

- the user writes `dd_topt_go_test(...)`
- Bazel still owns test scheduling, hermetic execution, and test output collection
- Datadog metadata still comes from the generated sync repo

But the actual compile path is Orchestrion-enabled through a transitioned wrapper target and a vendored `rules_go` toolchain that knows how to invoke Orchestrion coherently.

### Flow Diagram

```mermaid
flowchart TD
    A[MODULE.bazel] --> B[test_optimization_go_extension]
    B --> C[@test_optimization_data_go]
    A --> D[dd_topt_go_bootstrap]
    D --> E[orchestrion pin artifacts]
    D --> F[rules_go orchestrion extension wiring]

    G[BUILD: dd_topt_go_test] --> H[hidden raw go_test]
    G --> I[public orch_go_test wrapper]
    I --> J[function transition: orchestrion enabled]
    J --> H

    H --> K[rules_go compilepkg/link/stdlib actions]
    K --> L[orchestrion toolexec]
    L --> M[woven stdlib + user packages + synthetic testmain]
    M --> N[final Bazel test binary]
    N --> O[CI Visibility runtime logs and payloads]
```

## User-Facing Flow

### 1. Module setup

The user enables the Go extension and creates a generated metadata repository through:

- [README.md](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/README.md)
- [modules/go/MODULE.bazel](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/MODULE.bazel)

The Go-specific extension configures:

- sync repo generation
- Orchestrion repository wiring
- Go runtime metadata

### 2. Bootstrap

The bootstrap helper:

- updates `MODULE.bazel`
- points `rules_go` at the vendored module
- enables `@rules_go//go:extensions.bzl` Orchestrion extension
- runs `orchestrion pin`
- writes or patches:
  - `go.mod`
  - `go.sum`
  - `orchestrion.tool.go`
  - `orchestrion.yml`

Relevant implementation:

- [modules/go/tools/dd_topt_go_bootstrap/main.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/tools/dd_topt_go_bootstrap/main.go)

### 3. Macro expansion

`dd_topt_go_test` creates:

- a hidden raw `go_test`
- a public wrapper test target

The wrapper applies a transition that sets:

- `@rules_go//go/private/orchestrion:enabled = True`

Relevant implementation:

- [modules/go/topt_go_test.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/topt_go_test.bzl)
- [modules/go/topt_go_orchestrion.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/topt_go_orchestrion.bzl)

### 4. Vendored toolchain execution

When the transitioned raw target builds, the vendored `rules_go` implementation:

- enables Orchestrion in compile/link flows
- stages pin files
- manages synthetic module state
- rebuilds stdlib where needed
- compiles Bazel synthetic `testmain`
- links the final test binary

## Public Macro Behavior

### `dd_topt_go_test`

The macro in [topt_go_test.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/topt_go_test.bzl):

- resolves the correct Datadog service
- normalizes user `data`
- infers module labels via `importpath` / `embed`
- appends Orchestrion pin files as hidden data:
  - `go.mod`
  - `go.sum`
  - `orchestrion.tool.go`
  - `orchestrion.yml`
- creates a raw `go_test`
- creates a public `orch_go_test` wrapper

That means the user does not manually wire Orchestrion files into the test rule. The macro takes ownership of that.

### `orch_go_test`

The wrapper rule in [topt_go_orchestrion.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/topt_go_orchestrion.bzl):

- applies the Orchestrion transition
- forwards executable and runfiles
- preserves `.exe` on Windows

The Windows preservation fix matters because otherwise Bazel would produce an extensionless wrapper executable name on Windows and test execution would fail.

## Why a Vendored `rules_go` Was Needed

Orchestrion is fundamentally a `toolexec`-style compile-time tool.

In standard Go usage, the mental model is:

```text
go test -toolexec="orchestrion toolexec"
```

But `rules_go` does not expose a simple public seam equivalent to “attach `toolexec` everywhere and let the normal Go toolchain handle the rest”.

Because of that, the integration required a patched toolchain that could:

- enable Orchestrion across package compile
- enable Orchestrion across stdlib compile
- carry synthetic-module state
- preserve archive consistency across compile and link

That is why we vendored:

- [third_party/rules_go_orchestrion](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion)

instead of depending on an external personal fork at runtime.

## How the Vendored Toolchain Works

### Compile path

At compile time:

1. `archive.bzl` declares outputs for a package archive and, for synthetic testmain, a sidecar Orchestrion manifest.
2. `compilepkg.bzl` passes those outputs into the builder.
3. `compilepkg.go` compiles the package, and for synthetic testmain writes a sidecar file that records the Datadog helper packagefile selections used during compile.

This is one of the final key fixes.

### Link path

At link time:

1. `link.bzl` declares the sidecar manifest as an input to `GoLink`.
2. `link.go` loads the sidecar for synthetic testmain.
3. `link.go` reuses the compile-time helper packagefile family from the sidecar.
4. `link.go` completes the broader Datadog helper closure from the **same** helper-export root.

This prevents link-time regeneration from drifting into a second archive family.

### Importcfg rewriting

[importcfg.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/importcfg.go) is the core consistency layer.

Its responsibilities include:

- resolving stdlib packagefiles
- resolving Datadog helper packagefiles
- loading persisted stdlib export manifests
- sanitizing module-export archives into `.nolinkdeps` variants
- rewriting final synthetic importcfg entries coherently

This file is where most of the “archive family drift” problems surfaced.

### Orchestrion helper/bootstrap logic

[orchestrion.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go) handles:

- synthetic module preparation
- helper package warming
- module cache setup
- environment normalization
- SDK path handling

This file was responsible for several earlier bugs:

- shared cache vs Bazel stdlib cache mismatches
- incorrect absolute path handling
- helper export drift caused by unstable module/cache assumptions

## The Core Technical Problem

The integration looked, at first, like a simple “turn on Orchestrion” problem.

It was not.

The real problem was that Bazel test builds do not end at package compile. The final linked test binary depends on a coherent combination of:

- woven stdlib archives
- woven user package archives
- synthetic Bazel `testmain`
- Datadog helper packagefile exports

The failure mode that kept recurring was:

- compile succeeds with one packagefile/archive family
- link reconstructs another packagefile/archive family
- runtime ends up missing the instrumentation behavior that compile had already proven

That is why the final fix was not “more bootstrap”, “more env vars”, or “more logging”.

It was making compile and link consume the **same instrumentation closure**.

## Root Cause

The final root cause had two parts.

### Part 1. Wrong storage location for synthetic helper manifest

The synthetic `testmain` compile persisted Datadog helper metadata inside the archive as:

- `orchestrion.pack`

That was fine as a debugging convenience but incorrect for Darwin external link.

Darwin treated archive members as candidate objects and surfaced:

```text
ld64.lld: ... 000000.o: unhandled file type
```

So the manifest could not live inside the `.a` archive.

### Part 2. Compile/link helper family drift

After moving the manifest out of the archive, we discovered the real semantic bug:

- synthetic `testmain` compile resolved `gotesting` / `integrations` / related helpers from one helper-export root
- final synthetic link regenerated those helpers from another root

That meant the final binary was not reusing the exact instrumented helper closure that compile had already validated.

This is the reason we could see intermediate proof like:

- woven `testing.a`
- tracer logs in some places

while still missing the runtime CI Visibility hook in the final binary.

## The Final Fix Set

The changes between:

- `2f7871e` `go: checkpoint synthetic link fixes`
- and `a0c0b01` `go: fix local orchestrion civisibility flow`

contain the fix set that actually closed the issue.

### 1. Sidecar manifest for synthetic `testmain`

Implemented in:

- [archive.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/private/actions/archive.bzl)
- [compilepkg.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/private/actions/compilepkg.bzl)
- [compilepkg.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go)

This introduced:

- a dedicated `~testmain.a.orchestrion.pack` sidecar file
- propagation of that file through `GoArchiveData`

Why it mattered:

- removed the Darwin archive-member object leak
- created a first-class Bazel input for final link

### 2. Sidecar consumption in final `GoLink`

Implemented in:

- [link.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/private/actions/link.bzl)
- [link.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/link.go)

This made final link:

- read the synthetic compile-time helper manifest from the sidecar
- reuse compile-time helper packagefiles when Orchestrion link is disabled for the synthetic path
- append only the additional helper closure needed, from the same root

Why it mattered:

- final link stopped inventing a second helper universe

### 3. Helper-root normalization

Implemented in:

- [importcfg.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/importcfg.go)

This normalized helper-export root parsing and coalesced roots that earlier experiments had split.

Why it mattered:

- synthetic compile and final link started agreeing on what “the same helper root” actually means

### 4. SDK/stdliblist path stabilization

Implemented in:

- [orchestrion.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/orchestrion.go)
- [stdliblist.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/stdliblist.go)

These fixes removed a separate regression introduced by the path normalization work:

- absolute SDK paths were correct for some builder flows
- but `stdliblist` still required a relative `-sdk`

Why it mattered:

- this prevented the main repo validation from regressing after the synthetic-link fix

## What Did Not Turn Out To Be The Final Fix

These changes helped diagnose or unblock earlier failures, but they were not the final cause/fix pair:

- basic wrapper rule creation
- Windows `.exe` wrapper preservation
- bootstrap import tweaks alone
- removing `dd-trace-go.v1` alone
- enabling stdlib weaving alone
- re-enabling synthetic `testmain` weaving alone
- several generations of importcfg rewrite heuristics
- forcing plain `go tool link` by itself
- massive `TRACE` logging by itself

Those changes were useful because they moved the problem to a narrower layer, but they did not close it.

## Why The Debugging Took So Long

This integration sits at the intersection of:

- Bazel action graph semantics
- `rules_go` internals
- Orchestrion expectations
- Go stdlib rebuilding
- synthetic Bazel `testmain`
- platform-specific linker behavior

The hard part was that many states looked “almost correct”.

Examples:

- Orchestrion was active, but final runtime hook still missing
- `testing.a` was woven, but final binary still inconsistent
- tracer logs were present, but `instrumentTestingM` was not
- compile worked, but final link drifted into a different helper family

That made it easy to fix a symptom and still miss the real boundary violation.

## Validation Evidence

### Local proof

The final local proof came from the real `_tests` repository flow:

- target: `//src/go-project:hello_test`
- with `DD_TRACE_DEBUG=true`
- with `DD_CIVISIBILITY_ENABLED=true`

Observed runtime signals:

- `Datadog Tracer v2.6.0 DEBUG: ...`
- `instrumentTestingTFunc: instrumenting test function`
- `instrumentTestingM: finished with exit code: 0`

### CI proof

In CI:

- Linux and macOS logs showed tracer logs and `instrumentTestingTFunc`
- Windows logs showed:
  - `testing.Testing()=true`
  - `instrumentTestingM: finished with exit code: 0`

Together with the local runtime proof, that is enough to call the end-to-end integration fixed.

## Engineering Lessons

### 1. “Orchestrion enabled” is not the same as “final binary correctly instrumented”

It is possible to prove:

- Orchestrion on compile
- woven stdlib archives
- even some runtime tracer activity

while still shipping a final binary that does not use the exact instrumentation closure expected.

### 2. Synthetic `testmain` is the sharpest edge

Bazel’s synthetic test main is where:

- the Go testing package
- rules_go behavior
- Datadog helper closure
- final link semantics

all meet.

That is where the decisive fix ended up.

### 3. When debugging toolchain instrumentation, archive family consistency matters more than isolated symbols

Seeing symbols in `testing.a` was necessary but not sufficient.

The real question was:

- does the final linker consume the same archive/packagefile family that compile proved?

### 4. Sidecar metadata is safer than archive-member metadata for synthetic-link hacks

Embedding metadata inside `.a` archives is tempting, but Darwin external link is much less forgiving than that approach assumes.

## Recommended Reading Order

If someone needs to understand the final design quickly:

1. [modules/go/topt_go_test.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/topt_go_test.bzl)
2. [modules/go/topt_go_orchestrion.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/topt_go_orchestrion.bzl)
3. [modules/go/tools/dd_topt_go_bootstrap/main.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/modules/go/tools/dd_topt_go_bootstrap/main.go)
4. [third_party/rules_go_orchestrion/go/private/actions/archive.bzl](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/private/actions/archive.bzl)
5. [third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/compilepkg.go)
6. [third_party/rules_go_orchestrion/go/tools/builders/link.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/link.go)
7. [third_party/rules_go_orchestrion/go/tools/builders/importcfg.go](/Users/tony.redondo/repos/github/Datadog/rules_test_optimization/third_party/rules_go_orchestrion/go/tools/builders/importcfg.go)

## Simplified Final Mental Model

```mermaid
sequenceDiagram
    participant User as BUILD macro
    participant Wrapper as orch_go_test
    participant Raw as raw go_test
    participant RG as vendored rules_go
    participant Orch as Orchestrion
    participant Link as final GoLink
    participant Bin as final test binary

    User->>Wrapper: dd_topt_go_test(name=...)
    Wrapper->>Raw: transition orchestrion enabled
    Raw->>RG: compile stdlib + user pkgs + synthetic testmain
    RG->>Orch: toolexec compile
    Orch-->>RG: woven archives + helper packagefiles
    RG->>RG: write synthetic sidecar manifest next to ~testmain.a
    RG->>Link: declared inputs include sidecar manifest
    Link->>RG: reuse compile-time helper family
    RG-->>Bin: final linked Bazel test binary
    Bin-->>User: tracer logs + testing.T/testing.M instrumentation
```

## Bottom Line

The issue was fixed when we stopped treating synthetic final link as a place to rediscover Datadog helper state and instead made it reuse the exact helper state already proven during synthetic `testmain` compile.

That is the core idea behind the final working implementation.
