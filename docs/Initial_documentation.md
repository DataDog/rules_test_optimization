# Test Optimization Bazel support

## Approach Overview

The integration uses a Bazel module extension and repository rule to fetch Datadog Test Optimization metadata during module/repo resolution, and a small uploader test to ship payloads from hermetic test runs.

The steps are:

1. **Module/repository sync**:  
   A module extension instantiates a repository rule that performs authenticated HTTP requests to Datadog (settings, known tests, and test‑management tests when enabled). It materializes JSON outputs under `.testoptimization/`, writes a non‑secret `context.json`, and exposes public filegroups:
   - `@<repo>//:test_optimization_files` (core bundle, includes `settings.json`)
   - `@<repo>//:test_optimization_context` (the `context.json` only)
   - `@<repo>//:module_<sanitized>` (per‑module bundle: `settings.json` + that module’s known/test‑management files)
   The sync also emits an `export.bzl` helper describing available module labels and detected runtime/module hints for consumers.  
   POC: [https://github.com/DataDog/rules\_test\_optimization](https://github.com/DataDog/rules_test_optimization)

2. **Test instrumentation**:  
   Tests are instrumented by the tracer library as usual. Under Bazel, they discover synced metadata via runfiles (e.g., through `TEST_OPTIMIZATION_PAYLOADS_FILES`) and write test/coverage payloads to a writable path.

3. **Payload reporting**:  
   A dedicated uploader runs as a normal Bazel test, waits for payloads to quiesce, enriches them with `context.json`, and uploads via agentless (`DD_API_KEY`,`DD_SITE`) or EVP proxy (`DD_TRACE_AGENT_URL`).

4. **Language macros (optional)**:  
   Thin wrappers (e.g., for Go) compose tests with the uploader and wire the right runfiles/env so test code can read the synced files when needed.

### Go macro and import path inference

The `dd_topt_go_test` macro automatically selects the correct per‑module payloads by inferring the Go package `importpath` using `rules_go` providers, mirroring how `go_test` computes it.

- Preferred: add a `go_library` and set `embed = [":<that_library>"]` in your `dd_topt_go_test` call. The macro reads `GoArchive`/`GoLibrary` from `@rules_go//go/private:providers.bzl` via a Starlark aspect walking `embed`.
- Precedence for determining importpath:
  1) `importpath` explicitly set on the `go_test` invocation (if provided via kwargs)
  2) Provider‑based inference via `embed`
  3) Fallback to `<go module path>/<bazel package>`, where the module path is exported by the sync repo in `topt_data["go"]["module_path"]`
- Per‑module selection:
  - When using (1) or (2), the macro always attempts per‑module selection and falls back to the full bundle if the module isn’t present.
  - When using (3), the macro consults `topt_data["go"]["module_included"]` as a coarse gate; if false, it uses the full bundle.

Note: This repository declares a `bazel_dep("rules_go", "0.46.0")` to load provider definitions only. It does not configure any Go toolchains; consumers still set up `rules_go` and the Go SDK in their `MODULE.bazel`.

## Why a repository extension?

- **Hermeticity**: Bazel sandboxes can be hermetic (isolated, with no network access). The extension lets us gather backend data ahead of time.  
  Module/repo resolution can fetch what’s needed; tests then run offline using the synced JSONs.  

- **Environment access**: It gives us visibility into repository-level environment variables.  
  The rule also auto-detects CI and Git metadata and normalizes it into `context.json`.  

- **Backend data gathering**: We fetch settings and, when enabled, known tests and test‑management tests exactly once per repo state, then persist results as JSONs in an external repository. Tests consume them via runfiles instead of making network calls.  

- **Cache friendliness**: Per‑module JSONs and filegroups (`:module_<sanitized>`) let consumers scope dependencies narrowly so cache invalidations impact only related test targets. The top‑level `:test_optimization_files` remains stable (primarily `settings.json`).

## Cache Invalidation Scenarios

### Settings updates

Any configuration change in the Datadog UI (feature toggles, test settings, etc.) regenerates the settings JSON file. This naturally invalidates the test rule cache. Since the tracer library depends on these settings, this is unavoidable.

### Early flake detection & “new” test tagging (Known Tests)

These features rely on an API that returns the list of known tests for a service.

* Adding a new test already invalidates the cache for its test rule.  
* Per‑module splitting reduces blast radius: depending on `:module_<sanitized>` limits cache invalidation to tests that opt into that module bundle.  
* The extension also provides local kill‑switches (attributes) so teams can opt out of requesting Known Tests regardless of server flags when stricter caching is needed.

### Test Impact Analysis (TIA)

Datadog’s TIA works at the file level, similar to Bazel’s caching model. Bazel won’t re-run tests if source files are unchanged.

* Ideally, TIA could bring finer granularity within large test rules, but its mechanism requires a “skippable tests” JSON file.  
* That artifact would tend to invalidate the cache when Bazel would already skip the target, creating interference.  
* Given the overlap, TIA remains out of scope for the initial Bazel integration and would be considered as an explicit opt‑in if pursued.

### Flaky Test Management

This feature depends on a JSON list of flaky tests and their statuses (e.g. disabled, quarantined).

