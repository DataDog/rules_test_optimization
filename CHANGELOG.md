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
