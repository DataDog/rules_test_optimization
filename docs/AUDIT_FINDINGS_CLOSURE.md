# Audit Findings Closure Ledger

This ledger tracks closure for all findings from:
- `/Users/tony.redondo/Downloads/FINDINGS1.md`
- `/Users/tony.redondo/Downloads/FINDINGS2.md`

Disposition values:
- `fixed`
- `clarified-intent`
- `verified-not-actionable`

| ID | Source | Disposition | Files | Notes |
|---|---|---|---|---|
| C-1 | FINDINGS1 | fixed | `tools/core/schemas/sync_agentless_schema.py`, `tools/tests/python/test_python_tools.py` | Wrap non-`RuntimeError` parser failures as actionable `RuntimeError` instead of raw traceback. |
| C-2 | FINDINGS1 | fixed | `tools/core/validate_payload_schema.py`, `tools/tests/python/test_python_tools.py` | Added `patternProperties` regex compile error handling and tests. |
| C-3 | FINDINGS1 | fixed | `.github/workflows/ci.yml` | Hermetic lane now includes `--incompatible_strict_action_env` for parity with documented hermetic policy. |
| C-4 | FINDINGS1 | fixed | `modules/go/topt_go_test.bzl`, `modules/go/tests/test_macro.bzl` | Removed silent `rundir` override and verified explicit passthrough with macro tests. |
| C-5 | FINDINGS1 | fixed | `tools/core/common_utils.bzl`, `tools/core/test_optimization_sync.bzl`, `tools/core/test_optimization_uploader.bzl` | Centralized shared rule/uploader version constants in common utilities. |
| H-1 | FINDINGS1 | fixed | `tools/tests/integration/mock_dd_server.py` | Added `MAX_BODY_SIZE` guard to prevent unbounded request body reads. |
| H-2 | FINDINGS1 | fixed | `tools/tests/integration/mock_dd_server.py` | Narrowed coverage payload parse exception handling from broad `Exception` to explicit parser error types. |
| H-3 | FINDINGS1 | fixed | `tools/requirements.txt`, `CONTRIBUTING.md` | Added explicit Python dependency manifest and contributor install guidance. |
| H-4 | FINDINGS1 | fixed | `tools/core/test_optimization_sync.bzl`, `tools/tests/core/test_sync_utils.bzl` | Expanded CI provider mapping tests to cover the full provider matrix and added Buddy extraction checks. |
| H-5 | FINDINGS1 | fixed | `tools/dev/check_module_versions.py` | Replaced brittle `parents[2]` assumption with validated repository-root discovery. |
| H-6 | FINDINGS1 | fixed | `tools/dev/check_module_versions.py` | Aligned root detection strategy with other Python tooling via parent-walk module root discovery. |
| H-7 | FINDINGS1 | fixed | `tools/tests/integration/mock_dd_server.py` | Added startup fixture existence/JSON validation with clear error messages. |
| H-8 | FINDINGS1 | fixed | `README.md` | Added `module_label_override` guidance and usage example in import path inference docs. |
| H-9 | FINDINGS1 | fixed | `tools/tests/integration/run_mock_server_tests.sh` | Added dedicated repository-rule fetch/query smoke before baseline scenarios to assert sync-generated labels resolve. |
| H-10 | FINDINGS1 | clarified-intent | `tools/tests/integration/run_mock_server_tests.sh` | Harness already executes `bazel run //:dd_upload_payloads` across multiple scenarios; coverage now explicitly retained as canonical uploader E2E path. |
| H-11 | FINDINGS1 | fixed | `tools/core/test_optimization_uploader.bzl`, `docs/Maintainers.md` | Kept intentional `UPLOADER_VERSION`/`RULES_VERSION` divergence and documented rationale inline and in maintainer docs. |
| H-12 | FINDINGS1 | fixed | `tools/tests/integration/run_mock_server_tests.ps1` | Improved Git Bash discovery with env override, git-derived sibling path, and PATH fallback. |
| H-13 | FINDINGS1 | fixed | `tools/tests/integration/mock_dd_server.py` | Split text and bytes response helpers (`_send_text` / `_send_bytes`) to remove ambiguous mixed payload contract. |
| H-14 | FINDINGS1 | fixed | `tools/core/validate_payload_schema.py`, `tools/tests/python/test_python_tools.py` | Added `_reset_stats()` at `main()` entry and regression test for non-accumulating stats. |
| M-1 | FINDINGS1 | fixed | `tools/core/validate_payload_schema.py`, `tools/tests/python/test_python_tools.py` | Enforced `max_errors` checks immediately after each numeric bound append. |
| M-2 | FINDINGS1 | verified-not-actionable | `tools/core/schemas/sync_agentless_schema.py` | Parser defaults are resolved at runtime argument parsing; no import-time side effects to remediate. |
| M-3 | FINDINGS1 | fixed | `tools/tests/python/test_python_tools.py` | Replaced hardcoded `/tmp` path with `tempfile.gettempdir()` for platform safety. |
| M-4 | FINDINGS1 | fixed | `.github/workflows/ci.yml` | Raised tools coverage minimum signal from 5.0% to 30.0%. |
| M-5 | FINDINGS1 | fixed | `.github/workflows/ci.yml` | Removed hardcoded inline fallback; workflow now requires `TOOLS_COVERAGE_MIN` env value. |
| M-6 | FINDINGS1 | fixed | `tools/tests/integration/mock_dd_server.py` | Keyboard interrupt now emits explicit shutdown message. |
| M-7 | FINDINGS1 | fixed | `tools/core/test_optimization_sync.bzl`, `tools/tests/core/test_sync_utils.bzl` | Implemented Buddy CI metadata extraction and added test coverage. |
| M-8 | FINDINGS1 | fixed | `tools/core/test_optimization_sync.bzl`, `docs/Configuration_Reference.md` | Standardized AWS CodeBuild provider naming to `awscodebuild` and documented emitted provider value. |
| M-9 | FINDINGS1 | fixed | `.github/workflows/ci.yml` | Added CI drift guard (`cmp`) to enforce parity between example `.bazelrc` files. |
| M-10 | FINDINGS1 | fixed | `tools/dev/go_bootstrap.bzl`, `tools/tests/core/test_go_bootstrap_utils.bzl`, `tools/tests/core/BUILD.bazel` | Added unit coverage for go bootstrap path-validation helper. |
| M-11 | FINDINGS1 | fixed | `tools/tests/python/run_bazelw_wrapper_test.sh`, `tools/tests/python/BUILD.bazel`, `BUILD.bazel` | Added wrapper smoke tests that validate `bazelw` command parsing and `--repo_env` injection behavior. |
| M-12 | FINDINGS1 | fixed | `AGENTS.md`, `CONTRIBUTING.md` | Established `CONTRIBUTING.md` as canonical command matrix source and reduced duplication drift risk. |
| M-13 | FINDINGS1 | fixed | `tools/core/test_optimization_uploader.bzl`, `tools/tests/core/test_uploader_utils.bzl`, `tools/tests/core/BUILD.bazel` | Reworked template rendering to single-pass substitution and added regression test for non-recursive placeholder collisions. |
| M-14 | FINDINGS1 | fixed | `tools/tests/integration/run_mock_server_tests.sh` | Added schema-validator checks for integration snapshots (`citestcycle`, coverage event, coverage payload). |
| M-15 | FINDINGS1 | clarified-intent | `tools/core/test_optimization_sync.bzl` | Applied targeted maintainability extraction (`_set_context_tag_from_env`) without risky large-file split in this remediation PR. |
| M-16 | FINDINGS1 | fixed | `tools/core/test_optimization_sync.bzl`, `tools/tests/core/test_sync_utils.bzl` | Removed brittle pre-decode malformed JSON suffix heuristics and updated failure-path tests to rely on parser diagnostics. |
| M-17 | FINDINGS1 | fixed | `tools/core/test_optimization_sync.bzl` | Improved unknown-character fingerprint bucketing and documented non-cryptographic hashing limits inline. |
| M-18 | FINDINGS1 | fixed | `examples/single_service/src/go-project/main_test.go`, `examples/multi_service/src/go-project/main_test.go` | Added manifest/metadata assertions so example tests exercise synced test-optimization artifacts directly. |
| L-1 | FINDINGS1 | fixed | `tools/tests/integration/mock_dd_server.py` | Added type annotations across core helpers/server state and response methods. |
| L-2 | FINDINGS1 | clarified-intent | `examples/single_service/src/go-project/main_test.go`, `examples/multi_service/src/go-project/main_test.go` | Helpers remain duplicated intentionally because each example workspace is standalone and copy-paste friendly for consumers. |
| L-3 | FINDINGS1 | fixed | `examples/single_service/src/go-project/main_test.go`, `examples/multi_service/src/go-project/main_test.go` | `resolveRlocation` now returns explicit success signal (`path, ok`) and callers handle unresolved paths directly. |
| L-4 | FINDINGS1 | fixed | `.gitignore` | Added explicit note that `MODULE.bazel.lock` is intentionally tracked. |
| L-5 | FINDINGS1 | fixed | `CONTRIBUTING.md` | Documented action SHA pinning maintenance strategy (keep SHA and version comments updated together). |
| L-6 | FINDINGS1 | verified-not-actionable | `examples/*/.bazelrc` | Existing hermetic flags remain intentionally explicit for cross-version compatibility; no redundant-flag removal performed. |
| L-7 | FINDINGS1 | fixed | `tools/core/topt_macro_utils.bzl`, `modules/go/topt_go_test.bzl` | Normalized `is_dict` aliasing style to a consistent `_is_dict` internal convention. |
| L-8 | FINDINGS1 | clarified-intent | `tools/core/topt_selection_utils.bzl` | Empty-string return semantics for disabled/no-match selection are explicitly documented and preserved for compatibility. |
| L-9 | FINDINGS1 | fixed | `tools/core/test_optimization_sync.bzl` | Extracted nested `_opt` logic into reusable top-level helper `_set_context_tag_from_env`. |
| L-10 | FINDINGS1 | fixed | `tools/tests/python/test_python_tools.py` | Added additional validator edge tests (invalid `patternProperties`, max-error bounds, stats reset behavior). |
| L-11 | FINDINGS1 | fixed | `tools/core/common_utils.bzl`, `tools/tests/core/test_common_utils.bzl` | Hardened dedup collision handling to avoid suffixed-key collisions and added regression case. |
| L-12 | FINDINGS1 | fixed | `tools/core/common_utils.bzl` | Increased visibility for service names with spaces by emitting explicit user-facing warnings. |
| L-13 | FINDINGS1 | verified-not-actionable | `tools/core/test_optimization_sync.bzl` | Context-tag insertion remains guarded by non-empty value checks; empty tags are not emitted. |
| L-14 | FINDINGS1 | fixed | `tools/core/common_utils.bzl`, `tools/tests/core/test_common_utils.bzl` | Reduced all-invalid sanitization collisions using deterministic `module_<suffix>` fallback for non-empty invalid inputs. |
| L-15 | FINDINGS1 | clarified-intent | `.github/chainguard/github.rules_test_optimization_tests.sts.yaml` | Added explicit rationale that hardcoded upstream repository claims are intentional for OIDC trust scoping. |
| L-16 | FINDINGS1 | fixed | `tools/tests/integration/run_mock_server_tests.sh` | Added additional signal traps and server PID file for safer cleanup/recovery tooling. |
| L-17 | FINDINGS1 | clarified-intent | `tools/core/test_optimization_sync.bzl` | JSON round-trip deep-copy tradeoff remains intentional and documented for deterministic payload cloning behavior. |
| F2-1 | FINDINGS2 | fixed | `README.md`, `docs/Installation_Reference.md`, `.github/workflows/ci.yml` | Standardized WORKSPACE canonical repo name to `datadog-rules-test-optimization` and added workspace-mode CI smoke loading. |
| F2-2 | FINDINGS2 | fixed | `modules/go/topt_go_test.bzl`, `modules/go/tests/test_macro.bzl`, `README.md` | Resolved `rundir` behavior mismatch by honoring explicit values and documenting macro behavior. |
| F2-3 | FINDINGS2 | fixed | `modules/go/tests/test_macro.bzl`, `modules/go/tests/test_payloads_selector.bzl`, `modules/go/tests/test_selection_utils.bzl`, `AGENTS.md`, `CONTRIBUTING.md` | Made Go companion test loads repo-qualified so root `./bazelw test //...` works and documented canonical full-repo command. |
| F2-4 | FINDINGS2 | fixed | `tools/tests/core/BUILD.bazel` | Added previously omitted test targets to `//tools/tests/core:tests` suite. |
| F2-5 | FINDINGS2 | fixed | `README.md`, `docs/Installation_Reference.md` | Updated onboarding snippets to set explicit `service` and document fallback behavior. |
| F2-6 | FINDINGS2 | fixed | `.github/workflows/ci.yml` | Added dedicated `workspace-compat` CI job that validates WORKSPACE-mode core/go/uploader load paths. |
| F2-7 | FINDINGS2 | fixed | `tools/tests/example_stub_repo.bzl`, `tools/tests/core/test_sync_utils.bzl`, `tools/tests/core/BUILD.bazel` | Escaped generated Starlark string literals and added regression coverage for unsafe characters. |
| F2-8 | FINDINGS2 | fixed | `SECURITY.md` | Added repository security policy and private vulnerability reporting channels. |
| F2-9 | FINDINGS2 | fixed | `.github/workflows/ci.yml`, `.github/workflows/security.yml`, `.github/workflows/docs-links.yml` | Added workflow concurrency controls and job-level timeout bounds. |