* Any status update invalidates the cache for affected test rules.  
* Per‑module files again help narrow invalidations. Unlike TIA, Test Management provides clear value even with occasional cache churn.

## Multi‑service aggregation

Some repositories host multiple logical services. The multi‑service module extension instantiates one sync per service and creates an aggregator repository that exposes per‑service labels:

- `@test_optimization_data//:test_optimization_files_<service>`  
- `@test_optimization_data//:test_optimization_context_<service>`  
- `@test_optimization_data//:module_<service>_<sanitized_module>`  

It also exports a mapping so macros can select a service by key without consumers having to hardcode repo aliases.

## Runtime uploads and hermetic tests

Tests remain hermetic with network blocked. They write payloads under a shared writable directory (e.g., `.testoptimization/payloads/{tests,coverage}`). A small uploader test target then:

- Waits for the directory to become quiescent,  
- Enriches test payloads with `context.json` when present,  
- Uploads to Datadog using either `DD_API_KEY`/`DD_SITE` (agentless) or `DD_TRACE_AGENT_URL` (EVP proxy).

No secrets are written to disk; all credentials are passed via environment variables.

## Architecture diagram

```mermaid
flowchart TD
  %% Module/Repo phase: fetch and materialize metadata
  subgraph M[Module/Repo Resolution]
    A1[Bazel module extension\n test_optimization_sync_extension]
    A2[Repository rule\n test_optimization_sync]
    A1 --> A2
    A2 -->|POST Settings| D1[Datadog Settings API]
    A2 -->|POST Known Tests (if enabled)| D2[Known Tests API]
    A2 -->|POST Test Mgmt (if enabled)| D3[Test Management Tests API]
    A2 --> A3[.testoptimization/\n settings.json\n manifest.txt\n known_tests.json\n known_tests.module.*.json\n test_management.json\n test_management.module.*.json\n context.json]
    A2 --> A4[export.bzl + BUILD\n filegroups per module]
  end

  %% Build graph view: public entrypoints
  subgraph B[Build Graph]
    B1["@<repo>//:test_optimization_files"]
    B2["@<repo>//:test_optimization_context"]
    B3["@<repo>//:module_<sanitized>"]
  end
  A4 ---> B1
  A4 ---> B2
  A4 ---> B3

  %% Test execution: hermetic, offline
  subgraph T[Test Execution (Hermetic)]
    T1[Tests (instrumented)]
    P1[.testoptimization/payloads/\n  tests/*.json\n  coverage/*.json]
    T1 -->|read runfiles| A3
    T1 -->|write payloads| P1
  end

  %% Upload step: separate test target
  subgraph U[Upload]
    U1[Uploader test]\n
    U1 -->|enrich with| A3
    U1 -->|upload tests| G1{Agentless?\n DD_API_KEY}
    U1 -->|upload coverage| G1
    G1 -- Yes --> I1[(citestcycle/citestcov\n intake on <DD_SITE>)]
    G1 -- No  --> I2[(EVP proxy\n ${DD_TRACE_AGENT_URL})]
  end

  %% Optional multi-service aggregator (not connected to flow)
  C[[Optional: Multi-service aggregator]]
  C ---|exposes| C1["@test_optimization_data//:\n test_optimization_files_<service>\n module_<service>_<module>"]
```

<details>
<summary>Show ASCII fallback diagram</summary>

```text
Module/Repo Resolution
  [module extension] -> [repository rule]
            |                |-- POST Settings --> (Settings API)
            |                |-- POST Known Tests (if enabled) --> (Known Tests API)
            |                |-- POST Test Mgmt (if enabled) --> (Test Mgmt Tests API)
            |                v
            |        .testoptimization/
            |          - settings.json
            |          - manifest.txt
            |          - known_tests.json (+ per-module)
            |          - test_management.json (+ per-module)
            |          - context.json
            |        export.bzl + BUILD (filegroups)
            v
Build Graph
  @<repo>//:test_optimization_files
  @<repo>//:test_optimization_context
  @<repo>//:module_<sanitized>

Test Execution (Hermetic)
  [tests (instrumented)] --read runfiles--> synced JSONs
                         --write payloads--> .testoptimization/payloads/{tests,coverage}

Upload
  [uploader test] --enrich--> context.json
       |-- agentless (DD_API_KEY, DD_SITE) --> citestcycle/citestcov intake
       |-- EVP proxy (DD_TRACE_AGENT_URL) -> /evp_proxy/... endpoints

Optional: Multi-service aggregator
  @test_optimization_data//:test_optimization_files_<service>
  @test_optimization_data//:module_<service>_<module>
```

</details>

## Summary

The repository extension approach enables Bazel support for Test Optimization in a hermetic, cache‑friendly way. Metadata is fetched once during module/repo resolution, exposed as filegroups, and consumed by tests via runfiles. Per‑module outputs limit cache impact to relevant targets. Runtime uploads happen as a standard test, preserving hermetic execution for the rest of the suite. Settings and Test Management remain valuable even with occasional invalidations; Known Tests and any future TIA integration should be opt‑in to avoid disrupting established Bazel workflows.
