# Implementation Plan: Option 2 - TEST_UNDECLARED_OUTPUTS_DIR

## Review Notes

**Last reviewed:** Forty-seventh review pass (self-review: fix Section 12 Question 6 to use exit code preservation pattern)
**Status:** Ready for implementation

**Key decisions made:**
1. Use `TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true` environment variable to signal file-based payload output
2. **Uploader is a normal rule (not a test)** - invoked via `bazel run` after `bazel test`. This simplifies sandbox/network access since `bazel run` runs locally with full host access.
3. Path discovery uses `BUILD_WORKSPACE_DIRECTORY` + `bazel-testlogs` symlink, with explicit `TESTLOGS_DIR` env var override for non-standard setups
4. Simple quiescence logic waits for filesystem to settle before uploading
5. Existing upload and context.json enrichment logic is preserved (but runfiles lookup must change from `TEST_SRCDIR` to `RUNFILES_DIR` or `RUNFILES_MANIFEST_FILE` for cross-platform support)
6. **SINGLE uploader target per workspace** - NOT per-test (prevents race conditions)
7. **Upload ALL `*.json` files** in `tests/` and `coverage/` directories, then delete after successful upload (unless `DD_TOPT_KEEP_PAYLOADS=1`)
8. **Multi-service repos use single uploader with shared context** - the uploader uses workspace-level `context.json`; per-service context must be embedded in payloads by dd-trace-go
9. **Sharded/retry discovery is recursive** - the `find` command discovers `test.outputs` at any depth, including under `shard_*/` and `run_*/` directories

**Remaining risks:**
1. Path discovery on Windows needs verification (junctions vs symlinks)
2. Upload filtering uploads all `*.json` in payload directories - if other tools write JSON there, it will be uploaded (can enable prefix filtering with `DD_TOPT_FILTER_PREFIX=1`)
3. Multi-service assumption (payloads contain service metadata) is not validated - add integration test to verify service fields survive enrichment

**Version requirements:**
- **Minimum Bazel version:** 5.0+ (required for reliable `TEST_UNDECLARED_OUTPUTS_DIR` support)
- **Minimum dd-trace-go version:** This plan requires dd-trace-go >= X.Y.Z (TBD) which adds `TEST_UNDECLARED_OUTPUTS_DIR` support. Earlier versions will silently fall back to network mode (no file output).

> **IMPORTANT:** Both version requirements must be documented prominently and enforced before implementation. The dd-trace-go version will be pinned once the library changes are implemented.

**Version enforcement mechanisms:**
1. **Uploader warning:** If uploader finds no payloads but tests ran, log a warning suggesting dd-trace-go version check
2. **Documentation:** README must prominently list minimum versions
3. **Optional go.mod check:** Users can add a `//go:build` constraint or `require` directive to enforce minimum dd-trace-go version
4. **Runtime detection (future):** dd-trace-go could write a version marker file; uploader can check and warn if missing/outdated

**Critical requirements (must document):**
1. **Use `bazel run` (not `bazel test`)** - uploader is a normal rule, not a test
2. Uploader needs network access for uploads (automatic with `bazel run` in default config)
3. Uploader needs host filesystem access to read AND delete from `bazel-testlogs/` (automatic with `bazel run`)
4. **Use a SINGLE uploader target per workspace** - do NOT run multiple uploaders concurrently (enforced via lock file)
5. **Tests must run locally OR use `--remote_download_outputs=all`** - remote execution without downloading outputs leaves `bazel-testlogs/` empty
6. **`bazel-testlogs` must be discoverable** - via convenience symlink (default) OR set `TESTLOGS_DIR` env var explicitly. If using `--symlink_prefix` or disabled convenience symlinks, use the **same Bazel binary AND flags** used for `bazel test`:
   - Bash: `BAZEL_FLAGS=("--output_base=/custom/base"); TESTLOGS_DIR=$(bazel "${BAZEL_FLAGS[@]}" info bazel-testlogs) bazel "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads`
   - PowerShell: `$BazelFlags = @("--output_base=/custom/base"); $env:TESTLOGS_DIR = (bazel @BazelFlags info bazel-testlogs); bazel @BazelFlags run //:dd_upload_payloads`
   - **Note:** Both use arrays to correctly handle multiple flags or values with spaces
   - **Note:** If `TESTLOGS_DIR` is set but the path doesn't exist, the uploader fails fast with an error (vs graceful exit when auto-discovery finds nothing)
7. **Hermetic/sandboxed configs:** If using `--config=hermetic` or `--sandbox_default_allow_network=false`, exclude the uploader from these restrictions:
   - Run uploader outside hermetic config: `bazel run //:dd_upload_payloads` (without `--config=hermetic`)
   - Or add to `.bazelrc`: `run --sandbox_default_allow_network=true` (applies only to `bazel run`)
   - The uploader will detect network failures and exit with a clear error message
8. **Test caching and stale outputs:** Bazel's test caching can leave stale `test.outputs/` from previous runs. To ensure only current test results are uploaded:
   - **Recommended:** Use `--nocache_test_results` for CI runs: `bazel test --nocache_test_results //...`
   - **Alternative:** Clean testlogs before tests: `rm -rf bazel-testlogs/*/test.outputs 2>/dev/null || true`
   - **Note:** Without these precautions, cached test results may cause stale/duplicate data uploads
9. **Same workspace/machine requirement:** The uploader MUST run on the same machine and workspace where tests executed:
   - `bazel-testlogs` is a local symlink to the output base; it doesn't exist on other machines
   - For distributed CI (separate test and upload jobs), either:
     - Run uploader in the same job as tests
     - Archive `bazel-testlogs/` as a CI artifact and restore it before upload
     - Set `TESTLOGS_DIR` to the restored artifact path

**Exit codes:**
- `0` - All payloads uploaded successfully (or no payloads found)
- `1` - One or more uploads failed (partial success: successfully uploaded files are still deleted unless `DD_TOPT_KEEP_PAYLOADS=1`)
- `2` - Configuration error (invalid TESTLOGS_DIR, missing credentials, etc.)

**Required environment variables for upload:**

| Variable | Purpose | Required? |
|----------|---------|-----------|
| `DD_API_KEY` | Datadog API key for authentication | Yes (agentless mode) |
| `DD_SITE` | Datadog site (e.g., `datadoghq.com`, `datadoghq.eu`) | Yes (agentless mode) |
| `DD_TRACE_AGENT_URL` | Agent/EVP endpoint URL (e.g., `http://localhost:8126`) | Yes (agent/EVP mode) |

**Upload modes:**
- **Agentless mode (default):** Requires `DD_API_KEY` and `DD_SITE`; uploads directly to Datadog intake
- **Agent/EVP mode:** Requires `DD_TRACE_AGENT_URL`; uploads via local agent or EVP proxy

**Passing credentials to `bazel run`:**
```bash
# Option 1: Agentless mode - Inline (recommended for CI)
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads

# Option 2: Agent/EVP mode
DD_TRACE_AGENT_URL="http://localhost:8126" bazel run //:dd_upload_payloads

# Option 3: Export before run
export DD_API_KEY="your-api-key"
export DD_SITE="datadoghq.com"
bazel run //:dd_upload_payloads

# Option 4: Via .bazelrc (NOT recommended - credentials in file)
# run --action_env=DD_API_KEY
# run --action_env=DD_SITE
```

**Optional environment variables (for debugging and edge cases):**

| Variable | Default | Purpose |
|----------|---------|---------|
| `DD_TOPT_KEEP_PAYLOADS` | `0` | Set to `1` to retain payloads after successful upload (for debugging/re-upload) |
| `DD_TOPT_FILTER_PREFIX` | `0` | Set to `1` to only upload files matching `span_events_*.json` or `coverage_*.json` |
| `DD_TOPT_DEBUG` | `0` | Set to `1` to enable verbose upload logging (HTTP codes, response bodies, startTime stats) |
| `DD_TOPT_GZIP` | `0` | Set to `1` to gzip **test** payloads before upload (adds `Content-Encoding: gzip`) |
| `DD_TOPT_MAX_WAIT_SEC` | `300` | Override max wait time for slow filesystems (NFS, network drives) |
| `DD_TOPT_QUIESCENT_SEC` | `10` | Override quiescence wait time |
| `DD_TOPT_MAX_DEPTH` | `0` (unlimited) | Limit `find` depth for large `bazel-testlogs` trees (0=unlimited, see note below) |

**`DD_TOPT_MAX_DEPTH` usage notes:**
- Depth is measured from `bazel-testlogs/` (depth 0 = immediate children)
- Typical `test.outputs` paths require depth 3-5 (e.g., `bazel-testlogs/pkg/subpkg/test_name/test.outputs`)
- Sharded tests add 1 level (e.g., `bazel-testlogs/pkg/test_name/shard_1_of_3/test.outputs`)
- **Warning:** Setting depth too low will skip all `test.outputs` directories, resulting in empty uploads
- Example depths for common layouts:
  - Flat: `bazel-testlogs/my_test/test.outputs` → depth 2
  - Nested: `bazel-testlogs/src/pkg/my_test/test.outputs` → depth 4
  - Sharded: `bazel-testlogs/src/pkg/my_test/shard_1_of_3/test.outputs` → depth 5

---

## Executive Summary

Migrate from the current `--sandbox_writable_path` + `TEST_OPTIMIZATION_PAYLOADS_DIR` approach to using Bazel's built-in `TEST_UNDECLARED_OUTPUTS_DIR` for payload collection. This eliminates the need for `--sandbox_writable_path` and `--test_env` flags for **local execution**.

**Note for Remote Build Execution (RBE):** Remote tests require `--remote_download_outputs=all` to ensure test outputs are downloaded locally for the uploader.

---

## 1. Current State Analysis

### 1.1 Current Environment Variables

| Variable | Set By | Purpose | Required? |
|----------|--------|---------|-----------|
| `TEST_OPTIMIZATION_MANIFEST_FILE` | Macro | Runfiles path to `manifest.txt` (from `topt_data["manifest_path"]`) | Yes |
| `TEST_OPTIMIZATION_PAYLOADS_IN_FILES` | Macro (when payloads_dir set) | Signal to write payloads to files | Conditional |
| `TEST_OPTIMIZATION_PAYLOADS_DIR` | CLI (`--test_env`) | Absolute path where payloads are written | Yes (for file mode) |

### 1.2 Current Flow

```
User must provide:
  --sandbox_writable_path=$PWD/.testoptimization/payloads
  --test_env=TEST_OPTIMIZATION_PAYLOADS_DIR=$PWD/.testoptimization/payloads

[go_test] ──writes──▶ $TEST_OPTIMIZATION_PAYLOADS_DIR/tests/*.json
                      $TEST_OPTIMIZATION_PAYLOADS_DIR/coverage/*.json
                                    │
                                    ▼ (shared directory)
[uploader_test] ◀───── watches for quiescence, then uploads
```

### 1.3 Current Problems

1. **CLI complexity**: Users must provide two matching flags (`--sandbox_writable_path` and `--test_env`)
2. **Path coordination**: Both flags must specify the same absolute path
3. **Cache concerns**: Hardcoding paths in BUILD files affects cache
4. **Documentation burden**: Complex setup instructions

---

## 2. New Design: Option 2

### 2.1 Core Concept

