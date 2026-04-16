# Installation Reference

This page contains full installation and setup flows. For fast onboarding, use
the scenario quickstarts in `README.md`. For language-specific single-service
and multi-service onboarding, use [`docs/Language_Onboarding.md`](Language_Onboarding.md).

## Bzlmod installation

### Option A: install from Git commit (recommended until BCR publication)

In your `MODULE.bazel`:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
)

# Optional companion module (only needed if you use dd_topt_go_test)
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/go",
)

# Only needed when using dd_topt_go_test
bazel_dep(name = "rules_go", version = "0.60.0")

# Optional companion module (only needed if you use dd_topt_py_test)
bazel_dep(name = "datadog-rules-test-optimization-python", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-python",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/python",
)

# Optional companion module (only needed if you use dd_topt_java_test)
bazel_dep(name = "datadog-rules-test-optimization-java", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-java",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/java",
)

# Optional companion module (only needed if you use dd_topt_nodejs_test)
bazel_dep(name = "datadog-rules-test-optimization-nodejs", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-nodejs",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/nodejs",
)

# Optional companion module (only needed if you use dd_topt_dotnet_test)
bazel_dep(name = "datadog-rules-test-optimization-dotnet", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-dotnet",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/dotnet",
)

# Optional companion module (only needed if you use dd_topt_ruby_test)
bazel_dep(name = "datadog-rules-test-optimization-ruby", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-ruby",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "<commit-sha>",
    strip_prefix = "modules/ruby",
)
```

Use the same full commit SHA (40 chars) for core and companion modules.
For mirrored/archive installs, also pin and verify archive `sha256` values (see
"Archive mirror installation" below) so the fetched source is integrity-checked
in CI and local builds.

### Option B: local development overrides

```bzl
local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = "/absolute/path/to/datadog-rules-test-optimization",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-go",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/go",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-python",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/python",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-java",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/java",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-nodejs",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/nodejs",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-dotnet",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/dotnet",
)
local_path_override(
    module_name = "datadog-rules-test-optimization-ruby",
    path = "/absolute/path/to/datadog-rules-test-optimization/modules/ruby",
)
```

### Configure sync extension (single service)

```bzl
test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

# Minimal usage: defaults to writing under .testoptimization and creating
# @test_optimization_data//:test_optimization_files
test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
)

use_repo(test_optimization_sync, "test_optimization_data")
```

Core module note: `datadog-rules-test-optimization` is runtime-agnostic and
does not declare language-rule dependencies. Language-specific orchestration
lives in companion modules:
- `datadog-rules-test-optimization-go` (depends on `rules_go` providers),
- `datadog-rules-test-optimization-python`,
- `datadog-rules-test-optimization-java`,
- `datadog-rules-test-optimization-nodejs`,
- `datadog-rules-test-optimization-dotnet`,
- `datadog-rules-test-optimization-ruby`.

### Go companion module

For a fresh single-service Go workspace, the recommended path is:

1. add the core + Go companion dependency/override block
2. run guided bootstrap
3. use the generated local wrapper

Guided bootstrap command:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service go-service \
  --runtime-version 1.25.0 \
  --dd-trace-go-version v2.9.0-dev.0.20260409102143-ddd4e03ab47d
```

If the Go module lives below the workspace root:

```bash
bazel run @datadog-rules-test-optimization-go//:dd_topt_go_bootstrap -- \
  --guided \
  --service go-service \
  --runtime-version 1.25.0 \
  --dd-trace-go-version v2.9.0-dev.0.20260409102143-ddd4e03ab47d \
  --go-module-dir path/to/go-module
```

`--dd-trace-go-version` is optional. If omitted, the workspace uses the default
`v2.9.0-dev.0.20260409102143-ddd4e03ab47d`. It accepts a tag, pseudo-version, branch, or commit SHA. Bootstrap
resolves that input to exact tracer versions, keeps the local Go module pins on
those same versions, and prevents Bazel and the Go module from silently
drifting apart.

