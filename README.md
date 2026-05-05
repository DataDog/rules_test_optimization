# Datadog Test Optimization Bazel Module Extension

This repository provides Bazel integrations that fetch Datadog Test Optimization metadata during module/repository resolution and materialize JSON files for use in your build. It also generates public filegroups so consumers can depend on stable labels instead of wiring files manually.

> First release status: module metadata currently uses `1.0.0`, but Bazel Central Registry publication is still pending. Until BCR entries are published, install with `git_override` (Bzlmod) or commit-pinned `git_repository` / `http_archive` (WORKSPACE).

## Onboarding paths

Pick the path that matches your repository:

- **Per-language onboarding guide:** [`docs/Language_Onboarding.md`](docs/Language_Onboarding.md)
- **Bzlmod + core only (any language):** sync + uploader integration without language-specific macros
- **Bzlmod + Go companion:** `dd_topt_go_test` macro with importpath inference
- **Bzlmod + Python companion:** `dd_topt_py_test` macro with analysis-time selection
- **Bzlmod + Java companion:** `dd_topt_java_test` macro with analysis-time selection
- **Bzlmod + NodeJS companion:** `dd_topt_nodejs_test` macro with analysis-time selection
- **Bzlmod + .NET companion:** `dd_topt_dotnet_test` macro with analysis-time selection
- **Bzlmod + Ruby companion:** `dd_topt_ruby_test` macro with analysis-time selection
- **Bzlmod + multi-service monorepo:** one sync extension, per-service labels/exports
- **WORKSPACE mode:** fully supported for v1 when Bzlmod is disabled
- **Other languages:** use core sync/uploader now, or follow companion patterns for custom `dd_topt_<lang>_test` modules

## Maintainer note on the vendored rules_go split

The repository now publishes the Go integration as two complete `rules_go`
variants:

- generic Orchestrion-enabled base variant:
  `third_party/rules_go_orchestrion_base`
- complete Orchestrion-enabled variant with declared historical monorepo
  compatibility:
  `third_party/rules_go_orchestrion_complete`
- maintainer-only regression overlay used by variant smoke tests:
  `tools/tests/rules_go_variant_regressions`

The base/complete difference contract lives in:

- `third_party/rules_go_orchestrion_variants.json`
- `tools/dev/verify_rules_go_variants.py`

Maintainers can track each variant delta against upstream `rules_go` with:

- `third_party/rules_go_orchestrion_<variant>.METADATA.json`
- `third_party/rules_go_orchestrion_<variant>.CHANGED_FILES.md`
- `python3 tools/dev/diff_rules_go_fork.py --write-report`

## First-run checklist (all scenarios)

Use this checklist before your first CI rollout:

1. Keep the generated repo name as `test_optimization_data` (or consistently replace it in labels/commands if you choose another name).
2. Forward sync metadata environment variable names in `.bazelrc` under a named
   config, then use that config for test, doctor, and upload commands:
   - `common:test-optimization --repo_env=DD_API_KEY`
   - `common:test-optimization --repo_env=DD_SITE`
   - `common:test-optimization --repo_env=FETCH_SALT`
   - `common:test-optimization --repo_env=DD_GIT_REPOSITORY_URL`
   - `common:test-optimization --repo_env=DD_GIT_BRANCH`
   - `common:test-optimization --repo_env=DD_GIT_TAG`
   - `common:test-optimization --repo_env=DD_GIT_COMMIT_SHA`
   - `common:test-optimization --repo_env=DD_PR_NUMBER`
   - `test:test-optimization --remote_download_outputs=all`
   - `DD_GIT_*` must use `--repo_env`, never `--test_env`, so Git metadata
     does not become part of the test action cache key.
   - `DD_TEST_OPTIMIZATION_AGENT_URL` and
     `DD_TEST_OPTIMIZATION_AGENTLESS_URL` are not part of the Go/Orchestrion
     test sandbox. The uploader reads upload endpoints at `bazel run` time.
3. Create exactly one uploader target at workspace root:
   - `//:dd_upload_payloads` via `dd_payload_uploader(...)`
4. Create one doctor target at workspace root:
   - `//:dd_test_optimization_doctor` via `dd_test_optimization_doctor(...)`
5. Run tests, then doctor, then uploader, while preserving test exit code.
6. If using remote execution, keep `--remote_download_outputs=all` in the
   test config so the doctor and uploader can discover payload files locally
   after the test completes.

## Quickstart by scenario

### Bzlmod + core only (any language)

Use this when you do not need `dd_topt_go_test`:

```bzl
# MODULE.bazel
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)
test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
    service = "my-service",  # or set DD_SERVICE via --repo_env
)
use_repo(test_optimization_sync, "test_optimization_data")
```

```bzl
# BUILD.bazel (workspace root)
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")
load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")

dd_test_optimization_doctor(
    name = "dd_test_optimization_doctor",
    data = ["@test_optimization_data//:test_optimization_context"],
)

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bash
bazel test --config=test-optimization //... || test_status=$?; test_status=${test_status:-0}
bazel run --config=test-optimization //:dd_test_optimization_doctor || doctor_status=$?; doctor_status=${doctor_status:-0}
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //:dd_upload_payloads
upload_status=$?
if [ "$test_status" -ne 0 ]; then
  exit "$test_status"
fi
if [ "$doctor_status" -ne 0 ]; then
  exit "$doctor_status"
fi
exit "$upload_status"
```

