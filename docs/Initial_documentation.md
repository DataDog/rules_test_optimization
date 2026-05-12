# Test Optimization Bazel support

This document explains the current implementation architecture in this
repository. For installation and day-to-day usage, start with `README.md`.

> Last reviewed: 2026-05-07

## Approach Overview

The integration uses a Bazel module extension and repository rule to fetch
Datadog Test Optimization metadata during module/repo resolution, a
workspace-level doctor (via `bazel run`) to validate local outputs after tests,
and a workspace-level uploader (via `bazel run`) to ship payloads from hermetic
test runs.

The steps are:

1. **Module/repository sync**:  
   A module extension instantiates a repository rule that performs authenticated HTTP requests to Datadog (settings, known tests, and test‑management tests when enabled). It materializes JSON outputs under a configurable directory (default: `.testoptimization/`), writes a non‑secret `context.json`, and exposes public filegroups:
   - `@<repo>//:test_optimization_files` (core bundle, includes `cache/http/settings.json`)
   - `@<repo>//:test_optimization_context` (the `context.json` only)
   - `@<repo>//:module_<sanitized>` (per‑module bundle: `cache/http/settings.json` + that module’s known/test‑management files)
   The sync also emits an `export.bzl` helper describing available module labels, the resolved `manifest_path`, and detected runtime/module hints for consumers. Per‑module targets expose canonical runfile names rooted at the manifest directory (`<out_dir>/...`, default `.testoptimization/...`) regardless of where split files are stored physically.  
   Notes:
   - `DD_SITE` accepts bare host, app/api-prefixed host, or full URL; ASCII whitespace is trimmed and value is normalized to `https://api.<site>`.
   - Module labels are computed from the union of known-tests and test-management modules to avoid cross-feature collisions.
  Reference implementation: this repository

2. **Test instrumentation**:
   Tests are instrumented by the tracer library as usual. Under Bazel, they discover synced metadata via runfiles (for example through `DD_TEST_OPTIMIZATION_MANIFEST_FILE`) and write test/coverage payloads to `TEST_UNDECLARED_OUTPUTS_DIR`.

3. **Payload validation and reporting**:
   A single workspace-level doctor runs via `bazel run` after tests complete and validates local JSON payloads, Bazel target metadata, Git metadata, and invalid Go payload-selection states. A single workspace-level uploader then discovers all `test.outputs/` directories in `bazel-testlogs/`, waits for payloads to quiesce, enriches them with `context.json`, and uploads via agentless (`DD_API_KEY`, `DD_SITE`) or EVP proxy (`DD_TEST_OPTIMIZATION_AGENT_URL`).
   In mixed-runtime workspaces, the uploader can bundle multiple `context.json`
   files and select the matching one per payload using sibling
   `bazel_target_metadata.json` repo metadata instead of reusing one global
   context for the entire workspace.
   The doctor and uploader are workspace-level logical operations, but their
   Bazel targets do not have to live in the root package. Small repositories
   can use root labels; large monorepos should use a lightweight package such
   as `//tools/test_optimization`.
   Usage: run `bazel test`, then the doctor target, then the uploader with
   `--dry-run --validate-enrichment`, then the real uploader target. Preserve
   the test exit code, but do not run the real upload if doctor or dry-run
   enrichment validation fails.

4. **Language macros (optional)**:
   Thin wrappers (for Go/Python/Java/NodeJS/.NET/Ruby) set up the right runfiles/env so test code can read the synced files and write payloads to `TEST_UNDECLARED_OUTPUTS_DIR`.
   - Core module (`datadog-rules-test-optimization`) stays runtime-agnostic.
   - Language orchestration lives in companion modules (`datadog-rules-test-optimization-go`, `datadog-rules-test-optimization-python`, `datadog-rules-test-optimization-java`, `datadog-rules-test-optimization-nodejs`, `datadog-rules-test-optimization-dotnet`, `datadog-rules-test-optimization-ruby`).

### Go macro and import path inference

The `dd_topt_go_test` macro automatically selects the correct per‑module payloads by inferring the Go package `importpath` using `rules_go` providers, mirroring how `go_test` computes it.

