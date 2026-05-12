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
