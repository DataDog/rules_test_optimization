# Language Onboarding

This document is organized so each language owner can read one section and wire
their runtime without having to reconstruct the rest of the repository.

Terminology used here:

- Single-service: one Datadog service for the workspace or runtime slice
- Multi-service: one runtime owns multiple Datadog services in the same Bazel workspace
- Mixed-runtime monorepo: Go, Python, Java, NodeJS, .NET, or Ruby all coexist in one repo

Rule of thumb:

- Use one sync repo for single-service setups
- Use one multi-sync aggregator per runtime for multi-service setups
- In mixed-runtime monorepos, keep one sync repo or one multi-sync aggregator per runtime

Shared runtime contract for every language:

- Tests read the synced metadata through `DD_TEST_OPTIMIZATION_MANIFEST_FILE`
- Tests set `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES = "true"`
- Tests write payloads under `TEST_UNDECLARED_OUTPUTS_DIR/payloads/{tests,coverage}`
- The uploader runs later through `bazel run //:dd_upload_payloads`

Shared `.bazelrc` forwarding:

```text
common --repo_env=DD_API_KEY
common --repo_env=DD_SITE
```

Shared upload command:

```bash
bazel test //... || test_status=$?; test_status=${test_status:-0}
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads
exit $test_status
```

## Go

### Single-service

Recommended path: use the Go companion bootstrap for fresh single-service Go
workspaces.

```bzl
# MODULE.bazel
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/go",
)

bazel_dep(name = "rules_go", version = "0.59.0")
```

Bootstrap once:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service go-service \
  --runtime-version 1.24.0
```

The bootstrap writes `//tools/build:dd_go_test.bzl` and creates
`//:dd_upload_payloads` when it is missing.

```bzl
# package BUILD.bazel
load("@rules_go//go:def.bzl", "go_library")
load("//tools/build:dd_go_test.bzl", "dd_go_test")

go_library(
    name = "pkg_lib",
    srcs = ["*.go"],
)

dd_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],
)
```

If the workspace already has custom sync wiring, skip guided bootstrap and use
the manual `dd_topt_go_test(..., topt_data = ...)` path from `README.md`.

### Multi-service

Use the Go extension. This path is Go-only and materializes every configured
service with `runtime_name = "go"`.

```bzl
# MODULE.bazel
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/go",
)

bazel_dep(name = "rules_go", version = "0.59.0")

go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

go_topt.test_optimization_go(
    name = "test_optimization_data",
    services = ["go-service-a", "go-service-b"],
    runtime_version = "1.24.0",
)

use_repo(
    go_topt,
    "test_optimization_data",
    "test_optimization_data_go_service_a",
    "test_optimization_data_go_service_b",
)
```

```bzl
# package BUILD.bazel
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
    topt_service = "go_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_go_service_a",
        "@test_optimization_data//:test_optimization_context_go_service_b",
    ],
)
```

## Python

### Single-service

```bzl
# MODULE.bazel
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

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "py-service",
    runtime_name = "python",
    runtime_version = "3.12",
)

use_repo(topt, "test_optimization_data")
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bzl
# package BUILD.bazel
load("@rules_python//python:defs.bzl", "py_test")
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")

py_library(
    name = "pkg_lib",
    srcs = ["main.py"],
)

dd_topt_py_test(
    name = "pkg_py_test",
    srcs = ["main_test.py"],
    main = "main_test.py",
    deps = [":pkg_lib"],
    imports = ["example/python/pkg"],
    py_test_rule = py_test,
    topt_data = topt_data,
)
```

### Multi-service

Use the core multi-sync extension. All services in one call share the same
runtime metadata.

```bzl
# MODULE.bazel
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

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["py-service-a", "py-service-b"],
    runtime_name = "python",
    runtime_version = "3.12",
)

use_repo(
    topt,
    "test_optimization_data",
    "test_optimization_data_py_service_a",
    "test_optimization_data_py_service_b",
)
```

```bzl
# package BUILD.bazel
load("@rules_python//python:defs.bzl", "py_test")
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_py_test(
    name = "pkg_py_test",
    srcs = ["main_test.py"],
    main = "main_test.py",
    imports = ["example/python/pkg"],
    py_test_rule = py_test,
    topt_data = topt_data_by_service,
    topt_service = "py_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_py_service_a",
        "@test_optimization_data//:test_optimization_context_py_service_b",
    ],
)
```

## Java

### Single-service

```bzl
# MODULE.bazel
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

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "java-service",
    runtime_name = "java",
    runtime_version = "17",
)

use_repo(topt, "test_optimization_data")
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bzl
# package BUILD.bazel
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
load("@test_optimization_data//:export.bzl", "topt_data")

java_library(
    name = "pkg_lib",
    srcs = ["Hello.java"],
)

dd_topt_java_test(
    name = "pkg_java_test",
    srcs = ["HelloTest.java"],
    deps = [":pkg_lib"],
    test_class = "com.example.pkg.HelloTest",
    java_test_rule = java_test,
    topt_data = topt_data,
)
```

