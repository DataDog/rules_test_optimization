# Contributing

## Development Workflow

- Create a feature branch for each change.
- Keep pull requests focused (core-only, go-companion-only, or docs-only when possible).
- Keep repository-level Bazel config explicit in scripts/workflows: this repo
  intentionally has no root `.bazelrc` (example workspaces own local `.bazelrc`).
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
- Verify core/go module version alignment:
  - `python3 tools/dev/check_module_versions.py`
- Python tooling tests:
  - `./bazelw test //tools/tests/python:python_tools_test`
- Optional Python syntax smoke check when editing tooling:
  - `python3 -m py_compile tools/core/validate_payload_schema.py tools/core/schemas/sync_agentless_schema.py tools/tests/integration/mock_dd_server.py`
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
  - examples build on Linux/macOS/Windows
- `bazel-tests-hermetic`:
  - core tests with hermetic flags
  - go companion tests with hermetic flags
- Utility/lint lanes:
  - module version alignment check (`tools/dev/check_module_versions.py`)
  - shell scripts, PowerShell, schema sync checks, and Python tooling tests

## Snapshot Updates

- Integration snapshots are updated intentionally (never by default).
- Linux/macOS:
  - `UPDATE_SNAPSHOTS=1 tools/tests/integration/run_mock_server_tests.sh`
- Windows PowerShell:
  - `$env:UPDATE_SNAPSHOTS = "1"; ./tools/tests/integration/run_mock_server_tests.ps1`
- Always review snapshot diffs before committing to ensure they reflect expected behavioral changes.

## Maintainer Invariants

- Root module (`MODULE.bazel`) must stay runtime-agnostic and avoid non-dev
  language-rule dependencies. (`rules_go` is allowed only as `dev_dependency`
  for in-repo example builds.)
- Root module must not declare `bazel_dep(name = "datadog-rules-test-optimization-go", ...)`.
- Go-specific orchestration stays isolated in `modules/go`.
- Dev bootstrap wiring in `tools/dev/go_bootstrap.bzl` is dev-only and cycle-safe.

## PR Checklist

- [ ] Updated tests for changed behavior.
- [ ] For parser/tooling edits, added malformed-input coverage and verified
  error diagnostics remain actionable.
- [ ] Ran split-aware validation commands relevant to changed files.
- [ ] Updated docs/snippets for any load-path, module, or API changes.
- [ ] Confirmed no stale references to removed legacy paths (for example
  `//tools/go:*`, replaced by `modules/go/...` targets).
- [ ] Reviewed timeout metadata when adding new slow tests (`--test_verbose_timeout_warnings`).
- [ ] Included rationale and risk notes in PR description.

## Release Runbook (Core + Go Companion)

- Version alignment:
  - Keep root `MODULE.bazel` and `modules/go/MODULE.bazel` versions aligned.
  - Keep the Go companion dependency on core aligned with the same version.
  - Run `python3 tools/dev/check_module_versions.py` before every release cut.
- Publication order:
  1. Publish core module metadata/artifacts.
  2. Publish go companion metadata/artifacts (depends on core).
- Companion source mapping:
  - Ensure release metadata maps companion sources to `modules/go` (strip-prefix/subdirectory strategy).
- BCR metadata checklist (performed in the Bazel Central Registry repo):
  - Core module entry includes `MODULE.bazel`, `metadata.json`, and `source.json`.
  - Go companion entry includes `MODULE.bazel`, `metadata.json`, and `source.json`.
  - Companion `source.json` uses a `strip_prefix` that resolves to `modules/go` at archive root.
  - Generate scaffolding with BCR helper tooling (for example `bazel run //tools:add_module`) and then verify each generated file.
- Pre-announce validation:
  - core tests, go companion tests, examples build, integration harness, hermetic lane all green.
- Rollback notes:
  - If companion release fails, avoid publishing docs that require new load paths until both artifacts are available.
