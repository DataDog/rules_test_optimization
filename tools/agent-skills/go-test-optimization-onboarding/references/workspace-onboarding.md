# WORKSPACE Go Onboarding

Use this reference for repositories that still rely on `WORKSPACE`, including
large monorepos with custom Go wrappers or non-default `rules_go` repository
names.

## Inspect Before Editing

Collect these facts from the consumer repository:

- Existing `rules_go` repository name, commonly `io_bazel_rules_go`.
- Existing Bazel command wrapper, for example `bzl`, `bazelw`, or raw `bazel`.
- Existing Go SDK/toolchain version.
- Existing Go test wrapper macros and where repo policy lives.
- Existing `.bazelrc` config names used in CI.
- Pilot service name and Go module path.
- Sync repository name for the service. Use a stable, descriptive name when the
  repository will eventually instrument multiple services.
- Pilot runtime test targets that should emit payloads.
- Plain control targets that must remain uninstrumented.
- Build-only or `.build_test` targets that should not be expected to emit
  Datadog payloads.

Do not replace the repository's scheduling, Docker, tag, flaky, or shard policy.
Keep that logic in a repo-local wrapper layer and only swap the raw Go test
implementation for the Test Optimization path where needed.

## Dependency Wiring

Use the public WORKSPACE helper instead of manually copying patches. Pin a
commit reachable from `origin/main`. If the repository requires archive fetches
for `rules_go`, generate or copy the complete archive tuple from the published
onboarding pins; do not invent a SHA or point at a feature-branch commit.

From this repository, generate published pins with:

```bash
./bazelw run //tools/dev:print_go_onboarding_pins -- \
  --commit "$(git rev-parse origin/main)" \
  --variant complete \
  --verify-main-reachable
```

Use `--variant base` for normal repositories and `--variant complete` for large
monorepos that need the compatibility layer.

```bzl
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

git_repository(
    name = "datadog-rules-test-optimization",
    commit = "<published-main-commit>",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
)

load("@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl", "datadog_go_test_optimization_workspace_repositories")

datadog_go_test_optimization_workspace_repositories(
    rto_commit = "<published-main-commit>",
    rules_go_repo_name = "io_bazel_rules_go",
    rules_go_variant = "complete",
)
```

Choose the variant deliberately:

- `base`: normal Go repositories that need generic Orchestrion support.
- `complete`: large monorepos that need the extended compatibility layer.

Use the repository's existing `rules_go` repo name when it is already
established. The Go companion maps its `@rules_go` dependency to that name.

If the repository uses a non-default fetch model, set it explicitly:

```bzl
datadog_go_test_optimization_workspace_repositories(
    datadog_fetch = "git",
    rto_archive_prefix = "<archive-prefix>",
    rto_archive_sha256 = "<archive-sha256>",
    rto_archive_type = "tar.gz",
    rto_archive_url = "<archive-url>",
    rto_commit = "<published-main-commit>",
    rto_remote = "https://github.com/DataDog/rules_test_optimization.git",
    rules_go_fetch = "archive",
    rules_go_repo_name = "io_bazel_rules_go",
    rules_go_variant = "complete",
)
```

Use `rules_go_fetch = "git"` only when the consumer environment can fetch the
same published Git commit reliably. Use `rules_go_fetch = "archive"` when the
consumer's fetch policy or mirror expects an archive with a checked SHA.

## Optional Bootstrap Scaffolding

The Go bootstrap can generate WORKSPACE-oriented scaffolding without editing
`WORKSPACE` itself. This is useful for large repositories because it produces
the same doctor, uploader, pin files, wrapper template, `.bazelrc`, and
validation script patterns that the public docs expect.

The bootstrap command target must be resolvable before you can run it:

- If the consumer already resolves `@datadog-rules-test-optimization-go`, run
  the command from the consumer repository with its normal Bazel entrypoint.
- If the consumer does not resolve that repository yet, first place the manual
  dependency wiring from the previous section, or run the bootstrap from a
  separate `rules_test_optimization` checkout and pass
  `--workspace /absolute/path/to/consumer`.
