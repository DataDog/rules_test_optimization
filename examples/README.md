# Examples

This folder shows concise usage patterns for single-service and multi-service setups. These snippets are meant to be copied into your repo; in this repository we also keep them buildable (`//examples/...`) as a regression guard.

Tip: commands use `bazel` for portability in consumer repos. In this
repository, use `./bazelw` for local development convenience.

## Prerequisites

- Until BCR publication, install with `git_override(...)` as shown in the root `README.md`.
  If you are consuming a published release, keep the `bazel_dep(...)` lines and
  omit override blocks.
- Add module dependencies before `use_extension(...)`:
  - `bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")`
  - `bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")` for Go macro usage
  - `bazel_dep(name = "datadog-rules-test-optimization-python", version = "1.0.0")` for Python macro usage
  - `bazel_dep(name = "datadog-rules-test-optimization-java", version = "1.0.0")` for Java macro usage
  - `bazel_dep(name = "datadog-rules-test-optimization-nodejs", version = "1.0.0")` for NodeJS macro usage
  - `bazel_dep(name = "datadog-rules-test-optimization-dotnet", version = "1.0.0")` for .NET macro usage
  - `bazel_dep(name = "datadog-rules-test-optimization-ruby", version = "1.0.0")` for Ruby macro usage
  - `bazel_dep(name = "rules_go", ...)` for Go examples shown below
- For NodeJS/.NET/Ruby examples shown below, also pin reference rulesets and register toolchains:
  - `bazel_dep(name = "aspect_rules_js", version = "3.0.0-rc5")`
  - `bazel_dep(name = "rules_nodejs", version = "6.7.3")`
  - `bazel_dep(name = "rules_dotnet", version = "0.21.5")`
  - `bazel_dep(name = "rules_ruby", version = "0.21.1")`
  - `node = use_extension("@rules_nodejs//nodejs:extensions.bzl", "node"); node.toolchain(node_version = "22.22.0"); use_repo(node, "nodejs", "nodejs_host", "nodejs_toolchains"); register_toolchains("@nodejs_toolchains//:all")`
  - `dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet"); dotnet.toolchain(name = "dotnet", dotnet_version = "8.0.100"); use_repo(dotnet, "dotnet_toolchains"); register_toolchains("@dotnet_toolchains//:all")`
  - `ruby = use_extension("@rules_ruby//ruby:extensions.bzl", "ruby"); ruby.toolchain(name = "ruby", version = "3.3.9"); use_repo(ruby, "ruby", "ruby_toolchains"); register_toolchains("@ruby_toolchains//:all")`
- Configure Go toolchains/SDK in your repo if you build Go targets.
- Provide sync credentials via environment and forward them to repository rules:
  - shell/CI secret: `DD_API_KEY`
  - `.bazelrc`: `common --repo_env=DD_API_KEY` (and optionally `common --repo_env=DD_SITE`)

## Single-service (classic)

MODULE.bazel:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-python", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-java", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-nodejs", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-dotnet", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-ruby", version = "1.0.0")

bazel_dep(name = "rules_go", version = "0.60.0")  # or your repo-selected version
bazel_dep(name = "aspect_rules_js", version = "3.0.0-rc5")
bazel_dep(name = "rules_nodejs", version = "6.7.3")
bazel_dep(name = "rules_dotnet", version = "0.21.5")
bazel_dep(name = "rules_ruby", version = "0.21.1")

git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/go",
)
git_override(
    module_name = "datadog-rules-test-optimization-python",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/python",
)
git_override(
    module_name = "datadog-rules-test-optimization-java",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/java",
)
git_override(
    module_name = "datadog-rules-test-optimization-nodejs",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/nodejs",
)
git_override(
    module_name = "datadog-rules-test-optimization-dotnet",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/dotnet",
)
git_override(
    module_name = "datadog-rules-test-optimization-ruby",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/ruby",
)

node = use_extension("@rules_nodejs//nodejs:extensions.bzl", "node")
node.toolchain(node_version = "22.22.0")
use_repo(node, "nodejs", "nodejs_host", "nodejs_toolchains")
register_toolchains("@nodejs_toolchains//:all")

dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet")
dotnet.toolchain(
    name = "dotnet",
    dotnet_version = "8.0.100",
)
use_repo(dotnet, "dotnet_toolchains")
register_toolchains("@dotnet_toolchains//:all")