Use Bazel's `TEST_UNDECLARED_OUTPUTS_DIR` which is:
- **Always available** in every test (Bazel 5.0+)
- **Always writable** without any CLI flags
- **Automatically collected** by Bazel to `bazel-testlogs/<target>/test.outputs/`

> **Note:** `TEST_UNDECLARED_OUTPUTS_DIR` has been available since early Bazel versions, but reliable behavior requires Bazel 5.0+. Earlier versions may have edge cases with output collection.

### 2.2 New Environment Variables

| Variable | Set By | Purpose | Required? |
|----------|--------|---------|-----------|
| `TEST_OPTIMIZATION_MANIFEST_FILE` | Macro | Runfiles path to `manifest.txt` (from `topt_data["manifest_path"]`) | Yes |
| `TEST_OPTIMIZATION_PAYLOADS_IN_FILES` | Macro | Set to `"true"` to signal file-based output mode | Yes |

**Removed:**
- ~~`TEST_OPTIMIZATION_PAYLOADS_DIR`~~ - No longer needed (library uses `TEST_UNDECLARED_OUTPUTS_DIR`)

### 2.3 New Flow

```
No --sandbox_writable_path or --test_env flags required for local execution!
(RBE requires --remote_download_outputs=all)

[go_test_1] ──writes──▶ $TEST_UNDECLARED_OUTPUTS_DIR/tests/*.json
[go_test_2] ──writes──▶ $TEST_UNDECLARED_OUTPUTS_DIR/coverage/*.json
[go_test_N] ──writes──▶ ...
                                    │
                                    ▼ (Bazel collects automatically)
                      bazel-testlogs/<package>/<target>/test.outputs/
                                    │
                                    ▼
[SINGLE uploader] ◀─── globs ALL test.outputs/, waits for quiescence, uploads
```

> **IMPORTANT:** Use a SINGLE uploader target per workspace, NOT one per test.
> Multiple concurrent uploaders would race and delete each other's payloads.

### 2.4 Library Behavior (dd-trace-go)

> **REQUIRED:** dd-trace-go >= X.Y.Z (version TBD during implementation). Earlier versions do not support `TEST_UNDECLARED_OUTPUTS_DIR` and will silently fall back to network mode, resulting in no file output and empty uploads.
>
> **Rollout recommendation:** Pin to the minimum required version in your `go.mod` and add a CI check that warns if a lower version is detected.

```go
func getPayloadsDir() string {
    // Check if we're in Bazel file-output mode
    if os.Getenv("TEST_OPTIMIZATION_PAYLOADS_IN_FILES") == "true" {
        // Use Bazel's undeclared outputs directory
        if dir := os.Getenv("TEST_UNDECLARED_OUTPUTS_DIR"); dir != "" {
            return dir
        }
        // Warn if TEST_UNDECLARED_OUTPUTS_DIR not set (unexpected in Bazel)
        log.Warn("TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true but TEST_UNDECLARED_OUTPUTS_DIR not set; falling back to network mode")
    }

    // Fallback: not in Bazel mode, use network
    return ""
}
```

### 2.5 Directory Structure

Each test's payloads are isolated:

```
bazel-testlogs/
├── src/
│   ├── service_a/
│   │   └── unit_test/
│   │       └── test.outputs/
│   │           ├── tests/
│   │           │   └── span_events_<uuid>.json
│   │           └── coverage/
│   │               └── coverage_<uuid>.json
│   │
│   └── service_b/
│       └── integration_test/
│           └── test.outputs/
│               ├── tests/
│               │   └── span_events_<uuid>.json
│               └── coverage/
│                   └── coverage_<uuid>.json
```

**Payload file naming (convention, not enforced):**
- Test payloads: `span_events_<uuid>.json` in `tests/` subdirectory
- Coverage payloads: `coverage_<uuid>.json` in `coverage/` subdirectory

> **WARNING: Broad upload filtering**
>
> The uploader uploads ALL `*.json` files found in `tests/` and `coverage/` directories under `test.outputs/`. It does NOT filter by filename prefix by default.
>
> **Risk:** If other tools or test code write JSON files to these directories, they will be uploaded to Datadog. The test optimization library creates these directories specifically for payload output, so this should not normally occur.
>
> **Mitigation:** Set `DD_TOPT_FILTER_PREFIX=1` to enable strict prefix filtering (only `span_events_*.json` and `coverage_*.json` files).

### 2.6 Multi-Service Repositories

For monorepos with multiple services, the **single uploader per workspace** rule still applies. The uploader uses a workspace-level `context.json` which contains CI/Git metadata common to all services.

**Strategy:**
1. **Workspace-level context**: The `context.json` contains non-service-specific metadata (git commit, branch, CI job, etc.)
2. **Service-level context embedded in payloads**: dd-trace-go embeds service-specific metadata (service name, module path) directly in each payload file
3. **Single uploader uploads all payloads**: The uploader collects from all `test.outputs/` directories regardless of which service they belong to

**Example monorepo structure:**
```
bazel-testlogs/
├── services/
│   ├── auth/
│   │   └── tests/
│   │       └── test.outputs/tests/span_events_*.json   # Contains service=auth
│   └── billing/
│       └── tests/
│           └── test.outputs/tests/span_events_*.json   # Contains service=billing
```

**Important:** Per-service uploaders are NOT supported. Do not create multiple `dd_payload_uploader` targets—they will race and corrupt each other's payloads.

### 2.7 Sharded and Retry Test Discovery

Bazel creates additional subdirectories for sharded tests and flaky test retries:

```
bazel-testlogs/
└── src/my_test/
    ├── shard_1_of_3/
    │   └── test.outputs/tests/...
    ├── shard_2_of_3/
    │   └── test.outputs/tests/...
    ├── shard_3_of_3/
    │   └── test.outputs/tests/...
    └── run_2_of_3/           # Flaky test retry
        └── test.outputs/tests/...
```

The uploader's `find "$TESTLOGS_DIR" -type d -name "test.outputs"` command discovers `test.outputs` at **any depth**, automatically handling:
- Sharded tests (`shard_N_of_M/`)
- Flaky test retries (`run_N_of_M/`)
- Nested package structures

No special configuration is required—all payloads are discovered and uploaded.

---

## 3. Implementation Plan

### Phase 1: Update Macro (`topt_go_test.bzl`)

**File:** `tools/topt_go_test.bzl`

**Major Change: Remove per-test uploader**

The current macro creates THREE targets per test:
- `<name>_go` - the go_test
- `<name>_dd_upload_payloads` - the uploader (REMOVE THIS)
- `<name>` - test_suite containing both (CHANGE TO JUST THE TEST)

This caused a race condition: multiple uploaders running concurrently would scan ALL test.outputs and delete each other's payloads.

**New design:**
- Macro creates ONLY the go_test (no uploader)
- User creates ONE uploader target per workspace (see Phase 3)

**Changes:**

1. **Remove uploader creation from macro** - no more `dd_payload_uploader` per test
2. **Remove test_suite** - the macro target IS the go_test directly
3. **Remove all uploader-related parameters** - `payloads_dir`, `tests_subdir`, `coverage_subdir`, `quiescent_sec`, `max_wait_sec`, `fail_on_error`, `uploader_debug`, `uploader_tags`, `suite_tags`
4. Always set `TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true`
5. Update documentation strings

**New signature:**
```python
def dd_topt_go_test(
    name,
    topt_data,
    go_test_rule,
    # All uploader-related parameters REMOVED
    **kwargs
):
    # Build env map
    env = dict(kwargs.pop("env", {}))
    repo_name = topt_data.get("repo_name") or "test_optimization_data"
    manifest_path = topt_data.get("manifest_path") or ".testoptimization/manifest.txt"
    manifest_label = "@%s//:%s" % (repo_name, manifest_path)
    env["TEST_OPTIMIZATION_MANIFEST_FILE"] = "$(rlocationpath %s)" % manifest_label
    env["TEST_OPTIMIZATION_PAYLOADS_IN_FILES"] = "true"

    # Create ONLY the go_test - NO uploader, NO test_suite
    go_test_rule(
        name = name,  # Direct name, not name + "_go"
        data = data,
        env = env,
        **kwargs
    )

    # NO uploader created here - user must create ONE uploader per workspace
```

**Key design decisions:**
- The macro target IS the go_test directly (no `<name>_go` suffix)
- No per-test uploader (`<name>_dd_upload_payloads` does not exist)
- No test_suite wrapper
- Users must create ONE uploader target per workspace (see Phase 3)

---

### Phase 2: Update Uploader (`test_optimization_uploader.bzl`)

**File:** `tools/test_optimization_uploader.bzl`

**Changes:**

1. Change from watching single `$TEST_OPTIMIZATION_PAYLOADS_DIR` to watching `bazel-testlogs/`
2. Glob all `test.outputs/` directories
3. Update quiescence logic to handle multiple directories
4. Update both bash and PowerShell implementations

**Key Logic Changes:**

#### 2.1 Determine testlogs directory

Path discovery with explicit override support (see Section 14 and Appendix A/B for full implementation):

**Strategies (in order):**
1. **`TESTLOGS_DIR` env var** - Explicit override, use when convenience symlinks are disabled
2. `BUILD_WORKSPACE_DIRECTORY/bazel-testlogs` symlink (default case)
3. `./bazel-testlogs` in current directory

> **Note:** We intentionally do NOT call `bazel info` from within the uploader because running `bazel info` inside `bazel run` can deadlock when the output base is locked.

**For non-standard symlink setups** (e.g., `--symlink_prefix` or disabled convenience symlinks), use the **same Bazel binary AND flags** used for `bazel test`:

```bash
# Bash - use array for multiple flags or values with spaces
BAZEL_FLAGS=("--output_base=/custom/base")  # Add more flags to array as needed
TESTLOGS_DIR=$(bazel "${BAZEL_FLAGS[@]}" info bazel-testlogs) bazel "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads
```

```powershell
# PowerShell - use array splatting for multiple flags
$BazelFlags = @("--output_base=/custom/base")  # Add more flags to array as needed
$env:TESTLOGS_DIR = (bazel @BazelFlags info bazel-testlogs)
bazel @BazelFlags run //:dd_upload_payloads
```

See Appendix A (Bash) and Appendix B (PowerShell) for full implementation.

#### 2.2 Find all test.outputs directories

```bash
# Bash
find_test_outputs() {
    find "$TESTLOGS_DIR" -type d -name "test.outputs" 2>/dev/null
}
```

```powershell
# PowerShell
function Find-TestOutputs {
    Get-ChildItem -Path $TestlogsDir -Recurse -Directory -Filter "test.outputs" -ErrorAction SilentlyContinue
}
```

#### 2.3 Quiescence check across all directories

See Appendix A for full implementation. The uploader checks quiescence using:
- `latest_mtime_all()` - gets latest mtime of `*.json` files in `tests/` and `coverage/` subdirs only
- `count_payload_files()` - counts `*.json` files in `tests/` and `coverage/` subdirs only

**Important:** Both functions only scan the `tests/` and `coverage/` subdirectories within each `test.outputs/` directory, and only consider `*.json` files. Other files (logs, etc.) are ignored for quiescence calculation.

Since the uploader runs AFTER tests complete (`bazel run` after `bazel test`), quiescence simply waits for the filesystem to settle (`quiescent_sec`, default 10s).

#### 2.4 Upload from all directories