```powershell
bazel test --config=test-optimization //...
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
bazel run --config=test-optimization //:dd_test_optimization_doctor
$doctorStatus = $LASTEXITCODE
if ($null -eq $doctorStatus) { $doctorStatus = 0 }
# Set once per shell session before first run:
# $env:DD_API_KEY = "<your-api-key>"
# $env:DD_SITE = "datadoghq.com"
bazel run --config=test-optimization //:dd_upload_payloads
$uploadStatus = $LASTEXITCODE
if ($testStatus -ne 0) { exit $testStatus }
if ($doctorStatus -ne 0) { exit $doctorStatus }
exit $uploadStatus
```

### Bzlmod + Go companion (`dd_topt_go_test`)

For a fresh single-service Go workspace, start with the small manual
prerequisite block below, then let the guided bootstrap finish the Go-specific
setup.

```bzl
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
bazel_dep(name = "rules_go", version = "0.60.0")
```

Then run the Datadog bootstrap helper once from the workspace that owns your
Go module. `--dd-trace-go-version` is optional; if you omit it, the default is
`v2.9.0-dev.0.20260416093245-194346a71c51`.

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service go-service \
  --runtime-version 1.25.0 \
  --dd-trace-go-version v2.9.0-dev.0.20260416093245-194346a71c51 \
  --write-bazelrc
```

If the Go module lives below the workspace root:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service go-service \
  --runtime-version 1.25.0 \
  --dd-trace-go-version v2.9.0-dev.0.20260416093245-194346a71c51 \
  --go-module-dir path/to/go-module \
  --write-bazelrc
```

`--dd-trace-go-version` accepts a normal tag, a pseudo-version, a branch, or a
commit SHA. Bootstrap resolves that input to exact Go module versions before it
writes anything back to the workspace. If you rerun bootstrap without
`--dd-trace-go-version`, it preserves the managed tracer config that is already
in place.

The bootstrap helper:
- updates `MODULE.bazel` with a Datadog-managed `rules_go` override back to this repository's clean vendored `third_party/rules_go_orchestrion_base` base module and the `@rules_go//go:extensions.bzl` Orchestrion wiring required for Bazel builds
- adds the Datadog-managed single-service Go sync block (`test_optimization_go_extension`)
- creates a root `dd_test_optimization_doctor` target when missing
- creates a root `dd_upload_payloads` target when missing
- can print or write the recommended `.bazelrc` block with
  `--print-bazelrc-snippet` or `--write-bazelrc`
- creates `//tools/build:dd_go_test.bzl` for workspace-local Go tests
- writes a deterministic `orchestrion.tool.go` that matches the Bazel-side Orchestrion wiring
- repins `dd-trace-go` and the Orchestrion-managed Go helper packages to the resolved tracer versions
- writes `orchestrion.tool.go`
- writes a starter `orchestrion.yml` when missing
- writes either `dd_trace_go_version` or `dd_trace_go_versions` into the managed `MODULE.bazel` block, depending on whether the traced Go modules resolve to one shared version or different exact versions

By default, `dd_topt_go_test` also sets `DD_SERVICE` from the selected sync
metadata service name. If you already set `DD_SERVICE` in the test target's
`env`, the macro preserves your explicit value. If you pass `env = select(...)`,
the macro leaves that configurable env unchanged in this release.
- keeps Bazel's injected tracer versions and the local Go module pins aligned, and the build fails fast if they drift apart

The generated `.bazelrc` block is managed between
`# BEGIN Datadog Test Optimization Bazelrc` and
`# END Datadog Test Optimization Bazelrc`. It forwards sync metadata through
`common:test-optimization --repo_env=...` and adds
`test:test-optimization --remote_download_outputs=all`. It deliberately does
not generate `--test_env=DD_GIT_*`,
`--test_env=DD_TEST_OPTIMIZATION_AGENT_URL`, or
`--test_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL`.

Then use the generated local wrapper in your package:

```bzl
load("//tools/build:dd_go_test.bzl", "dd_go_test")

dd_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],
)
```

Use the manual `dd_topt_go_test(..., topt_data = ...)` path only when the
workspace already has custom sync wiring, mixed-language layout, or multi-service
Go setup.

### Bzlmod + Python companion (`dd_topt_py_test`)

```bzl
bazel_dep(name = "datadog-rules-test-optimization-python", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-python",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/python",
)
```

```bzl
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_py_test(
    name = "pkg_py_test",
    srcs = ["test_*.py"],
    deps = [":pkg_lib"],
    imports = ["example/python/pkg"],
    topt_data = topt_data,
)
```

`dd_topt_py_test` now defaults to `@rules_python//python:py_test`, so you only
need `py_test_rule` when you intentionally override the underlying test rule.
When you omit `main`, the macro uses the bundled pytest entry point, defaults
`args` to the Bazel package path, and adds `PYTEST_ADDOPTS=--ddtrace` unless
you already set it or opt out with `--no-ddtrace`. If you use `unittest` or
another custom runner, keep passing `main` and any custom `imports` or `args`
you need.

### Bzlmod + Java companion (`dd_topt_java_test`)

```bzl
bazel_dep(name = "datadog-rules-test-optimization-java", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-java",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/java",
)
```

```bzl
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_java_test(
    name = "pkg_java_test",
    srcs = ["*Test.java"],
    deps = [":pkg_lib"],
    test_class = "com.example.pkg.SampleTest",
    topt_data = topt_data,
    java_test_rule = java_test,
)
```