ruby = use_extension("@rules_ruby//ruby:extensions.bzl", "ruby")
ruby.toolchain(
    name = "ruby",
    version = "3.3.9",
)
use_repo(ruby, "ruby", "ruby_toolchains")
register_toolchains("@ruby_toolchains//:all")
```

This mirrors the buildable `examples/single_service` workspace in this
repository: one Datadog service shared across several runtime-specific test
macros, with Go using the bootstrap-managed extension. If your team owns only
Python, Java, NodeJS, .NET, or Ruby, the simpler runtime-specific setup is in
[`docs/Language_Onboarding.md`](../docs/Language_Onboarding.md).

Bootstrap once after adding the module prerequisites:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service go-service \
  --runtime-version 1.25.0 \
  --dd-trace-go-version v2.9.0-dev.0.20260409102143-ddd4e03ab47d
```

`--dd-trace-go-version` is optional. If omitted, bootstrap uses the default
`v2.9.0-dev.0.20260409102143-ddd4e03ab47d`. It accepts a tag, pseudo-version, branch, or commit SHA. Bootstrap
resolves that input to exact versions and repins the local Go module to match
what Bazel will use.

BUILD.bazel (generated wrapper path, inference via embed):

```bzl
load("@rules_go//go:def.bzl", "go_library")
load("//tools/build:dd_go_test.bzl", "dd_go_test")

go_library(
    name = "pkg_lib",
    srcs = ["*.go"],
)

dd_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],      # importpath inferred via rules_go provider
)
```

BUILD.bazel (Python companion):

```bzl
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_py_test(
    name = "pkg_py_test",
    srcs = ["test_*.py"],
    deps = [":pkg_lib"],
    imports = ["example/python/pkg"],
    topt_data = topt_data,
    py_test_rule = py_test,
)
```

BUILD.bazel (Java companion):

```bzl
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_java_test(
    name = "pkg_java_test",
    srcs = ["*Test.java"],
    deps = [":pkg_lib"],
    test_class = "com.example.pkg.SampleTest",
    topt_data = topt_data,
    java_test_rule = java_test,
)
```

BUILD.bazel (NodeJS companion):

```bzl
load("@aspect_rules_js//js:defs.bzl", "js_test")
load("@datadog-rules-test-optimization-nodejs//:topt_nodejs_test.bzl", "dd_topt_nodejs_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_nodejs_test(
    name = "pkg_nodejs_test",
    entry_point = "smoke_test.js",
    copy_data_to_bin = False,  # Datadog payload data comes from external repos.
    module_identifier = "apps/nodejs/pkg",
    topt_data = topt_data,
    nodejs_test_rule = js_test,
)
```

BUILD.bazel (.NET companion):

```bzl
load("@datadog-rules-test-optimization-dotnet//:topt_dotnet_test.bzl", "dd_topt_dotnet_test")
load("@test_optimization_data//:export.bzl", "topt_data")
load(":dotnet_test_adapter.bzl", "dotnet_csharp_test_adapter")

dd_topt_dotnet_test(
    name = "pkg_dotnet_test",
    srcs = ["smoke_test.cs"],
    target_frameworks = ["net8.0"],
    module_identifier = "Company.Product.Package",
    topt_data = topt_data,
    dotnet_test_rule = dotnet_csharp_test_adapter,
)
```

`dotnet_test_adapter.bzl` wraps `@rules_dotnet//dotnet:defs.bzl` `csharp_test` and maps the Datadog macro's `env` to `csharp_test(envs = ...)`.

BUILD.bazel (Ruby companion):

```bzl
load("@rules_ruby//ruby:defs.bzl", "rb_test")
load("@datadog-rules-test-optimization-ruby//:topt_ruby_test.bzl", "dd_topt_ruby_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_ruby_test(
    name = "pkg_ruby_test",
    srcs = ["smoke_test.rb"],
    main = "smoke_test.rb",
    module_identifier = "apps/ruby/pkg",
    topt_data = topt_data,
    ruby_test_rule = rb_test,
)
```

Root BUILD.bazel (ONE uploader per workspace):

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

Use the single-context form above only for single-runtime workspaces. Mixed-
runtime workspaces must add one `:test_optimization_context` label per
runtime/service repo so uploader enrichment stays aligned with each payload.

Running tests and uploading payloads:

```bash
# Run tests (preserving exit code) then upload payloads
bazel test //... || test_status=$?; test_status=${test_status:-0}
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads
exit $test_status

# RBE users: download outputs so uploader can discover payload files
bazel test //... --remote_download_outputs=all || test_status=$?; test_status=${test_status:-0}
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads
exit $test_status
```

```powershell
# Run tests (preserving exit code) then upload payloads
bazel test //...
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
# Set once per shell session before first run:
# $env:DD_API_KEY = "<your-api-key>"
# $env:DD_SITE = "datadoghq.com"
bazel run //:dd_upload_payloads
exit $testStatus

# RBE users: download outputs so uploader can discover payload files
bazel test //... --remote_download_outputs=all
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
bazel run //:dd_upload_payloads
exit $testStatus
```

