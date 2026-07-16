<!--
Unless explicitly stated otherwise all files in this repository are licensed under
the Apache 2.0 License.

This product includes software developed at Datadog
(https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.
-->

# WORKSPACE Java Onboarding

Use this path when the consumer repository disables Bzlmod or still relies on
`WORKSPACE`.

## Inspect Before Editing

Collect these facts first:

- Existing `rules_java` repository name, commonly `rules_java` but often
  remapped in monorepos.
- Existing Java language/runtime version and registered toolchains.
- Existing Maven/artifact repository name and lockfile ownership.
- Existing Java/JUnit wrapper macro, if any.
- Existing dd-java-agent target, filegroup, `http_file`, `maven_install`
  artifact, or local build path.
- Service name and Java runtime version for sync metadata.
- Runtime test targets that should emit payloads.
- Build-only controls that should not be listed as expected payload targets.
- Whether fetching this rules repository needs SSH git or authenticated archive
  access.
- A lightweight package for doctor/uploader targets, usually
  `//tools/test_optimization` in monorepos.

## Dependency Wiring

Declare the core repository first:

```bzl
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

git_repository(
    name = "datadog-rules-test-optimization",
    commit = "<published-main-commit>",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
)
```

For private/internal repositories, prefer SSH git fetch unless the Bazel
environment has authenticated archive access:

```bzl
git_repository(
    name = "datadog-rules-test-optimization",
    commit = "<published-main-commit>",
    remote = "ssh://git@github.com/DataDog/rules_test_optimization.git",
)
```

An unauthenticated codeload archive can return `404` for a private repository
even when the commit exists.

Declare `rules_java` using the consumer repository's normal mirror and
toolchain policy. Then use the public Datadog Java WORKSPACE helper:

```bzl
load("@datadog-rules-test-optimization//tools/java:workspace_repositories.bzl", "datadog_java_test_optimization_workspace_repositories")

datadog_java_test_optimization_workspace_repositories(
    rto_commit = "<published-main-commit>",
    rules_java_repo_name = "rules_java",
)
```

The helper declares only `datadog-rules-test-optimization-java`. It does not
declare `rules_java`, Java toolchains, test framework dependencies, Maven
repositories, or the dd-java-agent artifact.

Use archive mode when the consumer fetch policy requires mirrored Datadog
archives:

```bzl
datadog_java_test_optimization_workspace_repositories(
    rto_commit = "",
    datadog_fetch = "archive",
    rules_java_repo_name = "rules_java",
    rto_archive_url = "<mirror-url>",
    rto_archive_sha256 = "<archive-sha256>",
    rto_archive_prefix = "rules_test_optimization-<commit-sha>",
)
```

## Java Toolchains, Dependencies, And Agent

Keep Java setup in the consumer repository. The Datadog rule needs a label that
points at the dd-java-agent JAR:

```bzl
load("@rules_jvm_external//:defs.bzl", "artifact")

filegroup(
    name = "dd_java_agent",
    srcs = [artifact("com.datadoghq:dd-java-agent")],
    visibility = ["//visibility:public"],
)
```

Repositories may instead use `http_file`, a generated `genrule`, or a local
filegroup for development builds. Whatever source is chosen, pass that label to
`agent_jar`. Do not also add your own `-javaagent` flag at the same callsite;
`dd_topt_java_test` injects it.

## Sync, Doctor, And Uploader

Instantiate sync with Java metadata:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")

test_optimization_sync(
    name = "test_optimization_data",
    service = "<datadog-service>",
    runtime_name = "java",
    runtime_version = "<java-version>",
)
```

Add one logical doctor/uploader pair. Prefer a lightweight package in monorepos:

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

Direct Java test usage:

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

Repository-owned Java wrapper usage:

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

The repository wrapper must preserve `env`, `jvm_flags`, `data`, `tags`, and
visibility passed by `dd_topt_java_test`, and must execute a real Java test
process. Keep repository-specific feature flags, scheduling, flaky-test policy,
or framework selection in the wrapper layer.

Keep `stage_sources = True` in the onboarding path unless the repository has a
specific reason to opt out. It stages the target's direct `srcs` into test
runfiles so the Java tracer can populate `test.source.file`,
`test.source.start`, and `test.source.end`; without it, tests can still pass and
upload payloads while source location metadata is silently absent.