```bash
# Bash - use while read to handle paths with spaces safely
# Note: Uses TEST_OUTPUTS_CACHE (populated once at startup) instead of calling find_test_outputs
# repeatedly, for efficiency. See Appendix A for full caching implementation.

upload_all_tests() {
    local count=0
    while IFS= read -r outputs_dir; do
        [[ -z "$outputs_dir" ]] && continue
        local tests_dir="$outputs_dir/tests"
        [[ -d "$tests_dir" ]] || continue
        for f in "$tests_dir"/*.json; do
            [[ -f "$f" ]] || continue
            # Upload and delete on success
            if upload_single_test "$f"; then
                rm -f "$f"
                ((++count))
            fi
        done
    done < <(echo "$TEST_OUTPUTS_CACHE")
    log "uploaded $count test payloads"
}

upload_all_coverage() {
    local count=0
    while IFS= read -r outputs_dir; do
        [[ -z "$outputs_dir" ]] && continue
        local cov_dir="$outputs_dir/coverage"
        [[ -d "$cov_dir" ]] || continue
        for f in "$cov_dir"/*.json; do
            [[ -f "$f" ]] || continue
            # Upload and delete on success
            if upload_single_coverage "$f"; then
                rm -f "$f"
                ((++count))
            fi
        done
    done < <(echo "$TEST_OUTPUTS_CACHE")
    log "uploaded $count coverage payloads"
}
```

#### 2.5 Remove old parameters

**Remove from rule attributes:**
- `payloads_dir`
- `tests_subdir` (always `tests/`)
- `coverage_subdir` (always `coverage/`)

**Keep (existing):**
- `quiescent_sec` (env: `DD_TOPT_QUIESCENT_SEC`)
- `max_wait_sec` (env: `DD_TOPT_MAX_WAIT_SEC`)
- `fail_on_error`
- `debug`
- `data` (for context.json)

**Add (new):**
- `keep_payloads` (env: `DD_TOPT_KEEP_PAYLOADS`) - retain payloads after upload for debugging
- `filter_prefix` (env: `DD_TOPT_FILTER_PREFIX`) - only upload files matching `span_events_*.json` or `coverage_*.json`

---

### Phase 3: Update Uploader Rule Definition

**File:** `tools/test_optimization_uploader.bzl`

**Architectural Change: Single Uploader Per Workspace**

Users must create ONE uploader target in their workspace root (NOT per-test):

```python
# In root BUILD.bazel or a central location
load("@datadog-rules-test-optimization//tools:test_optimization_uploader.bzl", "dd_payload_uploader")

dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

**Usage:**

```bash
# RECOMMENDED: Preserve test exit code while still uploading payloads
# This pattern works with both `set -e` and without it
bazel test //... || test_status=$?; test_status=${test_status:-0}; bazel run //:dd_upload_payloads; exit $test_status

# Alternative (simpler but requires `set +e` or no errexit):
# bazel test //...; test_status=$?; bazel run //:dd_upload_payloads; exit $test_status

# PowerShell equivalent:
# $ErrorActionPreference = 'Continue'
# bazel test //...; $test_status=$LASTEXITCODE; bazel run //:dd_upload_payloads; exit $test_status

# Simple usage (WARNING: masks test failures - CI will pass even if tests fail):
# bazel test //...; bazel run //:dd_upload_payloads

