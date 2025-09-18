# RFC: Bazel Support for Datadog Test Optimization via Module Extension and Uploader

Author: Tony Redondo
Date: Sep 17, 2025  
Status: Draft

This document outlines a proposed method for integrating Datadog Test Optimization with Bazel. The approach involves using a module extension and repository rule to gather metadata during module/repository resolution, and a runtime uploader to transmit test and coverage data back to the backend. The document details the rationale behind this design, current behaviors, limitations, and a strategy for widespread adoption across various services and programming languages.

## Bazel 101

This section provides a short overview of Bazel concepts that are relevant to the proposal. It is not intended as a full introduction to Bazel, but rather a quick reference for terms used throughout this document.

### Hermetic Sandboxes

Bazel executes builds and tests inside isolated sandboxes. Inputs are declared explicitly, network access is usually disabled, and outputs are cached deterministically. This ensures reproducibility but restricts ad-hoc network activity during test execution.

### Cache

Bazel caches outputs of build and test actions based on their declared inputs. If the inputs do not change, the cached outputs can be reused without re-execution. This is central to Bazel’s performance model, and why undeclared inputs such as live network calls break reproducibility and invalidate cache guarantees.

### Repository Rules

Repository rules run during repository resolution, before builds and tests. They can fetch external data or generate files, and their outputs are tracked by the cache. They are commonly used for dependency setup.

### Rules vs Macros (what is a "real rule"?)

In Bazel, macros are Starlark functions that expand to other rule calls at load time; they cannot inspect providers or traverse dependency edges. A "real rule" refers to a Starlark rule (declared with `rule(...)`) that runs during the analysis phase. Real rules can:

- Access providers from their dependencies.
- Participate in analysis-time traversals (e.g., via aspects).
- Declare actions and outputs with proper dependency tracking and caching.

When this RFC mentions "a real rule + aspect," it means we intentionally use an analysis-time rule (not just a macro) so we can read providers like rules_go’s `GoArchive.importpath` and make decisions that are visible to Bazel’s incremental analysis and cache.

### Aspects

Aspects are analysis-time traversals that attach to specific attributes (e.g., `deps`, `embed`) and collect providers across a portion of the graph without changing the targets themselves. They are ideal for computing metadata derived from dependencies (such as a Go package’s effective `importpath`) and feeding that information into a rule that selects inputs or produces outputs accordingly. Aspects preserve hermeticity and let us mirror how native/rules-go logic derives values used by build/test rules.

### Environment Variables

Bazel allows passing environment variables into repository rules (--repo\_env) and test actions (--test\_env). These are the primary mechanism for injecting configuration or secrets.

### Sandbox Writable Paths

By default, Bazel sandboxes are read-only. Specific directories can be marked writable via \--sandbox\_writable\_path, allowing tests to produce artifacts such as logs.

### BEP, BES, and BSP

- BEP (Build Event Protocol): a structured stream of build/test events (targets, actions, test results, artifacts). Bazel can write BEP locally (e.g., `--build_event_json_file`/`--build_event_binary_file`) or send it to a remote backend.
- BES (Build Event Service): a remote endpoint that receives BEP over gRPC (`--bes_backend=<addr>`). Consumers can process builds/tests out-of-band (e.g., post-processing uploads) without modifying test actions or breaking hermeticity.
- BSP (Build Server Protocol): a language-agnostic protocol used by IDEs/tools to interact with build systems. Bazel BSP integrations translate Bazel’s graph and events (often via BEP) into BSP notifications and queries. While out of scope for the core rules here, BEP/BES/BSP awareness informs future integrations (e.g., uploader driven by BEP instead of running inside tests).

## Problem Statement

Modern CI/CD pipelines benefit from Bazel's hermetic, reproducible builds and tests, which are enforced through sandboxing, deterministic inputs, and caching. Datadog Test Optimization enhances CI velocity and quality through service-level test settings, features like early flake detection, "known tests," and test management, as well as the collection of test and coverage results for analysis. However, the typical Test Optimization approach, which relies on runtime network access during tests directly conflicts with Bazel's hermetic test execution, where network access is frequently blocked.

We need an integration that:

- Works with Bazel’s hermetic sandbox model (preferably with network blocked during test actions).  
- Fetches Test Optimization metadata (settings, known tests, test management tests) at a time compatible with Bazel’s caching and repository resolution phases.  
- Scales across languages and services, including multi‑service monorepos.  
- Minimizes cache invalidation scope to avoid unnecessary test re‑execution.  
- Uploads test and coverage payloads reliably from the same `bazel test` invocation without compromising hermeticity or leaking secrets to disk.  
- Provides a stable, simple API (labels, macros) for consumers and avoids intrusive changes in test targets.

## Current State

This section describes what exists today prior to this proposal and the work in this repository: running Datadog Test Optimization by fetching data at test runtime.

### How tests run today (pre‑proposal)

- Language tracers initialize within each test process (depending on the implementation this may be done from a parent process) and perform live network calls to Datadog to retrieve:  
  - Service settings and feature flags.  
  - Known Tests and Test Management tests if the feature is enabled.  
- Also fetches CI/Git metadata inferred from environment variables or by running git commands directly if data is missing.  
- Tests execute and the tracer records results. At test process completion, the tracer uploads test and coverage payloads directly to Datadog using either agentless (API key \+ site) or an EVP proxy URL.

### Where this collides with Bazel

- Bazel commonly enforces hermetic sandboxes with blocked network for test actions. Fetching metadata and uploading results from inside tests violates hermeticity and is not allowed in hermetic configurations.  
- Teams work around this by enabling network for tests (undermining reproducibility) or by scripting ad‑hoc prefetch steps that are not integrated into Bazel’s dependency and caching model.

### Operational characteristics

- Repeated work: every shard redundantly fetches the same settings and known tests.  
- Cache opacity: network responses at runtime are invisible to Bazel’s action cache; outcomes depend on timing rather than declared inputs.  
- Secrets everywhere: `DD_API_KEY` must be present in many test environments to enable uploads.  
- Multi‑service friction: in monorepos, service delineation has to be recreated per language and shard; ownership and separation are error‑prone.  
- Debuggability: failures and logs are scattered across shards and languages, making diagnosis difficult.

## Proposal

We propose standardizing this approach across Bazel‑based services as the supported integration for Datadog Test Optimization. The core tenets are:

1) Fetch metadata during module/repo resolution via a repository rule.  
2) Consume metadata via public filegroups and per‑module labels to minimize cache invalidations.  
3) Keep tests hermetic; write payloads to a shared writable directory configured via `--sandbox_writable_path` and `DD_PAYLOADS_DIR`.  
4) Upload payloads from a dedicated Bazel test that can be scheduled alongside the suite, enriches with non‑secret context, and supports both agentless and EVP proxy modes.  
5) Provide thin language macros that compose these pieces for a smooth developer experience.

