# Migration Guide: Go Companion Split

This guide covers migration from the pre-split Go macro path to the companion
module layout.

## What changed

- Removed: `@datadog-rules-test-optimization//tools/go:topt_go_test.bzl`
- New: `@datadog-rules-test-optimization-go//:topt_go_test.bzl`
- Core module (`datadog-rules-test-optimization`) remains runtime-agnostic.
- Go-specific orchestration now lives in `datadog-rules-test-optimization-go`.

## Bzlmod migration

In `MODULE.bazel`:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
bazel_dep(name = "rules_go", version = "0.59.0")
```

Update loads in Go BUILD files:

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
```

If developing locally with overrides:

```bzl
local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = "/absolute/path/to/datadog-rules-test-optimization",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-go",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/go",
)
```

## WORKSPACE migration (legacy mode)

WORKSPACE users can still load the Go macro from the repository source tree:

```bzl
# With: git_repository(name = "datadog_rules_test_optimization", ...)
load("@datadog_rules_test_optimization//modules/go:topt_go_test.bzl", "dd_topt_go_test")
```

Core sync/uploader loads remain:

```bzl
load("@datadog_rules_test_optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")
load("@datadog_rules_test_optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")
```

Make sure `rules_go` is configured in your workspace.

## Validation checklist

- Replace all stale loads that reference `//tools/go:*`.
- Run core tests:
  - `./bazelw test //tools/...`
- Run Go companion tests:
  - `cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../..`
- Build examples:
  - `./bazelw build //examples/...`
- Run integration harness:
  - Linux/macOS: `tools/tests/integration/run_mock_server_tests.sh`
  - Windows: `tools/tests/integration/run_mock_server_tests.ps1`
- Run hermetic smoke (mirror CI flags):
  - `./bazelw test //tools/... --spawn_strategy=sandboxed --strategy=TestRunner=sandboxed --sandbox_default_allow_network=false --modify_execution_info=TestRunner=+block-network --test_env=TZ=UTC --test_env=LANG=C --test_env=LC_ALL=C --enable_runfiles`
  - `cd modules/go && ../../bazelw test //... --override_module=datadog-rules-test-optimization=../.. --spawn_strategy=sandboxed --strategy=TestRunner=sandboxed --sandbox_default_allow_network=false --modify_execution_info=TestRunner=+block-network --test_env=TZ=UTC --test_env=LANG=C --test_env=LC_ALL=C --enable_runfiles`
