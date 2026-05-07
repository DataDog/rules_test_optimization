# Large WORKSPACE Go Rollout Plan

This document is the maintained rollout checklist for large WORKSPACE
monorepos that need Go Test Optimization with Orchestrion. It is intentionally
generic: it describes the repository shape and validation sequence without
encoding any consumer-specific service, path, or target names.

Use [`Language_Onboarding.md`](./Language_Onboarding.md#large-workspace-monorepos)
for the step-by-step onboarding guide. Use this page as the operator checklist
when the rollout needs a reviewable local pilot before wider adoption.

## Published Contract

- Consume one complete `rules_go` Orchestrion variant. Do not copy patch
  directories, and do not configure `patches`, `patch_tool`, or `patch_args`.
- Use `rules_go_orchestrion_base` for ordinary repositories.
- Use `rules_go_orchestrion_complete` only when the monorepo needs the declared
  extended compatibility layer.
- Keep the repository's existing Bazel name for `rules_go` when other
  repository code depends on that name.
- Use the public WORKSPACE helper so the Go companion repo mapping and the
  selected `rules_go` variant stay consistent.

```bzl
load(
    "@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl",
    "datadog_go_test_optimization_workspace_repositories",
)

datadog_go_test_optimization_workspace_repositories(
    rto_commit = "<published-origin-main-sha>",
    rules_go_repo_name = "<existing_rules_go_repo_name>",
    rules_go_variant = "complete",
)
```

Archive mode is also supported when the consuming environment requires a
mirrored or integrity-checked archive. Keep the commit, archive URL, archive
SHA256, and archive prefix generated from the same published commit.

## Local Pilot Requirements

- Use a commit that is reachable from `origin/main`; never publish feature-branch
  SHAs into consumer snippets.
- Configure `go_orchestrion_tool_repo(...)` with the current supported
  Orchestrion version and the current supported `dd-trace-go` Bazel-mode
  version.
- Configure `test_optimization_sync(...)` with:
  - `service`
  - `runtime_name = "go"`
  - `runtime_version`
  - `runtime_module_path`
  - `require_git_metadata = True`
- Keep repository-specific scheduling, Docker, tags, platform constraints, and
  flaky policy in the repository-local wrapper layer.
- Keep a plain wrapper path for controls and unconverted tests.
- Convert only the agreed runtime-emitting pilot targets first.
- Do not list `.build_test`, compile-only, or other build-only controls as
  doctor `expected_targets`.
- Add one root `dd_test_optimization_doctor` target.
- Add one root `dd_upload_payloads` target.
- Use `.bazelrc` or CLI flags to activate `--remote_download_outputs=all` for
  test commands.
- Pass `DD_GIT_*` only through `--repo_env`, never through `--test_env`.
- Pass uploader credentials at `bazel run` time, not into test actions.

## Bootstrap Flow

Generate repository-local scaffolding, then review it before committing:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --workspace-mode \
  --service "<datadog-service-name>" \
  --runtime-version "<go-sdk-version>" \
  --rules-go-repo-name "<existing_rules_go_repo_name>" \
  --rules-go-variant complete \
  --dd-trace-go-version v2.9.0-dev.0.20260416093245-194346a71c51 \
  --write-bazelrc \
  --write-root-targets \
  --write-orchestrion-files \
  --write-wrapper-template \
  --write-validation-script \
  --check-go-repositories \
  --large-monorepo \
  --shutdown-bazel-on-exit \
  --default-jobs=1 \
  --expected-target "//path/to/runtime/package:go_default_test" \
  --control-target "//path/to/plain/control:go_default_test"
```

If the repository owns checked-in `go_repository(...)` declarations, run the
repository-owned refresh command after targeted Go module sync and rerun
bootstrap with `--check-go-repositories`. Bootstrap should verify those pins; it
should not silently edit large generated dependency files on its own.

## Validation

Run the pilot serially, especially on low-disk hosts:

```bash
bazel sync --config=test-optimization --only=test_optimization_data --repo_env=FETCH_SALT="$(date +%s)"
bazel test --config=test-optimization <plain-control-target>
bazel test --config=test-optimization <build-only-control-target>
bazel test --config=test-optimization <instrumented-target-1>
bazel test --config=test-optimization <instrumented-target-2>
bazel run --config=test-optimization //:dd_test_optimization_doctor
bazel run --config=test-optimization //:dd_upload_payloads -- --dry-run --validate-enrichment
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //:dd_upload_payloads
bazel shutdown
```

Do not run the real uploader if the doctor or dry-run enrichment step fails.
Upload failed-test payloads only when those validation steps pass.

The doctor must see JSON payloads, Bazel target metadata, Git metadata, and only
valid Go payload-selection states. `module`, `module_override`, and
`full_bundle_disabled` are valid. `full_bundle_no_match` is a rollout blocker
unless the target was explicitly configured to allow it.

The dry-run enrichment step is the local proof that tags expected in Datadog are
present in the final upload body. Raw payload files on disk are intentionally
not the final enriched body.

## Disk Guardrails

- Check `df -h /` before every heavy Bazel phase.
- Do not run public repo validation, fixture validation, and monorepo validation
  at the same time.
- Run pilot targets in small batches; use `--jobs=1` when cache or disk pressure
  is high.
- Shut down the Bazel server before switching repositories.
- If free space drops below 35G, remove completed Bazel output bases before the
  next heavy phase.
- Do not delete the consumer repository `.git` directory as part of routine
  cleanup.
