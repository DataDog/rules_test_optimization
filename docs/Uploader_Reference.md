# Uploader Reference

This page is the full runtime/upload reference for `dd_payload_uploader`.
For a quick path, use the upload section in `README.md`.

## How it works

1. Tests write payloads to
   `$TEST_UNDECLARED_OUTPUTS_DIR/payloads/tests/*.json` and
   `$TEST_UNDECLARED_OUTPUTS_DIR/payloads/coverage/*.json`
2. Bazel automatically collects these to
   `bazel-testlogs/<package>/<target>/test.outputs/`
3. After tests complete, run the uploader via `bazel run`
4. The uploader discovers all `test.outputs/` directories, waits for
   quiescence, uploads, and deletes files

## Basic usage

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
# Assumes DD_API_KEY and DD_SITE are already set in environment
bazel run //:dd_upload_payloads
exit $testStatus

# REMOTE EXECUTION (RBE) - add flag to download outputs:
bazel test //... --remote_download_outputs=all
$testStatus = $LASTEXITCODE
if ($null -eq $testStatus) { $testStatus = 0 }
bazel run //:dd_upload_payloads
exit $testStatus
```

Always preserve the test exit code. Using plain `;` can make CI report success
when tests failed.

## Add the uploader target

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

## Upload modes

- **Agentless mode (default):** Requires `DD_API_KEY` and `DD_SITE`; uploads
  directly to Datadog intake
- **Agent/EVP mode:** Requires `DD_TRACE_AGENT_URL`; uploads via local agent or
  EVP proxy

## Passing credentials

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

```powershell
# Option 1: Agentless mode - environment already set (recommended for CI)
bazel run //:dd_upload_payloads

# Option 2: Agent/EVP mode
$env:DD_TRACE_AGENT_URL = "http://localhost:8126"
bazel run //:dd_upload_payloads

# Option 3: Set variables before run
$env:DD_API_KEY = "your-api-key"
$env:DD_SITE = "datadoghq.com"
bazel run //:dd_upload_payloads
```

## Exit codes

- `0` - All payloads uploaded successfully (or no payloads found)
- `1` - One or more uploads failed (partial success; successfully uploaded files
  are still deleted)
- `2` - Configuration error (invalid `TESTLOGS_DIR`, missing credentials, etc.)

## Optional environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `DD_TEST_OPTIMIZATION_KEEP_PAYLOADS` | `0` | Set to `1` to retain payloads after successful upload (for debugging/re-upload) |
| `DD_TEST_OPTIMIZATION_FILTER_PREFIX` | `0` | Set to `1` to only upload files matching `span_events_*.json` or `coverage_*.json` |
| `DD_TEST_OPTIMIZATION_DEBUG` | `0` | Set to `1` to enable verbose upload logging (HTTP codes, response bodies, startTime stats, and key runfile/CODEOWNERS resolution hits) |
| `DD_TEST_OPTIMIZATION_GZIP` | `0` | Set to `1` to gzip test payloads before upload (adds `Content-Encoding: gzip`) |
| `DD_TEST_OPTIMIZATION_MAX_WAIT_SEC` | `300` | Override max wait time for slow filesystems (NFS, network drives); set to `0` to skip waiting when no payloads are present |
| `DD_TEST_OPTIMIZATION_QUIESCENT_SEC` | `10` | Override quiescence wait time |
| `DD_TEST_OPTIMIZATION_MAX_DEPTH` | `0` (unlimited) | Limit `find` depth for large `bazel-testlogs` trees |
| `DD_TEST_OPTIMIZATION_CODEOWNERS_FILE` | auto | Explicit path to a CODEOWNERS file for enrichment fallback/discovery edge cases |
| `TESTLOGS_DIR` | auto | Explicit path to `bazel-testlogs` (for non-standard setups) |

## Endpoints and headers

- Agentless (when `DD_TRACE_AGENT_URL` unset):
  - Tests: `https://citestcycle-intake.<DD_SITE>/api/v2/citestcycle`
  - Coverage: `https://citestcov-intake.<DD_SITE>/api/v2/citestcov`
  - Requires `DD_API_KEY`
  - Test/dev override: set `DD_TEST_OPTIMIZATION_INTAKE_BASE` to use a custom
    base URL (agentless only)
- EVP proxy (when `DD_TRACE_AGENT_URL` set):
  - Base: `${DD_TRACE_AGENT_URL}/evp_proxy/v2/...`
  - Adds `X-Datadog-EVP-Subdomain` per endpoint
- Test payloads are JSON (msgpack is not available in Starlark). Coverage is
  multipart with `event` and `coveragex` parts.

## Reliability

- HTTP requests use a 60-second timeout
- Failed requests are retried up to 3 times with a 2-second delay between
  attempts
- Both transient errors (connection issues) and HTTP errors (4xx/5xx) trigger
  retries
- Behavior is consistent across Linux/macOS (bash/curl) and Windows
  (PowerShell)

## Metadata enrichment (`context.json`)

- When `context.json` is present in runfiles (provided via `data`), the uploader
  enriches each test payload by merging all non-null keys from `context.json`
  into `metadata.*`.
- If `context.json` is not present (or `jq` is unavailable on Unix), test
  payloads are uploaded as-is.
- `context.json` contains non-secret CI/Git/OS/runtime tags suitable for reuse
  at test time.
- Bazel rule identity is included as stable tags:
  `test.bazel.rule_name` and `test.bazel.rule_version`.
- `test`, `test_suite_end`, `test_module_end`, and `test_session_end` events
  may also be enriched with `test.codeowners` when source resolution and owner
  lookup succeed and the field is not already present.
- CODEOWNERS lookup order:
  - `<ci.workspace_path>/CODEOWNERS`
  - `<ci.workspace_path>/.github/CODEOWNERS`
  - `<ci.workspace_path>/.gitlab/CODEOWNERS`
  - `<ci.workspace_path>/docs/CODEOWNERS`
  - `<ci.workspace_path>/.docs/CODEOWNERS`
  - `<workspace>/...` equivalents
  - `./CODEOWNERS`
  - `<script_dir>/CODEOWNERS`
- Matching uses GitHub-style glob semantics with "last matching rule wins".
- CODEOWNERS enrichment is best-effort: parse/lookup failures and misses do not
  fail uploads; debug mode logs counters and skip reasons.

## Payload schema validation (best effort)

- Test payload schema validation runs only when all dependencies are available:
  bundled schema JSON, validator script, and `python3`.
- If validation dependencies are missing, validation is skipped and uploads
  continue.
- If validation runs and fails, the uploader logs a warning and continues.

## Test-time environment variables

`dd_topt_go_test` sets the following environment variables for instrumented
tests. Custom wrappers for other languages should set the same contract:

- `DD_TEST_OPTIMIZATION_MANIFEST_FILE`: runfile path to `manifest.txt` in the
  synced repo (`topt_data["manifest_path"]` aware of custom `out_dir`)
- `DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES`: always `"true"` so libraries write
  payloads to `TEST_UNDECLARED_OUTPUTS_DIR`

## Critical requirements

1. Use `bazel run` (not `bazel test`) for uploader execution
2. Use a single uploader target per workspace (no concurrent uploaders)
3. Tests must run locally, or use `--remote_download_outputs=all`
4. Run uploader on the same machine/workspace where tests executed
