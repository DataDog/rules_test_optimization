# Internal Monorepo Go Rollout Plan

This document describes the supported local rollout shape for large WORKSPACE
monorepos that need Go Test Optimization with Orchestrion.

## Published Contract

Use the complete `rules_go` variant:

```bzl
http_archive(
    name = "io_bazel_rules_go",
    urls = [RTO_ARCHIVE_URL],
    sha256 = RTO_ARCHIVE_SHA256,
    strip_prefix = RTO_ARCHIVE_PREFIX + "/third_party/rules_go_orchestrion_complete",
)
```

Do not configure `patches`, `patch_tool`, `patch_args`, or a local Datadog patch
directory. The extended compatibility layer is already part of
`rules_go_orchestrion_complete`.

Keep the Datadog repositories as separate repository declarations for the first
pilot:

```bzl
git_repository(
    name = "datadog-rules-test-optimization",
    remote = RTO_REMOTE,
    commit = RTO_COMMIT,
)

git_repository(
    name = "datadog-rules-test-optimization-go",
    remote = RTO_REMOTE,
    commit = RTO_COMMIT,
    strip_prefix = "modules/go",
    repo_mapping = {"@rules_go": "@io_bazel_rules_go"},
)
```

The first pilot intentionally changes only the `rules_go` repository to a
published archive subtree. Converting the Datadog core and Go companion
repositories to archives is a separate rollout decision.

## Local Pilot Requirements

- Use Go `1.25.9` when validating the target monorepo.
- Use Orchestrion `v1.9.0`.
- Use the exact `dd-trace-go` versions selected for the pilot.
- Configure the public tool repository as `rules_go_orchestrion_tool`.
- Use `require_git_metadata = True` for the sync rule once local Git metadata is
  available.
- Keep repo-local scheduling, Docker, tags, and flaky policy in the monorepo's
  wrapper layer.
- Convert only the agreed pilot targets first.
- Add one root uploader target and run it only with local credentials available.

## Validation

Run the pilot serially on low-disk hosts:

```bash
bzl sync --config=test-optimization-worker-pilot --only=test_optimization_data_test_optimization_worker --repo_env=FETCH_SALT="$(date +%s)"
bzl test --config=test-optimization-worker-pilot <plain-control-target>
bzl test --config=test-optimization-worker-pilot <instrumented-target-1>
bzl test --config=test-optimization-worker-pilot <instrumented-target-2>
bzl run --config=test-optimization-worker-pilot //:dd_upload_payloads
bzl shutdown
```

After each run, inspect `bazel-testlogs` for Datadog metadata and payload files.
The payload selection must be one of the expected supported states for the
target; mixed or no-match states are blockers.

## Disk Guardrails

- Check `df -h /` before every heavy Bazel phase.
- Do not run public repo validation, fixture validation, and monorepo validation
  at the same time.
- Shut down the Bazel server before switching repositories.
- If free space drops below 35G, remove completed Bazel output bases before
  starting the next phase.
- Do not delete the monorepo `.git` directory as part of routine cleanup.
