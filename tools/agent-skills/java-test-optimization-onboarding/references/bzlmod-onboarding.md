<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Bzlmod Java Onboarding

Use this path when the consumer repository uses `MODULE.bazel`.

## Dependency Wiring

Add the core module and Java companion module. Until Bazel Central Registry
publication exists, pin both with `git_override` to the same published commit:

```bzl
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
```

Do not add Java toolchains, test framework dependencies, or the dd-java-agent
through the Datadog rule. The consumer repository must provide them through its
normal dependency setup.

## Sync Metadata

Instantiate the sync extension with Java runtime metadata:

```bzl
topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "<datadog-service>",
    runtime_name = "java",
    runtime_version = "<java-version>",
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
        "//path/to:java_test",
    ],
)
```

## Test Targets

Use `dd_topt_java_test` directly when the repository does not already wrap
Java tests:

```bzl
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_java_test(
    name = "pkg_java_test",
    srcs = ["SampleTest.java"],
    deps = [":pkg_lib"],
    test_class = "com.example.pkg.SampleTest",
    topt_data = topt_data,
    agent_jar = "//tools/test_optimization:dd_java_agent",
)
```

For repositories with an existing Java/JUnit wrapper, pass it as
`java_test_rule`:

```bzl
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
load("@test_optimization_data//:export.bzl", "topt_data")
load("//tools/build:java_test.bzl", "repo_java_test")

dd_topt_java_test(
    name = "pkg_java_test",
    srcs = ["SampleTest.java"],
    deps = [":pkg_lib"],
    test_class = "com.example.pkg.SampleTest",
    java_test_rule = repo_java_test,
    topt_data = topt_data,
    agent_jar = "//tools/test_optimization:dd_java_agent",
)
```

The macro requires `agent_jar`, injects `-javaagent`, and owns the manifest and
payload-in-files environment variables. Do not duplicate that wiring in the
consumer test target.
