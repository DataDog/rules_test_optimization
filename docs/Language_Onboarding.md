# Language Onboarding

This document is organized so each language owner can read one section and wire
their runtime without having to reconstruct the rest of the repository.

Terminology used here:

- Single-service: one Datadog service for the workspace or runtime slice
- Multi-service: one runtime owns multiple Datadog services in the same Bazel workspace
- Mixed-runtime monorepo: Go, Python, Java, NodeJS, .NET, or Ruby all coexist in one repo

Rule of thumb:

- Use one sync repo for single-service setups
- Use one multi-sync aggregator per runtime for multi-service setups
- In mixed-runtime monorepos, keep one sync repo per runtime/service slice
- Use multi-sync aggregators only for multiple services of the same runtime

Shared runtime contract for every language:

- Tests read the synced metadata through `DD_TEST_OPTIMIZATION_MANIFEST_FILE`
- Tests set `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES = "true"`
- Tests write payloads under `TEST_UNDECLARED_OUTPUTS_DIR/payloads/{tests,coverage}`
- Tests write JSON payload files. Do not introduce runtime proxies or raw
  msgpack-only handoff paths.
- Run `//:dd_test_optimization_doctor` after tests to validate JSON payloads,
  Bazel target metadata, Git metadata, and invalid Go payload selection before
  upload.
- Run uploader dry-run enrichment validation when rolling out a new repository
  or debugging missing tags: it validates the final enriched body without
  uploading or deleting local payload files.
- The uploader runs later through `bazel run //:dd_upload_payloads`
- Mixed-runtime uploader wiring must bundle every relevant
  `:test_optimization_context` target and let the uploader choose the matching
  `context.json` per payload
- `DD_TEST_OPTIMIZATION_CONTEXT_JSON` remains a legacy explicit override, not
  the recommended mixed-runtime wiring path

Shared `.bazelrc` forwarding. Prefer the generated block from
`dd_topt_go_bootstrap --print-bazelrc-snippet` or
`dd_topt_go_bootstrap --write-bazelrc` for Go workspaces:

```text
common:test-optimization --repo_env=DD_API_KEY
common:test-optimization --repo_env=DD_SITE
common:test-optimization --repo_env=FETCH_SALT
common:test-optimization --repo_env=DD_GIT_REPOSITORY_URL
common:test-optimization --repo_env=DD_GIT_BRANCH
common:test-optimization --repo_env=DD_GIT_TAG
common:test-optimization --repo_env=DD_GIT_COMMIT_SHA
common:test-optimization --repo_env=DD_PR_NUMBER
test:test-optimization --remote_download_outputs=all
```

Pass `DD_GIT_*` only through `--repo_env`. Never forward it as test
environment data because that makes Git metadata part of the test action cache
key. For Go/Orchestrion, do not put `DD_TEST_OPTIMIZATION_AGENT_URL` or
`DD_TEST_OPTIMIZATION_AGENTLESS_URL` in `--test_env`; the uploader reads upload
endpoints at `bazel run` time.

Shared upload command:

```bash
bazel test --config=test-optimization //... || test_status=$?; test_status=${test_status:-0}
bazel run --config=test-optimization //:dd_test_optimization_doctor || doctor_status=$?; doctor_status=${doctor_status:-0}
if [ "$doctor_status" -ne 0 ]; then
  if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
  exit "$doctor_status"
fi
bazel run --config=test-optimization //:dd_upload_payloads -- --dry-run --validate-enrichment || dry_run_status=$?; dry_run_status=${dry_run_status:-0}
if [ "$dry_run_status" -ne 0 ]; then
  if [ "$test_status" -ne 0 ]; then exit "$test_status"; fi
  exit "$dry_run_status"
fi
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //:dd_upload_payloads
upload_status=$?
if [ "$test_status" -ne 0 ]; then
  exit "$test_status"
fi
exit "$upload_status"
```

## Go

### Single-service

Recommended path: use the Go companion bootstrap for fresh single-service Go
workspaces.

```bzl
# MODULE.bazel
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/go",
)

bazel_dep(name = "rules_go", version = "0.60.0")
```

Bootstrap once:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service go-service \
  --runtime-version 1.25.0 \
  --dd-trace-go-version v2.9.0-dev.0.20260416093245-194346a71c51 \
  --write-bazelrc
