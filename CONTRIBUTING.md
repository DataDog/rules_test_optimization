<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Contributing

## Development Workflow

- Create a feature branch for each change.
- Keep pull requests focused (core-only, single-companion-module-only, or docs-only when possible).
- Keep repository-level Bazel config explicit in scripts/workflows: this repo
  intentionally has no root `.bazelrc` (example workspaces own local `.bazelrc`).
- For new core-rule `fail(...)` diagnostics, prefer consistent prefixed wording
  (for example `test_optimization_sync:`) or shared helpers in
  `tools/core/common_utils.bzl` (`fail_with_prefix`).
- Preserve public label contracts from sync outputs:
  - `:test_optimization_files`
  - `:test_optimization_context`
  - `:module_<sanitized>`
- Keep the three sync contracts separate:
  - static single-service in `test_optimization_sync.bzl`;
  - static multi-service in `test_optimization_multi_sync.bzl`;
  - invocation-scoped Go/Python aggregation in
    `test_optimization_manifest_sync.bzl`.
  Manifest sync must not acquire target discovery, consumer naming policy, or a
  checked-in target/service registry.

## Validation Commands

- Canonical full-repo command:
  - `./bazelw test //...`
  - On macOS with Bazel 8.8.2, append
    `--noexperimental_split_xml_generation`. The split XML helper can terminate
    with `SIGSEGV` independently of the test target.

- Core module tests (repo root):
  - `./bazelw test //tools/...`
- Go companion tests:
  - `cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
  - `bash tools/tests/integration/run_go_helper_compatibility.sh` checks real
    wildcard `build`, `test`, `query`, and `cquery` commands, disabled-repository
    compatibility, and explicit-target diagnostics. Extra Bazel options can be
    passed as script arguments.
- Python companion tests:
  - `cd modules/python && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- Java companion tests:
  - `cd modules/java && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- NodeJS companion tests:
  - `cd modules/nodejs && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- .NET companion tests:
  - `cd modules/dotnet && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- Ruby companion tests:
  - `cd modules/ruby && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- Build examples from root:
  - `./bazelw build //examples/...`
- Verify core/companion module version alignment:
  - `python3 tools/dev/check_module_versions.py`
- Python tooling tests:
  - `bash tools/tests/python/run_python_tools_test.sh`
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
  - Windows primary entrypoint: `pwsh -File tools/tests/integration/run_mock_server_tests.ps1`
  - Windows convenience wrapper: `tools/tests/integration/run_mock_server_tests.cmd`
  - Mixed-runtime uploader changes are not done until both harnesses still pass:
    they cover single-context, explicit override, multi-context repo selection,
    and no-match fallback behavior.
  - Manifest-driven Go/Python changes:
    `python3 tools/tests/integration/run_manifest_sync_tests.py --mode full`.
    This proves strict manifest validation, disabled no-op behavior,
    deterministic output, target-specific cache invalidation, exact doctor
    targets, aggregate enrichment, and no host Go.
  - Windows manifest-disabled parsing:
    `python tools/tests/integration/run_manifest_sync_tests.py --mode disabled`.
- Test Optimization bootstrap config:
  - For config-gated Go and Python onboarding, keep
    `--config=test-optimization` as the only user-facing switch. The shared
    config entry is
    `common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1`.
  - Go needs no other build setting: an instrumented test selects the Go SDK
    that `ddtest instrument` instruments through its own transition.
  - Omitting the config is the documented complete opt-out for Go and Python:
    metadata repositories use disabled stubs when `enabled_by_env = True`,
    `dd_topt_go_test` creates a plain `go_test`, and Python keeps the consumer
    runner without Test Optimization wiring.
  - Other companions retain their existing enablement contract. Do not add
    `enabled_by_env = True` to their sync repositories until their runtime
    wrapper implements and tests the disabled export contract.
  - Do not add a consumer-local Test Optimization bool flag.
