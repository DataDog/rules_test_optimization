# Examples

This folder shows concise usage patterns for single-service and multi-service setups. These are snippets meant to be copied into your repo; they are not runnable here.

Tip: commands use `bazel` for portability in consumer repos. In this
repository, use `./bazelw` for local development convenience.

## Single-service (classic)

MODULE.bazel:

```bzl
test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

test_optimization_sync.test_optimization_sync(name = "test_optimization_data")
use_repo(test_optimization_sync, "test_optimization_data")
```

BUILD.bazel (inference via embed):

```bzl
load("@rules_go//go:def.bzl", "go_library", "go_test")
load("@datadog-rules-test-optimization//tools:topt_go_test.bzl", "dd_topt_go_test")
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
load("@datadog-rules-test-optimization//tools:test_optimization_uploader.bzl", "dd_payload_uploader")

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
```

## Multi-service (aggregator)

MODULE.bazel:

```bzl
topt_multi = use_extension(
    "@datadog-rules-test-optimization//tools:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt_multi.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["go-service", "ruby-service"],
)

use_repo(
    topt_multi,
    "test_optimization_data",                 # aggregator repo
    "test_optimization_data_go_service",      # per-service repos
    "test_optimization_data_ruby_service",
)
```

BUILD.bazel — Option A (explicit selection, inference via embed):

```bzl
load("@rules_go//go:def.bzl", "go_library", "go_test")
load("@datadog-rules-test-optimization//tools:topt_go_test.bzl", "dd_topt_go_test")
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
load("@datadog-rules-test-optimization//tools:topt_go_test.bzl", "dd_topt_go_test")
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
    go_test_rule = go_test,
)
```

Notes on importpath inference:
- Preferred: inference via `embed` above (reads rules_go provider).
- Optional: explicit `importpath` on `go_test` takes precedence when set.
- Fallback: if neither is available, the macro computes `<module_path>/<bazel package>` using the exported `topt_data["go"]["module_path"]` and the current Bazel package path.

Per-module filegroup (aggregator):

```bzl
# Select a single module for a specific service
filegroup(
  name = "dd_mod_core_go",
  srcs = ["@test_optimization_data//:module_go_service_core"],
)
```