Notes:
- The sequence above intentionally preserves the test exit code.
- Uploader failures are still reported in uploader logs/output; monitor those in CI.
- Example `runtests.sh` scripts default `DD_SITE` to `datadoghq.com` when not set.
- Windows-friendly wrappers are provided as `examples/*/runtests.ps1` and use
  native PowerShell + Bazel (no Git Bash dependency).

Dry-run mode for CI/debugging:
- Set `RUNTESTS_DRY_RUN=1` when invoking `examples/*/runtests.sh` to print
  the commands that would run without executing Bazel test/upload operations.
- PowerShell wrappers honor the same `RUNTESTS_DRY_RUN=1` environment variable.

## Multi-service (aggregator, Go-only example)

MODULE.bazel:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
bazel_dep(name = "rules_go", version = "0.60.0")  # or your repo-selected version

git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/go",
)

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
    "test_optimization_data",                 # aggregator repo
    "test_optimization_data_go_service_a",    # per-service repos
    "test_optimization_data_go_service_b",
)
```

Bootstrap once after adding the Go module files:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --go-module-dir src/go-project \
  --dd-trace-go-version v2.9.0-dev.0.20260409102143-ddd4e03ab47d
```

As in the single-service flow, `--dd-trace-go-version` is optional and defaults
to `v2.9.0-dev.0.20260409102143-ddd4e03ab47d`. It may resolve to one shared tracer version or to separate exact
versions for the traced Go modules when you pass a branch or commit SHA.

This multi-service path stays on the lower-level/manual API. Guided bootstrap is
only for fresh single-service Go workspaces.

Repository roles in multi-service mode:
- `@test_optimization_data//...` (aggregator) exposes combined per-service labels
  such as `:test_optimization_files_<service>` and
  `:module_<service>_<module_label>`.
- `@test_optimization_data_<service>//...` (per-service repos) are useful when
  loading a service-specific export dictionary directly.
- This Go extension form is for multi-service Go only. Every configured service
  is materialized as `runtime_name = "go"`.

For Python/Java/NodeJS/.NET/Ruby multi-service onboarding, use the core
`test_optimization_multi_sync_extension` and the per-language guide in
[`docs/Language_Onboarding.md`](../docs/Language_Onboarding.md). This `examples/multi_service` workspace is
intentionally scoped to Go.

BUILD.bazel — Option A (explicit selection, inference via embed):

```bzl
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
    topt_data = topt_data_by_service["go_service_a"],  # sanitized key
)
```

Mixed-runtime monorepo pattern:

```bzl
# Keep runtime-specific sync repos separate. This remains the recommended path
# when not every service is Go and not every service needs Orchestrion.
topt_go = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)
topt_go.test_optimization_sync(
    name = "test_optimization_data_go",
    service = "go-service",
    runtime_name = "go",
    runtime_version = "1.25.0",
)

topt_py = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)
topt_py.test_optimization_sync(
    name = "test_optimization_data_py",
    service = "py-service",
    runtime_name = "python",
    runtime_version = "3.12",
)

use_repo(topt_go, "test_optimization_data_go")
use_repo(topt_py, "test_optimization_data_py")
```

BUILD.bazel — Option B (mapping + key, inference via embed):

```bzl
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
    topt_service = "go_service_a",               # or raw "go-service-a"
    # If two services sanitize to the same key, use the deduped key (e.g. go_service_a_2).
)
```

Notes on importpath inference:
- Preferred: inference via `embed` above (reads rules_go provider).
- Optional: explicit `importpath` on `go_test` takes precedence when set.
- Fallback: if neither is available, the macro computes `<module_path>/<bazel package>` using the exported `topt_data["runtimes"]["go"]["module_path"]` and the current Bazel package path.

Per-module filegroup (aggregator):

```bzl
# Select a single module for a specific service
filegroup(
  name = "dd_mod_core_go",
  srcs = ["@test_optimization_data//:module_go_service_a_core"],
)
```

Root BUILD.bazel uploader (multi-service):

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
  name = "dd_upload_payloads",
  data = [
    "@test_optimization_data//:test_optimization_context_go_service_a",
    "@test_optimization_data//:test_optimization_context_go_service_b",
  ],
)
```

Mixed-runtime example rule:
- keep one sync repo per runtime/service
- keep one uploader at the workspace root
- add every matching context target to uploader `data`
- do not use `DD_TEST_OPTIMIZATION_CONTEXT_JSON` as the normal mixed-runtime path