- Go consumer integration harnesses:
  - Bzlmod: `tools/tests/integration/run_bzlmod_go_integration.sh`
  - WORKSPACE: `tools/tests/integration/run_workspace_go_integration.sh`
  - Both scripts build a temporary consumer from this checkout with upstream
    `rules_go` and the Go SDK that `ddtest instrument` instruments. Bzlmod
    consumes the repository through `archive_override(...)`; WORKSPACE runs a
    local and an archive fixture.
  - `RULES_GO_VERSION` (default `0.60.0`) selects upstream `rules_go`: a BCR
    `bazel_dep` in Bzlmod, or the release zip with its BCR integrity in
    WORKSPACE. `GO_VERSION` (default `1.25.0`) selects the Go SDK. `rules_go`
    `0.65.0` requires Go 1.26:
    `USE_BAZEL_VERSION=8.8.2 RULES_GO_VERSION=0.65.0 GO_VERSION=1.26.3 tools/tests/integration/run_workspace_go_integration.sh`
  - A new `rules_go` version in the WORKSPACE script needs its integrity in
    `rules_go_integrity`.
  - `FORBID_HOST_GO=1` shadows the host `go` with a failing sentinel (Unix
    only). ddtest needs no host Go, and CI runs every shard this way.
  - `WINDOWS_SMOKE_ONLY=1` (Bzlmod) runs only the instrumented test and its
    payload check, for Windows hosts without the hermetic sandbox:
    `WINDOWS_SMOKE_ONLY=1 tools/tests/integration/run_bzlmod_go_integration.sh`
  - `INTEGRATION_SCENARIO_MODE=release` runs only the archive fixture in
    WORKSPACE; `full` (default) runs both.
  - Set `KEEP_TMP=1` to keep the generated workspaces after a failure.
  - Each script validates:
    - normal mode, and hermetic mode with the inline CI sandbox/network-blocking flags
    - JSON payloads, the `bazel.go.instrumentation.*` and `bazel.go.sdk.*`
      target metadata, and the uploader dry run
    - strict BEP fresh/cached uploader behavior
    - structural `aquery` assertions (`assert_ddtest_aquery.py`) in the
      default, `opt`, and no-strip modes: compiles, link, and standard library
      use the instrumented SDK, the compile gets the registration file, the
      link gets Mini's `testopt`, and only the `TestRunner` has `no-remote-exec`
    - (Bzlmod) a build of the library alone fetches neither the instrumented
      SDK nor Mini, and contacts no metadata server while Test Optimization is
      disabled
- Hermetic smoke (mirror CI flags):
  - run the same test commands with sandbox/network-blocking flags from `.github/workflows/ci.yml`
- Cross-repo fixture validation for mixed-runtime changes:
  - In `../rules_test_optimization_tests/MODULE.bazel`, temporarily enable the
    documented `local_path_override(...)` entries for core and each affected
    companion module so the fixture repo resolves this checkout.
  - For BEP artifact-resolution changes, run the Go fixture scripts with
    `RTO_LOCAL_ARCHIVE=1 RTO_BEP_ARTIFACT_STAGING=1` so the fixture validates
    staged BEP artifacts instead of only the pinned release/local-output path:
    - `cd ../rules_test_optimization_tests/fixtures/bzlmod-go && RTO_LOCAL_ARCHIVE=1 RTO_BEP_ARTIFACT_STAGING=1 ./runtests`
    - `cd ../rules_test_optimization_tests/fixtures/workspace-go && RTO_LOCAL_ARCHIVE=1 RTO_BEP_ARTIFACT_STAGING=1 ./runtests`
    - `cd ../rules_test_optimization_tests/fixtures/bzlmod-go && RTO_LOCAL_ARCHIVE=1 RTO_BEP_ARTIFACT_STAGING=1 ./runtests-hermetic`
    - `cd ../rules_test_optimization_tests/fixtures/workspace-go && RTO_LOCAL_ARCHIVE=1 RTO_BEP_ARTIFACT_STAGING=1 ./runtests-hermetic`
  - Run the relevant fixture entrypoints there before calling the work done.
  - Restore the fixture repo to `git_override(...)` pins before pushing its PR.

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
  - companion module tests on Linux
  - mock-server integration harness on Linux (`.sh`) and Windows (`.ps1`)
  - examples build on Linux/macOS/Windows
  - the Linux result aggregates independent main-suite and mock-server shards
- `bazel-tests-hermetic`:
  - core tests with hermetic flags
  - companion module tests with hermetic flags
  - scope policy: Linux-only by design today; non-Linux hermetic expansion is tracked separately to keep CI runtime bounded
- `workspace-compat-shard (rules_go <version>, <module system>)`:
  - one shard per supported `rules_go` version (`0.60.0`, `0.61.1`, `0.62.0`,
    `0.63.0`, `0.64.2`, `0.65.0`) and WORKSPACE/Bzlmod pair, with
    `FORBID_HOST_GO=1`; `0.65.0` runs with Go `1.26.3`
  - the Go integration scripts themselves cover normal mode, hermetic mode, and structural `aquery` checks
- `workspace-compat`:
  - requires every `workspace-compat-shard` to succeed when full CI runs
- `windows-go-smoke`:
  - runs `WINDOWS_SMOKE_ONLY=1 tools/tests/integration/run_bzlmod_go_integration.sh`
    on Windows: one instrumented Go test and its payload check
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
- Root module must not declare direct `bazel_dep(...)` edges to companion
  modules (`datadog-rules-test-optimization-go`, `...-python`, `...-java`,
  `...-nodejs`, `...-dotnet`, `...-ruby`).
- Language-specific orchestration stays isolated in `modules/<language>`.
- Dev bootstrap wiring in `tools/dev/*_bootstrap.bzl` is dev-only and cycle-safe.
- Manifest normalization and repository rendering are deterministic: equivalent
  input order must produce byte-identical exports, BUILD content, and
  expected-target JSON.
- One managed invocation must reuse one manifest path and metadata snapshot
  across test, doctor, dry-run, and upload. A second invocation refetches once;
  unchanged stable metadata must retain Bazel test-result cache hits, while
  telemetry timing facts remain outside test action inputs.