### Bzlmod + NodeJS companion (`dd_topt_nodejs_test`)

```bzl
bazel_dep(name = "aspect_rules_js", version = "3.0.0-rc5")
bazel_dep(name = "rules_nodejs", version = "6.7.3")
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
```

```bzl
load("@aspect_rules_js//js:defs.bzl", "js_test")
load("@datadog-rules-test-optimization-nodejs//:topt_nodejs_test.bzl", "dd_topt_nodejs_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_nodejs_test(
    name = "pkg_nodejs_test",
    entry_point = "smoke_test.js",
    copy_data_to_bin = False,  # Datadog payload data comes from external repos.
    module_identifier = "apps/nodejs/pkg",
    topt_data = topt_data,
    nodejs_test_rule = js_test,
)
```

### Bzlmod + .NET companion (`dd_topt_dotnet_test`)

```bzl
bazel_dep(name = "rules_dotnet", version = "0.21.5")
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
```

```bzl
load("@datadog-rules-test-optimization-dotnet//:topt_dotnet_test.bzl", "dd_topt_dotnet_test")
load("@test_optimization_data//:export.bzl", "topt_data")
load(":dotnet_test_adapter.bzl", "dotnet_csharp_test_adapter")

dd_topt_dotnet_test(
    name = "pkg_dotnet_test",
    srcs = ["smoke_test.cs"],
    target_frameworks = ["net8.0"],
    module_identifier = "Company.Product.Package",
    topt_data = topt_data,
    dotnet_test_rule = dotnet_csharp_test_adapter,
)
```

`dotnet_test_adapter.bzl` wraps `@rules_dotnet//dotnet:defs.bzl` `csharp_test` and maps the Datadog macro's `env` to `csharp_test(envs = ...)`.

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

### Bzlmod + Ruby companion (`dd_topt_ruby_test`)

```bzl
bazel_dep(name = "rules_ruby", version = "0.21.1")
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
```

```bzl
load("@rules_ruby//ruby:defs.bzl", "rb_test")
load("@datadog-rules-test-optimization-ruby//:topt_ruby_test.bzl", "dd_topt_ruby_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_ruby_test(
    name = "pkg_ruby_test",
    srcs = ["smoke_test.rb"],
    main = "smoke_test.rb",
    module_identifier = "apps/ruby/pkg",
    topt_data = topt_data,
    ruby_test_rule = rb_test,
)
```

### Optional: workspace-local wrappers (less boilerplate)

If your workspace always uses the same synced repo (`@test_optimization_data`)
and the same underlying test rule symbols, create thin local wrappers so
package BUILD files do not repeat `topt_data` and `*_test_rule`.

Single-service wrapper pattern (Go example):

```bzl
# tools/build/dd_go_test.bzl
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

def dd_go_test(name, **kwargs):
    dd_topt_go_test(
        name = name,
        topt_data = topt_data,
        orchestrion_pin_files = [
            "//:go.mod",
            "//:go.sum",
            "//:orchestrion.tool.go",
            "//:orchestrion.yml",
        ],
        **kwargs
    )
```

```bzl
# package BUILD.bazel
load("//tools/build:dd_go_test.bzl", "dd_go_test")

dd_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],
)
```

You can apply the same pattern to all companion macros:

```bzl
# tools/build/dd_py_test.bzl
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")

def dd_py_test(name, **kwargs):
    dd_topt_py_test(
        name = name,
        topt_data = topt_data,
        **kwargs
    )
```

```bzl
# tools/build/dd_java_test.bzl
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
load("@test_optimization_data//:export.bzl", "topt_data")

def dd_java_test(name, **kwargs):
    dd_topt_java_test(
        name = name,
        topt_data = topt_data,
        java_test_rule = native.java_test,
        **kwargs
    )
```

```bzl
# tools/build/dd_nodejs_test.bzl
load("@aspect_rules_js//js:defs.bzl", "js_test")
load("@datadog-rules-test-optimization-nodejs//:topt_nodejs_test.bzl", "dd_topt_nodejs_test")
load("@test_optimization_data//:export.bzl", "topt_data")

def dd_nodejs_test(name, **kwargs):
    dd_topt_nodejs_test(
        name = name,
        topt_data = topt_data,
        nodejs_test_rule = js_test,
        **kwargs
    )
```

```bzl
# tools/build/dd_dotnet_test.bzl
load("@datadog-rules-test-optimization-dotnet//:topt_dotnet_test.bzl", "dd_topt_dotnet_test")
load("@test_optimization_data//:export.bzl", "topt_data")
load("//:dotnet_test_adapter.bzl", "dotnet_csharp_test_adapter")

def dd_dotnet_test(name, **kwargs):
    dd_topt_dotnet_test(
        name = name,
        topt_data = topt_data,
        dotnet_test_rule = dotnet_csharp_test_adapter,
        **kwargs
    )
```

```bzl
# tools/build/dd_ruby_test.bzl
load("@rules_ruby//ruby:defs.bzl", "rb_test")
load("@datadog-rules-test-optimization-ruby//:topt_ruby_test.bzl", "dd_topt_ruby_test")
load("@test_optimization_data//:export.bzl", "topt_data")

def dd_ruby_test(name, **kwargs):
    dd_topt_ruby_test(
        name = name,
        topt_data = topt_data,
        ruby_test_rule = rb_test,
        **kwargs
    )
```

For multi-service repos, either:

1. Keep `topt_service` as a wrapper argument and pass `topt_data_by_service`
2. Create one wrapper per service with `topt_service` pre-set

