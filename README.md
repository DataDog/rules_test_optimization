# Datadog Test Optimization Bazel Module Extension

This repository provides a Bazel module extension and repository rule that fetch Datadog Test Optimization metadata during the module resolution phase and materialize JSON files for use in your build. It also generates a public filegroup so you can conveniently depend on all produced files with a single label.

The extension performs these HTTP POST transactions (via curl):

- Settings: always executed. Parses feature flags from response.
- Known Tests: executed only when `known_tests_enabled: true` in Settings.
- Test Management Tests: executed only when `test_management.enabled: true` in Settings.

All outputs are written under a configurable directory (default: `.testoptimization`) and are grouped under a single filegroup target.

## What gets created

Given an external repository name `<repo_name>` created by the extension, the generated BUILD inside the external repo contains:

- A core filegroup target named `test_optimization_files` which includes `settings.json` and `manifest.txt`
- Files (always created; some may be minimal stubs if the corresponding feature is disabled):
  - `settings.json` (Settings API response)
  - `manifest.txt` (Payload manifest; version marker for change tracking, currently `version=1`)
  - `known_tests.json` (Known Tests API response or minimal stub)
  - Per-module Known Tests/Test Management (via filegroups): each module has a target exposing canonical runfiles under `.testoptimization/` with `known_tests.json` and `test_management.json`, scoped to that module. Physical files are stored under `.testoptimization/module_<sanitized>/known_tests.json` and `.testoptimization/module_<sanitized>/test_management.json`.
  - `test_management.json` (Test Management Tests API response or minimal stub)
  - `context.json` (Non-secret CI/Git/OS/runtime tags)

Reference settings with a single label:

```bzl
@<repo_name>//:test_optimization_files
```

### Per-module files and labels

When Known Tests are enabled, the combined response `data.attributes.tests` is a map keyed by module name. For convenience and performance, the sync rule automatically splits this response into per-module files and creates one public target per module. The same splitting is performed for Test Management tests (`test_management.json`), keyed by module under `data.attributes.modules`:

- Each module target exposes canonical runfiles:
  - `.testoptimization/known_tests.json` (module-scoped; same shape as combined)
  - `.testoptimization/test_management.json` (module-scoped; same shape as combined)
- Each module also becomes a public target: `:module_<sanitized_module>` that includes:
  - `.testoptimization/settings.json`
  - `.testoptimization/manifest.txt`
  - `.testoptimization/known_tests.json` (always present; stub when empty)
  - `.testoptimization/test_management.json` (always present; stub when empty)
- These per-module files are not bundled into `:test_optimization_files`

Sanitization rules for `<sanitized_module>`:

- For file names: lowercase; characters outside `[a-z0-9._-]` are replaced with `_`
- For target names: lowercase; characters outside `[a-z0-9_]` are replaced with `_`
- If collisions occur after sanitization, numeric suffixes like `_2`, `_3` are appended deterministically

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
# provided by the dd_topt_go_test macro (see tools/topt_go_test.bzl).
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

test_optimization_sync = use_extension("@datadog-rules-test-optimization//tools:test_optimization_sync.bzl", "test_optimization_sync_extension")

# Minimal usage: defaults to writing under .testoptimization and creating the filegroup
test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
)

