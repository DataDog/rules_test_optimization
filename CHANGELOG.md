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

### Changed
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
- Go test analysis now fails with migration guidance when Test Optimization
  metadata is enabled but the global Orchestrion build setting is disabled,
  preventing a partial upgrade from silently dropping instrumentation.
- Config-disabled Go analysis now resolves stable empty Orchestrion repository
  targets before host-Go discovery or source fetching, so ordinary targets do
  not require Go to be installed merely because the integration is declared.

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