### Bzlmod + multi-service monorepo

Use the Go extension multi-service form only for multi-service Go setups. It is
not a generic mixed-runtime extension; every service configured through it is
materialized as `runtime_name = "go"`. For Python/Java/NodeJS/.NET/Ruby
multi-service onboarding, use
[`docs/Language_Onboarding.md`](docs/Language_Onboarding.md).

```bzl
go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

go_topt.test_optimization_go(
    name = "test_optimization_data",
    services = ["go-service-a", "go-service-b"],
    runtime_version = "1.25.0",
)

use_repo(
    go_topt,
    "test_optimization_data",
    "test_optimization_data_go_service_a",
    "test_optimization_data_go_service_b",
)
```

For macro consumers, load `topt_data_by_service` from
`@test_optimization_data//:export.bzl` and select by `topt_service`.

### Bzlmod + mixed-language monorepo

For mixed-runtime repos, keep one sync repo per runtime or runtime/service
slice and use the matching companion on top of each exported dataset. Do not
reuse one shared sync repo across different runtimes.

```bzl
topt_go = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)
topt_go.test_optimization_sync(
    name = "test_optimization_data_go",
    service = "go-service",
    runtime_name = "go",
    runtime_version = "1.25.0",
)

topt_ruby = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)
topt_ruby.test_optimization_sync(
    name = "test_optimization_data_ruby",
    service = "ruby-service",
    runtime_name = "ruby",
    runtime_version = "3.3.9",
)

use_repo(topt_go, "test_optimization_data_go")
use_repo(topt_ruby, "test_optimization_data_ruby")
```

Then load the matching export in each runtime-specific wrapper or BUILD file:
- Go targets use `@test_optimization_data_go//:export.bzl`
- Ruby targets use `@test_optimization_data_ruby//:export.bzl`

Root uploader wiring in a mixed-runtime workspace must bundle every matching
context target so the uploader can pick the correct `context.json` per payload:

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data_go//:test_optimization_context",
        "@test_optimization_data_ruby//:test_optimization_context",
    ],
)
```

### WORKSPACE mode

WORKSPACE remains supported for v1. Minimal setup:

```bzl
# WORKSPACE
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