```

The default Go module sync mode is `targeted`, so bootstrap does not run
`go mod tidy` unless you pass `--go-mod-sync=tidy`. In large repositories, pass
`--go-binary=/path/to/go` when bootstrap must use the same pinned Go SDK as
Bazel. The path must point to a `go` or `go.exe` executable and must not include
arguments.

The bootstrap writes `//tools/build:dd_go_test.bzl` and creates
`//:dd_test_optimization_doctor` plus `//:dd_upload_payloads` when they are
missing. With `--write-bazelrc`, it also writes the managed
`test-optimization` config used by the command examples above.

`--dd-trace-go-version` is optional. If omitted, the default is
`v2.9.0-dev.0.20260416093245-194346a71c51`. It accepts a tag, pseudo-version,
branch, or commit SHA. Bootstrap resolves that input to the exact tracer
versions Bazel will use, repins the local Go module to match, and later builds
fail fast if the workspace setting and local pins no longer match.

```bzl
# package BUILD.bazel
load("@rules_go//go:def.bzl", "go_library")
load("//tools/build:dd_go_test.bzl", "dd_go_test")

go_library(
    name = "pkg_lib",
    srcs = ["*.go"],
)

dd_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],
)
```

Because the generated `dd_go_test` wrapper forwards `**kwargs`, it also
supports `stage_sources = True` directly:

```bzl
dd_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],
    stage_sources = True,
)
```

`stage_sources` stages only the target's direct `srcs` and direct
`embedsrcs`. When enabled, the wrapper defaults `rundir` to `.` only if you
did not already set `rundir` yourself.

If the workspace already has custom sync wiring, skip guided bootstrap and use
the manual `dd_topt_go_test(..., topt_data = ...)` path from `README.md`.
In WORKSPACE mode, that manual path still uses the Go companion as its own
repository and loads the macro from
`@datadog-rules-test-optimization-go//:topt_go_test.bzl`. The companion must
resolve an Orchestrion-enabled `rules_go` fork, so the WORKSPACE wiring for
that fork needs `repo_mapping = {"@rules_go": "@io_bazel_rules_go"}` or the
equivalent mapping used by the consumer's repository layout. That fork also
needs to expose the public `go_orchestrion_tool_repo(...)` helper, preserve the
`//go/private/orchestrion:*` targets that the companion transition uses, and
keep the default tool-repo name `rules_go_orchestrion_tool`. When Go tests live
below the module root, pass the module-root pin files through
`orchestrion_pin_files` or inject them from a repo-local wrapper.

For WORKSPACE monorepos, prefer bootstrap `--workspace-mode` to generate the
generic local scaffolding. It can write the root doctor/uploader targets,
`.bazelrc` block, Orchestrion pin files, and a split wrapper template while
leaving `WORKSPACE` placement under repository control. The generated wrapper
template keeps repo-specific policy in a local helper and exposes separate
plain and optimized wrapper functions, so large repositories do not have to
rediscover that split during onboarding.

### Large WORKSPACE monorepos

Use this flow when the repository already has substantial `WORKSPACE` wiring,
custom Go wrappers, checked-in Gazelle output, or a non-default `rules_go`
repository name. The goal is to add Test Optimization without replacing the
repository's existing build policy.

Start by identifying the existing Go shape:

- The Bazel repository name used for `rules_go`, for example
  `io_bazel_rules_go`.
- The Go module path that owns the pilot tests.
- The Go SDK version used by the repository.
- The smallest set of runtime test targets that should emit payloads.
- Any plain or build-only control targets that should keep using the existing
  wrapper path.

Wire the public WORKSPACE helper instead of copying patch directories or
declaring `patches = [...]`. Use `rules_go_variant = "base"` for normal
repositories. Use `rules_go_variant = "complete"` only when the repository
needs the declared extended monorepo compatibility variant.

```bzl
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

git_repository(
    name = "datadog-rules-test-optimization",
    commit = "<rules-test-optimization-commit>",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
)

load(
    "@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl",
    "datadog_go_test_optimization_workspace_repositories",
)

datadog_go_test_optimization_workspace_repositories(
    rto_commit = "<rules-test-optimization-commit>",
    datadog_fetch = "git",
    rules_go_repo_name = "<existing_rules_go_repo_name>",
    rules_go_fetch = "archive",
    rules_go_variant = "complete",
    rto_archive_url = "https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/<rules-test-optimization-commit>",
    rto_archive_sha256 = "<sha256-for-that-archive>",
    rto_archive_prefix = "rules_test_optimization-<rules-test-optimization-commit>",
)

load("@<existing_rules_go_repo_name>//go:deps.bzl", "go_orchestrion_tool_repo")

go_orchestrion_tool_repo(
    version = "v1.9.0",
    dd_trace_go_version = "v2.9.0-dev.0.20260416093245-194346a71c51",
)

load(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync",
)

test_optimization_sync(
    name = "test_optimization_data",
    service = "<datadog-service-name>",
    runtime_name = "go",
    runtime_version = "<go-sdk-version>",
    runtime_module_path = "<go-module-path>",
    require_git_metadata = True,
)
```

