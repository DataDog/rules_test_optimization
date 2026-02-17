# Repository Guidelines

This repository ships Bazel integrations that fetch Datadog Test Optimization metadata at module/repo resolution and reliably upload test/coverage payloads from hermetic builds.

## Project Overview
The solution separates concerns into three phases:
1. **Fetch phase (module/repo resolution)**: repository rule fetches metadata from Datadog APIs.
2. **Execute phase (test runtime)**: tests run hermetically, consume pre-fetched metadata via runfiles, and write payloads to `TEST_UNDECLARED_OUTPUTS_DIR`.
3. **Upload phase (post-test)**: a dedicated uploader target (`bazel run //:dd_upload_payloads`) discovers and uploads payloads from `bazel-testlogs/<target>/test.outputs/`.

## Documentation
- User-facing onboarding and command flow: see `README.md` (use its `Reference links` section for deep references).
- Overview: see `docs/Initial_documentation.md` for how the solution works (architecture, data flow, and operational notes).
- Problem statement & proposal: see `docs/RFC.md` for background rationale and trade-offs (historical context).
- Usage snippets: see `examples/README.md` for copy/paste single-service and multi-service examples.

Agents: start with `README.md` for current operational behavior, then use the overview and RFC when you need architecture details or design rationale/trade-off context.

## Project Structure & Module Organization
- `tools/` — Starlark sources:
  - `core/common_utils.bzl` — shared utilities for logging, sanitization, validation, and deduplication used across multiple rule files.
  - `core/test_optimization_sync.bzl` — module extension + repo rule producing `.testoptimization/cache/http/settings.json`, per‑module files, and `.testoptimization/context.json`.
  - `core/test_optimization_multi_sync.bzl` — multi-service module extension for monorepos with multiple services.
  - `core/test_optimization_uploader.bzl` — workspace-level uploader rule (normal rule, not test; runs via `bazel run`).
  - `dev/go_bootstrap.bzl` — dev-only bootstrap extension wiring the local Go companion repo from this workspace.
- `modules/go/` — Go companion module sources:
  - `topt_go_test.bzl` — macro wrapping `go_test` with test optimization environment variables.
  - `topt_go_infer.bzl` — aspect + rule to infer Go `importpath` via rules_go providers and select per‑module payloads.
  - `tests/` — Go-specific Starlark tests and local stub extension for `@test_optimization_data`.
- Top‑level: `README.md`, `MODULE.bazel`, `WORKSPACE`, `bazelw`.
- Consumers depend on `@<repo>//:test_optimization_files` or `:module_<sanitized>`; context via `@<repo>//:test_optimization_context`.

## Generated Repository Structure
The sync rule creates `@test_optimization_data//` containing:
- `BUILD` with public filegroups (`:test_optimization_files`, `:test_optimization_context`, `:module_<sanitized>`).
- `export.bzl` exporting the `topt_data` dict for macros.
- `.testoptimization/cache/http/settings.json`, `.testoptimization/cache/http/known_tests.json`, `.testoptimization/cache/http/test_management.json`, `.testoptimization/manifest.txt`, `.testoptimization/context.json`.
- `.testoptimization/module_<sanitized>/` per-module splits for cache efficiency.

## Key Design Patterns
- **Per-module splitting**: known tests and test management data are split by module to reduce cache invalidation.
- **Sanitization**: module names are converted into Bazel-safe labels using `sanitize_label_fragment()` (lowercase, `[a-z0-9_]` only, deterministic suffixes).
- **Go importpath inference**: `topt_go_payloads_selector` mirrors rules_go importpath logic (explicit `importpath` > `embed` provider > fallback `<module>/<package>`).
- **Cross-platform uploader**: Unix uses Bash/curl; Windows uses PowerShell and .NET `HttpClient`.

## Build, Test, and Development Commands
- Build all: `./bazelw build //...` — compiles and validates Starlark targets.
- Run tests then upload payloads:
  ```bash
  # Tests write payloads to TEST_UNDECLARED_OUTPUTS_DIR automatically
  # Bazel collects them to bazel-testlogs/<target>/test.outputs/
  ./bazelw test //... || test_status=$?; test_status=${test_status:-0}
  DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" ./bazelw run //:dd_upload_payloads
  exit $test_status
  ```
- Force refetch of test optimization data:
  ```bash
  bazel sync --only=test_optimization_data --repo_env=FETCH_SALT=<timestamp>
  # If Bazel reports WORKSPACE-disabled sync errors, retry with:
  bazel sync --enable_workspace --only=test_optimization_data --repo_env=FETCH_SALT=<timestamp>
  ```
- Inspect generated repo files:
  ```bash
  ls -la $(bazel info output_base)/external/test_optimization_data/.testoptimization/
  cat $(bazel info output_base)/external/test_optimization_data/BUILD
  cat $(bazel info output_base)/external/test_optimization_data/export.bzl
  ```
- Typical workflow: edit Starlark, then `./bazelw test //tools/...`.
- Companion Go workflow: `cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`.
- Release guard: `python3 tools/dev/check_module_versions.py` (core/go version alignment).

## Coding Style & Naming Conventions
- Starlark: 2‑space indent; `snake_case` for rules/macros/attrs; concise, descriptive docstrings.
- Public labels are stable — do not rename `test_optimization_files`, `test_optimization_context`, or `module_<sanitized>`.
- Outputs under `.testoptimization/` are fixed: `manifest.txt`, `context.json`, `cache/http/settings.json`, `cache/http/known_tests.json`, `cache/http/test_management.json`, and per‑module canonical files exposed via `:module_<sanitized>` targets (runfiles rooted under the manifest directory).

