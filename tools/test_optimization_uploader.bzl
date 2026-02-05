# A Starlark rule that uploads CI Visibility test and coverage payloads
# after tests complete, by discovering all test.outputs directories in
# bazel-testlogs, waiting for filesystem quiescence, and uploading payloads.
#
# This is a normal rule (not a test rule) invoked via `bazel run` after
# `bazel test` completes. This simplifies sandbox/network access since
# `bazel run` runs locally with full host access.
#
# Usage pattern:
#   # Run tests first, then upload payloads
#   bazel test //... || test_status=$?; test_status=${test_status:-0}; bazel run //:dd_upload_payloads; exit $test_status
#
# Key features:
# - Discovers all test.outputs/ directories in bazel-testlogs automatically
# - Supports sharded tests (shard_N_of_M/) and retries (run_N_of_M/)
# - Uploads test payloads to CI Test Cycle intake
# - Uploads coverage payloads to Code Coverage intake
# - Deletes payloads after successful upload (unless DD_TOPT_KEEP_PAYLOADS=1)
# - Uses workspace-level lock to prevent concurrent uploaders
# - Enriches payloads with context.json metadata

# Version identifier sent in Datadog-Meta-Tracer-Version header
UPLOADER_VERSION = "2.0.0"

def log_info(message):
    print("dd_payload_uploader: %s" % message)

def log_debug(debug_enabled, message):
    if debug_enabled:
        print("dd_payload_uploader: %s" % message)

def _render_template(template, substitutions):
    # Simple template renderer compatible with the existing {key} placeholders.
    # It also converts doubled braces ({{, }}) into single braces after substitution,
    # which keeps literal braces used by shell/JSON/PowerShell intact.
    out = template
    for k, v in substitutions.items():
        out = out.replace("{" + k + "}", str(v))

    # Unescape '{{' and '}}' used to protect literal braces in the template
    out = out.replace("{{", "{").replace("}}", "}")
    return out

# Helper to keep template booleans consistent across bash/PowerShell.
def _bool_to_str(value):
    return "True" if value else "False"

# Public alias for tests (avoid importing private symbols)
render_template_for_tests = _render_template

