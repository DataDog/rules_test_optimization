<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Bzlmod Python Onboarding

Use this path when the consumer repository uses `MODULE.bazel`.

## Dependency Wiring

Add the core module and Python companion module. Until Bazel Central Registry
publication exists, pin both with `git_override` to the same published commit:

```bzl
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
```

Do not add `pytest` or `ddtrace` through the Datadog rule. The consumer Python
dependency repository must provide both packages through its normal lockfile.

## Sync Metadata

Instantiate the sync extension with Python runtime metadata:

```bzl
topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "<datadog-service>",
    runtime_name = "python",
    runtime_version = "<python-version>",
)

use_repo(topt, "test_optimization_data")
```

## Doctor And Uploader Targets

Add one logical doctor/uploader pair. In monorepos, prefer a lightweight package
such as `//tools/test_optimization`; root labels are still fine for small repos:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_targets.bzl", "dd_test_optimization_targets")

dd_test_optimization_targets(
    name = "test_optimization",
    sync_repo_name = "test_optimization_data",
    expected_targets = [
        "//path/to:python_test",
    ],
)
```

## Test Targets

For repositories without an existing pytest wrapper, use managed pytest mode:

```bzl
load("@python_deps//:requirements.bzl", "requirement")
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_py_test(
    name = "pkg_py_test",
    srcs = glob(["test_*.py"]),
    deps = [
        requirement("ddtrace"),
        requirement("pytest"),
    ],
    imports = ["example/python/pkg"],
    topt_data = topt_data,
)
```

For repositories with an existing wrapper, use `consumer_runner`; see
[consumer-runner.md](consumer-runner.md).