- Do not assume `@datadog-rules-test-optimization-go` exists in a blank
  WORKSPACE repository.

Use print modes first:

```bash
<bazel-command> run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --workspace /absolute/path/to/consumer \
  --workspace-mode \
  --service <datadog-service> \
  --runtime-version <go-version> \
  --sync-repo-name test_optimization_data_<service_key> \
  --rto-commit <published-main-commit> \
  --rules-go-variant complete \
  --rules-go-repo-name io_bazel_rules_go \
  --bazel-command <bazel-command> \
  --bazel-config test-optimization \
  --expected-target //path/to/pilot:go_default_test \
  --control-target //path/to/plain:go_default_test \
  --large-monorepo \
  --default-jobs 1 \
  --shutdown-bazel-on-exit \
  --print-workspace-snippet \
  --print-bazelrc-snippet \
  --print-validation-script
```

Then use write modes only for files the repository should actually own:

```bash
<bazel-command> run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --workspace /absolute/path/to/consumer \
  --workspace-mode \
  --service <datadog-service> \
  --runtime-version <go-version> \
  --sync-repo-name test_optimization_data_<service_key> \
  --rto-commit <published-main-commit> \
  --rules-go-variant complete \
  --rules-go-repo-name io_bazel_rules_go \
  --bazel-command <bazel-command> \
  --bazel-config test-optimization \
  --expected-target //path/to/pilot:go_default_test \
  --control-target //path/to/plain:go_default_test \
  --write-bazelrc \
  --write-root-targets \
  --write-orchestrion-files \
  --write-wrapper-template \
  --write-validation-script \
  --go-mod-sync=targeted
```

Replace `<bazel-command>` with the repository's real entrypoint, such as `bzl`
or `./bazelw` when running from the consumer repository. If running from a
separate `rules_test_optimization` checkout, use that checkout's Bazel wrapper
and replace the target with `//modules/go:dd_topt_go_bootstrap`; keep
`--workspace` pointed at the consumer root. Review generated wrapper templates
before adopting them: the repository must keep its own scheduling, Docker, tag,
flaky, and registry policy in local wrapper code.

If the repository needs archive-mode WORKSPACE wiring, add the same fetch and
archive flags used by the manual helper snippet:
`--rules-go-fetch archive`, `--rto-archive-url`, `--rto-archive-sha256`,
`--rto-archive-prefix`, and `--rto-archive-type`. Add
`--datadog-fetch archive` only when the Datadog repositories themselves must
also be fetched from the archive.

Review any generated WORKSPACE sync snippet before committing it. If the Go
module path is known and stable, add `runtime_module_path = "<go-module-path>"`
to `test_optimization_sync(...)` even if the generated snippet omits it. That
keeps checked-in configuration self-contained and avoids relying on
`GO_MODULE_PATH` in normal CI.

## Go Module And go_repository Updates

Bootstrap defaults to `--go-mod-sync=targeted` when it is allowed to write
Orchestrion pin files. Targeted sync updates only the Orchestrion and Datadog
tracer modules needed by the generated tool file; it does not run a broad
`go mod tidy`.

Use these rules for large WORKSPACE repositories:

- Keep `--go-mod-sync=targeted` when bootstrap should update `go.mod` and
  `go.sum` for the Orchestrion tool imports.
- Use `--go-mod-sync=off` when the repository has its own Go module update
  process and you only want bootstrap to write Bazel scaffolding.
- Use `--go-mod-sync=tidy` only when the repository owner explicitly wants a
  full module tidy as part of onboarding.
- If the repository checks in Gazelle-style `go_repository(...)` declarations,
  also run bootstrap with `--check-go-repositories` after targeted sync.
- If the repository has an existing refresh command for those declarations,
  pass it through `--go-repositories-refresh-command '<repo-owned-command>'`
  instead of editing the generated repository rules manually.
- If no refresh command exists, run with `--print-go-repository-updates` and
  apply the printed version changes using the repository's normal dependency
  workflow.

The goal is to keep the tracer version used by Orchestrion, the Go module graph,
and any checked-in WORKSPACE `go_repository(...)` declarations coherent without
rewriting unrelated dependencies.

