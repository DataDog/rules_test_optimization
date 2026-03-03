# Maintainer and Engineering Guide

This document is for contributors and maintainers of
`rules_test_optimization`. For consumer onboarding, start with `README.md`.

## Quick maintainer checks

- Core rules/tests from repository root:
  - `./bazelw test //tools/...`
- Go companion tests from module root:
  - `cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- Python companion tests from module root:
  - `cd modules/python && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- Java companion tests from module root:
  - `cd modules/java && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- NodeJS companion tests from module root:
  - `cd modules/nodejs && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- .NET companion tests from module root:
  - `cd modules/dotnet && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- Ruby companion tests from module root:
  - `cd modules/ruby && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
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
- Root workspace resolves `@datadog-rules-test-optimization-python` and
  `@datadog-rules-test-optimization-java` through corresponding dev-only
  bootstrap extensions under `tools/dev/`.
- Root workspace resolves `@datadog-rules-test-optimization-nodejs`,
  `@datadog-rules-test-optimization-dotnet`, and
  `@datadog-rules-test-optimization-ruby` through corresponding dev-only
  bootstrap extensions under `tools/dev/`.
- `go_bootstrap.local_go_companion(path = "...")` must stay repository-relative
  (no absolute paths, drive prefixes, or `..` traversal) and must point to a
  real module root containing `MODULE.bazel`.
- Do not add a root `bazel_dep` edge from core to the Go companion; that creates
  a dependency cycle (`core -> companion -> core`). The same constraint applies
  to Python, Java, NodeJS, .NET, and Ruby companions.
- Schema ownership remains in core:
  - `tools/core/schemas/*`
  - `tools/core/validate_payload_schema.py`
- Keep `tools/` runtime-agnostic (`tools/core`, `tools/tests`, `tools/dev`);
  do not add placeholder language packages under `tools/<language>`.
  Language-specific orchestration belongs in `modules/<language>/`.

## Adding a language companion module

Use this checklist when adding `dd_topt_<language>_test` support.

1. **Wrapper macro**
   - Add a companion module under `modules/<language>/` with a wrapper macro
     (no `tools/<language>` placeholder package) that accepts:
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
- Repository policy: keep root `.bazelrc` absent; prefer explicit flags in CI
  and example-local `.bazelrc` files.

Examples:

```sh
# Refresh only on git environment variables
./bazelw build //tools/... //examples/...

# Refresh on an hourly TTL
FETCH_SALT_TTL=3600 ./bazelw build //tools/... //examples/...

# Override computed Git metadata
DD_GIT_REPOSITORY_URL=https://github.com/acme/api.git \
DD_GIT_BRANCH=main \
DD_GIT_COMMIT_SHA=$(git rev-parse HEAD) \
./bazelw test //tools/...
```