## Testing Guidelines
- Prefer `./bazelw test //...` for running tests.
- Tests write payloads to `$TEST_UNDECLARED_OUTPUTS_DIR/payloads/{tests,coverage}` (Bazel's built-in writable directory).
- Bazel automatically collects these to `bazel-testlogs/<package>/<target>/test.outputs/`.
- Use `./bazelw run //:dd_upload_payloads` after tests complete to upload payloads.
- For Go, use `dd_topt_go_test` to set up the test with correct environment variables.
- Create ONE uploader target per workspace at the root BUILD.bazel.

## Consumer Tips (bzlmod + Go)
- In `MODULE.bazel`: add `bazel_dep("datadog-rules-test-optimization", ...)` and `bazel_dep("datadog-rules-test-optimization-go", ...)`, then `use_extension("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync_extension")`, instantiate `test_optimization_sync(name = "test_optimization_data", service = "<service>", runtime_name = "go", runtime_version = "<ver>")`, then `use_repo(..., "test_optimization_data")`.
- In root `BUILD.bazel`: create the workspace-level uploader:
  ```bzl
  load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

  dd_payload_uploader(
      name = "dd_upload_payloads",
      data = ["@test_optimization_data//:test_optimization_context"],
  )
  ```
- In test `BUILD.bazel` files: `load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")` and `load("@test_optimization_data//:export.bzl", "topt_data")`; set `topt_data = topt_data` in `dd_topt_go_test(...)`.
- Import path inference (preferred): add a `go_library` and set `embed = [":<that_library>"]` in your `dd_topt_go_test` call. The macro reads rules_go's provider to compute the same `importpath` `go_test` uses and selects the matching per‑module payload group. If no match exists, it falls back to the core bundle automatically.
- Fallback (no embed): if neither `embed` nor explicit `importpath` is provided, the macro computes `<go module path>/<bazel package>` using the exported `topt_data["runtimes"]["go"]["module_path"]`. In this fallback mode only, it consults `topt_data["runtimes"]["go"]["module_included"]` as a coarse gate before attempting per‑module selection.
- Tests can read `DD_TEST_OPTIMIZATION_MANIFEST_FILE` to resolve the manifest directory (via `filepath.Dir()`) and access synced payloads.

Note: Core module (`datadog-rules-test-optimization`) is rules-go free. The Go companion module declares the `rules_go` dependency to load provider definitions; consumers still configure Go SDK/toolchains in their own `MODULE.bazel`.

## Maintainer Architecture Map
- Core ownership (`tools/core/*`): runtime-agnostic sync + uploader + shared helpers; keep it free from non-dev language-rule dependencies.
- Go ownership (`modules/go/*`): Go macro/aspect/selector and Go-specific tests.
- Bootstrap ownership (`tools/dev/go_bootstrap.bzl`): dev-only local repo wiring for root workspace testing; do not convert it into a module dependency edge.
- Invariants:
  - root module must not `bazel_dep` the Go companion module (avoid `core -> go -> core` cycle),
  - root module keeps `rules_go` as dev-only for in-repo examples (not consumer-facing core behavior),
  - Go companion must depend on core and `rules_go`,
  - public generated labels in synced repos remain stable (`test_optimization_files`, `test_optimization_context`, `module_<sanitized>`).

## Bootstrap Troubleshooting
- Symptom: `@datadog-rules-test-optimization-go` not found from repo root.
  - Verify root `MODULE.bazel` still wires `//tools/dev:go_bootstrap.bzl` with `dev_dependency = True` and `use_repo(...)`.
- Symptom: companion tests resolve released core instead of local core.
  - Run companion tests with `--override_module=datadog-rules-test-optimization=../..`.

## Multi‑Service Usage
- Use `test_optimization_multi_sync_extension` (`@...//tools/core:test_optimization_multi_sync.bzl`) with `services = ["<svc1>", "<svc2>"]` to fetch multiple services at once.
- Aggregator repo exposes per‑service labels:
  - `@test_optimization_data//:test_optimization_files_<svc>`
  - `@test_optimization_data//:module_<svc>_<module_label>` (example: `:module_go_service_core`).
- Macros: `load("@test_optimization_data//:export.bzl", "topt_data_by_service")` then either pass `topt_data = topt_data_by_service["<svc>"]`, or pass the mapping and set `topt_service = "<svc>"` in `dd_topt_go_test`.

## Hermetic Config
- Use `--config=hermetic` to enable sandboxing, stable locale, and network blocking (see `.bazelrc` pattern in the consumer repo).
- Network: prefer `--sandbox_default_allow_network=false`; alternatively add `--modify_execution_info=TestRunner=+block-network`.
- No `--sandbox_writable_path` needed — tests use `TEST_UNDECLARED_OUTPUTS_DIR` which is always writable.
- Windows: consider `--enable_runfiles`; if sandboxing is unavailable, fall back to local strategies for tests.

## Commit & Pull Request Guidelines
- Use imperative subjects (≤72 chars). Example: `sync: normalize DD_SITE parsing`.
- Include rationale, testing notes, and linked issues; update `README.md` for user‑visible changes.
- CI must pass on Linux/macOS/Windows; avoid OS‑specific regressions.

## Security & Configuration Tips
- Never write secrets to disk. Pass `DD_API_KEY`, `DD_SITE` via environment when running the uploader.
- `context.json` is non‑secret; include it via `@<repo>//:test_optimization_context` in the uploader's data.
- If CODEOWNERS auto-discovery is not reliable in your environment, set `DD_TEST_OPTIMIZATION_CODEOWNERS_FILE` explicitly to a checked-in CODEOWNERS path.
- Agentless uploads require `DD_API_KEY` and `DD_SITE`; EVP proxy requires `DD_TRACE_AGENT_URL` (EVP headers handled by the rule).
- Uploader credentials are passed at runtime: `DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" ./bazelw run //:dd_upload_payloads`
