## Datadog Test Optimization for Bazel — Agent Guide

This repository provides Bazel integrations that fetch Datadog Test Optimization metadata and reliably upload test payloads (tests and coverage) even in hermetic/sandboxed builds. It is designed to work cross-platform (Linux/macOS/Windows) and with both Datadog Agent EVP proxy and agentless intake.

### Problems this solves

- Tests executed in hermetic sandboxes cannot call external networks to upload results to Datadog.
- CI/git/OS/runtime context must be consistent across the pipeline and available to consumers that need it at different phases.

This repo addresses these by:
- Fetching server-side metadata during Bazel module/repo resolution (outside the test sandbox).
- Generating a non-secret `context.json` with CI, git, OS, and runtime tags that can be consumed at test runtime.
- Providing a test rule that waits for test payloads, enriches them with `context.json`, and uploads them to Datadog within the same `bazel test` invocation.

---

## Architecture overview

There are two main building blocks:

1) Repository rule and module extension (tools/test_optimization_sync.bzl)
- What it does
  - Runs during module/repo resolution (outside test sandbox).
  - Detects CI/git/OS/runtime context from environment (provider-aware) and user overrides.
  - Calls Datadog endpoints to download metadata (settings, known tests, test management), writing JSON outputs.
  - Produces `context.json` with a comprehensive, non-secret set of tags to reuse at runtime.
  - Emits public filegroups in the generated external repo:
    - `test_optimization_files`: all downloaded JSON files (also includes per-module known-tests files)
    - `test_optimization_context`: the `context.json` file
    - One per-module group for Known Tests: `known_tests_module_<sanitized_module>`

- Outputs (file names fixed under `out_dir`):
  - `settings.json`
  - `knowntests.json`
  - `tmtests.json`
  - `context.json` (non-secret CI/Git/OS/runtime tags)
  - Per-module Known Tests: `knowntests.module.<sanitized_module>.json` (one per module key)

- Endpoints used (agent APIs under `api.<DD_SITE>`):
  - Settings: `https://api.<DD_SITE>/api/v2/libraries/tests/services/setting`
  - Known Tests: `https://api.<DD_SITE>/api/v2/ci/libraries/tests`
  - Test Management Tests: `https://api.<DD_SITE>/api/v2/test/libraries/test-management/tests`

2) Runtime uploader test rule (tools/test_optimization_uploader_test.bzl)
- What it does
  - Runs as a normal Bazel test target in the same `bazel test` invocation.
  - Watches a shared writable directory for payloads produced by other tests, waits for a quiescent period, then uploads.
  - Enriches test payload JSON with tags from `context.json` under `metadata.*`.
  - Uploads test payloads to CI Test Cycle intake; uploads coverage payloads as multipart form to coverage intake.
  - Cross-platform:
    - Linux/macOS: bash + curl; enrichment via `jq` when available.
    - Windows: PowerShell + .NET HttpClient; enrichment via `ConvertFrom-Json`.

- Upload paths per dd-trace-go:
  - Agentless (requires `DD_API_KEY`):
    - Tests: `https://citestcycle-intake.<DD_SITE>/api/v2/citestcycle`
    - Coverage: `https://citestcov-intake.<DD_SITE>/api/v2/citestcov`
  - EVP proxy (when `DD_TRACE_AGENT_URL` is set):
    - Tests: `${DD_TRACE_AGENT_URL}/evp_proxy/v2/api/v2/citestcycle` with header `X-Datadog-EVP-Subdomain: citestcycle-intake`
    - Coverage: `${DD_TRACE_AGENT_URL}/evp_proxy/v2/api/v2/citestcov` with header `X-Datadog-EVP-Subdomain: citestcov-intake`

