# internal monorepo Go Test Optimization Pilot Plan

## Goal

Instrument one CI App-owned Go service in `internal monorepo` with Datadog Test
Optimization in WORKSPACE mode and prove all of these together:

1. `internal monorepo` can consume the current public `rules_test_optimization`
   WORKSPACE Go contract.
2. Instrumented pilot targets emit Datadog test payload files from hermetic
   Bazel tests.
3. The workspace-level uploader can find and upload those payloads from
   `bazel-testlogs`.
4. Untouched `dd_go_test` targets still run through the current plain
   `go_test(...)` path.
5. The repository-local flaky companion behavior still works for both:
   - explicit `flaky = True`
   - central `is_flaky(name)` registration

This pilot is intentionally limited to the test-payload path. Coverage is not a
rollout gate.

## Execution Baseline

This document was re-derived from the local checkouts inspected on 2026-04-23:

- `rules_test_optimization`:
  `2917f0df87da958513fc9c4532abfa5895013913`
- `rules_test_optimization_tests`:
  `39dd1300859e1df0d094714e6c70028a83e44df0`
- `internal monorepo`:
  `bdab29a34063b73d6274e29e59631441b7838acd`

Important: the current effective consumer proof baseline is the content of the
local `rules_test_optimization_tests` checkout, not just its clean commit SHA.
At inspection time that checkout also contained the currently required
monorepo-shaped proof lane:

- `fixtures/workspace-go-monorepo-shape/`
- `README.md` updates that document that fixture
- `.github/workflows/bazel-tests.yml` updates that run that fixture in CI

If any of the three repositories move, or if the local
`rules_test_optimization_tests` checkout no longer contains the
monorepo-shaped fixture and its README/workflow wiring, re-derive this plan
from source instead of reusing it unchanged.

## Current Facts That Drive The Plan

### Public rules repository

- The public WORKSPACE-mode Go consumer contract is:
  - clean Orchestrion-enabled base fork in
    `third_party/rules_go_orchestrion/`
  - optional consumer-owned patch bundle exported from
    `third_party/rules_go_patches/`
- WORKSPACE-mode Go still uses separate external repositories for:
  - core rules
  - Go companion module
  - Orchestrion-enabled `@io_bazel_rules_go`
- `go_orchestrion_tool_repo(...)` still requires:
  - repository name `rules_go_orchestrion_tool`
  - explicit `version`
  - either shared `dd_trace_go_version` or exact
    `dd_trace_go_versions`, never both
- The Go companion still expects module-root Orchestrion pin files to be
  staged through `orchestrion_pin_files` for nested packages.
- The current default tracer setting in the vendored rules_go fork is already
  `v2.9.0-dev`.

### Current public consumer proof baseline

The current external consumer proof lives in the local
`rules_test_optimization_tests` checkout and covers four Go shapes:

- `fixtures/workspace-go/`
  - clean WORKSPACE consumer
  - expected metadata path: `payload_selection = "module"`
- `fixtures/workspace-go-patched/`
  - patched WORKSPACE consumer with the exported `all_patches` patch bundle
  - expected metadata path: `payload_selection = "module"`
- `fixtures/bzlmod-go-patched/`
  - patched Bzlmod consumer with the same patch bundle
  - expected metadata path: `payload_selection = "module"`
- `fixtures/workspace-go-monorepo-shape/`
  - patched WORKSPACE consumer that models the current internal monorepo wrapper split
    and package layout
  - pinned tuple: Go `1.25.9`, Orchestrion `v1.9.0`,
    `dd-trace-go/v2`
    `v2.9.0-dev`,
    `dd-trace-go.v1` `v1.74.8`
  - current expected metadata path:
    `payload_selection = "full_bundle_disabled"`

`internal monorepo` must follow the patched WORKSPACE consumer shape and the
monorepo-shaped wrapper split that is already proven publicly. This pilot must
not invent a new integration model.

### Current internal monorepo state

- `internal monorepo` is a WORKSPACE repository.
- The repo-root Go module is:
  - module path: `<internal_go_module>`
  - Go version: `1.25.9`
- Bazel Go toolchain version is pinned to `1.25.9` in
  `rules/go/version.bzl`.
- `WORKSPACE` currently binds `@io_bazel_rules_go` to upstream
  `rules_go v0.60.0` plus nine local patch files under
  `third_party/rules_go/`.
- Those nine patch filenames are the same bundle that the public repo now
  exports as `all_patches`.
- Root `BUILD.bazel` already exports `go.mod` and `go.sum`, but not
  `orchestrion.tool.go` or `orchestrion.yml`.
- Root `.bazelrc` already imports `tools/bazelrc/*.bazelrc` fragments and
  explicitly warns against putting shared `--repo_env` flags into unscoped
  configs.
