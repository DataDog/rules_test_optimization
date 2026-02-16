# Datadog Test Optimization Bazel Module Extension

This repository provides Bazel integrations that fetch Datadog Test Optimization metadata during module/repository resolution and materialize JSON files for use in your build. It also generates public filegroups so consumers can depend on stable labels instead of wiring files manually.

## Documentation map

- `README.md` (this file): setup, usage, runtime behavior, and troubleshooting
- `docs/Initial_documentation.md`: architecture and data-flow deep dive
- `docs/RFC.md`: design rationale, trade-offs, and historical proposal context
- `examples/README.md`: copy/paste snippets for single-service and multi-service setup

## Requirements

- **Bazel 5.0+** - Required for `TEST_UNDECLARED_OUTPUTS_DIR` support used by payload collection
- **Tracer/runtime with DD Test Optimization file-mode support** - Must honor `DD_TEST_OPTIMIZATION_MANIFEST_FILE` and `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES`
- **rules_go v0.51.0+** (for Go importpath inference) - This repository reads `GoInfo`/`GoArchive` providers when selecting per-module payloads
- **DD_SITE format** - Accepts bare host, app/api-prefixed host, or full URL; normalized to `https://api.<site>`
- **Uploader tooling (per platform)** - Required for `bazel run //:dd_upload_payloads`
  - **Linux**: `bash`, `curl`, `find`, `stat` (GNU), `awk`, and one of `md5sum` or `shasum`
  - **macOS**: `bash` (3.2+), `curl`, `find`, `stat` (BSD), `awk`, and one of `md5` or `shasum`
  - **Windows**: `powershell.exe` (Windows PowerShell 5.1+ or PowerShell 7+); the uploader uses .NET `HttpClient`

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
# provided by the dd_topt_go_test macro (see tools/go/topt_go_test.bzl).
```

## Installation (Bzlmod)

In your `MODULE.bazel`:

```bzl
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")

# Optional: develop locally
local_path_override(
    module_name = "datadog-rules-test-optimization",
    path = "/absolute/path/to/datadog-rules-test-optimization",
)

test_optimization_sync = use_extension("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync_extension")

# Minimal usage: defaults to writing under .testoptimization and creating the filegroup
test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
)

use_repo(test_optimization_sync, "test_optimization_data")
```

Note: This module declares a dependency on `rules_go` solely to load provider definitions for Go importpath inference. It does not configure any Go toolchains. Consumers still need to set up `rules_go` and the Go SDK as usual to build and run Go targets.

### Planned split for optional `rules_go`

The current module keeps `rules_go` as a repository dependency because Go
orchestration lives in-tree (`//tools/go:*`). A planned follow-up split is:

- core module/package: sync + uploader + shared orchestration helpers (no `rules_go` dependency)
- Go companion module/package: Go macro/aspect/selector (`dd_topt_go_test`) with `rules_go` dependency

This would let non-Go consumers depend only on the core module while Go users
add the Go companion module explicitly.

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
    runtime_version = "1.24",
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
#  - One module for one service (module label sanitized by the single-service repo)
#    @test_optimization_data//:module_go_service_core

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
  - `repo_name`: external repository name created by the sync rule (e.g., `test_optimization_data`)
  - `manifest_path`: path to `manifest.txt` inside the generated repo (defaults to `.testoptimization/manifest.txt`, respects `out_dir`)
  - `labels`: list of available per-module sanitized labels
  - `set`: dict-as-set keyed by sanitized labels for fast membership checks
  - `runtimes["go"]`: nested object with:
    - `module_path`: detected Go module path (may be empty)
    - `sanitized_module_path`: sanitized label fragment for `module_path`
    - `module_included`: boolean; true when the detected Go module has a matching per-module filegroup. The `dd_topt_go_test` macro uses this flag only when falling back to `<module_path>/<bazel package>`; it is ignored when `importpath` is inferred via `embed` or explicitly provided.

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

## Installation (WORKSPACE)

If your project uses legacy WORKSPACE mode instead of Bzlmod, use the repository rule directly.

### 1) Add this repository in `WORKSPACE`

