# Audit Findings Remediation Register

This register tracks deduplicated findings from:

- `/Users/tony.redondo/Downloads/findings10.md`
- `/Users/tony.redondo/Downloads/findings11.md`

## Completion Checklist

- [x] `all_confirmed_closed`
- [x] `all_partial_closed`
- [x] `all_not_confirmed_rationalized`
- [x] `all_deferred_issued`

## Validation Evidence

The following remediation validation matrix was executed after applying fixes:

- `./bazelw test //tools/...` (pass)
- `./bazelw build //examples/...` (pass)
- `cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..` (pass)
- `tools/tests/integration/run_mock_server_tests.sh` (pass)
- `python3 tools/dev/check_module_versions.py` (pass)
- `./bazelw test //tools/... --spawn_strategy=sandboxed --strategy=TestRunner=sandboxed --sandbox_default_allow_network=false --modify_execution_info=TestRunner=+block-network --test_env=TZ=UTC --test_env=LANG=C --test_env=LC_ALL=C --enable_runfiles` (pass)
- `cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../.. --spawn_strategy=sandboxed --strategy=TestRunner=sandboxed --sandbox_default_allow_network=false --modify_execution_info=TestRunner=+block-network --test_env=TZ=UTC --test_env=LANG=C --test_env=LC_ALL=C --enable_runfiles` (pass)

## Legend

- Verdict: `confirmed`, `partial`, `not_confirmed`
- Disposition: `fix_now`, `fix_doc`, `no_action`, `defer_with_issue`
- Status: `open`, `in_progress`, `closed`

## Findings Register