def _uploader_impl(ctx):
    quiescent_sec = ctx.attr.quiescent_sec
    max_wait_sec = ctx.attr.max_wait_sec
    fail_on_error = ctx.attr.fail_on_error
    debug = ctx.attr.debug
    keep_payloads = ctx.attr.keep_payloads
    filter_prefix = ctx.attr.filter_prefix

    # Find context.json in data files (supports any repo alias)
    context_json_rloc = ""
    for f in ctx.files.data:
        if f.basename == "context.json":
            context_json_rloc = f.short_path
            break

    # High-level debug of rule inputs
    log_info("Generating uploader scripts (Option 2: TEST_UNDECLARED_OUTPUTS_DIR)")
    log_debug(
        debug,
        "Attributes → quiescent_sec=%s, max_wait_sec=%s, fail_on_error=%s, debug=%s, keep_payloads=%s, filter_prefix=%s" %
        (
            quiescent_sec,
            max_wait_sec,
            fail_on_error,
            debug,
            keep_payloads,
            filter_prefix,
        ),
    )
    if context_json_rloc:
        log_debug(debug, "context.json found at: %s" % context_json_rloc)
    else:
        log_debug(debug, "context.json not found in data files; enrichment disabled")
    if ctx.files.data:
        log_debug(debug, "Data files count: %d" % len(ctx.files.data))
        for f in ctx.files.data:
            log_debug(debug, "  data file: %s (%s)" % (f.basename, f.short_path))

    # Bash implementation (Unix)
    bash_template = """
#!/usr/bin/env bash
set -euo pipefail

# NOTE: This is a template file. Placeholders like {{quiescent_sec}} are replaced
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
    # Normalize relative prefixes that can appear in bzlmod runfile paths
    rloc="${rloc#./}"
    while [[ "$rloc" == ../* ]]; do
        rloc="${rloc#../}"
    done
    local candidates=("$rloc")
    if [[ "$rloc" == external/* ]]; then
        candidates+=("${rloc#external/}")
    else
        # Try the external/ prefix when short_path omits it under bzlmod.
        candidates+=("external/$rloc")
    fi
    for cand in "${{candidates[@]}}"; do
        # Try RUNFILES_DIR first (Unix default)
        if [[ -n "${{RUNFILES_DIR:-}}" && -f "$RUNFILES_DIR/$cand" ]]; then
            echo "$RUNFILES_DIR/$cand"
            return
        fi
        # Try $0.runfiles fallback
        if [[ -f "$0.runfiles/$cand" ]]; then
            echo "$0.runfiles/$cand"
            return
        fi
        # Try RUNFILES_MANIFEST_FILE (Windows/manifest-only)
        if [[ -n "${{RUNFILES_MANIFEST_FILE:-}}" && -f "$RUNFILES_MANIFEST_FILE" ]]; then
            local path
            # Use awk with substr() for regex-free extraction (handles metacharacters in paths)
            path=$(awk -v key="$cand" '$1 == key {{ print substr($0, length(key)+2); exit }}' "$RUNFILES_MANIFEST_FILE")
            if [[ -n "$path" && -f "$path" ]]; then
                echo "$path"
                return
            fi
        fi
    done
    echo ""  # Not found
}}

# Resolve context.json path (used by upload functions for payload enrichment)
# Path is determined at rule implementation time from data files
CONTEXT_JSON_RLOC="{context_json_rloc}"
if [[ -n "$CONTEXT_JSON_RLOC" ]]; then
    CONTEXT_JSON=$(resolve_runfile "$CONTEXT_JSON_RLOC")
    if [[ -z "$CONTEXT_JSON" ]]; then
        log "warning: context.json not found in runfiles; payloads will not be enriched"
    fi
else
    CONTEXT_JSON=""
    dbg "context.json not configured in data files; enrichment disabled"
fi

# Normalize boolean value (handles True/False from Starlark, 1/0, true/false)
# Uses tr for POSIX compatibility (macOS ships with Bash 3.2 which lacks ${{var,,}})
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

# Windows detection - delegate to PowerShell if needed
if [[ "$(uname -s | tr 'A-Z' 'a-z')" == *mingw* || "$(uname -s | tr 'A-Z' 'a-z')" == *msys* || "$(uname -s | tr 'A-Z' 'a-z')" == *cygwin* ]]; then
  ps_path="$(dirname "$0")/$(basename "$0" .sh).ps1"
  dbg "Windows-like environment detected; delegating to PowerShell: $ps_path"
  exec powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ps_path"
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

# Temporary working directory for enriched payloads / multipart event files
TMP_PAYLOAD_DIR="$(mktemp -d "${{TMPDIR:-/tmp}}/dd_topt_payloads.XXXXXX" 2>/dev/null || true)"
if [[ -z "$TMP_PAYLOAD_DIR" || ! -d "$TMP_PAYLOAD_DIR" ]]; then
    log "error: failed to create temp directory for payload uploads"
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    exit 2
fi

# Cleanup lock on exit
cleanup() {{
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    rm -rf "$TMP_PAYLOAD_DIR" 2>/dev/null || true
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
#   TESTLOGS_DIR=$(bazel "${{BAZEL_FLAGS[@]}}" info bazel-testlogs) bazel "${{BAZEL_FLAGS[@]}}" run ...

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
    find "$TESTLOGS_DIR" "${{depth_args[@]+"${{depth_args[@]}}"}}" -type d -name "test.outputs" 2>/dev/null || true
}}

# Warn if MAX_DEPTH is set and no test.outputs found (likely depth too shallow)
# Note: Must be called AFTER cache_test_outputs to use the cache
check_depth_warning() {{
    if [[ -z "$TEST_OUTPUTS_CACHE" ]] && (( MAX_DEPTH > 0 )); then
        log "warning: DD_TOPT_MAX_DEPTH=$MAX_DEPTH may be too shallow"
        log "hint: typical test.outputs paths require depth 3-5; try increasing or removing the limit"
    fi
}}

# Detect stat flavor (BSD vs GNU) to choose correct flags
# GNU stat supports: stat -c %Y / (returns numeric mtime)
# BSD stat supports: stat -f %m / (returns numeric mtime)
STAT_FLAVOR="bsd"
if stat -c %Y / >/dev/null 2>&1; then
    STAT_FLAVOR="gnu"
fi
dbg "stat detection: STAT_FLAVOR=$STAT_FLAVOR (uname=$(uname -s))"

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
            if [[ "$STAT_FLAVOR" == "bsd" ]]; then
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
    local found
    found=$(find "$TESTLOGS_DIR" \\( -name "test.log" -o -name "test.xml" \\) -type f -print -quit 2>/dev/null)
    [[ -n "$found" ]]
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

    # Refresh cache in case new test.outputs dirs appeared (e.g., remote downloads)
    cache_test_outputs
    total_files=$(count_payload_files)

    if (( total_files == 0 )); then
        if (( elapsed > MAX_WAIT_SEC )); then
            if tests_executed; then
                log "warning: tests ran but no payload files found"
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
        dbg "no payload files yet; waiting"
        sleep 2
        continue
    fi

    if (( elapsed > MAX_WAIT_SEC )); then
        log "max wait exceeded ($MAX_WAIT_SEC s); proceeding to upload"
        break
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

# Build endpoints
DD_SITE="${{DD_SITE:-datadoghq.com}}"
INTAKE_BASE="${{DD_TOPT_INTAKE_BASE:-}}"
if [[ -z "${{DD_TRACE_AGENT_URL:-}}" ]]; then
  AGENTLESS=1
  if [[ -n "$INTAKE_BASE" ]]; then
    # Allow tests/dev to override intake base without changing DD_SITE.
    BASE="${{INTAKE_BASE%/}}"
    TEST_URL="${{BASE}}/api/v2/citestcycle"
    COV_URL="${{BASE}}/api/v2/citestcov"
    dbg "DD_TOPT_INTAKE_BASE override active: $BASE"
  else
    TEST_URL="https://citestcycle-intake.${{DD_SITE}}/api/v2/citestcycle"
    COV_URL="https://citestcov-intake.${{DD_SITE}}/api/v2/citestcov"
  fi
else
  AGENTLESS=0
  TEST_URL="${{DD_TRACE_AGENT_URL}}/evp_proxy/v2/api/v2/citestcycle"
  COV_URL="${{DD_TRACE_AGENT_URL}}/evp_proxy/v2/api/v2/citestcov"
  if [[ -n "$INTAKE_BASE" ]]; then
    dbg "DD_TOPT_INTAKE_BASE ignored in EVP mode"
  fi
fi
dbg "mode: AGENTLESS=$AGENTLESS DD_SITE=$DD_SITE"
dbg "endpoints: TEST_URL=$TEST_URL COV_URL=$COV_URL"

hdrs=(
  -H "Datadog-Meta-Lang: bazel-starlark"
  -H "Datadog-Meta-Lang-Version: n/a"
  -H "Datadog-Meta-Lang-Interpreter: bazel-run"
  -H "Datadog-Meta-Tracer-Version: {uploader_version}"
  -H "Accept: application/json"
)
if (( AGENTLESS == 1 )); then
  if [[ -z "${{DD_API_KEY:-}}" ]]; then
    log "error: DD_API_KEY required for agentless uploads"
    log "hint: pass credentials via environment: DD_API_KEY=... DD_SITE=... bazel run //:dd_upload_payloads"
    exit 2  # Configuration error
  fi
  hdrs+=( -H "DD-API-KEY: $DD_API_KEY" )
else
  # EVP subdomain headers per endpoint
  TEST_EVP=( -H "X-Datadog-EVP-Subdomain: citestcycle-intake" )
  COV_EVP=( -H "X-Datadog-EVP-Subdomain: citestcov-intake" )
fi
dbg "headers prepared (agentless=$AGENTLESS)"

# Load context.json for enrichment
JQ_AVAILABLE=0
if command -v jq >/dev/null 2>&1; then JQ_AVAILABLE=1; fi
dbg "jq available: $JQ_AVAILABLE"
dbg "context.json: ${{CONTEXT_JSON:-<none>}}"

enrich_with_context() {{
  local infile="$1"; local tmpfile="$2"
  dbg "enrich_with_context: infile='$infile' outfile='$tmpfile' ctx='${{CONTEXT_JSON:-<none>}}' jq=$JQ_AVAILABLE"
  if (( JQ_AVAILABLE == 0 )) || [[ -z "$CONTEXT_JSON" ]] || [[ ! -f "$CONTEXT_JSON" ]]; then
    cp "$infile" "$tmpfile"
    return 0
  fi
  jq --slurpfile ctx "$CONTEXT_JSON" '
    (.metadata |= (. // {{}}))
    | (.metadata["*"] |= ((. // {{}}) + ($ctx[0] | with_entries(select(.value != null)))))
  ' "$infile" > "$tmpfile"
}}

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
        # Some runfiles can be read-only; best-effort cleanup keeps uploads resilient.
        if ! rm -f "$file" 2>/dev/null; then
            chmod u+w "$file" 2>/dev/null || true
            rm -f "$file" 2>/dev/null || true
        fi
    else
        dbg "keeping payload (KEEP_PAYLOADS=1): $file"
    fi
}}

# Track upload failures globally
UPLOAD_FAILURES=0

upload_single_test() {{
    local file="$1"
    local body
    # Use a temp file to avoid collisions when multiple uploads run in parallel.
    body="$(mktemp "$TMP_PAYLOAD_DIR/test_payload.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$body" ]]; then
        dbg "upload_single_test: failed to create temp file"
        return 1
    fi
    enrich_with_context "$file" "$body"
    dbg "upload_single_test: posting '$file' (body '$body')"
    if (( AGENTLESS == 1 )); then
      if curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \\
        -X POST "${{TEST_URL}}" "${{hdrs[@]}}" -H "Content-Type: application/json" --data-binary @"${{body}}" -o /dev/null -w "%{{http_code}}" >/dev/null; then
        rm -f "$body"
        return 0
      else
        rm -f "$body"
        return 1
      fi
    else
      if curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \\
        -X POST "${{TEST_URL}}" "${{hdrs[@]}}" "${{TEST_EVP[@]}}" -H "Content-Type: application/json" --data-binary @"${{body}}" -o /dev/null -w "%{{http_code}}" >/dev/null; then
        rm -f "$body"
        return 0
      else
        rm -f "$body"
        return 1
      fi
    fi
}}

upload_single_coverage() {{
    local file="$1"
    # Create event.json for multipart
    local eventjson
    # Use a temp file for multipart metadata to avoid leaking into runfiles.
    eventjson="$(mktemp "$TMP_PAYLOAD_DIR/coverage_event.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$eventjson" ]]; then
        dbg "upload_single_coverage: failed to create temp file"
        return 1
    fi
    echo '{{"dummy":true}}' > "$eventjson"
    dbg "upload_single_coverage: posting '$file'"
    if (( AGENTLESS == 1 )); then
      if curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \\
        -X POST "${{COV_URL}}" "${{hdrs[@]}}" \\
        -F "event=@${{eventjson}};type=application/json;filename=fileevent.json" \\
        -F "coveragex=@${{file}};type=application/json;filename=filecoveragex.json" -o /dev/null -w "%{{http_code}}" >/dev/null; then
        rm -f "$eventjson"
        return 0
      else
        rm -f "$eventjson"
        return 1
      fi
    else
      if curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \\
        -X POST "${{COV_URL}}" "${{hdrs[@]}}" "${{COV_EVP[@]}}" \\
        -F "event=@${{eventjson}};type=application/json;filename=fileevent.json" \\
        -F "coveragex=@${{file}};type=application/json;filename=filecoveragex.json" -o /dev/null -w "%{{http_code}}" >/dev/null; then
        rm -f "$eventjson"
        return 0
      else
        rm -f "$eventjson"
        return 1
      fi
    fi
}}

upload_all_tests() {{
    local total=0
    local failed=0
    local skipped=0
    # Iterate the cached test.outputs list to avoid rescanning the filesystem.
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
            if upload_single_test "$f"; then
                log "uploaded test payload: $f"
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
    # Iterate the cached test.outputs list to avoid rescanning the filesystem.
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
            if upload_single_coverage "$f"; then
                log "uploaded coverage payload: $f"
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
"""

    bash_script = _render_template(
        bash_template,
        {
            "quiescent_sec": quiescent_sec,
            "max_wait_sec": max_wait_sec,
            "fail_on_error": _bool_to_str(fail_on_error),
            "debug": _bool_to_str(debug),
            "keep_payloads": _bool_to_str(keep_payloads),
            "filter_prefix": _bool_to_str(filter_prefix),
            "uploader_version": UPLOADER_VERSION,
            "context_json_rloc": context_json_rloc,
        },
    )
    log_debug(debug, "Bash script rendered (bytes=%d)" % len(bash_script))

    # PowerShell implementation (Windows)
    ps_template = """
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Resolve runfile path for context.json lookup
# Since `bazel run` does NOT set TEST_SRCDIR, we use RUNFILES_DIR or RUNFILES_MANIFEST_FILE
function Resolve-Runfile {{
    param([string]$Rloc)

    # Normalize relative prefixes that can appear in bzlmod runfile paths
    if ($Rloc.StartsWith("./")) {{ $Rloc = $Rloc.Substring(2) }}
    while ($Rloc.StartsWith("../")) {{ $Rloc = $Rloc.Substring(3) }}

    $candidates = @($Rloc)
    if ($Rloc.StartsWith("external/")) {{
        $candidates += $Rloc.Substring(9)
    }} else {{
        # Try the external/ prefix when short_path omits it under bzlmod.
        $candidates += "external/$Rloc"
    }}

    foreach ($cand in $candidates) {{
        # Try RUNFILES_DIR first
        if ($env:RUNFILES_DIR) {{
            $candidate = Join-Path $env:RUNFILES_DIR $cand
            if (Test-Path $candidate) {{ return $candidate }}
        }}

        # Try $PSScriptRoot.runfiles fallback
        $candidate = Join-Path "$PSScriptRoot.runfiles" $cand
        if (Test-Path $candidate) {{ return $candidate }}

        # Try RUNFILES_MANIFEST_FILE (Windows default)
        if ($env:RUNFILES_MANIFEST_FILE -and (Test-Path $env:RUNFILES_MANIFEST_FILE)) {{
            $manifest = Get-Content $env:RUNFILES_MANIFEST_FILE
            foreach ($line in $manifest) {{
                if ($line.StartsWith("$cand ")) {{
                    $path = $line.Substring($cand.Length + 1)
                    if (Test-Path $path) {{ return $path }}
                }}
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
# Path is determined at rule implementation time from data files
$ContextJsonRloc = "{context_json_rloc}"
if ($ContextJsonRloc) {{
    $script:ContextJson = Resolve-Runfile $ContextJsonRloc
    if (-not $script:ContextJson) {{
        Log "warning: context.json not found in runfiles; payloads will not be enriched"
    }}
}} else {{
    $script:ContextJson = $null
    Dbg "context.json not configured in data files; enrichment disabled"
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
    if ($val -notmatch '^\\d+$') {{
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

# Temp directory for enriched payloads / event files
$script:TmpPayloadDir = Join-Path $env:TEMP ("dd_topt_payloads_" + [System.Guid]::NewGuid().ToString("N"))
try {{
    New-Item -ItemType Directory -Path $script:TmpPayloadDir -Force | Out-Null
}} catch {{
    Log "error: failed to create temp directory for payload uploads: $script:TmpPayloadDir"
    Release-Lock
    exit 2
}}

# Cleanup function for lock release
function Release-Lock {{
    if ($script:LockStream) {{
        $script:LockStream.Close()
        $script:LockStream = $null
        Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
    }}
    if ($script:TmpPayloadDir -and (Test-Path -LiteralPath $script:TmpPayloadDir)) {{
        Remove-Item -LiteralPath $script:TmpPayloadDir -Recurse -Force -ErrorAction SilentlyContinue
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

    # Refresh cache in case new test.outputs dirs appeared (e.g., remote downloads)
    Update-TestOutputsCache
    $totalFiles = Count-PayloadFiles

    if ($totalFiles -eq 0) {{
        if ($elapsed -gt $MaxWaitSec) {{
            if (Test-ExecutedTests) {{
                Log "warning: tests ran but no payload files found"
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
        Dbg "no payload files yet; waiting"
        Start-Sleep -Seconds 2
        continue
    }}

    if ($elapsed -gt $MaxWaitSec) {{
        Log "max wait exceeded ($MaxWaitSec s); proceeding to upload"
        break
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

# Build endpoints
$Agentless = [string]::IsNullOrEmpty($env:DD_TRACE_AGENT_URL)
$DD_Site = if ([string]::IsNullOrEmpty($env:DD_SITE)) {{ 'datadoghq.com' }} else {{ $env:DD_SITE }}
# Allow tests/dev to override intake base without changing DD_SITE.
$IntakeBase = $env:DD_TOPT_INTAKE_BASE
if ($Agentless) {{
  if (-not [string]::IsNullOrEmpty($IntakeBase)) {{
    $Base = $IntakeBase.TrimEnd('/')
    $TestUrl = "$Base/api/v2/citestcycle"
    $CovUrl = "$Base/api/v2/citestcov"
    Dbg "DD_TOPT_INTAKE_BASE override active: $Base"
  }} else {{
    $TestUrl = "https://citestcycle-intake.$DD_Site/api/v2/citestcycle"
    $CovUrl = "https://citestcov-intake.$DD_Site/api/v2/citestcov"
  }}
}} else {{
  $TestUrl = "$($env:DD_TRACE_AGENT_URL)/evp_proxy/v2/api/v2/citestcycle"
  $CovUrl = "$($env:DD_TRACE_AGENT_URL)/evp_proxy/v2/api/v2/citestcov"
  if (-not [string]::IsNullOrEmpty($IntakeBase)) {{ Dbg "DD_TOPT_INTAKE_BASE ignored in EVP mode" }}
}}
Dbg "mode: Agentless=$Agentless Site=$DD_Site"
Dbg "endpoints: TestUrl=$TestUrl CovUrl=$CovUrl"

$CommonHeaders = @{{
  'Datadog-Meta-Lang' = 'bazel-starlark'
  'Datadog-Meta-Lang-Version' = 'n/a'
  'Datadog-Meta-Lang-Interpreter' = 'bazel-run'
  'Datadog-Meta-Tracer-Version' = '{uploader_version}'
  'Accept' = 'application/json'
}}
if ($Agentless) {{
  if ([string]::IsNullOrEmpty($env:DD_API_KEY)) {{
    Log "error: DD_API_KEY required for agentless uploads"
    Log "hint: pass credentials via environment: `$env:DD_API_KEY=... `$env:DD_SITE=... bazel run //:dd_upload_payloads"
    Release-Lock
    exit 2  # Configuration error
  }}
  $CommonHeaders['DD-API-KEY'] = $env:DD_API_KEY
}} else {{
  $TestEvp = @{{ 'X-Datadog-EVP-Subdomain' = 'citestcycle-intake' }}
  $CovEvp  = @{{ 'X-Datadog-EVP-Subdomain' = 'citestcov-intake' }}
}}
Dbg "headers prepared (agentless=$Agentless)"

Dbg "context.json: $(if ([string]::IsNullOrEmpty($script:ContextJson)) {{ '<none>' }} else {{ $script:ContextJson }})"

function Merge-With-Context([string]$infile, [string]$outfile) {{
  if (-not $script:ContextJson -or -not (Test-Path -LiteralPath $script:ContextJson)) {{
    Dbg "Merge-With-Context: no context; copying '$infile' to '$outfile'"
    Copy-Item -LiteralPath $infile -Destination $outfile -Force; return
  }}
  try {{
    $payload = Get-Content -LiteralPath $infile -Raw | ConvertFrom-Json -ErrorAction Stop
  }} catch {{ Copy-Item -LiteralPath $infile -Destination $outfile -Force; return }}
  try {{
    $ctx = Get-Content -LiteralPath $script:ContextJson -Raw | ConvertFrom-Json -ErrorAction Stop
  }} catch {{ $ctx = $null }}
  if (-not $payload.metadata) {{ $payload | Add-Member -NotePropertyName metadata -NotePropertyValue @{{}} }}
  if (-not $payload.metadata.'*') {{ $payload.metadata.'*' = @{{}} }}
  if ($ctx) {{
    foreach ($prop in $ctx.PSObject.Properties) {{
      if ($prop.Value -ne $null) {{ $payload.metadata.'*'.($prop.Name) = $prop.Value }}
    }}
  }}
  Dbg "Merge-With-Context: wrote enriched '$outfile'"
  $payload | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $outfile -Encoding UTF8
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

function Send-PostJson([string]$url, [hashtable]$headers, [string]$file) {{
  $maxRetries = 3
  $retryDelay = 2
  for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {{
    $client = $null
    try {{
      $client = New-Object System.Net.Http.HttpClient
      $client.Timeout = [TimeSpan]::FromSeconds(60)
      foreach ($k in $headers.Keys) {{ $client.DefaultRequestHeaders.Add($k, [string]$headers[$k]) }}
      Dbg "Send-PostJson: POST $url (file '$file'; attempt $attempt/$maxRetries)"
      $content = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8))
      $content.Headers.ContentType = 'application/json'
      $resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
      if ($resp.IsSuccessStatusCode) {{
        return $true
      }} else {{
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        Dbg "Send-PostJson: HTTP $([int]$resp.StatusCode) on attempt $attempt"
        if ($attempt -eq $maxRetries) {{
          Log "upload failed: HTTP $([int]$resp.StatusCode) $body"
          return $false
        }}
      }}
    }} catch {{
      Dbg "Send-PostJson: Exception on attempt $attempt - $_"
      if ($attempt -eq $maxRetries) {{
        Log "upload failed: $_"
        return $false
      }}
    }} finally {{
      if ($client) {{ $client.Dispose() }}
    }}
    Start-Sleep -Seconds $retryDelay
  }}
  return $false
}}

function Upload-SingleTest([string]$FilePath) {{
    $body = Join-Path $script:TmpPayloadDir ("test_payload_" + [System.Guid]::NewGuid().ToString("N") + ".json")
    Merge-With-Context $FilePath $body
    $hdrs = $CommonHeaders.Clone()
    if (-not $Agentless) {{ $hdrs['X-Datadog-EVP-Subdomain'] = 'citestcycle-intake' }}
    Dbg "Upload-SingleTest: posting '$FilePath' (body '$body')"
    $result = Send-PostJson $TestUrl $hdrs $body
    Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue
    return $result
}}

function Upload-SingleCoverage([string]$FilePath) {{
    $eventFile = Join-Path $script:TmpPayloadDir ("coverage_event_" + [System.Guid]::NewGuid().ToString("N") + ".json")
    Set-Content -LiteralPath $eventFile -Value '{{"dummy":true}}' -Encoding UTF8

    $client = $null
    $fs = $null
    $maxRetries = 3
    $retryDelay = 2
    $uploaded = $false

    try {{
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        foreach ($k in $CommonHeaders.Keys) {{ $client.DefaultRequestHeaders.Add($k, [string]$CommonHeaders[$k]) }}
        if (-not $Agentless) {{ $client.DefaultRequestHeaders.Add('X-Datadog-EVP-Subdomain','citestcov-intake') }}

        for ($attempt = 1; $attempt -le $maxRetries -and -not $uploaded; $attempt++) {{
            try {{
                $content = New-Object System.Net.Http.MultipartFormDataContent
                $eventContent = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($eventFile, [System.Text.Encoding]::UTF8))
                $eventContent.Headers.ContentType = 'application/json'
                $content.Add($eventContent, 'event', 'fileevent.json')
                $fs = [System.IO.File]::OpenRead($FilePath)
                $covContent = New-Object System.Net.Http.StreamContent($fs)
                $covContent.Headers.ContentType = 'application/json'
                $content.Add($covContent, 'coveragex', 'filecoveragex.json')
                Dbg "Upload-SingleCoverage: posting '$FilePath' (attempt $attempt/$maxRetries)"
                $resp = $client.PostAsync($CovUrl, $content).GetAwaiter().GetResult()
                if ($resp.IsSuccessStatusCode) {{
                    $uploaded = $true
                }} else {{
                    $respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    Dbg "Upload-SingleCoverage: HTTP $([int]$resp.StatusCode) on attempt $attempt"
                    if ($attempt -eq $maxRetries) {{
                        Log "coverage upload failed: HTTP $([int]$resp.StatusCode) $respBody"
                    }}
                }}
            }} catch {{
                Dbg "Upload-SingleCoverage: Exception on attempt $attempt - $_"
                if ($attempt -eq $maxRetries) {{
                    Log "coverage upload failed: $_"
                }}
            }} finally {{
                if ($fs) {{ $fs.Dispose(); $fs = $null }}
            }}
            if (-not $uploaded -and $attempt -lt $maxRetries) {{ Start-Sleep -Seconds $retryDelay }}
        }}
    }} finally {{
        if ($client) {{ $client.Dispose() }}
        Remove-Item -LiteralPath $eventFile -Force -ErrorAction SilentlyContinue
    }}
    return $uploaded
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
                Log "uploaded test payload: $($f.FullName)"
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
                Log "uploaded coverage payload: $($f.FullName)"
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
"""

    ps_script = _render_template(
        ps_template,
        {
            "quiescent_sec": quiescent_sec,
            "max_wait_sec": max_wait_sec,
            "fail_on_error": _bool_to_str(fail_on_error),
            "debug": _bool_to_str(debug),
            "keep_payloads": _bool_to_str(keep_payloads),
            "filter_prefix": _bool_to_str(filter_prefix),
            "uploader_version": UPLOADER_VERSION,
            "context_json_rloc": context_json_rloc,
        },
    )
    log_debug(debug, "PowerShell script rendered (bytes=%d)" % len(ps_script))

    # Emit scripts
    bash_file = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(output = bash_file, content = bash_script, is_executable = True)
    ps_file = ctx.actions.declare_file(ctx.label.name + ".ps1")
    ctx.actions.write(output = ps_file, content = ps_script, is_executable = False)

    # Create a batch file wrapper for native Windows (calls PowerShell)
    bat_template = """@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT_DIR%{ps_name}"
exit /b %ERRORLEVEL%
"""
    bat_script = bat_template.replace("{ps_name}", ps_file.basename)
    bat_file = ctx.actions.declare_file(ctx.label.name + ".bat")
    ctx.actions.write(output = bat_file, content = bat_script, is_executable = True)
    log_debug(debug, "Declared outputs → bash='%s', ps='%s', bat='%s'" % (bash_file.basename, ps_file.basename, bat_file.basename))

    # Include optional data files (e.g., context.json) in runfiles so scripts can locate them
    # Include both the PowerShell and batch files in runfiles for cross-platform support
    runfiles = ctx.runfiles(files = [ps_file, bat_file] + ctx.files.data)
    log_debug(debug, "Runfiles include %d data file(s) plus PowerShell and batch scripts" % len(ctx.files.data))

    # Use platform detection to return .bat on Windows, .sh on Unix
    is_windows = ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])
    executable = bat_file if is_windows else bash_file
    return [DefaultInfo(executable = executable, runfiles = runfiles)]