If the environment can fetch Git repositories reliably, use
`rules_go_fetch = "git"` and omit the archive attributes. If the environment
mirrors or blocks GitHub codeload archives, publish the same commit to a mirror
controlled by the consuming organization and point `rto_archive_url` at that
mirror.

`runtime_module_path` is preferred for checked-in configuration because it makes
module selection explicit and does not depend on operator shell state. If the
module path must stay environment-specific during local experiments, pass
`GO_MODULE_PATH` with `--repo_env` instead of `--test_env`.

Use bootstrap to write the local pieces that are safe to generate, but keep
`WORKSPACE` placement under repository review:

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

Use `--expected-target` only for targets that run instrumented test code and
therefore emit JSON payloads. Do not list `.build_test`, compile-only, or other
build-only controls as expected runtime targets; keep those under
`--control-target` or run them separately before the doctor.

The generated wrapper template should be adapted to the repository's existing
wrapper layer. Keep scheduling, tags, flaky policy, Docker defaults,
platform constraints, and other repository-specific behavior in the local
helper. The optimized wrapper should call `dd_topt_go_test`, pass
`topt_data`, and always provide module-root pin files:

```bzl
orchestrion_pin_files = [
    "//:go.mod",
    "//:go.sum",
    "//:orchestrion.tool.go",
    "//:orchestrion.yml",
]
```

Export the pin files from the root package if the repository's package layout
requires that for cross-package labels. Keep the plain wrapper path available
for controls and for tests that are not part of the rollout yet.

If the repository has checked-in `go_repository` declarations, run bootstrap
with `--check-go-repositories` and then use the repository-owned refresh command
to add or update the Orchestrion and tracer dependencies. Do not hand-edit large
generated dependency files unless that is already the repository's documented
maintenance path.

Validate in this order:

1. Run `bazel sync --config=test-optimization --only=test_optimization_data`
   with a fresh `FETCH_SALT` when metadata should be refetched.
2. Run plain and build-only controls first.
3. Run the instrumented targets in small batches, serially if disk or cache
   pressure is high.
4. Run `bazel run --config=test-optimization //:dd_test_optimization_doctor`.
5. Run
   `bazel run --config=test-optimization //:dd_upload_payloads -- --dry-run --validate-enrichment`.
6. Run the real uploader with `DD_API_KEY` and `DD_SITE` in the command
   environment, not in the test sandbox.

For remote execution or remote cache setups, keep
`test:test-optimization --remote_download_outputs=all` in the active `.bazelrc`
config. Without local undeclared outputs, the doctor and uploader cannot inspect
or enrich the payloads after `bazel test`.

If the doctor reports missing Git metadata, missing Bazel metadata,
`full_bundle_no_match`, or msgpack payloads, fix the sync, wrapper, tracer, or
uploader configuration. Do not work around those failures by adding `DD_GIT_*`
or upload endpoints to `--test_env`; that would make sandbox test actions
non-hermetic and can invalidate Bazel cache keys.

### Multi-service

Use the Go extension. This path is Go-only and materializes every configured
service with `runtime_name = "go"`.

```bzl
# MODULE.bazel
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/go",
)

bazel_dep(name = "rules_go", version = "0.60.0")

go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

go_topt.test_optimization_go(
    name = "test_optimization_data",
    services = ["go-service-a", "go-service-b"],
    runtime_version = "1.25.0",
)

use_repo(
    go_topt,
    "test_optimization_data",
    "test_optimization_data_go_service_a",
    "test_optimization_data_go_service_b",
)
```

```bzl
# package BUILD.bazel
load("@rules_go//go:def.bzl", "go_library")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

go_library(
    name = "pkg_lib",
    srcs = ["*.go"],
)

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],
    topt_data = topt_data_by_service,
    topt_service = "go_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = [
        "@test_optimization_data//:test_optimization_context_go_service_a",
        "@test_optimization_data//:test_optimization_context_go_service_b",
    ],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_go_service_a",
        "@test_optimization_data//:test_optimization_context_go_service_b",
    ],
)
```

