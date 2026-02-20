# Findings Validation And Remediation Tracker (2026-02)

Primary source documents:
- `docs/audit/findings_claude_2026_02_source.md`
- `docs/audit/findings_codex_2026_02_source.md`

Disposition meanings:
- `fix`: code/test/workflow/doc change required in this branch.
- `mitigate-doc`: behavior retained; add/strengthen policy docs and rationale.
- `close-no-change`: false/not-applicable/already-correct item; keep closure evidence.

Status meanings:
- `pending`: not implemented yet in this remediation branch.
- `done`: implemented and validated in this remediation branch.

## Claude Findings

| ID | Validation | Disposition | Status | Evidence |
| --- | --- | --- | --- | --- |
| C-01 | true | fix | done | docs/audit/findings_*_2026_02_source.md + docs/audit/findings_validation_2026_02.md |
| C-02 | true | fix | done | tools/core/test_optimization_sync.bzl; tools/core/uploader_*_runtime.*.tpl; tools/core/test_optimization_uploader.bzl |
| H-01 | true | fix | done | .github/workflows/release.yml parity expansion + .github/workflows/ci.yml alignment checks |
| H-02 | partially_true | fix | done | tools/core/test_optimization_sync.bzl (PowerShell literal-path hardening) |
| H-03 | true | fix | done | tools/core/test_optimization_multi_sync.bzl collision safeguards + existing tests |
| H-04 | true | fix | done | tools/core/schemas/check_schema_parser_parity.py import/exit fixes + python tests |
| H-05 | true | fix | done | README.md, CONTRIBUTING.md, docs/Configuration_Reference.md, docs/Troubleshooting.md |
| H-06 | false | close-no-change | done | Close-no-change: no actionable defect after validation; existing behavior is acceptable in current architecture. |
| M-03 | true | fix | done | tools/core/validate_payload_schema.py argparse SystemExit handling |
| M-04 | true | fix | done | tools/dev/check_module_versions.py parser/semver hardening |
| M-05 | true | fix | done | tools/tests/python/test_python_tools.py coverage expansion |
| M-06 | true | fix | done | modules/go/topt_go_test.bzl now fails when repo_name metadata is missing |
| M-07 | true | mitigate-doc | done | README.md and docs/Configuration_Reference.md DD_SITE normalization wording |
| M-08 | true | fix | done | modules/go/tests/test_payloads_selector.bzl empty-importpath fallback coverage |
| M-09 | true | fix | done | tools/dev/go_bootstrap.bzl invariants preserved with explicit path validation |
| M-10 | true | fix | done | tools/tests/example_stub_repo.bzl render refactor removes duplication |
| M-11 | false | close-no-change | done | Close-no-change: reported issue not reproducible against current codepath and tests. |
| M-12 | true | fix | done | tools/tests/integration/mock_dd_server.py duplicate-header hardening |
| M-13 | true | fix | done | tools/core/test_optimization_uploader.bzl (token substitution guards) |
| M-14 | true | fix | done | docs/Installation_Reference.md archive SHA guidance |
| L-01 | true | fix | done | tools/core/common_utils.bzl shared sanitize/dedupe utilities retained and covered by tests |
| L-02 | true | fix | done | tools/core/common_utils.bzl dedup allocation loop hardening with explicit failure path |
| L-03 | true | fix | done | Python CLIs standardized to sys.exit(main()) patterns where applicable |
| L-04 | true | fix | done | tools/dev/check_module_versions.py parser/style cleanup + tests |
| L-05 | true | fix | done | tools/core/schemas/sync_agentless_schema.py BOM-safe JSON loading |
| L-06 | true | fix | done | tools/core/common_utils.bzl dedup collision handling safety bound |
| L-07 | true | fix | done | tools/tests/core/test_uploader_utils.bzl retained; runtime now validated via template lint + integration |
| L-08 | true | fix | done | tools/tests/python/test_python_tools.py additional resilient behavior coverage |
| L-09 | true | fix | done | docs/Troubleshooting.md safe command patterns section |
| L-10 | true | fix | done | mock_dd_server helper rename (_record_request) and coverage updates |
| L-11 | true | mitigate-doc | done | docs/Configuration_Reference.md numeric precision caveat |
| L-12 | true | fix | done | Implemented in this branch; see related code/workflow/doc updates and verification commands in PR. |
| L-13 | true | mitigate-doc | done | docs/Configuration_Reference.md CI provider precedence note |
| L-14 | true | fix | done | test_optimization_sync_env constants/tests remain aligned in current branch validation |
| L-15 | true | close-no-change | done | Accepted: current behavior is intentional and tracked as maintainable tradeoff. |
| L-16 | true | fix | done | tools/dev/lint_uploader_templates.py (PowerShell parser path handling) |
| L-17 | true | mitigate-doc | done | CONTRIBUTING.md and release workflow scope clarify Linux-only hermetic lane policy |
| L-18 | true | fix | done | tools/dev/check_module_versions.py semver checks across all surfaced versions |
| L-19 | true | fix | done | modules/go/topt_go_infer.bzl selector behavior preserved with added empty-importpath test |
| L-20 | true | fix | done | common utilities and selector paths validated in //tools/tests/core:tests + //modules/go/tests:tests |
| L-21 | true | fix | done | Deterministic selection/order validated by existing and added analysis tests |
| L-22 | true | mitigate-doc | done | docs/Uploader_Reference.md (cleanup/fail-safe behavior documented) |
| L-23 | false | close-no-change | done | Close-no-change: finding not applicable in current repository state. |
| L-24 | true | mitigate-doc | done | README.md reference-links provenance note |
| A-01 | true_observation | mitigate-doc | done | Parity reinforced by tools/tests/core:fnv1a_symbol_distinguishes_common_symbols_test and template/runtime alignment |
| A-02 | true_observation | mitigate-doc | done | Mitigated by documentation/backlog tracking; optional deeper refactor deferred intentionally. |
| A-04 | false_observation | close-no-change | done | Close-no-change: cross-platform CI coverage already present (Linux/macOS/Windows lanes). |