dd_payload_uploader = rule(
    implementation = _uploader_impl,
    executable = True,  # Makes it runnable via `bazel run`
    attrs = {
        "quiescent_sec": attr.int(default = 10, doc = "Seconds to wait for filesystem to settle before uploading (env: DD_TOPT_QUIESCENT_SEC)"),
        "max_wait_sec": attr.int(default = 300, doc = "Maximum seconds to wait for payloads (env: DD_TOPT_MAX_WAIT_SEC). Default is sufficient since uploader runs after tests complete."),
        "fail_on_error": attr.bool(default = False, doc = "Exit with error if no payloads found when tests ran"),
        "debug": attr.bool(default = False, doc = "Enable debug logging"),
        "keep_payloads": attr.bool(default = False, doc = "Keep payload files after successful upload (env: DD_TOPT_KEEP_PAYLOADS)"),
        "filter_prefix": attr.bool(default = False, doc = "Only upload files matching span_events_*.json or coverage_*.json (env: DD_TOPT_FILTER_PREFIX)"),
        # Optional files to place in runfiles (e.g., a generated context.json)
        "data": attr.label_list(allow_files = True, doc = "Data files to include in runfiles (e.g., context.json for enrichment)"),
        # Private attribute to detect Windows platform
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    doc = """
Uploads CI Visibility test and coverage payloads to Datadog.

This rule discovers all test.outputs directories in bazel-testlogs (created by
TEST_UNDECLARED_OUTPUTS_DIR), waits for quiescence, and uploads payloads.

Usage:
    # In BUILD.bazel at workspace root
    load("@datadog-rules-test-optimization//tools:test_optimization_uploader.bzl", "dd_payload_uploader")

    dd_payload_uploader(
        name = "dd_upload_payloads",
        data = ["@test_optimization_data//:test_optimization_context"],
    )

    # After running tests:
    bazel test //... || test_status=$?; test_status=${test_status:-0}; bazel run //:dd_upload_payloads; exit $test_status

Exit codes:
    0 - All payloads uploaded successfully (or no payloads found)
    1 - One or more uploads failed
    2 - Configuration error (invalid TESTLOGS_DIR, missing credentials, etc.)

Required environment variables for upload:
    DD_API_KEY - Datadog API key (agentless mode)
    DD_SITE - Datadog site (agentless mode, default: datadoghq.com)
    OR
    DD_TRACE_AGENT_URL - Agent/EVP endpoint URL (agent mode)

Optional environment variables:
    TESTLOGS_DIR - Override testlogs directory (for non-standard setups)
    DD_TOPT_INTAKE_BASE - Override intake base URL (agentless only, test/dev)
    DD_TOPT_KEEP_PAYLOADS=1 - Retain payloads after upload
    DD_TOPT_FILTER_PREFIX=1 - Only upload span_events_*.json and coverage_*.json
    DD_TOPT_MAX_WAIT_SEC - Override max wait time
    DD_TOPT_QUIESCENT_SEC - Override quiescence wait time
    DD_TOPT_MAX_DEPTH - Limit find depth for large testlogs trees
""",
)