git_repository(
    name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

load("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")

test_optimization_sync(
    name = "test_optimization_data",
    service = "my-service",  # recommended; otherwise falls back to DD_SERVICE or unnamed-service
)
```

For Go in WORKSPACE mode, keep the core and Go companion as separate external
repositories and load `dd_topt_go_test` from
`@datadog-rules-test-optimization-go//:topt_go_test.bzl`. Prefer the public
WORKSPACE helper so the Go companion and Orchestrion-enabled `rules_go` fork use
the same commit, repo mapping, and variant:

```bzl
load("@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl", "datadog_go_test_optimization_workspace_repositories")

datadog_go_test_optimization_workspace_repositories(
    rto_commit = "<commit-sha>",
    rules_go_repo_name = "io_bazel_rules_go",
    rules_go_variant = "base",  # or "complete" for extended monorepo compatibility
)
```

Use `rules_go_variant = "base"` for normal consumers. Use `complete` only when
the consumer needs the declared extended monorepo compatibility layer. Both
variants are complete `rules_go` trees and do not require `patches`,
`patch_tool`, or a consumer-owned patch directory. The public WORKSPACE helper
also expects the default tool-repo name `rules_go_orchestrion_tool`, so
consumers should not rename that repository.
When Go tests live below the module root, pass the module-root pin files through
`orchestrion_pin_files` (for example `["//:go.mod", "//:orchestrion.tool.go"]`)
or inject them from a repo-local wrapper.

Use [`docs/Installation_Reference.md`](docs/Installation_Reference.md) for mirrored `http_archive`, Go toolchain
setup, uploader wiring, and full WORKSPACE details.
You can also print a starting WORKSPACE snippet without modifying files:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --print-workspace-snippet \
  --rto-commit <commit-sha> \
  --rules-go-variant base
```

### Other languages

Use the core-only path above, or mirror the companion pattern used by
Go/Python/Java/NodeJS/.NET/Ruby, then wire your language test rule/macro so it:

1. Includes `@test_optimization_data//:test_optimization_files` in `data`
2. Sets `DD_TEST_OPTIMIZATION_MANIFEST_FILE` to the manifest runfile path
   - At runtime, resolve the payload root as `dirname(DD_TEST_OPTIMIZATION_MANIFEST_FILE)`.
3. Sets `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES = "true"`
4. Writes payloads under `TEST_UNDECLARED_OUTPUTS_DIR/payloads/{tests,coverage}`
5. Adds `@test_optimization_data//:test_optimization_context` to uploader `data`

For a generic wrapper pattern, see [Other languages (without companion macro)](#other-languages-without-companion-macro).

## Requirements

### Command convention

- Consumer repository commands in this README use `bazel`
- Repository-maintainer workflows in this repo use `./bazelw` (see [`docs/Maintainers.md`](docs/Maintainers.md))
- This repository intentionally does not define a root `.bazelrc`.
  Example workspaces keep local `.bazelrc` files; CI and maintainer docs provide
  canonical flags.

### Compatibility snapshot

| Component | Recommended baseline | Notes |
|-----------|----------------------|-------|
| Bazel | `8.5.1` | Repository baseline (`.bazelversion`) and primary CI lanes |
| rules_go (Go users) | `0.60.0` | README examples use this version; importpath inference requires `0.51.0+` |
| Go toolchain (example) | `1.25.0` | Consumer repositories may use another supported version |
| Module versions | `1.0.0` metadata | BCR publication is pending; use commit pin/override install paths |

- **Bazel 8.5.1 (repo baseline)** - Matches `.bazelversion` and primary CI lanes
- **WORKSPACE compatibility lane** - CI intentionally validates `--noenable_bzlmod --enable_workspace` on Bazel `8.4.1` during migration away from WORKSPACE mode in Bazel 9+
- **Bazel 5.0+ minimum capability** - Earliest Bazel line with required `TEST_UNDECLARED_OUTPUTS_DIR` payload support
- **Tracer/runtime with DD Test Optimization file-mode support** - Must honor `DD_TEST_OPTIMIZATION_MANIFEST_FILE` and `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES`
- **rules_go v0.51.0+** (for Go importpath inference) - This repository reads `GoInfo`/`GoArchive` providers when selecting per-module payloads
- **DD_SITE format** - Accepts bare host, app/api-prefixed host, or full URL; leading/trailing ASCII whitespace is trimmed, then normalized to `https://api.<site>`
- **Uploader tooling (per platform)** - Required for `bazel run //:dd_upload_payloads`
  - **Linux**: `bash`, `curl`, `find`, `stat` (GNU), `awk`, and one of `md5sum` or `shasum`
  - **macOS**: `bash` (3.2+), `curl`, `find`, `stat` (BSD), `awk`, and one of `md5` or `shasum`
  - **Windows**: `powershell.exe` (Windows PowerShell 5.1+ or PowerShell 7+); the uploader uses .NET `HttpClient` and is intentionally PowerShell-only (no Git Bash dependency)

Optional tooling:
- **jq** (Linux/macOS) - Used to enrich test payloads with `context.json`. If missing, uploads proceed without enrichment.
- **python3** - Used for uploader payload schema validation and Unix telemetry metadata extraction. If missing, schema validation is skipped and telemetry files fail individually with a warning.

### Contract gate checklist

Before rollout in a consumer repository, confirm the tracer/runtime implementation:
- resolves `DD_TEST_OPTIMIZATION_MANIFEST_FILE` through Bazel runfiles
- enables file-mode output when `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true`
- writes JSON payloads under `TEST_UNDECLARED_OUTPUTS_DIR/payloads/tests`, `TEST_UNDECLARED_OUTPUTS_DIR/payloads/coverage`, and `TEST_UNDECLARED_OUTPUTS_DIR/payloads/telemetry`

The extension performs these HTTP POST transactions (via host HTTP tooling: curl on Unix/macOS, PowerShell on Windows):

- Settings: always executed. Parses feature flags from response.
- Known Tests: executed only when `known_tests_enabled: true` in Settings.
- Test Management Tests: executed only when `test_management.enabled: true` in Settings.

All outputs are written under a configurable directory (default: `.testoptimization`) and are grouped under a single filegroup target. The exact manifest path is exported via `topt_data["manifest_path"]`.

## What gets created

Given an external repository name `<repo_name>` created by the extension, the generated BUILD inside the external repo contains:

- A core filegroup target named `test_optimization_files` which includes `cache/http/settings.json` and `manifest.txt`
- Files (always created; some may be minimal stubs if the corresponding feature is disabled):
  - `cache/http/settings.json` (Settings API response)
  - `manifest.txt` (Payload manifest; version marker for change tracking, currently `version=1`)
  - `cache/http/known_tests.json` (Known Tests API response or minimal stub)
  - `cache/http/test_management.json` (Test Management Tests API response or minimal stub)
  - `context.json` (Non-secret CI/Git/OS/runtime tags)
  - Per-module Known Tests/Test Management (via filegroups): each module has a target exposing canonical runfiles under `<manifest_dir>/cache/http/` with `known_tests.json` and `test_management.json`, scoped to that module. Physical files are stored under `<out_dir>/module_<sanitized>/known_tests.json` and `<out_dir>/module_<sanitized>/test_management.json` (default `<out_dir>` is `.testoptimization`).

Reference settings with a single label:

```bzl
@<repo_name>//:test_optimization_files
```

### Per-module files and labels

When Known Tests are enabled, the combined response `data.attributes.tests` is a map keyed by module name. For convenience and performance, the sync rule automatically splits this response into per-module files and creates one public target per module. The same splitting is performed for Test Management tests (`test_management.json`), keyed by module under `data.attributes.modules`:

- Each module target exposes canonical runfiles (stable names, regardless of `out_dir`):
  - `<manifest_dir>/cache/http/known_tests.json` (module-scoped; same shape as combined)
  - `<manifest_dir>/cache/http/test_management.json` (module-scoped; same shape as combined)
- Each module also becomes a public target: `:module_<sanitized_module>` that includes:
  - `<manifest_dir>/cache/http/settings.json`
  - `<manifest_dir>/manifest.txt`
  - `<manifest_dir>/cache/http/known_tests.json` (always present; stub when empty)
  - `<manifest_dir>/cache/http/test_management.json` (always present; stub when empty)
- These per-module files are not bundled into `:test_optimization_files`

Sanitization rules for `<sanitized_module>` (file paths and target labels):

- Lowercase input
- Characters outside `[a-z0-9_]` are replaced with `_`
- Consecutive underscores are collapsed, then leading/trailing underscores are trimmed
- If collisions occur after sanitization, numeric suffixes like `_2`, `_3` are appended deterministically

Labels are computed from the union of module names across known tests and test management so a `module_<sanitized>` target always refers to a single module (avoids cross-feature collisions).

Example usage:

```bzl
# Consume only the module "pkg/foo" tests metadata
filegroup(
    name = "dd_known_tests_pkg_foo",
    srcs = [
        "@test_optimization_data//:module_pkg_foo",
    ],
)

# If you need file paths at test time, use rlocationpaths on the selector target
# provided by the dd_topt_go_test macro (see [`modules/go/topt_go_test.bzl`](modules/go/topt_go_test.bzl)).
```

## Advanced installation and setup

The quickstarts above cover the most common onboarding paths.

For complete setup matrices and advanced options, use:

- [`docs/Installation_Reference.md`](docs/Installation_Reference.md) for full Bzlmod/WORKSPACE flows
- [`docs/Configuration_Reference.md`](docs/Configuration_Reference.md) for attribute and environment details

## Uploading test, coverage, and telemetry payloads

The uploader is a normal Bazel rule (not a test) that runs via `bazel run` after your tests complete. It discovers all test payloads written to `TEST_UNDECLARED_OUTPUTS_DIR` (Bazel's built-in directory for undeclared test outputs) and uploads them to Datadog.

### How it works

1. Tests write payloads to `$TEST_UNDECLARED_OUTPUTS_DIR/payloads/tests/*.json`, `$TEST_UNDECLARED_OUTPUTS_DIR/payloads/coverage/*.json`, and `$TEST_UNDECLARED_OUTPUTS_DIR/payloads/telemetry/*.json`
2. Bazel automatically collects these to `bazel-testlogs/<package>/<target>/test.outputs/`
3. After tests complete, run the doctor via `bazel run` to validate local
   outputs before upload
4. Then run the uploader via `bazel run`
5. The uploader discovers all `test.outputs/` directories, waits for quiescence, uploads, and deletes files

Telemetry-specific notes:
- Telemetry files must contain one raw top-level tracer telemetry request body per file.
- Telemetry uploads are reconstructed from the raw body plus the uploader mode.
- Telemetry does not use test-payload enrichment (`context.json`, CODEOWNERS, or schema validation).
- `DD_TEST_OPTIMIZATION_FILTER_PREFIX=1` still filters only test and coverage filenames; telemetry files remain eligible regardless of filename prefix.

### Basic usage

```bash
# RECOMMENDED: Run tests, validate payloads, then upload payloads.
bazel test --config=test-optimization //... || test_status=$?; test_status=${test_status:-0}
bazel run --config=test-optimization //:dd_test_optimization_doctor || doctor_status=$?; doctor_status=${doctor_status:-0}
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //:dd_upload_payloads
upload_status=$?
if [ "$test_status" -ne 0 ]; then
  exit "$test_status"
fi
if [ "$doctor_status" -ne 0 ]; then
  exit "$doctor_status"
fi
exit "$upload_status"

# HERMETIC/REMOTE EXECUTION - keep --config=test-optimization on test and doctor.
bazel test --config=test-optimization --config=hermetic //... || test_status=$?; test_status=${test_status:-0}
bazel run --config=test-optimization --config=hermetic //:dd_test_optimization_doctor || doctor_status=$?; doctor_status=${doctor_status:-0}
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //:dd_upload_payloads
upload_status=$?
if [ "$test_status" -ne 0 ]; then
  exit "$test_status"
fi
if [ "$doctor_status" -ne 0 ]; then
  exit "$doctor_status"
fi
exit "$upload_status"
```

```powershell
# RECOMMENDED: Run tests, validate payloads, then upload payloads.
bazel test --config=test-optimization //...
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
bazel run --config=test-optimization //:dd_test_optimization_doctor
$doctorStatus = $LASTEXITCODE
if ($null -eq $doctorStatus) { $doctorStatus = 0 }
# Set once per shell session before first run:
# $env:DD_API_KEY = "<your-api-key>"
# $env:DD_SITE = "datadoghq.com"
bazel run --config=test-optimization //:dd_upload_payloads
$uploadStatus = $LASTEXITCODE
if ($testStatus -ne 0) { exit $testStatus }
if ($doctorStatus -ne 0) { exit $doctorStatus }
exit $uploadStatus

# HERMETIC/REMOTE EXECUTION - keep --config=test-optimization on test and doctor.
bazel test --config=test-optimization --config=hermetic //...
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
bazel run --config=test-optimization --config=hermetic //:dd_test_optimization_doctor
$doctorStatus = $LASTEXITCODE
if ($null -eq $doctorStatus) { $doctorStatus = 0 }
bazel run --config=test-optimization //:dd_upload_payloads
$uploadStatus = $LASTEXITCODE
if ($testStatus -ne 0) { exit $testStatus }
if ($doctorStatus -ne 0) { exit $doctorStatus }
exit $uploadStatus
```

**IMPORTANT**: Always preserve the test exit code! Using plain `;` causes CI to report success even when tests fail.

### Important runtime requirements

1. Use `bazel run` (not `bazel test`) for uploader execution.
2. Use a single uploader target per workspace (do not run concurrent uploaders).
3. Tests must run locally, or use `--remote_download_outputs=all`.
4. Run uploader on the same machine/workspace where tests executed.
5. `DD_TEST_OPTIMIZATION_CONTEXT_JSON` is a legacy explicit override for
   advanced workflows that already resolved one specific `context.json` path.
   Do not use it as the normal mixed-runtime wiring path; mixed-runtime
   workspaces should pass every relevant `:test_optimization_context` target in
   uploader `data` and let the uploader select per payload.

### Full uploader reference

For complete uploader details, use [`docs/Uploader_Reference.md`](docs/Uploader_Reference.md), including:

- uploader target attributes and optional environment variables
- agentless vs EVP credential modes and endpoint behavior
- retry/reliability semantics and exit codes
- metadata enrichment (`context.json`, CODEOWNERS) and schema validation

## Convenience macro: dd_topt_go_test

The `dd_topt_go_test` macro creates a `go_test` target with Datadog Test
Optimization data/env wiring included, and always runs through an internal
Orchestrion-enabled wrapper target.

By default, it sets `rundir` to the current Bazel package when not explicitly
provided. If you enable `stage_sources = True`, it instead defaults `rundir`
to `.` unless you already set `rundir` yourself.

For a fresh single-service Go workspace, prefer the guided bootstrap flow above.
It generates the local `dd_go_test` wrapper and the uploader target for you.

Use the raw macro directly only when you need the lower-level API.

Before using it directly, configure the Go companion extension in `MODULE.bazel`:

```bzl
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
bazel_dep(name = "rules_go", version = "0.60.0")

go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

go_topt.test_optimization_go(
    name = "test_optimization_data",
    service = "go-service",
    runtime_version = "1.25.0",
    module_path = "github.com/example/service",
)

use_repo(go_topt, "test_optimization_data")
```

`module_path` should match the Go module path from `go.mod`. The sync rule
still honors `GO_MODULE_PATH` first for CI overrides, but the explicit attr is
the recommended default because it avoids repo-local `--repo_env` glue.

Then run the Datadog bootstrap helper once so Orchestrion is pinned into the
workspace Go module. Repository/bootstrap resolution may use network access.
After that, Orchestrion build actions consume a declared offline Go module
download cache staged in `@rules_go_orchestrion_tool`; they do not depend on a
warmed host Go module cache. Test payloads still use the Bazel file-output
contract: the tracer writes JSON files under `TEST_UNDECLARED_OUTPUTS_DIR`, and
the uploader enriches those JSON files with repository and Bazel metadata. Pass
`--dd-trace-go-version <query>` if you want a non-default tracer version;
otherwise the default is `v2.9.0-dev.0.20260416093245-194346a71c51`.

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap
```

If you wire Orchestrion manually instead of using bootstrap, you can also set
the tracer versions directly in `MODULE.bazel`.

Shared-version form:

```bzl
orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = "v1.9.0",
    dd_trace_go_version = "v2.7.0-rc.4",
)
use_repo(orchestrion, "rules_go_orchestrion_tool")
```

Per-module form:

```bzl
orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = "v1.9.0",
    dd_trace_go_versions = {
        "github.com/DataDog/dd-trace-go/v2": "v2.7.0-rc.4",
        "github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.8.0-dev.0.20260316165907-0cdd3b7576b7",
        "github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.8.0-dev.0.20260316165907-0cdd3b7576b7",
    },
)
use_repo(orchestrion, "rules_go_orchestrion_tool")
```

The maintained repository integration scripts validate the hermetic Go path
with explicit Bazel flags in the script itself. There is no special repo-root
`--config=hermetic` shortcut for this flow.

If both settings are omitted, the default is still
`v2.9.0-dev.0.20260416093245-194346a71c51`. Manual setups must keep the local Go
module pins on the same effective versions, or the build will stop with a
mismatch error. Do not set both `dd_trace_go_version` and `dd_trace_go_versions`
in the same `orchestrion.from_source(...)` call.
Bootstrap also refuses to take over tracer settings that are already managed
manually outside its own managed block.

### Basic usage

```bzl
load("@rules_go//go:def.bzl", "go_library")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

go_library(
    name = "pkg_lib",
    srcs = ["*.go"],
)

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],  # enables provider-based importpath inference
    topt_data = topt_data,
)
```

`dd_topt_go_test` enables CI Visibility and payload-to-files mode by default,
so opt-in Go tests emit payload files without extra `--test_env` settings.

If the tracer needs runtime-visible source files for AST-derived metadata such
as `test.source.end`, enable source staging explicitly:

```bzl
dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],
    stage_sources = True,
    topt_data = topt_data,
)
```

`stage_sources` stages only the target's direct `srcs` and direct
`embedsrcs`. When enabled, it changes the default `rundir` to `.` only if you
did not already set `rundir`. An explicit `rundir` still wins unchanged.

Then run tests, validate payloads, and upload:

```bash
bazel test --config=test-optimization //... || test_status=$?; test_status=${test_status:-0}
bazel run --config=test-optimization //:dd_test_optimization_doctor || doctor_status=$?; doctor_status=${doctor_status:-0}
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run --config=test-optimization //:dd_upload_payloads
upload_status=$?
if [ "$test_status" -ne 0 ]; then
  exit "$test_status"