## Sync And Orchestrion Setup

Declare the Orchestrion tool repository and Test Optimization sync repository
near the repository's existing Go toolchain wiring:

```bzl
load("@io_bazel_rules_go//go:orchestrion_workspace.bzl", "go_orchestrion_tool_repo")
load("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")

go_orchestrion_tool_repo(
    dd_trace_go_version = "v2.9.0-dev.0.20260416093245-194346a71c51",
    version = "v1.9.0",
)

test_optimization_sync(
    name = "test_optimization_data_<service_key>",
    debug = True,
    require_git_metadata = True,
    runtime_module_path = "<go-module-path>",
    runtime_name = "go",
    runtime_version = "<go-version>",
    service = "<datadog-service>",
)
```

Use the actual `rules_go` repository name in the `go_orchestrion_tool_repo`
load. For example, if the repository maps rules_go to `io_bazel_rules_go`, load
from `@io_bazel_rules_go//go:orchestrion_workspace.bzl`.

If the repository already defines a Go version constant for Bazel toolchains,
reuse that constant for `runtime_version` instead of hardcoding another copy.
Prefer checked-in `runtime_module_path` when the service module path is stable.
Use `GO_MODULE_PATH` through `--repo_env` only for local experiments or
repository layouts where the module path must stay environment-specific.

Use the actual sync repository name everywhere later. If the sync rule is named
`test_optimization_data_worker`, the labels are:

```text
@test_optimization_data_worker//:export.bzl
@test_optimization_data_worker//:test_optimization_context
```

## Orchestrion Pin Files

Add root pin files when the repository does not already have them:

```go
//go:build tools

package tools

import (
    _ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2"
    _ "github.com/DataDog/dd-trace-go/contrib/net/http/v2"
    _ "github.com/DataDog/dd-trace-go/v2/orchestrion"
    _ "github.com/DataDog/orchestrion"
)
```

```yaml
# yaml-language-server: $schema=https://datadoghq.dev/orchestrion/schema.json
meta:
  name: test-optimization
  description: Orchestrion configuration for Datadog Test Optimization.

aspects: []
```

Export those files from the root package:

```bzl
exports_files([
    "go.mod",
    "go.sum",
    "orchestrion.tool.go",
    "orchestrion.yml",
])
```

If `go.mod` or `go.sum` are already exported, extend the existing
`exports_files` list instead of creating a duplicate declaration. The important
invariant is that every label used in `orchestrion_pin_files` is visible from
the target packages that call the wrapper.

Update `go.mod` and `go.sum` using the repository's normal Go module workflow
so the final test binary can resolve the packages injected by Orchestrion. Keep
the dd-trace-go version coherent with `go_orchestrion_tool_repo`.

## Bazel Config

Add a named config and use it consistently for sync, test, doctor, and upload:

```text
common:test-optimization --repo_env=DD_API_KEY
common:test-optimization --repo_env=DD_SITE
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL
common:test-optimization --repo_env=DD_SERVICE
common:test-optimization --repo_env=DD_ENV
common:test-optimization --repo_env=FETCH_SALT
common:test-optimization --repo_env=DD_GIT_REPOSITORY_URL
common:test-optimization --repo_env=DD_GIT_BRANCH
common:test-optimization --repo_env=DD_GIT_TAG
common:test-optimization --repo_env=DD_GIT_COMMIT_SHA
common:test-optimization --repo_env=DD_GIT_HEAD_COMMIT
common:test-optimization --repo_env=DD_GIT_COMMIT_MESSAGE
common:test-optimization --repo_env=DD_GIT_HEAD_MESSAGE
common:test-optimization --repo_env=DD_GIT_COMMIT_AUTHOR_NAME
common:test-optimization --repo_env=DD_GIT_COMMIT_AUTHOR_EMAIL
common:test-optimization --repo_env=DD_GIT_COMMIT_AUTHOR_DATE
common:test-optimization --repo_env=DD_GIT_COMMIT_COMMITTER_NAME
common:test-optimization --repo_env=DD_GIT_COMMIT_COMMITTER_EMAIL
common:test-optimization --repo_env=DD_GIT_COMMIT_COMMITTER_DATE
common:test-optimization --repo_env=DD_GIT_HEAD_AUTHOR_NAME
common:test-optimization --repo_env=DD_GIT_HEAD_AUTHOR_EMAIL
common:test-optimization --repo_env=DD_GIT_HEAD_AUTHOR_DATE
common:test-optimization --repo_env=DD_GIT_HEAD_COMMITTER_NAME
common:test-optimization --repo_env=DD_GIT_HEAD_COMMITTER_EMAIL
common:test-optimization --repo_env=DD_GIT_HEAD_COMMITTER_DATE
common:test-optimization --repo_env=DD_GIT_PR_BASE_BRANCH
common:test-optimization --repo_env=DD_GIT_PR_BASE_BRANCH_SHA
common:test-optimization --repo_env=DD_GIT_PR_BASE_BRANCH_HEAD_SHA
common:test-optimization --repo_env=DD_PR_NUMBER
test:test-optimization --remote_download_outputs=all
# Optional for local experiments when runtime_module_path is not checked in.
common:test-optimization --repo_env=GO_MODULE_PATH
```