use_repo(test_optimization_sync, "test_optimization_data")
```

Note: This module declares a dependency on `rules_go` solely to load provider definitions for Go importpath inference. It does not configure any Go toolchains. Consumers still need to set up `rules_go` and the Go SDK as usual to build and run Go targets.

### Multi-service usage (Bzlmod)

Fetch multiple services with one extension and select per-service data by label:

```bzl
# MODULE.bazel
topt_multi = use_extension(
    "@datadog-rules-test-optimization//tools:test_optimization_multi_sync.bzl",
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
```

Additional helper file exported by the generated repository:

- `export.bzl` with a single dictionary `modules` containing:
  - `repo_name`: external repository name created by the sync rule (e.g., `test_optimization_data`)
  - `labels`: list of available per-module sanitized labels
  - `set`: dict-as-set keyed by sanitized labels for fast membership checks
  - `go`: nested object with:
    - `module_path`: detected Go module path (may be empty)
    - `sanitized_module_path`: sanitized label fragment for `module_path`
    - `module_included`: boolean; true when the detected Go module has a matching per-module filegroup. The `dd_topt_go_test` macro uses this flag only when falling back to `<module_path>/<bazel package>`; it is ignored when `importpath` is inferred via `embed` or explicitly provided.

Then in any BUILD file:

```bzl
filegroup(
    name = "dd_test_opt_files",
    srcs = ["@test_optimization_data//:test_optimization_files"],
)

# Access context.json separately (for the uploader test rule)
filegroup(
    name = "dd_test_opt_context",
    srcs = ["@test_optimization_data//:test_optimization_context"],
)
```

## Installation (WORKSPACE)

If your project uses legacy WORKSPACE mode instead of Bzlmod, use the repository rule directly.

### 1) Add this repository in `WORKSPACE`

```bzl
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "datadog_rules_test_optimization",
    # Pin to a release tarball; example:
    # urls = ["https://github.com/DataDog/rules_test_optimization/archive/refs/tags/v1.0.0.tar.gz"],
    # strip_prefix = "rules_test_optimization-1.0.0",
    # sha256 = "<sha256>",
)

# Alternatively, for development:
# load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")
# git_repository(
#     name = "datadog_rules_test_optimization",
#     remote = "https://github.com/DataDog/rules_test_optimization.git",
#     tag = "v1.0.0",
# )
# Or:
# local_repository(
#     name = "datadog_rules_test_optimization",
#     path = "/absolute/path/to/rules_test_optimization",
# )
```

### 2) Instantiate the repository rule in `WORKSPACE`

```bzl
load("@datadog_rules_test_optimization//tools:test_optimization_sync.bzl", "test_optimization_sync")

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

### 4) Add the uploader test target

```bzl
load("@datadog_rules_test_optimization//tools:test_optimization_uploader_test.bzl", "dd_payload_uploader_test")

dd_payload_uploader_test(
    name = "dd_upload_payloads",
    # If omitted, the rule uses $DD_PAYLOADS_DIR (recommended with --sandbox_writable_path)
    tests_subdir = "tests",
    coverage_subdir = "coverage",
    quiescent_sec = 10,
    max_wait_sec = 1800,
    fail_on_error = False,
    # Provide context.json via runfiles so enrichment can occur
    data = [":dd_test_opt_context"],
)
```

### 5) Forward environment variables in `.bazelrc`

```bash
# Repository rule (module/repo phase) — affects refetch
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

# Tests (runtime)
test --test_env=DD_API_KEY
test --test_env=DD_SITE
test --test_env=DD_TRACE_AGENT_URL
test --test_env=DD_PAYLOADS_DIR
```

## Uploading test and coverage payloads (same `bazel test` invocation)

Use the provided test rule `dd_payload_uploader_test` to watch a shared writable directory for payloads, enrich test payloads with metadata from `context.json`, and upload them to Datadog during the same `bazel test` command.

### Where to write payloads

- Write payloads to a stable, non-sandboxed path made writable via `--sandbox_writable_path`.
- Recommended layout:

```
<workspace>/.testoptimization/payloads/
  tests/     # JSON payloads for CI Test Cycle intake
  coverage/  # JSON payloads for Code Coverage intake
```

Expose the path to tests via `--test_env=DD_PAYLOADS_DIR=<abs path>`. Tests must write:
- `$DD_PAYLOADS_DIR/tests/*.json`
- `$DD_PAYLOADS_DIR/coverage/*.json`

### Add the uploader test target

In a BUILD file (e.g., `//tools`):