The POC for this proposal can be found here: [https://github.com/DataDog/rules\_test\_optimization](https://github.com/DataDog/rules_test_optimization)   
There's also a repository to test the POC rules here: [https://github.com/DataDog/rules\_test\_optimization\_tests](https://github.com/DataDog/rules_test_optimization_tests) 

### Design Overview

At a high level, the proposal moves all network‑dependent metadata fetching out of test actions and into Bazel’s module/repository resolution phase, then ships results from a dedicated uploader test. This preserves hermeticity for user tests while maintaining complete Test Optimization functionality.

- Phase 1 — [Sync at module/repo resolution](https://github.com/DataDog/rules_test_optimization/blob/main/tools/test_optimization_sync.bzl):  
    
  - A module extension instantiates a repository rule that performs the Datadog API calls for Settings (always), Known Tests (when enabled), and Test Management tests (when enabled).  
  - The rule writes deterministic JSON outputs under a fixed directory (default: `.testoptimization/`) and produces a non‑secret `context.json` with CI/Git/OS/runtime tags.  
  - It generates a BUILD file exposing stable public filegroups:  
    - `@<repo>//:test_optimization_files` (core bundle with `settings.json`),  
    - `@<repo>//:test_optimization_context` (`context.json` only),  
    - `@<repo>//:module_<sanitized>` (per‑module bundles with `settings.json` \+ that module’s known/test‑management files).  
  - It emits `export.bzl` with a structured `topt_data` object describing the available per‑module labels and language hints (e.g., Go module path inclusion).


- Phase 2 — Hermetic test execution:  
    
  - Tests run without network and can optionally read the synced JSONs from runfiles (e.g., via `TEST_OPTIMIZATION_PAYLOADS_FILES`).  
  - Instrumented tests write payloads to a single shared writable directory (e.g., `.testoptimization/payloads/{tests,coverage}`) configured via `--sandbox_writable_path` and `DD_PAYLOADS_DIR`.


- Phase 3 — [Upload outside user tests](https://github.com/DataDog/rules_test_optimization/blob/main/tools/test_optimization_uploader_test.bzl):  
    
  - A small uploader test target waits for the payload directory to become quiescent, enriches test payloads with `context.json` (if present), and uploads via agentless (`DD_API_KEY`, `DD_SITE`) or an EVP proxy (`DD_TRACE_AGENT_URL`).


- [Multi‑service monorepos](https://github.com/DataDog/rules_test_optimization/blob/main/tools/test_optimization_multi_sync.bzl):  
    
  - A higher‑level “multi‑sync” extension materializes one repository per service and an aggregator repository that re‑exports per‑service filegroups and a service mapping (`topt_data_by_service`). Macros can select services by key without hardcoding repo aliases.

Why this solves the problem

- Hermeticity: User tests run offline; only the repository rule (during resolution) and the uploader test (at the end) require network.  
- Caching: Metadata is captured as declared repository outputs; tests depend on stable filegroups, and per‑module bundles narrow cache invalidations to relevant targets.  
- Security: Secrets are not written to disk and are scoped to the uploader; test actions themselves do not require `DD_API_KEY`.  
- Simplicity: Consumers depend on stable labels and, where available, language macros that hide wiring details (env/runfiles/uploader).

### Required Library Changes

Under Bazel, tracing libraries must avoid all network calls for Test Optimization and operate entirely on files. Libraries detect Bazel mode via `TEST_OPTIMIZATION_PAYLOADS_FILES`, consume pre‑fetched JSONs from runfiles, and write test and coverage payloads to `$DD_PAYLOADS_DIR` for the uploader to send. Outside Bazel, libraries retain the same current behavior, fetching and accessing the network directly.

Common behavior:

- Detection: If `TEST_OPTIMIZATION_PAYLOADS_FILES` is set and non‑empty, enter “Bazel mode”. Otherwise use existing network transport.  
- Inputs (read‑only):  
  - Parse `TEST_OPTIMIZATION_PAYLOADS_FILES` as a space‑separated list of runfiles paths. Resolve each path to a real file via standard Bazel runfiles resolution:  
    - If `RUNFILES_MANIFEST_FILE` exists, treat each token as a runfiles logical path and map it to a real path by scanning the manifest.  
    - Else, if `TEST_SRCDIR` or `RUNFILES_DIR` exists, join with the token and test for existence.  
    - Else, if a token is already an absolute path and exists, use it as‑is.  
  - From the resolved files, load:  
    - `settings.json`  
    - Any number of `knowntests*.json` files (combined known tests)  
    - Any number of `tmtests*.json` files (combined test management tests)  
  - Accept both “combined” shapes (e.g., `knowntests.json` with `data.attributes.tests`) and split per‑module shapes (e.g., `knowntests.module.<sanitized>.json`). Merge by unioning entries; empty stubs are valid and should be treated as “no data”.  
- Outputs (write‑only):  
  - Ensure `$DD_PAYLOADS_DIR/tests` and `$DD_PAYLOADS_DIR/coverage` exist (create if needed, handling concurrent processes safely).  
  - Serialize test payloads to `$DD_PAYLOADS_DIR/tests/*.json` (JSON only; do not use msgpack in Bazel mode).  
  - Serialize coverage payloads to `$DD_PAYLOADS_DIR/coverage/*.json` (one file per logical coverage unit; uploader will wrap as multipart with a generated `event.json`).  
  - Use unique, deterministic file names to avoid clashes across shards (e.g., include PID/TID/timestamp/random suffix). Flush and fsync where appropriate for durability.  
- Network: In Bazel mode, do not perform any HTTP calls (for metadata fetch or uploads). All remote interactions are delegated to the repository rule (metadata) and the uploader test (shipping).  
- Config precedence: Honor `settings.json` feature flags (e.g., known tests enabled, test management enabled). If missing, default to conservative behavior (features disabled) rather than reaching the network.  
- Logging: Emit a clear startup line noting “Bazel mode enabled via TEST\_OPTIMIZATION\_PAYLOADS\_FILES” and list resolved files for troubleshooting.

Test data contracts (minimum viable)

- settings.json: full server response preferred; if absent, treat features as disabled and do not attempt network requests.  
- known tests: accept combined (`data.attributes.tests`) or per‑module files (`knowntests.module.*.json` → module key → test identifiers). Merge by union.  
- test management tests: accept combined (`data.attributes.modules`) or per‑module files (`tmtests.module.*.json` → module key → test states). Merge by union.  
- Forward compatibility: ignore unknown keys; fail closed (no network) on parse errors in Bazel mode.

Backwards compatibility

- Outside Bazel (no `TEST_OPTIMIZATION_PAYLOADS_FILES`), preserve current behavior: live metadata fetch (settings/known tests) and direct uploads according to existing environment variables.

### Detailed Design

Repository Rule and Module Extension

- The `test_optimization_sync_extension` tag is declared in `MODULE.bazel`. It instantiates `test_optimization_sync` with optional attributes:  
  - `service`: explicit override for service name (else derived from `DD_SERVICE`).  
  - `runtime_name`, `runtime_version`, `runtime_arch`: enrich `configurations` and `context.json`.  
  - `knowntests`, `test_management`: local kill‑switches to skip specific feature requests and emit minimal stubs while adjusting `settings.json` accordingly.  
  - `debug`: increases logging verbosity and writes additional artifacts (e.g., request JSONs) for troubleshooting.  
- The repository rule performs:  
  1. Settings request: always issued; response persisted to `settings.json`.  
  2. Known Tests request: gated by settings and `knowntests` attribute; persisted to `knowntests.json` and split by module (`knowntests.module.<sanitized>.json`).  
  3. Test Management Tests request: gated by settings and `test_management` attribute; persisted to `tmtests.json` and split by module.  
  4. `context.json`: built locally from CI/git/OS/runtime information — non‑secret and safe to ship as runfiles.  
  5. A generated `BUILD` file that exposes:  
     - `:test_optimization_files` → only `settings.json` (stable bundle for most uses).  
     - `:test_optimization_context` → `context.json` (opt‑in for enrichment).  
     - `:module_<sanitized>` → per‑module bundle of settings \+ module‑specific JSONs.  
  6. An `export.bzl` with `topt_data` describing labels and language‑specific hints (e.g., Go module path inclusion).  
- HTTP behavior uses `curl` with fail‑fast and retries; `DD_SITE` is normalized; Windows and non‑Windows paths are handled. The rule declares all relevant env vars in `environ` so changes lead to re‑execution and fresh outputs.

Per‑Module Labels and Sanitization

- Module names are sanitized for file and target names; collisions are resolved deterministically with numeric suffixes.  
- Consumers can depend only on the module(s) they need, limiting rebuilds and cache invalidations when unrelated modules change.

Multi‑Service Aggregation

- For monorepos with multiple services, the multi‑service extension instantiates one repo per service plus an aggregator repo that exposes per‑service labels and a `topt_data_by_service` mapping. This allows macros to select a service by logical key without leaking the concrete repo alias.

Runtime Uploader

- `dd_payload_uploader_test` watches `$DD_PAYLOADS_DIR`, waits for quiescence (`quiescent_sec`), then performs uploads within the same `bazel test` invocation. It supports:  
  - Agentless mode (`DD_API_KEY`, `DD_SITE`) posting to `https://citestcycle-intake.<site>/api/v2/citestcycle` and `https://citestcov-intake.<site>/api/v2/citestcov`.  
  - EVP proxy mode (`DD_TRACE_AGENT_URL`) posting to `/evp_proxy/v2/...` with subdomain routing headers.  
- When `context.json` is present in runfiles (supplied via a data dependency on `@<repo>//:test_optimization_context`), test payloads are enriched by merging context keys.  
- The uploader intentionally performs no network for tests themselves; only the uploader test talks to the network, and only at the end of the test phase when payloads quiesce.

Language Macros

- Provide macros per language to:  
  - Attach runfiles and env (`TEST_OPTIMIZATION_PAYLOADS_FILES`, `DD_PAYLOADS_DIR`).  
  - Add the uploader test target automatically.  
  - Surface reasonable defaults and allow overrides.  
- Go importpath inference:  
  - A Starlark aspect walks `embed` on the `go_test` target and reads `GoArchive.importpath` from rules_go providers, mirroring how `go_test` computes it.  
  - A small rule uses the inferred importpath to pick the matching `:module_<sanitized>` filegroup from the synced repo and exposes it in runfiles; the macro sets `TEST_OPTIMIZATION_PAYLOADS_FILES` to `$(rlocationpaths :<selector>)`.  
  - Precedence: (1) explicit `importpath` kwarg on the `go_test`; (2) provider‑based inference via `embed`; (3) fallback to `<go module path>/<bazel package>`.  
  - The exported `topt_data["go"]["module_included"]` flag is consulted only in fallback mode; when inferring via (1) or (2), the macro always attempts per‑module selection and falls back to the full bundle if no match exists.  
- Module dependency: this repository declares a `bazel_dep("rules_go", <version>)` to make the provider load visible under Bzlmod; it does not configure toolchains. Consumers must still configure `rules_go` and the Go SDK in their own `MODULE.bazel`.

- [The existing `dd_topt_go_test` demonstrates this pattern and should be mirrored for other languages incrementally.](https://github.com/DataDog/rules_test_optimization/blob/main/tools/topt_go_test.bzl)

Security Considerations

- Secrets are passed via `--repo_env`/`--test_env` and not written to disk. The repo rule’s HTTP calls rely on `DD_API_KEY` at fetch time; the uploader uses either `DD_API_KEY` or `DD_TRACE_AGENT_URL` at test time.  
- `context.json` contains only non‑secret metadata and is safe to include as runfiles.  
- Consumers should configure sandboxing and network blocking for tests (`--config=hermetic`, `--sandbox_default_allow_network=false`) and make only the payload directory writable.

Performance and Caching

- Repository fetches are kept minimal and retried on transient failures. Splitting per module reduces invalidation impact.  
- Caching keys for the repository rule include attributes and declared env vars; downstream test targets cache on the content of the JSONs they depend on.

Observability and Debugging

- Informational and debug logs are printed by the rule and the uploader; additional artifacts (request bodies) can be enabled via `debug`.  
- The `bazelw` wrapper in this repo can materialize git metadata into `--repo_env` to ensure consistent fetch keys across CI runs.

Backwards Compatibility and Adoption

- Public labels are stable: `:test_optimization_files`, `:test_optimization_context`, `:module_<sanitized>`.  
- Consumers on WORKSPACE can instantiate the repository rule directly; Bzlmod users rely on `use_extension` \+ `use_repo`.  
- A gradual rollout plan can start by adopting the uploader test and filegroup dependencies, then moving to language macros for deeper integration.

## Limitations of the Proposal

Hermetic and Network Boundaries

- Tests remain hermetic with network disabled, but the repository rule and uploader test still require network during repository resolution and the final upload step. For environments that mandate zero network everywhere, organizations must seed artifacts from trusted mirrors and route uploads through internal proxies. We could potentially overcome this by implementing the uploader at BEP watcher level (Build Event Protocol) but we need more research time to have a clear picture on how it might be implemented.

Test Impact Analysis (TIA)

- Omitted initially due to interference with Bazel caching semantics; any future TIA integration should be explicit opt‑in and carefully evaluated.

Cache Invalidation and Granularity

- Settings changes and Test Management updates appropriately invalidate caches. Per‑module filegroups minimize blast radius, but monolithic tests can still see broad invalidations.

Language Coverage

- Convenience macros exist for Go; other languages require similar wrappers or manual wiring until macros are provided.

Platform and Tooling

- Cross‑platform handling exists (macOS/Linux/Windows), but less common shells/environments may need tweaks. `curl` is required; `jq` is optional for enrichment.

## Alternatives Considered

- Runtime fetching in each test: violates hermeticity, increases flakiness, and explodes network calls.  
- Bazel spawn strategy wrappers or custom test runners: intrusive and language‑specific; increases maintenance burden.  
- BES (Build Event Service) post‑processing: could be implemented for the uploader but requires more research time.  
- Repository rule without per‑module splitting: simpler, but causes wider cache invalidations across large monorepos.
 - Macro‑only Go inference: macros cannot read providers in Bazel; a real rule + aspect is required to access `GoArchive.importpath` and follow `embed` dependencies during analysis while keeping BUILD usage simple.

## Future Work

- Evaluate an opt‑in TIA approach that does not fight Bazel caching semantics (e.g., coarse‑grained TIA hints that do not land in the action cache key).  
- Evaluate the inclusion of tracer telemetry data by modifying the tracer's telemetry transport and the inclusion of this type of payloads in the uploader.  
- Provide first‑class macros for other languages and unify env wiring patterns.  
- Evaluate the possibility to implement the uploader using the Bazel build event service.  
- Add optional verification tests that assert `context.json` enrichment in CI.
