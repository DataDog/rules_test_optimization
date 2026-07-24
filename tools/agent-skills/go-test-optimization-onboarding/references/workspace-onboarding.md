<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

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
- Ordinary control targets used to prove config-disabled behavior.
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
  --rules-go-upstream v0_60_0 \
  --variant base \
  --verify-main-reachable
```

Use `--variant base`. When multiple upstream `rules_go` versions are supported,
use `--rules-go-upstream` to choose the upstream support line; omit it to
preserve the repository default. The current published release tuple is tracked in
[`docs/Installation_Reference.md`](../../../../docs/Installation_Reference.md#current-v120-published-tuple).

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
    rules_go_upstream = "v0_60_0",
    rules_go_variant = "base",
)
```

Omit `rules_go_upstream` to preserve the repository default. The default is
currently `v0_60_0`, which preserves the existing
`third_party/rgo/v0_60_0/base` path.

Use the repository's existing `rules_go` repo name when it is already
established. The Go companion maps its `@rules_go` dependency to that name.

Add these lines to the named config used by test, doctor, and uploader:

```text
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
build:test-optimization --@io_bazel_rules_go//go/private/orchestrion:enabled=true
```

`--config=test-optimization` is the only user-facing switch. Omitting it
renders disabled metadata stubs and selects the local empty Orchestrion aliases.

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
    rules_go_upstream = "v0_60_0",
    rules_go_variant = "base",
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
  --rules-go-upstream v0_60_0 \
  --rules-go-variant base \
  --rules-go-repo-name io_bazel_rules_go \
  --bazel-command <bazel-command> \
  --bazel-config test-optimization \
  --expected-target //path/to/pilot:go_default_test \
  --control-target //path/to/plain:go_default_test \
  --doctor-target //tools/test_optimization:dd_test_optimization_doctor \
  --upload-target //tools/test_optimization:dd_upload_payloads \
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
  --rules-go-upstream v0_60_0 \
  --rules-go-variant base \
  --rules-go-repo-name io_bazel_rules_go \
  --bazel-command <bazel-command> \
  --bazel-config test-optimization \
  --expected-target //path/to/pilot:go_default_test \
  --control-target //path/to/plain:go_default_test \
  --doctor-target //tools/test_optimization:dd_test_optimization_doctor \
  --upload-target //tools/test_optimization:dd_upload_payloads \
  --write-bazelrc \
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
module path is known and stable, pass `module_path = "<go-module-path>"` to
`dd_topt_go_workspace_sync_repositories(...)`. That
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
through the reusable Go companion helpers near the repository's existing Go
toolchain wiring:

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_orchestrion_repository.bzl", "dd_topt_go_orchestrion_tool_repo")
load("@datadog-rules-test-optimization-go//:topt_go_workspace.bzl", "dd_topt_go_workspace_sync_repositories")

dd_topt_go_orchestrion_tool_repo(
    dd_trace_go_version = "v2.9.0",
    go_sdk_root = "@go_sdk//:ROOT",
    go_sdk_version = "<go-version>",
    version = "v1.9.0",
)

# Call the repository's existing go_rules_dependencies() wiring after the
# real tool repository. rules_go supplies the disabled fallback itself.

dd_topt_go_workspace_sync_repositories(
    name = "test_optimization_data_<service_key>",
    debug = True,
    require_git_metadata = True,
    module_path = "<go-module-path>",
    runtime_version = "<go-version>",
    service = "<datadog-service>",
)
```

The public Go helper is config-gated by default. Do not add a second enable
attribute to each repository or test target.

`@go_sdk//:ROOT` is the SDK registered by the repository's existing
`go_register_toolchains(version = "<go-version>")` call. Keep
`go_sdk_version`, `runtime_version`, and that toolchain version equal. This
central wiring lets enabled Orchestrion bootstrap without a host `go` binary;
it is not repeated per service.

The helper loads the public Orchestrion repository API through the Go
companion's repository mapping, so consumers do not load it from their apparent
`rules_go` repository directly. The apparent repository name still belongs in
the `.bazelrc` analysis-time flag shown above. Do not load
`orchestrion_empty_repository`; the fork creates that fallback internally for
ordinary WORKSPACE use.

If the repository already defines a Go version constant for Bazel toolchains,
reuse that constant for `runtime_version` instead of hardcoding another copy.
Prefer checked-in `module_path` when the service module path is stable.
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

For large monorepos where root-level tool imports would churn the main module,
do not add a root `orchestrion.tool.go` only for Test Optimization. Keep the
Orchestrion tool version in Bazel, then use package-local pin files. An explicit
`orchestrion_pin_files = []` is valid only when the target package contains a
package-local `go.mod` that the macro can auto-discover. Otherwise the central
wrapper must pass visible labels for the owning module's `go.mod` and relevant
pin files.
For standard Go `testing`, that repo-local wrapper should also inject
`orchestrion_mode = "test_optimization"`. Automatic `testify/suite`
instrumentation is outside this mode.

## Bazel Config

Add a named config and use it consistently for sync, test, doctor, and upload:

```text
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
common:test-optimization --repo_env=DD_API_KEY
common:test-optimization --repo_env=DD_SITE
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL
common:test-optimization --repo_env=DD_SERVICE
common:test-optimization --repo_env=DD_ENV
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
build:test-optimization --@io_bazel_rules_go//go/private/orchestrion:enabled=true
test:test-optimization --remote_download_minimal
test:test-optimization --remote_download_regex=.*test[.]outputs.*
test:test-optimization --zip_undeclared_test_outputs
# Optional for local experiments when module_path is not checked in.
common:test-optimization --repo_env=GO_MODULE_PATH
```