```bzl
load("@datadog-rules-test-optimization//tools:test_optimization_uploader_test.bzl", "dd_payload_uploader_test")

dd_payload_uploader_test(
    name = "dd_upload_payloads",
    # If omitted, the rule uses $DD_PAYLOADS_DIR (recommended with --sandbox_writable_path)
    tests_subdir = "tests",
    coverage_subdir = "coverage",
    quiescent_sec = 10,      # idle window before uploading starts
    max_wait_sec = 1800,     # upper bound wait
    fail_on_error = False,   # set True to fail the test on upload errors
    # Provide context.json via runfiles so enrichment can occur
    data = [":dd_test_opt_context"],
    # timeout = "long",     # uncomment if your test phase can be long
)
```

Run together with your tests:

```bash
bazel test //... //tools:dd_upload_payloads \
  --sandbox_writable_path=$PWD/.testoptimization/payloads \
  --test_env=DD_PAYLOADS_DIR=$PWD/.testoptimization/payloads
```

### Endpoints, headers, and behavior

- Agentless (when `DD_TRACE_AGENT_URL` unset):
  - Tests: `https://citestcycle-intake.<DD_SITE>/api/v2/citestcycle`
  - Coverage: `https://citestcov-intake.<DD_SITE>/api/v2/citestcov`
  - Requires `DD_API_KEY`
- EVP proxy (when `DD_TRACE_AGENT_URL` set):
  - Base: `${DD_TRACE_AGENT_URL}/evp_proxy/v2/...`
  - Adds `X-Datadog-EVP-Subdomain` per endpoint
- Test payloads are JSON (msgpack not available in Starlark). Coverage is multipart with `event` and `coveragex` parts.
- Requests include `Accept: application/json`. Test uploads set `Content-Type: application/json`.

### Reliability

- HTTP requests use a 60-second timeout
- Failed requests are retried up to 3 times with a 2-second delay between attempts
- Both transient errors (connection issues) and HTTP errors (4xx/5xx) trigger retries
- Behavior is consistent across Linux/macOS (bash/curl) and Windows (PowerShell)

### Metadata enrichment (context.json)

- When `context.json` is present in runfiles (provided via the `data` attribute), the uploader enriches each test payload by merging all non-null keys from `context.json` into the payload under `metadata.*`.
- If `context.json` is not present (or if `jq` is unavailable on Unix), test payloads are uploaded as-is.
- The `context.json` file is produced by the sync extension and contains non-secret CI/Git/OS/runtime tags suitable for reuse at test time.

### Test-time environment variables

The macro sets the following environment variables for instrumented tests:

- `TEST_OPTIMIZATION_MANIFEST_FILE`: Runfile path to `manifest.txt` in the synced repo. Libraries resolve this via Bazel runfiles and call `filepath.Dir()` to derive the `.testoptimization` directory containing all synced payload files (settings, known tests, etc.).
- `DD_PAYLOADS_DIR`: Directory where tests write output payloads (`tests/*.json`, `coverage/*.json`). Must be writable via `--sandbox_writable_path`.

## Convenience macro: dd_topt_go_test

Replace a `go_test` with a single label that runs the Go test and the uploader. This macro creates:
- `<name>_go`: underlying `go_test`
- `<name>_dd_upload_payloads`: uploader test
- `<name>`: a `test_suite` that includes both

Prerequisite (one-time): ensure the sync repo exists as `@test_optimization_data` via Bzlmod or WORKSPACE (see Installation above). Define a small wrapper that loads `modules` and passes it to the macro.

### Bzlmod

```bzl
# tools/dd_topt_go_test_auto.bzl (in your repo)
load("@test_optimization_data//:export.bzl", "topt_data")
load("@datadog-rules-test-optimization//tools:topt_go_test.bzl", "dd_topt_go_test as _dd_topt_go_test")

def dd_topt_go_test(name, go_test_rule, **kwargs):
    _dd_topt_go_test(
        name = name,
        topt_data = topt_data,
        go_test_rule = go_test_rule,
        **kwargs
    )
```

### Import path inference

The macro auto-selects the correct per-module payloads by inferring the Go package `importpath` using rules_go providers, mirroring how `go_test` computes it:

- Precedence:
  1) `importpath` explicitly set on your `go_test` invocation (if provided in kwargs)
  2) Inference via `embed = [":<go_library>"]` by reading `GoArchive.importpath` from rules_go (recommended)
  3) Fallback: `<go module path>/<bazel package>` where the Go module path comes from the synced repo’s exported `topt_data["go"]["module_path"]`

- Per-module selection:
  - When using inference (1 or 2), the macro always attempts per-module selection and falls back to the full bundle if no matching module group exists.
  - When using the fallback (3), the macro consults `topt_data["go"]["module_included"]` as a coarse gate. If false, it skips per-module selection and uses the full bundle. If true, it attempts per-module selection with the computed fallback path.

Recommended pattern for best results:

```bzl
load("@rules_go//go:def.bzl", "go_library", "go_test")
load("@datadog-rules-test-optimization//tools:topt_go_test.bzl", "dd_topt_go_test")
load("@test_optimization_data//:export.bzl", "topt_data")

go_library(
    name = "pkg_lib",
    srcs = ["*.go"],
)

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    embed = [":pkg_lib"],    # enables provider-based inference
    topt_data = topt_data,
    go_test_rule = go_test,
)
```
Usage in BUILD (single-service):

```bzl
load("@rules_go//go:def.bzl", "go_test")
load("//tools:dd_topt_go_test_auto.bzl", "dd_topt_go_test")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    go_test_rule = go_test,
    # Uploader knobs:
    # quiescent_sec = 10,
    # max_wait_sec = 1800,
    # fail_on_error = False,
)
```

### WORKSPACE

```bzl
# tools/dd_topt_go_test_auto.bzl (in your repo)
load("@test_optimization_data//:export.bzl", "topt_data")
load("@datadog_rules_test_optimization//tools:topt_go_test.bzl", "dd_topt_go_test as _dd_topt_go_test")

def dd_topt_go_test(name, go_test_rule, **kwargs):
    _dd_topt_go_test(
        name = name,
        topt_data = topt_data,
        go_test_rule = go_test_rule,
        **kwargs
    )
```

Usage in BUILD (multi-service aggregator):

```bzl
load("@rules_go//go:def.bzl", "go_test")
load("//tools:dd_topt_go_test_auto.bzl", "dd_topt_go_test")

load("@test_optimization_data//:export.bzl", "topt_data_by_service")

dd_topt_go_test(
    name = "pkg_go_test",
    srcs = ["*_test.go"],
    topt_data = topt_data_by_service,   # pass mapping
    topt_service = "go_service",       # select service
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

### Service name validation errors

**Symptom**: Error message about invalid or empty service name.

**Solution**: Ensure service name is provided via one of:
1. The `service` attribute:
   ```bzl
   test_optimization_sync.test_optimization_sync(
       name = "test_optimization_data",
       service = "my-service",
   )
   ```

2. Or via environment variable in `.bazelrc`:
   ```
   common --repo_env=DD_SERVICE=my-service
   ```

### Network errors during fetch

**Symptom**: `curl` errors or timeout during repository resolution.

**Solutions**:

1. **Verify DD_SITE** is correct (defaults to `datadoghq.com`):
   ```
   common --repo_env=DD_SITE=datadoghq.eu  # for EU region
   ```

2. **Check firewall/proxy** allows HTTPS to:
   - `https://api.datadoghq.com` (or your DD_SITE)

3. **Verify API key permissions**: The API key needs read access to:
   - CI Visibility Settings API
   - Libraries Tests API (for Known Tests)
   - Test Management API (for Test Management)

### Tests not uploading

**Symptom**: Tests run but no data appears in Datadog UI.

**Solutions**:

1. **Verify uploader test ran**:
   ```bash
   bazel test //... //tools:dd_upload_payloads --test_output=all
   ```
   Look for `[dd-uploader]` log lines.

2. **Check payload directory is writable**:
   ```bash
   # Must match your --test_env=DD_PAYLOADS_DIR
   ls -la $PWD/.testoptimization/payloads/tests/
   ls -la $PWD/.testoptimization/payloads/coverage/
   ```

