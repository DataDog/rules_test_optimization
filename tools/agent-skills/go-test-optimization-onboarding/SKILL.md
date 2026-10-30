---
name: datadog-go-test-optimization-onboarding
description: Use when instrumenting a Bazel Go repository or monorepo with Datadog Test Optimization through `ddtest instrument`. Applies to WORKSPACE and Bzlmod consumers, large monorepos with local Go wrappers, migration from a 1.x Go setup, doctor/uploader validation, and RFC-safe setup that avoids patches, payload proxies, DD_GIT_* test environment variables, and missing remote outputs.
---

<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->


# Datadog Go Test Optimization onboarding

Use this skill when you need to instrument a Bazel Go repository with Datadog
Test Optimization. This skill is intentionally project-neutral: it is stored in
the repository as a Codex-compatible skill, but any agent can read it as a
normal implementation guide.

Instrumented tests build with the Go SDK that `ddtest instrument` instruments
and link Mini, ddtest's Test Optimization runtime. The ddtest side is
documented in
[ddtest's Bazel guide](https://github.com/DataDog/ddtest/blob/main/ddto/docs/bazel.md).

## Non-negotiable contract

Keep the RFC contract intact:

- Tests write JSON payloads to `TEST_UNDECLARED_OUTPUTS_DIR`.
- Bazel collects those files under `bazel-testlogs/<target>/test.outputs/`.
- The doctor validates local files after `bazel test`.
- The uploader runs after the doctor with `bazel run`.
- Use the default Python 3.10+ uploader unless a temporary rollback explicitly
  requires `use_python_uploader = False`. Its coordinator prepares shared
  CODEOWNERS, contexts, schemas, freshness, and telemetry once, then starts up
  to eight independent file workers by default. Each worker owns enrichment,
  validation, preventive splitting, retries, and cleanup for one test,
  coverage, or telemetry source file.
- Run one uploader process. Use `--dry-run --validate-enrichment` to prepare
  requests without HTTP or deletion, `--debug` only for verbose redacted
  diagnostics, and review the final file/type/split/request/cleanup totals.
- Test bodies are split before HTTP when they exceed `4_718_592` bytes. HTTP
  `413` is terminal and must not trigger a retry or adaptive split; coverage
  and telemetry are not split.
- Do not add payload proxies or msgpack-only handoff paths.
- Do not pass `DD_GIT_*` through `--test_env`; use `--repo_env` for sync metadata.
- Do not pass uploader endpoints or credentials into the test sandbox.
- Use upstream `rules_go`. Do not patch it or override it with a fork.
- Put `--remote_download_minimal`,
  `--remote_download_regex=.*test[.]outputs.*`, and
  `--zip_undeclared_test_outputs` in the active test `.bazelrc` config when
  remote execution or remote cache can leave test outputs remote-only.
- Configure doctor/uploader with repeatable `--bep-json=<path>` flags,
  `--freshness-source=bep`, `--freshness-mode=required`,
  `--artifact-source=bep`, and `--artifact-staging-dir=<temp-dir>`.
  If BEP still points at HTTP/HTTPS `outputs.zip` artifacts, use
  `--remote-artifacts=download` or `required` without a downloader. Use a
  downloader only for bytestream/CAS/custom-auth artifact providers.
- Run pilot tests with a fresh `--build_event_json_file` path per Bazel test
  invocation; pass the same paths to doctor/uploader with `--bep-json`.
- In CI, keep a per-job diagnostic report directory with
  `DD_TEST_OPTIMIZATION_REPORT_DIR` or wrapper `--report-dir`, and configure
  wrapper `--support-bundle` or `DD_TEST_OPTIMIZATION_SUPPORT_BUNDLE` for
  complete escalation artifacts. For first-pass customer troubleshooting after
  tests have run, ask for
  `bazel run --config=test-optimization //<topt-package>:dd_test_optimization_doctor -- --support-bundle=<path>`
  with any matching BEP/artifact flags. Use `//:` for `<topt-package>` only in
  a small repository whose targets intentionally live at the root.
  For bundle triage, inspect `summary.md`, `diagnostics.json`,
  `reports/doctor-report.json`, optional uploader reports, and
  `command/flags.json` in that order.

## First actions

1. Read the consumer repository's Bazel shape before editing:
   - Does it use `MODULE.bazel`, `WORKSPACE`, or both?
   - What command does the repository use for Bazel: `bazel`, `bazelw`, `bzl`,
     or a repo-local wrapper?
   - How is `rules_go` declared? In WORKSPACE it must be named
     `io_bazel_rules_go`, because the instrumented SDK repositories load it
     under that name.
   - Is there a repo-local Go test wrapper?
   - What Go SDK/toolchain version does Bazel use? Does `go.mod` have a
     `toolchain` or `go` directive that gives it?
   - Does `go.mod` require `github.com/DataDog/ddtest/ddto` because tests use
     Mini's Go API?
   - Does the repository still have a 1.x Datadog Go setup: a managed Go
     bootstrap block in `MODULE.bazel`, a `rules_go` fork override, or 1.x
     attributes in its Go wrapper?
   - What Test Optimization sync repository name will this service use?
   - Which targets are runtime tests and which are build-only controls?
2. Read this repository's current docs when details are needed:
   - `README.md` for quickstart and current command flow.
   - `docs/Language_Onboarding.md` for language-specific Go guidance.
   - `docs/Installation_Reference.md` for flags, helper APIs, and pinning.
   - `docs/Uploader_Reference.md` for doctor, dry-run, and upload behavior.
   - `docs/Troubleshooting.md` for failure diagnosis.
3. Pick the correct path:
   - Bzlmod fresh/simple Go repo: use the Go bootstrap guided flow.
   - Repository with a 1.x Go setup: follow the migration section in
     [bzlmod-onboarding.md](references/bzlmod-onboarding.md#migrating-a-1x-setup)
     or [workspace-onboarding.md](references/workspace-onboarding.md#migrating-a-1x-setup).
   - WORKSPACE repo: use the generic WORKSPACE helper.
   - Large monorepo with an existing central wrapper: keep repo policy local
     and route that same wrapper through `dd_topt_go_test`; do not introduce a
     second macro name for enabled tests.
   - Large monorepo with a consumer-owned managed test command: use manifest
     sync only when that command can expand exact labels and derive
     service/runtime contexts. Do not create a checked-in target/service map.

## Implementation paths

- **WORKSPACE consumers:** follow [workspace-onboarding.md](references/workspace-onboarding.md).
- **Bzlmod consumers:** follow [bzlmod-onboarding.md](references/bzlmod-onboarding.md).
- **Validation:** follow [validation-checklist.md](references/validation-checklist.md).
- **Debugging:** follow [troubleshooting.md](references/troubleshooting.md).

## Universal shape

Every successful Go onboarding should end with these pieces:

- Repository resolution fetches Test Optimization metadata during Bazel
  repository/module resolution.
- The root module configures the Go SDK that `ddtest instrument` instruments
  once: `topt_go_ddtest.sdk(...)` in Bzlmod, or
  `topt_go_ddtest_workspace_repositories(...)` in WORKSPACE. This
  configuration is workspace-wide, never per service or test. `ddtest
  instrument` needs no host `go` binary.
- Only instrumented tests select the instrumented SDK's toolchains. Other
  builds fetch neither the instrumented SDKs nor Mini, and Bazel fetches only
  the SDKs of the exec platforms it selects.
- Go tests use one central repo-local wrapper that delegates to
  `dd_topt_go_test`. The named config, not a different BUILD macro, selects
  enabled behavior.
- An instrumented test preserves the source test's execution policy.
  `dd_topt_go_test` keeps `no-remote-exec` on the public test's `TestRunner`
  only; standard library, compile, and link actions stay cacheable and
  remote-capable.
- The workspace has exactly one `dd_test_optimization_doctor` target and one
  `dd_upload_payloads` target. Root is acceptable for small repositories; use a
  lightweight package such as `//tools/test_optimization` in monorepos.
- `.bazelrc` or CLI commands provide sync metadata with `--repo_env`,
  including the bootstrap-managed metadata key set and any runtime-specific
  module path override, such as `GO_MODULE_PATH`, only when needed.
- The Go module needs no Datadog requirements. A module that uses Mini's Go
  API requires `github.com/DataDog/ddtest/ddto`; in Bzlmod, the workspace then
  replaces `go_deps`' copy of that module with the generated Mini.
- Test commands use a named config such as `--config=test-optimization`.
- Validation first runs an ordinary public test without that config, then the
  enabled test with it on the same fresh Bazel output root. Disabled mode must
  keep the test runnable without metadata requests, payload generation, or
  fetching the instrumented SDK.
- Remote-output-sensitive test configs include
  `--remote_download_minimal --remote_download_regex=.*test[.]outputs.*`
  and `--zip_undeclared_test_outputs`.
- Validation commands pass each matching BEP file with repeatable `--bep-json`
  flags and required BEP freshness/artifact flags. Use
  `DD_TEST_OPTIMIZATION_*` environment variables only for single-invocation
  manual flows where one BEP file is sufficient.
- CI wrappers write `doctor-report.json`, one selected uploader report
  (`uploader-dry-run-report.json` or `uploader-upload-report.json`), and
  `dd-test-optimization-support.zip` under a per-job report directory.
  Prefer the wrapper support bundle for full CI escalation; use the doctor-only
  support bundle for the simplest initial customer request. Keep individual
  reports for local inspection and manual fallback flows.
- A real upload processes every available fresh valid payload after validation
  attempts. The wrapper preserves the earliest test, doctor, or uploader exit
  code; uploader errors never replace an earlier test result.

For automatic managed Go/Python monorepos, the universal shape has these
additional constraints:

- declare one `test_optimization_manifest_sync` aggregate repository, separate
  from static multi-sync;
- keep target discovery, service naming, and managed orchestration in the
  consumer repository;
- load `topt_data_by_target` in the central wrapper and preserve the raw Go
  path when the current full label is absent;
- wire doctor to aggregate context data and the generated
  `:expected_targets` file;
- treat the invocation manifest as a private command handoff, never as
  user-facing `.bazelrc` configuration;
- reuse that exact manifest and resolved metadata snapshot for test, doctor,
  dry-run, and optional upload; only a later managed invocation creates a new
  manifest and fetches current backend state;
- preserve Bazel test-result cache hits when selected settings/module payloads
  are unchanged, and keep variable telemetry timing facts out of test inputs;
- keep Java and other non-Python companions on their static onboarding paths.

Use the consumer's existing Bazel entrypoint in all commands. Do not switch a
repository from `bzl` or `bazelw` to raw `bazel` just because examples use the
generic binary name.

For large WORKSPACE repositories, prefer the Go bootstrap's `--workspace-mode`
scaffolding modes before writing boilerplate by hand. Use `--print-*` modes to
review snippets first. Use `--write-root-targets` only for a small repository
that intentionally owns doctor/uploader targets at the root. In a monorepo,
create those targets in its lightweight Test Optimization package, then use
`--write-bazelrc`, `--write-wrapper-template`, and `--write-validation-script`
only when those generated files match local policy.

## Large WORKSPACE Monorepo Policy

When applying this guide to a large WORKSPACE monorepo with a repository-local
Go wrapper, treat it as a consumer-specific integration:

- Use the WORKSPACE onboarding path, not the Bzlmod guided flow.
- Keep Test Optimization policy in the existing repo-local central Go wrapper
  instead of changing every BUILD file or adding an optimized-only wrapper.
- The central Go wrapper passes only `topt_data` (and `topt_service` or
  `go_test_rule` when needed). `dd_topt_go_test` needs no instrumentation
  attributes.
- Preserve repository-local wrapper policy such as tags, scheduling, Docker
  defaults, platform constraints, and flaky-test behavior in the local helper
  layer.
- Validate with fresh `bazel-testlogs/<target>/test.outputs/`, inspect
  `bazel_target_metadata.json` for
  `bazel.go.instrumentation.backend = "ddtest"` on Go targets, then run the
  doctor and one enrichment-validating uploader pass; use dry-run only when
  real upload is disabled.

## Branch and PR hygiene

Before making changes in a real repository, confirm whether to use the current
branch or create a new branch from the latest default branch. Keep onboarding
changes reviewable:

- Put reusable rule changes in `rules_test_optimization`, not in a consumer
  repository workaround.
- Put consumer-specific scheduling, Docker, tag, flaky, and wrapper policy in
  the consumer repository.
- Put automatic target expansion and service-derivation policy in the
  consumer's managed command. Do not move it into the Rule or Gazelle.
- If an issue requires changing this rule repository, add matching fixture
  coverage in `rules_test_optimization_tests` before declaring it solved.

## Stop conditions

Stop and escalate instead of guessing when:

- The repository requires a new public rule behavior not covered by current docs.
- A target produces msgpack payloads instead of JSON.
- A repository rule fails with a `DDTEST_INSTRUMENT` contract mismatch. That
  is a problem with the ddtest release pinned in `rules_test_optimization`,
  not with the consumer.
- The doctor reports missing Git metadata after sync was configured.
- The doctor reports missing Bazel metadata.
- A known pilot that requires module selection reports
  `bazel.go.payload_selection = "full_bundle_no_match"`, or a generic fallback
  reports it without an explicitly configured doctor exception.
- The only available fix would put `DD_GIT_*`, credentials, or upload endpoints
  into the test sandbox.
- Validation requires secrets that are not already available in the environment.
