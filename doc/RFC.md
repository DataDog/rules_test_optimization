# RFC: Bazel Support for Datadog Test Optimization via Module Extension and Hermetic Uploader

Objective: Define and ratify an approach to integrate Datadog Test Optimization with Bazel using a module extension and repository rule to fetch metadata at module/repo resolution, combined with a hermetic runtime uploader to ship test and coverage payloads. This document motivates the design, enumerates current behavior and constraints, and proposes a path for adoption across services and languages.


## Problem Statement

Modern CI/CD pipelines favor hermetic, reproducible builds and tests. Bazel enforces these properties through sandboxing, deterministic inputs, and caching. Datadog Test Optimization (TO) improves CI velocity and quality by (a) providing service‑level test settings, (b) enabling features like early flake detection, “known tests,” and test management, and (c) collecting test and coverage results for analysis. However, typical TO integrations assume runtime network access during tests and/or language‑specific library setup, which directly conflicts with Bazel’s hermetic test execution where network access is often blocked.

We need an integration that:

- Works with Bazel’s hermetic sandbox model (preferably with network blocked during test actions).
- Fetches TO metadata (settings, known tests, test management tests) at a time compatible with Bazel’s caching and repository resolution phases.
- Scales across languages and services, including multi‑service monorepos.
- Minimizes cache invalidation scope to avoid unnecessary test re‑execution.
- Uploads test and coverage payloads reliably from the same `bazel test` invocation without compromising hermeticity or leaking secrets to disk.
- Provides a stable, simple API (labels, macros) for consumers and avoids intrusive changes in test targets.


## Current State

This section describes what exists today prior to this proposal and the work in this repository: running Datadog Test Optimization by fetching data at test runtime.

How tests run today (pre‑proposal)
- Language tracers or test harnesses initialize within each test process or shard and perform live network calls to Datadog to retrieve:
  - Service settings and feature flags.
  - Known Tests and, when enabled, Test Management tests.
  - Optional CI/Git metadata inferred from environment variables.
- Tests execute and the tracer records results. At test or shard completion, the tracer uploads test and coverage payloads directly to Datadog using either agentless (API key + site) or an EVP proxy URL.

Where this collides with Bazel
- Bazel commonly enforces hermetic sandboxes with blocked network for test actions. Fetching metadata and uploading results from inside tests violates hermeticity and is not allowed in hermetic configurations.
- Teams work around this by enabling network for tests (undermining reproducibility) or by disabling parts of the product (losing value), or by scripting ad‑hoc prefetch steps that are not integrated into Bazel’s dependency and caching model.

Operational characteristics
- Repeated work: every shard redundantly fetches the same settings and known tests.
- Cache opacity: network responses at runtime are invisible to Bazel’s action cache; outcomes depend on timing rather than declared inputs.
- Secrets everywhere: `DD_API_KEY` must be present in many test environments to enable uploads.
- Multi‑service friction: in monorepos, service delineation has to be recreated per language and shard; ownership and separation are error‑prone.
- Debuggability: failures and logs are scattered across shards and languages, making diagnosis difficult.


## Limitations (Current Approach)

Hermeticity and Network Access
- Runtime metadata fetching and payload uploads require network during test execution, conflicting with Bazel’s hermetic sandbox model.

Non‑deterministic Inputs and Caching
- Live HTTP responses are not part of Bazel action inputs. Tests can exhibit stale or inconsistent behavior because the cache cannot reason about runtime side effects.

Duplication and Overhead
- Each test or shard repeats the same HTTP requests and performs separate uploads, adding latency and external dependency on Datadog endpoints.

Security Posture
- Secrets (API keys) must be present in many test environments when uploading from within tests, broadening exposure and complicating audits.

Operational Complexity and Observability
- Logs and failures distribute across shards and languages; environment inference varies run to run, making diagnosis and local reproduction difficult.

Multi‑service and Multi‑language Friction
- Without a centralized prefetch, service boundaries blur and language ecosystems duplicate integration logic.


## Proposal

