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

Always preserve the test exit code. Using plain `;` can make CI report success
when tests failed.

Credential handling:

- Pass `DD_API_KEY`, `DD_SITE`, and `DD_TEST_OPTIMIZATION_AGENT_URL` at runtime via
  environment variables only.
- Do not hardcode secrets in `BUILD.bazel`, scripts committed to git, or CI
  logs.
- The generated uploader scripts read env vars directly (no shell `eval`
  expansion of credential values).

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

Multi-service aggregator variant (include each service context):

```bzl
dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data//:test_optimization_context_service_a",
        "@test_optimization_data//:test_optimization_context_service_b",
    ],
)
```

Mixed-runtime variant (include one context target per runtime or runtime/service repo):

```bzl
dd_payload_uploader(
    name = "dd_upload_payloads",
    data = [
        "@test_optimization_data_go//:test_optimization_context",
        "@test_optimization_data_python//:test_optimization_context",
        "@test_optimization_data_java//:test_optimization_context",
    ],
)
```

## Upload modes

- **Agentless mode (default):** Requires `DD_API_KEY` and `DD_SITE`; uploads
  directly to Datadog intake
- **EVP proxy mode:** Requires `DD_TEST_OPTIMIZATION_AGENT_URL`; uploads via local agent or
  EVP proxy

## Passing credentials

```bash
# Option 1: Agentless mode - Inline (recommended for CI)
DD_API_KEY="$DD_API_KEY" DD_SITE="$DD_SITE" bazel run //:dd_upload_payloads

# Option 2: EVP proxy mode
DD_TEST_OPTIMIZATION_AGENT_URL="http://localhost:8126" bazel run //:dd_upload_payloads

# Option 3: Export before run
export DD_API_KEY="your-api-key"
export DD_SITE="datadoghq.com"
bazel run //:dd_upload_payloads
```

```powershell
# Option 1: Agentless mode
$env:DD_API_KEY = "<your-api-key>"
$env:DD_SITE = "datadoghq.com"
bazel run //:dd_upload_payloads

# Option 2: EVP proxy mode
$env:DD_TEST_OPTIMIZATION_AGENT_URL = "http://localhost:8126"
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
| `DD_TEST_OPTIMIZATION_FILTER_PREFIX` | `0` | `0` uploads all payload files; set to `1` to only upload `span_events_*.json` or `coverage_*.json` |
| `DD_TEST_OPTIMIZATION_DEBUG` | `0` | Set to `1` to enable verbose upload logging (HTTP codes, response bodies, startTime stats, and key runfile/CODEOWNERS resolution hits) |
| `DD_TEST_OPTIMIZATION_GZIP` | `0` | Set to `1` to gzip test payloads before upload (adds `Content-Encoding: gzip`) |
| `DD_TEST_OPTIMIZATION_MAX_WAIT_SEC` | `300` | Override max wait time for slow filesystems (NFS, network drives); set to `0` to skip waiting when no payloads are present |
| `DD_TEST_OPTIMIZATION_QUIESCENT_SEC` | `10` | Override quiescence wait time |
| `DD_TEST_OPTIMIZATION_MAX_DEPTH` | `0` (unlimited) | Limit `find` depth for large `bazel-testlogs` trees |
| `DD_TEST_OPTIMIZATION_CODEOWNERS_FILE` | auto | Explicit path to a CODEOWNERS file for enrichment fallback/discovery edge cases |
| `DD_TEST_OPTIMIZATION_CONTEXT_JSON` | unset | Legacy explicit override for one readable `context.json` path. It still wins when set, but mixed-runtime workspaces should prefer bundling all context targets in uploader `data`. |
| `TESTLOGS_DIR` | auto | Explicit path to `bazel-testlogs` (for non-standard setups) |

### `DD_TEST_OPTIMIZATION_FILTER_PREFIX` behavior

`DD_TEST_OPTIMIZATION_FILTER_PREFIX=1` is mainly for mixed-output environments
where non-Test-Optimization payload JSON files can exist next to Datadog payloads
inside `test.outputs/`. Enabling it narrows uploads to canonical filename
prefixes:
- Test events: `span_events_*.json`
- Coverage: `coverage_*.json`

Leave it at `0` for normal repositories where uploader-managed payload
directories contain only Datadog files.

### `DD_TEST_OPTIMIZATION_MAX_WAIT_SEC` behavior (including `0`)

`DD_TEST_OPTIMIZATION_MAX_WAIT_SEC` controls how long the uploader waits for
payload discovery/quiescence before proceeding.
- `> 0`: wait up to the configured budget for payload files to appear and settle.
- `0`: skip waiting loops immediately. If no payloads are found, uploader exits
  cleanly with "nothing to upload" semantics.

## Endpoints and headers

- Agentless (when `DD_TEST_OPTIMIZATION_AGENT_URL` unset):
  - Tests: `https://citestcycle-intake.<DD_SITE>/api/v2/citestcycle`
  - Coverage: `https://citestcov-intake.<DD_SITE>/api/v2/citestcov`
  - Requires `DD_API_KEY`
  - `DD_SITE` is validated as a hostname (ASCII-whitespace is trimmed first),
    with compatibility normalization for `app.`/`api.` prefixes and URL-shaped
    inputs; credentials/ports are rejected
  - Test/dev override: set `DD_TEST_OPTIMIZATION_AGENTLESS_URL` to use a custom
    base URL (agentless only)