- The manifest-driven API is additive. Do not change static single-service or
  static multi-service semantics while modifying it.
- Validate cross-repository rollout in this order:
  `rules_test_optimization`, then `rules_test_optimization_tests`, then the
  consumer repository. A green Rule unit test does not replace consumer E2E.

## PR Checklist

- [ ] Updated tests for changed behavior.
- [ ] For parser/tooling edits, added malformed-input coverage and verified
  error diagnostics remain actionable.
- [ ] Ran split-aware validation commands relevant to changed files.
- [ ] Updated docs/snippets for any load-path, module, or API changes.
- [ ] Audited all first-party Markdown and agent skills affected by a public
  onboarding change; vendored and local historical plan documents are excluded.
- [ ] For manifest-driven changes, proved no committed target/service mapping,
  exact target-set validation, disabled no-fetch behavior, and deterministic
  rendering.
- [ ] For Go instrumentation changes, documented any change to the pinned
  ddtest release, the `topt_go_ddtest` SDK configuration, opt-out flags, and
  payload metadata.
- [ ] Updated `LICENSE-3rdparty.csv` for dependency or vendored-code changes.
- [ ] Confirmed no stale references to removed legacy paths (for example
  `//tools/go:*`, replaced by `modules/go/...` targets).
- [ ] Reviewed timeout metadata when adding new slow tests (`--test_verbose_timeout_warnings`).
- [ ] Included rationale and risk notes in PR description.

## Release Runbook (Core + Companion Modules)

- CI release gate:
  - Trigger `.github/workflows/release.yml` via `workflow_dispatch` (or push a version tag) before publication.
  - Both paths execute the full validation suite and test the packaged archive
    with real Go consumers in Bzlmod and WORKSPACE. A branch dispatch saves the
    bundle as a workflow artifact but never creates a tag or release.
  - A version-tag push prepares a **draft** GitHub release only after every
    release job passes. It does not publish the draft or submit BCR changes.
    Review the generated notes/assets, then publish explicitly.
  - The draft contains `rules_test_optimization-X.Y.Z.tar.gz`, `SHA256SUMS`,
    `release.json`, `INSTALL.md`, and `RELEASE_NOTES.md`. Notes come from the
    matching `CHANGELOG.md` section. Installation blocks cover core and all six
    companions, with one archive and checksum.
  - The archive contains only the committed revision, including executable
    modes. Packaging uses a fixed gzip header, so repeated builds of the same
    revision with the same toolchain produce the same bytes. The workflow
    verifies its checksums before attaching the exact validated bundle.
  - An existing release is not edited or overwritten. If draft creation fails
    partway through, inspect the existing draft and its assets before deciding
    how to resume; rerunning must not replace published checksums.

- Local bundle preview (Python 3.11+ and Git; no publication):

  ```sh
  python3 tools/dev/build_release.py --ref HEAD --tag vX.Y.Z --output /path/to/empty-directory
  ```

  The expected tag must match `MODULE.bazel` and have a nonempty changelog
  section. Omit `--tag` for a branch validation preview. Uncommitted edits are
  not included. Do not relabel an older release archive or regenerate a
  published asset in place.

- Version alignment:
  - Keep root `MODULE.bazel` and all companion `modules/*/MODULE.bazel` versions aligned.
  - Keep each companion dependency on core aligned with the same version.
  - Keep `tools/core/common_utils.bzl` `RULES_VERSION` aligned with root
    `MODULE.bazel` version.
  - Keep `UPLOADER_VERSION` in semantic-version format (`X.Y.Z`) and update it
    intentionally when uploader runtime behavior changes.
  - Run `python3 tools/dev/check_module_versions.py` before every release cut.
    In tag workflows, it also requires `GITHUB_REF` to equal
    `refs/tags/v<root-module-version>`. Branch and pull-request workflows keep
    the alignment-only check. To check a planned tag locally without creating
    it, run `GITHUB_REF=refs/tags/vX.Y.Z python3 tools/dev/check_module_versions.py`
    with the intended version in place of `X.Y.Z`.
- Publication order:
  1. Publish core module metadata/artifacts.
  2. Publish companion metadata/artifacts (depends on core).
- Companion source mapping:
  - Ensure release metadata maps each companion source to `modules/<language>` (strip-prefix/subdirectory strategy).
- BCR metadata checklist (performed in the Bazel Central Registry repo):
  - Core module entry includes `MODULE.bazel`, `metadata.json`, and `source.json`.
  - Companion entries include `MODULE.bazel`, `metadata.json`, and `source.json`.
  - Each companion `source.json` uses a `strip_prefix` that resolves to `modules/<language>` at archive root.
  - Generate scaffolding with BCR helper tooling (for example `bazel run //tools:add_module`) and then verify each generated file.
- Pre-announce validation:
  - core tests, companion tests, examples build, integration harness, hermetic lane all green.
- Rollback notes:
  - If companion release fails, avoid publishing docs that require new load paths until both artifacts are available.
