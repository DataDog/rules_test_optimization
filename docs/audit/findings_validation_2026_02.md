# Findings Validation And Remediation Tracker (2026-02)

This tracker is the execution ledger for findings in:
- `/Users/tony.redondo/Downloads/findings01.md`
- `/Users/tony.redondo/Downloads/findings02.md`

Disposition meanings:
- `fix`: code/test/workflow/doc change required in this branch.
- `mitigate-doc`: keep behavior but add/strengthen policy and rationale documentation.
- `close-no-change`: finding is false/unverifiable/already addressed; keep evidence in PR.

## Findings 01

| ID | Validation | Disposition | Done | Evidence |
| --- | --- | --- | --- | --- |
| 1.1 | true | fix | [x] | `tools/core/test_optimization_sync_env.bzl`, `tools/tests/core/test_sync_utils.bzl` |
| 2.1 | true | fix | [x] | `modules/go/topt_go_test.bzl`, `modules/go/tests/test_macro.bzl` |
| 2.2 | true | fix | [x] | `tools/core/test_optimization_sync.bzl` |
| 2.3 | partially_true | fix | [x] | `tools/core/test_optimization_sync.bzl`, command/path guard tests |
| 2.4 | true | close-no-change | [x] | Bazel predeclared `platform_common` documented in PR rationale |
| 2.5 | partially_true | fix | [x] | New env-helper coverage in `tools/tests/core/test_sync_utils.bzl` |
| 3.1 | true | fix | [x] | `_MAX_REF_STRIP_ITERATIONS` in `test_optimization_sync_env.bzl` |
| 3.2 | true | fix | [x] | `_split_json_payload_by_module` in `test_optimization_sync.bzl` |
| 3.3 | true | fix | [x] | Fail-prefix policy + targeted sync prefix cleanup (`test_optimization_sync`) |
| 3.4 | true | mitigate-doc | [x] | Decomposition roadmap in `docs/Maintainers.md` |
| 3.5 | true | mitigate-doc | [x] | Bazel baseline/workspace-compat clarified in `README.md` |
| 3.6 | true | fix | [x] | `tools/dev/check_module_versions.py` validates `RULES_VERSION` alignment |
| 3.7 | true | fix | [x] | Step-level timeouts in `.github/workflows/ci.yml` |
| 3.9 | partially_true | fix | [x] | `DD_TEST_OPTIMIZATION_MAX_WAIT_SEC=0` scenario in integration harness |
| 3.10 | true | fix | [x] | Mock body-limit configurability in `tools/tests/integration/mock_dd_server.py` |
| 3.11 | true | fix | [x] | Pre-check readable input files in `validate_payload_schema.py` |
| 3.12 | true | fix | [x] | Expanded tools coverage target list in CI workflow |
| 3.13 | true | mitigate-doc | [x] | Schema source-of-truth workflow in `CONTRIBUTING.md` + `docs/Maintainers.md` |
| 3.14 | true | fix | [x] | `CHANGELOG.md` + `SECURITY.md` added to docs-links workflow |
| 3.15 | false | close-no-change | [x] | Existing Windows Git Bash prerequisite remains documented/guarded |
| 3.16 | partially_true | fix | [x] | Control-character path rejection + command builder failure test |
| 3.17 | true | mitigate-doc | [x] | Linux-only hermetic scope policy documented in maintainer/contrib docs |
| 3.18 | true | fix | [x] | Added `1.0.0` section to `CHANGELOG.md` |
| 4.1 | unverifiable | close-no-change | [x] | Historical RFC date left unchanged (no authoritative repo evidence) |
| 4.2 | true | fix | [x] | Targeted cleanup while touching affected paths |
| 4.3 | true | fix | [x] | `RUNTESTS_DRY_RUN` documented in `examples/README.md` |
| 4.4 | partially_true | fix | [x] | Filter-prefix purpose clarified in `docs/Uploader_Reference.md` |
| 4.5 | true | fix | [x] | Determinism + known-vector hash assertions in sync utility tests |
| 4.6 | true | fix | [x] | Strengthened macro/stub assertions and new env-none regression test |
| 4.7 | partially_true | close-no-change | [x] | Intentional cache-busting retained; policy documented |
| 4.9 | partially_true | fix | [x] | Explicit `MAX_WAIT_SEC` behavior section in uploader docs |
| 4.10 | true | fix | [x] | Codefresh sha/repository mapping in `test_optimization_sync_env.bzl` + tests |
| 4.11 | true | fix | [x] | Added empty/minimal environment regression test |
| 4.12 | true | fix | [x] | Shared sanitization constant reused via `common_utils` |
| 4.14 | false | close-no-change | [x] | `FETCH_SALT_TTL` documentation already present; retained |
| 4.15 | true | mitigate-doc | [x] | ShellCheck severity policy rationale documented in CI workflow |

## Findings 02

| ID | Validation | Disposition | Done | Evidence |
| --- | --- | --- | --- | --- |
| F-01 | true | fix | [x] | Buildifier checksum verification in `.github/workflows/ci.yml` |
| F-02 | true | fix | [x] | Strict DD_SITE hostname validation in sync + uploader templates |
| F-03 | true | fix | [x] | Event-aware Buildifier diff range logic in CI workflow |
| F-04 | true | fix | [x] | Expanded Python tools coverage target list |
| F-05 | true | fix | [x] | Unsupported schema keywords now error by default (+ warn-mode override) |
| F-06 | true | fix | [x] | `actions/setup-python` with pinned version in CI/release jobs |
| F-07 | true | fix | [x] | Release workflow always runs full validation path |
| F-08 | true | fix | [x] | Explicit Windows `jq` setup/check step in CI |
| F-09 | true | mitigate-doc | [x] | README clarifies 8.5.1 baseline vs 8.4.1 workspace-compat lane |
| F-10 | true | fix | [x] | Deterministic Python dependency pin (`PyYAML==6.0.3`) |
| F-11 | true | fix | [x] | Docs link-check scope now includes `CHANGELOG.md` + `SECURITY.md` |
| F-12 | true | fix | [x] | Parser parity tool now emits actionable install/remediation hints |
| F-13 | true | mitigate-doc | [x] | Decomposition roadmap added to maintainer docs |
| F-14 | true | fix | [x] | Local lint prerequisites documented in `CONTRIBUTING.md` |

## Close-No-Change Acceptance Criteria

- Include code/doc evidence links in PR description for `2.4`, `3.15`, `4.1`, `4.7`, and `4.14`.
- For `4.1`, keep as unresolved historical metadata unless maintainer provides authoritative date source.
