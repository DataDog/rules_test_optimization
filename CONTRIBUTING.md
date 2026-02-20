# Contributing

## Development Workflow

- Create a feature branch for each change.
- Keep pull requests focused (core-only, go-companion-only, or docs-only when possible).
- Keep repository-level Bazel config explicit in scripts/workflows: this repo
  intentionally has no root `.bazelrc` (example workspaces own local `.bazelrc`).
- For new core-rule `fail(...)` diagnostics, prefer consistent prefixed wording
  (for example `test_optimization_sync:`) or shared helpers in
  `tools/core/common_utils.bzl` (`fail_with_prefix`).
- Preserve public label contracts from sync outputs:
  - `:test_optimization_files`
  - `:test_optimization_context`
  - `:module_<sanitized>`

## Validation Commands

- Canonical full-repo command:
  - `./bazelw test //...`

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
- Optional Python tooling dependencies (for local script execution):
  - `python3 -m pip install --require-hashes -r tools/requirements.txt`
- Local lint prerequisites (match CI tooling):
  - `shellcheck` (shell lint lane)
  - `buildifier` (Starlark formatting lane)
  - `jq` (integration harness payload/CODEOWNERS checks)
- Optional pre-commit setup:
  - `python3 -m pip install pre-commit && pre-commit install`
- Optional Python syntax smoke check when editing tooling:
  - `python3 -m py_compile tools/core/validate_payload_schema.py tools/core/schemas/sync_agentless_schema.py tools/tests/integration/mock_dd_server.py`
- Integration harness:
  - Prerequisites: `jq` (Linux/macOS). Windows harness is PowerShell-only.
  - Linux/macOS: `tools/tests/integration/run_mock_server_tests.sh`
  - Windows primary entrypoint: `tools/tests/integration/run_mock_server_tests.ps1`
  - Windows convenience wrapper: `tools/tests/integration/run_mock_server_tests.cmd`
- Hermetic smoke (mirror CI flags):
  - run the same test commands with sandbox/network-blocking flags from `.github/workflows/ci.yml`

## Schema Source Of Truth

- Canonical schema source is `tools/core/schemas/agentless-schema.yaml`.
- Generated artifact is `tools/core/schemas/agentless-schema.json`.
- When editing schema structure:
  - update YAML first,
  - run `python3 tools/core/schemas/sync_agentless_schema.py`,
  - run parity/sync checks:
    - `python3 tools/core/schemas/check_schema_parser_parity.py`
    - `python3 tools/core/schemas/sync_agentless_schema.py --check`

## CI Lanes

- `bazel-tests`:
  - core tests (`//tools/...`) on Linux/macOS/Windows
  - go companion tests (`modules/go`) on Linux/macOS/Windows
  - integration harness on Linux/macOS (`.sh`) and Windows (`.ps1`)
  - examples build on Linux/macOS/Windows
- `bazel-tests-hermetic`:
  - core tests with hermetic flags
  - go companion tests with hermetic flags
  - scope policy: Linux-only by design today; non-Linux hermetic expansion is tracked separately to keep CI runtime bounded
- Utility/lint lanes:
  - module version alignment check (`tools/dev/check_module_versions.py`)
  - `.bazelversion` parity check (`tools/dev/check_bazelversion_sync.py`)
  - shell scripts, PowerShell, Buildifier, gofmt, schema sync checks, fixture JSON checks, and Python tooling tests
- Workflow dependency pinning:
  - Keep GitHub Actions pinned by commit SHA and preserve the `# vX.Y.Z` comment.
  - Use Dependabot (or equivalent) to refresh both SHA and version comment together.

## Snapshot Updates

- Integration snapshots are updated intentionally (never by default).
- Linux/macOS:
  - `UPDATE_SNAPSHOTS=1 tools/tests/integration/run_mock_server_tests.sh`
- Windows PowerShell:
  - `$env:UPDATE_SNAPSHOTS = "1"; ./tools/tests/integration/run_mock_server_tests.ps1`
- Windows CMD wrapper:
  - `set UPDATE_SNAPSHOTS=1 && tools\\tests\\integration\\run_mock_server_tests.cmd`
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

- CI release gate:
  - Trigger `.github/workflows/release.yml` via `workflow_dispatch` (or push a version tag) before publication.
  - The workflow now always executes the full validation suite for release safety.

- Version alignment:
  - Keep root `MODULE.bazel` and `modules/go/MODULE.bazel` versions aligned.
  - Keep the Go companion dependency on core aligned with the same version.
  - Keep `tools/core/common_utils.bzl` `RULES_VERSION` aligned with root
    `MODULE.bazel` version.
  - Keep `UPLOADER_VERSION` in semantic-version format (`X.Y.Z`) and update it
    intentionally when uploader runtime behavior changes.
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