- `internal monorepo` already has a repository-local `dd_go_test` wrapper at:
  - public alias: `rules/go/dd_go_test.bzl`
  - implementation: `rules/go/private/dd_go_test/dd_go_test.bzl`
- The current `dd_go_test` behavior that must stay intact is:
  - Docker defaults when `dd-requires-docker` is present
  - `local` / `exclusive` enforcement for non-manual targets
  - flaky companion `<name>.build_test` for both explicit `flaky = True` and
    `is_flaky(name)`
- `internal monorepo` does not currently contain:
  - Datadog core WORKSPACE repo wiring
  - Datadog Go companion WORKSPACE repo wiring
  - Test Optimization sync repo wiring
  - a root uploader target
  - root `orchestrion.tool.go`
  - root `orchestrion.yml`
- The current repo-root tracer state is mixed:
  - `gopkg.in/DataDog/dd-trace-go.v1 v1.74.8`
  - `github.com/DataDog/dd-trace-go/v2 v2.7.1`
  - `github.com/DataDog/dd-trace-go/contrib/net/http/v2 v2.7.1`
  - `github.com/DataDog/dd-trace-go/contrib/log/slog/v2` is not pinned yet

### Non-negotiable decisions already made

To keep this pilot executable without mid-flight decisions, treat all of these
as fixed:

1. The pilot uses the currently proven monorepo-shaped tuple:
   - `ORCHESTRION_VERSION = v1.9.0`
   - `DD_TRACE_GO_VERSION = v2.9.0-dev`
2. This pilot intentionally updates the repo-root v2 tracer modules from
   `v2.7.1` to that proven pseudo-version. Do not try to keep the root module on
   `v2.7.1` under this plan.
3. Use the shared `dd_trace_go_version = "<exact version>"` form, not the
   per-module map. The current monorepo-shaped proof uses one exact version
   across all required v2 tracer modules.
4. Keep the current v1 tracer line at the effective version already used by the
   service shape (`v1.74.8`) unless `go mod tidy` only rewrites formatting or
   indirect ordering.
5. Keep the repo-local wrapper split outside the public Datadog macro:
   - `dd_go_test(...)` stays the plain path
   - `dd_topt_go_test(...)` is the opt-in pilot path
6. Do not introduce `stage_sources` in this pilot. The current monorepo-shaped
   public proof does not cover it. The pilot uses normal nested packages plus
   module-root `orchestrion_pin_files`.
7. The sync/export preflight decides whether the current backend state supports
   `payload_selection = "module"` or still requires
   `payload_selection = "full_bundle_disabled"`.
8. `payload_selection = "full_bundle_no_match"` is always a rollout failure.

If the pilot cannot use the proven pseudo-version tuple in the repo-root Go
module, stop and write a different plan. Do not partially execute this one.

## Pilot Scope

### Service

Use `domains/ci-app/apps/apis/test-optimization-worker`.

Why this service:

- Its service name is exactly `test-optimization-worker`.
- Its owner is `ci-app-backend`, so the pilot stays inside the CI App team.
- It has several nested Go test packages with different characteristics:
  - `worker`
  - `worker/notifications`
  - `worker/store`
- `worker/notifications` already imports `dd-trace-go/v2`.
- `worker/store` already uses runfile data via
  `data = glob([".recordings/**"])`.
- `worker/flaky_test_categorization` gives one untouched local control target.

### Targets

Instrument these existing targets:

- `//domains/ci-app/apps/apis/test-optimization-worker/worker:go_default_test`
- `//domains/ci-app/apps/apis/test-optimization-worker/worker/notifications:go_default_test`
- `//domains/ci-app/apps/apis/test-optimization-worker/worker/store:go_default_test`

Adopt them in this order:

1. `worker/notifications`
2. `worker`
3. `worker/store`

Add one pilot-only parity target:

- `//domains/ci-app/apps/apis/test-optimization-worker/worker:topt_flaky_test`

Keep this target unchanged as the plain-path local control:

- `//domains/ci-app/apps/apis/test-optimization-worker/worker/flaky_test_categorization:go_default_test`

Use this existing registry-flaky target as the `is_flaky(name)` control:

- `//domains/case_management/modules/slack:go_default_test.build_test`

That target is already listed in `etc/ci/test-all/flaky_test_targets.txt`, so
its `.build_test` target only exists if the shared helper still preserves the
central `is_flaky(name)` path after the wrapper refactor.

### Stable names used in this plan

Use these exact names:

```text
RTO_ROOT=<local checkout of rules_test_optimization at 2917f0df87da958513fc9c4532abfa5895013913>
RTO_TESTS_ROOT=<local checkout of rules_test_optimization_tests whose contents include fixtures/workspace-go-monorepo-shape>
INTERNAL_MONOREPO_ROOT=<local checkout of internal monorepo at bdab29a34063b73d6274e29e59631441b7838acd>
RTO_COMMIT=2917f0df87da958513fc9c4532abfa5895013913
RTO_TESTS_COMMIT=39dd1300859e1df0d094714e6c70028a83e44df0
INTERNAL_MONOREPO_BASE_COMMIT=bdab29a34063b73d6274e29e59631441b7838acd
PILOT_SERVICE=test-optimization-worker
PILOT_SYNC_REPO=test_optimization_data_test_optimization_worker
PILOT_BAZEL_CONFIG=test-optimization-worker-pilot
PILOT_FIXTURE=workspace-go-monorepo-shape
INTERNAL_MONOREPO_GO_VERSION=1.25.9
ORCHESTRION_VERSION=v1.9.0
DD_TRACE_GO_VERSION=v2.9.0-dev
DD_TRACE_GO_V1_VERSION=v1.74.8
RTO_REMOTE=https://github.com/Datadog/rules_test_optimization.git
RTO_ARCHIVE_URL=https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/${RTO_COMMIT}
RTO_ARCHIVE_PREFIX=rules_test_optimization-${RTO_COMMIT}
RTO_ARCHIVE_SHA256=266af99edecaff5dd0ba0468b9f511c29b395723a15332c0c15259049a03ede1
EXPECTED_PAYLOAD_SELECTION=<set in Validation Sequence step 3>
```

## internal monorepo Changes

### 1. Re-home `rules_go` consumption to the current public model

Files to change:

- `WORKSPACE`
- `third_party/rules_go_patches/**`
- `third_party/rules_go_patches/README.md`
- remove `third_party/rules_go/**` after all references move

Make these changes:

1. Export the canonical `all_patches` bundle from the frozen
   `rules_test_optimization` checkout into a consumer-owned
   `internal monorepo/third_party/rules_go_patches/` directory.
2. Commit the generated `BUILD.bazel` from the export tool.
3. Port the current patch-maintenance notes from
   `internal monorepo/third_party/rules_go/README.md` into
   `internal monorepo/third_party/rules_go_patches/README.md`, but update the text so
   it describes the new source of truth:
   - clean base from `rules_test_optimization`
   - consumer-owned patch bundle in `third_party/rules_go_patches/`
4. Remove the old `third_party/rules_go/` directory so `internal monorepo` has only one
   patch-bundle location.

From `$RTO_ROOT`, run the export tool:

```bash
python3 tools/dev/export_rules_go_patch_bundle.py \
  --bundle all_patches \
  --destination "$INTERNAL_MONOREPO_ROOT/third_party/rules_go_patches" \
  --force
```

In `internal monorepo/WORKSPACE`, replace the current upstream `rules_go` zip plus
local patch labels with the frozen public baseline and the exported
consumer-owned patch bundle. The first pilot keeps the proven
`workspace-go-monorepo-shape` fetch model:

- `git_repository(...)` for `datadog-rules-test-optimization`
- `git_repository(...)` for `datadog-rules-test-optimization-go`
- `http_archive(...)` only for `@io_bazel_rules_go`

Use this shape:

```bzl
RTO_COMMIT = "2917f0df87da958513fc9c4532abfa5895013913"
RTO_REMOTE = "https://github.com/Datadog/rules_test_optimization.git"
RTO_ARCHIVE_URL = "https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/%s" % RTO_COMMIT
RTO_ARCHIVE_PREFIX = "rules_test_optimization-%s" % RTO_COMMIT
RTO_ARCHIVE_SHA256 = "266af99edecaff5dd0ba0468b9f511c29b395723a15332c0c15259049a03ede1"

git_repository(
    name = "datadog-rules-test-optimization",
    commit = RTO_COMMIT,
    remote = RTO_REMOTE,
)

git_repository(
    name = "datadog-rules-test-optimization-go",
    commit = RTO_COMMIT,
    remote = RTO_REMOTE,
    strip_prefix = "modules/go",
    repo_mapping = {
        "@rules_go": "@io_bazel_rules_go",
    },
)

http_archive(
    name = "io_bazel_rules_go",
    urls = [RTO_ARCHIVE_URL],
    sha256 = RTO_ARCHIVE_SHA256,
    type = "tar.gz",
    strip_prefix = RTO_ARCHIVE_PREFIX + "/third_party/rules_go_orchestrion",
    patch_tool = "patch",
    patch_args = ["-p1"],
    patches = [
        "//third_party/rules_go_patches:0002-Include-logs-for-test-reports-regardless-of-failure-.patch",
        "//third_party/rules_go_patches:0008-Pass-through-cflags-to-the-assembler-in-cgo-mode.patch",
        "//third_party/rules_go_patches:0009-Use-LLVM-for-all-linking.patch",
        "//third_party/rules_go_patches:0011-fix-cdeps-propagation.patch",
        "//third_party/rules_go_patches:0013-Add-buildInfo-metadata-support.patch",
        "//third_party/rules_go_patches:0014-Fix-protobuf-compatibility-use-rules_proto-for-Proto.patch",
        "//third_party/rules_go_patches:0015-Set-GoLink-resource_set-to-match-lld-thread-count.patch",
        "//third_party/rules_go_patches:0015-Optimize-_filter_options-use-O1-dict-lookup-for-exac.patch",
        "//third_party/rules_go_patches:0016-lazy-cc-toolchain-resolution.patch",
    ],
)
```

