---
name: datadog-go-test-optimization-onboarding
description: Use when instrumenting a Bazel Go repository or monorepo with Datadog Test Optimization and Orchestrion. Applies to WORKSPACE and Bzlmod consumers, large monorepos with local Go wrappers, doctor/uploader validation, and RFC-safe setup that avoids patches, payload proxies, DD_GIT_* test environment variables, and missing remote outputs.
---

<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->


# Datadog Go Test Optimization Onboarding

Use this skill when you need to instrument a Bazel Go repository with Datadog
Test Optimization. This skill is intentionally project-neutral: it is stored in
the repository as a Codex-compatible skill, but any agent can read it as a
normal implementation guide.

## Non-Negotiable Contract

Keep the RFC contract intact:

- Tests write JSON payloads to `TEST_UNDECLARED_OUTPUTS_DIR`.
- Bazel collects those files under `bazel-testlogs/<target>/test.outputs/`.
- The doctor validates local files after `bazel test`.
- The uploader runs after the doctor with `bazel run`.
- Do not add payload proxies or msgpack-only handoff paths.
- Do not pass `DD_GIT_*` through `--test_env`; use `--repo_env` for sync metadata.
- Do not pass uploader endpoints or credentials into the test sandbox.
- Do not copy or apply `rules_go` patch bundles manually.
- Use `--remote_download_minimal --remote_download_regex=.*test[.]outputs.*`
  when remote execution or remote cache can leave test outputs remote-only.
  If the test run uses `--zip_undeclared_test_outputs`, pass
  `--artifact-source=bep` to doctor and uploader.
  If BEP still points at remote/CAS artifacts, use BEP artifact resolution with
  `--remote-artifacts=download` or `required` and a downloader.
- Run pilot tests with `--build_event_json_file` and pass the same BEP file to
  doctor/uploader with `--freshness-source=bep --freshness-mode=required`.

## First Actions

1. Read the consumer repository's Bazel shape before editing:
   - Does it use `MODULE.bazel`, `WORKSPACE`, or both?
   - What command does the repository use for Bazel: `bazel`, `bazelw`, `bzl`,
     or a repo-local wrapper?
   - What is the Bazel repository name for `rules_go`?
   - Is there a repo-local Go test wrapper?
   - What Go SDK/toolchain version does Bazel use?
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
   - WORKSPACE repo: use the generic WORKSPACE helper.
   - Large monorepo with existing wrappers: keep repo policy local and add a
     Test Optimization wrapper path beside the existing plain wrapper path.

## Implementation Paths

- **WORKSPACE consumers:** follow [workspace-onboarding.md](references/workspace-onboarding.md).
- **Bzlmod consumers:** follow [bzlmod-onboarding.md](references/bzlmod-onboarding.md).
- **Validation:** follow [validation-checklist.md](references/validation-checklist.md).
- **Debugging:** follow [troubleshooting.md](references/troubleshooting.md).

## Universal Shape

Every successful Go onboarding should end with these pieces:

- Repository resolution fetches Test Optimization metadata during Bazel
  repository/module resolution.
- The Orchestrion tool repository is configured with the same dd-trace-go
  version that the consumer Go module can resolve.
- Orchestrion pin files exist and are exported when tests live below the
  workspace root.
- Go tests use `dd_topt_go_test` directly or through a repo-local wrapper.
- The root package has exactly one `dd_test_optimization_doctor` target.
- The root package has exactly one `dd_upload_payloads` target.
- `.bazelrc` or CLI commands provide sync metadata with `--repo_env`,
  including the bootstrap-managed metadata key set and any runtime-specific
  module path override, such as `GO_MODULE_PATH`, only when needed.
- Go module updates are deliberate: bootstrap uses targeted module sync by
  default, large WORKSPACE repositories verify checked-in `go_repository`
  declarations when they exist, and agents do not run broad `go mod tidy`
  unless the repository explicitly wants that behavior.
- Test commands use a named config such as `--config=test-optimization`.
- Remote-output-sensitive test configs include
  `--remote_download_minimal --remote_download_regex=.*test[.]outputs.*`.
- Validation commands pass the matching BEP file to doctor and uploader in
  required BEP freshness mode.
- Real upload happens only after tests, doctor, and dry-run enrichment pass.

Use the consumer's existing Bazel entrypoint in all commands. Do not switch a
repository from `bzl` or `bazelw` to raw `bazel` just because examples use the
generic binary name.

For large WORKSPACE repositories, prefer the Go bootstrap's `--workspace-mode`
scaffolding modes before writing boilerplate by hand. Use `--print-*` modes to
review snippets first, then `--write-bazelrc`, `--write-root-targets`,
`--write-orchestrion-files`, `--write-wrapper-template`, and
`--write-validation-script` only when those generated files match the
repository's local policy.

## Large WORKSPACE Monorepo Policy

When applying this guide to a large WORKSPACE monorepo with a repository-local
Go wrapper, treat it as a consumer-specific integration:

- Use the WORKSPACE onboarding path, not the Bzlmod guided flow.
- Keep Test Optimization policy in the repo-local optimized Go wrapper instead
  of changing every BUILD file to call the public macro directly.
- The optimized Go wrapper should pass
  `orchestrion_mode = "test_optimization"` for standard Go `testing` targets.
  Do not rely on the public macro's default `general` mode for Test
  Optimization onboarding. Use `general` only for explicit compatibility
  validation.
- Preserve repository-local wrapper policy such as tags, scheduling, Docker
  defaults, platform constraints, and flaky-test behavior in the local helper
  layer.
- Validate with fresh `bazel-testlogs/<target>/test.outputs/`, inspect
  `bazel_target_metadata.json` for
  `bazel.go.orchestrion.mode = "test_optimization"` on Go targets, then run
  the doctor and uploader dry-run before any real upload.

## Branch And PR Hygiene

Before making changes in a real repository, confirm whether to use the current
branch or create a new branch from the latest default branch. Keep onboarding
changes reviewable:

- Put reusable rule changes in `rules_test_optimization`, not in a consumer
  repository workaround.
- Put consumer-specific scheduling, Docker, tag, flaky, and wrapper policy in
  the consumer repository.
- If an issue requires changing this rule repository, add matching fixture
  coverage in `rules_test_optimization_tests` before declaring it solved.

## Stop Conditions

Stop and escalate instead of guessing when:

- The repository requires a new public rule behavior not covered by current docs.
- A target produces msgpack payloads instead of JSON.
- The doctor reports missing Git metadata after sync was configured.
- The doctor reports missing Bazel metadata.
- `bazel.go.payload_selection` is `full_bundle_no_match`.
- The only available fix would put `DD_GIT_*`, credentials, or upload endpoints
  into the test sandbox.
- Validation requires secrets that are not already available in the environment.