### Multi-service

```bzl
# MODULE.bazel
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

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["java-service-a", "java-service-b"],
    runtime_name = "java",
    runtime_version = "17",
)

use_repo(
    topt,
    "test_optimization_data",
    "test_optimization_data_java_service_a",
    "test_optimization_data_java_service_b",
)
```

```bzl
# package BUILD.bazel
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_java_test(
    name = "pkg_java_test",
    srcs = ["HelloTest.java"],
    test_class = "com.example.pkg.HelloTest",
    java_test_rule = java_test,
    topt_data = topt_data_by_service,
    topt_service = "java_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_java_service_a",
        "@test_optimization_data//:test_optimization_context_java_service_b",
    ],
)
```

## NodeJS

### Single-service

```bzl
# MODULE.bazel
bazel_dep(name = "aspect_rules_js", version = "3.0.0-rc5")
bazel_dep(name = "rules_nodejs", version = "6.7.3")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-nodejs", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-nodejs",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/nodejs",
)

node = use_extension("@rules_nodejs//nodejs:extensions.bzl", "node")
node.toolchain(node_version = "22.22.0")
use_repo(node, "nodejs", "nodejs_host", "nodejs_toolchains")
register_toolchains("@nodejs_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "nodejs-service",
    runtime_name = "nodejs",
    runtime_version = "22.22.0",
)

use_repo(topt, "test_optimization_data")
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bzl
# package BUILD.bazel
load("@aspect_rules_js//js:defs.bzl", "js_test")
load("@datadog-rules-test-optimization-nodejs//:topt_nodejs_test.bzl", "dd_topt_nodejs_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_nodejs_test(
    name = "pkg_nodejs_test",
    entry_point = "smoke_test.js",
    copy_data_to_bin = False,
    module_identifier = "apps/nodejs/pkg",
    nodejs_test_rule = js_test,
    topt_data = topt_data,
)
```

### Multi-service

```bzl
# MODULE.bazel
bazel_dep(name = "aspect_rules_js", version = "3.0.0-rc5")
bazel_dep(name = "rules_nodejs", version = "6.7.3")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-nodejs", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-nodejs",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/nodejs",
)

node = use_extension("@rules_nodejs//nodejs:extensions.bzl", "node")
node.toolchain(node_version = "22.22.0")
use_repo(node, "nodejs", "nodejs_host", "nodejs_toolchains")
register_toolchains("@nodejs_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["nodejs-service-a", "nodejs-service-b"],
    runtime_name = "nodejs",
    runtime_version = "22.22.0",
)

use_repo(
    topt,
    "test_optimization_data",
    "test_optimization_data_nodejs_service_a",
    "test_optimization_data_nodejs_service_b",
)
```

```bzl
# package BUILD.bazel
load("@aspect_rules_js//js:defs.bzl", "js_test")
load("@datadog-rules-test-optimization-nodejs//:topt_nodejs_test.bzl", "dd_topt_nodejs_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_nodejs_test(
    name = "pkg_nodejs_test",
    entry_point = "smoke_test.js",
    copy_data_to_bin = False,
    module_identifier = "apps/nodejs/pkg",
    nodejs_test_rule = js_test,
    topt_data = topt_data_by_service,
    topt_service = "nodejs_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_nodejs_service_a",
        "@test_optimization_data//:test_optimization_context_nodejs_service_b",
    ],
)
```

## .NET

Use a small adapter to map the Datadog macro's `env` argument to
`rules_dotnet`'s `envs` argument.

```bzl
# dotnet_test_adapter.bzl
load("@rules_dotnet//dotnet:defs.bzl", "csharp_test")

def dotnet_csharp_test_adapter(name, data = None, env = None, **kwargs):
    envs = dict(kwargs.pop("envs", {}))
    if env:
        envs.update(env)

    csharp_test(
        name = name,
        data = [] if data == None else data,
        envs = envs,
        **kwargs
    )
```

### Single-service