Keep the existing `@io_bazel_rules_go` repository name and keep the existing
`go_rules_dependencies()`, `go_download_sdk(...)`, `go_register_toolchains()`,
and the rest of the current toolchain setup unchanged.

Do not convert the Datadog repos themselves to `http_archive(...)` in this
first pilot. That migration is out of scope until it is re-proven in the public
fixture repository first.

### 2. Add Datadog WORKSPACE repositories, the public Orchestrion helper, and the sync repo

Files to change:

- `WORKSPACE`

Add these declarations in `WORKSPACE`:

1. Load `test_optimization_sync` from
   `@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl`.
2. Load `go_orchestrion_tool_repo` from
   `@io_bazel_rules_go//go:orchestrion_workspace.bzl`.
3. Add local WORKSPACE constants:
   - `ORCHESTRION_VERSION = "v1.9.0"`
   - `DD_TRACE_GO_VERSION = "v2.9.0-dev"`
4. Instantiate `go_orchestrion_tool_repo(...)` with the shared-version form:

```bzl
go_orchestrion_tool_repo(
    version = ORCHESTRION_VERSION,
    dd_trace_go_version = DD_TRACE_GO_VERSION,
)
```

5. Instantiate the sync repo:

```bzl
test_optimization_sync(
    name = "test_optimization_data_test_optimization_worker",
    service = "test-optimization-worker",
    runtime_name = "go",
    runtime_version = "1.25.9",
)
```

Do not rename `rules_go_orchestrion_tool`.

Do not use `dd_trace_go_versions` in this pilot. The currently proven
monorepo-shaped tuple does not require the per-module override form.

### 3. Add repo-root Orchestrion pin files and export them for nested packages

Files to change:

- `go.mod`
- `go.sum`
- add `orchestrion.tool.go`
- add `orchestrion.yml`
- `BUILD.bazel`

Run the repo-root bootstrap work at the `internal monorepo` root, because the root Go
module is the authoritative module for the pilot service.

Use the repo's pinned Go version for all manual Go module commands:

```bash
export GO111MODULE=on
export GOWORK=off
export GOTOOLCHAIN=go1.25.9+auto
```

Then:

1. Run Orchestrion pin at the repository root:

```bash
go run github.com/DataDog/orchestrion@"${ORCHESTRION_VERSION}" pin
```

2. Patch the generated `orchestrion.tool.go` import block so it contains these
   blank imports and no legacy CI Visibility import:

```go
import (
    _ "github.com/DataDog/orchestrion"
    _ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration
    _ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
    _ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration
)
```

3. Align the repo-root module pins with the proven tuple:

```bash
go mod edit -require=github.com/DataDog/dd-trace-go/v2@"${DD_TRACE_GO_VERSION}"
go mod edit -require=github.com/DataDog/dd-trace-go/contrib/net/http/v2@"${DD_TRACE_GO_VERSION}"
go mod edit -require=github.com/DataDog/dd-trace-go/contrib/log/slog/v2@"${DD_TRACE_GO_VERSION}"
go get github.com/DataDog/dd-trace-go/v2/orchestrion@"${DD_TRACE_GO_VERSION}"
go mod tidy
```

4. Keep `gopkg.in/DataDog/dd-trace-go.v1` at the effective version already used
   by this service shape (`v1.74.8`). If `go mod tidy` changes that line's
   effective version, restore it before continuing.
5. If `orchestrion pin` did not leave `orchestrion.yml` behind, create this
   starter file at the repo root:

```yaml
---
# yaml-language-server: $schema=https://datadoghq.dev/orchestrion/schema.json
meta:
  name: datadog/go-bootstrap
  description: Datadog starter configuration for Orchestrion.

aspects: []
```

6. Extend root `BUILD.bazel` `exports_files([...])` to include:
   - `orchestrion.tool.go`
   - `orchestrion.yml`

Without those exports, nested packages cannot reliably use:

```bzl
[
    "//:go.mod",
    "//:go.sum",
    "//:orchestrion.tool.go",
    "//:orchestrion.yml",
]
```

The root `go.mod` change is repo-wide module state. That is expected in
WORKSPACE mode and is part of this pilot.

### 4. Add the pilot uploader target

Files to change:

- `BUILD.bazel`