The required keys mirror the public sync metadata environment contract used by
the bootstrap. Runtime-specific overrides such as `GO_MODULE_PATH` are
optional and should be used only when the checked-in sync configuration cannot
carry the module path. Keeping extra values as `--repo_env` is safe for the
test action cache because they affect repository/module resolution, not the
test sandbox.

Never add:

```text
test:test-optimization --test_env=DD_GIT_...
test:test-optimization --test_env=DD_API_KEY
test:test-optimization --test_env=DD_TEST_OPTIMIZATION_AGENT_URL
test:test-optimization --test_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL
```

`DD_GIT_*` belongs to metadata sync, not the test action cache key. Upload
credentials and upload endpoints belong to the uploader runtime, not the test
sandbox.

If the repository already uses a service-specific config name, keep it. The
important part is that sync, test, doctor, and uploader commands all use the
same config, and that the test config includes `--remote_download_outputs=all`
when remote outputs may otherwise stay remote-only.

## Root Targets

Add one doctor and one uploader target at the repository root:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = ["@test_optimization_data_<service_key>//:test_optimization_context"],
    expected_targets = [
        "//path/to/pilot:go_default_test",
    ],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data_<service_key>//:test_optimization_context"],
    fail_on_error = True,
)
```

Only put targets in `expected_targets` when they are real runtime test targets.
Do not expect payloads from `.build_test` controls or analysis/build-only
targets.

## Local Wrapper Pattern

For monorepos, avoid changing every BUILD file to load public macros directly.
Prefer this split:

- A shared repo-local policy helper applies Docker defaults, tags, shards,
  flaky policy, exec constraints, and registry behavior.
- The existing plain wrapper calls that helper with raw `go_test`.
- A new Test Optimization wrapper calls that helper with `dd_topt_go_test`.
- The Test Optimization wrapper sets Orchestrion pin files and `topt_data`.
- The wrapper rejects explicit per-target `topt_data` and
  `orchestrion_pin_files` overrides when those values must stay consistent
  across the repository.

The wrapper should always pass stable Orchestrion pin files when tests are not
at the repo root:

```bzl
orchestrion_pin_files = [
    "//:go.mod",
    "//:go.sum",
    "//:orchestrion.tool.go",
    "//:orchestrion.yml",
]
topt_data = topt_data
```

If the repository has multiple Go modules, use the pin files that correspond to
the module owning the target.

## Target Conversion

Convert a small pilot first:

- Change only runtime test targets from the plain wrapper to the Test
  Optimization wrapper.
- Keep target names stable.
- Keep ordinary test attributes unchanged.
- Keep plain controls on the existing wrapper.
- Keep `.build_test` controls out of the doctor `expected_targets` list because
  they build the target but do not emit runtime payloads.
- Add one intentionally flaky runtime control only if the repository needs to
  prove flaky policy behavior.

After the pilot is green, expand service by service. Do not use a pilot-only
wrapper design that cannot scale to the rest of the repository.
