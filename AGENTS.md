# Repository Guidelines

This repository ships Bazel integrations that fetch Datadog Test Optimization metadata at module/repo resolution and reliably upload test/coverage payloads from hermetic builds.

## Documentation
- Overview: see `docs/Initial_documentation.md` for how the solution works (architecture, data flow, and operational notes).
- Problem statement & proposal: see `docs/RFC.md` for the background problem this solves, rationale, and the detailed design.

Agents: start with the Overview, then skim the RFC to understand constraints and goals before modifying code or rules.

## Project Structure & Module Organization
- `tools/` — Starlark sources:
  - `test_optimization_sync.bzl` — module extension + repo rule producing `.testoptimization/settings.json`, per‑module files, and `.testoptimization/context.json`.
  - `test_optimization_uploader_test.bzl` — runtime uploader test rule.
  - `topt_go_test.bzl` — macro wrapping `go_test` with the uploader.
  - `topt_go_infer.bzl` — aspect + rule to infer Go `importpath` via rules_go providers and select per‑module payloads.
- Top‑level: `README.md`, `MODULE.bazel`, `WORKSPACE`, `bazelw`.
- Consumers depend on `@<repo>//:test_optimization_files` or `:module_<sanitized>`; context via `@<repo>//:test_optimization_context`.

## Build, Test, and Development Commands
- Build all: `./bazelw build //...` — compiles and validates Starlark targets.
- Run tests + uploader:
  `./bazelw test //... //tools:dd_upload_payloads \
   --sandbox_writable_path=$PWD/.testoptimization/payloads \
   --test_env=DD_PAYLOADS_DIR=$PWD/.testoptimization/payloads`
- Typical workflow: edit Starlark, then `./bazelw test //tools/...`.

## Coding Style & Naming Conventions
- Starlark: 2‑space indent; `snake_case` for rules/macros/attrs; concise, descriptive docstrings.
- Public labels are stable — do not rename `test_optimization_files`, `test_optimization_context`, or `module_<sanitized>`.
- Outputs under `.testoptimization/` are fixed: `settings.json`, `known_tests.json`, `known_tests.module.*.json`, `test_management.json`, `test_management.module.*.json`, `context.json`.

## Testing Guidelines
- Prefer `./bazelw test //...`; the uploader rule runs as a normal test.
- To exercise uploads, write payloads to `$DD_PAYLOADS_DIR/{tests,coverage}` and pass a writable path via `--sandbox_writable_path`.
- For Go, use `dd_topt_go_test` to bundle the uploader with `go_test`.

## Consumer Tips (bzlmod + Go)
- In `MODULE.bazel`: add `bazel_dep("datadog-rules-test-optimization", ...)`, `use_extension("@datadog-rules-test-optimization//tools:test_optimization_sync.bzl", "test_optimization_sync_extension")`, instantiate `test_optimization_sync(name = "test_optimization_data", service = "<service>", runtime_name = "go", runtime_version = "<ver>")`, then `use_repo(..., "test_optimization_data")`.
- In `BUILD.bazel`: `load("@datadog-rules-test-optimization//tools:topt_go_test.bzl", "dd_topt_go_test")` and `load("@test_optimization_data//:export.bzl", "topt_data")`; set `topt_data = topt_data` in `dd_topt_go_test(...)`.
- Import path inference (preferred): add a `go_library` and set `embed = [":<that_library>"]` in your `dd_topt_go_test` call. The macro reads rules_go’s provider to compute the same `importpath` `go_test` uses and selects the matching per‑module payload group. If no match exists, it falls back to the core bundle automatically.
- Fallback (no embed): if neither `embed` nor explicit `importpath` is provided, the macro computes `<go module path>/<bazel package>` using the exported `topt_data["go"]["module_path"]`. In this fallback mode only, it consults `topt_data["go"]["module_included"]` as a coarse gate before attempting per‑module selection.
- Tests can read `TEST_OPTIMIZATION_PAYLOADS_FILES` (space‑separated runfiles) to inspect synced payloads.

Note: This repository declares a `bazel_dep` on `rules_go` to load provider definitions for Go importpath inference. It does not configure Go toolchains; consumers must still configure `rules_go` (SDK, toolchains) in their own `MODULE.bazel`.

## Multi‑Service Usage
- Use `test_optimization_multi_sync_extension` (`@...//tools:test_optimization_multi_sync.bzl`) with `services = ["<svc1>", "<svc2>"]` to fetch multiple services at once.
- Aggregator repo exposes per‑service labels:
  - `@test_optimization_data//:test_optimization_files_<svc>`
  - `@test_optimization_data//:module_<svc>_<module_label>` (example: `:module_go_service_core`).
- Macros: `load("@test_optimization_data//:export.bzl", "topt_data_by_service")` then either pass `topt_data = topt_data_by_service["<svc>"]`, or pass the mapping and set `topt_service = "<svc>"` in `dd_topt_go_test`.

## Hermetic Config
- Use `--config=hermetic` to enable sandboxing, stable locale, and network blocking (see `.bazelrc` pattern in the consumer repo).
- Network: prefer `--sandbox_default_allow_network=false`; alternatively add `--modify_execution_info=TestRunner=+block-network`.
- Windows: consider `--enable_runfiles`; if sandboxing is unavailable, fall back to local strategies for tests.

## Commit & Pull Request Guidelines
- Use imperative subjects (≤72 chars). Example: `sync: normalize DD_SITE parsing`.
- Include rationale, testing notes, and linked issues; update `README.md` for user‑visible changes.
- CI must pass on Linux/macOS/Windows; avoid OS‑specific regressions.

## Security & Configuration Tips
- Never write secrets to disk. Pass `DD_API_KEY`, `DD_SITE`, `DD_TRACE_AGENT_URL` via `--repo_env`/`--test_env`.
- `context.json` is non‑secret; include it via `@<repo>//:test_optimization_context`.
- Agentless uploads require `DD_API_KEY`; EVP proxy requires `DD_TRACE_AGENT_URL` (EVP headers handled by the rule).