Add a workspace-level uploader target at the repo root:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data_test_optimization_worker//:test_optimization_context",
    ],
    fail_on_error = True,
)
```

The pilot is single-service, so the uploader should carry exactly one
`test_optimization_context` target.

### 5. Add a dedicated pilot Bazel config instead of shared `.bazelrc` changes

Files to change:

- add `tools/bazelrc/test-optimization-worker-pilot.bazelrc`
- `.bazelrc`

Add this import to root `.bazelrc` next to the other `tools/bazelrc/*.bazelrc`
imports:

```text
import %workspace%/tools/bazelrc/test-optimization-worker-pilot.bazelrc
```

Create `tools/bazelrc/test-optimization-worker-pilot.bazelrc` and scope the
pilot settings under a named config so they do not affect ordinary builds:

```text
common:test-optimization-worker-pilot --repo_env=DD_API_KEY
common:test-optimization-worker-pilot --repo_env=DD_SITE
common:test-optimization-worker-pilot --repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL
common:test-optimization-worker-pilot --repo_env=DD_TEST_OPTIMIZATION_HTTP_CONNECT_TIMEOUT_SECONDS
common:test-optimization-worker-pilot --repo_env=DD_TEST_OPTIMIZATION_HTTP_MAX_TIME_SECONDS
common:test-optimization-worker-pilot --repo_env=DD_TEST_OPTIMIZATION_HTTP_RETRY_ATTEMPTS
common:test-optimization-worker-pilot --repo_env=DD_TEST_OPTIMIZATION_HTTP_RETRY_DELAY_SECONDS
common:test-optimization-worker-pilot --repo_env=DD_TEST_OPTIMIZATION_HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS
common:test-optimization-worker-pilot --repo_env=DD_ENV
common:test-optimization-worker-pilot --repo_env=DD_GIT_REPOSITORY_URL
common:test-optimization-worker-pilot --repo_env=DD_GIT_BRANCH
common:test-optimization-worker-pilot --repo_env=DD_GIT_TAG
common:test-optimization-worker-pilot --repo_env=DD_GIT_COMMIT_SHA
common:test-optimization-worker-pilot --repo_env=DD_GIT_HEAD_COMMIT
common:test-optimization-worker-pilot --repo_env=DD_GIT_COMMIT_MESSAGE
common:test-optimization-worker-pilot --repo_env=DD_GIT_HEAD_MESSAGE
common:test-optimization-worker-pilot --repo_env=DD_GIT_COMMIT_AUTHOR_NAME
common:test-optimization-worker-pilot --repo_env=DD_GIT_COMMIT_AUTHOR_EMAIL
common:test-optimization-worker-pilot --repo_env=DD_GIT_COMMIT_AUTHOR_DATE
common:test-optimization-worker-pilot --repo_env=DD_GIT_COMMIT_COMMITTER_NAME
common:test-optimization-worker-pilot --repo_env=DD_GIT_COMMIT_COMMITTER_EMAIL
common:test-optimization-worker-pilot --repo_env=DD_GIT_COMMIT_COMMITTER_DATE
common:test-optimization-worker-pilot --repo_env=DD_GIT_HEAD_AUTHOR_NAME
common:test-optimization-worker-pilot --repo_env=DD_GIT_HEAD_AUTHOR_EMAIL
common:test-optimization-worker-pilot --repo_env=DD_GIT_HEAD_AUTHOR_DATE
common:test-optimization-worker-pilot --repo_env=DD_GIT_HEAD_COMMITTER_NAME
common:test-optimization-worker-pilot --repo_env=DD_GIT_HEAD_COMMITTER_EMAIL
common:test-optimization-worker-pilot --repo_env=DD_GIT_HEAD_COMMITTER_DATE
common:test-optimization-worker-pilot --repo_env=DD_GIT_PR_BASE_BRANCH
common:test-optimization-worker-pilot --repo_env=DD_GIT_PR_BASE_BRANCH_SHA
common:test-optimization-worker-pilot --repo_env=DD_GIT_PR_BASE_BRANCH_HEAD_SHA
common:test-optimization-worker-pilot --repo_env=DD_PR_NUMBER
common:test-optimization-worker-pilot --repo_env=GO_MODULE_PATH=<internal_go_module>
common:test-optimization-worker-pilot --repo_env=FETCH_SALT
test:test-optimization-worker-pilot --remote_download_outputs=all
```

Every sync, test, run, and query command for this pilot must use
`--config=test-optimization-worker-pilot`.

Keep the explicit `GO_MODULE_PATH=<internal_go_module>` passthrough in
the pilot config. That removes avoidable ambiguity when sync runs from
non-standard local contexts.

### 6. Add a dedicated pilot wrapper that preserves `dd_go_test` policy

Files to change:

- `rules/go/private/dd_go_test/dd_go_test.bzl`
- add `rules/go/private/dd_go_test/dd_topt_go_test.bzl`
- add `rules/go/dd_topt_go_test.bzl`

Do not replace the current public `dd_go_test` macro.

Instead:

1. Factor the existing policy logic in
   `rules/go/private/dd_go_test/dd_go_test.bzl` into one shared helper that:
   - applies Docker defaults
   - bans unmanaged `local` / `exclusive`
   - calls the chosen underlying test macro
   - emits `<name>.build_test` when
     `kwargs.get("flaky", False) or is_flaky(name)` is true
2. Keep `dd_go_test(...)` calling that helper with raw `go_test`.
3. Add a new pilot-only `dd_topt_go_test(...)` wrapper that calls the same
   helper with Datadog's companion macro and prebinds:
   - `topt_data` from
     `@test_optimization_data_test_optimization_worker//:export.bzl`
   - `orchestrion_pin_files = ["//:go.mod", "//:go.sum", "//:orchestrion.tool.go", "//:orchestrion.yml"]`

The new pilot wrapper must pass ordinary test kwargs through unchanged so these
existing target shapes still work:

- `embed = [":go_default_library"]`
- `data = glob([".recordings/**"])`
- `embedsrcs = [...]`
- explicit `deps`
- explicit `flaky = True`

This keeps the repository policy in one place while limiting Test Optimization
to the pilot targets.

### 7. Convert only the pilot BUILD files

Files to change:

- `domains/ci-app/apps/apis/test-optimization-worker/worker/BUILD.bazel`
- `domains/ci-app/apps/apis/test-optimization-worker/worker/notifications/BUILD.bazel`
- `domains/ci-app/apps/apis/test-optimization-worker/worker/store/BUILD.bazel`

Make these changes:

1. For the three pilot targets, change the load from:

```bzl
load("//rules/go:dd_go_test.bzl", "dd_go_test")
```

to:

```bzl
load("//rules/go:dd_topt_go_test.bzl", "dd_topt_go_test")
```

2. Rename only the macro call, not the target name:

```bzl
dd_topt_go_test(
    name = "go_default_test",
    ...
)
```

3. Leave `flaky_test_categorization` unchanged on `dd_go_test`.
4. In `worker/BUILD.bazel`, add:

```bzl
dd_topt_go_test(
    name = "topt_flaky_test",
    srcs = [
        "kpi_statistics_test.go",
        "kpi_test.go",
        "purger_test.go",
        "testmanagement_test.go",
    ],
    embed = [":go_default_library"],
    flaky = True,
    deps = [
        ...the same deps as go_default_test...
    ],
)
```

The parity target must reuse the same `embed`, source set, and dependency set
as `worker:go_default_test`. The only behavioral difference is the name and
`flaky = True`.

## Validation Sequence

Run the validation in this exact order.

### 1. Public contract preflight

Before touching `internal monorepo`, confirm that the current public consumer shapes are
healthy and still match the current contract:

- `rules_test_optimization_tests/fixtures/workspace-go`
- `rules_test_optimization_tests/fixtures/workspace-go-patched`
- `rules_test_optimization_tests/fixtures/bzlmod-go-patched`
- `rules_test_optimization_tests/fixtures/workspace-go-monorepo-shape`

Run:

```bash
(cd "$RTO_TESTS_ROOT/fixtures/workspace-go" && ./runtests && ./runtests-hermetic)
(cd "$RTO_TESTS_ROOT/fixtures/workspace-go-patched" && ./runtests && ./runtests-hermetic)
(cd "$RTO_TESTS_ROOT/fixtures/bzlmod-go-patched" && ./runtests && ./runtests-hermetic)
(cd "$RTO_TESTS_ROOT/fixtures/workspace-go-monorepo-shape" && ./runtests && ./runtests-hermetic)
```

Expected baseline:

- the first three fixtures still validate the normal per-module path
- the monorepo-shaped fixture still validates
  `payload_selection = "full_bundle_disabled"`
- the monorepo-shaped fixture still exercises:
  - repo-local `dd_go_test` / `dd_topt_go_test` split
  - `embedsrcs`
  - `data = glob(...)`
  - explicit flaky companion generation
  - uploader flow

If you must validate unpublished local `rules_test_optimization` changes before
landing them, use the fixture repo's documented local-archive path for the
patched fixtures:

```bash
RTO_LOCAL_ARCHIVE=1 ./runtests
```

Do not require cold-start `RTO_LOCAL_ARCHIVE=1 ./runtests-hermetic` runs for
the patched fixtures. That path is intentionally unsupported today.

If executing the pilot reveals a generic bug in the public rules repo, stop the
`internal monorepo` rollout and fix that public bug first with the current fixture
coverage. Do not widen this pilot into a cross-repository refactor.

### 2. Repo-root Orchestrion and tracer validation

After the `internal monorepo` repo-root Go module changes are in place, verify the
exact pinned tuple at the `internal monorepo` root:

```bash
go list -mod=mod -m -json github.com/DataDog/dd-trace-go/v2
go list -mod=mod -m -json github.com/DataDog/dd-trace-go/contrib/net/http/v2
go list -mod=mod -m -json github.com/DataDog/dd-trace-go/contrib/log/slog/v2
go list -mod=mod -m -json gopkg.in/DataDog/dd-trace-go.v1
go list -mod=mod github.com/DataDog/dd-trace-go/v2/orchestrion
```

Required outcome:

- all three v2 modules resolve to
  `v2.9.0-dev`
- `gopkg.in/DataDog/dd-trace-go.v1` still resolves to `v1.74.8`
- `github.com/DataDog/dd-trace-go/v2/orchestrion` resolves cleanly from the
  same root module

Also verify the root labels exist:

```bash
bzl query 'set("//:go.mod" "//:go.sum" "//:orchestrion.tool.go" "//:orchestrion.yml")'
```

### 3. Sync repo validation

Force a fresh sync with the pilot config:

```bash
bzl sync \
  --config=test-optimization-worker-pilot \
  --only=test_optimization_data_test_optimization_worker \
  --repo_env=FETCH_SALT="$(date +%s)"
```

If Bazel reports a WORKSPACE-disabled sync error, rerun the same command with
`--enable_workspace`.

Then inspect the generated repo:

```bash
SYNC_ROOT="$(bzl info output_base)/external/test_optimization_data_test_optimization_worker/.testoptimization"
EXPORT_BZL="$(bzl info output_base)/external/test_optimization_data_test_optimization_worker/export.bzl"
BUILD_FILE="$(bzl info output_base)/external/test_optimization_data_test_optimization_worker/BUILD"

ls -R "$SYNC_ROOT"
rg -n 'module_path|module_included|test-optimization-worker' "$EXPORT_BZL"
rg -n 'module_' "$BUILD_FILE"
```

Verify the generated repo contains:

- `cache/http/settings.json`
- `cache/http/known_tests.json`
- `cache/http/test_management.json`
- `manifest.txt`
- `context.json`

Then set `EXPECTED_PAYLOAD_SELECTION` using exactly one of these valid states:

1. Current fallback state:
   - Go export data shows `module_included = False`
   - there is no usable Go per-module filegroup set for this pilot
   - set `EXPECTED_PAYLOAD_SELECTION=full_bundle_disabled`
2. Provisioned per-module state:
   - Go export data shows `module_included = True`
   - Go per-module filegroups are exported
   - set `EXPECTED_PAYLOAD_SELECTION=module`

Any mixed state is a stop condition. Examples:

- `module_included = True` but no exported Go per-module filegroups
- exported Go per-module filegroups exist but `module_included = False`

The current likely outcome, based on the existing monorepo-shaped public
fixture, is `EXPECTED_PAYLOAD_SELECTION=full_bundle_disabled`.

### 4. Local plain-path control

Run the untouched local control target:

```bash
bzl test \
  --config=test-optimization-worker-pilot \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/flaky_test_categorization:go_default_test
```

This target must still succeed through the ordinary `dd_go_test -> go_test`
path.

### 5. Registry-flaky build_test control

Run the existing registry-flaky control target:

```bash
bzl test \
  --config=test-optimization-worker-pilot \
  //domains/case_management/modules/slack:go_default_test.build_test
```

This validates that the shared helper still emits `.build_test` targets for the
central `is_flaky(name)` path, not only for explicit `flaky = True`.

### 6. Instrumented target validation

Run the instrumented targets in rollout order:

```bash
bzl test \
  --config=test-optimization-worker-pilot \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/notifications:go_default_test

bzl test \
  --config=test-optimization-worker-pilot \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/store:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:topt_flaky_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:topt_flaky_test.build_test
```

If `worker/notifications` fails because the proven tuple does not work with the
pilot service, stop the rollout.

If `worker/notifications` succeeds but `worker` or `worker/store` fail because
the mixed v1/v2 service shape is not compatible with the proven tuple, stop the
rollout and revert the `internal monorepo` pilot changes. Do not land a partial service
rollout under this plan.

### 7. Metadata and payload validation

After the instrumented tests run, inspect the test outputs:

```bash
find bazel-testlogs/domains/ci-app/apps/apis/test-optimization-worker \
  -name '*_topt_bazel_metadata.json' -print

find bazel-testlogs/domains/ci-app/apps/apis/test-optimization-worker \
  -path '*/test.outputs/payloads/tests/*.json' -print
```

For each instrumented target, verify the emitted Bazel metadata JSON contains:

- `bazel.test_optimization.repo_name = "test_optimization_data_test_optimization_worker"`
- `bazel.test_optimization.service_name = "test-optimization-worker"`
- `bazel.test_optimization.runtime_name = "go"`
- `bazel.go.importpath_source = "inferred"`
- `bazel.go.orchestrion.enabled = true`
- `bazel.go.payload_selection = "${EXPECTED_PAYLOAD_SELECTION}"`
- `bazel.go.importpath = "<internal_go_module>/domains/ci-app/apps/apis/test-optimization-worker/worker"`
  for `worker:go_default_test` and `worker:topt_flaky_test`
- `bazel.go.importpath = "<internal_go_module>/domains/ci-app/apps/apis/test-optimization-worker/worker/notifications"`
  for `worker/notifications:go_default_test`
- `bazel.go.importpath = "<internal_go_module>/domains/ci-app/apps/apis/test-optimization-worker/worker/store"`
  for `worker/store:go_default_test`

Interpretation rules:

- If `EXPECTED_PAYLOAD_SELECTION=module`, then `full_bundle_disabled` is a
  failure.
- If `EXPECTED_PAYLOAD_SELECTION=full_bundle_disabled`, then that fallback is
  acceptable for this pilot.
- `full_bundle_no_match` is always a failure.

For the untouched local control target, there should be no
`*_topt_bazel_metadata.json` file because it did not go through the Datadog
wrapper.

### 8. Uploader validation

Run the uploader against downloaded test outputs:

```bash
bzl test \
  --config=test-optimization-worker-pilot \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/notifications:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker/store:go_default_test \
  //domains/ci-app/apps/apis/test-optimization-worker/worker:topt_flaky_test \
  || test_status=$?; test_status=${test_status:-0}

DD_API_KEY="$DD_API_KEY" DD_SITE="${DD_SITE:-datadoghq.com}" \
  bzl run --config=test-optimization-worker-pilot //:dd_upload_payloads

exit $test_status
```

Because the pilot config sets `--remote_download_outputs=all` for tests, this
same command works for local runs and remote-exec runs.

## Acceptance Criteria

The pilot is complete only when all of these are true:

1. `internal monorepo` consumes the frozen public repo commit through:
   - clean `rules_go` base from `third_party/rules_go_orchestrion`
   - consumer-owned `third_party/rules_go_patches`
   - Datadog core + Go companion external repos
2. Root `go.mod`, `go.sum`, `orchestrion.tool.go`, and `orchestrion.yml` are
   present and exported from root `BUILD.bazel`.
3. The repo-root Go module resolves the proven tuple:
   - Orchestrion `v1.9.0`
   - v2 tracer modules
     `v2.9.0-dev`
   - v1 tracer `v1.74.8`
4. `test_optimization_data_test_optimization_worker` syncs successfully and
   exports a consistent state for either:
   - per-module selection (`EXPECTED_PAYLOAD_SELECTION=module`)
   - fallback disabled selection
     (`EXPECTED_PAYLOAD_SELECTION=full_bundle_disabled`)
5. The three pilot targets run successfully with the Datadog wrapper.
6. `worker:topt_flaky_test.build_test` exists and passes.
7. The existing registry-flaky control target
   `//domains/case_management/modules/slack:go_default_test.build_test`
   still exists and passes.
8. Each instrumented target emits:
   - payload files under `test.outputs/payloads/tests/`
   - Bazel metadata with repo, service, runtime, importpath source, and
     `payload_selection = "${EXPECTED_PAYLOAD_SELECTION}"`
9. No instrumented target emits `payload_selection = "full_bundle_no_match"`.
10. `//:dd_upload_payloads` succeeds with `fail_on_error = True`.
11. The untouched local control target still succeeds through the plain local
    `dd_go_test` path.

## Stop Conditions

Stop the rollout and revert the `internal monorepo` pilot changes if any of these
happen:

- the local `rules_test_optimization_tests` checkout no longer contains the
  monorepo-shaped fixture, README documentation, and workflow lane that define
  the current public proof baseline
- the pilot cannot use the repo-root pseudo-version tuple
  (`v1.9.0` plus
  `v2.9.0-dev`)
- the sync/export state is internally inconsistent
- any instrumented target emits `payload_selection = "full_bundle_no_match"`
- `worker/notifications` cannot be instrumented with the proven tuple
- the later `worker` or `worker/store` targets fail because the mixed v1/v2
  service shape is incompatible with the proven tuple
- the pilot requires a generic fix in `rules_test_optimization` or
  `rules_test_optimization_tests`

If a generic rules change is needed, land that fix with the current public
fixture coverage first, then re-freeze the inputs and write a new `internal monorepo`
pilot plan against the new state.

## Out Of Scope

This plan does not include:

- repository-wide conversion of `dd_go_test`
- a generic multi-service `internal monorepo` wrapper architecture
- coverage payload rollout gates
- non-Go runtimes in `internal monorepo`
- backend provisioning work to create module data for `test-optimization-worker`
- changes to the public rules repositories beyond fixing a generic bug that
  reproduces outside `internal monorepo`
