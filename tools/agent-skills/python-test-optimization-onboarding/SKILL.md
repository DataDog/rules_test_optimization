---
name: datadog-python-test-optimization-onboarding
description: Use when instrumenting a Bazel Python repository or monorepo with Datadog Test Optimization. Applies to Bzlmod and WORKSPACE consumers, managed pytest targets, repository-owned pytest wrappers, consumer_runner mode, doctor/uploader validation, and RFC-safe setup that avoids payload proxies, DD_GIT_* test environment variables, and missing remote outputs.
---

# Datadog Python Test Optimization Onboarding

Use this skill when you need to instrument a Bazel Python repository with
Datadog Test Optimization. The skill is intentionally project-neutral: it is
stored in this repository as a Codex-compatible skill, but any agent can read it
as a normal implementation guide.

## Non-Negotiable Contract

Keep the RFC contract intact:

- Tests write JSON payloads to `TEST_UNDECLARED_OUTPUTS_DIR`.
- Bazel collects those files under `bazel-testlogs/<target>/test.outputs/`.
- The doctor validates local files after `bazel test`.
- The uploader runs after the doctor with `bazel run`.
- Do not add payload proxies or upload-from-test-sandbox paths.
- Do not pass `DD_GIT_*` through `--test_env`; use `--repo_env` for sync
  metadata.
- Do not pass uploader credentials or upload endpoints into the test sandbox.
- Use `--remote_download_outputs=all` when remote execution or remote cache can
  leave test outputs remote-only.

## First Actions

1. Read the consumer repository's Bazel shape before editing:
   - Does it use `MODULE.bazel`, `WORKSPACE`, or both?
   - What command does the repository use for Bazel: `bazel`, `bazelw`, `bzl`,
     or a repo-local wrapper?
   - What is the Bazel repository name for `rules_python`?
   - What Python version and toolchain does Bazel use?
   - Which repository owns Python dependencies and lockfiles?
   - Does the repository already have a pytest wrapper macro?
   - Which lightweight package should own the logical doctor/uploader pair
     (for example `//tools/test_optimization`)?
   - Does fetching this rules repository require SSH git or authenticated
     archive access?
   - Which runtime test targets should emit payloads?
   - Which build-only or analysis-only targets should not be expected to emit
     payloads?
   - Is `FETCH_SALT` absent from the normal test, doctor, and uploader flow?
2. Read this repository's current docs when details are needed:
   - `README.md` for quickstart and current command flow.
   - `docs/Language_Onboarding.md` for language-specific Python guidance.
   - `docs/Installation_Reference.md` for helper APIs and pinning.
   - `docs/Uploader_Reference.md` for doctor, dry-run, and upload behavior.
   - `docs/Troubleshooting.md` for failure diagnosis.
3. Pick the correct path:
   - Bzlmod repo: follow [bzlmod-onboarding.md](references/bzlmod-onboarding.md).
   - WORKSPACE repo: follow [workspace-onboarding.md](references/workspace-onboarding.md).
   - Existing pytest wrapper: also follow [consumer-runner.md](references/consumer-runner.md).
   - Validation and debugging: follow
     [validation-checklist.md](references/validation-checklist.md) and
     [troubleshooting.md](references/troubleshooting.md).

## Universal Shape

Every successful Python onboarding should end with these pieces:

- Repository or module resolution fetches Test Optimization metadata.
- The consumer repository owns `rules_python`, Python toolchains, `pip_parse`,
  `pytest`, `ddtrace`, and lockfiles.
- Python tests use `dd_topt_py_test` directly or through a repo-local wrapper.
- Managed pytest mode is used when the repository does not already own a pytest
  runner.
- `consumer_runner` mode is used when the repository must keep an existing
  pytest wrapper, custom launcher, or import policy.
- The workspace has exactly one logical doctor/uploader pair. In monorepos,
  place it in a lightweight package such as `//tools/test_optimization`; root
  labels are still fine for small repositories.
- `.bazelrc` or CLI commands provide sync metadata with `--repo_env`.
- Test commands use a named config such as `--config=test-optimization`.
- Remote-output-sensitive test configs include `--remote_download_outputs=all`.
- `FETCH_SALT` is used only for a separate, explicit
  `bazel sync --only=<repo> --repo_env=FETCH_SALT="$(date +%s)"` refresh, never
  as part of normal test, doctor, or uploader commands.
- Real upload happens only after tests, doctor, and dry-run enrichment pass.

Use the consumer's existing Bazel entrypoint in all commands. Do not switch a
repository from `bzl` or `bazelw` to raw `bazel` just because examples use the
generic binary name.

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

- The repository requires a new public rule behavior not covered by current
  docs.
- A target produces no JSON payloads after the pytest process ran.
- The doctor reports missing Git metadata after sync metadata was configured.
- The doctor reports missing Bazel metadata.
- The only available fix would put `DD_GIT_*`, credentials, or upload endpoints
  into the test sandbox.
- The only tried doctor/uploader placement is the root package in a large
  monorepo and no lightweight package placement has been attempted.
- A private repository fetch returns `404` and SSH/authenticated archive mode
  has not been confirmed.
- Validation requires secrets that are not already available in the environment.