| ID | Source IDs | Finding | Verdict | Disposition | Phase | Status | Verification | Closing commit |
|---|---|---|---|---|---|---|---|---|
| F001 | F10-H1 | Multi-sync extension missing HTTP policy attrs parity with single-sync | confirmed | fix_now | 1 | closed | bazel core test suite | TBD |
| F002 | F10-H2 | `dd_payload_uploader` explicit visibility not set | confirmed | fix_now | 1 | closed | uploader macro default visibility | TBD |
| F003 | F10-H3, F11-M5 | Uploader implementation concentrated in very large monolithic template/file | confirmed | fix_now | 4 | closed | uploader templates extracted into dedicated modules + expanded uploader utility/integration coverage | TBD |
| F004 | F10-H4 | Go infer importpath typing edge case not hardened | partial | fix_now | 4 | closed | type-guarded importpath inference + tests | TBD |
| F005 | F10-C3 | `validate_payload_schema.py` internals lack direct unit tests | confirmed | fix_now | 3 | closed | direct helper/unit coverage added | TBD |
| F006 | F10-C4, F10-C8 | Missing comprehensive uploader failure/retry integration scenarios | partial | fix_now | 2 | closed | new 4xx/5xx/unreachable/coverage retry scenarios | TBD |
| F007 | F10-C5 | Integration snapshot strictness risk (`citestcov` fixtures too weak) | partial | fix_now | 2 | closed | non-empty coverage fixtures + strict assertions | TBD |
| F008 | F10-C6 | Mock retry counters shared state brittleness across scenarios | partial | fix_now | 2 | closed | retry-counter reset endpoint + scenario resets | TBD |
| F009 | F10-C7 | `log_info`, `log_debug`, `is_dict` lacking direct tests | confirmed | fix_now | 3 | closed | common utils unit tests added | TBD |
| F010 | F10-H11 | Uploader helper functions missing unit tests | confirmed | fix_now | 3 | closed | uploader helper + parser parity tests added | TBD |
| F011 | F10-H12 | Sync HTTP helper internals under-tested at unit level | confirmed | fix_now | 3 | closed | sync helper coverage expanded | TBD |
| F012 | F10-H13 | `_collect_env(ctx)` wrapper not directly tested | confirmed | fix_now | 3 | closed | collect_env ctx wrapper test added | TBD |
| F013 | F10-H14 | No empty-input tests for `_build_module_label_map` | confirmed | fix_now | 3 | closed | empty-input mapping test added | TBD |
| F014 | F10-H15 | `load_yaml` fallback path (PyYAML/Ruby) not tested | confirmed | fix_now | 3 | closed | fallback and failure python tests added | TBD |
| F015 | F10-H16 | Windows integration harness forces debug and softens gzip assertion behavior | confirmed | fix_now | 2 | closed | default debug parity + strict gzip assertion | TBD |
| F016 | F10-H17 | PowerShell integration entrypoint is intentionally thin wrapper around Bash | confirmed | no_action | 0 | closed | design documented | N/A |
| F017 | F10-H18 | Runfile parity tests miss explicit not-found parity assertion | partial | fix_now | 3 | closed | explicit not-found parity test added | TBD |
| F018 | F10-H19, F10-M31, F10-M38, F10-L32 | Several tests rely on brittle substring checks vs stronger structure assertions | confirmed | fix_now | 3 | closed | additional structural/unit assertions added | TBD |
| F019 | F10-H20, F10-H25, F10-L30 | `check_module_versions.py` tests miss failure/malformed cases | confirmed | fix_now | 3 | closed | negative and main-path mismatch tests added | TBD |
| F020 | F10-H21 | Missing no-API-key branch tests for `_partition_unix_headers` | confirmed | fix_now | 3 | closed | missing-key branch test added | TBD |
| F021 | F10-H22 | `normalize_ref` edge-case coverage incomplete | partial | fix_now | 3 | closed | refs edge-case normalization tests added | TBD |
| F022 | F10-H23 | EVP unreachable/wrong URL integration test scenario missing | confirmed | fix_now | 2 | closed | unreachable intake failure scenario added | TBD |
| F023 | F10-H24, F10-L29 | `render_stub_build` service-key path missing direct tests | confirmed | fix_now | 3 | closed | service-suffixed stub target test added | TBD |
| F024 | F10-H26 | CI provider matrix tests missing (GitLab/Jenkins/Buildkite, etc.) | confirmed | fix_now | 3 | closed | provider matrix coverage expanded | TBD |
| F025 | F10-H27 | Duplicate `Manual.SectionHeaderIgnored` finding | not_confirmed | no_action | 0 | closed | verified unique scenario | N/A |
| F026 | F10-M1 | `validate_payload_schema` number branch control-flow consistency concern | confirmed | fix_now | 4 | closed | scalar early-return + bounds handling cleanup | TBD |
| F027 | F10-M2 | Duplicate DD-API-KEY header injection concern in PowerShell path | not_confirmed | no_action | 0 | closed | map semantics ensure unique keys | N/A |
| F028 | F10-M3, F10-M4 | `filter_prefix` naming inconsistency across attr/internal/template vars | confirmed | fix_now | 4 | closed | internal naming normalized (`filter_prefix`) | TBD |
| F029 | F10-M5, F10-M47 | `test_optimization_sync.bzl` too broad; env collection overly large function | confirmed | fix_now | 4 | closed | DD_GIT override helper extracted for env collector | TBD |
| F030 | F10-M6, F10-M48 | Multi-sync aggregate generation via string concat; shared behavior divergence risk | confirmed | fix_now | 4 | closed | aggregate rendering tests + aggregator docs alignment | TBD |
| F031 | F10-M7 | `is_dict` idiom/style concern | confirmed | no_action | 0 | closed | style-only concern; behavior covered by direct unit tests | N/A |
| F032 | F10-M8 | Redundant `.get()` lookups in module label merge loop | confirmed | fix_now | 4 | closed | duplicate lookups removed in module loop | TBD |
| F033 | F10-M9 | `platform_common` usage clarity concern | partial | fix_doc | 5 | closed | uploader target-platform constraint comments clarified | TBD |
| F034 | F10-M10 | Provider fallback may mask rules_go changes | confirmed | fix_doc | 5 | closed | fallback precedence documented + selector/infer tests expanded | TBD |
| F035 | F10-M11 | Go test macro does not validate labels against existing exported targets | confirmed | fix_now | 4 | closed | sanitized label validation + failure tests | TBD |
| F036 | F10-M12 | `module_included` missing disables per-module selection silently | confirmed | fix_now | 4 | closed | fallback now enables per-module when labels exist | TBD |
| F037 | F10-M13 | `rundir` mismatch validation absent | confirmed | fix_now | 4 | closed | custom rundir normalized to package path + tests | TBD |
| F038 | F10-M14, F10-M15, F10-L7, F10-L8 | API key / command env handling security notes (mostly by design) | confirmed | fix_doc | 5 | closed | uploader credential handling guidance clarified | TBD |
| F039 | F10-M16, F11-H4 | Security automation scope narrow (CodeQL + Dependabot) | confirmed | fix_now | 1 | closed | security/dependabot workflow updates | TBD |
| F040 | F10-M17, F10-M18 | Missing explicit workflow permissions in CI/docs workflows | partial | fix_now | 1 | closed | workflow permissions blocks added | TBD |
| F041 | F10-M19 | Hermetic lane Linux-only (intentional policy) | confirmed | fix_doc | 5 | closed | maintainer CI policy documents Linux-only hermetic rationale | TBD |
| F042 | F10-M20, F11-H2 | Coverage gate effectively non-blocking (`0/0` passes; tiny threshold) | confirmed | fix_now | 1 | closed | CI gate now fails on non-actionable signal | TBD |
| F043 | F10-M21 | ShellCheck install command Ubuntu-specific risk | partial | no_action | 0 | closed | job pinned to ubuntu | N/A |
| F044 | F10-M22 | Example single vs multi extensions differ (intentional product surface) | confirmed | no_action | 0 | closed | design documented | N/A |
| F045 | F10-M23 | `go_bootstrap` hardcoded path coupling | confirmed | fix_doc | 5 | closed | bootstrap path constraints documented and validated | TBD |
| F046 | F10-M24, F10-M26, F10-H10 | Multi-service uploader usage under-documented | confirmed | fix_now | 5 | closed | uploader/install/examples docs now include multi-service data patterns | TBD |
| F047 | F10-M25 | HTTP `-1` override semantics need clearer docs | partial | fix_doc | 5 | closed | configuration reference clarifies `-1` fallback resolution | TBD |
| F048 | F10-M27 | Terminology drift (`svc` vs sanitized service keys) | partial | fix_doc | 5 | closed | docs normalized around "service key"/sanitized naming | TBD |
| F049 | F10-M28, F10-L18 | `DD_TEST_OPTIMIZATION_FILTER_PREFIX` default behavior unclear in docs | confirmed | fix_now | 5 | closed | default and enabled behavior clarified in docs tables | TBD |
| F050 | F10-M29, F10-L24, F10-L28 | Multi-service `aggregate.bzl`/export behavior not clearly documented | partial | fix_now | 5 | closed | examples + uploader/install docs expanded for aggregator outputs | TBD |
| F051 | F10-M30, F10-L21, F10-H8, F10-H9 | Examples drift: `git_override` guidance mismatched with example MODULE files | confirmed | fix_now | 5 | closed | example MODULE comments and docs guidance aligned | TBD |
| F052 | F10-M32, F10-M33, F10-M39, F10-M40 | Additional uploader/sync test edge-case coverage gaps | partial | fix_now | 3 | closed | extra manifest/clone/normalize edge tests added | TBD |
| F053 | F10-M34 | `parse_go_module_path` edge cases missing | confirmed | fix_now | 3 | closed | parse-go edge tests added | TBD |
| F054 | F10-M35 | `dedup_keys` deterministic behavior coverage can be stronger | confirmed | fix_now | 3 | closed | deterministic duplicate-order coverage added | TBD |
| F055 | F10-M36 | Unicode sanitization tests narrow | partial | fix_now | 3 | closed | additional unicode sanitization tests added | TBD |
| F056 | F10-M37 | FNV uniqueness/collision test concern mostly heuristic | partial | no_action | 0 | closed | non-actionable collision proof | N/A |
| F057 | F10-M41 | Missing mock `PORT=` timeout handling claim | not_confirmed | no_action | 0 | closed | timeout already present | N/A |
| F058 | F10-M42 | `.cmd` wrapper error clarity can be improved | confirmed | fix_now | 2 | closed | explicit powershell presence check in .cmd | TBD |
| F059 | F10-M43, F11-M3 | Integration tests outside Bazel suite graph | confirmed | fix_now | 1 | closed | explicit policy documented in tools/tests BUILD | TBD |
| F060 | F10-M44, F10-M45, F10-L38 | `check_module_versions.py` parsing/path assumptions brittle | confirmed | fix_now | 4 | closed | parser/dep extraction hardened + tests | TBD |
| F061 | F10-M46 | `go_bootstrap` path existence validation not explicit | partial | fix_now | 4 | closed | bootstrap path validation now enforces non-empty relative path and verifies `MODULE.bazel` exists at target path | TBD |
| F062 | F10-M49 | Fixture schema expectations undocumented/inconsistent | confirmed | fix_now | 5 | closed | fixture contract documented + strict snapshot assertions | TBD |
| F063 | F10-M50 | Mixed analysistest/unittest style consistency note | confirmed | no_action | 0 | closed | style preference; no defect | N/A |
| F064 | F10-M51 | Trailing-newline JSON render test does not validate parseability | confirmed | fix_now | 3 | closed | JSON parseability assertion added | TBD |
| F065 | F10-L1 | `_debug()` global coupling in schema validator script | confirmed | fix_now | 4 | closed | debug helper decoupled from main-only global state | TBD |
| F066 | F10-L2 | Minor docstring formatting cleanup in common utils | confirmed | no_action | 0 | closed | cosmetic only | N/A |
| F067 | F10-L3 | `== None` in Starlark (valid idiom) | partial | no_action | 0 | closed | language semantics | N/A |
| F068 | F10-L9 | Go infer aspect follows `embed` only (deps-only path gap) | confirmed | fix_now | 4 | closed | aspect now traverses `deps` and `embed` + test | TBD |
| F069 | F10-L10 | Empty sanitize label edge behavior (`module_module`) | confirmed | no_action | 0 | closed | acceptable edge default | N/A |
| F070 | F10-L11 | `feature/**` workflow trigger breadth | confirmed | no_action | 0 | closed | current branch policy | N/A |
| F071 | F10-L12 | Security workflow schedule informational note | confirmed | no_action | 0 | closed | informational | N/A |
| F072 | F10-L13 | Dependabot ecosystems breadth (same root cause as F039) | confirmed | fix_now | 1 | closed | dependabot scope documented | TBD |
| F073 | F10-L14 | Duplicate `.bazelversion` policy across root/modules | confirmed | fix_doc | 5 | closed | maintainers docs explain dual-file policy rationale | TBD |
| F074 | F10-L15 | Root `.bazelignore` note | confirmed | fix_now | 4 | closed | root bazel output paths now ignored | TBD |
| F075 | F10-L16 | `WORKSPACE` emptiness concern (intentional for bzlmod) | confirmed | no_action | 0 | closed | compatibility note exists | N/A |
| F076 | F10-L17, F10-L25, F11-M2 | Gazelle version mismatch docs/examples | confirmed | fix_now | 5 | closed | example MODULE Gazelle version aligned with docs | TBD |
| F077 | F10-L19 | README other-language manifest guidance clarity | partial | fix_doc | 5 | closed | README clarifies manifest directory derivation | TBD |
| F078 | F10-L20 | PowerShell redirection example clarity | partial | fix_doc | 5 | closed | troubleshooting uses/explains `*>&1` redirection | TBD |
| F079 | F10-L22 | Placeholder SHA mention clarity in install docs | partial | fix_doc | 5 | closed | installation docs require full SHA + consistency guidance | TBD |
| F080 | F10-L23 | CONTRIBUTING legacy-path wording unclear | confirmed | fix_doc | 5 | closed | contributing checklist clarifies legacy path replacement | TBD |
| F081 | F10-L26 | RFC lock-file wording drift | confirmed | fix_doc | 5 | closed | RFC distinguishes uploader runtime lock from module lockfile | TBD |
| F082 | F10-L27 | Maintainers CODEOWNERS path finding interpreted as defect | not_confirmed | no_action | 0 | closed | docs describe fallback behavior | N/A |
| F083 | F10-L31 | Assertion order confusion claim in test is stylistic | partial | no_action | 0 | closed | API usage correct | N/A |
| F084 | F10-L33 | `type(obj) == "dict"` style note | confirmed | no_action | 0 | closed | stylistic only | N/A |
| F085 | F10-L34, F10-L35 | Generic test names/docstring style consistency notes | partial | no_action | 0 | closed | style-only | N/A |
| F086 | F10-L36, F11-M4 | Integration script `jq` requirement vs docs optional wording mismatch | confirmed | fix_now | 5 | closed | maintainer doc now states harness-level jq requirement explicitly | TBD |
| F087 | F10-L37 | `cygpath` usage/documentation clarity on Windows | partial | fix_doc | 5 | closed | troubleshooting documents `cygpath` usage/fallback behavior | TBD |
| F088 | F10-L39 | `@bazel_tools` dependency note in go bootstrap | confirmed | no_action | 0 | closed | acceptable Bazel pattern | N/A |
| F089 | F10-L40 | `DD_SITE` fallback in example runtests under-documented | confirmed | fix_doc | 5 | closed | examples README now documents default DD_SITE behavior | TBD |
| F090 | F10-L41 | `bazelw` DD_GIT_* override behavior by design | confirmed | no_action | 0 | closed | expected feature | N/A |
| F091 | F10-L42 | Docs links workflow `GITHUB_TOKEN` usage note | confirmed | no_action | 0 | closed | standard action usage | N/A |
| F092 | F11-H1 | Root `//...` command examples in docs conflict with repo constraints | confirmed | fix_now | 5 | closed | maintainer/root docs now use repo-supported scoped commands | TBD |
| F093 | F11-H3 | Chainguard STS repo mismatch (same root cause as F040) | confirmed | fix_now | 1 | closed | chainguard sts config corrected | TBD |
| F094 | F11-M1 | Version alignment guard ignores example modules | confirmed | fix_now | 4 | closed | script now validates example MODULE deps too | TBD |
| F095 | F11-M6 | CI only dry-runs example runtests scripts | confirmed | fix_doc | 5 | closed | CI + maintainers docs document dry-run rationale | TBD |
| F096 | F11-L1, F11-L2, F11-L3 | Low CI/test metadata quality notes (parser diagnostics, malformed test breadth, stale timeout metadata) | partial | fix_doc | 5 | closed | contributing checklist adds parser diagnostics + timeout review guidance | TBD |

## Current Phase Progress

- Phase 0: `completed`
- Phase 1: `completed`
- Phase 2: `completed`
- Phase 3: `completed`
- Phase 4: `completed`
- Phase 5: `completed`
- Phase 6: `completed`