3. **Ensure --sandbox_writable_path is set**:
   ```bash
   bazel test //... //tools:dd_upload_payloads \
     --sandbox_writable_path=$PWD/.testoptimization/payloads \
     --test_env=DD_PAYLOADS_DIR=$PWD/.testoptimization/payloads
   ```

4. **Verify environment variables** for upload:
   - Agentless mode requires: `DD_API_KEY`, `DD_SITE`
   - EVP proxy mode requires: `DD_TRACE_AGENT_URL`

### Per-module files not found

**Symptom**: `dd_topt_go_test` fails with "module_X not found" or falls back to full bundle.

**Solutions**:

1. **List available modules**:
   ```bash
   bazel query 'kind(".*", @test_optimization_data//...)' | grep module_
   ```

2. **Check Go module path detection**:
   ```bash
   # Enable debug to see detected module path
   # Look for logs like: "Detected module path 'github.com/myorg/repo'"
   ```

3. **Verify importpath inference** (if using `embed`):
   - Ensure `go_library` target exists
   - Check that `embed = [":library_target"]` is set on your test

4. **Override module label** explicitly (as workaround):
   ```bzl
   dd_topt_go_test(
       name = "my_test",
       module_label_override = "my_expected_module",  # Matches :module_my_expected_module
       ...
   )
   ```

### Cache invalidation happening too often

**Symptom**: Repository refetches on every build.

**Causes & Solutions**:

1. **Changing Git state**: `GIT_DIRTY`, `DD_GIT_*` variables are in `environ` list.
   - Remove `GIT_DIRTY` from your `.bazelrc` if you don't want dirty-tree sensitivity.

2. **FETCH_SALT with TTL**: If using `FETCH_SALT_TTL` in `bazelw`, each TTL expiry triggers refetch.
   - Increase TTL or remove FETCH_SALT for stable builds.

3. **Datadog backend changes**: Settings or test lists changing upstream invalidate cache.
   - Expected behavior; use per-module files to limit blast radius.
   - Consider kill-switches for Known Tests if too noisy:
     ```bzl
     test_optimization_sync.test_optimization_sync(
         name = "test_optimization_data",
         known_tests = False,  # Disable Known Tests locally
     )
     ```

### Windows-specific issues

**Symptom**: PowerShell errors or `bazelw` not found.

**Solutions**:

1. **Use PowerShell for bazelw equivalent**:
   ```powershell
   # Set environment variables directly before bazel commands
   $env:DD_GIT_REPOSITORY_URL = "https://github.com/myorg/repo.git"
   bazel build //...
   ```

2. **Verify PowerShell execution policy**:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

3. **Check paths use forward slashes** in Starlark/Bazel contexts (backward slashes are auto-converted).

### Debugging tips

1. **View HTTP request bodies** (when `debug = True`):
   - Look for lines like: `[http] Settings request body: {...}`

2. **Inspect generated files**:
   ```bash
   # Settings
   cat $(bazel info output_base)/external/test_optimization_data/.testoptimization/settings.json | jq .
   
   # Per-module known tests
   cat $(bazel info output_base)/external/test_optimization_data/.testoptimization/module_*/known_tests.json | jq .
   ```

3. **Check BUILD file generation**:
   ```bash
   cat $(bazel info output_base)/external/test_optimization_data/BUILD
   ```

4. **Verify export.bzl contents**:
   ```bash
   cat $(bazel info output_base)/external/test_optimization_data/export.bzl
   ```

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
  - `out_dir` (string): base output directory. Defaults to `.testoptimization` (settings and test management output file names are fixed as `settings.json` and `test_management.json` under `out_dir`)
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

## How data is fetched

The rule executes curl with timeouts and retries to these Datadog endpoints:

- Settings: `https://api.<DD_SITE>/api/v2/libraries/tests/services/setting`
- Known Tests: `https://api.<DD_SITE>/api/v2/ci/libraries/tests`
- Test Management Tests: `https://api.<DD_SITE>/api/v2/test/libraries/test-management/tests`