# Or in CI, use a post-step/finally block to guarantee upload even on test failure
```

Since the uploader runs via `bazel run` after tests complete, all payloads are already written. The uploader waits `quiescent_sec` (default 10s) to ensure no files are still being written, then uploads all payloads and deletes them.

**CRITICAL:** Always preserve the test exit code! Using plain `;` causes CI to report success even when tests fail. Use the `|| test_status=$?` pattern shown above (safe with `set -e`).

**Note:** The uploader is a normal rule (not a test rule), so use `bazel run` not `bazel test`.

**Uploader rule design:**

- Normal rule (not test rule) - invoked via `bazel run`, not `bazel test`
- No `local = True` or `tags = ["no-sandbox"]` needed - `bazel run` runs locally with full host access
- Attributes: `quiescent_sec`, `max_wait_sec`, `fail_on_error`, `debug`, `data`, `keep_payloads`, `filter_prefix`, `gzip_payloads`

```python
dd_payload_uploader = rule(
    implementation = _uploader_impl,
    executable = True,  # Makes it runnable via `bazel run`
    attrs = {
        "quiescent_sec": attr.int(default = 10),  # Wait for filesystem to settle
        "max_wait_sec": attr.int(default = 300),  # Wait up to 5min for slow filesystems (env: DD_TOPT_MAX_WAIT_SEC)
        "fail_on_error": attr.bool(default = False),
        "debug": attr.bool(default = False),
        "keep_payloads": attr.bool(default = False),  # Keep payloads after upload for debugging (env: DD_TOPT_KEEP_PAYLOADS)
        "filter_prefix": attr.bool(default = False),  # Only upload span_events_*.json and coverage_*.json (env: DD_TOPT_FILTER_PREFIX)
        "gzip_payloads": attr.bool(default = False),  # Gzip test payloads before upload (env: DD_TOPT_GZIP)
        "data": attr.label_list(allow_files = True),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
)
# NOTE: max_wait_sec is 300s (5 minutes) by default.
# The uploader runs AFTER tests complete via `bazel run`, so we only need to wait for
# filesystem quiescence. 300s provides headroom for slow filesystems (NFS) while failing
# faster on real issues. Can be overridden via DD_TOPT_MAX_WAIT_SEC environment variable.
```

**Why a normal rule instead of a test rule:**

The uploader is invoked via `bazel run`, which:
- Runs locally (no remote execution)
- Runs without sandboxing (full host filesystem access)
- Has network access

This eliminates the need for `local = True`, `tags = ["no-sandbox"]`, or any sandbox workarounds.

**Simple uploader target:**

```python
# In BUILD.bazel at workspace root
dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

**Why `bazel run` is the right choice:**
- The uploader requires network access (inherently non-hermetic)
- The uploader reads from and deletes payloads in `bazel-testlogs/`
- `bazel run` provides all necessary access automatically

---

### Phase 4: Update Documentation

#### 4.1 README.md

**Remove:**
- References to `--sandbox_writable_path`
- References to `--test_env=TEST_OPTIMIZATION_PAYLOADS_DIR`
- References to `payloads_dir` parameter

**Update:**
- Test-time environment variables section
- Usage examples
- Troubleshooting section

**New simplified usage:**
```bash
# RECOMMENDED: Preserve test exit code while still uploading payloads
# This pattern works with both `set -e` and without it
bazel test //... || test_status=$?; test_status=${test_status:-0}; bazel run //:dd_upload_payloads; exit $test_status

# REMOTE EXECUTION (RBE) - add flag to download outputs:
bazel test //... --remote_download_outputs=all || test_status=$?; test_status=${test_status:-0}; bazel run //:dd_upload_payloads; exit $test_status

# Simple usage (WARNING: masks test failures - CI will pass even if tests fail):
# bazel test //...; bazel run //:dd_upload_payloads

# CI: Use a post-step/finally block to guarantee upload regardless of test exit code
```

#### 4.2 docs/RFC.md

**Update:**
- Required Library Changes section
- Environment variables documentation
- Detection logic

#### 4.3 AGENTS.md

**Update:**
- Consumer tips
- Environment variable references

---

### Phase 5: Update Examples

**Files:**
- `examples/single_service/src/go-project/main_test.go`
- `examples/multi_service/src/go-project/main_test.go`

**Changes:**
- Update environment variable dump to show new variables
- Remove references to `TEST_OPTIMIZATION_PAYLOADS_DIR`

---

## 4. Environment Variable Summary

### Final Environment Variables

| Variable | Set By | Value | Purpose |
|----------|--------|-------|---------|
| `TEST_OPTIMIZATION_MANIFEST_FILE` | Macro | Runfiles path to `manifest.txt` (from `topt_data["manifest_path"]`) | Read optimization data |
| `TEST_OPTIMIZATION_PAYLOADS_IN_FILES` | Macro | `"true"` | Signal to write payloads to `TEST_UNDECLARED_OUTPUTS_DIR` |

### Bazel-Provided Variables (test time - used by library)

| Variable | Set By | Purpose |
|----------|--------|---------|
| `TEST_UNDECLARED_OUTPUTS_DIR` | Bazel (test only) | Where library writes payloads |
| `TEST_SRCDIR` | Bazel (test only) | Test runfiles directory |

### Bazel-Provided Variables (uploader - `bazel run`)

| Variable | Set By | Purpose |
|----------|--------|---------|
| `BUILD_WORKSPACE_DIRECTORY` | Bazel (`bazel run`) | Workspace root for discovering `bazel-testlogs` |
| `RUNFILES_DIR` | Bazel (`bazel run`, Unix) | Runfiles directory for `context.json` lookup |
| `RUNFILES_MANIFEST_FILE` | Bazel (`bazel run`, Windows) | Runfiles manifest for `context.json` lookup (manifest-only mode) |

### Uploader Override Variables (optional)

| Variable | Set By | Purpose |
|----------|--------|---------|
| `TESTLOGS_DIR` | User (optional) | Explicit path to `bazel-testlogs` directory. Required when using `--symlink_prefix` or disabled convenience symlinks. Use same Bazel binary AND flags as tests: Bash `TESTLOGS_DIR=$(bazel "${BAZEL_FLAGS[@]}" info bazel-testlogs)` with `BAZEL_FLAGS=(...)`, PowerShell `$env:TESTLOGS_DIR = (bazel @BazelFlags info bazel-testlogs)` with `$BazelFlags = @(...)`. Fails fast if set but path doesn't exist. |

---

## 5. Detailed Code Changes

### 5.1 `tools/topt_go_test.bzl`

**Change 1: Update module docstring**
```python
# Before:
# - Use --sandbox_writable_path and --test_env=TEST_OPTIMIZATION_PAYLOADS_DIR on the CLI.

# After:
# Payloads are written to TEST_UNDECLARED_OUTPUTS_DIR automatically.
# RBE users: ensure --remote_download_outputs=all is set.
```

**Change 2: Update function signature (remove all uploader params - breaking change)**
```python
# Before:
def dd_topt_go_test(
    name,
    topt_data,
    go_test_rule,
    payloads_dir = None,
    tests_subdir = "tests",
    coverage_subdir = "coverage",
    quiescent_sec = 10,
    max_wait_sec = 1800,
    fail_on_error = False,
    uploader_debug = False,
    uploader_tags = [],
    suite_tags = [],
    **kwargs
):

# After (all uploader params removed):
def dd_topt_go_test(
    name,
    topt_data,
    go_test_rule,
    **kwargs
):
```

**Change 3: Always set `TEST_OPTIMIZATION_PAYLOADS_IN_FILES` (not conditional)**
```python
# Before:
    if payloads_dir:
        env["TEST_OPTIMIZATION_PAYLOADS_IN_FILES"] = "true"

# After:
    # Signal to library to write payloads to TEST_UNDECLARED_OUTPUTS_DIR
    # Always set - no longer conditional
    env["TEST_OPTIMIZATION_PAYLOADS_IN_FILES"] = "true"
```

**Change 4: Remove uploader creation entirely**
```python
# Before:
    # The macro created an uploader per test
    dd_payload_uploader(
        name = uploader_name,
        payloads_dir = payloads_dir,
        ...
    )

    # And a test_suite wrapping both
    native.test_suite(
        name = name,
        tests = [":" + inner_name, ":" + uploader_name],
    )

# After:
    # NO uploader created - user creates ONE uploader per workspace
    # The macro target IS the go_test directly (no test_suite wrapper)
    go_test_rule(
        name = name,  # Direct name
        ...
    )
```

**User must create a single uploader in their workspace:**
```python
# In BUILD.bazel at workspace root
dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

### 5.2 `tools/test_optimization_uploader.bzl`

See Appendix A for full bash template.
See Appendix B for full PowerShell template.

---

## 6. Testing Plan

### 6.1 Unit Tests

1. **Macro generates correct env vars**
   - `TEST_OPTIMIZATION_MANIFEST_FILE` is set
   - `TEST_OPTIMIZATION_PAYLOADS_IN_FILES` is set to `"true"`
   - No `TEST_OPTIMIZATION_PAYLOADS_DIR`

### 6.2 Integration Tests (Local)

> **Note:** These tests assume the `bazel-testlogs` convenience symlink exists (default Bazel behavior). For non-standard setups using `--symlink_prefix` or disabled convenience symlinks, use `BAZEL_FLAGS` consistently across test, info, and run commands to ensure they all use the same output base.

1. **Single test writes payloads**
   ```bash
   # For non-standard setups: BAZEL_FLAGS=("--output_base=...")
   bazel ${BAZEL_FLAGS[@]+"${BAZEL_FLAGS[@]}"} test //src:my_test --test_output=streamed
   ls ${TESTLOGS_DIR:-bazel-testlogs}/src/my_test/test.outputs/tests/
   ls ${TESTLOGS_DIR:-bazel-testlogs}/src/my_test/test.outputs/coverage/
   ```

2. **Multiple tests write payloads**
   ```bash
   bazel ${BAZEL_FLAGS[@]+"${BAZEL_FLAGS[@]}"} test //src/... --test_output=streamed
   find ${TESTLOGS_DIR:-bazel-testlogs} -name "test.outputs" -type d
   ```

3. **Uploader finds and uploads all payloads**
   ```bash
   # Set TESTLOGS_DIR if using non-standard output base (must be exported or inline)
   # export TESTLOGS_DIR=$(bazel "${BAZEL_FLAGS[@]}" info bazel-testlogs)
   bazel ${BAZEL_FLAGS[@]+"${BAZEL_FLAGS[@]}"} run //:dd_upload_payloads
   ```

4. **Sharded tests work correctly**
   ```bash
   bazel ${BAZEL_FLAGS[@]+"${BAZEL_FLAGS[@]}"} test //src:sharded_test --test_sharding_strategy=explicit --test_output=streamed
   ls ${TESTLOGS_DIR:-bazel-testlogs}/src/sharded_test/shard_*/test.outputs/
   ```

### 6.3 Integration Tests (CI)

1. **Linux (ubuntu-latest)**
   - Basic test execution
   - Payload collection
   - Upload verification

2. **macOS (macos-latest)**
   - Same as Linux

3. **Windows (windows-latest)**
   - PowerShell uploader works
   - Path handling correct
   - MANIFEST file resolution works

4. **Remote Build Execution (RBE) - if applicable**
   - Verify with `--remote_download_outputs=all` flag
   - Confirm test.outputs are downloaded locally
   - Confirm uploader finds and uploads payloads
   - Document that without this flag, uploads will be empty

### 6.4 Edge Cases

1. **No payloads generated** - Exits with success message (nothing to upload)
2. **Test crashes before writing** - Partial payloads from other tests are still uploaded
3. **Some tests fail** - Payloads from passing tests are still uploaded (use `;` not `&&` to run uploader)
4. **Large number of tests** - Performance acceptable (glob is O(n) in test count)
5. **Test with no undeclared outputs** - Skipped gracefully (no test.outputs/ directory)
6. **Stale files from previous runs** - Uploaded and deleted (cleanup behavior)

### 6.5 Execution Flow

Since the uploader runs via `bazel run` after `bazel test`, all tests complete before the uploader starts:

```
Timeline:
─────────────────────────────────────────────────────────────────────▶ time

[bazel test //...]
  [test_1]   ████████░░░░░░░░░░░░░░░░░░░░░░░░ (writes payloads, completes)
  [test_2]   ░░░░████████████░░░░░░░░░░░░░░░░ (writes payloads, completes)
  [test_3]   ░░░░░░░░░░████████████░░░░░░░░░░ (writes payloads, completes)
                                   ▲
                                   └── All tests complete

[bazel run //:dd_upload_payloads]
  [uploader] ░░░░░░░░░░░░░░░░░░░░░░░░████████ (waits quiescent_sec, uploads, deletes)
```

The uploader:
1. **Waits for quiescence** - `quiescent_sec` (default 10s) ensures filesystem is settled
2. **Uploads all payloads** - from all `test.outputs/` directories
3. **Deletes uploaded files** - prevents re-uploading on next run

---

## 7. Rollback Plan

If issues arise:

1. **Immediate**: Revert commits
2. **Test repo**: Update to previous commit hash
3. **Documentation**: Note temporary regression

---

## 8. Usage Summary

### Running Tests and Uploading Payloads

```bash
# RECOMMENDED: Preserve test exit code while still uploading payloads
bazel test //... || test_status=$?; test_status=${test_status:-0}; bazel run //:dd_upload_payloads; exit $test_status

# REMOTE EXECUTION (RBE) - add flag to download outputs:
bazel test //... --remote_download_outputs=all || test_status=$?; test_status=${test_status:-0}; bazel run //:dd_upload_payloads; exit $test_status
```

### BUILD Configuration

```python
# BUILD.bazel for each test
dd_topt_go_test(
    name = "my_test",
    ...
)

# BUILD.bazel at workspace root (ONE uploader for entire workspace)
dd_payload_uploader(
    name = "dd_upload_payloads",
    data = ["@test_optimization_data//:test_optimization_context"],
)
```

---

## 9. Appendices

### Appendix A: New Bash Uploader Template

**Note:** This template shows the new path discovery and file globbing logic. The existing upload logic (curl calls, headers, context.json enrichment via `enrich_with_context` function, retry logic) from the current implementation MUST be preserved and adapted to iterate over multiple `test.outputs/` directories.

**Runfiles Resolution:** Since `bazel run` does NOT set `TEST_SRCDIR`, the uploader uses `RUNFILES_DIR` or `RUNFILES_MANIFEST_FILE` to locate `context.json`. Both must be supported for cross-platform compatibility (Windows uses manifest-only by default):

```bash
# Support both directory and manifest-based runfiles
resolve_runfile() {
    local rloc="$1"
    # Try RUNFILES_DIR first (Unix default)
    if [[ -n "${RUNFILES_DIR:-}" && -f "$RUNFILES_DIR/$rloc" ]]; then
        echo "$RUNFILES_DIR/$rloc"
        return
    fi
    # Try $0.runfiles fallback
    if [[ -f "$0.runfiles/$rloc" ]]; then
        echo "$0.runfiles/$rloc"
        return
    fi
    # Try RUNFILES_MANIFEST_FILE (Windows/manifest-only)
    if [[ -n "${RUNFILES_MANIFEST_FILE:-}" && -f "$RUNFILES_MANIFEST_FILE" ]]; then
        local path
        # Use awk with substr() for regex-free extraction (handles metacharacters in paths)
        path=$(awk -v key="$rloc" '$1 == key { print substr($0, length(key)+2); exit }' "$RUNFILES_MANIFEST_FILE")
        if [[ -n "$path" && -f "$path" ]]; then
            echo "$path"
            return
        fi
    fi
    echo ""  # Not found
}

CONTEXT_JSON=$(resolve_runfile "test_optimization_data/context.json")
```

```bash
#!/usr/bin/env bash
set -euo pipefail

# NOTE: This is a template file. Placeholders like {quiescent_sec} are replaced
# by Starlark during rule execution. Double braces {{ and }} are literal braces
# (escaped for Python .format() compatibility).

# Logging functions (defined first so other functions can use them)
# DEBUG is set later, so we use a function that checks the variable at runtime
log() {{ echo "[dd-uploader] $1"; }}
dbg() {{ if [[ "${{DEBUG:-0}}" == "1" ]]; then echo "[dd-uploader][dbg] $1" >&2; fi }}

# Resolve runfile path for context.json lookup
# Since `bazel run` does NOT set TEST_SRCDIR, we use RUNFILES_DIR or RUNFILES_MANIFEST_FILE
resolve_runfile() {{
    local rloc="$1"
    # Try RUNFILES_DIR first (Unix default)
    if [[ -n "${{RUNFILES_DIR:-}}" && -f "$RUNFILES_DIR/$rloc" ]]; then
        echo "$RUNFILES_DIR/$rloc"
        return
    fi
    # Try $0.runfiles fallback
    if [[ -f "$0.runfiles/$rloc" ]]; then
        echo "$0.runfiles/$rloc"
        return
    fi
    # Try RUNFILES_MANIFEST_FILE (Windows/manifest-only)
    if [[ -n "${{RUNFILES_MANIFEST_FILE:-}}" && -f "$RUNFILES_MANIFEST_FILE" ]]; then
        local path
        # Use awk with substr() for regex-free extraction (handles metacharacters in paths)
        path=$(awk -v key="$rloc" '$1 == key {{ print substr($0, length(key)+2); exit }}' "$RUNFILES_MANIFEST_FILE")
        if [[ -n "$path" && -f "$path" ]]; then
            echo "$path"
            return
        fi
    fi
    echo ""  # Not found
}}

# Resolve context.json path (used by upload functions for payload enrichment)
CONTEXT_JSON=$(resolve_runfile "test_optimization_data/context.json")
if [[ -z "$CONTEXT_JSON" ]]; then
    log "warning: context.json not found in runfiles; payloads will not be enriched"
fi

# Normalize boolean value (handles True/False from Starlark, 1/0, true/false)
# Uses tr for POSIX compatibility (macOS ships with Bash 3.2 which lacks ${var,,})
normalize_bool() {{
    local val
    val=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$val" in
        1|true|yes) echo "1" ;;
        *) echo "0" ;;
    esac
}}

# Validate numeric value; exit 2 if invalid
validate_numeric() {{
    local name="$1"
    local val="$2"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        log "error: $name must be a non-negative integer, got: '$val'"
        exit 2  # Configuration error
    fi
}}

# Rule attributes (can be overridden via environment variables)
QUIESCENT_SEC=${{DD_TOPT_QUIESCENT_SEC:-{quiescent_sec}}}
MAX_WAIT_SEC=${{DD_TOPT_MAX_WAIT_SEC:-{max_wait_sec}}}
FAIL_ON_ERROR=$(normalize_bool "{fail_on_error}")
KEEP_PAYLOADS=$(normalize_bool "${{DD_TOPT_KEEP_PAYLOADS:-{keep_payloads}}}")
FILTER_PREFIX=$(normalize_bool "${{DD_TOPT_FILTER_PREFIX:-{filter_prefix}}}")
DEBUG=$(normalize_bool "{debug}")

# Validate numeric environment variables
validate_numeric "QUIESCENT_SEC" "$QUIESCENT_SEC"
validate_numeric "MAX_WAIT_SEC" "$MAX_WAIT_SEC"
if [[ -n "${{DD_TOPT_MAX_DEPTH:-}}" ]]; then
    validate_numeric "DD_TOPT_MAX_DEPTH" "$DD_TOPT_MAX_DEPTH"
fi

# Acquire exclusive lock to prevent concurrent uploaders
# Uses mkdir for portability (works on macOS which lacks flock)
# Lock is scoped to workspace to allow parallel uploads in different workspaces
# Hash generation handles both Linux (md5sum) and macOS (md5 -q) formats
compute_workspace_hash() {{
    local workspace="${{BUILD_WORKSPACE_DIRECTORY:-$(pwd)}}"
    # Try md5sum (Linux), then md5 -q (macOS), then shasum, then fallback
    if command -v md5sum >/dev/null 2>&1; then
        echo -n "$workspace" | md5sum | cut -c1-8
    elif command -v md5 >/dev/null 2>&1; then
        echo -n "$workspace" | md5 -q | cut -c1-8
    elif command -v shasum >/dev/null 2>&1; then
        echo -n "$workspace" | shasum -a 256 | cut -c1-8
    else
        echo "default"
    fi
}}
WORKSPACE_HASH=$(compute_workspace_hash)
LOCK_DIR="${{TMPDIR:-/tmp}}/dd_upload_payloads_$WORKSPACE_HASH.lock"

acquire_lock() {{
    local max_attempts=3
    local attempt=0
    while (( attempt < max_attempts )); do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo $$ > "$LOCK_DIR/pid"
            dbg "acquired lock: $LOCK_DIR (workspace hash: $WORKSPACE_HASH)"
            return 0
        fi
        # Check if lock is stale (owner process dead)
        if [[ -f "$LOCK_DIR/pid" ]]; then
            local owner_pid
            owner_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
            if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
                dbg "removing stale lock (pid $owner_pid is dead)"
                rm -rf "$LOCK_DIR" 2>/dev/null || true
                ((++attempt))
                continue
            fi
        fi
        log "error: another uploader is already running (lock: $LOCK_DIR)"
        log "hint: wait for the other uploader to finish, or remove the lock directory if stale"
        return 1
    done
    return 1
}}

if ! acquire_lock; then
    exit 2
fi

# Cleanup lock on exit
cleanup() {{
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}}
trap cleanup EXIT

# Determine bazel-testlogs directory
# Priority: TESTLOGS_DIR env var > BUILD_WORKSPACE_DIRECTORY/bazel-testlogs > ./bazel-testlogs
#
# NOTE: We intentionally do NOT call `bazel info` from within the uploader.
# Running `bazel info` inside `bazel run` can deadlock when the output base is locked.
# For non-standard setups (--symlink_prefix, disabled symlinks), users should set
# TESTLOGS_DIR externally using the same Bazel binary AND flags as for 'bazel test':
#   BAZEL_FLAGS=("--output_base=/custom/base")
#   TESTLOGS_DIR=$(bazel "${BAZEL_FLAGS[@]}" info bazel-testlogs) bazel "${BAZEL_FLAGS[@]}" run ...

# Check explicit TESTLOGS_DIR override first (fail fast if set but invalid)
if [[ -n "${{TESTLOGS_DIR:-}}" ]]; then
    if [[ -d "$TESTLOGS_DIR" ]]; then
        dbg "using explicit TESTLOGS_DIR=$TESTLOGS_DIR"
    else
        log "error: TESTLOGS_DIR is set but path does not exist: $TESTLOGS_DIR"
        log "hint: ensure you used the same Bazel wrapper for 'bazel info' as for 'bazel test'"
        exit 2  # Configuration error (see exit codes in docs)
    fi
else
    # Auto-discover testlogs directory
    if [[ -n "${{BUILD_WORKSPACE_DIRECTORY:-}}" ]]; then
        candidate="$BUILD_WORKSPACE_DIRECTORY/bazel-testlogs"
        if [[ -d "$candidate" ]] || [[ -L "$candidate" ]]; then
            TESTLOGS_DIR="$candidate"
        fi
    fi

    if [[ -z "${{TESTLOGS_DIR:-}}" ]] && {{ [[ -d "bazel-testlogs" ]] || [[ -L "bazel-testlogs" ]]; }}; then
        TESTLOGS_DIR="$(pwd)/bazel-testlogs"
    fi

    if [[ -z "${{TESTLOGS_DIR:-}}" ]]; then
        log "warning: testlogs dir not found (nothing to upload)"
        log "hint: set TESTLOGS_DIR env var, or ensure bazel-testlogs symlink exists"
        # Exit 0 by default (graceful no-op), but respect FAIL_ON_ERROR to catch misconfigurations
        if [[ "$FAIL_ON_ERROR" == "1" ]]; then
            log "error: FAIL_ON_ERROR is set and no testlogs found - this may indicate misconfiguration"
            exit 2  # Configuration error
        fi
        exit 0
    fi

    dbg "auto-discovered TESTLOGS_DIR=$TESTLOGS_DIR"
fi

# Find all test.outputs directories
# Supports DD_TOPT_MAX_DEPTH to limit search depth for large testlogs trees
MAX_DEPTH=${{DD_TOPT_MAX_DEPTH:-0}}
find_test_outputs() {{
    local depth_args=()
    if (( MAX_DEPTH > 0 )); then
        depth_args=(-maxdepth "$MAX_DEPTH")
        dbg "limiting find depth to $MAX_DEPTH"
    fi
    find "$TESTLOGS_DIR" "${{depth_args[@]}}" -type d -name "test.outputs" 2>/dev/null || true
}}

# Warn if MAX_DEPTH is set and no test.outputs found (likely depth too shallow)
# Note: Must be called AFTER cache_test_outputs to use the cache
check_depth_warning() {{
    if [[ -z "$TEST_OUTPUTS_CACHE" ]] && (( MAX_DEPTH > 0 )); then
        log "warning: DD_TOPT_MAX_DEPTH=$MAX_DEPTH may be too shallow"
        log "hint: typical test.outputs paths require depth 3-5; try increasing or removing the limit"
    fi
}}

# Detect OS for stat command differences
IS_MACOS=0
if [[ "$(uname -s)" == "Darwin" ]]; then
    IS_MACOS=1
fi
dbg "OS detection: IS_MACOS=$IS_MACOS (uname=$(uname -s))"

# Get latest mtime across tests/ and coverage/ subdirs in all test.outputs directories
# Note: Only scans payload directories, not all files under test.outputs
latest_mtime_all() {{
    local max_mtime=0
    while IFS= read -r outputs_dir; do
        [[ -z "$outputs_dir" ]] && continue
        for subdir in "tests" "coverage"; do
            local dir="$outputs_dir/$subdir"
            [[ -d "$dir" ]] || continue
            local mt
            if (( IS_MACOS == 1 )); then
                mt=$(find "$dir" -type f -name "*.json" -exec stat -f '%m' {{}} + 2>/dev/null | sort -nr | head -1 || echo 0)
            else
                mt=$(find "$dir" -type f -name "*.json" -exec stat -c '%Y' {{}} + 2>/dev/null | sort -nr | head -1 || echo 0)
            fi
            mt=${{mt:-0}}
            if (( mt > max_mtime )); then
                max_mtime=$mt
            fi
        done
    done < <(echo "$TEST_OUTPUTS_CACHE")
    echo "$max_mtime"
}}

# Count total payload files across all test.outputs (only tests/ and coverage/ subdirs)
count_payload_files() {{
    local count=0
    while IFS= read -r outputs_dir; do
        [[ -z "$outputs_dir" ]] && continue
        local tests_dir="$outputs_dir/tests"
        local cov_dir="$outputs_dir/coverage"
        if [[ -d "$tests_dir" ]]; then
            local tests_count
            tests_count=$(find "$tests_dir" -name "*.json" 2>/dev/null | wc -l)
            count=$((count + tests_count))
        fi
        if [[ -d "$cov_dir" ]]; then
            local cov_count
            cov_count=$(find "$cov_dir" -name "*.json" 2>/dev/null | wc -l)
            count=$((count + cov_count))
        fi
    done < <(echo "$TEST_OUTPUTS_CACHE")
    echo "$count"
}}

start_ts=$(date +%s)
dbg "Uploader start time: $start_ts"

# Detect if tests actually ran by looking for test.log or test.xml files
# This helps distinguish "no payloads because tests didn't run" from "tests ran but dd-trace-go is misconfigured"
tests_executed() {{
    local count
    count=$(find "$TESTLOGS_DIR" \( -name "test.log" -o -name "test.xml" \) -type f 2>/dev/null | head -1 | wc -l)
    (( count > 0 ))
}}

# Wait for quiescence (filesystem to settle)
# Since the uploader runs AFTER tests complete (via `bazel run` after `bazel test`),
# we just need a short quiescence period to ensure all files are written.
dbg "Waiting for test outputs to quiesce..."

# Cache the list of test.outputs directories for efficiency (avoid rescanning on each loop iteration)
TEST_OUTPUTS_CACHE=""
cache_test_outputs() {{
    TEST_OUTPUTS_CACHE=$(find_test_outputs)
}}
cache_test_outputs
check_depth_warning  # Warn if MAX_DEPTH may be too shallow

while true; do
    now=$(date +%s)
    elapsed=$((now - start_ts))

    if (( elapsed > MAX_WAIT_SEC )); then
        log "max wait exceeded ($MAX_WAIT_SEC s); proceeding to upload"
        break
    fi

    total_files=$(count_payload_files)

    if (( total_files == 0 )); then
        if tests_executed; then
            log "warning: tests ran but no payload files found"
            log "hint: ensure dd-trace-go >= X.Y.Z (minimum version) is installed"
            log "hint: check that TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true is set"
            if [[ "$FAIL_ON_ERROR" == "1" ]]; then
                log "error: FAIL_ON_ERROR is set; failing due to missing payloads"
                exit 1
            fi
        else
            log "no payload files found and no test execution detected; nothing to upload"
        fi
        exit 0
    fi

    # Check if files have been stable for QUIESCENT_SEC
    cur=$(latest_mtime_all)
    idle=$((now - cur))
    dbg "total_files=$total_files, idle=$idle s"

    if (( idle >= QUIESCENT_SEC )); then
        log "outputs quiescent for $idle s ($total_files files); starting upload"
        break
    fi

    sleep 2
done

# Upload all files, then delete them after successful upload

# Check if file matches prefix filter (when enabled)
matches_filter() {{
    local file="$1"
    local expected_prefix="$2"
    if [[ "$FILTER_PREFIX" == "1" ]]; then
        local basename
        basename=$(basename "$file")
        [[ "$basename" == "$expected_prefix"* ]]
    else
        return 0  # No filtering, accept all
    fi
}}

# Delete file unless KEEP_PAYLOADS is set
cleanup_file() {{
    local file="$1"
    if [[ "$KEEP_PAYLOADS" != "1" ]]; then
        rm -f "$file"
    else
        dbg "keeping payload (KEEP_PAYLOADS=1): $file"
    fi
}}

# Track upload failures globally
UPLOAD_FAILURES=0

# Upload a single test payload file to Datadog
# PRESERVED FROM EXISTING IMPLEMENTATION: This function contains the HTTP upload logic
# (curl calls with headers, context.json enrichment, retry logic). The existing
# implementation must be adapted to:
# 1. Read context.json from runfiles via resolve_runfile()
# 2. Use the established endpoint and authentication headers
# Returns 0 on success, non-zero on failure
upload_single_test() {{
    local file="$1"
    # ... existing upload logic from current uploader template ...
    # Example structure (actual implementation preserved from current code):
    # local context_json
    # context_json=$(resolve_runfile "test_optimization_data/context.json")
    # curl -X POST "$UPLOAD_ENDPOINT/tests" \
    #     -H "Content-Type: application/json" \
    #     -H "DD-API-KEY: $DD_API_KEY" \
    #     --data-binary @"$file" \
    #     --fail --silent --show-error
    return 0  # Placeholder - actual implementation preserved from existing code
}}

# Upload a single coverage payload file to Datadog
# PRESERVED FROM EXISTING IMPLEMENTATION: Same pattern as upload_single_test
# but uses the coverage endpoint
upload_single_coverage() {{
    local file="$1"
    # ... existing upload logic from current uploader template ...
    return 0  # Placeholder - actual implementation preserved from existing code
}}

upload_all_tests() {{
    local total=0
    local failed=0
    local skipped=0
    while IFS= read -r outputs_dir; do
        [[ -z "$outputs_dir" ]] && continue
        local tests_dir="$outputs_dir/tests"
        [[ -d "$tests_dir" ]] || continue

        for f in "$tests_dir"/*.json; do
            [[ -f "$f" ]] || continue
            # Skip files not matching prefix filter (when enabled)
            if ! matches_filter "$f" "span_events_"; then
                dbg "skipping (prefix filter): $f"
                ((++skipped))
                continue
            fi
            # ... upload logic for single file (preserved from current impl) ...
            # Per-file success: only delete files that uploaded successfully
            if upload_single_test "$f"; then
                cleanup_file "$f"
                ((++total))
            else
                log "warning: failed to upload $f"
                ((++failed))
                ((++UPLOAD_FAILURES))
            fi
        done
    done < <(echo "$TEST_OUTPUTS_CACHE")
    log "uploaded $total test payloads"
    if (( failed > 0 )); then
        log "warning: $failed test payloads failed to upload"
    fi
    if (( skipped > 0 )); then
        dbg "skipped $skipped files (prefix filter)"
    fi
}}

upload_all_coverage() {{
    local total=0
    local failed=0
    local skipped=0
    while IFS= read -r outputs_dir; do
        [[ -z "$outputs_dir" ]] && continue
        local cov_dir="$outputs_dir/coverage"
        [[ -d "$cov_dir" ]] || continue

        for f in "$cov_dir"/*.json; do
            [[ -f "$f" ]] || continue
            # Skip files not matching prefix filter (when enabled)
            if ! matches_filter "$f" "coverage_"; then
                dbg "skipping (prefix filter): $f"
                ((++skipped))
                continue
            fi
            # ... upload logic for single file (preserved from current impl) ...
            # Per-file success: only delete files that uploaded successfully
            if upload_single_coverage "$f"; then
                cleanup_file "$f"
                ((++total))
            else
                log "warning: failed to upload $f"
                ((++failed))
                ((++UPLOAD_FAILURES))
            fi
        done
    done < <(echo "$TEST_OUTPUTS_CACHE")
    log "uploaded $total coverage payloads"
    if (( failed > 0 )); then
        log "warning: $failed coverage payloads failed to upload"
    fi
    if (( skipped > 0 )); then
        dbg "skipped $skipped files (prefix filter)"
    fi
}}

upload_all_tests
upload_all_coverage

# Exit with appropriate code based on upload results
if (( UPLOAD_FAILURES > 0 )); then
    log "done with $UPLOAD_FAILURES upload failures"
    exit 1
else
    log "done"
    exit 0
fi
```

### Appendix B: New PowerShell Uploader Template

**Note:** This template shows the new path discovery and file globbing logic. The existing upload logic (HttpClient calls, headers, context.json enrichment via `Merge-With-Context` function, retry logic) from the current implementation MUST be preserved and adapted to iterate over multiple `test.outputs/` directories.

**Runfiles Resolution Change:** Since `bazel run` does NOT set `TEST_SRCDIR`, the uploader must use `RUNFILES_DIR` or `RUNFILES_MANIFEST_FILE` to locate `context.json`. Both must be supported since Windows uses manifest-only by default:

```powershell
# OLD (test rule): context via TEST_SRCDIR
# $ContextJson = Join-Path $env:TEST_SRCDIR "test_optimization_data/context.json"

# NEW (bazel run): support both directory and manifest-based runfiles
function Resolve-Runfile {
    param([string]$Rloc)

    # Try RUNFILES_DIR first
    if ($env:RUNFILES_DIR) {
        $candidate = Join-Path $env:RUNFILES_DIR $Rloc
        if (Test-Path $candidate) { return $candidate }
    }

    # Try $PSScriptRoot.runfiles fallback
    $candidate = Join-Path "$PSScriptRoot.runfiles" $Rloc
    if (Test-Path $candidate) { return $candidate }

    # Try RUNFILES_MANIFEST_FILE (Windows default)
    if ($env:RUNFILES_MANIFEST_FILE -and (Test-Path $env:RUNFILES_MANIFEST_FILE)) {
        $manifest = Get-Content $env:RUNFILES_MANIFEST_FILE
        foreach ($line in $manifest) {
            if ($line.StartsWith("$Rloc ")) {
                $path = $line.Substring($Rloc.Length + 1)
                if (Test-Path $path) { return $path }
            }
        }
    }

    return $null  # Not found
}

$ContextJson = Resolve-Runfile "test_optimization_data/context.json"
```

```powershell
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Resolve runfile path for context.json lookup
# Since `bazel run` does NOT set TEST_SRCDIR, we use RUNFILES_DIR or RUNFILES_MANIFEST_FILE
function Resolve-Runfile {{
    param([string]$Rloc)

    # Try RUNFILES_DIR first
    if ($env:RUNFILES_DIR) {{
        $candidate = Join-Path $env:RUNFILES_DIR $Rloc
        if (Test-Path $candidate) {{ return $candidate }}
    }}

    # Try $PSScriptRoot.runfiles fallback
    $candidate = Join-Path "$PSScriptRoot.runfiles" $Rloc
    if (Test-Path $candidate) {{ return $candidate }}

    # Try RUNFILES_MANIFEST_FILE (Windows default)
    if ($env:RUNFILES_MANIFEST_FILE -and (Test-Path $env:RUNFILES_MANIFEST_FILE)) {{
        $manifest = Get-Content $env:RUNFILES_MANIFEST_FILE
        foreach ($line in $manifest) {{
            if ($line.StartsWith("$Rloc ")) {{
                $path = $line.Substring($Rloc.Length + 1)
                if (Test-Path $path) {{ return $path }}
            }}
        }}
    }}

    return $null  # Not found
}}

# Logging functions (defined early so other functions can use them)
# Note: $Debug is set later, so Dbg checks the variable at runtime
$script:DebugMode = $false  # Will be set properly after Normalize-Bool is defined
function Log([string]$msg) {{ Write-Output "[dd-uploader] $msg" }}
function Dbg([string]$msg) {{ if ($script:DebugMode) {{ Write-Output "[dd-uploader][dbg] $msg" }} }}

# Resolve context.json path (used by upload functions for payload enrichment)
$script:ContextJson = Resolve-Runfile "test_optimization_data/context.json"
if (-not $script:ContextJson) {{
    Log "warning: context.json not found in runfiles; payloads will not be enriched"
}}

# Normalize boolean value (handles True/False from Starlark, 1/0, true/false)
function Normalize-Bool([string]$val) {{
    switch ($val.ToLower()) {{
        {{ $_ -in '1', 'true', 'yes' }} {{ return $true }}
        default {{ return $false }}
    }}
}}

# Validate numeric value; exit 2 if invalid
function Validate-Numeric([string]$name, [string]$val) {{
    if ($val -notmatch '^\d+$') {{
        Log "error: $name must be a non-negative integer, got: '$val'"
        exit 2  # Configuration error
    }}
}}

# Rule attributes (can be overridden via environment variables)
$QuiescentSec = if ($env:DD_TOPT_QUIESCENT_SEC) {{ $env:DD_TOPT_QUIESCENT_SEC }} else {{ "{quiescent_sec}" }}
$MaxWaitSec = if ($env:DD_TOPT_MAX_WAIT_SEC) {{ $env:DD_TOPT_MAX_WAIT_SEC }} else {{ "{max_wait_sec}" }}
$MaxDepth = if ($env:DD_TOPT_MAX_DEPTH) {{ $env:DD_TOPT_MAX_DEPTH }} else {{ "0" }}

# Validate numeric values before conversion
Validate-Numeric "QUIESCENT_SEC" $QuiescentSec
Validate-Numeric "MAX_WAIT_SEC" $MaxWaitSec
Validate-Numeric "MAX_DEPTH" $MaxDepth

$QuiescentSec = [int]$QuiescentSec
$MaxWaitSec = [int]$MaxWaitSec
$MaxDepth = [int]$MaxDepth

$FailOnError = Normalize-Bool "{fail_on_error}"
$KeepPayloads = if ($env:DD_TOPT_KEEP_PAYLOADS) {{ Normalize-Bool $env:DD_TOPT_KEEP_PAYLOADS }} else {{ Normalize-Bool "{keep_payloads}" }}
$FilterPrefix = if ($env:DD_TOPT_FILTER_PREFIX) {{ Normalize-Bool $env:DD_TOPT_FILTER_PREFIX }} else {{ Normalize-Bool "{filter_prefix}" }}
$Debug = Normalize-Bool "{debug}"

# Now that $Debug is set, update the script-level debug mode for Dbg function
$script:DebugMode = $Debug

# Acquire exclusive lock to prevent concurrent uploaders
# Lock is scoped to workspace to allow parallel uploads in different workspaces
$WorkspacePath = if ($env:BUILD_WORKSPACE_DIRECTORY) {{ $env:BUILD_WORKSPACE_DIRECTORY }} else {{ (Get-Location).Path }}
$WorkspaceHash = [System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($WorkspacePath))).Replace("-","").Substring(0,8)
$LockFile = Join-Path $env:TEMP "dd_upload_payloads_$WorkspaceHash.lock"

function Acquire-Lock {{
    $maxAttempts = 3
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {{
        try {{
            $script:LockStream = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
            Dbg "acquired lock: $LockFile (workspace hash: $WorkspaceHash)"
            return $true
        }} catch {{
            # Check if lock file is stale (no process holding it, but file exists)
            if (Test-Path $LockFile) {{
                $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
                if ($lockAge.TotalMinutes -gt 30) {{
                    Dbg "removing stale lock (age: $($lockAge.TotalMinutes) minutes)"
                    Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
                    continue
                }}
            }}
        }}
    }}
    return $false
}}

if (-not (Acquire-Lock)) {{
    Log "error: another uploader is already running (lock: $LockFile)"
    Log "hint: wait for the other uploader to finish, or remove the lock file if stale"
    exit 2
}}

# Cleanup function for lock release
function Release-Lock {{
    if ($script:LockStream) {{
        $script:LockStream.Close()
        $script:LockStream = $null
        Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
    }}
}}

# Register cleanup on exit (backup for unexpected termination)
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {{ Release-Lock }}

# Determine bazel-testlogs directory
# Priority: TESTLOGS_DIR env var > BUILD_WORKSPACE_DIRECTORY/bazel-testlogs > ./bazel-testlogs
#
# NOTE: We intentionally do NOT call `bazel info` from within the uploader.
# Running `bazel info` inside `bazel run` can deadlock when the output base is locked.
# For non-standard setups (--symlink_prefix, disabled symlinks), users should set
# TESTLOGS_DIR externally using the same Bazel binary AND flags as for 'bazel test':
#   $BazelFlags = @("--output_base=/custom/base")
#   $env:TESTLOGS_DIR = (bazel @BazelFlags info bazel-testlogs); bazel @BazelFlags run ...

# Check explicit TESTLOGS_DIR override first (fail fast if set but invalid)
if ($env:TESTLOGS_DIR) {{
    if (Test-Path $env:TESTLOGS_DIR) {{
        $TestlogsDir = $env:TESTLOGS_DIR
        Dbg "using explicit TESTLOGS_DIR=$TestlogsDir"
    }} else {{
        Log "error: TESTLOGS_DIR is set but path does not exist: $($env:TESTLOGS_DIR)"
        Log "hint: ensure you used the same Bazel wrapper for 'bazel info' as for 'bazel test'"
        Release-Lock
        exit 2  # Configuration error (see exit codes in docs)
    }}
}} else {{
    # Auto-discover testlogs directory
    $TestlogsDir = $null

    if ($env:BUILD_WORKSPACE_DIRECTORY) {{
        $candidate = Join-Path $env:BUILD_WORKSPACE_DIRECTORY "bazel-testlogs"
        if (Test-Path $candidate) {{ $TestlogsDir = $candidate }}
    }}

    if (-not $TestlogsDir) {{
        $candidate = Join-Path (Get-Location) "bazel-testlogs"
        if (Test-Path $candidate) {{ $TestlogsDir = $candidate }}
    }}

    if (-not $TestlogsDir) {{
        Log "warning: testlogs dir not found (nothing to upload)"
        Log "hint: set TESTLOGS_DIR env var, or ensure bazel-testlogs symlink exists"
        # Exit 0 by default (graceful no-op), but respect FailOnError to catch misconfigurations
        if ($FailOnError) {{
            Log "error: FailOnError is set and no testlogs found - this may indicate misconfiguration"
            Release-Lock
            exit 2  # Configuration error
        }}
        Release-Lock
        exit 0
    }}

    Dbg "auto-discovered TestlogsDir=$TestlogsDir"
}}

# Find all test.outputs directories (supports DD_TOPT_MAX_DEPTH to limit search depth)
# Note: -Depth parameter requires PowerShell 7+; on older versions, depth limiting is ignored
function Find-TestOutputs {{
    $params = @{{
        Path = $TestlogsDir
        Recurse = $true
        Directory = $true
        Filter = "test.outputs"
        ErrorAction = 'SilentlyContinue'
    }}
    if ($MaxDepth -gt 0) {{
        # -Depth is only available in PowerShell 7+
        if ($PSVersionTable.PSVersion.Major -ge 7) {{
            $params['Depth'] = $MaxDepth
            Dbg "limiting search depth to $MaxDepth"
        }} else {{
            Dbg "warning: DD_TOPT_MAX_DEPTH ignored (requires PowerShell 7+, have $($PSVersionTable.PSVersion))"
        }}
    }}
    Get-ChildItem @params
}}

# Cache the list of test.outputs directories for efficiency (avoid rescanning on each loop iteration)
$script:TestOutputsCache = @()
function Update-TestOutputsCache {{
    $script:TestOutputsCache = @(Find-TestOutputs)
}}

function Get-LatestMTimeAll {{
    $maxTime = [DateTime]::MinValue
    foreach ($outputsDir in $script:TestOutputsCache) {{
        foreach ($subdir in @("tests", "coverage")) {{
            $dir = Join-Path $outputsDir.FullName $subdir
            if (-not (Test-Path $dir)) {{ continue }}
            $files = Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue
            foreach ($file in $files) {{
                if ($file.LastWriteTime -gt $maxTime) {{
                    $maxTime = $file.LastWriteTime
                }}
            }}
        }}
    }}
    return $maxTime
}}

function Count-PayloadFiles {{
    $count = 0
    foreach ($outputsDir in $script:TestOutputsCache) {{
        $testsDir = Join-Path $outputsDir.FullName "tests"
        $covDir = Join-Path $outputsDir.FullName "coverage"
        if (Test-Path $testsDir) {{
            $count += @(Get-ChildItem -Path $testsDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
        }}
        if (Test-Path $covDir) {{
            $count += @(Get-ChildItem -Path $covDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
        }}
    }}
    return $count
}}

# Detect if tests actually ran by looking for test.log or test.xml files
# This helps distinguish "no payloads because tests didn't run" from "tests ran but dd-trace-go is misconfigured"
function Test-ExecutedTests {{
    $testFiles = Get-ChildItem -Path $TestlogsDir -Recurse -File -Include @("test.log", "test.xml") -ErrorAction SilentlyContinue | Select-Object -First 1
    return $null -ne $testFiles
}}

# Wait for quiescence (filesystem to settle)
# Since the uploader runs AFTER tests complete (via `bazel run` after `bazel test`),
# we just need a short quiescence period to ensure all files are written.
$start = Get-Date
Dbg "Uploader start time: $start"

# Initialize the cache
Update-TestOutputsCache

while ($true) {{
    $elapsed = ((Get-Date) - $start).TotalSeconds

    if ($elapsed -gt $MaxWaitSec) {{
        Log "max wait exceeded ($MaxWaitSec s); proceeding to upload"
        break
    }}

    $totalFiles = Count-PayloadFiles

    if ($totalFiles -eq 0) {{
        if (Test-ExecutedTests) {{
            Log "warning: tests ran but no payload files found"
            Log "hint: ensure dd-trace-go >= X.Y.Z (minimum version) is installed"
            Log "hint: check that TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true is set"
            if ($FailOnError) {{
                Log "error: FailOnError is set; failing due to missing payloads"
                Release-Lock
                exit 1
            }}
        }} else {{
            Log "no payload files found and no test execution detected; nothing to upload"
        }}
        Release-Lock
        exit 0
    }}

    # Check if files have been stable for QuiescentSec
    $latestTime = Get-LatestMTimeAll
    $idle = ((Get-Date) - $latestTime).TotalSeconds
    Dbg "total_files=$totalFiles, idle=$idle s"

    if ($idle -ge $QuiescentSec) {{
        Log "outputs quiescent for $idle s ($totalFiles files); starting upload"
        break
    }}

    Start-Sleep -Seconds 2
}}

# Check if file matches prefix filter (when enabled)
function Test-PrefixFilter([string]$FilePath, [string]$ExpectedPrefix) {{
    if (-not $FilterPrefix) {{ return $true }}  # No filtering, accept all
    $basename = Split-Path -Leaf $FilePath
    return $basename.StartsWith($ExpectedPrefix)
}}

# Delete file unless KeepPayloads is set
function Remove-PayloadFile([string]$FilePath) {{
    if (-not $KeepPayloads) {{
        Remove-Item -LiteralPath $FilePath -Force
    }} else {{
        Dbg "keeping payload (KEEP_PAYLOADS=1): $FilePath"
    }}
}}

# Track upload failures globally
$script:UploadFailures = 0

# Upload a single test payload file to Datadog
# PRESERVED FROM EXISTING IMPLEMENTATION: This function contains the HTTP upload logic
# (HttpClient calls, headers, context.json enrichment, retry logic). The existing
# implementation must be adapted to:
# 1. Read context.json from runfiles via Resolve-Runfile
# 2. Use the established endpoint and authentication headers
# Returns $true on success, $false on failure
function Upload-SingleTest([string]$FilePath) {{
    # ... existing upload logic from current uploader template ...
    # Example structure (actual implementation preserved from current code):
    # $contextJson = Resolve-Runfile "test_optimization_data/context.json"
    # Invoke-RestMethod -Uri "$UploadEndpoint/tests" -Method Post ...
    return $true  # Placeholder - actual implementation preserved from existing code
}}

# Upload a single coverage payload file to Datadog
# PRESERVED FROM EXISTING IMPLEMENTATION: Same pattern as Upload-SingleTest
# but uses the coverage endpoint
function Upload-SingleCoverage([string]$FilePath) {{
    # ... existing upload logic from current uploader template ...
    return $true  # Placeholder - actual implementation preserved from existing code
}}

function Upload-AllTests {{
    $total = 0
    $failed = 0
    $skipped = 0
    foreach ($outputsDir in $script:TestOutputsCache) {{
        $testsDir = Join-Path $outputsDir.FullName "tests"
        if (-not (Test-Path $testsDir)) {{ continue }}
        $files = Get-ChildItem -Path $testsDir -Filter "*.json" -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {{
            if (-not (Test-PrefixFilter $f.FullName "span_events_")) {{
                Dbg "skipping (prefix filter): $($f.FullName)"
                $skipped++
                continue
            }}
            if (Upload-SingleTest $f.FullName) {{
                Remove-PayloadFile $f.FullName
                $total++
            }} else {{
                Log "warning: failed to upload $($f.FullName)"
                $failed++
                $script:UploadFailures++
            }}
        }}
    }}
    Log "uploaded $total test payloads"
    if ($failed -gt 0) {{ Log "warning: $failed test payloads failed to upload" }}
    if ($skipped -gt 0) {{ Dbg "skipped $skipped files (prefix filter)" }}
}}

function Upload-AllCoverage {{
    $total = 0
    $failed = 0
    $skipped = 0
    foreach ($outputsDir in $script:TestOutputsCache) {{
        $covDir = Join-Path $outputsDir.FullName "coverage"
        if (-not (Test-Path $covDir)) {{ continue }}
        $files = Get-ChildItem -Path $covDir -Filter "*.json" -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {{
            if (-not (Test-PrefixFilter $f.FullName "coverage_")) {{
                Dbg "skipping (prefix filter): $($f.FullName)"
                $skipped++
                continue
            }}
            if (Upload-SingleCoverage $f.FullName) {{
                Remove-PayloadFile $f.FullName
                $total++
            }} else {{
                Log "warning: failed to upload $($f.FullName)"
                $failed++
                $script:UploadFailures++
            }}
        }}
    }}
    Log "uploaded $total coverage payloads"
    if ($failed -gt 0) {{ Log "warning: $failed coverage payloads failed to upload" }}
    if ($skipped -gt 0) {{ Dbg "skipped $skipped files (prefix filter)" }}
}}

# Main upload logic wrapped in try/finally for proper cleanup
try {{
    Upload-AllTests
    Upload-AllCoverage

    # Exit with appropriate code based on upload results
    if ($script:UploadFailures -gt 0) {{
        Log "done with $($script:UploadFailures) upload failures"
        exit 1
    }} else {{
        Log "done"
        exit 0
    }}
}} finally {{
    Release-Lock
}}
```

---

## 10. Success Criteria

1. **No CLI flags required for local execution** (RBE requires `--remote_download_outputs=all`)
2. **All tests write payloads** to `TEST_UNDECLARED_OUTPUTS_DIR`
3. **Uploader collects from all** `bazel-testlogs/*/test.outputs/`
4. **CI passes** on Linux, macOS, and Windows
5. **Documentation is clear** - includes network/filesystem/RBE requirements
6. **Clean API** - all unused parameters removed (breaking change accepted)
7. **Simple quiescence** - wait for filesystem to settle, upload all, cleanup after
8. **Uploader invoked via `bazel run`** - normal rule with full host access

---

## 11. Implementation Phases Summary

| Phase | Description | Key Changes |
|-------|-------------|-------------|
| 1 | Update macro | Remove per-test uploader, macro creates only go_test, remove all uploader params |
| 2 | Update uploader scripts | Simple quiescence, glob `test.outputs/`, cleanup after upload, prefix filter option, keep payloads option |
| 3 | Update uploader rule | Change to normal rule with `executable=True`, single target per workspace, new attrs: `keep_payloads`, `filter_prefix` |
| 4 | Update documentation | Document single-uploader pattern, `bazel run` usage, RBE requirements, multi-service strategy, **dd-trace-go minimum version** |
| 5 | Update examples | Show single uploader target, `bazel run` invocation, multi-service example |
| 6 | Testing | Verify on Linux, macOS, Windows; test cleanup after upload, test sharded/retry discovery, **test multi-service payloads preserve service fields** |

---

## 12. Open Questions (Resolved)

1. **Context.json enrichment**: Currently the uploader enriches payloads with `context.json`. Should this still happen, and how does it work with multiple test.outputs directories?
   - **Answer**: Yes, same enrichment logic applies to each payload file regardless of source directory.

2. **Uploader type**: Should the uploader be a test target or a `bazel run` target?
   - **Decision**: Use normal rule with `bazel run`. This eliminates sandbox workarounds (`local=True`, `tags=["no-sandbox"]`) and provides simpler access to host filesystem and network.

3. **Cleanup of old payloads**: Should the uploader clean up after successful upload?
   - **Decision**: **YES** - uploader MUST delete payloads after successful upload (by default).
   - **Rationale**: Without cleanup, stale payloads from prior runs or cached tests will be re-uploaded, causing duplicates and potentially wrong data.
   - **Implementation**: After successful upload, `rm -f "$file"` to delete the payload.
   - **Debug option**: Set `DD_TOPT_KEEP_PAYLOADS=1` to retain payloads for debugging or re-upload after fixing credentials/network issues.

4. **Deduplication**: If the same test runs multiple times (flaky test retries), could we get duplicate uploads?
   - **Answer**: Each run gets a separate directory (`run_N_of_M`), so no filename collisions. The backend should handle potential duplicates.

5. **Stale payload handling**: How to handle payloads from prior runs?
   - **Decision**: Simple quiescence + upload all + cleanup:
     1. **Wait for filesystem to settle** (`quiescent_sec`, default 10s)
     2. **Upload ALL files** - no filtering by default (enable prefix filtering with `DD_TOPT_FILTER_PREFIX=1`)
     3. **Cleanup after upload** - delete uploaded files (disable with `DD_TOPT_KEEP_PAYLOADS=1`)
   - **Rationale**:
     - Since uploader runs AFTER tests complete (`bazel run` after `bazel test`), all files are already written
     - Simple quiescence ensures filesystem is settled
     - Uploading all files (including any stale from prior runs) cleans up the workspace
     - Backend should handle duplicate/stale data gracefully
   - **Prefix filter option**: Set `DD_TOPT_FILTER_PREFIX=1` to only upload files matching known prefixes (`span_events_*.json`, `coverage_*.json`). This prevents uploading unrelated JSON files that may exist in the same directories.

6. **Scheduling gap**: How to ensure uploader runs after all tests complete?
   - **Decision**: Use `bazel run` after `bazel test` - tests are guaranteed complete before uploader starts.
   - **Usage**: `bazel test //... || test_status=$?; test_status=${test_status:-0}; bazel run //:dd_upload_payloads; exit $test_status` (preserves test exit code while ensuring upload runs)

7. **Multiple uploaders racing**: What if multiple uploaders run concurrently?
   - **Decision**: Design enforces SINGLE uploader per workspace.
   - **Rationale**: Multiple uploaders scanning all `test.outputs/` would race and delete each other's payloads.
   - **Implementation**: Macro no longer creates per-test uploaders; user creates ONE uploader target.
   - **Documentation**: Must clearly warn against running multiple uploaders.

8. **Library version requirements**: What if users have an older dd-trace-go without `TEST_UNDECLARED_OUTPUTS_DIR` support?
   - **Decision**: Document minimum required version (TBD during implementation).
   - **Behavior**: Older versions will silently fall back to network mode (no file output), resulting in empty uploads.
   - **Recommendation**: The updated dd-trace-go should log a warning when `TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true` but `TEST_UNDECLARED_OUTPUTS_DIR` is not set.

9. **Multi-service repositories**: How do monorepos with multiple services use the single uploader?
   - **Decision**: Single uploader with workspace-level `context.json`; service-specific metadata embedded in payloads.
   - **Rationale**: The uploader collects payloads from ALL `test.outputs/` directories regardless of service; per-service context (service name, module) must be embedded by dd-trace-go at runtime.
   - **Documentation**: Multi-service strategy documented in section 2.6.

10. **Timeout for slow filesystems**: Is the originally proposed `max_wait_sec` (120s) sufficient for NFS/network drives?
    - **Decision**: No. Increased default to 300s (5 minutes) with environment variable override (`DD_TOPT_MAX_WAIT_SEC`).
    - **Rationale**: Network filesystems may have significant latency; 5 minutes provides headroom while still failing fast for stuck uploads.

---

## 13. Design Note: Uploader as Normal Rule (Not Test Rule)

### Why Normal Rule with `bazel run`?

The uploader is implemented as a **normal executable rule** (not a test rule) and is invoked via `bazel run`, not `bazel test`. This design choice eliminates all sandbox-related complexity.

### Alternatives Considered

| Approach | Pros | Cons |
|----------|------|------|
| **Test rule + sandbox workarounds** | Fits `bazel test //...` workflow | Requires `local=True` + `tags=["no-sandbox"]`, complex documentation |
| **Test rule + CLI flags** | Explicit control | Defeats purpose of eliminating flags |
| **Normal rule + `bazel run`** (CHOSEN) | Simple, no workarounds needed | Separate command from test run |

### Why `bazel run` Works

When you run `bazel run //:target`:
1. **`BUILD_WORKSPACE_DIRECTORY`** is automatically set to the workspace root
2. **Network access** is available by default (no sandbox)
3. **Host filesystem access** is available (no sandbox)
4. **No special tags or attributes** are needed

This eliminates the need for `local=True`, `tags=["no-sandbox"]`, or any CLI flags.

### Critical Requirements for Uploader

| Requirement | Why | How Ensured |
|-------------|-----|-------------|
| **Network access** | Upload payloads to Datadog intake API | `bazel run` provides by default |
| **Host filesystem access** | Read `bazel-testlogs/` directory | `bazel run` provides by default |
| **Write access to testlogs** | Delete payloads after successful upload | `bazel run` provides by default |

**User-facing documentation must include:**

```markdown
## Uploader Requirements

The payload uploader requires:

1. **Single uploader per workspace** - Create ONE uploader target at workspace root.
   Do NOT run multiple uploaders concurrently; they will race and delete each other's payloads.

2. **Use `bazel run`** - The uploader is a normal rule (not a test), so use `bazel run //:dd_upload_payloads`.
   This automatically provides network and host filesystem access.

3. **Host filesystem access** - The uploader reads from and DELETES payloads in `bazel-testlogs/`.
   Note: Payloads are deleted after successful upload to prevent re-uploading.

4. **Remote Build Execution (RBE)** - If using RBE, you MUST use:
   `--remote_download_outputs=all` on the test run (not the uploader run).
   Without this flag, test outputs won't be downloaded and uploads will be empty.

5. **Environment variables** (for agentless mode):
   - `DD_API_KEY` - Your Datadog API key
   - `DD_SITE` - Your Datadog site (default: datadoghq.com)
```

### Data Flow

```
[go_test_1] ──▶ TEST_UNDECLARED_OUTPUTS_DIR ──▶ bazel-testlogs/pkg/test_1/test.outputs/
[go_test_2] ──▶ TEST_UNDECLARED_OUTPUTS_DIR ──▶ bazel-testlogs/pkg/test_2/test.outputs/
                     (sandboxed)                        │
                                                        ▼
                                          [uploader (bazel run)]
                                          - Runs outside sandbox
                                          - BUILD_WORKSPACE_DIRECTORY available
                                          - Can access bazel-testlogs/
                                          - Can access network for uploads
```

---

## 14. Path Discovery for Uploader

Since the uploader runs via `bazel run`, `BUILD_WORKSPACE_DIRECTORY` is **always available** and set to the workspace root.

### Discovery Strategies

The uploader tries these strategies in order:

1. **`TESTLOGS_DIR` env var** - Explicit override for non-standard setups
2. **`BUILD_WORKSPACE_DIRECTORY/bazel-testlogs`** - Default case (convenience symlink exists)
3. **`./bazel-testlogs`** - Current directory fallback

> **Important:** We intentionally do NOT call `bazel info` from within the uploader. Running `bazel info` inside `bazel run` can deadlock because the output base is locked by the active `bazel run` process.

### Non-Standard Symlink Setups

For workspaces using `--symlink_prefix` or disabled convenience symlinks, set `TESTLOGS_DIR` before running the uploader. **Use the same Bazel binary AND flags you used for `bazel test`** (replace `bazel` with your wrapper if needed, and include any flags that affect output base like `--output_base`, `--output_user_root`, or custom configs):

```bash
# Bash - use array for multiple flags or values with spaces
BAZEL_FLAGS=("--output_base=/custom/base")  # Add more flags to array as needed
export TESTLOGS_DIR=$(bazel "${BAZEL_FLAGS[@]}" info bazel-testlogs)
bazel "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads

# Or in a single command:
TESTLOGS_DIR=$(bazel "${BAZEL_FLAGS[@]}" info bazel-testlogs) bazel "${BAZEL_FLAGS[@]}" run //:dd_upload_payloads
```

```powershell
# PowerShell - use array splatting for multiple flags
$BazelFlags = @("--output_base=/custom/base")  # Add more flags to array as needed
$env:TESTLOGS_DIR = (bazel @BazelFlags info bazel-testlogs)
bazel @BazelFlags run //:dd_upload_payloads
```

**Behavior note:**
- If `TESTLOGS_DIR` is explicitly set but the path doesn't exist, the uploader **fails fast with an error** (likely a misconfiguration)
- If `TESTLOGS_DIR` is not set and auto-discovery finds nothing, the uploader **exits gracefully** with a hint (likely no tests were run)

### Why This Works

1. **`bazel run` always sets `BUILD_WORKSPACE_DIRECTORY`** to the workspace root
2. By default, the workspace root contains a `bazel-testlogs` symlink
3. If symlink doesn't exist, `TESTLOGS_DIR` provides an explicit override
4. No recursive `bazel` calls avoids deadlock and binary mismatch issues
5. All strategies check existence before returning

### Platform Notes

| Platform | Behavior |
|----------|----------|
| Linux | `bazel-testlogs` is typically a symlink; `-L` test handles symlinks correctly |
| macOS | Same as Linux |
| Windows | Uses PowerShell; `Test-Path` handles junctions and symlinks correctly |
