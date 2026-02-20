# Installation Reference

This page contains full installation and setup flows. For fast onboarding, use
the scenario quickstarts in `README.md`.

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
bazel_dep(name = "rules_go", version = "0.59.0")
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
does not declare `rules_go`. Go-specific orchestration lives in the companion
module `datadog-rules-test-optimization-go`, which depends on `rules_go` for
provider types only (toolchains are still configured by consumers).

### Go companion module

If you use the Go convenience macro, load it from the companion module:

```bzl
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
```

### Core-only consumer (no Go companion)

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
    services = ["go-service", "ruby-service"],
    runtime_name = "go",
    runtime_version = "1.24.0",
    debug = True,
)

use_repo(
    topt_multi,
    # Aggregator repo
    "test_optimization_data",
    # Per-service repos (auto-created, names include sanitized service key)
    "test_optimization_data_go_service",
    "test_optimization_data_ruby_service",
)

# Consuming labels (aggregator):
#  - All files for one service
#    @test_optimization_data//:test_optimization_files_go_service
#  - One module for one service (service + module label in the aggregator repo)
#    @test_optimization_data//:module_go_service_core
# Per-service repos are primarily used for per-service exports like:
#   load("@test_optimization_data_go_service//:export.bzl", "topt_data")

# Macros that expect "topt_data" can use either:
# 1) Select explicitly:
#    load("@test_optimization_data//:export.bzl", "topt_data_by_service")
#    dd_topt_go_test(..., topt_data = topt_data_by_service["go_service"], go_test_rule = go_test)
# 2) Pass the mapping and choose via topt_service (keeps BUILD simpler):
#    dd_topt_go_test(..., topt_data = topt_data_by_service, topt_service = "go_service", go_test_rule = go_test)
#    When service names sanitize to the same key, pass the deduped key shown in
#    the available list (for example "go_service_2").
```

Additional helper file exported by the generated repository:

- `export.bzl` with a single dictionary `topt_data` containing:
  - `repo_name`: external repository name created by the sync rule (for example,
    `test_optimization_data`)
  - `manifest_path`: path to `manifest.txt` inside the generated repo
  - `labels`: list of available per-module sanitized labels
  - `set`: dict-as-set keyed by sanitized labels for fast membership checks
  - `runtimes["go"]`: nested object with:
    - `module_path`: detected Go module path (may be empty)
    - `sanitized_module_path`: sanitized label fragment for `module_path`
    - `module_included`: boolean; true when the detected Go module has a
      matching per-module filegroup

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
For WORKSPACE Go macro usage, ensure the selected commit includes
`modules/go/topt_go_test.bzl`.

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
    # runtime_version = "1.24.0",
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
        "@test_optimization_data//:test_optimization_context_go_service",
        "@test_optimization_data//:test_optimization_context_ruby_service",
    ],
)
```

### 5) Forward environment variables in `.bazelrc`

```text
# Repository rule (module/repo phase) — affects refetch
common --repo_env=DD_API_KEY
common --repo_env=DD_SITE
common --repo_env=DD_TEST_OPTIMIZATION_API_BASE  # Optional override for Datadog API base URL (test/dev)
common --repo_env=DD_TEST_OPTIMIZATION_HTTP_CONNECT_TIMEOUT_SECONDS  # Optional sync HTTP connect-timeout override
common --repo_env=DD_TEST_OPTIMIZATION_HTTP_MAX_TIME_SECONDS         # Optional sync HTTP max-time override
common --repo_env=DD_TEST_OPTIMIZATION_HTTP_RETRY_ATTEMPTS           # Optional sync HTTP retry-attempt override
common --repo_env=DD_TEST_OPTIMIZATION_HTTP_RETRY_DELAY_SECONDS      # Optional sync HTTP retry-delay override
common --repo_env=DD_TEST_OPTIMIZATION_HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS  # Optional sync execute-timeout buffer override
common --repo_env=DD_SERVICE
common --repo_env=DD_ENV
common --repo_env=DD_GIT_REPOSITORY_URL
common --repo_env=DD_GIT_BRANCH
common --repo_env=DD_GIT_COMMIT_SHA
common --repo_env=DD_GIT_HEAD_COMMIT
common --repo_env=DD_GIT_COMMIT_MESSAGE
common --repo_env=DD_GIT_HEAD_MESSAGE
# Optional: override detected Go module path for export.bzl
common --repo_env=GO_MODULE_PATH
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
test --test_env=DD_TRACE_AGENT_URL
test --test_env=DD_TEST_OPTIMIZATION_INTAKE_BASE  # Optional override for intake base URL (agentless only, test/dev)
```

Security note: keep secret values out of `.bazelrc`. Forward variable names
with `--repo_env=DD_API_KEY` and provide values via shell/CI secret stores.
In Bazel file-mode workflows, tests do not require `DD_API_KEY`/`DD_SITE`;
those credentials are only needed for the post-test uploader step.

Repository policy note: this repository intentionally has no root `.bazelrc`.
Consumer repos should keep their own `.bazelrc` and follow CI-maintainer flags
from `README.md` and `docs/Maintainers.md`.

### 6) Configure Go support in WORKSPACE (for `dd_topt_go_test`)

If your repository already configures `rules_go`, keep your existing setup and
skip to the BUILD snippet below.

In `WORKSPACE`:

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "io_bazel_rules_go",
    urls = [
        "https://github.com/bazelbuild/rules_go/releases/download/v0.59.0/rules_go-v0.59.0.zip",
    ],
    sha256 = "<rules_go_sha256>",
)

http_archive(
    name = "bazel_gazelle",
    urls = [
        "https://github.com/bazelbuild/bazel-gazelle/releases/download/v0.39.0/bazel-gazelle-v0.39.0.tar.gz",
    ],
    sha256 = "<bazel_gazelle_sha256>",
)

load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")
go_rules_dependencies()
go_register_toolchains(version = "1.24.0")

load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies")
gazelle_dependencies()
```

Then in your Go package `BUILD.bazel`:

```bzl
load("@io_bazel_rules_go//go:def.bzl", "go_library", "go_test")
load("@datadog-rules-test-optimization//modules/go:topt_go_test.bzl", "dd_topt_go_test")
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
    go_test_rule = go_test,
)
```

Note: in WORKSPACE mode for this repository, use the canonical repository name
`datadog-rules-test-optimization` so companion Go loads resolve consistently.