We propose standardizing this approach across Bazel‑based services as the supported integration for Datadog Test Optimization. The core tenets are:

1) Fetch metadata during module/repo resolution via a repository rule.
2) Consume metadata via public filegroups and per‑module labels to minimize cache invalidations.
3) Keep tests hermetic; write payloads to a shared writable directory configured via `--sandbox_writable_path` and `DD_PAYLOADS_DIR`.
4) Upload payloads from a dedicated Bazel test that can be scheduled alongside the suite, enriches with non‑secret context, and supports both agentless and EVP proxy modes.
5) Provide thin language macros that compose these pieces for a smooth developer experience.

### Design Overview

At a high level, the proposal moves all network‑dependent metadata fetching out of test actions and into Bazel’s module/repository resolution phase, then ships results from a dedicated uploader test. This preserves hermeticity for user tests while maintaining complete Test Optimization functionality.

- Phase 1 — Sync at module/repo resolution:
  - A module extension instantiates a repository rule that performs the Datadog API calls for Settings (always), Known Tests (when enabled), and Test Management tests (when enabled).
  - The rule writes deterministic JSON outputs under a fixed directory (default: `.testoptimization/`) and produces a non‑secret `context.json` with CI/Git/OS/runtime tags.
  - It generates a BUILD file exposing stable public filegroups:
    - `@<repo>//:test_optimization_files` (core bundle with `settings.json`),
    - `@<repo>//:test_optimization_context` (`context.json` only),
    - `@<repo>//:module_<sanitized>` (per‑module bundles with `settings.json` + that module’s known/test‑management files).
  - It emits `export.bzl` with a structured `topt_data` object describing the available per‑module labels and language hints (e.g., Go module path inclusion).

- Phase 2 — Hermetic test execution:
  - Tests run without network and can optionally read the synced JSONs from runfiles (e.g., via `TEST_OPTIMIZATION_PAYLOADS_FILES`).
  - Instrumented tests write payloads to a single shared writable directory (e.g., `.testoptimization/payloads/{tests,coverage}`) configured via `--sandbox_writable_path` and `DD_PAYLOADS_DIR`.

- Phase 3 — Upload outside user tests:
  - A small uploader test target waits for the payload directory to become quiescent, enriches test payloads with `context.json` (if present), and uploads via agentless (`DD_API_KEY`, `DD_SITE`) or an EVP proxy (`DD_TRACE_AGENT_URL`).

- Multi‑service monorepos:
  - A higher‑level “multi‑sync” extension materializes one repository per service and an aggregator repository that re‑exports per‑service filegroups and a service mapping (`topt_data_by_service`). Macros can select services by key without hardcoding repo aliases.

Why this solves the problem
- Hermeticity: User tests run offline; only the repository rule (during resolution) and the uploader test (at the end) require network.
- Caching: Metadata is captured as declared repository outputs; tests depend on stable filegroups, and per‑module bundles narrow cache invalidations to relevant targets.
- Security: Secrets are not written to disk and are scoped to the uploader; test actions themselves do not require `DD_API_KEY`.
- Simplicity: Consumers depend on stable labels and, where available, language macros that hide wiring details (env/runfiles/uploader).

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
     - `:module_<sanitized>` → per‑module bundle of settings + module‑specific JSONs.
  6. An `export.bzl` with `topt_data` describing labels and language‑specific hints (e.g., Go module path inclusion).
- HTTP behavior uses `curl` with fail‑fast and retries; `DD_SITE` is normalized; Windows and non‑Windows paths are handled. The rule declares all relevant env vars in `environ` so changes lead to re‑execution and fresh outputs.

Per‑Module Labels and Sanitization
- Module names are sanitized for file and target names; collisions are resolved deterministically with numeric suffixes.
- Consumers can depend only on the module(s) they need, limiting rebuilds and cache invalidations when unrelated modules change.

Multi‑Service Aggregation
- For monorepos with multiple services, the multi‑service extension instantiates one repo per service plus an aggregator repo that exposes per‑service labels and a `topt_data_by_service` mapping. This allows macros to select a service by logical key without leaking the concrete repo alias.

