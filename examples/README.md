# Examples

This folder shows concise usage patterns for single-service and multi-service setups. These snippets are meant to be copied into your repo; in this repository we also keep them buildable (`//examples/...`) as a regression guard.

Tip: commands use `bazel` for portability in consumer repos. In this
repository, use `./bazelw` for local development convenience.

## Prerequisites

- Add module dependencies before `use_extension(...)`:
  - `bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")`
- `bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")` for Go macro usage
  - `bazel_dep(name = "rules_go", ...)` for Go examples shown below
- Configure Go toolchains/SDK in your repo if you build Go targets.
- Provide sync credentials via environment and forward them to repository rules:
  - shell/CI secret: `DD_API_KEY`
  - `.bazelrc`: `common --repo_env=DD_API_KEY` (and optionally `common --repo_env=DD_SITE`)

## Single-service (classic)

MODULE.bazel:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
bazel_dep(name = "rules_go", version = "0.59.0")  # or your repo-selected version

test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

test_optimization_sync.test_optimization_sync(name = "test_optimization_data")
use_repo(test_optimization_sync, "test_optimization_data")
```

BUILD.bazel (inference via embed):

```bzl
load("@rules_go//go:def.bzl", "go_library", "go_test")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

go_library(
    name = "pkg_lib",
    srcs = ["*.go"],
)

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],      # importpath inferred via rules_go provider
    topt_data = topt_data,     # single-service dict
    go_test_rule = go_test,
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
# Assumes DD_API_KEY and DD_SITE are already set in environment
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

## Multi-service (aggregator)

MODULE.bazel:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
bazel_dep(name = "rules_go", version = "0.59.0")  # or your repo-selected version

topt_multi = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt_multi.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["go-service", "ruby-service"],
    runtime_name = "go",
    runtime_version = "1.24",
)

use_repo(
    topt_multi,
    "test_optimization_data",                 # aggregator repo
    "test_optimization_data_go_service",      # per-service repos
    "test_optimization_data_ruby_service",
)
```

Repository roles in multi-service mode:
- `@test_optimization_data//...` (aggregator) exposes combined per-service labels
  such as `:test_optimization_files_<service>` and
  `:module_<service>_<module_label>`.
- `@test_optimization_data_<service>//...` (per-service repos) are useful when
  loading a service-specific export dictionary directly.

BUILD.bazel — Option A (explicit selection, inference via embed):

```bzl
load("@rules_go//go:def.bzl", "go_library", "go_test")
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
    topt_data = topt_data_by_service["go_service"],  # sanitized key
    go_test_rule = go_test,
)
```

BUILD.bazel — Option B (mapping + key, inference via embed):

```bzl
load("@rules_go//go:def.bzl", "go_library", "go_test")
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
    topt_service = "go_service",                 # or raw "go-service"
    # If two services sanitize to the same key, use the deduped key (e.g. go_service_2).
    go_test_rule = go_test,
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
  srcs = ["@test_optimization_data//:module_go_service_core"],
)
```