Guided bootstrap is intentionally for single-service Go workspaces. If the
workspace already uses conflicting or multi-service sync wiring:
- `test_optimization_sync_extension`
- `test_optimization_multi_sync_extension`
- a conflicting `test_optimization_go_extension` setup

use the manual/advanced Go setup path instead.

If the workspace already has a matching single-service
`test_optimization_go_extension` plus `use_repo(...)`, guided bootstrap can
reuse that wiring and continue.

The generated package-facing API is:

```bzl
load("//tools/build:dd_go_test.bzl", "dd_go_test")
```

### Python companion module

```bzl
load("@datadog-rules-test-optimization-python//:topt_py_test.bzl", "dd_topt_py_test")
```

### Java companion module

```bzl
load("@datadog-rules-test-optimization-java//:topt_java_test.bzl", "dd_topt_java_test")
```

### NodeJS companion module

```bzl
load("@datadog-rules-test-optimization-nodejs//:topt_nodejs_test.bzl", "dd_topt_nodejs_test")
```

### .NET companion module

```bzl
load("@datadog-rules-test-optimization-dotnet//:topt_dotnet_test.bzl", "dd_topt_dotnet_test")
```

### Ruby companion module

```bzl
load("@datadog-rules-test-optimization-ruby//:topt_ruby_test.bzl", "dd_topt_ruby_test")
```

### Core-only consumer (no companion module)

If your repository needs sync + uploader only (including non-Go languages),
depend on core only:

```bzl
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
test_optimization_sync.test_optimization_sync(name = "test_optimization_data")
use_repo(test_optimization_sync, "test_optimization_data")
```

### Multi-service usage (Bzlmod)

Fetch multiple services with one extension and select per-service data by label:

```bzl
# MODULE.bazel
topt_multi = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_multi_sync.bzl",
    "test_optimization_multi_sync_extension",
)

topt_multi.test_optimization_multi_sync(
    name = "test_optimization_data",
    services = ["service-a", "service-b"],
    runtime_name = "python",
    runtime_version = "3.12",
    debug = True,
)

use_repo(
    topt_multi,
    # Aggregator repo
    "test_optimization_data",
    # Per-service repos (auto-created, names include sanitized service key)
    "test_optimization_data_service_a",
    "test_optimization_data_service_b",
)

# Consuming labels (aggregator):
#  - All files for one service
#    @test_optimization_data//:test_optimization_files_service_a
#  - One module for one service (service + module label in the aggregator repo)
#    @test_optimization_data//:module_service_a_core
# Per-service repos are primarily used for per-service exports like:
#   load("@test_optimization_data_service_a//:export.bzl", "topt_data")

# Macros that expect "topt_data" can use either:
# 1) Select explicitly:
#    load("@test_optimization_data//:export.bzl", "topt_data_by_service")
#    dd_topt_py_test(..., topt_data = topt_data_by_service["service_a"])
# 2) Pass the mapping and choose via topt_service (keeps BUILD simpler):
#    dd_topt_py_test(..., topt_data = topt_data_by_service, topt_service = "service_a")
#    When service names sanitize to the same key, pass the deduped key shown in
#    the available list (for example "service_a_2").
```

Mixed-runtime note: keep runtime-specific sync repositories separate (for
example one sync for Go services and another sync for Python services). A single
`test_optimization_multi_sync` call currently models one runtime per invocation.

Additional helper file exported by the generated repository:

- `export.bzl` with a single dictionary `topt_data` containing:
  - `repo_name`: external repository name created by the sync rule (for example,
    `test_optimization_data`)
  - `manifest_path`: path to `manifest.txt` inside the generated repo
  - `labels`: list of available per-module sanitized labels
  - `set`: dict-as-set keyed by sanitized labels for fast membership checks
  - `runtimes["go"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`
  - `runtimes["python"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`
  - `runtimes["java"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`
  - `runtimes["nodejs"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`
  - `runtimes["dotnet"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`
  - `runtimes["ruby"]`: nested object with `module_path`, `sanitized_module_path`, `module_included`

Then in any BUILD file:

```bzl
filegroup(
    name = "dd_test_opt_files",
    srcs = ["@test_optimization_data//:test_optimization_files"],
)

# Access context.json separately (for the uploader)
filegroup(
    name = "dd_test_opt_context",
    srcs = ["@test_optimization_data//:test_optimization_context"],
)
```

## WORKSPACE installation (Bazel without Bzlmod)

WORKSPACE mode is supported for v1 when Bzlmod is disabled.

### 1) Add this repository in `WORKSPACE`

```bzl
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

git_repository(
    name = "datadog-rules-test-optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    # Use an immutable commit SHA.
    commit = "<commit-sha>",
)

# Or:
# local_repository(
#     name = "datadog-rules-test-optimization",
#     path = "/absolute/path/to/rules_test_optimization",
# )
```

Pin an immutable commit SHA (or internal mirrored archive) for reproducibility.

For WORKSPACE Go usage, pin both repositories at the same revision:

- `datadog-rules-test-optimization` for sync and uploader rules
- `datadog-rules-test-optimization-go` for `dd_topt_go_test`

Load the Go macro from `@datadog-rules-test-optimization-go//:topt_go_test.bzl`,
not from the root repository.

### Archive mirror installation

If your environment requires `http_archive`, use an internal mirror and pin all
three values (`urls`, `strip_prefix`, and `sha256`):

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "datadog-rules-test-optimization",
    urls = [
        "https://artifacts.example.internal/bazel-mirror/datadog/rules_test_optimization/<commit-sha>.tar.gz",
    ],
    # Match your mirrored archive layout. For commit archives this is typically:
    # "rules_test_optimization-<full_commit_sha>".
    strip_prefix = "rules_test_optimization-<commit-sha>",
    sha256 = "<sha256-for-archive>",
)
```

If your mirror repackages archives, adjust `strip_prefix` to the archive's
actual top-level directory.

### 2) Instantiate the repository rule in `WORKSPACE`

```bzl
load("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")

test_optimization_sync(
    name = "test_optimization_data",
    service = "my-service",  # recommended; otherwise falls back to DD_SERVICE or unnamed-service
    # Optional:
    # runtime_name = "go",
    # runtime_version = "1.25.0",
    # known_tests = True,
    # test_management = True,
)
```

### 3) Depend on generated files in BUILD files

```bzl
filegroup(
    name = "dd_test_opt_files",
    srcs = ["@test_optimization_data//:test_optimization_files"],
)

filegroup(
    name = "dd_test_opt_context",
    srcs = ["@test_optimization_data//:test_optimization_context"],
)
```

### 4) Add the uploader target (one per workspace)

```bzl
# In root BUILD.bazel
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    # Provide context.json via runfiles so enrichment can occur
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

Multi-service aggregator variant:

```bzl
dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_service_a",
        "@test_optimization_data//:test_optimization_context_service_b",
    ],
)
```

### 5) Forward environment variables in `.bazelrc`

