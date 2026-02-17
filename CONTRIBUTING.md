# Contributing

## Development Workflow

- Create a feature branch for each change.
- Keep pull requests focused (core-only, go-companion-only, or docs-only when possible).
- Preserve public label contracts from sync outputs:
  - `:test_optimization_files`
  - `:test_optimization_context`
  - `:module_<sanitized>`

## Split-Aware Validation Commands

- Core module tests (repo root):
  - `./bazelw test //tools/...`
- Go companion tests:
  - `cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- Build examples from root:
  - `./bazelw build //examples/...`
- Integration harness:
  - Linux/macOS: `tools/tests/integration/run_mock_server_tests.sh`
  - Windows: `tools/tests/integration/run_mock_server_tests.ps1`
- Hermetic smoke (mirror CI flags):
  - run the same test commands with sandbox/network-blocking flags from `.github/workflows/ci.yml`

## CI Lanes

- `bazel-tests`:
  - core tests (`//tools/...`) on Linux/macOS/Windows
  - go companion tests (`modules/go`) on Linux/macOS/Windows
  - integration harness on Linux/macOS (`.sh`) and Windows (`.ps1`)
  - examples build on Linux
- `bazel-tests-hermetic`:
  - core tests with hermetic flags
  - go companion tests with hermetic flags
- Lint lanes:
  - shell scripts, PowerShell, schema sync checks

## Maintainer Invariants

- Root module (`MODULE.bazel`) must stay runtime-agnostic and avoid non-dev
  language-rule dependencies. (`rules_go` is allowed only as `dev_dependency`
  for in-repo example builds.)
- Root module must not declare `bazel_dep(name = "datadog-rules-test-optimization-go", ...)`.
- Go-specific orchestration stays isolated in `modules/go`.
- Dev bootstrap wiring in `tools/dev/go_bootstrap.bzl` is dev-only and cycle-safe.

## PR Checklist

- [ ] Updated tests for changed behavior.
- [ ] Ran split-aware validation commands relevant to changed files.
- [ ] Updated docs/snippets for any load-path, module, or API changes.
- [ ] Confirmed no stale references to removed legacy paths (for example `//tools/go:*`).
- [ ] Included rationale and risk notes in PR description.

## Release Runbook (Core + Go Companion)

- Version alignment:
  - Publish core and go companion with aligned versions for initial rollout.
- Publication order:
  1. Publish core module metadata/artifacts.
  2. Publish go companion metadata/artifacts (depends on core).
- Companion source mapping:
  - Ensure release metadata maps companion sources to `modules/go` (strip-prefix/subdirectory strategy).
- Pre-announce validation:
  - core tests, go companion tests, examples build, integration harness, hermetic lane all green.
- Rollback notes:
  - If companion release fails, avoid publishing docs that require new load paths until both artifacts are available.