Hermetic Runtime Uploader
- `dd_payload_uploader_test` watches `$DD_PAYLOADS_DIR`, waits for quiescence (`quiescent_sec`), then performs uploads within the same `bazel test` invocation. It supports:
  - Agentless mode (`DD_API_KEY`, `DD_SITE`) posting to `https://citestcycle-intake.<site>/api/v2/citestcycle` and `https://citestcov-intake.<site>/api/v2/citestcov`.
  - EVP proxy mode (`DD_TRACE_AGENT_URL`) posting to `/evp_proxy/v2/...` with subdomain routing headers.
- When `context.json` is present in runfiles (supplied via a data dependency on `@<repo>//:test_optimization_context`), test payloads are enriched by merging context keys.
- The uploader intentionally performs no network for tests themselves; only the uploader test talks to the network, and only at the end of the test phase when payloads quiesce.

Language Macros and DX
- Provide macros per language to:
  - Attach runfiles and env (`TEST_OPTIMIZATION_PAYLOADS_FILES`, `DD_PAYLOADS_DIR`).
  - Add the uploader test target automatically.
  - Surface reasonable defaults (e.g., inferred Go import paths) and allow overrides.
- The existing `dd_topt_go_test` demonstrates this pattern and should be mirrored for other languages incrementally.

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
- Consumers on WORKSPACE can instantiate the repository rule directly; Bzlmod users rely on `use_extension` + `use_repo`.
- A gradual rollout plan can start by adopting the uploader test and filegroup dependencies, then moving to language macros for deeper integration.

## Limitations of the Proposal

Hermetic and Network Boundaries
- Tests remain hermetic with network disabled, but the repository rule and uploader test still require network during repository resolution and the final upload step. For environments that mandate zero network everywhere, organizations must seed artifacts from trusted mirrors and route uploads through internal proxies.

Test Impact Analysis (TIA)
- Omitted initially due to interference with Bazel caching semantics; any future TIA integration should be explicit opt‑in and carefully evaluated.

Cache Invalidation and Granularity
- Settings changes and Test Management updates appropriately invalidate caches. Per‑module filegroups minimize blast radius, but monolithic tests can still see broad invalidations.

Language Coverage
- Convenience macros exist for Go; other languages require similar wrappers or manual wiring until macros are provided.

Platform Nuances and Tooling
- Cross‑platform handling exists (macOS/Linux/Windows), but less common shells/environments may need tweaks. `curl` is required; `jq` is optional for enrichment.

Security
- Secrets are injected via env and not written to disk; CI must still ensure secure handling and avoid log leakage.

Alternatives Considered
- Runtime fetching in each test: violates hermeticity, increases flakiness, and explodes network calls.
- Bazel spawn strategy wrappers or custom test runners: intrusive and language‑specific; increases maintenance burden.
- BES (Build Event Service) post‑processing: could ship payloads, but does not solve the need for pre‑fetched metadata (known tests, settings) inside hermetic tests.
- Repository rule without per‑module splitting: simpler, but causes wider cache invalidations across large monorepos.

Rollout Plan
1. Pilot the module extension and uploader in one or two services across macOS/Linux/Windows CI.
2. Establish a standard `.bazelrc` snippet forwarding required `--repo_env` and `--test_env` and setting hermetic configs.
3. Publish language‑specific macros (Java/Python/JS) mirroring `dd_topt_go_test`.
4. Document multi‑service usage patterns and update service templates.
5. Monitor telemetry (upload success rates, fetch times) and iterate on defaults (timeouts, retries).

Open Questions / Future Work
- Evaluate an opt‑in TIA approach that does not fight Bazel caching semantics (e.g., coarse‑grained TIA hints that do not land in the action cache key).
- Provide first‑class macros for other languages and unify env wiring patterns.
- Add optional verification tests that assert `context.json` enrichment in CI.
- Consider a pluggable persistence layer for organizations that require fetching via internal mirrors or pre‑baked artifacts.
 