```text
# Repository rule (module/repo phase) — affects refetch
common --repo_env=DD_API_KEY
common --repo_env=DD_SITE
common --repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL  # Optional shared direct URL override for sync + uploader agentless path (test/dev)
common --repo_env=DD_TEST_OPTIMIZATION_HTTP_CONNECT_TIMEOUT_SECONDS  # Optional sync HTTP connect-timeout override
common --repo_env=DD_TEST_OPTIMIZATION_HTTP_MAX_TIME_SECONDS         # Optional sync HTTP max-time override
common --repo_env=DD_TEST_OPTIMIZATION_HTTP_RETRY_ATTEMPTS           # Optional sync HTTP retry-attempt override
common --repo_env=DD_TEST_OPTIMIZATION_HTTP_RETRY_DELAY_SECONDS      # Optional sync HTTP retry-delay override
common --repo_env=DD_TEST_OPTIMIZATION_HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS  # Optional sync execute-timeout buffer override
common --repo_env=DD_SERVICE
common --repo_env=DD_ENV
common --repo_env=DD_GIT_REPOSITORY_URL
common --repo_env=DD_GIT_BRANCH
common --repo_env=DD_GIT_TAG
common --repo_env=DD_GIT_COMMIT_SHA
common --repo_env=DD_GIT_HEAD_COMMIT
common --repo_env=DD_GIT_COMMIT_MESSAGE
common --repo_env=DD_GIT_HEAD_MESSAGE
common --repo_env=DD_GIT_COMMIT_AUTHOR_NAME
common --repo_env=DD_GIT_COMMIT_AUTHOR_EMAIL
common --repo_env=DD_GIT_COMMIT_AUTHOR_DATE
common --repo_env=DD_GIT_COMMIT_COMMITTER_NAME
common --repo_env=DD_GIT_COMMIT_COMMITTER_EMAIL
common --repo_env=DD_GIT_COMMIT_COMMITTER_DATE
common --repo_env=DD_GIT_HEAD_AUTHOR_NAME
common --repo_env=DD_GIT_HEAD_AUTHOR_EMAIL
common --repo_env=DD_GIT_HEAD_AUTHOR_DATE
common --repo_env=DD_GIT_HEAD_COMMITTER_NAME
common --repo_env=DD_GIT_HEAD_COMMITTER_EMAIL
common --repo_env=DD_GIT_HEAD_COMMITTER_DATE
common --repo_env=DD_GIT_PR_BASE_BRANCH
common --repo_env=DD_GIT_PR_BASE_BRANCH_SHA
common --repo_env=DD_GIT_PR_BASE_BRANCH_HEAD_SHA
common --repo_env=DD_PR_NUMBER
# Optional: override detected Go module path for export.bzl
common --repo_env=GO_MODULE_PATH
# Optional: provide Python module path hint for export.bzl
common --repo_env=PYTHON_MODULE_PATH
# Optional: provide Java module path hint for export.bzl
common --repo_env=JAVA_MODULE_PATH
# Optional: provide NodeJS module path hint for export.bzl
common --repo_env=NODEJS_MODULE_PATH
# Optional: provide .NET module path hint for export.bzl
common --repo_env=DOTNET_MODULE_PATH
# Optional: provide Ruby module path hint for export.bzl
common --repo_env=RUBY_MODULE_PATH
# Optional: force refetch once (example)
# common --repo_env=FETCH_SALT=<timestamp>

# Uploader (bazel run, pass credentials inline or export before run)
# DD_API_KEY and DD_SITE are passed when running the uploader:
#   DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads
# PowerShell equivalent:
#   # Set once per shell session before first run:
#   # $env:DD_API_KEY = "<your-api-key>"
#   # $env:DD_SITE = "datadoghq.com"
#   bazel run //:dd_upload_payloads

# Tests (runtime)
# Keep uploader credentials out of test runtime by default.
test --test_env=DD_TEST_OPTIMIZATION_AGENT_URL
test --test_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL  # Optional override for intake base URL (agentless only, test/dev)
```

Security note: keep secret values out of `.bazelrc`. Forward variable names
with `--repo_env=DD_API_KEY` and provide values via shell/CI secret stores.
In Bazel file-mode workflows, tests do not require `DD_API_KEY`/`DD_SITE`;
those credentials are only needed for the post-test uploader step.

Git metadata note: wrappers in this repository and the sibling fixture repo can
fill in current commit author and committer fields automatically when a CI
provider does not expose them. Explicit `DD_GIT_*` values still win over both
provider-derived metadata and wrapper synthesis.

Repository policy note: this repository intentionally has no root `.bazelrc`.
Consumer repos should keep their own `.bazelrc` and follow CI-maintainer flags
from `README.md` and `docs/Maintainers.md`.

### 6) Configure Go support in WORKSPACE with the Go companion repository

This is the lower-level/manual setup path. For Bzlmod single-service Go
workspaces, prefer guided bootstrap instead.

If your repository already configures an Orchestrion-enabled `rules_go` fork or
consumer-owned merge, keep that setup and skip to the companion-repo and BUILD
snippets below.

First, add the Go companion repository. For a local checkout:

```bzl
load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

local_repository(
    name = "datadog-rules-test-optimization-go",
    path = "/absolute/path/to/rules_test_optimization/modules/go",
    repo_mapping = {
        "@rules_go": "@io_bazel_rules_go",
    },
)
```

