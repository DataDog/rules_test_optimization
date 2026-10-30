<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# WORKSPACE Go Onboarding

Use this reference for repositories that still rely on `WORKSPACE`, including
large monorepos with custom Go wrappers.

## Inspect Before Editing

Collect these facts from the consumer repository:

- How `rules_go` is declared. It must be upstream `rules_go` named
  `io_bazel_rules_go`: the instrumented SDK repositories that `go_wrap_sdk`
  writes load it under that name.
- Existing Bazel command wrapper, for example `bzl`, `bazelw`, or raw `bazel`.
- Existing Go SDK/toolchain version and the `go_register_toolchains(...)` call.
- Existing Go test wrapper macros and where repo policy lives.
- Existing `.bazelrc` config names used in CI.
- Pilot service name and Go module path.
- Sync repository name for the service. Use a stable, descriptive name when the
  repository will eventually instrument multiple services.
- Pilot runtime test targets that should emit payloads.
- Ordinary control targets used to prove config-disabled behavior.
- Build-only or `.build_test` targets that should not be expected to emit
  Datadog payloads.
- Whether the repository still has a 1.x Datadog Go setup. See
  [Migrating A 1.x Setup](#migrating-a-1x-setup).

Do not replace the repository's scheduling, Docker, tag, flaky, or shard policy.
Keep that logic in a repo-local wrapper layer and only swap the raw Go test
implementation for the Test Optimization path where needed.

## Dependency Wiring

Use the public WORKSPACE helpers. Pin a commit reachable from `origin/main`.
For archive fetches, generate or copy the complete archive tuple from the
published onboarding pins; do not invent a SHA or point at a feature-branch
commit.

From this repository, generate published pins with:

```bash
./bazelw run //tools/dev:print_go_onboarding_pins -- \
  --commit "$(git rev-parse origin/main)" \
  --verify-main-reachable
```

It prints `RTO_COMMIT`, `RTO_REMOTE`, `RTO_ARCHIVE_URL`, `RTO_ARCHIVE_SHA256`,
`RTO_ARCHIVE_PREFIX`, and `RTO_ARCHIVE_TYPE`. See
[`docs/Installation_Reference.md`](../../../../docs/Installation_Reference.md#generate-published-go-pins).

Declare the repositories in this order:

```bzl
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

# Upstream rules_go first, named io_bazel_rules_go.
http_archive(
    name = "io_bazel_rules_go",
    sha256 = "<sha256 from the rules_go release notes>",
    urls = ["https://github.com/bazel-contrib/rules_go/releases/download/v0.60.0/rules_go-v0.60.0.zip"],
)

git_repository(
    name = "datadog-rules-test-optimization",
    commit = "<published-main-commit>",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
)

load("@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl", "datadog_go_test_optimization_workspace_repositories")

datadog_go_test_optimization_workspace_repositories(
    rto_commit = "<published-main-commit>",
)

load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")

go_rules_dependencies()

go_register_toolchains(version = "<go-version>")

load("@datadog-rules-test-optimization-go//:topt_go_ddtest_repository.bzl", "topt_go_ddtest_workspace_repositories")

topt_go_ddtest_workspace_repositories(go_version = "<go-version>")
```

`rules_go` `0.60.0` or newer is supported; CI covers `0.60.0` through `0.65.0`,
and `0.65.0` requires Go `1.26`. Keep the repository's existing
`go_rules_dependencies()` and `go_register_toolchains(...)` calls.

`datadog_go_test_optimization_workspace_repositories(...)` declares only the
Go companion repository, and fails when `rules_go` is not declared yet. Keep
its `rules_go_repo_name` at the default `io_bazel_rules_go`.

`topt_go_ddtest_workspace_repositories(...)` declares the ddtest repositories
and registers the instrumented toolchains. Call it after
`go_rules_dependencies()`. It takes the same arguments as the Bzlmod `sdk` tag
except `go_mod`: `go_version`, `base_sdk_roots`, `exec_platforms`,
`experiments`, and `panic_hook`. To instrument the SDK that
`go_register_toolchains(...)` registered instead of downloading one, map the
exec platform to its root:

```bzl
topt_go_ddtest_workspace_repositories(
    base_sdk_roots = {"linux_amd64": "@go_sdk//:ROOT"},
    exec_platforms = ["linux_amd64"],
)
```

Without `base_sdk_roots`, exec platforms download the official SDK of
`go_version`. The default `exec_platforms` is all six ddtest platforms, and
Bazel fetches only the SDKs of the exec platforms it selects. Only instrumented
tests select these toolchains, so other builds fetch neither the instrumented
SDKs nor Mini, ddtest's Test Optimization runtime. `ddtest instrument` needs no
host `go` binary. See
[ddtest's Bazel guide](https://github.com/DataDog/ddtest/blob/main/ddto/docs/bazel.md)
for the ddtest side.

Add this line to the named config used by test, doctor, and uploader:

```text
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
```

`--config=test-optimization` is the only user-facing switch. No global Go flag
is required.

For a managed monorepo, declare one aggregate repository after the Rule
dependency:

```bzl
load(
    "@datadog-rules-test-optimization//tools/core:test_optimization_manifest_sync.bzl",
    "test_optimization_manifest_sync",
)

test_optimization_manifest_sync(
    name = "test_optimization_data",
)
```

Do not pass a service list. The repository-owned managed command expands exact
labels, derives service/runtime contexts, and supplies the private temporary
manifest to its child Bazel processes. The manifest handoff is not an ordinary
WORKSPACE or `.bazelrc` setting. Existing static WORKSPACE helpers remain the
right path when the consumer has no managed discovery command.

If the repository fetches the Go companion from an archive, set it explicitly.
Declare the core repository from the same archive:

```bzl
datadog_go_test_optimization_workspace_repositories(
    rto_commit = "<published-main-commit>",
    datadog_fetch = "archive",
    rto_archive_url = "<archive-url>",
    rto_archive_sha256 = "<archive-sha256>",
    rto_archive_prefix = "<archive-prefix>",
    rto_archive_type = "tar.gz",
)
```

## Optional Bootstrap Scaffolding

The Go bootstrap can generate WORKSPACE-oriented scaffolding without editing
`WORKSPACE` itself. This is useful for large repositories because it produces
the same doctor, uploader, wrapper template, `.bazelrc`, and validation script
patterns that the public docs expect.

The bootstrap command target must be resolvable before you can run it:

- If the consumer already resolves `@datadog-rules-test-optimization-go`, run
  the command from the consumer repository with its normal Bazel entrypoint.
- If the consumer does not resolve that repository yet, first place the
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

The printed WORKSPACE snippet follows the order shown above. It shows upstream
`rules_go` as a commented `http_archive` placeholder with the release URL,
calls `go_register_toolchains(...)` and
`topt_go_ddtest_workspace_repositories(go_version = ...)` with
`--runtime-version`, and ends with the sync repository.

Then use write modes only for files the repository should actually own:

```bash
<bazel-command> run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --workspace /absolute/path/to/consumer \
  --workspace-mode \
  --service <datadog-service> \
  --runtime-version <go-version> \
  --sync-repo-name test_optimization_data_<service_key> \
  --bazel-command <bazel-command> \
  --bazel-config test-optimization \
  --expected-target //path/to/pilot:go_default_test \
  --control-target //path/to/plain:go_default_test \
  --doctor-target //tools/test_optimization:dd_test_optimization_doctor \
  --upload-target //tools/test_optimization:dd_upload_payloads \
  --write-bazelrc \
  --write-wrapper-template \
  --write-validation-script
```

Replace `<bazel-command>` with the repository's real entrypoint, such as `bzl`
or `./bazelw` when running from the consumer repository. If running from a
separate `rules_test_optimization` checkout, use that checkout's Bazel wrapper
with the same target label and keep `--workspace` pointed at the consumer root.
Review generated wrapper templates before adopting them: the repository must
keep its own scheduling, Docker, tag, flaky, and registry policy in local
wrapper code.

If the repository needs archive-mode WORKSPACE wiring, add
`--datadog-fetch archive`, `--rto-archive-url`, `--rto-archive-sha256`,
`--rto-archive-prefix`, and `--rto-archive-type` to the snippet command.

Review any generated WORKSPACE sync snippet before committing it. If the Go
module path is known and stable, pass `module_path = "<go-module-path>"` to
`dd_topt_go_workspace_sync_repositories(...)`. That keeps checked-in
configuration self-contained and avoids relying on `GO_MODULE_PATH` in normal
CI.

## Sync Setup

Declare the Test Optimization sync repository through the reusable Go companion
helper, after the ddtest repositories:

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_workspace.bzl", "dd_topt_go_workspace_sync_repositories")

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

If the repository already defines a Go version constant for Bazel toolchains,
reuse that constant for `runtime_version` and `go_version` instead of
hardcoding another copy. Prefer checked-in `module_path` when the service
module path is stable. Use `GO_MODULE_PATH` through `--repo_env` only for local
experiments or repository layouts where the module path must stay
environment-specific.

Use the actual sync repository name everywhere later. If the sync rule is named
`test_optimization_data_worker`, the labels are:

```text
@test_optimization_data_worker//:export.bzl
@test_optimization_data_worker//:test_optimization_context
```

The Go module needs no Datadog requirements. If tests use Mini's Go API, they
must use the packages of `@topt_go_ddtest_mini`, not a `go_repository` copy of
`github.com/DataDog/ddtest/ddto`; analysis fails with
`would link Mini's packages twice` otherwise.

## Migrating A 1.x Setup

A 1.x WORKSPACE setup used a `rules_go` fork and extra Go helper calls. To move
it to `ddtest instrument`:

- Declare upstream `rules_go` as `io_bazel_rules_go` in place of the 1.x
  `rules_go` fork.
- Call `datadog_go_test_optimization_workspace_repositories(...)` with only the
  arguments shown above.
- Remove the 1.x Go instrumentation helper calls and add
  `topt_go_ddtest_workspace_repositories(...)` after `go_rules_dependencies()`.
- Remove the 1.x instrumentation attributes from wrappers and callsites.
  `dd_topt_go_test` fails analysis with a migration message while they remain.
- The `# BEGIN Datadog Go Pin Files` blocks that 1.x wrote in BUILD files are
  harmless. You may delete them.

`--print-workspace-snippet` prints the current wiring to compare against. The
[migration note](../../../../CHANGELOG.md#unreleased) lists the files,
`go.mod` requirements, and metadata keys that changed.

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
- That central wrapper sets `topt_data`.
- The wrapper rejects explicit per-target `topt_data` overrides when that value
  must stay consistent across the repository.

The central wrapper loads `@test_optimization_data//:export.bzl`. This is safe
in config-gated onboarding because the disabled repository keeps the same
public labels and returns before metadata requests. Omitting
`--config=test-optimization` makes `dd_topt_go_test` emit the normal public
`go_test` shape; BUILD callsites do not select another macro.

### Large WORKSPACE Monorepo Wrapper Shape

For a large WORKSPACE monorepo, use this guide's monorepo path and keep the
Test Optimization policy in the repository's existing central Go wrapper. That
wrapper should call the public Go macro with the repository's internal raw rule
as `go_test_rule` and the aggregate service data:

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", _rto_dd_topt_go_test = "dd_topt_go_test")
load("@test_optimization_data_go//:aggregate.bzl", "topt_data_by_service")
load("//path/to/repo/go:raw_go_test.bzl", _repo_raw_go_test = "go_test")

def dd_go_test(name, topt_service, **kwargs):
    _rto_dd_topt_go_test(
        name = name,
        go_test_rule = _repo_raw_go_test,
        topt_data = topt_data_by_service,
        topt_service = topt_service,
        **kwargs
    )
```

The repository-local wrapper should own and reject caller overrides for
`go_test_rule` and `topt_data`, so individual BUILD files cannot drift away
from the centrally validated Test Optimization setup. Declare pilot services in
the repository's Test Optimization metadata file, and keep the expected runtime
targets for doctor/uploader validation in the repository's lightweight Test
Optimization BUILD package.

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