Settings response attributes determine which follow-up requests are sent:

- `known_tests_enabled` → triggers Known Tests
- `test_management.enabled` → triggers Test Management Tests

If a feature is disabled, the rule still writes a minimal stub JSON for that output file so consumers can always depend on the filegroup.

You can also disable features locally regardless of the server response using the kill-switch attributes:

```bzl
test_optimization_sync.test_optimization_sync(
    name = "test_optimization_data",
    # Force-disable features locally; settings.json will be updated accordingly
    known_tests = False,
    test_management = False,
)
```

## OS and runtime configuration

- OS fields (auto-detected):
  - `os.platform`, `os.version`, `os.architecture` are detected from the host (via `uname`).
- Runtime fields (configurable):
  - `runtime.name`, `runtime.version`, `runtime.architecture`
  - If `runtime_arch` is not provided, it defaults to `os.architecture`.

## Service and environment

- Service precedence: `service` attr > `DD_SERVICE` env > `"unnamed-service"`
- Environment (`env` attribute in payload): `DD_ENV` env or default `"CI"`

## Caching semantics

The repository rule re-executes (fetches) when:

- Any provided attribute changes (e.g., `out_dir`, `service`, runtime_*), or
- Any environment variable listed in `environ` changes, or
- The rule’s Starlark implementation changes.

Outputs are content-addressed for downstream actions, but the repository fetch is keyed only by the repository rule inputs above (attrs + `environ`).

## Environment variables

The rule uses the following environment variables (they are declared in `environ`, and thus affect the repository rule cache key). The extension auto-detects CI providers and maps their environment variables to unified fields (repository URL, branch, SHA, etc.). Datadog-specific `DD_*` variables override provider-derived values.

### Datadog and generic inputs

- `DD_API_KEY` (required): Datadog API key
- `DD_SITE` (optional): site domain (e.g., `datadoghq.com`, `datadoghq.eu`). If a value like `app.datadoghq.com` is provided, it is normalized to use `api.<site>`
- `FETCH_SALT` (optional): use to force re-fetch, e.g., `--repo_env=FETCH_SALT=$(date +%s)`
- `GIT_DIRTY` (optional): only for cache-key shaping, not sent to Datadog

### Datadog Git overrides (highest precedence)

- `DD_GIT_REPOSITORY_URL`
- `DD_GIT_BRANCH`
- `DD_GIT_COMMIT_SHA`
- `DD_GIT_HEAD_COMMIT`
- `DD_GIT_COMMIT_MESSAGE`
- `DD_GIT_HEAD_MESSAGE`

### CI provider detection (examples of fields used)

Below is a summary of detection keys and mapped fields. If multiple are available, Datadog-specific overrides (`DD_GIT_*`) take precedence.

- AppVeyor (detect by `APPVEYOR`)
  - repo: `APPVEYOR_REPO_NAME` (if provider=github → `https://github.com/<name>.git`)
  - sha: `APPVEYOR_REPO_COMMIT`
  - branch: `APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH` or `APPVEYOR_REPO_BRANCH`

- Azure Pipelines (detect by `TF_BUILD`)
  - repo: `BUILD_REPOSITORY_URI`
  - sha: `BUILD_SOURCEVERSION`
  - branch: `BUILD_SOURCEBRANCH`
  - message: `BUILD_SOURCEVERSIONMESSAGE`

- Bitbucket (detect by `BITBUCKET_COMMIT`)
  - repo: `BITBUCKET_GIT_HTTP_ORIGIN` or `https://bitbucket.org/<slug>.git`
  - sha: `BITBUCKET_COMMIT`
  - branch: `BITBUCKET_BRANCH`

- Buildkite (detect by `BUILDKITE`)
  - repo: `BUILDKITE_REPO`
  - sha: `BUILDKITE_COMMIT`
  - branch: `BUILDKITE_BRANCH`
  - message: `BUILDKITE_MESSAGE`

- CircleCI (detect by `CIRCLECI`)
  - repo: `CIRCLE_REPOSITORY_URL`
  - sha: `CIRCLE_SHA1`
  - branch: `CIRCLE_BRANCH`