- Preferred: add a `go_library` and set `embed = [":<that_library>"]` in your `dd_topt_go_test` call. The macro reads `GoArchive`/`GoInfo` from `@rules_go//go:def.bzl` via a Starlark aspect walking `embed`.
- Precedence for determining importpath:
  1) `importpath` explicitly set on the `go_test` invocation (if provided via kwargs)
  2) Provider‑based inference via `embed`
  3) Fallback to `<go module path>/<bazel package>`, where the module path is exported by the sync repo in `topt_data["runtimes"]["go"]["module_path"]`
- Per‑module selection:
  - When using (1) or (2), the macro always attempts per‑module selection and falls back to the full bundle if the module isn’t present.
  - When using (3), the macro consults `topt_data["runtimes"]["go"]["module_included"]` as a coarse gate; if false, it uses the full bundle.

Note: The core module no longer declares `rules_go`. The companion module
`datadog-rules-test-optimization-go` declares `rules_go` for provider
definitions only. Consumers still configure Go toolchains/SDK in their own
`MODULE.bazel`.

### Python macro and module identifier inference

`dd_topt_py_test` applies analysis-time selection with this precedence:

1) explicit `module_identifier`,
2) inferred candidates (`imports`, dependency-propagated identifiers, explicit attrs),
3) fallback from `<python module path>/<bazel package>` when available,
4) full-bundle fallback.

### Java macro and package identifier inference

`dd_topt_java_test` applies analysis-time selection with this precedence:

1) explicit `module_identifier`,
2) `test_class` package plus dependency/attribute-derived candidates,
3) fallback from `<java module path>/<bazel package>` when available,
4) full-bundle fallback.

### NodeJS macro and module identifier inference

`dd_topt_nodejs_test` applies analysis-time selection with this precedence:

1) explicit `module_identifier`,
2) inferred candidates (`package_name`, `module_name`, `npm_package`, `entry_point`, and dependency-propagated identifiers),
3) fallback from `<nodejs module path>/<bazel package>` when available,
4) full-bundle fallback.

### .NET macro and namespace identifier inference

`dd_topt_dotnet_test` applies analysis-time selection with this precedence:

1) explicit `module_identifier`,
2) inferred candidates (`root_namespace`, `assembly_name`, `project_name`, `test_class`, and dependency-propagated identifiers),
3) fallback from `<dotnet module path>.<bazel package>` when available,
4) full-bundle fallback.

### Ruby macro and module identifier inference

`dd_topt_ruby_test` applies analysis-time selection with this precedence:

1) explicit `module_identifier`,
2) inferred candidates (`require_path`, `gem_name`, `library_name`, `main`, and dependency-propagated identifiers),
3) fallback from `<ruby module path>/<bazel package>` when available,
4) full-bundle fallback.

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

### Flaky Test Retries (known flakes)

Separate from Flaky Test Management, this feature returns a list of tests that have been observed as flaky and are eligible for automatic retries by the tracer. It uses the dedicated `api/v2/ci/libraries/tests/flaky` endpoint.

* Gated by `flaky_test_retries_enabled` in the Settings response.
* The raw backend response (with `data` as an array of test entries) is persisted as-is under `cache/http/flaky_tests.json`, then split into per-module files by grouping entries on `entry.attributes.configurations.test.bundle`.
* Tracer-side behavior such as "retry only known flakes" (`DD_CIVISIBILITY_FLAKY_RETRY_ONLY_KNOWN_FLAKES`) is decided at test runtime and is independent of whether this endpoint is fetched.

## Multi‑service aggregation

Some repositories host multiple logical services. The multi‑service module extension instantiates one sync per service and creates an aggregator repository that exposes per‑service labels:

- `@test_optimization_data//:test_optimization_files_<sanitized_service>` (for example `go_service` for `go-service`)  
- `@test_optimization_data//:test_optimization_context_<sanitized_service>`  
- `@test_optimization_data//:module_<sanitized_service>_<sanitized_module>` (for example `:module_go_service_core`)  

It also exports a mapping so macros can select a service by key without consumers having to hardcode repo aliases.
Workspace-level doctor and uploader targets can consume the service-qualified
context aliases; the shared context helper maps those aliases back to the
generated per-service sync repository keys used by payload metadata.

## Runtime uploads and hermetic tests