fi
if [ "$doctor_status" -ne 0 ]; then
  exit "$doctor_status"
fi
exit "$upload_status"
```

```powershell
bazel test --config=test-optimization //...
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
bazel run --config=test-optimization //:dd_test_optimization_doctor
$doctorStatus = $LASTEXITCODE
if ($null -eq $doctorStatus) { $doctorStatus = 0 }
# Set once per shell session before first run:
# $env:DD_API_KEY = "<your-api-key>"
# $env:DD_SITE = "datadoghq.com"
bazel run --config=test-optimization //:dd_upload_payloads
$uploadStatus = $LASTEXITCODE
if ($testStatus -ne 0) { exit $testStatus }
if ($doctorStatus -ne 0) { exit $doctorStatus }
exit $uploadStatus
```

### If tests use local fixtures

Declare fixture files explicitly in `data`:

```bzl
dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    data = glob(["testdata/**"]),
    topt_data = topt_data,
)
```

The bootstrap-generated `//tools/build:dd_go_test.bzl` wrapper forwards
`**kwargs`, so it supports `stage_sources = True` the same way without wrapper
changes.

### Import path inference

The macro auto-selects the correct per-module payloads by inferring the Go package `importpath` using rules_go providers, mirroring how `go_test` computes it:

- Precedence:
  1) `importpath` explicitly set on your `go_test` invocation (if provided in kwargs)
  2) Inference via `embed = [":<go_library>"]` by reading `GoArchive.importpath` from rules_go (recommended)
  3) Fallback: `<go module path>/<bazel package>` where the Go module path comes from the synced repo's exported `topt_data["runtimes"]["go"]["module_path"]`