## Python

### Single-service

```bzl
# MODULE.bazel
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-python", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-python",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/python",
)

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "py-service",
    runtime_name = "python",
    runtime_version = "3.12",
)

use_repo(topt, "test_optimization_data")
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = ["@test_optimization_data//:test_optimization_context"],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bzl
# package BUILD.bazel
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")

py_library(
    name = "pkg_lib",
    srcs = ["main.py"],
)

dd_topt_py_test(
    name = "pkg_py_test",
    srcs = ["main_test.py"],
    main = "main_test.py",
    deps = [":pkg_lib"],
    imports = ["example/python/pkg"],
    topt_data = topt_data,
)
```

The snippet above shows the custom-runner path. For pytest-based tests, you can
omit `main`; `dd_topt_py_test` now defaults to
`@rules_python//python:py_test`, runs the bundled pytest entry point, defaults
`args` to the Bazel package path, and sets `PYTEST_ADDOPTS=--ddtrace` unless
you already set it or opt out with `--no-ddtrace`.

### Multi-service

Use the core multi-sync extension. All services in one call share the same
runtime metadata.

```bzl
# MODULE.bazel
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-python", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-python",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/python",
)

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["py-service-a", "py-service-b"],
    runtime_name = "python",
    runtime_version = "3.12",
)

use_repo(
    topt,
    "test_optimization_data",
    "test_optimization_data_py_service_a",
    "test_optimization_data_py_service_b",
)
```

```bzl
# package BUILD.bazel
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_py_test(
    name = "pkg_py_test",
    srcs = ["main_test.py"],
    main = "main_test.py",
    imports = ["example/python/pkg"],
    topt_data = topt_data_by_service,
    topt_service = "py_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = [
        "@test_optimization_data//:test_optimization_context_py_service_a",
        "@test_optimization_data//:test_optimization_context_py_service_b",
    ],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_py_service_a",
        "@test_optimization_data//:test_optimization_context_py_service_b",
    ],
)
```

## Java

### Single-service

```bzl
# MODULE.bazel
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-java", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-java",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/java",
)

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "java-service",
    runtime_name = "java",
    runtime_version = "17",
)

use_repo(topt, "test_optimization_data")

# dd-java-agent JAR consumed by dd_topt_java_test's agent_jar.
http_file = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
http_file(
    name = "dd_java_agent",
    downloaded_file_path = "dd-java-agent.jar",
    urls = ["https://repo1.maven.org/maven2/com/datadoghq/dd-java-agent/1.60.0/dd-java-agent-1.60.0.jar"],
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = ["@test_optimization_data//:test_optimization_context"],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bzl
# package BUILD.bazel
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
load("@test_optimization_data//:export.bzl", "topt_data")

java_library(
    name = "pkg_lib",
    srcs = ["Hello.java"],
)

dd_topt_java_test(
    name = "pkg_java_test",
    srcs = ["HelloTest.java"],
    deps = [":pkg_lib"],
    test_class = "com.example.pkg.HelloTest",
    topt_data = topt_data,
    agent_jar = "@dd_java_agent//file",
)
```

### Multi-service

```bzl
# MODULE.bazel
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-java", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-java",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/java",
)

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["java-service-a", "java-service-b"],
    runtime_name = "java",
    runtime_version = "17",
)

use_repo(
    topt,
    "test_optimization_data",
    "test_optimization_data_java_service_a",
    "test_optimization_data_java_service_b",
)

# dd-java-agent JAR consumed by dd_topt_java_test's agent_jar.
http_file = use_repo_rule("@bazel_tools//tools/build_defs/repo:http.bzl", "http_file")
http_file(
    name = "dd_java_agent",
    downloaded_file_path = "dd-java-agent.jar",
    urls = ["https://repo1.maven.org/maven2/com/datadoghq/dd-java-agent/1.60.0/dd-java-agent-1.60.0.jar"],
)
```

```bzl
# package BUILD.bazel
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_java_test(
    name = "pkg_java_test",
    srcs = ["HelloTest.java"],
    test_class = "com.example.pkg.HelloTest",
    topt_data = topt_data_by_service,
    topt_service = "java_service_a",
    agent_jar = "@dd_java_agent//file",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = [
        "@test_optimization_data//:test_optimization_context_java_service_a",
        "@test_optimization_data//:test_optimization_context_java_service_b",
    ],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_java_service_a",
        "@test_optimization_data//:test_optimization_context_java_service_b",
    ],
)
```