For mirrored archives, publish the `modules/go` subtree as the repository root:

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "datadog-rules-test-optimization-go",
    urls = [
        "https://artifacts.example.internal/bazel-mirror/datadog/rules_test_optimization/<commit-sha>.tar.gz",
    ],
    strip_prefix = "rules_test_optimization-<commit-sha>/modules/go",
    sha256 = "<go_companion_sha256>",
    repo_mapping = {
        "@rules_go": "@io_bazel_rules_go",
    },
)
```

Then configure an Orchestrion-enabled `rules_go` fork and the public WORKSPACE
Orchestrion helper. The repository bound to `@io_bazel_rules_go` must be the
forked, Orchestrion-enabled copy, not an upstream release archive. If you are
mirroring this repository directly, publish the
`third_party/rules_go_orchestrion` subtree as the `@io_bazel_rules_go`
repository root. If you maintain your own merged fork, keep the same public
files and labels, including `go/orchestrion_workspace.bzl` and the
`//go/private/orchestrion:*` targets, including the `:enabled` build setting
that `dd_topt_go_test` flips through its wrapper transition.

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "io_bazel_rules_go",
    urls = [
        "https://artifacts.example.internal/bazel-mirror/datadog/rules_test_optimization/<commit-sha>.tar.gz",
    ],
    strip_prefix = "rules_test_optimization-<commit-sha>/third_party/rules_go_orchestrion",
    sha256 = "<rules_go_sha256>",
)

http_archive(
    name = "bazel_gazelle",
    urls = [
        "https://github.com/bazelbuild/bazel-gazelle/releases/download/v0.39.1/bazel-gazelle-v0.39.1.tar.gz",
    ],
    sha256 = "<bazel_gazelle_sha256>",
)

load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")
load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies")
load("@io_bazel_rules_go//go:orchestrion_workspace.bzl", "go_orchestrion_tool_repo")

go_rules_dependencies()
go_register_toolchains(version = "1.25.0")
gazelle_dependencies()

go_orchestrion_tool_repo(
    version = "<orchestrion_version>",
    # Optional. When omitted, the helper uses the fork's current default
    # shared dd-trace-go version.
    dd_trace_go_version = "<resolved_dd_trace_go_version>",
)
```

Notes for the helper:

- `version` is required in WORKSPACE mode.
- `dd_trace_go_version` and `dd_trace_go_versions` are mutually exclusive.
- Keep the default tool-repo name `rules_go_orchestrion_tool`; the current fork
  resolves that name internally.

Then in your Go package `BUILD.bazel`:

```bzl
load("@io_bazel_rules_go//go:def.bzl", "go_library")
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

go_library(
    name = "pkg_lib",
    srcs = ["*.go"],
)

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],  # Enables provider-based importpath inference
    topt_data = topt_data,
)
```

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
`embedsrcs`. When enabled, it changes the default `rundir` to `.` only if the
caller did not already set `rundir`.

Note: in WORKSPACE mode, Go support uses two repositories:

- `datadog-rules-test-optimization` for the core rules
- `datadog-rules-test-optimization-go` for the Go companion

The repository bound to `@io_bazel_rules_go` must be an Orchestrion-enabled
`rules_go` fork or a consumer-owned merge that includes the Orchestrion
workspace helper. Add `repo_mapping = {"@rules_go": "@io_bazel_rules_go"}` on
the `datadog-rules-test-optimization-go` repository declaration so the Go
companion resolves that fork consistently.

Also note that Orchestrion-backed Go tests expect the local Go module files to
be pinned consistently for instrumentation. `dd_topt_go_test` auto-stages
package-local pin files when they live next to the BUILD file, but nested test
packages should pass the module-root labels explicitly through
`orchestrion_pin_files`, for example:

```bzl
dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],
    orchestrion_pin_files = [
        "//:go.mod",
        "//:go.sum",
        "//:orchestrion.tool.go",
        "//:orchestrion.yml",
    ],
    topt_data = topt_data,
)
```
