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
bazel_dep(name = "datadog-rules-test-optimization", version = "1.2.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-python", version = "1.2.0")
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
    enabled_by_env = True,
    runtime_module_path = "<python-module-path>",
    runtime_name = "python",
    runtime_version = "<python-version>",
    service = "<datadog-service>",
)

use_repo(topt, "test_optimization_data")
```

Enable this sync only through the named Bazel config:

```text
common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1
```

Do not add a `rules_go` Orchestrion flag to a Python-only consumer.
Set `runtime_module_path` to the stable Python package/module prefix used by
backend module groups. This is the checked-in default; `PYTHON_MODULE_PATH`
remains an explicit higher-precedence override. Keep that environment variable
unset, or standardize it in repository configuration, when selection must be
deterministic across CI and developer machines.

### Managed manifest variant

When a consumer-owned command discovers exact Go/Python targets, use the
separate aggregate API instead of static service declarations:

```bzl
topt_manifest = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_manifest_sync.bzl",
    "test_optimization_manifest_sync_extension",
)
topt_manifest.test_optimization_manifest_sync(
    name = "test_optimization_data",
)
use_repo(topt_manifest, "test_optimization_data")
```

The command supplies runtime module paths and service names through its private
temporary manifest. Do not add that handoff to `.bazelrc` or ask users to
maintain it. The central Python wrapper selects
`topt_data_by_target.get(<full-label>)` and keeps its raw path when absent.

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

For manifest-managed wiring, replace the static expected list with:

```bzl
dd_test_optimization_targets(
    name = "test_optimization",
    context_data = [
        "@test_optimization_data//:test_optimization_context",
    ],
    expected_targets_file = "@test_optimization_data//:expected_targets",
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

Omit `module_identifier` when inference or the
`runtime_module_path` + Bazel package fallback identifies the test. Inferred
misses use the canonical full bundle. When synchronized metadata exposes module
groups, an explicit `module_identifier` or `module_label_override` must match
one or analysis fails; when no groups exist, the canonical full bundle remains
valid.
