<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Large WORKSPACE Go Rollout Guide

This document is the rollout checklist for large WORKSPACE monorepos that add
Go Test Optimization. Go tests build with the Go SDK that `ddtest instrument`
instruments and link Mini, ddtest's Test Optimization runtime. The page is
generic: it describes the repository shape and validation sequence without
naming any consumer's services, paths, or targets.

Use [`Language_Onboarding.md`](./Language_Onboarding.md#large-workspace-monorepos)
for the step-by-step onboarding guide. Use this page as the operator checklist
when the rollout needs a reviewable local pilot before wider adoption.

This page describes the static pilot path. A monorepo with a repository-owned
managed command that expands exact targets should instead use the
[automatic managed Go/Python contract](./Language_Onboarding.md#automatic-managed-gopython-monorepos).
That path derives services per invocation and does not check in pilot lists,
Gazelle policy, or ownership gates. Both paths share the same `rules_go`,
instrumentation, doctor, and uploader requirements.

## Published Contract

- Use upstream `rules_go`, declared as `io_bazel_rules_go`. The SDK
  repositories that `go_wrap_sdk` writes for the instrumented SDK load it under
  that name.
- Use the public WORKSPACE helpers, in the order shown in
  [step 8 of the Installation Reference](./Installation_Reference.md#8-configure-go-support-in-workspace-with-the-public-helper):
  `datadog_go_test_optimization_workspace_repositories(...)` for the Go
  companion, then, after `go_rules_dependencies()` and
  `go_register_toolchains(...)`, `topt_go_ddtest_workspace_repositories(...)`
  for the instrumented SDK.
- Pin a commit that is reachable from `origin/main`; never publish
  feature-branch SHAs into consumer snippets. In archive mode, keep the commit,
  archive URL, archive SHA256, and archive prefix generated from that same
  commit; see [Generate published Go pins](./Installation_Reference.md#generate-published-go-pins).

```bzl
load(
    "@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl",
    "datadog_go_test_optimization_workspace_repositories",
)

datadog_go_test_optimization_workspace_repositories(
    rto_commit = "<published-origin-main-sha>",
)

# After go_rules_dependencies() and go_register_toolchains(version = "<go-sdk-version>"):
load(
    "@datadog-rules-test-optimization-go//:topt_go_ddtest_repository.bzl",
    "topt_go_ddtest_workspace_repositories",
)

topt_go_ddtest_workspace_repositories(
    base_sdk_roots = {"linux_amd64": "@go_sdk//:ROOT"},
    exec_platforms = ["linux_amd64"],
)
```

## Local Pilot Requirements

- Instrument the repository's central SDK with `base_sdk_roots`, or set
  `go_version` to the repository's Go version. List every exec platform that
  runs instrumented tests in `exec_platforms`.
- Configure `dd_topt_go_workspace_sync_repositories(...)` with:
  - `service`
  - `runtime_version`
  - `module_path`
  - `require_git_metadata = True`
  The public helper supplies `runtime_name = "go"` and config-gated metadata
  sync by default.
- Keep repository-specific scheduling, Docker, tags, platform constraints, and
  flaky policy in the repository-local wrapper layer.
- Route the existing central Go wrapper through `dd_topt_go_test`. Keep BUILD
  callsites on that same wrapper; the named config controls whether its
  expansion is normal or instrumented.
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
- Keep one user-facing `test-optimization` metadata config:

  ```bazelrc
  common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
  ```

  Instrumented tests select the instrumented SDK through their own transition.
  Removing the config disables the metadata repositories, and the disabled
  export builds a plain `go_test`; the public Go helpers enable that metadata
  gating by default.

## Bootstrap Flow

Generate repository-local scaffolding, then review it before committing:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --workspace-mode \
  --write-bazelrc \
  --write-wrapper-template \
  --write-validation-script \
  --large-monorepo \
  --shutdown-bazel-on-exit \
  --default-jobs=1 \
  --expected-target "//path/to/runtime/package:go_default_test" \
  --doctor-target "//tools/test_optimization:dd_test_optimization_doctor" \
  --upload-target "//tools/test_optimization:dd_upload_payloads" \
  --control-target "//path/to/plain/control:go_default_test"
```

`--print-workspace-snippet` with `--service`, `--runtime-version`, and
`--rto-commit` prints the WORKSPACE wiring for review. Create the single
doctor/uploader pair in `//tools/test_optimization:BUILD.bazel`; do not use
`--write-root-targets` for this monorepo flow.

### Updating an existing managed config

Rerun the same bootstrap with `--write-bazelrc`. It replaces the content
between the Datadog-managed markers with the current config, preserves all
content outside those markers, and is idempotent. A workspace set up by 1.x
must also replace its 1.x WORKSPACE wiring by hand with the helpers above; see
the [migration note](../CHANGELOG.md#unreleased).

## Validation

Run the pilot serially, especially on low-disk hosts:

```bash
bazel sync --config=test-optimization --only=test_optimization_data --repo_env=FETCH_SALT="$(date +%s)"
bazel test --config=test-optimization <plain-control-target>
bazel test --config=test-optimization <build-only-control-target>
bazel test --config=test-optimization <instrumented-target-1>
bazel test --config=test-optimization <instrumented-target-2>
bazel run --config=test-optimization //tools/test_optimization:dd_test_optimization_doctor
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //tools/test_optimization:dd_upload_payloads -- --validate-enrichment
bazel shutdown
```

Run the real uploader after the doctor even when an earlier phase fails. It
validates enrichment and uploads available fresh valid failed-test payloads in
one pass while the wrapper preserves the earlier failure as the job result.

The doctor must see JSON payloads, Bazel target metadata, Git metadata, and only
valid Go payload-selection states. `module`, `module_override`, and
`full_bundle_disabled` are valid. `full_bundle_no_match` is a rollout blocker
unless the target was explicitly configured to allow it.

Upload-time enrichment validation proves that tags expected in Datadog are
present in the final upload body. Raw payload files on disk are intentionally
not the final enriched body.

For instrumentation failures, see
[Go tests instrumented by ddtest](./Troubleshooting.md#go-tests-instrumented-by-ddtest).

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