## NodeJS

### Single-service

```bzl
# MODULE.bazel
bazel_dep(name = "aspect_rules_js", version = "3.0.0-rc5")
bazel_dep(name = "rules_nodejs", version = "6.7.3")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-nodejs", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-nodejs",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/nodejs",
)

node = use_extension("@rules_nodejs//nodejs:extensions.bzl", "node")
node.toolchain(node_version = "22.22.0")
use_repo(node, "nodejs", "nodejs_host", "nodejs_toolchains")
register_toolchains("@nodejs_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "nodejs-service",
    runtime_name = "nodejs",
    runtime_version = "22.22.0",
)

use_repo(topt, "test_optimization_data")
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = ["@test_optimization_data//:test_optimization_context"],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bzl
# package BUILD.bazel
load("@aspect_rules_js//js:defs.bzl", "js_test")
load("@datadog-rules-test-optimization-nodejs//:topt_nodejs_test.bzl", "dd_topt_nodejs_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_nodejs_test(
    name = "pkg_nodejs_test",
    entry_point = "smoke_test.js",
    copy_data_to_bin = False,
    module_identifier = "apps/nodejs/pkg",
    nodejs_test_rule = js_test,
    topt_data = topt_data,
)
```

### Multi-service

```bzl
# MODULE.bazel
bazel_dep(name = "aspect_rules_js", version = "3.0.0-rc5")
bazel_dep(name = "rules_nodejs", version = "6.7.3")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-nodejs", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-nodejs",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/nodejs",
)

node = use_extension("@rules_nodejs//nodejs:extensions.bzl", "node")
node.toolchain(node_version = "22.22.0")
use_repo(node, "nodejs", "nodejs_host", "nodejs_toolchains")
register_toolchains("@nodejs_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["nodejs-service-a", "nodejs-service-b"],
    runtime_name = "nodejs",
    runtime_version = "22.22.0",
)

use_repo(
    topt,
    "test_optimization_data",
    "test_optimization_data_nodejs_service_a",
    "test_optimization_data_nodejs_service_b",
)
```

```bzl
# package BUILD.bazel
load("@aspect_rules_js//js:defs.bzl", "js_test")
load("@datadog-rules-test-optimization-nodejs//:topt_nodejs_test.bzl", "dd_topt_nodejs_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_nodejs_test(
    name = "pkg_nodejs_test",
    entry_point = "smoke_test.js",
    copy_data_to_bin = False,
    module_identifier = "apps/nodejs/pkg",
    nodejs_test_rule = js_test,
    topt_data = topt_data_by_service,
    topt_service = "nodejs_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = [
        "@test_optimization_data//:test_optimization_context_nodejs_service_a",
        "@test_optimization_data//:test_optimization_context_nodejs_service_b",
    ],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_nodejs_service_a",
        "@test_optimization_data//:test_optimization_context_nodejs_service_b",
    ],
)
```

## .NET

Use a small adapter to map the Datadog macro's `env` argument to
`rules_dotnet`'s `envs` argument.

```bzl
# dotnet_test_adapter.bzl
load("@rules_dotnet//dotnet:defs.bzl", "csharp_test")

def dotnet_csharp_test_adapter(name, data = None, env = None, **kwargs):
    envs = dict(kwargs.pop("envs", {}))
    if env:
        envs.update(env)

    csharp_test(
        name = name,
        data = [] if data == None else data,
        envs = envs,
        **kwargs
    )
```

### Single-service

```bzl
# MODULE.bazel
bazel_dep(name = "rules_dotnet", version = "0.21.5")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-dotnet", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-dotnet",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/dotnet",
)

dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet")
dotnet.toolchain(
    name = "dotnet",
    dotnet_version = "8.0.100",
)
use_repo(dotnet, "dotnet_toolchains")
register_toolchains("@dotnet_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "dotnet-service",
    runtime_name = "dotnet",
    runtime_version = "8.0.100",
)

use_repo(topt, "test_optimization_data")
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = ["@test_optimization_data//:test_optimization_context"],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bzl
# package BUILD.bazel
load("@datadog-rules-test-optimization-dotnet//:topt_dotnet_test.bzl", "dd_topt_dotnet_test")
load("@test_optimization_data//:export.bzl", "topt_data")
load(":dotnet_test_adapter.bzl", "dotnet_csharp_test_adapter")

dd_topt_dotnet_test(
    name = "pkg_dotnet_test",
    srcs = ["smoke_test.cs"],
    target_frameworks = ["net8.0"],
    module_identifier = "Company.Product.Package",
    dotnet_test_rule = dotnet_csharp_test_adapter,
    topt_data = topt_data,
)
```