Tests remain hermetic with network blocked. They write payloads to Bazel's built-in `TEST_UNDECLARED_OUTPUTS_DIR/payloads/{tests,coverage}`, which is automatically collected to `bazel-testlogs/<target>/test.outputs/`. A single workspace-level doctor validates those local outputs before upload. A single workspace-level uploader (via `bazel run`) then:

- Discovers all `test.outputs/` directories in `bazel-testlogs/`,
- Waits for filesystem quiescence,
- Enriches test payloads with `context.json` when present,
- When multiple bundled contexts are present, matches them per payload using
  `bazel.test_optimization.repo_name` from sibling `bazel_target_metadata.json`,
- Can dry-run the enrichment path without uploading or deleting files,
- Uploads to Datadog using either `DD_API_KEY`/`DD_SITE` (agentless) or `DD_TEST_OPTIMIZATION_AGENT_URL` (EVP proxy),
- Deletes successfully uploaded payloads.

No secrets are written to disk; all credentials are passed via environment variables.

Contributor note: CI includes a dedicated hermetic lane (`bazel-tests-hermetic`
in `.github/workflows/ci.yml`) that runs `./bazelw test //tools/...` with
sandboxed execution and network access disabled. Keep this lane in mind when
adding tests or tooling that might accidentally rely on host network state.

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
    A2 --> A3[.testoptimization (default)\n manifest.txt\n context.json\n cache/http/settings.json\n cache/http/known_tests.json\n (per-module targets expose canonical files)\n cache/http/test_management.json\n (per-module targets expose canonical files)]
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
    P1[bazel-testlogs/.../test.outputs/\n  payloads/tests/*.json\n  payloads/coverage/*.json]
    T1 -->|read runfiles| A3
    T1 -->|write to TEST_UNDECLARED_OUTPUTS_DIR| P1
  end

  %% Validate/upload steps: bazel run after tests
  subgraph U[Validate and upload via bazel run]
    U0[Doctor rule]
    U1[Uploader rule]
    U0 -->|validate| P1
    U0 -->|validate context| A3
    U0 --> U1
    U1 -->|enrich with| A3
    U1 -->|upload tests| G1{Agentless?\n DD_API_KEY}
    U1 -->|upload coverage| G1
    G1 -- Yes --> I1[(citestcycle/citestcov\n intake on <DD_SITE>)]
    G1 -- No  --> I2[(EVP proxy\n ${DD_TEST_OPTIMIZATION_AGENT_URL})]
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
            |        .testoptimization/ (default out_dir)
            |          - manifest.txt
            |          - context.json
            |          - cache/http/settings.json
            |          - cache/http/known_tests.json (+ per-module)
            |          - cache/http/test_management.json (+ per-module)
            |        export.bzl + BUILD (filegroups)
            v
Build Graph
  @<repo>//:test_optimization_files
  @<repo>//:test_optimization_context
  @<repo>//:module_<sanitized>

Test Execution (Hermetic)
  [tests (instrumented)] --read runfiles--> synced JSONs
                         --write payloads--> TEST_UNDECLARED_OUTPUTS_DIR/payloads/{tests,coverage} (-> bazel-testlogs/.../test.outputs/)

Validate and upload (via bazel run)
  [doctor rule] --validate--> payload JSON, bazel_target_metadata.json, context.json
  [uploader rule] --dry-run enrichment or upload--> context.json
       |-- agentless (DD_API_KEY, DD_SITE) --> citestcycle/citestcov intake
       |-- EVP proxy (DD_TEST_OPTIMIZATION_AGENT_URL) -> /evp_proxy/... endpoints

Optional: Multi-service aggregator
  @test_optimization_data//:test_optimization_files_<service>
  @test_optimization_data//:module_<service>_<module>
```

</details>

## Summary

The repository extension approach enables Bazel support for Test Optimization in
a hermetic, cache-friendly way. Metadata is fetched once during module/repo
resolution, exposed as filegroups, and consumed by tests via runfiles.
Per-module outputs limit cache impact to relevant targets. Post-test validation
and runtime uploads happen through workspace-level `bazel run` targets,
preserving hermetic execution for tests. Settings and Test Management remain
valuable even with occasional invalidations; Known Tests and any future TIA
integration should be opt-in to avoid disrupting established Bazel workflows.
