# Datadog Test Optimization Bazel Module Extension

This repository provides Bazel integrations that fetch Datadog Test Optimization metadata during module/repository resolution and materialize JSON files for use in your build. It also generates public filegroups so consumers can depend on stable labels instead of wiring files manually.

> First release status: module metadata currently uses `1.0.0`, but Bazel Central Registry publication is still pending. Until BCR entries are published, install with `git_override` (Bzlmod) or commit-pinned `git_repository` / `http_archive` (WORKSPACE).

## Onboarding paths

Pick the path that matches your repository:

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

## First-run checklist (all scenarios)

Use this checklist before your first CI rollout:

1. Keep the generated repo name as `test_optimization_data` (or consistently replace it in labels/commands if you choose another name).
2. Forward required environment variable names in `.bazelrc`:
   - `common --repo_env=DD_API_KEY`
   - `common --repo_env=DD_SITE`
   - Optional sync overrides when needed:
     - `common --repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL` (shared direct URL override for sync + uploader agentless path)
     - `common --repo_env=DD_TEST_OPTIMIZATION_HTTP_CONNECT_TIMEOUT_SECONDS`
     - `common --repo_env=DD_TEST_OPTIMIZATION_HTTP_MAX_TIME_SECONDS`
     - `common --repo_env=DD_TEST_OPTIMIZATION_HTTP_RETRY_ATTEMPTS`
     - `common --repo_env=DD_TEST_OPTIMIZATION_HTTP_RETRY_DELAY_SECONDS`
     - `common --repo_env=DD_TEST_OPTIMIZATION_HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS`
     - `common --repo_env=GO_MODULE_PATH` (optional Go module-path hint)
     - `common --repo_env=PYTHON_MODULE_PATH` (optional Python module-path hint)
     - `common --repo_env=JAVA_MODULE_PATH` (optional Java module-path hint)
     - `common --repo_env=NODEJS_MODULE_PATH` (optional NodeJS module-path hint)
     - `common --repo_env=DOTNET_MODULE_PATH` (optional .NET module-path hint)
     - `common --repo_env=RUBY_MODULE_PATH` (optional Ruby module-path hint)
   - Keep `DD_API_KEY` and `DD_SITE` out of test runtime by default.
     In Bazel file-mode, tests do not need uploader credentials.
   - Optional test runtime forwarding only when your tracer/test harness needs it:
     - `test --test_env=DD_TEST_OPTIMIZATION_AGENT_URL`
     - `test --test_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL`
3. Create exactly one uploader target at workspace root:
   - `//:dd_upload_payloads` via `dd_payload_uploader(...)`
4. Run tests, then uploader, while preserving test exit code.
5. If using remote execution, add `--remote_download_outputs=all` on test runs.

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

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

```bash
bazel test //... || test_status=$?; test_status=${test_status:-0}
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads
exit $test_status
```

```powershell
bazel test //...
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
# Set once per shell session before first run:
# $env:DD_API_KEY = "<your-api-key>"
# $env:DD_SITE = "datadoghq.com"
bazel run //:dd_upload_payloads
exit $testStatus
```

### Bzlmod + Go companion (`dd_topt_go_test`)

Start from the core-only quickstart above, then add these extra module
dependencies:

```bzl
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/go",
)
bazel_dep(name = "rules_go", version = "0.59.0")
```

Then use `dd_topt_go_test` in your package:

```bzl
load("@rules_go//go:def.bzl", "go_test")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    topt_data = topt_data,
    go_test_rule = go_test,
)
```

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
load("@rules_python//python:defs.bzl", "py_test")
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")

dd_topt_py_test(
    name = "pkg_py_test",
    srcs = ["test_*.py"],
    deps = [":pkg_lib"],
    imports = ["example/python/pkg"],
    topt_data = topt_data,
    py_test_rule = py_test,
)
```

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
load("@rules_go//go:def.bzl", "go_test")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

def dd_go_test(name, **kwargs):
    dd_topt_go_test(
        name = name,
        topt_data = topt_data,
        go_test_rule = go_test,
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
load("@rules_python//python:defs.bzl", "py_test")
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
load("@test_optimization_data//:export.bzl", "topt_data")

def dd_py_test(name, **kwargs):
    dd_topt_py_test(
        name = name,
        topt_data = topt_data,
        py_test_rule = py_test,
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

```bzl
topt_multi = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt_multi.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["go-service", "ruby-service"],
    runtime_name = "go",
    runtime_version = "1.24.0",
)

use_repo(
    topt_multi,
    "test_optimization_data",
    "test_optimization_data_go_service",
    "test_optimization_data_ruby_service",
)
```

For macro consumers, load `topt_data_by_service` from
`@test_optimization_data//:export.bzl` and select by `topt_service`.

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

Use [`docs/Installation_Reference.md`](docs/Installation_Reference.md) for mirrored `http_archive`, Go toolchain
setup, uploader wiring, and full WORKSPACE details.

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
| rules_go (Go users) | `0.59.0` | README examples use this version; importpath inference requires `0.51.0+` |
| Go toolchain (example) | `1.24.0` | Consumer repositories may use another supported version |
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
- **python3** - Used for uploader payload schema validation. If missing, uploads proceed without schema validation.