The required keys mirror the public sync metadata environment contract used by
the bootstrap. Runtime-specific overrides such as `GO_MODULE_PATH` are
optional and should be used only when the checked-in sync configuration cannot
carry the module path. Keeping extra values as `--repo_env` is safe for the
test action cache because they affect repository/module resolution, not the
test sandbox.

Do not add `FETCH_SALT` to the normal config. Use it only in a separate,
explicit force-refresh command such as
`bazel sync --config=test-optimization --only=<repo> --repo_env=FETCH_SALT="$(date +%s)"` when rollout
owners intentionally need fresh backend metadata.

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
same config, and that the test config includes
`--remote_download_minimal --remote_download_regex=.*test[.]outputs.*` and
`--zip_undeclared_test_outputs` when remote outputs may otherwise stay
remote-only. Pass the matching BEP files to doctor/uploader with repeatable
`--bep-json=<path>` plus `--freshness-source=bep`,
`--freshness-mode=required`, `--artifact-source=bep`, and
`--artifact-staging-dir=<temp-dir>` so zipped
undeclared outputs are staged from BEP before local discovery. If BEP points at
remote-only HTTP/HTTPS `outputs.zip` carriers, add
`--remote-artifacts=download` or `required`; bytestream/CAS/custom-auth
providers also need `--bep-artifact-downloader=<path>`.

## Doctor And Uploader Targets

Add one doctor and one uploader target per workspace. Root is acceptable for a
small repository. In a monorepo, use a lightweight package such as
`//tools/test_optimization` so these commands do not analyze unrelated root
wiring:

```bzl
# tools/test_optimization/BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

dd_test_optimization_targets(
    name = "test_optimization",
    sync_repo_name = "test_optimization_data_<service_key>",
    expected_targets = [
        "//path/to/pilot:go_default_test",
    ],
    uploader_kwargs = {
        "fail_on_error": True,
    },
)
```

Only put targets in `expected_targets` when they are real runtime test targets.
Do not expect payloads from `.build_test` controls or analysis/build-only
targets.

## Local Wrapper Pattern

For monorepos, avoid changing every BUILD file to load public macros directly.
Use one central wrapper:

- A shared repo-local policy helper applies Docker defaults, tags, shards,
  flaky policy, exec constraints, and registry behavior.
- The existing public wrapper calls that helper with `dd_topt_go_test`.
- That central wrapper sets `orchestrion_mode = "test_optimization"`,
  Orchestrion pin files, and `topt_data`.
- The wrapper rejects explicit per-target `topt_data` and
  `orchestrion_pin_files` overrides when those values must stay consistent
  across the repository.

The central wrapper loads `@test_optimization_data//:export.bzl`. This is safe
in config-gated onboarding because the disabled repository keeps the same
public labels and returns before metadata requests. Omitting
`--config=test-optimization` makes `dd_topt_go_test` emit the normal public
`go_test` shape; BUILD callsites do not select another macro.

The wrapper should always pass stable Orchestrion pin files when tests are not
at the repo root:

```bzl
orchestrion_mode = "test_optimization",
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

### Large WORKSPACE Monorepo Wrapper Shape

For a large WORKSPACE monorepo, use this guide's monorepo path and keep the
Test Optimization policy in the repository's existing central Go wrapper. That
wrapper should call the public Go macro with the repository's internal raw rule
as `go_test_rule`, the aggregate service data, and the standard Go `testing`
Orchestrion mode:

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", _rto_dd_topt_go_test = "dd_topt_go_test")
load("@test_optimization_data_go//:aggregate.bzl", "topt_data_by_service")
load("//path/to/repo/go:raw_go_test.bzl", _repo_raw_go_test = "go_test")

def dd_go_test(name, topt_service, **kwargs):
    _rto_dd_topt_go_test(
        name = name,
        go_test_rule = _repo_raw_go_test,
        orchestrion_mode = "test_optimization",
        orchestrion_pin_files = [
            "//:go.mod",
            "//:go.sum",
        ],
        topt_data = topt_data_by_service,
        topt_service = topt_service,
        **kwargs
    )
```

The repository-local wrapper should own and reject caller overrides for
`go_test_rule`, `orchestrion_pin_files`, and `topt_data`, so individual BUILD
files cannot drift away from the centrally validated Test Optimization setup.
Declare pilot services in the repository's Test Optimization metadata file, and
keep the expected runtime targets for doctor/uploader validation in the
repository's lightweight Test Optimization BUILD package. Use
`orchestrion_mode = "general"` only for explicit compatibility validation, not
for the normal Test Optimization onboarding path.

## Pilot Selection

Start with a small service or package scope without changing test callsites:

- Route the existing central wrapper through `dd_topt_go_test`.
- Select the initial capable services or packages in repository-owned central
  policy, not with a per-target Test Optimization attribute.
- Keep target names stable.
- Keep ordinary test attributes unchanged.
- Keep an ordinary control target and run it without the named config.
- Keep `.build_test` controls out of the doctor `expected_targets` list because
  they build the target but do not emit runtime payloads.
- Add one intentionally flaky runtime control only if the repository needs to
  prove flaky policy behavior.

After the pilot is green, expand service by service. Do not use a pilot-only
wrapper design that cannot scale to the rest of the repository.