```bzl
# MODULE.bazel
bazel_dep(name = "rules_dotnet", version = "0.21.5")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-dotnet", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-dotnet",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/dotnet",
)

dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet")
dotnet.toolchain(
    name = "dotnet",
    dotnet_version = "8.0.100",
)
use_repo(dotnet, "dotnet_toolchains")
register_toolchains("@dotnet_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "dotnet-service",
    runtime_name = "dotnet",
    runtime_version = "8.0.100",
)

use_repo(topt, "test_optimization_data")
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bzl
# package BUILD.bazel
load("@datadog-rules-test-optimization-dotnet//:topt_dotnet_test.bzl", "dd_topt_dotnet_test")
load("@test_optimization_data//:export.bzl", "topt_data")
load(":dotnet_test_adapter.bzl", "dotnet_csharp_test_adapter")

dd_topt_dotnet_test(
    name = "pkg_dotnet_test",
    srcs = ["smoke_test.cs"],
    target_frameworks = ["net8.0"],
    module_identifier = "Company.Product.Package",
    dotnet_test_rule = dotnet_csharp_test_adapter,
    topt_data = topt_data,
)
```

### Multi-service

```bzl
# MODULE.bazel
bazel_dep(name = "rules_dotnet", version = "0.21.5")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-dotnet", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-dotnet",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/dotnet",
)

dotnet = use_extension("@rules_dotnet//dotnet:extensions.bzl", "dotnet")
dotnet.toolchain(
    name = "dotnet",
    dotnet_version = "8.0.100",
)
use_repo(dotnet, "dotnet_toolchains")
register_toolchains("@dotnet_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["dotnet-service-a", "dotnet-service-b"],
    runtime_name = "dotnet",
    runtime_version = "8.0.100",
)

use_repo(
    topt,
    "test_optimization_data",
    "test_optimization_data_dotnet_service_a",
    "test_optimization_data_dotnet_service_b",
)
```

```bzl
# package BUILD.bazel
load("@datadog-rules-test-optimization-dotnet//:topt_dotnet_test.bzl", "dd_topt_dotnet_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")
load(":dotnet_test_adapter.bzl", "dotnet_csharp_test_adapter")

dd_topt_dotnet_test(
    name = "pkg_dotnet_test",
    srcs = ["smoke_test.cs"],
    target_frameworks = ["net8.0"],
    module_identifier = "Company.Product.Package",
    dotnet_test_rule = dotnet_csharp_test_adapter,
    topt_data = topt_data_by_service,
    topt_service = "dotnet_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_dotnet_service_a",
        "@test_optimization_data//:test_optimization_context_dotnet_service_b",
    ],
)
```

## Ruby

### Single-service

```bzl
# MODULE.bazel
bazel_dep(name = "rules_ruby", version = "0.21.1")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-ruby", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-ruby",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/ruby",
)

ruby = use_extension("@rules_ruby//ruby:extensions.bzl", "ruby")
ruby.toolchain(
    name = "ruby",
    version = "3.3.9",
)
use_repo(ruby, "ruby", "ruby_toolchains")
register_toolchains("@ruby_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

topt.test_optimization_sync(
    name = "test_optimization_data",
    service = "ruby-service",
    runtime_name = "ruby",
    runtime_version = "3.3.9",
)

use_repo(topt, "test_optimization_data")
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bzl
# package BUILD.bazel
load("@rules_ruby//ruby:defs.bzl", "rb_test")
load("@datadog-rules-test-optimization-ruby//:topt_ruby_test.bzl", "dd_topt_ruby_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_ruby_test(
    name = "pkg_ruby_test",
    srcs = ["smoke_test.rb"],
    main = "smoke_test.rb",
    module_identifier = "apps/ruby/pkg",
    ruby_test_rule = rb_test,
    topt_data = topt_data,
)
```

### Multi-service

```bzl
# MODULE.bazel
bazel_dep(name = "rules_ruby", version = "0.21.1")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

bazel_dep(name = "datadog-rules-test-optimization-ruby", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-ruby",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/ruby",
)

ruby = use_extension("@rules_ruby//ruby:extensions.bzl", "ruby")
ruby.toolchain(
    name = "ruby",
    version = "3.3.9",
)
use_repo(ruby, "ruby", "ruby_toolchains")
register_toolchains("@ruby_toolchains//:all")

topt = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["ruby-service-a", "ruby-service-b"],
    runtime_name = "ruby",
    runtime_version = "3.3.9",
)

use_repo(
    topt,
    "test_optimization_data",
    "test_optimization_data_ruby_service_a",
    "test_optimization_data_ruby_service_b",
)
```

```bzl
# package BUILD.bazel
load("@rules_ruby//ruby:defs.bzl", "rb_test")
load("@datadog-rules-test-optimization-ruby//:topt_ruby_test.bzl", "dd_topt_ruby_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_ruby_test(
    name = "pkg_ruby_test",
    srcs = ["smoke_test.rb"],
    main = "smoke_test.rb",
    module_identifier = "apps/ruby/pkg",
    ruby_test_rule = rb_test,
    topt_data = topt_data_by_service,
    topt_service = "ruby_service_a",
)
```

```bzl
# root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_ruby_service_a",
        "@test_optimization_data//:test_optimization_context_ruby_service_b",
    ],
)
```