### Contract gate checklist

Before rollout in a consumer repository, confirm the tracer/runtime implementation:
- resolves `DD_TEST_OPTIMIZATION_MANIFEST_FILE` through Bazel runfiles
- enables file-mode output when `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true`
- writes JSON payloads under `TEST_UNDECLARED_OUTPUTS_DIR/payloads/tests` and `TEST_UNDECLARED_OUTPUTS_DIR/payloads/coverage`

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

## Uploading test and coverage payloads

The uploader is a normal Bazel rule (not a test) that runs via `bazel run` after your tests complete. It discovers all test payloads written to `TEST_UNDECLARED_OUTPUTS_DIR` (Bazel's built-in directory for undeclared test outputs) and uploads them to Datadog.

### How it works

1. Tests write payloads to `$TEST_UNDECLARED_OUTPUTS_DIR/payloads/tests/*.json` and `$TEST_UNDECLARED_OUTPUTS_DIR/payloads/coverage/*.json`
2. Bazel automatically collects these to `bazel-testlogs/<package>/<target>/test.outputs/`
3. After tests complete, run the uploader via `bazel run`
4. The uploader discovers all `test.outputs/` directories, waits for quiescence, uploads, and deletes files

### Basic usage

```bash
# RECOMMENDED: Run tests, then upload payloads (preserves test exit code)
bazel test //... || test_status=$?; test_status=${test_status:-0}
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads
exit $test_status

# Or as a one-liner:
bazel test //... || test_status=$?; test_status=${test_status:-0}; DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads; exit $test_status

# REMOTE EXECUTION (RBE) - add flag to download outputs:
bazel test //... --remote_download_outputs=all || test_status=$?; test_status=${test_status:-0}; DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads; exit $test_status
```

```powershell
# RECOMMENDED: Run tests, then upload payloads (preserves test exit code)
bazel test //...
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
# Set once per shell session before first run:
# $env:DD_API_KEY = "<your-api-key>"
# $env:DD_SITE = "datadoghq.com"
bazel run //:dd_upload_payloads
exit $testStatus

# REMOTE EXECUTION (RBE) - add flag to download outputs:
bazel test //... --remote_download_outputs=all
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
bazel run //:dd_upload_payloads
exit $testStatus
```

**IMPORTANT**: Always preserve the test exit code! Using plain `;` causes CI to report success even when tests fail.

### Important runtime requirements

1. Use `bazel run` (not `bazel test`) for uploader execution.
2. Use a single uploader target per workspace (do not run concurrent uploaders).
3. Tests must run locally, or use `--remote_download_outputs=all`.
4. Run uploader on the same machine/workspace where tests executed.

### Full uploader reference

For complete uploader details, use [`docs/Uploader_Reference.md`](docs/Uploader_Reference.md), including:

- uploader target attributes and optional environment variables
- agentless vs EVP credential modes and endpoint behavior
- retry/reliability semantics and exit codes
- metadata enrichment (`context.json`, CODEOWNERS) and schema validation

## Convenience macro: dd_topt_go_test

The `dd_topt_go_test` macro creates a `go_test` target with Datadog Test
Optimization data/env wiring included.

By default, it also sets `rundir` to the current Bazel package when not
explicitly provided.

### Basic usage

```bzl
load("@rules_go//go:def.bzl", "go_library", "go_test")
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
    go_test_rule = go_test,
)
```

Then run tests and upload:

```bash
bazel test //... || test_status=$?; test_status=${test_status:-0}
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads
exit $test_status
```

```powershell
bazel test //...
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
# Set once per shell session before first run:
# $env:DD_API_KEY = "<your-api-key>"
# $env:DD_SITE = "datadoghq.com"
bazel run //:dd_upload_payloads
exit $testStatus
```

### If tests use local fixtures

Declare fixture files explicitly in `data`:

```bzl
dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    data = glob(["testdata/**"]),
    topt_data = topt_data,
    go_test_rule = go_test,
)
```

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
    go_test_rule = go_test,
)
```

### Multi-service usage

```bzl
load("@rules_go//go:def.bzl", "go_test")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    topt_data = topt_data_by_service,   # pass mapping
    topt_service = "go_service",        # select service
    go_test_rule = go_test,
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
  - https://github.com/DataDog/rules_test_optimization/issues

## Reference links

- Maintainer/contributor workflows: [`docs/Maintainers.md`](docs/Maintainers.md)
- Full installation reference: [`docs/Installation_Reference.md`](docs/Installation_Reference.md)
- Full troubleshooting playbook: [`docs/Troubleshooting.md`](docs/Troubleshooting.md)
- Configuration and fetch behavior reference: [`docs/Configuration_Reference.md`](docs/Configuration_Reference.md)
- Uploader runtime reference: [`docs/Uploader_Reference.md`](docs/Uploader_Reference.md)
- External-link provenance note: repository behavior is source-of-truth in this repo's code/tests; external docs are informative and may lag temporarily.

## Tips

- Maintainers: this repository's `./bazelw` supports `FETCH_SALT_TTL` (for example: `FETCH_SALT_TTL=3600 ./bazelw build //tools/... //examples/...`).
- For debugging, set `debug = True` when calling the extension to get verbose logs, including request bodies and detected OS info.