- GitHub Actions (detect by `GITHUB_SHA`)
  - repo: `GITHUB_SERVER_URL` + `GITHUB_REPOSITORY` + `.git`
  - sha: `GITHUB_SHA`
  - ref → branch: normalized from `GITHUB_REF`

- GitLab (detect by `GITLAB_CI`)
  - repo: `CI_REPOSITORY_URL`
  - sha: `CI_COMMIT_SHA`
  - branch: `CI_COMMIT_BRANCH`
  - message: `CI_COMMIT_MESSAGE`
  - head sha (MR): `CI_MERGE_REQUEST_SOURCE_BRANCH_SHA`

- Jenkins (detect by `JENKINS_URL`)
  - repo: `GIT_URL` or `GIT_URL_1`
  - sha: `GIT_COMMIT`
  - branch: `GIT_BRANCH`

- TeamCity (detect by `TEAMCITY_VERSION`)
  - repo: `GIT_URL`
  - sha: `GIT_COMMIT`
  - branch: `GIT_BRANCH`

- Travis CI (detect by `TRAVIS`)
  - repo: `TRAVIS_REPO_SLUG` → `https://github.com/<slug>.git`
  - sha: `TRAVIS_COMMIT`
  - branch: `TRAVIS_PULL_REQUEST_BRANCH` or `TRAVIS_BRANCH`
  - message: `TRAVIS_COMMIT_MESSAGE`

- Bitrise (detect by `BITRISE_BUILD_SLUG`)
  - repo: `BITRISE_GIT_REPOSITORY_URL`
  - sha: `BITRISE_GIT_COMMIT`
  - branch: `BITRISE_GIT_BRANCH`

- Codefresh (detect by `CF_BUILD_ID`)
  - branch: `CF_BRANCH`

- AWS CodeBuild/CodePipeline (detect by `CODEBUILD_INITIATOR`)
  - limited extraction by default

- Drone (detect by `DRONE`)
  - repo: `DRONE_GIT_HTTP_URL`
  - sha: `DRONE_COMMIT_SHA`
  - branch: `DRONE_BRANCH`
  - message: `DRONE_COMMIT_MESSAGE`

All above detection variables are also declared in `environ` to ensure changes re-run the repository rule.

## Wrapper script (bazelw)

This repo provides a `bazelw` wrapper to simplify running with the right `--repo_env` variables:

- Computes Git metadata when a Git repo is present and forwards via `--repo_env`:
  - `GIT_DIRTY`: `clean|dirty`
  - `DD_GIT_REPOSITORY_URL`: from `git config --get remote.origin.url`
  - `DD_GIT_BRANCH`: from `git symbolic-ref --short -q HEAD` (falls back to `rev-parse --abbrev-ref`); defaults to `auto:git-detached-head` on detached HEAD
  - `DD_GIT_COMMIT_SHA`: from `git rev-parse HEAD`
  - `DD_GIT_HEAD_COMMIT`: same as `DD_GIT_COMMIT_SHA`
  - `DD_GIT_COMMIT_MESSAGE`: one-line subject of the HEAD commit
  - `DD_GIT_HEAD_MESSAGE`: same as `DD_GIT_COMMIT_MESSAGE`
- Precedence: if you export any `DD_GIT_*` variables in your shell, they override the computed ones.

Examples:

```sh
# Refresh only on git environmnet variables
./bazelw build //...

# Refresh on an hourly TTL
FETCH_SALT_TTL=3600 ./bazelw build //...

# Override computed Git metadata (useful in CI or custom scenarios)
DD_GIT_REPOSITORY_URL=https://github.com/acme/api.git \
DD_GIT_BRANCH=main \
DD_GIT_COMMIT_SHA=$(git rev-parse HEAD) \
./bazelw test //...
```

## Tips

- You can set a TTL via `FETCH_SALT_TTL`.
- For debugging, set `debug = True` when calling the extension to get verbose logs, including request bodies and detected OS info.