Reference implementations in dd-trace-go:
- CI Test Cycle transport and headers: [civisibility_transport.go](https://raw.githubusercontent.com/DataDog/dd-trace-go/refs/heads/main/ddtrace/tracer/civisibility_transport.go)
- Coverage client: [coverage.go](https://raw.githubusercontent.com/DataDog/dd-trace-go/refs/heads/main/internal/civisibility/utils/net/coverage.go)
- Tag constants: [git.go](https://raw.githubusercontent.com/DataDog/dd-trace-go/refs/heads/main/internal/civisibility/constants/git.go), [ci.go](https://raw.githubusercontent.com/DataDog/dd-trace-go/refs/heads/main/internal/civisibility/constants/ci.go), [os.go](https://raw.githubusercontent.com/DataDog/dd-trace-go/refs/heads/main/internal/civisibility/constants/os.go), [runtime.go](https://raw.githubusercontent.com/DataDog/dd-trace-go/refs/heads/main/internal/civisibility/constants/runtime.go)

---

## Data flow (end-to-end)

1. Module resolution fetches server metadata and writes JSON files and `context.json`.
2. Tests run and write Datadog CI payloads (JSON) under a shared writable directory:
   - `$DD_PAYLOADS_DIR/tests/*.json`
   - `$DD_PAYLOADS_DIR/coverage/*.json`
3. The uploader test waits until the directory is idle for `quiescent_sec`, then starts uploading.
4. Before uploading tests payloads, the uploader merges `context.json` into `metadata.*`.
5. Uploads test payloads to CI Test Cycle intake; uploads coverage as multipart `event` + `coveragex`.

---

## Setup and usage

### 1) Add the sync extension in MODULE.bazel

```bzl
test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)

test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
    # Optional runtime fields; can be omitted
    # runtime_name = "go",
    # runtime_version = "go1.22",
)

use_repo(test_optimization_sync, "test_optimization_data")
```

In your BUILD files, you can depend on the generated filegroups:

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

### Alternative: WORKSPACE mode

If you use legacy WORKSPACE mode instead of Bzlmod, load the repository rule directly and instantiate it in `WORKSPACE`:

```bzl
load("@datadog_rules_test_optimization//tools:test_optimization_sync.bzl", "test_optimization_sync")

test_optimization_sync(
    name = "test_optimization_data",
    # Optional:
    # service = "my-service",
    # runtime_name = "go",
    # runtime_version = "go1.22",
)
```

You can also use the helper to install with sensible defaults:

```bzl
load("@datadog_rules_test_optimization//tools:repositories.bzl", "dd_test_opt_repositories")

dd_test_opt_repositories(name = "test_optimization_data")
```

### 2) Configure a shared payloads directory and pass it to tests

Tests should write JSON payloads to a real filesystem path outside the sandbox. Recommended:
- CLI flags for `bazel test`:
  - `--sandbox_writable_path=$PWD/.testoptimization/payloads`
  - `--test_env=DD_PAYLOADS_DIR=$PWD/.testoptimization/payloads`

Expected tree:
```
<workspace>/.testoptimization/payloads/
  tests/     # CI Test Cycle JSON payloads
  coverage/  # Coverage JSON payloads
```

### 3) Add the uploader test target

```bzl
load("@datadog-rules-test-optimization//tools:test_optimization_uploader_test.bzl", "dd_payload_uploader_test")

dd_payload_uploader_test(
    name = "dd_upload_payloads",
    payloads_dir = "$(execroot)/.testoptimization/payloads",  # or rely on $DD_PAYLOADS_DIR
    tests_subdir = "tests",
    coverage_subdir = "coverage",
    quiescent_sec = 10,
    max_wait_sec = 1800,
    fail_on_error = False,
    data = ["@test_optimization_data//:test_optimization_context"],  # bring context.json into runfiles
)
```

Run with your tests:

```bash
bazel test //... //tools:dd_upload_payloads \
  --sandbox_writable_path=$PWD/.testoptimization/payloads \
  --test_env=DD_PAYLOADS_DIR=$PWD/.testoptimization/payloads
```

### Endpoints, headers, and behavior

- Agentless (when `DD_TRACE_AGENT_URL` is unset):
  - Tests: `https://citestcycle-intake.<DD_SITE>/api/v2/citestcycle`
  - Coverage: `https://citestcov-intake.<DD_SITE>/api/v2/citestcov`
  - Requires `DD_API_KEY`
- EVP proxy (when `DD_TRACE_AGENT_URL` is set):
  - Tests: `${DD_TRACE_AGENT_URL}/evp_proxy/v2/api/v2/citestcycle` with `X-Datadog-EVP-Subdomain: citestcycle-intake`
  - Coverage: `${DD_TRACE_AGENT_URL}/evp_proxy/v2/api/v2/citestcov` with `X-Datadog-EVP-Subdomain: citestcov-intake`
- Requests include `Accept: application/json`. Test uploads set `Content-Type: application/json`.
- Coverage uploads are multipart with two parts: `event` and `coveragex`.

### Convenience macro: dd_topt_go_test

Replace a `go_test` with a single label that runs both the Go test and the uploader. This macro creates:
- `<name>_go`: underlying `go_test`
- `<name>_dd_upload_payloads`: uploader test
- `<name>`: a `test_suite` including both

Bzlmod:

```bzl
load("@datadog-rules-test-optimization//tools:topt_go_test.bzl", "dd_topt_go_test")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    # Optional overrides if you used a different repo name:
    # context_label = "@test_optimization_data//:test_optimization_context",
    # files_label = "@test_optimization_data//:test_optimization_files",
    # quiescent_sec = 10,
    # max_wait_sec = 1800,
    # fail_on_error = False,
)
```

WORKSPACE:

```bzl
load("@datadog_rules_test_optimization//tools:topt_go_test.bzl", "dd_topt_go_test")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
)
```

---

## Environment forwarding (.bazelrc)

- Repository rule (module/repo phase) reads env via `--repo_env` (affects re-fetching):
```bash
common --repo_env=DD_API_KEY
common --repo_env=DD_SITE
common --repo_env=DD_SERVICE
common --repo_env=DD_ENV
common --repo_env=DD_GIT_REPOSITORY_URL
common --repo_env=DD_GIT_BRANCH
common --repo_env=DD_GIT_COMMIT_SHA
common --repo_env=DD_GIT_HEAD_COMMIT
common --repo_env=DD_GIT_COMMIT_MESSAGE
common --repo_env=DD_GIT_HEAD_MESSAGE
# Optional TTL: common --repo_env=FETCH_SALT
```

- Tests (runtime) receive env via `--test_env`:
```bash
test --test_env=DD_API_KEY
test --test_env=DD_SITE
test --test_env=DD_TRACE_AGENT_URL
test --test_env=DD_PAYLOADS_DIR
```

Do not write secrets (like `DD_API_KEY`) to files; keep them in env only.

---

## Wrapper script (`bazelw`)

This repo ships a `bazelw` wrapper that forwards computed Git metadata via `--repo_env` for you and supports a TTL for refetches.

Examples:

```bash
# Auto-forward Git repository URL, branch, SHA, and commit message
./bazelw build //...

# Force a refresh every hour
FETCH_SALT_TTL=3600 ./bazelw test //...

# Override computed Git values
DD_GIT_REPOSITORY_URL=https://github.com/acme/api.git \
DD_GIT_BRANCH=main \
DD_GIT_COMMIT_SHA=$(git rev-parse HEAD) \
./bazelw test //...
```

Precedence: any `DD_GIT_*` you export will override what `bazelw` computes.

## `context.json` content

`context.json` aggregates non-secret tags from CI/git/OS/runtime to enrich payloads. Keys include (examples, presence depends on env):

- OS: `os.platform`, `os.version`, `os.architecture`
- Runtime: `runtime.name`, `runtime.version`, `runtime.architecture`
- Git (subset): `git.repository_url`, `git.branch`, `git.commit.sha`, `git.commit.message`, `git.commit.head.sha`, `git.commit.head.message`, `git.tag`, author/committer fields, PR base fields, `pr.number`
- Service/environment: `service.name`, `env`
- CI: `ci.provider.name`, `ci.workspace_path`, `ci.pipeline.id`, `ci.pipeline.number`, `ci.pipeline.url`, `ci.pipeline.name`, `ci.job.id`, `ci.job.name`, `ci.job.url`, `ci.stage.name`, `ci.node.name`, `ci.node.labels`

The uploader merges every non-null top-level key from `context.json` into `metadata.*` of test payloads.

Tag constants reference:
- Git: [git.go](https://raw.githubusercontent.com/DataDog/dd-trace-go/refs/heads/main/internal/civisibility/constants/git.go)
- CI: [ci.go](https://raw.githubusercontent.com/DataDog/dd-trace-go/refs/heads/main/internal/civisibility/constants/ci.go)
- OS: [os.go](https://raw.githubusercontent.com/DataDog/dd-trace-go/refs/heads/main/internal/civisibility/constants/os.go)
- Runtime: [runtime.go](https://raw.githubusercontent.com/DataDog/dd-trace-go/refs/heads/main/internal/civisibility/constants/runtime.go)

---

## Cross-platform behavior

- Linux/macOS
  - Uses bash + curl; jq for JSON enrichment (uploads as-is if jq is absent).
- Windows
  - Uses PowerShell + .NET HttpClient; enriches from `context.json` via `ConvertFrom-Json`.

---

## Failure handling and knobs

- `quiescent_sec` (default 10): directory idle window before upload starts.
- `max_wait_sec` (default 1800): maximum time to wait before uploading anyway.
- `fail_on_error` (default False): if True, the uploader test fails on upload errors; otherwise it logs and continues.

---

## Security and privacy

- `context.json` contains non-secret context only.
- `DD_API_KEY` and similar secrets are never written to disk; they are used as environment variables.
- Prefer passing env names in `.bazelrc` and values at runtime via CI.

---

## Troubleshooting

- No uploads happening
  - Verify tests wrote JSON payloads under `$DD_PAYLOADS_DIR/{tests,coverage}`.
  - Check `quiescent_sec` and `max_wait_sec` settings; logs show when upload begins.
  - Ensure network is allowed; add `requires-network`-style tags in your environment if necessary.

- Missing enrichment
  - Confirm `data = ["@test_optimization_data//:test_optimization_context"]` is set on the uploader target.
  - On Linux/macOS, ensure `jq` is present (otherwise upload proceeds without merging `context.json`).

- Agentless errors
  - Ensure `DD_API_KEY` is forwarded via `--test_env` and `DD_SITE` is correct.

---

## File map (key files in this repo)

- `tools/test_optimization_sync.bzl`
  - Repository rule + module extension
  - HTTP to Datadog, CI/git/OS/runtime detection, writes JSON outputs + `context.json`
  - Exposes `test_optimization_files` and `test_optimization_context` filegroups

- `tools/test_optimization_uploader_test.bzl`
  - `dd_payload_uploader_test` test rule
  - Waits for payloads, enriches from `context.json`, uploads to Datadog
  - Cross-platform implementation

- `tools/topt_go_test.bzl`
  - `dd_topt_go_test` macro for Go: wraps `go_test` + uploader into a `test_suite`

- `tools/repositories.bzl`
  - WORKSPACE helper `dd_test_opt_repositories` to install the sync repo

- `README.md`
  - Usage examples for both fetching and uploading flows

---

## At-a-glance commands

```bash
# Run tests and uploader in one go
bazel test //... //tools:dd_upload_payloads \
  --sandbox_writable_path=$PWD/.testoptimization/payloads \
  --test_env=DD_PAYLOADS_DIR=$PWD/.testoptimization/payloads
```


