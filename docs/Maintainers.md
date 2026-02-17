# Maintainer and Engineering Guide

This document is for contributors and maintainers of
`rules_test_optimization`. For consumer onboarding, start with `README.md`.

## Quick maintainer checks

- Core rules/tests from repository root:
  - `./bazelw test //tools/...`
- Go companion tests from module root:
  - `cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- Integration harness:
  - Linux/macOS: `tools/tests/integration/run_mock_server_tests.sh`
  - Windows: `tools/tests/integration/run_mock_server_tests.ps1`
- Hermetic lane parity (local smoke):
  - Run the same commands with sandbox/network-blocking flags used in CI.
- Version alignment guard:
  - `python3 tools/dev/check_module_versions.py`

## Bootstrap and module graph notes

- Root workspace resolves `@datadog-rules-test-optimization-go` through
  `tools/dev/go_bootstrap.bzl` (dev-only wiring).
- Do not add a root `bazel_dep` edge from core to the Go companion; that creates
  a dependency cycle (`core -> go -> core`).
- Schema ownership remains in core:
  - `tools/core/schemas/*`
  - `tools/core/validate_payload_schema.py`

## Adding a language companion module

Use this checklist when adding `dd_topt_<language>_test` support.

1. **Wrapper macro**
   - Add a companion module under `modules/<language>/` with a wrapper macro that
     accepts:
     - `name`
     - `topt_data` (single-service dict or multi-service mapping)
     - `topt_service` (optional for multi-service selection)
     - language test-rule symbol injection (similar to `go_test_rule`)
   - Ensure it appends selector + manifest labels to `data` and sets:
     - `DD_TEST_OPTIMIZATION_MANIFEST_FILE`
     - `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES = "true"`

2. **Selector / inference rule**
   - Add analysis-time selection logic in `modules/<language>/`:
     - precedence: explicit identifier -> inferred identifier -> fallback
       identifier -> full bundle
     - module label resolution should match `module_<sanitized>` names from sync
       outputs
   - Keep fallback-to-full-bundle behavior non-fatal.

3. **Companion module dependency policy**
   - Keep root core module (`datadog-rules-test-optimization`) free of
     language-specific rule dependencies.
   - Put language-specific dependencies (for example `rules_go`,
     `rules_python`, etc.) in the companion module only.
   - Use repo-qualified loads back to core shared helpers when needed.

4. **Runtime metadata keys**
   - Extend sync-exported runtime metadata under:
     - `topt_data["runtimes"]["<language>"]`
   - Keep core keys stable (`repo_name`, `manifest_path`, `labels`, `set`) and
     avoid changing generated public label names.

5. **Tests**
   - Add unit tests for:
     - macro service-selection and data/env wiring
     - selector precedence + fallback behavior
     - sync export shape for runtime metadata
   - Extend integration harness coverage if language runtime
     inference/selection adds new branches.

## Wrapper script (`bazelw`)

This repository includes `bazelw` to forward repo env vars consistently:

- Computes Git metadata when a Git repo is present and forwards via `--repo_env`.
- Exported `DD_GIT_*` values override computed metadata.

Examples:

```sh
# Refresh only on git environment variables
./bazelw build //...

# Refresh on an hourly TTL
FETCH_SALT_TTL=3600 ./bazelw build //...

# Override computed Git metadata
DD_GIT_REPOSITORY_URL=https://github.com/acme/api.git \
DD_GIT_BRANCH=main \
DD_GIT_COMMIT_SHA=$(git rev-parse HEAD) \
./bazelw test //tools/...
```

```powershell
# Refresh only on git environment variables
.\bazelw build //...

# Refresh on an hourly TTL
$env:FETCH_SALT_TTL = "3600"
.\bazelw build //...

# Override computed Git metadata
$env:DD_GIT_REPOSITORY_URL = "https://github.com/acme/api.git"
$env:DD_GIT_BRANCH = "main"
$env:DD_GIT_COMMIT_SHA = (git rev-parse HEAD)
.\bazelw test //tools/...
```

## Integration tests (mock server)

Run full sync + uploader flow locally (without hitting Datadog):

```sh
tools/tests/integration/run_mock_server_tests.sh
```

Windows entrypoints:

```powershell
.\tools\tests\integration\run_mock_server_tests.ps1
```

```bat
tools\tests\integration\run_mock_server_tests.cmd
```

Notes:

- The PowerShell entrypoint reuses the Bash harness for parity and prefers Git
  for Windows `bash.exe` (or `DD_TEST_OPTIMIZATION_GIT_BASH` when set).
- Test-only endpoint overrides:
  - `DD_TEST_OPTIMIZATION_API_BASE` (sync)
  - `DD_TEST_OPTIMIZATION_INTAKE_BASE` (uploader, agentless path)
- The harness asserts CODEOWNERS enrichment/preservation and runfile manifest
  fallback behavior, and prints focused diagnostics on assertion failures.

## CI and reproducibility policy

- CI includes a Linux hermetic lane (`bazel-tests-hermetic`) with sandboxed
  execution and network blocking, plus cross-platform `bazel-tests` and mock
  server integration coverage.
- Repository tracks both `.bazelversion` and `MODULE.bazel.lock` in git to
  reduce local/CI drift.
- Current PR baseline checks:

```sh
./bazelw test //tools/...
cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..
```

```powershell
.\bazelw test //tools/...
Push-Location modules/go
..\..\bazelw test //... --override_module=datadog-rules-test-optimization=../..
Pop-Location
```

## Schema sync helper

Source of truth:

- `tools/core/schemas/agentless-schema.yaml`

Regenerate runtime JSON schema:

```sh
python3 tools/core/schemas/sync_agentless_schema.py
```

```powershell
python3 tools/core/schemas/sync_agentless_schema.py
```

Check schema sync status (CI/pre-commit friendly):

```sh
python3 tools/core/schemas/sync_agentless_schema.py --check
```

```powershell
python3 tools/core/schemas/sync_agentless_schema.py --check
```

The helper uses PyYAML when available and falls back to Ruby's built-in YAML
parser.

## Publication checklist (when BCR publication is enabled)

This repository currently uses pre-publication install paths in README
(`git_override` / commit pin). When publishing to BCR, update and verify:

- Module entries for:
  - `datadog-rules-test-optimization`
  - `datadog-rules-test-optimization-go`
- Per-module BCR files:
  - `MODULE.bazel`
  - `metadata.json`
  - `source.json`
- Companion module `source.json` maps archive root to `modules/go` via
  `strip_prefix`.
