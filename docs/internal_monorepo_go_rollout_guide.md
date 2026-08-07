<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Large WORKSPACE Go Rollout Guide

This document is the maintained rollout checklist for large WORKSPACE
monorepos that need Go Test Optimization with Orchestrion. It is intentionally
generic: it describes the repository shape and validation sequence without
encoding any consumer-specific service, path, or target names.

Use [`Language_Onboarding.md`](./Language_Onboarding.md#large-workspace-monorepos)
for the step-by-step onboarding guide. Use this page as the operator checklist
when the rollout needs a reviewable local pilot before wider adoption.

This page describes the static pilot path. A monorepo with a repository-owned
managed command that expands exact targets should instead use the
[automatic managed Go/Python contract](./Language_Onboarding.md#automatic-managed-gopython-monorepos).
That path derives services per invocation and does not check in pilot lists,
Gazelle policy, or ownership gates. Both paths share the same `rules_go`,
Orchestrion, doctor, and uploader safety requirements.

## Published Contract

- Consume one complete base `rules_go` Orchestrion tree. Do not copy patch
  directories, and do not configure `patches`, `patch_tool`, or `patch_args`.
- Use the versioned base `rules_go` Orchestrion tree for ordinary repositories.
- Keep the repository's existing Bazel name for `rules_go` when other
  repository code depends on that name.
- Use the public WORKSPACE helper so the Go companion repo mapping and the
  selected `rules_go` upstream support line stay consistent.

```bzl
load(
    "@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl",
    "datadog_go_test_optimization_workspace_repositories",
)

datadog_go_test_optimization_workspace_repositories(
    rto_commit = "<published-origin-main-sha>",
    rules_go_repo_name = "<existing_rules_go_repo_name>",
    rules_go_upstream = "v0_60_0",
    rules_go_variant = "base",
)
```

Archive mode is also supported when the consuming environment requires a
mirrored or integrity-checked archive. Keep the commit, archive URL, archive
SHA256, and archive prefix generated from the same published commit.

## Local Pilot Requirements

- Use a commit that is reachable from `origin/main`; never publish feature-branch
  SHAs into consumer snippets.
- Configure `dd_topt_go_orchestrion_tool_repo(...)` with the current supported
  Orchestrion version and the current supported `dd-trace-go` Bazel-mode
  version, plus the repository's central `@go_sdk//:ROOT` label and exact Go
  SDK version. Do not load the underlying `rules_go` repository rule directly
  or repeat this wiring per service.
- Configure `dd_topt_go_workspace_sync_repositories(...)` with:
  - `service`
  - `runtime_version`
  - `module_path`
  - `require_git_metadata = True`
  The public helper supplies `runtime_name = "go"` and config-gated metadata
  sync by default.
- Keep repository-specific scheduling, Docker, tags, platform constraints, and
  flaky policy in the repository-local wrapper layer.
- Route the existing central Go wrapper through `dd_topt_go_test` and set
  `orchestrion_mode = "test_optimization"` for
  standard Go `testing` Test Optimization pilots. The `general` mode remains
  available for explicit compatibility validation only.
- Keep BUILD callsites on that same wrapper; the named config controls whether
  its expansion is normal or instrumented.
- Select only the agreed runtime-emitting pilot scope in central repository
  policy.
- Do not list `.build_test`, compile-only, or other build-only controls as
  doctor `expected_targets`.
- Add one `dd_test_optimization_doctor` target and one `dd_upload_payloads`
  target in a lightweight package such as `//tools/test_optimization`.
- Use `.bazelrc` to activate
  `--remote_download_minimal --remote_download_regex=.*test[.]outputs.*` and
  `--zip_undeclared_test_outputs` for test commands. Pass a fresh
  `--build_event_json_file=...` per Bazel test invocation and pass matching
  doctor/uploader `--bep-json=<path>` flags with `--freshness-source=bep`,
  `--freshness-mode=required`, `--artifact-source=bep`, and
  `--artifact-staging-dir=<temp-dir>`.
- Pass `DD_GIT_*` only through `--repo_env`, never through `--test_env`.
- Pass uploader credentials at `bazel run` time, not into test actions.
- Keep one user-facing `test-optimization` config with both phase-correct
  switches:

  ```bazelrc
  common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
  build:test-optimization --@io_bazel_rules_go//go/private/orchestrion:enabled=true
  ```

  Removing `--config=test-optimization` disables both metadata repositories
  and Orchestrion aliases. The public Go helpers enable metadata gating by
  default; they do not dynamically control Orchestrion repository declaration.

## Bootstrap Flow

Generate repository-local scaffolding, then review it before committing:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --workspace-mode \
  --service "<datadog-service-name>" \
  --runtime-version "<go-sdk-version>" \
  --rules-go-repo-name "<existing_rules_go_repo_name>" \
  --rules-go-upstream v0_60_0 \
  --rules-go-variant base \
  --dd-trace-go-version v2.9.1 \
  --write-bazelrc \
  --write-orchestrion-files \
  --write-wrapper-template \
  --write-validation-script \
  --check-go-repositories \
  --large-monorepo \
  --shutdown-bazel-on-exit \
  --default-jobs=1 \
  --expected-target "//path/to/runtime/package:go_default_test" \
  --doctor-target "//tools/test_optimization:dd_test_optimization_doctor" \
  --upload-target "//tools/test_optimization:dd_upload_payloads" \
  --control-target "//path/to/plain/control:go_default_test"
```

Create the single doctor/uploader pair in
`//tools/test_optimization:BUILD.bazel`; do not use `--write-root-targets` for
this monorepo flow.

### Updating an existing managed config

When upgrading from the current release, rerun the same bootstrap with
`--write-bazelrc`. It replaces the content between the Datadog-managed markers
with the current single-config contract, preserves all content outside those
markers, and is idempotent. This adds both
`DD_TEST_OPTIMIZATION_ENABLED=1` and the existing `rules_go` Orchestrion flag to
the named config; consumers do not need a separate migration mode or a second
bool flag.

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
bazel run --config=test-optimization //tools/test_optimization:dd_test_optimization_doctor
bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- --dry-run --validate-enrichment
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads
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