When automatic per-module selection is close but not exact (for example, custom
import path layouts), use `module_label_override` to pin the expected sanitized
module suffix:

```bzl
dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],
    module_label_override = "github_com_example_custom_pkg",
    topt_data = topt_data,
)
```

### Multi-service usage

This is the advanced/manual path. Guided bootstrap is intentionally limited to
fresh single-service Go workspaces.

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    topt_data = topt_data_by_service,   # pass mapping
    topt_service = "go_service_a",      # select service
)
```

## Other languages (without companion macro)

Core sync + uploader support is runtime-agnostic and works for any language
runtime that honors the file-mode contract. This section is primarily for
languages beyond the first-class companions (`go`, `python`, `java`, `nodejs`,
`dotnet`, `ruby`).

Repository layout note: keep `tools/` runtime-agnostic (`tools/core`,
`tools/tests`, `tools/dev`). Add first-class language orchestration under
`modules/<language>/` companion modules instead of creating `tools/<language>`
placeholder packages.

### Generic wrapper pattern

For non-Go rules, wire the same env/data contract in your own test macro:

```bzl
load("@test_optimization_data//:export.bzl", "topt_data")

manifest_label = "@%s//:%s" % (topt_data["repo_name"], topt_data["manifest_path"])

my_lang_test(
    name = "my_lang_test",
    srcs = ["test_file.ext"],
    data = [
        "@test_optimization_data//:test_optimization_files",
        manifest_label,
    ],
    env = {
        "DD_TEST_OPTIMIZATION_MANIFEST_FILE": "$(rlocationpath %s)" % manifest_label,
        "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "true",
    },
)
```

Depending on your rule set, the exact attributes may differ (`env`, `data`,
args, wrapper script, etc.), but the required contract is always:

1. Resolve `DD_TEST_OPTIMIZATION_MANIFEST_FILE` via runfiles
2. Set `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES = "true"`
3. Write payloads to `TEST_UNDECLARED_OUTPUTS_DIR/payloads/{tests,coverage}`

First-class companion macros in this repository also default `DD_SERVICE` from
the selected sync metadata service name. They never override an explicit caller
`DD_SERVICE`, and they leave `env = select(...)` unchanged.

### Building a first-class companion module

If you want `dd_topt_<language>_test`-style first-class support in this repo,
follow the maintainer checklist in [`docs/Maintainers.md`](docs/Maintainers.md).

## Troubleshooting

Use the quick triage map and detailed playbook in [`docs/Troubleshooting.md`](docs/Troubleshooting.md).

Fast checks before diving deep:

- Verify env forwarding (`DD_API_KEY`, `DD_SITE`) and force refetch:
  - `bazel sync --only=<repo_name> --repo_env=FETCH_SALT=<timestamp>`
  - If Bazel reports WORKSPACE-disabled sync errors, retry with:
    `bazel sync --enable_workspace --only=<repo_name> --repo_env=FETCH_SALT=<timestamp>`
- Confirm payload files exist under `bazel-testlogs/*/test.outputs/`
- For RBE, rerun tests with `--remote_download_outputs=all`
- Enable debug logging on sync/uploader rules for richer diagnostics
- If needed, file an issue with sanitized logs:
  - open an issue in the repository issue tracker

## Reference links

- Per-language onboarding guide: [`docs/Language_Onboarding.md`](docs/Language_Onboarding.md)
- Maintainer/contributor workflows: [`docs/Maintainers.md`](docs/Maintainers.md)
- Full installation reference: [`docs/Installation_Reference.md`](docs/Installation_Reference.md)
- Full troubleshooting playbook: [`docs/Troubleshooting.md`](docs/Troubleshooting.md)
- Configuration and fetch behavior reference: [`docs/Configuration_Reference.md`](docs/Configuration_Reference.md)
- Uploader runtime reference: [`docs/Uploader_Reference.md`](docs/Uploader_Reference.md)
- External-link provenance note: repository behavior is source-of-truth in this repo's code/tests; external docs are informative and may lag temporarily.

## Tips

- Maintainers: this repository's `./bazelw` supports `FETCH_SALT_TTL` (for example: `FETCH_SALT_TTL=3600 ./bazelw build //tools/... //examples/...`).
- For debugging, set `debug = True` when calling the extension to get verbose logs, including request bodies and detected OS info.
