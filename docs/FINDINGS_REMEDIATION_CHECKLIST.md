# Findings Remediation Checklist

This checklist tracks remediation status for validated findings from:
- `FINDINGS1.md`
- `FINDINGS2.md`

Legend:
- `pending`: not implemented yet
- `done`: implemented in this branch
- `closed-no-change`: validated false or intentionally no-op with rationale

| ID | Source | Status | Notes |
|---|---|---|---|
| C-01 | FINDINGS1 | done | Removed empty trailing section in `common_utils.bzl`. |
| H-01 | FINDINGS1 | done | Normalized Go formatting in single-service example. |
| H-02 | FINDINGS1 | done | Normalized style across single/multi Go examples. |
| H-03 | FINDINGS1 | done | Example runtest scripts now use root `bazelw`. |
| H-04 | FINDINGS1 | done | Removed user-specific absolute paths from audit ledger. |
| H-05 | FINDINGS1 | done | YAML loader now falls back to Ruby for any PyYAML failure. |
| M-01 | FINDINGS1 | done | Extracted CI/env helpers into `test_optimization_sync_env.bzl`. |
| M-02 | FINDINGS1 | done | Added template extraction/lint workflow for embedded uploader templates. |
| M-03 | FINDINGS1 | done | Documented global `os.Stdout` swap tradeoff in example tests. |
| M-04 | FINDINGS1 | done | Added expected/actual output diagnostics in multi-service test. |
| M-05 | FINDINGS1 | done | Standardized greeting assertions with explicit expected/got output. |
| M-06 | FINDINGS1 | done | Documented supported schema subset and emit warnings for unsupported keywords. |
| M-07 | FINDINGS1 | done | Validator stats now use run-local state, avoiding cross-call accumulation. |
| M-08 | FINDINGS1 | done | Extracted integration harness shared helpers into `run_mock_server_tests_lib.sh`. |
| M-09 | FINDINGS1 | done | Added descriptive assertions in `run_bazelw_wrapper_test.sh`. |
| M-10 | FINDINGS1 | done | PowerShell harness now discovers repo root by walking up to `MODULE.bazel`/`.git`. |
| M-11 | FINDINGS1 | done | Added explicit intent comment for workflow concurrency policy. |
| M-12 | FINDINGS1 | done | Added inline documentation for manifest label-path assumptions. |
| M-13 | FINDINGS1 | done | Payload clone helper now deep-clones full payload structure. |
| M-14 | FINDINGS1 | done | Removed redundant `_go_test` alias assignment in macro. |
| L-01 | FINDINGS1 | done | Added explicit intentional-duplication comments in example tests. |
| L-02 | FINDINGS1 | done | Added/used `is_list` and `is_string` helpers in shared Starlark utilities. |
| L-03 | FINDINGS1 | done | CMD wrapper now returns `%ERRORLEVEL%` directly. |
| L-04 | FINDINGS1 | done | Added upper bound to PyYAML requirement. |
| L-05 | FINDINGS1 | done | Added `.editorconfig` and CI `gofmt` check job. |
| L-06 | FINDINGS1 | done | Replaced regex-only parsing with call-block extraction parser. |
| L-07 | FINDINGS1 | done | Python test runfile fallback now discovers repo root by walking parents. |
| L-08 | FINDINGS1 | done | Mock server now returns HTTP 400 on invalid Content-Length conditions. |
| L-09 | FINDINGS1 | done | Added `__init__.py` files for Python tooling packages. |
| L-10 | FINDINGS1 | done | Added parser-parity check script and CI gate. |
| L-11 | FINDINGS1 | done | Removed duplicate module description in sync-utils tests. |
| L-12 | FINDINGS1 | done | Added explicit inline note documenting empty-string override semantics. |
| L-13 | FINDINGS1 | done | Removed unnecessary `mkdir` before schema JSON write. |
| L-14 | FINDINGS1 | done | Added CI JSON validation for integration fixtures/snapshots. |
| L-15 | FINDINGS1 | done | Added Bazel API/version note in `go_bootstrap.bzl`. |
| L-16 | FINDINGS1 | done | Added explicit Starlark lint coverage path via Buildifier CI checks. |
| L-17 | FINDINGS1 | done | Added Buildifier install/check steps in CI. |
| L-18 | FINDINGS1 | closed-no-change | Already validated in `bazelw` numeric guard logic. |
| I-01 | FINDINGS1 | done | Raised tools coverage threshold from 30% to 40%. |
| I-02 | FINDINGS1 | done | Added `CHANGELOG.md`. |
| I-03 | FINDINGS1 | done | Added Dependabot automation for `/tools` pip dependencies. |
| I-04 | FINDINGS1 | done | `WORKSPACE` already carries explanatory compatibility comment. |
| I-05 | FINDINGS1 | done | Added `.pre-commit-config.yaml`. |
| I-06 | FINDINGS1 | done | Expanded CODEOWNERS into path-scoped sections plus fallback. |
| I-07 | FINDINGS1 | done | Documented Windows Git Bash requirement and `.cmd` wrapper usage. |
| F-01 | FINDINGS2 | done | Added repository URL userinfo scrubbing in `bazelw` and sync env collection. |
| F-02 | FINDINGS2 | done | CI now installs Python requirements before schema/coverage tooling. |
| F-03 | FINDINGS2 | done | Dependabot now includes pip updates for `/tools`. |
| F-04 | FINDINGS2 | done | Coverage lane now includes Bazel-backed verification before trace coverage. |
| F-05 | FINDINGS2 | done | Added release workflow with runbook-aligned validation steps. |
| F-06 | FINDINGS2 | done | Addressed via M-01/M-02/M-08 maintainability decompositions. |
| F-07 | FINDINGS2 | done | Closed via H-04 path portability fix. |
| F-08 | FINDINGS2 | done | Added `jq` prerequisite guidance in `CONTRIBUTING.md`. |
| F-09 | FINDINGS2 | done | Added `.ps1` and `.cmd` entrypoint clarity in `CONTRIBUTING.md`. |
| F-10 | FINDINGS2 | done | Added concrete hermetic `.bazelrc` references in `AGENTS.md`. |
| F-11 | FINDINGS2 | done | Closed via CODEOWNERS path-scoping update (I-06). |
| F-12 | FINDINGS2 | done | Added missing script to shell-lint scope and improved wrapper-test assertions. |
