<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog and this project follows semantic
versioning.

## [Unreleased]

### Changed

- Go tests are instrumented by `ddtest instrument` instead of Orchestrion. This
  is a breaking change for Go consumers. `dd_topt_go_test` builds every enabled
  test with the Go SDK that `ddtest instrument` instruments, adds Mini's
  `testopt` library and a registration file to the hidden raw `go_test` (Mini
  is ddtest's Test Optimization runtime), and selects the instrumented
  toolchains through the public test's transition. Builds without instrumented
  tests fetch neither the instrumented SDKs nor Mini, and the instrumentation
  needs no host Go. The ddtest release is pinned in
  `modules/go/topt_go_ddtest_repository.bzl`.
- Bzlmod root modules configure the SDK to instrument with
  `topt_go_ddtest.sdk(...)` (`go_mod`, `go_version`, `base_sdk_roots`,
  `exec_platforms`, `experiments`, `panic_hook`); the Go companion registers
  the toolchains. WORKSPACE consumers call
  `topt_go_ddtest_workspace_repositories(...)` after `go_rules_dependencies()`.
- The Go companion uses upstream `rules_go` from the Bazel Central Registry,
  `0.60.0` or newer, under the repository name `io_bazel_rules_go`. CI covers
  `rules_go` `0.60.0`, `0.61.1`, `0.62.0`, `0.63.0`, `0.64.2`, and `0.65.0`.
- `datadog_go_test_optimization_workspace_repositories` declares only the Go
  companion and fails when `rules_go` is not declared yet. Declare upstream
  `rules_go` as `io_bazel_rules_go` before calling it.
- Go target metadata reports `bazel.go.instrumentation.backend`,
  `bazel.go.instrumentation.version`, `bazel.go.instrumentation.release`,
  `bazel.go.instrumentation.contract`, `bazel.go.sdk.name`, and
  `bazel.go.sdk.version` instead of `bazel.go.orchestrion.enabled` and
  `bazel.go.orchestrion.mode`.
- The test-binary linker flags (`-s -w` where `rules_go` does not already
  strip) apply to every enabled Go test by default. `no-remote-exec` stays on
  the `TestRunner` action only.
- `dd_topt_go_stdlib_warmup` always builds the instrumented standard library,
  with or without `--config=test-optimization`.
- `dd_topt_go_bootstrap` writes a managed `topt_go_ddtest.sdk(...)` block
  (`go_version` from `--runtime-version`, otherwise `go_mod`) and adds
  `bazel_dep(name = "rules_go", version = "0.60.0")` when it is missing. It
  writes no `rules_go` override and runs no Go commands. Its WORKSPACE snippet
  declares upstream `rules_go` first and calls
  `topt_go_ddtest_workspace_repositories`. Published onboarding pins contain
  only the six `RTO_*` values.

### Removed

- Orchestrion support: the `orchestrion_mode` and `orchestrion_pin_files`
  attributes of `dd_topt_go_test`, which now fail with a migration message;
  the `orchestrion` extension and `dd_topt_go_orchestrion_tool_repo`; pin
  files; `orchestrion.tool.go` and `orchestrion.yml`; and `dd-trace-go` version
  pinning in `go.mod`.
- The vendored `rules_go` forks (`third_party/rgo`,
  `third_party/rules_go_orchestrion`), their registry, consumer patch profiles,
  tooling, and CI jobs, and the fork blocks of release bundles. The WORKSPACE
  helper no longer accepts `rules_go_fetch`, `rules_go_upstream`, or
  `rules_go_variant`.
- Bootstrap flags `--write-orchestrion-files`, `--orchestrion-version`,
  `--dd-trace-go-version`, `--rules-go-remote`, `--rules-go-commit`,
  `--rules-go-upstream`, `--rules-go-variant`, `--rules-go-fetch`,
  `--check-go-repositories`, `--print-go-repository-updates`,
  `--go-repositories-file`, `--go-repositories-refresh-command`,
  `--go-binary`, and `--go-mod-sync`, and the `--variant`,
  `--rules-go-upstream`, `--dd-trace-go-version`, and `--orchestrion-version`
  flags of `print_go_onboarding_pins`.
- The Orchestrion and `rules_go` fork documents and the
  `rules-go-orchestrion-upstream-migration` agent skill.

### Migrating Go consumers

- Remove `orchestrion_mode` and `orchestrion_pin_files` from `dd_topt_go_test`
  calls and wrappers.
- Remove the `rules_go` override that points at the fork
  (`third_party/rgo/...`) and the `orchestrion` extension with its
  `rules_go_orchestrion_tool` repository, and depend on upstream `rules_go`
  `0.60.0` or newer. In WORKSPACE, declare upstream `rules_go` as
  `io_bazel_rules_go`, drop the fork arguments of
  `datadog_go_test_optimization_workspace_repositories`, and remove the
  `dd_topt_go_orchestrion_tool_repo` call.
- Delete `orchestrion.tool.go` and `orchestrion.yml`, and the Orchestrion and
  `dd-trace-go` requirements in `go.mod` that only served as pins.
- Add `topt_go_ddtest.sdk(go_mod = "//:go.mod")` to the root `MODULE.bazel`,
  or call `topt_go_ddtest_workspace_repositories(go_version = ...)` in
  WORKSPACE.
- Or rerun `dd_topt_go_bootstrap`: it replaces the
  `# BEGIN Datadog Go Orchestrion bootstrap` block with the new managed block,
  and stops if an unmanaged `rules_go` override still points at the fork. If
  the old block's fork commit no longer loads, run the bootstrap from another
  workspace with `--workspace <path>`, or delete the block by hand. Old
  `# BEGIN Datadog Go Pin Files` blocks in BUILD files are harmless and can be
  deleted.
- If `go.mod` requires `github.com/DataDog/ddtest/ddto`, replace `go_deps`'
  copy with the generated Mini: `use_repo(topt_go_ddtest, "topt_go_ddtest_mini")`
  and `override_repo(go_deps, com_github_datadog_ddtest_ddto = "topt_go_ddtest_mini")`.
- Anything that read `bazel.go.orchestrion.*` from target metadata now reads
  `bazel.go.instrumentation.*` and `bazel.go.sdk.*`.

## [1.4.0] - 2026-10-29

### Added

- Release bundles with SHA256 checksums, archive-based installation snippets
  for core/companions/Go forks, and notes generated from this changelog. Tag
  workflows prepare a draft only after all release validations pass; manual
  branch runs produce a downloadable preview without publishing.

### Changed

- Recommend release archives for installation. Go Bzlmod bootstrap now infers
  and preserves checksum-pinned archive overrides and mirrors without requiring
  a Git override for the Orchestrion-enabled fork.
- Use Bazel `8.8.2` for repository and example validation.

### Fixed

- Exclude development-only Bazel configuration from the generated
  `workspace_runtime` and `bzlmod_runtime` Go patch profiles.

## [1.3.0] - 2026-10-21

### Added

- Added `test_optimization_manifest_sync` and
  `test_optimization_manifest_sync_extension` for consumer-managed,
  invocation-scoped Go/Python monorepo onboarding. The new aggregate
  repository exports target-to-context data, narrow per-context/per-module
  labels, bundled contexts, and a generated exact-target file without requiring
  a checked-in service registry.
- Added dynamic exact-target input support to the doctor and convenience
  target macro, plus integration coverage for disabled behavior, deterministic
  manifests, no-host-Go execution, multi-context enrichment, and metadata
  cache isolation.
- Reusable Go WORKSPACE helpers for config-gated metadata sync and fixed-name
  Orchestrion repository declaration, matching the public Go Bzlmod onboarding
  contract.
- Added a non-default `rules_go` v0.62.0 support line with the maintained
  Orchestrion integration and public consumer patch profile.
- Added a non-default `rules_go` v0.63.0 support line with the maintained
  Orchestrion integration and public consumer patch profile.
- Added `DD_TEST_OPTIMIZATION_LOG_LEVEL` with `ERROR`, `WARN`, `INFO`, and
  `DEBUG` levels for sync, doctor, and uploader diagnostics. The default is
  `INFO`; per-output cached-payload skip messages are available at `DEBUG`.

### Changed

- The uploader now defaults to the shared Python implementation on Linux,
  macOS, and Windows. When upgrading from `1.2.0`, install Python `3.10` or
  newer on the machine running `dd_upload_payloads`. Set
  `DD_TEST_OPTIMIZATION_PYTHON` or `PYTHON` if the interpreter is not available
  as `python3` or `python` on `PATH`. For a temporary rollback, set
  `use_python_uploader = False` on the workspace's `dd_payload_uploader`
  target to use the former Bash/curl or PowerShell uploader.
- Orchestrion repository bootstrap now reuses Go's configured or default build
  and module caches for ordinary Go work when they are writable, with a
  repository-local fallback for read-only environments. The Datadog cache is
  reserved for final patched bootstrap artifacts, and the config-disabled path
  leaves the persistent cache untouched. Cache discovery stays on the installed
  Go toolchain so read-only module caches cannot block fallback selection, and
  unsupported cache queries fall back instead of aborting bootstrap.
- Go payload selection now matches the exact module identifiers emitted by the
  test runtime, including escaped fallback target names and external `_test`
  packages. One package shard carries both internal and external test metadata
  when they run in the same test binary.
- Updated the maintained `rules_go` Orchestrion integration to Orchestrion
  `v1.12.0` and `dd-trace-go/v2` `v2.9.1`, preserving upstream test-variant
  resolution while retaining the Bazel-specific resolver compatibility layer.
  Orchestrion `v1.12.0` requires Go `1.25.0` or newer.
- The public Go Bzlmod extension now defaults `enabled_by_env` to `True`, so
  omitting `--config=test-optimization` disables metadata sync and Orchestrion
  together while the named config enables both.
- Config-gated Go and Python macros now consume disabled sync exports as real
  runtime no-ops while preserving the consumer's ordinary public test target.
  Go emits the public raw `go_test`; Python keeps the selected runner and applies
  the CI Visibility runtime kill switch.
- Python payload selection now derives the normal module identifier from runtime
  and Bazel package metadata, keeping explicit `module_identifier` values for
  repository-specific exceptions. When module groups are available, explicit
  identifiers and module-label overrides must match one; inferred or derived
  misses and metadata with no module groups retain the canonical full-bundle
  fallback.
- The Go WORKSPACE bootstrap template now generates one central config-gated
  `dd_go_test` wrapper. The former optimized wrapper name is a compatibility
  alias to that same function, not a second rollout path.
- Go consumers upgrading from `1.2.0` should rerun `dd_topt_go_bootstrap` with
  `--write-bazelrc` before or with the Rule upgrade. The managed `.bazelrc`
  update is idempotent and adds both metadata and Orchestrion activation to the
  `test-optimization` config. Consumers that deliberately retain manual
  always-enabled metadata may set `enabled_by_env = False`, but must also keep
  the Orchestrion build setting enabled.

### Fixed
- Release validation now rejects tags that do not match the core module
  version, while retaining the existing core/companion alignment checks.
- Generated Go payload and metadata helpers are manual and config-compatible,
  so wildcard `build`, `test`, and `cquery` commands work with Test Optimization
  disabled. Unconfigured `query` can still list the targets without analysis.
- Static Go descriptors now select payloads by the test package's effective
  `importpath`, using the synchronized repository's module catalog. This
  restores per-package cache invalidation without loading generated exports or
  eagerly resolving unselected service repositories.
- Go test analysis now fails with migration guidance when Test Optimization
  metadata is enabled but the global Orchestrion build setting is disabled,
  preventing a partial upgrade from silently dropping instrumentation.
- Config-disabled Go analysis now resolves stable empty Orchestrion repository
  targets before host-Go discovery or source fetching, so ordinary targets do
  not require Go to be installed merely because the integration is declared.
- Generated-profile verification now checks deterministic output bytes for
  `GoStdlib`, `GoSyntheticTestmainHelpers`, synthetic `GoCompilePkg`, and
  `GoLink` actions across every maintained `rules_go` version. The builder
  normalizes ephemeral execroot and Go work paths, CGO random seeds, source
  trim paths, and copied helper build IDs while preserving relative CGO input
  resolution. Ordinary Go actions cannot consume the instrumented stdlib
  cache.

## [1.2.0] - 2026-06-03

### Added
- Go companion support for `orchestrion_mode = "test_optimization"` on
  `dd_topt_go_test`, including bootstrap/docs wiring and integration coverage
  for the standard Go `testing` path.
- Go target metadata for the selected Orchestrion mode and test-binary linker
  optimization state.

### Changed
- Optimized Go Test Optimization builds by narrowing Orchestrion work to the
  test path, trimming synthetic test link inputs, and keeping ordinary package
  compiles on the plain rules_go path in `test_optimization` mode.
- Isolated Go Orchestrion dependency preparation so generated onboarding
  wiring is easier to validate and maintain.
- Updated the Python example `ddtrace` pin to `4.10.1`.

### Fixed
- Corrected mode-aware Go Test Optimization metadata so doctor/uploader
  validation can inspect the selected mode and linker optimization state.

## [1.1.0] - 2026-05-25

### Added
- Java companion now ships a WORKSPACE repository helper for non-bzlmod
  consumers.
- Java onboarding documentation skill to guide new Java consumers.

### Changed
- Refreshed documentation around the supported `test -> doctor -> dry-run
  enrichment -> upload` flow, large WORKSPACE Go onboarding, and current
  Orchestrion tracer pins.
- Hardened git repository URL handling by stripping URL userinfo before
  forwarding metadata.
- Improved sync schema parser fallback behavior to try Ruby after any PyYAML
  failure.
- Standardized Go example formatting and test diagnostics across single-service
  and multi-service examples.
- Added a workspace-wide Go tracer selection flow that supports:
  - shared `dd_trace_go_version` pins,
  - per-module `dd_trace_go_versions` pins for real SHA-based resolution,
  - bootstrap normalization of tags, pseudo-versions, branches, and commit
    SHAs into exact persisted versions,
  - mismatch checks that stop Bazel builds when the configured tracer versions
    and local Go module pins drift apart.
- Added CI hardening for Python dependency installation, Buildifier checks,
  gofmt checks, and fixture JSON validation.
- Added release automation workflow (`.github/workflows/release.yml`) to codify
  release runbook validation.
- Updated the default Go tracer pin for Bazel/Orchestrion onboarding from the
  previous pseudo-version to `v2.9.0-rc.2`.
- `UPLOADER_VERSION` now tracks `RULES_VERSION` so both move together in
  future releases.

### Fixed
- Core: preserve the raw executable basename in the Unix wrapper symlink so
  argv[0]-sensitive test binaries observe the expected name.
- Java: corrected the `testonly` selector so Java test targets are recognized
  consistently.

## [1.0.0] - 2026-02-19

### Added
- Initial public release of Datadog Test Optimization Bazel rules with:
  - repository/module sync rule for settings + known-tests + test-management
    payload retrieval,
  - workspace uploader target (`dd_payload_uploader`) for post-test payload upload,
  - generated runfile contracts (`test_optimization_files`,
    `test_optimization_context`, `module_<sanitized>`).
- Go companion module with `dd_topt_go_test` macro and importpath-aware payload
  selection.
- Python companion module with `dd_topt_py_test` analysis-time payload
  selection.
- Java companion module with `dd_topt_java_test` analysis-time payload
  selection.
- NodeJS companion module with `dd_topt_nodejs_test` analysis-time payload
  selection.
- .NET companion module with `dd_topt_dotnet_test` analysis-time payload
  selection.
- Ruby companion module with `dd_topt_ruby_test` analysis-time payload
  selection.
- Example workspaces for single-service and multi-service usage patterns.

### Changed
- Established CI validation matrix covering core rules, companion module,
  examples, and integration harnesses.
