# Examples

This folder shows concise usage patterns for single-service and multi-service setups. These are snippets meant to be copied into your repo; they are not runnable here.

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

BUILD.bazel:

```bzl
load("@rules_go//go:def.bzl", "go_test")
load("@datadog-rules-test-optimization//tools:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    topt_data = topt_data,        # single-service dict
    go_test_rule = go_test,
)
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

BUILD.bazel — Option A (explicit selection):

```bzl
load("@rules_go//go:def.bzl", "go_test")
load("@datadog-rules-test-optimization//tools:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    topt_data = topt_data_by_service["go_service"],  # sanitized key
    go_test_rule = go_test,
)
```

BUILD.bazel — Option B (mapping + key):

```bzl
load("@rules_go//go:def.bzl", "go_test")
load("@datadog-rules-test-optimization//tools:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    topt_data = topt_data_by_service,
    topt_service = "go_service",                 # or raw "go-service"
    go_test_rule = go_test,
)
```

Per-module filegroup (aggregator):

```bzl
# Select a single module for a specific service
filegroup(
  name = "dd_mod_core_go",
  srcs = ["@test_optimization_data//:module_go_service_core"],
)
```