```bzl
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")

git_repository(
    name = "datadog_rules_test_optimization",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "3107bb94a9adbc6523cfe90901824ca2e7b6a6d2",
)

# Or:
# local_repository(
#     name = "datadog_rules_test_optimization",
#     path = "/absolute/path/to/rules_test_optimization",
# )
```

Use a commit or release tag that exists in this repository and keep it up to date with your dependency policy.

If your environment requires `http_archive`, use an internal mirror and pin all three
values (`urls`, `strip_prefix`, and `sha256`). Example format:

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "datadog_rules_test_optimization",
    urls = [
        "https://artifacts.example.internal/bazel-mirror/datadog/rules_test_optimization/3107bb94a9adbc6523cfe90901824ca2e7b6a6d2.tar.gz",
    ],
    strip_prefix = "rules_test_optimization-3107bb94a9adbc6523cfe90901824ca2e7b6a6d2",
    sha256 = "<internal-mirror-sha256>",
)
```

If your mirror repackages archives, adjust `strip_prefix` to the archive's actual top-level directory.

### 2) Instantiate the repository rule in `WORKSPACE`

```bzl
load("@datadog_rules_test_optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")

test_optimization_sync(
    name = "test_optimization_data",
    # Optional:
    # service = "my-service",
    # runtime_name = "go",
    # runtime_version = "go1.22",
    # known_tests = True,
    # test_management = True,
)
```

### 3) Depend on the generated files in BUILD files

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

### 4) Add the uploader target (ONE per workspace)

Create a single uploader target at your workspace root:

```bzl
# In root BUILD.bazel
load("@datadog_rules_test_optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    # Provide context.json via runfiles so enrichment can occur
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

### 5) Forward environment variables in `.bazelrc`

```bash
# Repository rule (module/repo phase) — affects refetch
common --repo_env=DD_API_KEY
common --repo_env=DD_SITE
common --repo_env=DD_TEST_OPTIMIZATION_API_BASE  # Optional override for Datadog API base URL (test/dev)
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
# Optional TTL: common --repo_env=FETCH_SALT

# Uploader (bazel run, pass credentials inline or export before run)
# DD_API_KEY and DD_SITE are passed when running the uploader:
#   DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads

# Tests (runtime)
test --test_env=DD_API_KEY
test --test_env=DD_SITE
test --test_env=DD_TRACE_AGENT_URL
test --test_env=DD_TEST_OPTIMIZATION_INTAKE_BASE  # Optional override for intake base URL (agentless only, test/dev)
```

Security note: keep secret *values* out of `.bazelrc`. Forward variable names with
`--repo_env=DD_API_KEY` and provide values via your shell/CI secret store at runtime.

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

**IMPORTANT**: Always preserve the test exit code! Using plain `;` causes CI to report success even when tests fail.

### Add the uploader target

```bzl
# In BUILD.bazel at workspace root
load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    # Provide context.json via runfiles so enrichment can occur
    data = ["@test_optimization_data//:test_optimization_context"],
    # Optional settings:
    # quiescent_sec = 10,      # Wait for filesystem to settle (default: 10)
    # max_wait_sec = 300,      # Max wait before proceeding (default: 300)
    # fail_on_error = False,   # Fail if no payloads found when tests ran
    # debug = False,           # Enable debug logging
    # gzip_payloads = False,   # Gzip test payloads before upload
)
```

### Upload modes

- **Agentless mode (default):** Requires `DD_API_KEY` and `DD_SITE`; uploads directly to Datadog intake
- **Agent/EVP mode:** Requires `DD_TRACE_AGENT_URL`; uploads via local agent or EVP proxy

### Passing credentials

```bash
# Option 1: Agentless mode - Inline (recommended for CI)
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads

# Option 2: Agent/EVP mode
DD_TRACE_AGENT_URL="http://localhost:8126" bazel run //:dd_upload_payloads

# Option 3: Export before run
export DD_API_KEY="your-api-key"
export DD_SITE="datadoghq.com"
bazel run //:dd_upload_payloads
```

### Exit codes

- `0` - All payloads uploaded successfully (or no payloads found)
- `1` - One or more uploads failed (partial success: successfully uploaded files are still deleted)
- `2` - Configuration error (invalid TESTLOGS_DIR, missing credentials, etc.)

### Optional environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `DD_TEST_OPTIMIZATION_KEEP_PAYLOADS` | `0` | Set to `1` to retain payloads after successful upload (for debugging/re-upload) |
| `DD_TEST_OPTIMIZATION_FILTER_PREFIX` | `0` | Set to `1` to only upload files matching `span_events_*.json` or `coverage_*.json` |
| `DD_TEST_OPTIMIZATION_DEBUG` | `0` | Set to `1` to enable verbose upload logging (HTTP codes, response bodies, startTime stats, and key runfile/CODEOWNERS resolution hits) |
| `DD_TEST_OPTIMIZATION_GZIP` | `0` | Set to `1` to gzip **test** payloads before upload (adds `Content-Encoding: gzip`) |
| `DD_TEST_OPTIMIZATION_MAX_WAIT_SEC` | `300` | Override max wait time for slow filesystems (NFS, network drives); set to `0` to skip waiting when no payloads are present |
| `DD_TEST_OPTIMIZATION_QUIESCENT_SEC` | `10` | Override quiescence wait time |
| `DD_TEST_OPTIMIZATION_MAX_DEPTH` | `0` (unlimited) | Limit `find` depth for large `bazel-testlogs` trees |
| `DD_TEST_OPTIMIZATION_CODEOWNERS_FILE` | auto | Explicit path to a CODEOWNERS file for enrichment fallback/discovery edge cases |
| `TESTLOGS_DIR` | auto | Explicit path to `bazel-testlogs` (for non-standard setups) |

### Endpoints and headers

- Agentless (when `DD_TRACE_AGENT_URL` unset):
  - Tests: `https://citestcycle-intake.<DD_SITE>/api/v2/citestcycle`
  - Coverage: `https://citestcov-intake.<DD_SITE>/api/v2/citestcov`
  - Requires `DD_API_KEY`
  - Test/dev override: set `DD_TEST_OPTIMIZATION_INTAKE_BASE` to use a custom base URL (agentless only)
- EVP proxy (when `DD_TRACE_AGENT_URL` set):
  - Base: `${DD_TRACE_AGENT_URL}/evp_proxy/v2/...`
  - Adds `X-Datadog-EVP-Subdomain` per endpoint
- Test payloads are JSON (msgpack not available in Starlark). Coverage is multipart with `event` and `coveragex` parts.

### Reliability

- HTTP requests use a 60-second timeout
- Failed requests are retried up to 3 times with a 2-second delay between attempts
- Both transient errors (connection issues) and HTTP errors (4xx/5xx) trigger retries
- Behavior is consistent across Linux/macOS (bash/curl) and Windows (PowerShell)

### Metadata enrichment (context.json)

- When `context.json` is present in runfiles (provided via the `data` attribute), the uploader enriches each test payload by merging all non-null keys from `context.json` into the payload under `metadata.*`.
- If `context.json` is not present (or if `jq` is unavailable on Unix), test payloads are uploaded as-is.
- The `context.json` file is produced by the sync extension and contains non-secret CI/Git/OS/runtime tags suitable for reuse at test time.
- Bazel rule identity is included as stable tags: `test.bazel.rule_name` and `test.bazel.rule_version`.
- `test`, `test_suite_end`, `test_module_end`, and `test_session_end` events are also enriched with `test.codeowners` when a source file can be resolved, owners are found, and the field is not already present.
- CODEOWNERS lookup order is: `<ci.workspace_path>/CODEOWNERS`, `<ci.workspace_path>/.github/CODEOWNERS`, `<ci.workspace_path>/.gitlab/CODEOWNERS`, `<ci.workspace_path>/docs/CODEOWNERS`, `<ci.workspace_path>/.docs/CODEOWNERS`, then `<workspace>/...` equivalents, then `./CODEOWNERS`, and finally `<script_dir>/CODEOWNERS`.
- Matching uses GitHub-style glob semantics with "last matching rule wins". The stored value is a JSON-array string (for example: `["@team/a","@team/b"]` as string content in `test.codeowners`).
- Absolute source paths outside repository-derived roots are ignored for CODEOWNERS fallback matching.
- CODEOWNERS enrichment is best-effort: parse/lookup failures and misses do not fail uploads; debug mode logs counters and skip reasons.

### Payload schema validation (best effort)

- Test payload schema validation runs only when all of the following are available in runfiles/environment: the bundled schema JSON, the validator script, and `python3`.
- If any validation dependency is unavailable, validation is skipped and uploads continue.
- If validation runs and fails, the uploader logs a warning and continues uploading.

### Test-time environment variables

The macro sets the following environment variables for instrumented tests:

- `DD_TEST_OPTIMIZATION_MANIFEST_FILE`: Runfile path to `manifest.txt` in the synced repo. The macro uses `topt_data["manifest_path"]` so custom `out_dir` values are supported. Libraries resolve this via Bazel runfiles and call `filepath.Dir()` to derive the directory containing synced files (`manifest.txt`, `context.json`, and `cache/http/*`).
- `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES`: Always set to `"true"`. Signals to the library that payloads should be written to `TEST_UNDECLARED_OUTPUTS_DIR`.

### Critical requirements

1. **Use `bazel run` (not `bazel test`)** - The uploader is a normal rule, not a test
2. **Use a SINGLE uploader target per workspace** - Do NOT run multiple uploaders concurrently (enforced via lock file)
3. **Tests must run locally OR use `--remote_download_outputs=all`** - Remote execution without downloading outputs leaves `bazel-testlogs/` empty
4. **Same workspace/machine requirement** - The uploader MUST run on the same machine and workspace where tests executed

## Convenience macro: dd_topt_go_test

The `dd_topt_go_test` macro simplifies setting up Go tests with Datadog Test Optimization. It creates a go_test target with the necessary environment variables and data dependencies.

By default, the macro also:
- Sets `rundir` to the current Bazel package when not explicitly provided

If tests read local fixtures (for example under `testdata/`), declare them explicitly in `data`:

```bzl
dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    data = glob(["testdata/**"]),
    topt_data = topt_data,
    go_test_rule = go_test,
)
```

## Adding a New Language Orchestration Module

Use this checklist when adding `dd_topt_<language>_test` support:

1. **Wrapper macro**
   - Add a language wrapper under `tools/<language>/` that accepts:
     - `name`
     - `topt_data` (single-service dict or multi-service mapping)
     - `topt_service` (optional for multi-service selection)
     - language test-rule symbol injection (similar to `go_test_rule`)
   - Ensure it appends selector + manifest labels to `data` and sets:
     - `DD_TEST_OPTIMIZATION_MANIFEST_FILE`
     - `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES = "true"`

2. **Selector / inference rule**
   - Add analysis-time selection logic in `tools/<language>/`:
     - precedence: explicit identifier -> inferred identifier -> fallback identifier -> full bundle
     - module label resolution should match `module_<sanitized>` names from sync outputs
   - Keep fallback-to-full-bundle behavior non-fatal.

3. **Runtime metadata keys**
   - Extend sync-exported runtime metadata under:
     - `topt_data["runtimes"]["<language>"]`
   - Keep core keys stable (`repo_name`, `manifest_path`, `labels`, `set`) and avoid changing generated public label names.

4. **Tests**
   - Add unit tests for:
     - macro service-selection and data/env wiring
     - selector precedence + fallback behavior
     - sync export shape for runtime metadata
   - Extend integration harness coverage if language runtime inference/selection adds new branches.

### Basic usage

```bzl
load("@rules_go//go:def.bzl", "go_library", "go_test")
load("@datadog-rules-test-optimization//tools/go:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

go_library(
    name = "pkg_lib",
    srcs = ["*.go"],
)

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],    # enables provider-based importpath inference
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

### Import path inference

The macro auto-selects the correct per-module payloads by inferring the Go package `importpath` using rules_go providers, mirroring how `go_test` computes it:

- Precedence:
  1) `importpath` explicitly set on your `go_test` invocation (if provided in kwargs)
  2) Inference via `embed = [":<go_library>"]` by reading `GoArchive.importpath` from rules_go (recommended)
  3) Fallback: `<go module path>/<bazel package>` where the Go module path comes from the synced repo's exported `topt_data["runtimes"]["go"]["module_path"]`

### Multi-service usage

```bzl
load("@rules_go//go:def.bzl", "go_test")
load("@datadog-rules-test-optimization//tools/go:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    topt_data = topt_data_by_service,   # pass mapping
    topt_service = "go_service",        # select service
    go_test_rule = go_test,
)
```

## Troubleshooting

### Repository rule not fetching data

**Symptom**: Build succeeds but test optimization files are empty or stale.

**Solutions**:

1. **Verify DD_API_KEY is set**:
   ```bash
   bazel info --repo_env | grep DD_API_KEY
   ```
   If not set, add to `.bazelrc`:
   ```
   common --repo_env=DD_API_KEY
   ```

2. **Force refetch** with a cache-busting salt:
   ```bash
   bazel sync --only=test_optimization_data --repo_env=FETCH_SALT=$(date +%s)
   ```

3. **Check repository cache** to see if the rule ran:
   ```bash
   # Find the external repository directory
   bazel info output_base
   # Repository contents at: $(bazel info output_base)/external/test_optimization_data
   ls -la $(bazel info output_base)/external/test_optimization_data/.testoptimization/
   ```

4. **Enable debug logging** in your `MODULE.bazel`:
   ```bzl
   test_optimization_sync.test_optimization_sync(
       name = "test_optimization_data",
       debug = True,  # Verbose logging
   )
   ```

### Uploader not finding payloads

**Symptom**: Uploader runs but says "no payload files found".

**Solutions**:

1. **Check if tests wrote payloads**:
   ```bash
   find bazel-testlogs -name "test.outputs" -type d
   ls bazel-testlogs/*/test.outputs/payloads/tests/
   ```

2. **Verify tracer support**: Ensure your tracer/runtime supports file mode via `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES` and manifest discovery via `DD_TEST_OPTIMIZATION_MANIFEST_FILE`

3. **Check DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES**: The macro should set this to "true". Verify your test's environment:
   ```bash
   bazel test //your:test --test_output=all 2>&1 | grep DD_TEST_OPTIMIZATION
   ```

4. **For RBE users**: Add `--remote_download_outputs=all` to download test outputs locally

### Non-standard bazel-testlogs location

**Symptom**: Uploader can't find `bazel-testlogs` directory.

**Solution**: Set `TESTLOGS_DIR` explicitly using the same Bazel flags:

```bash
# Bash - use array for multiple flags
BAZEL_FLAGS=("--output_base=/custom/base")
TESTLOGS_DIR=$(bazel "${BAZEL_FLAGS[@]}" info bazel-testlogs) bazel "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads
```

```powershell
# PowerShell
$BazelFlags = @("--output_base=/custom/base")
$env:TESTLOGS_DIR = (bazel @BazelFlags info bazel-testlogs)
bazel @BazelFlags run //:dd_upload_payloads
```

### Tests not uploading (network errors)

**Symptom**: Uploader fails with network errors.

**Solutions**:

1. **Verify credentials**:
   - Agentless mode requires: `DD_API_KEY`, `DD_SITE`
   - Agent mode requires: `DD_TRACE_AGENT_URL`

2. **Check firewall/proxy** allows HTTPS to:
   - `https://citestcycle-intake.datadoghq.com`
   - `https://citestcov-intake.datadoghq.com`
   (or equivalent for your DD_SITE)

3. **Enable debug logging**:
   ```bzl
   dd_payload_uploader(
       name = "dd_upload_payloads",
       debug = True,
       ...
   )
   ```

### Per-module files not found

**Symptom**: `dd_topt_go_test` fails with "module_X not found" or falls back to full bundle.

**Solutions**:

1. **List available modules**:
   ```bash
   bazel query 'kind(".*", @test_optimization_data//...)' | grep module_
   ```

2. **Override module label** explicitly (as workaround):
   ```bzl
   dd_topt_go_test(
       name = "my_test",
       module_label_override = "my_expected_module",  # Matches :module_my_expected_module
       ...
   )
   ```

### Windows-specific issues

**Symptom**: PowerShell errors or path issues.

**Solutions**:

1. **Verify PowerShell execution policy**:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

2. **Check paths use forward slashes** in Starlark/Bazel contexts (backward slashes are auto-converted).

### Getting help

If issues persist:

1. **Enable debug mode** and capture full output:
   ```bash
   bazel sync --only=test_optimization_data --repo_env=FETCH_SALT=$(date +%s) 2>&1 | tee debug.log
   ```

2. **Collect diagnostic info**:
   - Bazel version: `bazel version`
   - OS: `uname -a` (Linux/macOS) or `systeminfo` (Windows)
   - Repository rule outputs (as shown above)
   - Sanitized logs (remove API keys before sharing)

3. **File an issue** at: https://github.com/DataDog/rules_test_optimization/issues

## Configuration and attributes

Extension tag: `test_optimization_sync.test_optimization_sync(...)`

- Required
  - `name`: external repository name to create

- Optional
  - `out_dir` (string): base output directory. Defaults to `.testoptimization` (settings and test management output file names are fixed as `settings.json` and `test_management.json` under `out_dir`). The actual manifest path is exported via `topt_data["manifest_path"]`.
  - `service` (string): overrides service name. Precedence: `service` attr > `DD_SERVICE` env > `"unnamed-service"`
  - `runtime_name` (string): optional runtime name to include in configurations (e.g. `go`)
  - `runtime_version` (string): optional runtime version to include in configurations (e.g. `go1.22`)
  - `runtime_arch` (string): optional runtime architecture. Defaults to auto-detected `os.architecture` when not provided
  - `known_tests` (bool, default `True`): local kill-switch for Known Tests. When `False`, the Known Tests request is skipped and a minimal stub is written. The downloaded `settings.json` is also updated to set `known_tests_enabled: false`.
  - `test_management` (bool, default `True`): local kill-switch for Test Management Tests. When `False`, the Test Management request is skipped and a minimal stub is written. The downloaded `settings.json` is also updated to set `test_management.enabled: false`.
  - `debug` (bool): default `False`. Enables verbose logging

Notes:
- If optional file attributes are omitted, defaults are used under `out_dir` and do not affect the repository rule cache key.
- Parent directories are created automatically for all output paths.

## Uploader attributes

Rule: `dd_payload_uploader(...)`

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `name` | string | required | Target name |
| `quiescent_sec` | int | `10` | Seconds to wait for filesystem to settle before uploading |
| `max_wait_sec` | int | `300` | Maximum seconds to wait for payloads (`0` skips waiting when no payloads are present) |
| `fail_on_error` | bool | `False` | Exit with error if no payloads found when tests ran |
| `debug` | bool | `False` | Enable debug logging |
| `keep_payloads` | bool | `False` | Keep payload files after successful upload |
| `filter_prefix` | bool | `False` | Only upload files matching `span_events_*.json` or `coverage_*.json` |
| `gzip_payloads` | bool | `False` | Gzip test payloads before upload |
| `data` | label_list | `[]` | Data files to include (e.g., context.json for enrichment) |

## How data is fetched

The rule executes curl with timeouts and retries to these Datadog endpoints:

- Settings: `https://api.<DD_SITE>/api/v2/libraries/tests/services/setting`
- Known Tests: `https://api.<DD_SITE>/api/v2/ci/libraries/tests`
- Test Management Tests: `https://api.<DD_SITE>/api/v2/test/libraries/test-management/tests`

Settings response attributes determine which follow-up requests are sent:

- `known_tests_enabled` → triggers Known Tests
- `test_management.enabled` → triggers Test Management Tests

If a feature is disabled, the rule still writes a minimal stub JSON for that output file so consumers can always depend on the filegroup.

## Environment variables

The rule uses the following environment variables (they are declared in `environ`, and thus affect the repository rule cache key). The extension auto-detects CI providers and maps their environment variables to unified fields (repository URL, branch, SHA, etc.). Datadog-specific `DD_*` variables override provider-derived values.

### Datadog and generic inputs

- `DD_API_KEY` (required): Datadog API key
- `DD_SITE` (optional): site domain (e.g., `datadoghq.com`, `datadoghq.eu`). If a value like `app.datadoghq.com` is provided, it is normalized to use `api.<site>`
- `FETCH_SALT` (optional): use to force re-fetch, e.g., `--repo_env=FETCH_SALT=$(date +%s)`
- `GO_MODULE_PATH` (optional): explicit Go module path override used when emitting `export.bzl`

### Datadog Git overrides (highest precedence)

- `DD_GIT_REPOSITORY_URL`
- `DD_GIT_BRANCH`
- `DD_GIT_COMMIT_SHA`
- `DD_GIT_HEAD_COMMIT`
- `DD_GIT_COMMIT_MESSAGE`
- `DD_GIT_HEAD_MESSAGE`

### CI provider detection

The extension auto-detects these CI providers and maps their environment variables:

- GitHub Actions, GitLab CI, Jenkins, CircleCI, Azure Pipelines, Buildkite, Travis CI, Bitbucket, AppVeyor, TeamCity, Bitrise, Codefresh, AWS CodeBuild, Drone

All detection variables are declared in `environ` to ensure changes re-run the repository rule. Extra CI metadata inputs include `APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH`, `CI_PROJECT_PATH`, `GITHUB_WORKFLOW`, `TRAVIS_JOB_WEB_URL`, and `BUILD_URL`.

## Wrapper script (bazelw)

This repo provides a `bazelw` wrapper to simplify running with the right `--repo_env` variables:

- Computes Git metadata when a Git repo is present and forwards via `--repo_env`
- Precedence: if you export any `DD_GIT_*` variables in your shell, they override the computed ones

Examples:

```sh
# Refresh only on git environment variables
./bazelw build //...

# Refresh on an hourly TTL
FETCH_SALT_TTL=3600 ./bazelw build //...

# Override computed Git metadata
DD_GIT_REPOSITORY_URL=https://github.com/acme/api.git \
DD_GIT_BRANCH=main \
DD_GIT_COMMIT_SHA=$(git rev-parse HEAD) \
./bazelw test //...
```

## Integration tests (mock server)

For a full end-to-end flow (sync + uploader) without hitting Datadog, run:

```sh
tools/tests/integration/run_mock_server_tests.sh
```

On Windows, use the PowerShell entrypoint (or the `cmd.exe` wrapper):

```powershell
.\tools\tests\integration\run_mock_server_tests.ps1
```

```bat
tools\tests\integration\run_mock_server_tests.cmd
```

The Windows PowerShell entrypoint reuses the same Bash harness for parity and
prefers Git for Windows `bash.exe` (or `DD_TEST_OPTIMIZATION_GIT_BASH` when set).

This starts a local mock HTTP server and uses the following test-only overrides:

- `DD_TEST_OPTIMIZATION_API_BASE` to redirect sync requests
- `DD_TEST_OPTIMIZATION_INTAKE_BASE` to redirect uploader requests (agentless only)
- The harness asserts CODEOWNERS enrichment/preservation and runfile manifest
  fallback behavior (including BOM/tab exact keys and suffix-key resolution).
- On assertion failures, it prints focused uploader diagnostics plus manifest
  uploader log tails to speed up cross-platform triage.

CI note: `.github/workflows/ci.yml` also runs a dedicated hermetic lane
(`bazel-tests-hermetic`) on Linux with sandboxed execution and network blocking.
This is intentional: it catches hidden host/network dependencies that can pass
in normal local runs but fail in locked-down CI environments. By policy, this
lane is Linux-only for now; macOS/Windows remain covered by the normal
`bazel-tests` matrix plus the mock-server integration harness.

Reproducibility policy: this repository tracks both `.bazelversion` and
`MODULE.bazel.lock` in git to reduce local/CI toolchain and module-resolution
drift over time.
Current PR CI gates `./bazelw test //tools/...` plus the mock-server integration
harness on each OS; when changing targets outside `//tools/...`, run
`./bazelw test //...` locally before opening the PR.

## Schema sync helper

The source of truth for the uploader payload schema is:

- `tools/core/schemas/agentless-schema.yaml`

Regenerate the runtime JSON schema after YAML edits:

```sh
python3 tools/core/schemas/sync_agentless_schema.py
```

Check whether both files are in sync (CI/pre-commit friendly):

```sh
python3 tools/core/schemas/sync_agentless_schema.py --check
```

The helper uses PyYAML when available and falls back to Ruby's built-in YAML parser.

## Tips

- You can set a TTL via `FETCH_SALT_TTL`.
- For debugging, set `debug = True` when calling the extension to get verbose logs, including request bodies and detected OS info.