### Multi-service

```bzl
# MODULE.bazel
bazel_dep(name = "rules_dotnet", version = "0.21.5")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-dotnet", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-dotnet",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/dotnet",
)

dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet")
dotnet.toolchain(
    name = "dotnet",
    dotnet_version = "8.0.100",
)
use_repo(dotnet, "dotnet_toolchains")
register_toolchains("@dotnet_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["dotnet-service-a", "dotnet-service-b"],
    runtime_name = "dotnet",
    runtime_version = "8.0.100",
)

use_repo(
    topt,
    "test_optimization_data",
    "test_optimization_data_dotnet_service_a",
    "test_optimization_data_dotnet_service_b",
)
```

```bzl
# package BUILD.bazel
load("@datadog-rules-test-optimization-dotnet//:topt_dotnet_test.bzl", "dd_topt_dotnet_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")
load(":dotnet_test_adapter.bzl", "dotnet_csharp_test_adapter")

dd_topt_dotnet_test(
    name = "pkg_dotnet_test",
    srcs = ["smoke_test.cs"],
    target_frameworks = ["net8.0"],
    module_identifier = "Company.Product.Package",
    dotnet_test_rule = dotnet_csharp_test_adapter,
    topt_data = topt_data_by_service,
    topt_service = "dotnet_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = [
        "@test_optimization_data//:test_optimization_context_dotnet_service_a",
        "@test_optimization_data//:test_optimization_context_dotnet_service_b",
    ],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_dotnet_service_a",
        "@test_optimization_data//:test_optimization_context_dotnet_service_b",
    ],
)
```

## Ruby

### Single-service

```bzl
# MODULE.bazel
bazel_dep(name = "rules_ruby", version = "0.21.1")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-ruby", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-ruby",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/ruby",
)

ruby = use_extension("@rules_ruby//ruby:extensions.bzl", "ruby")
ruby.toolchain(
    name = "ruby",
    version = "3.3.9",
)
use_repo(ruby, "ruby", "ruby_toolchains")
register_toolchains("@ruby_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "ruby-service",
    runtime_name = "ruby",
    runtime_version = "3.3.9",
)

use_repo(topt, "test_optimization_data")
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = ["@test_optimization_data//:test_optimization_context"],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bzl
# package BUILD.bazel
load("@rules_ruby//ruby:defs.bzl", "rb_test")
load("@datadog-rules-test-optimization-ruby//:topt_ruby_test.bzl", "dd_topt_ruby_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_ruby_test(
    name = "pkg_ruby_test",
    srcs = ["smoke_test.rb"],
    main = "smoke_test.rb",
    module_identifier = "apps/ruby/pkg",
    ruby_test_rule = rb_test,
    topt_data = topt_data,
)
```

### Multi-service

```bzl
# MODULE.bazel
bazel_dep(name = "rules_ruby", version = "0.21.1")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-ruby", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-ruby",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/ruby",
)

ruby = use_extension("@rules_ruby//ruby:extensions.bzl", "ruby")
ruby.toolchain(
    name = "ruby",
    version = "3.3.9",
)
use_repo(ruby, "ruby", "ruby_toolchains")
register_toolchains("@ruby_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["ruby-service-a", "ruby-service-b"],
    runtime_name = "ruby",
    runtime_version = "3.3.9",
)

use_repo(
    topt,
    "test_optimization_data",
    "test_optimization_data_ruby_service_a",
    "test_optimization_data_ruby_service_b",
)
```

```bzl
# package BUILD.bazel
load("@rules_ruby//ruby:defs.bzl", "rb_test")
load("@datadog-rules-test-optimization-ruby//:topt_ruby_test.bzl", "dd_topt_ruby_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_ruby_test(
    name = "pkg_ruby_test",
    srcs = ["smoke_test.rb"],
    main = "smoke_test.rb",
    module_identifier = "apps/ruby/pkg",
    ruby_test_rule = rb_test,
    topt_data = topt_data_by_service,
    topt_service = "ruby_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = [
        "@test_optimization_data//:test_optimization_context_ruby_service_a",
        "@test_optimization_data//:test_optimization_context_ruby_service_b",
    ],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_ruby_service_a",
        "@test_optimization_data//:test_optimization_context_ruby_service_b",
    ],
)
```
