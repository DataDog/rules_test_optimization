<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# Bzlmod Java Onboarding

Use this path when the consumer repository uses `MODULE.bazel`.

## Dependency Wiring

Add core and Java companion blocks from the release's `INSTALL.md`, with
the same archive URL and SHA256. Replace the placeholders below and match the
module versions to the release. For older releases without bundle assets or
development commits, use the Git alternative in `docs/Installation_Reference.md`.

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.4.0")
archive_override(
    module_name = "datadog-rules-test-optimization",
    urls = ["<release-archive-url>"],
    sha256 = "<release-archive-sha256>",
    strip_prefix = "<archive-prefix>",
)

bazel_dep(name = "datadog-rules-test-optimization-java", version = "1.4.0")
archive_override(
    module_name = "datadog-rules-test-optimization-java",
    urls = ["<release-archive-url>"],
    sha256 = "<release-archive-sha256>",
    strip_prefix = "<archive-prefix>/modules/java",
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
    stage_sources = True,
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
    stage_sources = True,
    topt_data = topt_data,
    agent_jar = "//tools/test_optimization:dd_java_agent",
)
```

The macro requires `agent_jar`, injects `-javaagent`, and owns the manifest and
payload-in-files environment variables. Do not duplicate that wiring in the
consumer test target.

Keep `stage_sources = True` in the onboarding path unless the repository has a
specific reason to opt out. It stages the target's direct `srcs` into test
runfiles so the Java tracer can populate `test.source.file`,
`test.source.start`, and `test.source.end`; without it, tests can still pass and
upload payloads while source location metadata is silently absent.