- EVP proxy (when `DD_TEST_OPTIMIZATION_AGENT_URL` set):
  - Base: `${DD_TEST_OPTIMIZATION_AGENT_URL}/evp_proxy/v2/...`
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
  (PowerShell-only runtime path; no Git Bash requirement)

## Metadata enrichment (`context.json`)

- The uploader resolves `context.json` in this order:
  1. `DD_TEST_OPTIMIZATION_CONTEXT_JSON` when it points to a readable file
  2. if exactly one bundled context exists, use that context for every payload
  3. if multiple bundled contexts exist, read sibling `bazel_target_metadata.json`, take `bazel.test_optimization.repo_name`, and use the matching bundled context for that payload
  4. if multiple bundled contexts exist and no match is found, skip only the `context.json` merge for that payload and continue uploading
  5. if no bundled context resolves, upload without context enrichment
- When a `context.json` file is available, the uploader enriches each test
  payload by merging all non-null keys from `context.json` into `metadata.*`.
- Bazel sidecar metadata from `bazel_target_metadata.json` is merged separately.
  If a multi-context payload has no repo match, those Bazel sidecar tags remain
  and only the `context.json` merge is skipped.
- If `context.json` is not present (or `jq` is unavailable on Unix), test
  payloads are uploaded as-is.
- `context.json` contains non-secret CI/Git/OS/runtime tags suitable for reuse
  at test time.
- `DD_TEST_OPTIMIZATION_CONTEXT_JSON` is a runtime uploader override only. Do
  not pass it via `--repo_env`, do not treat it as sync-time configuration, and
  do not use it as the normal mixed-runtime wiring path.
- Bazel metadata is included as stable tags:
  `bazel.rule_name`, `bazel.rule_version`, `bazel.os`, and `bazel.arch`.
- When enrichment is active, those Bazel keys are merged into test payload
  `metadata.*` alongside the existing CI, Git, OS, and runtime tags.
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

### Advanced: reuse an already-fetched context file

If your workflow already resolved Test Optimization data during the test
command, you can avoid re-resolving the uploader context through external repo
labels by passing the existing `context.json` path directly at uploader runtime:

```bash
DD_API_KEY="$DD_API_KEY" \
DD_SITE="$DD_SITE" \
DD_TEST_OPTIMIZATION_CONTEXT_JSON="/abs/path/to/context.json" \
bazel run //:dd_upload_payloads
```

This override is global for that uploader invocation. In mixed-runtime
workspaces, prefer bundling all relevant context targets and let the uploader
match them per payload instead of forcing one override path onto the entire run.

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
