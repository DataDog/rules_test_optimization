# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog and this project follows semantic
versioning.

## [Unreleased]

### Changed
- Hardened git repository URL handling by stripping URL userinfo before
  forwarding metadata.
- Improved sync schema parser fallback behavior to try Ruby after any PyYAML
  failure.
- Standardized Go example formatting and test diagnostics across single-service
  and multi-service examples.
- Added CI hardening for Python dependency installation, Buildifier checks,
  gofmt checks, and fixture JSON validation.
- Added release automation workflow (`.github/workflows/release.yml`) to codify
  release runbook validation.

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
- Example workspaces for single-service and multi-service usage patterns.

### Changed
- Established CI validation matrix covering core rules, companion module,
  examples, and integration harnesses.