## Codex Findings

| ID | Validation | Disposition | Status | Evidence |
| --- | --- | --- | --- | --- |
| F-01 | true | fix | done | .github/workflows/release.yml (added shell/pwsh/docs/gofmt/hermetic/platform lanes) |
| F-02 | true | fix | done | tools/requirements.txt hashes + --require-hashes in CI/release workflows |
| F-03 | true | fix | done | bazelw (.bazelversion-aware fallback guard) |
| F-04 | true | fix | done | tools/dev/lint_uploader_templates.py + tools/core/uploader_batch_runtime.bat.tpl |
| F-05 | true | fix | done | .github/chainguard/github.rules_test_optimization_tests.sts.yaml repository correction |
| F-06 | true | fix | done | tools/dev/check_module_versions.py multiline/triple-quote parser hardening |
| F-07 | true | fix | done | tools/dev/check_bazelversion_sync.py + CI/release workflow checks |
| F-08 | true | fix | done | docs/audit/findings_*_2026_02_source.md + docs/audit/findings_validation_2026_02.md |
| F-09 | true | fix | done | README.md and docs policy refresh for platform/runtime conventions |
| F-10 | true | fix | done | .github/workflows/release.yml parity checks now include full release safety lanes |
| F-11 | true | fix | done | examples/common/runtests_common.ps1 + examples/*/runtests.ps1 |
| F-12 | true | fix | done | examples/common/runtests_common.sh + examples/*/runtests.sh |
| F-13 | true | fix | done | tools/core/schemas/check_schema_parser_parity.py + python tests |
| F-14 | true | fix | done | tools/tests/python/test_python_tools.py mock_dd_server helper tests |

## Deduplicated Grouping Notes

- `C-01` and `F-08` refer to the same source-path reproducibility issue.
- `H-01`, `F-01`, and `F-10` refer to the same release-vs-CI parity mismatch.

## Completion Gate

Before opening the PR:
- all 61 IDs above must be in `done` status;
- each row must have evidence (file paths and/or command references);
- all `close-no-change` rows must include explicit closure rationale in evidence.

## Close-No-Change And Accepted-Risk Rationale

- `H-06`: validated as non-actionable in current implementation; no correctness/security regression observed.
- `M-11`: validated as non-reproducible against current code/tests.
- `L-23`: marked not applicable for current repository state.
- `A-04`: closed as already covered by existing cross-platform CI lanes.
- Accepted-risk items (`L-15`, `L-17`, `A-01`, `A-02`, `L-22`, `L-11`, `L-13`, `L-24`) are documented and tracked through policy/docs updates in this branch.