```powershell
# Refresh only on git environment variables
.\bazelw build //tools/... //examples/...

# Refresh on an hourly TTL
$env:FETCH_SALT_TTL = "3600"
.\bazelw build //tools/... //examples/...

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

Update integration snapshots intentionally when payload shape changes:

```sh
UPDATE_SNAPSHOTS=1 tools/tests/integration/run_mock_server_tests.sh
```

Windows entrypoints:

```powershell
.\tools\tests\integration\run_mock_server_tests.ps1
```

```bat
tools\tests\integration\run_mock_server_tests.cmd
```

Notes:

- The PowerShell entrypoint is native and self-contained (no Git Bash
  dependency). Linux/macOS keep the Bash harness.
- Test-only endpoint overrides:
  - `DD_TEST_OPTIMIZATION_AGENTLESS_URL` (shared direct URL override for sync + uploader agentless path)
  - `DD_TEST_OPTIMIZATION_AGENT_URL` (uploader, EVP proxy path)
- The harness asserts CODEOWNERS enrichment/preservation and runfile manifest
  fallback behavior, and prints focused diagnostics on assertion failures.
- The harness requires `jq` for snapshot/enrichment assertions.
- Snapshot fixture contract:
  - `citestcov_event.json` remains a JSON object with a non-empty `events` list.
  - `citestcov_coverage.json` remains a JSON object with `version` and a
    non-empty `files` list containing `filename` + `segments`.
- CODEOWNERS discovery intentionally checks both `docs/CODEOWNERS` and
  `.docs/CODEOWNERS`; the `.docs` path is retained as a legacy compatibility
  fallback for repositories that still keep ownership files there.

## Runtime metadata/version invariants

- `WORKSPACE` is intentionally present in sync env discovery/forwarding lists
  (alongside `GITHUB_WORKSPACE`, `CI_PROJECT_DIR`, etc.) to preserve workspace
  root resolution in heterogeneous CI environments.
- `UPLOADER_VERSION` and `RULES_VERSION` are intentionally independent:
  uploader script/runtime evolution can ship without forcing a rules contract
  bump, while payload metadata still carries both values for observability.

## CI and reproducibility policy

- CI includes a Linux hermetic lane (`bazel-tests-hermetic`) with sandboxed
  execution and network blocking, plus cross-platform `bazel-tests` and mock
  server integration coverage.
- Hermetic scope policy is intentionally Linux-only today to keep CI runtime
  bounded while preserving one strict sandboxed signal in every PR.
- CI intentionally stays cacheless for Bazel execution in `bazel-tests`.
  - Rationale: each run should re-evaluate repository rules from a fresh state.
  - Guardrail: do not add Bazel cache steps (`actions/cache`, disk cache,
    remote cache) without explicit maintainer approval.
- CI includes a lightweight tools coverage signal (`coverage-tools`) to ensure
  line-coverage artifacts are generated and stay above a minimum floor.
- Shell linting scope includes integration harnesses, `bazelw`, and example
  `runtests.sh` scripts.
- CI runs example `runtests.sh` scripts in `RUNTESTS_DRY_RUN=1` mode to verify
  wiring without requiring Datadog credentials in PR checks.
- Repository tracks both `.bazelversion` and `MODULE.bazel.lock` in git to
  reduce local/CI drift.
- `.bazelversion` is intentionally duplicated at repository root and companion
  module roots (`modules/go/`, `modules/python/`, `modules/java/`,
  `modules/nodejs/`, `modules/dotnet/`, `modules/ruby/`) so either workspace
  entrypoint resolves the same Bazel line.
- CI also keeps a dedicated WORKSPACE-compat probe on Bazel `8.4.1` (separate
  from the `8.5.1` baseline lanes) so legacy `--enable_workspace` behavior is
  continuously exercised during Bazel 9 migration.
- Current PR baseline checks:

```sh
./bazelw test //tools/...
cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..
cd modules/python && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..
cd modules/java && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..
cd modules/nodejs && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..
cd modules/dotnet && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..
cd modules/ruby && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..
```

```powershell
.\bazelw test //tools/...
Push-Location modules/go
..\..\bazelw test //... --override_module=datadog-rules-test-optimization=../..
Pop-Location
Push-Location modules\python
..\..\bazelw test //... --override_module=datadog-rules-test-optimization=../..
Pop-Location
Push-Location modules\java
..\..\bazelw test //... --override_module=datadog-rules-test-optimization=../..
Pop-Location
Push-Location modules\nodejs
..\..\bazelw test //... --override_module=datadog-rules-test-optimization=../..
Pop-Location
Push-Location modules\dotnet
..\..\bazelw test //... --override_module=datadog-rules-test-optimization=../..
Pop-Location
Push-Location modules\ruby
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

## Sync file decomposition roadmap

`tools/core/test_optimization_sync.bzl` is intentionally being decomposed in
guarded slices rather than one large move. Current slices are:
- shared split-by-module extraction helper (`_split_json_payload_by_module`)
- env/URL normalization hardening extracted into dedicated helpers

Planned next slices:
- move HTTP transport/retry helpers into a focused module
- isolate repository output/rendering helpers
- keep parity tests green on every slice before removing legacy wrappers

## Publication checklist (when BCR publication is enabled)

This repository currently uses pre-publication install paths in README
(`git_override` / commit pin). When publishing to BCR, update and verify:

- Module entries for:
  - `datadog-rules-test-optimization`
  - `datadog-rules-test-optimization-go`
  - `datadog-rules-test-optimization-python`
  - `datadog-rules-test-optimization-java`
  - `datadog-rules-test-optimization-nodejs`
  - `datadog-rules-test-optimization-dotnet`
  - `datadog-rules-test-optimization-ruby`
- Per-module BCR files:
  - `MODULE.bazel`
  - `metadata.json`
  - `source.json`
- Companion module `source.json` maps archive root to `modules/go` via
  `strip_prefix` (and similarly for `modules/python`, `modules/java`,
  `modules/nodejs`, `modules/dotnet`, and `modules/ruby`).
