#!/usr/bin/env bash
set -euo pipefail

# NOTE: This is a template file. Placeholders like __DDTPL_QUIESCENT_SEC__ are replaced
# by Starlark during rule execution. Double braces { and } are literal braces
# (escaped for Python .format() compatibility).

# Logging functions (defined first so other functions can use them)
# DEBUG is set later, so we use a function that checks the variable at runtime
log() { echo "[dd-uploader] $1"; }
DEBUG_BOOTSTRAP=$(echo "${DD_TEST_OPTIMIZATION_DEBUG:-0}" | tr '[:upper:]' '[:lower:]')
dbg() {
    local dbg_val="${DEBUG:-$DEBUG_BOOTSTRAP}"
    dbg_val=$(echo "$dbg_val" | tr '[:upper:]' '[:lower:]')
    if [[ "$dbg_val" == "1" || "$dbg_val" == "true" || "$dbg_val" == "yes" ]]; then
        echo "[dd-uploader][dbg] $1" >&2
    fi
}
dbg "startup runfiles env: RUNFILES_DIR='${RUNFILES_DIR:-<unset>}' RUNFILES_MANIFEST_FILE='${RUNFILES_MANIFEST_FILE:-<unset>}' script='$0'"

trim_ascii_whitespace() {
    local value="$1"
    value="${value#"${value%%[!$' 	
']*}"}"
    value="${value%"${value##*[!$' 	
']}"}"
    printf '%s
' "$value"
}

normalize_dd_site_or_fail() {
    local raw="$1"
    local site
    site=$(trim_ascii_whitespace "$raw")
    if [[ -z "$site" ]]; then
        echo "datadoghq.com"
        return 0
    fi

    # Keep compatibility with legacy DD_SITE input shapes.
    if [[ "$site" == *"://"* ]]; then
        site="${site#*://}"
    fi
    site="${site%%/*}"
    site="${site%%\?*}"
    site="${site%%#*}"
    if [[ "$site" == app.* ]]; then site="${site#app.}"; fi
    if [[ "$site" == api.* ]]; then site="${site#api.}"; fi
    site=$(echo "$site" | tr '[:upper:]' '[:lower:]')
    site=$(trim_ascii_whitespace "$site")

    if [[ -z "$site" ]]; then
        log "error: DD_SITE resolved to an empty hostname (input: '$raw')"
        return 1
    fi
    if [[ "$site" == *"@"* ]]; then
        log "error: DD_SITE must not include credentials/userinfo: '$raw'"
        return 1
    fi
    if [[ "$site" == *":"* ]]; then
        log "error: DD_SITE must be a hostname without an explicit port: '$raw'"
        return 1
    fi
    if [[ "$site" == .* || "$site" == *. || "$site" == *..* ]]; then
        log "error: DD_SITE must be a valid hostname: '$raw'"
        return 1
    fi
    if [[ ! "$site" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]; then
        log "error: DD_SITE contains unsupported hostname characters: '$raw'"
        return 1
    fi
    echo "$site"
}

# Resolve runfile path for context.json lookup
# Since `bazel run` does NOT set TEST_SRCDIR, we use RUNFILES_DIR or RUNFILES_MANIFEST_FILE
resolve_runfile() {
    local input_rloc="$1"
    local rloc="$input_rloc"
    # Normalize relative prefixes that can appear in bzlmod runfile paths
    rloc="${rloc#./}"
    while [[ "$rloc" == ../* ]]; do
        rloc="${rloc#../}"
    done
    # Defensive guard: runfile labels must remain repository-relative.
    # We intentionally reject absolute paths and parent traversal segments so
    # runfile resolution cannot escape the runfiles tree.
    if [[ -z "$rloc" || "$rloc" == /* || "$rloc" =~ ^[A-Za-z]:/ || "$rloc" == ".." || "$rloc" == */.. || "$rloc" == */../* ]]; then
        dbg "resolve_runfile: rejected suspicious runfile label '$input_rloc' (normalized='$rloc')"
        echo ""
        return
    fi
    local candidates=("$rloc")
    if [[ "$rloc" == external/* ]]; then
        candidates+=("${rloc#external/}")
    else
        # Try the external/ prefix when short_path omits it under bzlmod.
        candidates+=("external/$rloc")
    fi
    if [[ "$rloc" != _main/* ]]; then
        candidates+=("_main/$rloc")
    fi
    local manifest_file="${RUNFILES_MANIFEST_FILE:-}"
    dbg "resolve_runfile: input='$input_rloc' normalized='$rloc' candidates='${candidates[*]}'"
    if [[ -n "${RUNFILES_DIR:-}" ]]; then
        local rf_state="missing"
        if [[ -d "$RUNFILES_DIR" ]]; then
            rf_state="dir"
        elif [[ -e "$RUNFILES_DIR" ]]; then
            rf_state="exists_non_dir"
        fi
        dbg "resolve_runfile: RUNFILES_DIR='$RUNFILES_DIR' state=$rf_state"
    else
        dbg "resolve_runfile: RUNFILES_DIR=<unset>"
    fi
    if [[ -n "$manifest_file" ]]; then
        local mf_state="missing"
        if [[ -f "$manifest_file" ]]; then
            mf_state="file"
        elif [[ -e "$manifest_file" ]]; then
            mf_state="exists_non_file"
        fi
        dbg "resolve_runfile: RUNFILES_MANIFEST_FILE='$manifest_file' state=$mf_state"
    else
        dbg "resolve_runfile: RUNFILES_MANIFEST_FILE=<unset>"
    fi
    for cand in "${candidates[@]}"; do
        dbg "resolve_runfile: trying candidate '$cand'"
        # Try RUNFILES_DIR first (Unix default)
        if [[ -n "${RUNFILES_DIR:-}" && -f "$RUNFILES_DIR/$cand" ]]; then
            dbg "resolve_runfile: hit RUNFILES_DIR -> '$RUNFILES_DIR/$cand'"
            echo "$RUNFILES_DIR/$cand"
            return
        fi
        # Try $0.runfiles fallback
        if [[ -f "$0.runfiles/$cand" ]]; then
            dbg "resolve_runfile: hit script runfiles -> '$0.runfiles/$cand'"
            echo "$0.runfiles/$cand"
            return
        fi
        # Try RUNFILES_MANIFEST_FILE (Windows/manifest-only)
        if [[ -n "$manifest_file" && -f "$manifest_file" ]]; then
            local path
            # Pass 1: exact manifest key match (preferred).
            # Use awk + substr() for regex-free extraction, so candidate labels
            # containing regex metacharacters are treated as plain text.
            # We also strip a UTF-8 BOM from the first manifest key for parity
            # with PowerShell and editors/tools that emit BOM-prefixed files.
            path=$(awk -v key="$cand" '
                BEGIN { bom = sprintf("%c%c%c", 239, 187, 191) }
                {
                    k = $1
                    if (NR == 1 && index(k, bom) == 1) {
                        k = substr(k, 4)
                    }
                    if (k == key) {
                        print substr($0, length($1) + 2)
                        exit
                    }
                }
            ' "$manifest_file")
            path=$(trim_ascii_whitespace "$path")
            if [[ -n "$path" ]]; then
                if [[ -f "$path" ]]; then
                    dbg "resolve_runfile: hit manifest exact key '$cand' -> '$path'"
                    echo "$path"
                    return
                fi
                dbg "resolve_runfile: manifest exact key '$cand' -> '$path' (not a file)"
            fi
            # Fallback: some manifests prefix keys with repo names (for example "<repo>/path/to/file").
            # Match entries whose key ends with "/<candidate>" or "\<candidate>".
            # Pass 2: suffix match for repo-prefixed key variants.
            path=$(awk -v key="$cand" '
                BEGIN { bom = sprintf("%c%c%c", 239, 187, 191) }
                {
                    k = $1
                    if (NR == 1 && index(k, bom) == 1) {
                        k = substr(k, 4)
                    }
                    if (length(k) > length(key) && substr(k, length(k) - length(key) + 1) == key) {
                        sep = substr(k, length(k) - length(key), 1)
                        if (sep == "/" || sep == "\\") {
                            print substr($0, length($1) + 2)
                            exit
                        }
                    }
                }
            ' "$manifest_file")
            path=$(trim_ascii_whitespace "$path")
            if [[ -n "$path" ]]; then
                if [[ -f "$path" ]]; then
                    dbg "resolve_runfile: hit manifest suffix key '$cand' -> '$path'"
                    echo "$path"
                    return
                fi
                dbg "resolve_runfile: manifest suffix key '$cand' -> '$path' (not a file)"
            fi
        fi
    done
    dbg "resolve_runfile: miss for input '$input_rloc'"
    echo ""  # Not found
}

# Resolve execroot-relative artifact path (File.path).
# Bazel commonly provides paths like "external/<repo>/..." relative to execroot.
resolve_artifact_path() {
    local input_path="$1"
    if [[ -z "$input_path" ]]; then
        echo ""
        return
    fi
    dbg "resolve_artifact_path: input='$input_path'"
    if [[ -f "$input_path" ]]; then
        dbg "resolve_artifact_path: hit direct -> '$input_path'"
        echo "$input_path"
        return
    fi
    local script_dir execroot candidate
    script_dir=$(cd "$(dirname "$0")" && pwd -P)
    execroot=$(cd "$script_dir/../../.." 2>/dev/null && pwd -P || true)
    if [[ -n "$execroot" ]]; then
        candidate="$execroot/$input_path"
        if [[ -f "$candidate" ]]; then
            dbg "resolve_artifact_path: hit execroot-relative -> '$candidate'"
            echo "$candidate"
            return
        fi
    fi
    dbg "resolve_artifact_path: miss for input '$input_path'"
    echo ""
}

# Resolve context.json path (used by upload functions for payload enrichment)
# Path is determined at rule implementation time from data files
CONTEXT_JSON_RLOC="__DDTPL_CONTEXT_JSON_RLOC__"
CONTEXT_JSON_PATH="__DDTPL_CONTEXT_JSON_PATH__"
dbg "context.json resolution inputs: path='$CONTEXT_JSON_PATH' rloc='$CONTEXT_JSON_RLOC'"
CONTEXT_JSON=$(resolve_artifact_path "$CONTEXT_JSON_PATH")
if [[ -n "$CONTEXT_JSON" ]]; then
    # Direct artifact path is fastest and most deterministic when available.
    dbg "context.json resolved via direct path: '$CONTEXT_JSON'"
elif [[ -n "$CONTEXT_JSON_RLOC" ]]; then
    # Runfiles lookup supports launcher/platform variants and bzlmod naming.
    CONTEXT_JSON=$(resolve_runfile "$CONTEXT_JSON_RLOC")
    if [[ -z "$CONTEXT_JSON" ]]; then
        log "warning: context.json not found in runfiles; payloads will not be enriched"
    else
        dbg "context.json resolved via runfiles: '$CONTEXT_JSON'"
    fi
else
    CONTEXT_JSON=""
    dbg "context.json not configured in data files; enrichment disabled"
fi

# Resolve schema and validator paths (used for payload validation)
SCHEMA_JSON_RLOC="__DDTPL_SCHEMA_JSON_RLOC__"
SCHEMA_JSON_PATH="__DDTPL_SCHEMA_JSON_PATH__"
SCHEMA_VALIDATOR_RLOC="__DDTPL_SCHEMA_VALIDATOR_RLOC__"
SCHEMA_VALIDATOR_PATH="__DDTPL_SCHEMA_VALIDATOR_PATH__"
dbg "schema resolution inputs: schema_path='$SCHEMA_JSON_PATH' schema_rloc='$SCHEMA_JSON_RLOC' validator_path='$SCHEMA_VALIDATOR_PATH' validator_rloc='$SCHEMA_VALIDATOR_RLOC'"
SCHEMA_JSON=$(resolve_artifact_path "$SCHEMA_JSON_PATH")
if [[ -n "$SCHEMA_JSON" ]]; then
    dbg "schema resolved via direct path: '$SCHEMA_JSON'"
elif [[ -n "$SCHEMA_JSON_RLOC" ]]; then
    # Fallback to runfiles so validation still works under manifest-only setups.
    SCHEMA_JSON=$(resolve_runfile "$SCHEMA_JSON_RLOC")
    if [[ -z "$SCHEMA_JSON" ]]; then
        log "warning: schema not found in runfiles; validation disabled"
    else
        dbg "schema resolved via runfiles: '$SCHEMA_JSON'"
    fi
else
    SCHEMA_JSON=""
    dbg "schema not configured in data files; validation disabled"
fi
SCHEMA_VALIDATOR=$(resolve_artifact_path "$SCHEMA_VALIDATOR_PATH")
if [[ -n "$SCHEMA_VALIDATOR" ]]; then
    dbg "schema validator resolved via direct path: '$SCHEMA_VALIDATOR'"
elif [[ -n "$SCHEMA_VALIDATOR_RLOC" ]]; then
    # Keep parity with schema resolution order (direct path first, runfile second).
    SCHEMA_VALIDATOR=$(resolve_runfile "$SCHEMA_VALIDATOR_RLOC")
    if [[ -z "$SCHEMA_VALIDATOR" ]]; then
        log "warning: schema validator not found in runfiles; validation disabled"
    else
        dbg "schema validator resolved via runfiles: '$SCHEMA_VALIDATOR'"
    fi
else
    SCHEMA_VALIDATOR=""
    dbg "schema validator not configured in data files; validation disabled"
fi

# Normalize boolean value (handles True/False from Starlark, 1/0, true/false)
# Uses tr for POSIX compatibility (macOS ships with Bash 3.2 which lacks ${var,,})
normalize_bool() {
    local val
    val=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$val" in
        1|true|yes) echo "1" ;;
        *) echo "0" ;;
    esac
}

# Validate numeric value; exit 2 if invalid
validate_numeric() {
    local name="$1"
    local val="$2"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        log "error: $name must be a non-negative integer, got: '$val'"
        exit 2  # Configuration error
    fi
}

# Generate UUID (best effort). Uses uuidgen, python3, or /dev/urandom.
generate_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
        return
    fi
    if [[ -r /dev/urandom ]]; then
        local hex
        hex=$(od -An -N16 -tx1 /dev/urandom | tr -d ' 
')
        echo "${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}"
        return
    fi
    echo "00000000-0000-0000-0000-000000000000"
}

# Compute FNV-1a 32-bit hex fingerprint (non-cryptographic, for parity checks only)
fnv1a_32() {
    local input="$1"
    if [[ -z "$input" ]]; then
        echo ""
        return
    fi
    local alphabet=$'0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_:/.+@=#%~!$^*()[]{}<>?,;|\\\"\'` '
    local hash=2166136261
    local input_len="${#input}"
    local alpha_len="${#alphabet}"
    local i j idx found ch ach
    for ((i = 0; i < input_len; i++)); do
        ch="${input:i:1}"
        idx=0
        found=0
        for ((j = 0; j < alpha_len; j++)); do
            ach="${alphabet:j:1}"
            if [[ "$ach" == "$ch" ]]; then
                idx=$j
                found=1
                break
            fi
        done
        if (( found == 0 )); then
            # Keep unknown-character bucketing aligned with sync-side Starlark logic.
            idx=$((alpha_len + (i % 7)))
        fi
        hash=$((hash ^ idx))
        hash=$(( (hash * 16777619) & 0xffffffff ))
    done
    printf '%08x' "$hash"
}

# Rule attributes (can be overridden via environment variables)
QUIESCENT_SEC=${DD_TEST_OPTIMIZATION_QUIESCENT_SEC:-__DDTPL_QUIESCENT_SEC__}
MAX_WAIT_SEC=${DD_TEST_OPTIMIZATION_MAX_WAIT_SEC:-__DDTPL_MAX_WAIT_SEC__}
FAIL_ON_ERROR=$(normalize_bool "__DDTPL_FAIL_ON_ERROR__")
KEEP_PAYLOADS=$(normalize_bool "${DD_TEST_OPTIMIZATION_KEEP_PAYLOADS:-__DDTPL_KEEP_PAYLOADS__}")
FILTER_PREFIX=$(normalize_bool "${DD_TEST_OPTIMIZATION_FILTER_PREFIX:-__DDTPL_FILTER_PREFIX__}")
DEBUG=$(normalize_bool "${DD_TEST_OPTIMIZATION_DEBUG:-__DDTPL_DEBUG__}")
GZIP_PAYLOADS=$(normalize_bool "${DD_TEST_OPTIMIZATION_GZIP:-__DDTPL_GZIP_PAYLOADS__}")
RULES_VERSION="__DDTPL_RULES_VERSION__"
RUNTIME_ID=$(generate_uuid)

# Validate numeric environment variables
validate_numeric "QUIESCENT_SEC" "$QUIESCENT_SEC"
validate_numeric "MAX_WAIT_SEC" "$MAX_WAIT_SEC"
if [[ -n "${DD_TEST_OPTIMIZATION_MAX_DEPTH:-}" ]]; then
    validate_numeric "DD_TEST_OPTIMIZATION_MAX_DEPTH" "$DD_TEST_OPTIMIZATION_MAX_DEPTH"
fi
if [[ "$GZIP_PAYLOADS" == "1" ]]; then
    if ! command -v gzip >/dev/null 2>&1; then
        log "warning: DD_TEST_OPTIMIZATION_GZIP=1 but gzip not found; disabling gzip"
        GZIP_PAYLOADS=0
    fi
fi
dbg "gzip enabled: $GZIP_PAYLOADS"

# Baseline curl retry flags. We append --retry-all-errors only when supported
# by the installed curl binary (introduced in curl 7.85.0).
CURL_RETRY_FLAGS=(__DDTPL_CURL_RETRY_FLAGS__)
if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
    CURL_RETRY_FLAGS+=(--retry-all-errors)
fi
dbg "curl retry flags: ${CURL_RETRY_FLAGS[*]}"

# Acquire exclusive lock to prevent concurrent uploaders
# Uses mkdir for portability (works on macOS which lacks flock)
# Lock is scoped to workspace to allow parallel uploads in different workspaces
# Hash generation handles both Linux (md5sum) and macOS (md5 -q) formats
compute_workspace_hash() {
    local workspace="${BUILD_WORKSPACE_DIRECTORY:-$(pwd)}"
    # Try md5sum (Linux), then md5 -q (macOS), then shasum, then fallback
    if command -v md5sum >/dev/null 2>&1; then
        printf "%s" "$workspace" | md5sum | cut -c1-8
    elif command -v md5 >/dev/null 2>&1; then
        printf "%s" "$workspace" | md5 -q | cut -c1-8
    elif command -v shasum >/dev/null 2>&1; then
        printf "%s" "$workspace" | shasum -a 256 | cut -c1-8
    else
        echo "default"
    fi
}
WORKSPACE_HASH=$(compute_workspace_hash)
LOCK_DIR="${TMPDIR:-/tmp}/dd_upload_payloads_$WORKSPACE_HASH.lock"
LOCK_ACQUIRED=0

lock_dir_age_seconds() {
    local dir="$1"
    local now mtime
    # Cross-platform stat:
    # - BSD/macOS: stat -f %m
    # - GNU/Linux: stat -c %Y
    now=$(date +%s)
    if mtime=$(stat -f %m "$dir" 2>/dev/null); then
        :
    elif mtime=$(stat -c %Y "$dir" 2>/dev/null); then
        :
    else
        echo 0
        return
    fi
    if [[ "$mtime" =~ ^[0-9]+$ ]]; then
        echo $(( now - mtime ))
    else
        echo 0
    fi
}

acquire_lock() {
    local max_attempts=3
    local attempt=0
    while (( attempt < max_attempts )); do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            # Persist PID metadata right after lock creation. If this write fails
            # we treat the lock as unusable and immediately remove it.
            if ! echo $$ > "$LOCK_DIR/pid" 2>/dev/null; then
                rm -rf "$LOCK_DIR" 2>/dev/null || true
                log "error: failed to initialize lock metadata at $LOCK_DIR/pid"
                return 1
            fi
            LOCK_ACQUIRED=1
            dbg "acquired lock: $LOCK_DIR (workspace hash: $WORKSPACE_HASH)"
            return 0
        fi
        # Check if lock is stale:
        # 1) lock dir exists but pid file is empty/malformed
        # 2) lock dir exists but pid file is missing
        # 3) pid exists but process is no longer alive
        if [[ -f "$LOCK_DIR/pid" ]]; then
            local owner_pid
            owner_pid=$(tr -d '[:space:]' < "$LOCK_DIR/pid" 2>/dev/null || echo "")
            if [[ -z "$owner_pid" ]]; then
                local lock_age
                lock_age=$(lock_dir_age_seconds "$LOCK_DIR")
                if [[ "$lock_age" =~ ^[0-9]+$ ]] && (( lock_age > 30 )); then
                    dbg "removing stale lock (empty pid file, age ${lock_age}s)"
                    rm -rf "$LOCK_DIR" 2>/dev/null || true
                    ((++attempt))
                    continue
                fi
                ((++attempt))
                sleep 1
                continue
            fi
            if ! kill -0 "$owner_pid" 2>/dev/null; then
                dbg "removing stale lock (pid $owner_pid is dead)"
                rm -rf "$LOCK_DIR" 2>/dev/null || true
                ((++attempt))
                continue
            fi
        else
            local lock_age
            lock_age=$(lock_dir_age_seconds "$LOCK_DIR")
            if [[ "$lock_age" =~ ^[0-9]+$ ]] && (( lock_age > 30 )); then
                dbg "removing stale lock (missing pid file, age ${lock_age}s)"
                rm -rf "$LOCK_DIR" 2>/dev/null || true
                ((++attempt))
                continue
            fi
            # Fresh lock without pid metadata might be in the middle of setup by
            # another uploader; back off briefly before retrying.
            ((++attempt))
            sleep 1
            continue
        fi
        log "error: another uploader is already running (lock: $LOCK_DIR)"
        log "hint: wait for the other uploader to finish, or remove the lock directory if stale"
        return 1
    done
    return 1
}

if ! acquire_lock; then
    exit 2
fi

# Temporary working directory for enriched payloads / multipart event files
TMP_PAYLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dd_topt_payloads.XXXXXX" 2>/dev/null || true)"
if [[ -z "$TMP_PAYLOAD_DIR" || ! -d "$TMP_PAYLOAD_DIR" ]]; then
    log "error: failed to create temp directory for payload uploads"
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    exit 2
fi

# Cleanup lock on exit
cleanup() {
    # Only the lock owner may remove LOCK_DIR. This avoids deleting an active
    # uploader's lock when the current process failed to acquire it.
    if [[ "$LOCK_ACQUIRED" == "1" ]]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
    rm -rf "$TMP_PAYLOAD_DIR" 2>/dev/null || true
}
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
if [[ -n "${TESTLOGS_DIR:-}" ]]; then
    if [[ -d "$TESTLOGS_DIR" ]]; then
        # Explicit override wins over all discovery heuristics.
        dbg "using explicit TESTLOGS_DIR=$TESTLOGS_DIR"
    else
        log "error: TESTLOGS_DIR is set but path does not exist: $TESTLOGS_DIR"
        log "hint: ensure you used the same Bazel wrapper for 'bazel info' as for 'bazel test'"
        exit 2  # Configuration error (see exit codes in docs)
    fi
else
    # Auto-discover testlogs directory
    # Discovery order intentionally mirrors common Bazel invocation contexts:
    # 1) BUILD_WORKSPACE_DIRECTORY (when provided by launcher)
    # 2) local bazel-testlogs symlink in current directory
    if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
        candidate="$BUILD_WORKSPACE_DIRECTORY/bazel-testlogs"
        if [[ -d "$candidate" ]] || [[ -L "$candidate" ]]; then
            TESTLOGS_DIR="$candidate"
        fi
    fi

    if [[ -z "${TESTLOGS_DIR:-}" ]] && { [[ -d "bazel-testlogs" ]] || [[ -L "bazel-testlogs" ]]; }; then
        TESTLOGS_DIR="$(pwd)/bazel-testlogs"
    fi

    if [[ -z "${TESTLOGS_DIR:-}" ]]; then
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
# Supports DD_TEST_OPTIMIZATION_MAX_DEPTH to limit search depth for large testlogs trees
MAX_DEPTH=${DD_TEST_OPTIMIZATION_MAX_DEPTH:-0}
find_test_outputs() {
    local depth_args=()
    if (( MAX_DEPTH > 0 )); then
        depth_args=(-maxdepth "$MAX_DEPTH")
        dbg "limiting find depth to $MAX_DEPTH"
    fi
    find "$TESTLOGS_DIR" "${depth_args[@]+"${depth_args[@]}"}" -type d -name "test.outputs" 2>/dev/null || true
}

# Warn if MAX_DEPTH is set and no test.outputs found (likely depth too shallow)
# Note: Must be called AFTER cache_test_outputs to use the cache
check_depth_warning() {
    if [[ -z "$TEST_OUTPUTS_CACHE" ]] && (( MAX_DEPTH > 0 )); then
        log "warning: DD_TEST_OPTIMIZATION_MAX_DEPTH=$MAX_DEPTH may be too shallow"
        log "hint: typical test.outputs paths require depth 3-5; try increasing or removing the limit"
    fi
}

# Detect stat flavor (BSD vs GNU) to choose correct flags
# GNU stat supports: stat -c %Y / (returns numeric mtime)
# BSD stat supports: stat -f %m / (returns numeric mtime)
STAT_FLAVOR="bsd"
if stat -c %Y / >/dev/null 2>&1; then
    STAT_FLAVOR="gnu"
fi
dbg "stat detection: STAT_FLAVOR=$STAT_FLAVOR (uname=$(uname -s))"

# Get latest mtime across payloads/tests and payloads/coverage in test.outputs.
# Note: Only scans payload directories, not all files under test.outputs
latest_mtime_all() {
    local max_mtime=0
    while IFS= read -r outputs_dir; do
        [[ -z "$outputs_dir" ]] && continue
        for subdir in "payloads/tests" "payloads/coverage"; do
            local dir="$outputs_dir/$subdir"
            [[ -d "$dir" ]] || continue
            local mt
            if [[ "$STAT_FLAVOR" == "bsd" ]]; then
                mt=$(find "$dir" -type f -name "*.json" -exec stat -f '%m' {} + 2>/dev/null | sort -nr | head -1 || echo 0)
            else
                mt=$(find "$dir" -type f -name "*.json" -exec stat -c '%Y' {} + 2>/dev/null | sort -nr | head -1 || echo 0)
            fi
            mt=${mt:-0}
            if (( mt > max_mtime )); then
                max_mtime=$mt
            fi
        done
    done < <(echo "$TEST_OUTPUTS_CACHE")
    echo "$max_mtime"
}

# Count total payload files across all test.outputs payload directories.
count_payload_files() {
    local count=0
    while IFS= read -r outputs_dir; do
        [[ -z "$outputs_dir" ]] && continue
        local tests_dir="$outputs_dir/payloads/tests"
        local cov_dir="$outputs_dir/payloads/coverage"
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
}

start_ts=$(date +%s)
dbg "Uploader start time: $start_ts"

# Detect if tests actually ran by looking for test.log or test.xml files
# This helps distinguish "no payloads because tests didn't run" from "tests ran but dd-trace-go is misconfigured"
tests_executed() {
    local found
    found=$(find "$TESTLOGS_DIR" \( -name "test.log" -o -name "test.xml" \) -type f -print -quit 2>/dev/null)
    [[ -n "$found" ]]
}

# Wait for quiescence (filesystem to settle)
# Since the uploader runs AFTER tests complete (via `bazel run` after `bazel test`),
# we just need a short quiescence period to ensure all files are written.
dbg "Waiting for test outputs to quiesce..."

# Cache the list of test.outputs directories for efficiency (avoid rescanning on each loop iteration)
TEST_OUTPUTS_CACHE=""
cache_test_outputs() {
    TEST_OUTPUTS_CACHE=$(find_test_outputs)
}
cache_test_outputs
check_depth_warning  # Warn if MAX_DEPTH may be too shallow

while true; do
    now=$(date +%s)
    elapsed=$((now - start_ts))

    # Refresh cache in case new test.outputs dirs appeared (e.g., remote downloads)
    cache_test_outputs
    total_files=$(count_payload_files)

    if (( total_files == 0 )); then
        # No payloads yet. Branch behavior depends on max-wait policy:
        # - MAX_WAIT_SEC=0: immediate decision (upload no-op or fail-on-error)
        # - MAX_WAIT_SEC>0: keep polling until timeout
        if (( MAX_WAIT_SEC == 0 )); then
            if tests_executed; then
                log "warning: tests ran but no payload files found"
                log "hint: check that DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true is set"
                if [[ "$FAIL_ON_ERROR" == "1" ]]; then
                    log "error: FAIL_ON_ERROR is set; failing due to missing payloads"
                    exit 1
                fi
            else
                log "no payload files found and no test execution detected; nothing to upload"
            fi
            exit 0
        fi
        if (( elapsed > MAX_WAIT_SEC )); then
            if tests_executed; then
                log "warning: tests ran but no payload files found"
                log "hint: check that DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES=true is set"
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
        # Payloads exist but waiting budget is exhausted; proceed anyway.
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
if ! DD_SITE="$(normalize_dd_site_or_fail "${DD_SITE:-datadoghq.com}")"; then
  exit 2
fi
INTAKE_BASE="${DD_TEST_OPTIMIZATION_INTAKE_BASE:-}"
if [[ -z "${DD_TRACE_AGENT_URL:-}" ]]; then
  # Agentless mode: direct public intake URLs (or explicit override base).
  AGENTLESS=1
  if [[ -n "$INTAKE_BASE" ]]; then
    # Allow tests/dev to override intake base without changing DD_SITE.
    BASE="${INTAKE_BASE%/}"
    TEST_URL="${BASE}/api/v2/citestcycle"
    COV_URL="${BASE}/api/v2/citestcov"
    dbg "DD_TEST_OPTIMIZATION_INTAKE_BASE override active: $BASE"
  else
    TEST_URL="https://citestcycle-intake.${DD_SITE}/api/v2/citestcycle"
    COV_URL="https://citestcov-intake.${DD_SITE}/api/v2/citestcov"
  fi
else
  # EVP mode: route through agent endpoint with required subdomain headers.
  AGENTLESS=0
  TEST_URL="${DD_TRACE_AGENT_URL}/evp_proxy/v2/api/v2/citestcycle"
  COV_URL="${DD_TRACE_AGENT_URL}/evp_proxy/v2/api/v2/citestcov"
  if [[ -n "$INTAKE_BASE" ]]; then
    dbg "DD_TEST_OPTIMIZATION_INTAKE_BASE ignored in EVP mode"
  fi
fi
dbg "mode: AGENTLESS=$AGENTLESS DD_SITE=$DD_SITE"
dbg "endpoints: TEST_URL=$TEST_URL COV_URL=$COV_URL"

HEADER_LANG_DEFAULT="bazel-starlark"
HEADER_LANG_VERSION_DEFAULT="n/a"
HEADER_LANG_INTERPRETER_DEFAULT="bazel-run"
HEADER_TRACER_VERSION_DEFAULT="__DDTPL_UPLOADER_VERSION__"
if (( AGENTLESS == 1 )); then
  if [[ -z "${DD_API_KEY:-}" ]]; then
    log "error: DD_API_KEY required for agentless uploads"
    log "hint: pass credentials via environment: DD_API_KEY=... DD_SITE=... bazel run //:dd_upload_payloads"
    exit 2  # Configuration error
  fi
else
  # EVP subdomain headers per endpoint
  TEST_EVP=( -H "X-Datadog-EVP-Subdomain: citestcycle-intake" )
  COV_EVP=( -H "X-Datadog-EVP-Subdomain: citestcov-intake" )
fi
dbg "headers prepared (agentless=$AGENTLESS; test headers can be derived from metadata)"

# Redact sensitive header values (keep last 4 chars for DD-API-KEY)
redact_header() {
  local h="$1"
  local name="${h%%:*}"
  if [[ "$name" == "DD-API-KEY" ]]; then
    local val="${h#*:}"
    val="${val# }"; val="${val% }"; val="${val%%$'\r'}"
    if (( ${#val} > 4 )); then
      echo "DD-API-KEY: ****${val: -4}"
    else
      echo "DD-API-KEY: $val"
    fi
  else
    echo "$h"
  fi
}

dbg_headers() {
  local label="$1"; shift
  local arr=("$@")
  local i=0
  while (( i < ${#arr[@]} )); do
    if [[ "${arr[$i]}" == "-H" && $((i+1)) -lt ${#arr[@]} ]]; then
      dbg "header[$label]: $(redact_header "${arr[$((i+1))]}")"
      i=$((i+2))
      continue
    fi
    dbg "header[$label]: ${arr[$i]}"
    i=$((i+1))
  done
}

# Load context.json for enrichment
JQ_AVAILABLE=0
if command -v jq >/dev/null 2>&1; then JQ_AVAILABLE=1; fi
dbg "jq available: $JQ_AVAILABLE"
dbg "context.json: ${CONTEXT_JSON:-<none>}"

# CODEOWNERS state (initialized lazily on first enrichment attempt).
CODEOWNERS_INITIALIZED=0
CODEOWNERS_ENABLED=0
CODEOWNERS_FILE=""
CODEOWNERS_WORKSPACE_ROOT=""
CODEOWNERS_CONTEXT_WORKSPACE=""
CODEOWNERS_RULE_REGEX=()
CODEOWNERS_RULE_OWNERS=()
CODEOWNERS_RULE_HAS_OWNERS=()
CODEOWNERS_SOURCE_CANDIDATES=()
CODEOWNERS_MATCH_NONE="__DD_CODEOWNERS_NO_MATCH__"
CODEOWNERS_MATCH_EMPTY="__DD_CODEOWNERS_EMPTY_OWNERS__"
CODEOWNERS_SPLIT_PATTERN=""
CODEOWNERS_SPLIT_OWNERS_RAW=""
CO_EVENTS_SCANNED=0
CO_EVENTS_ENRICHED=0
CO_EVENTS_SKIPPED_EXISTING=0
CO_EVENTS_SKIPPED_MISSING_SOURCE=0
CO_EVENTS_SKIPPED_UNMATCHED=0
CO_EVENTS_SKIPPED_ERRORS=0

decode_percent_path() {
  local value="$1"
  if [[ "$value" != *"%"* ]]; then
    echo "$value"
    return
  fi
  # Avoid introducing NUL bytes into shell strings.
  if [[ "$value" == *"%00"* ]]; then
    echo "$value"
    return
  fi
  # Decode only when every '%' participates in a valid %XX sequence.
  # This keeps behavior deterministic for malformed input.
  local stripped
  stripped=$(echo "$value" | sed -E 's/%[0-9A-Fa-f]{2}//g')
  if [[ "$stripped" == *"%"* ]]; then
    echo "$value"
    return
  fi
  local decoded
  decoded=$(printf '%b' "${value//%/\\x}" 2>/dev/null || true)
  if [[ -n "$decoded" ]]; then
    echo "$decoded"
  else
    echo "$value"
  fi
}

normalize_path_like() {
  local raw="$1"
  if [[ "$raw" == file://* ]]; then
    raw="${raw#file://}"
  fi
  raw=$(decode_percent_path "$raw")
  # Decode can re-introduce backslashes (for example %5C on Windows paths).
  # Normalize after decoding so slash-based matching stays consistent.
  raw="${raw//\\//}"
  # Collapse duplicated separators to improve matching stability.
  while [[ "$raw" == *"//"* ]]; do
    raw=$(echo "$raw" | sed -E 's#/{2,}#/#g')
  done
  while [[ "$raw" == ./* ]]; do
    raw="${raw#./}"
  done
  if [[ "$raw" =~ ^/[A-Za-z]:/ ]]; then
    # file:///C:/... style paths become /C:/... after scheme removal.
    # Drop only the leading slash to preserve the drive-qualified path.
    raw="${raw:1}"
  fi

  local is_abs=0
  if [[ "$raw" == /* ]]; then
    is_abs=1
    raw="${raw#/}"
  fi

  # Canonicalize dot segments. If normalization would escape above root,
  # return failure so caller can skip unsafe/invalid candidates.
  local -a parts=()
  local -a stack=()
  local part idx
  IFS='/' read -r -a parts <<< "$raw"
  for part in "${parts[@]}"; do
    case "$part" in
      ""|".")
        continue
        ;;
      "..")
        if (( ${#stack[@]} > 0 )); then
          idx=$(( ${#stack[@]} - 1 ))
          unset "stack[$idx]"
          stack=("${stack[@]}")
        else
          echo ""
          return 1
        fi
        ;;
      *)
        stack+=("$part")
        ;;
    esac
  done

  local joined=""
  if (( ${#stack[@]} > 0 )); then
    joined="${stack[0]}"
    for ((idx = 1; idx < ${#stack[@]}; idx++)); do
      joined="$joined/${stack[$idx]}"
    done
  fi

  if (( is_abs == 1 )); then
    echo "/$joined"
  else
    echo "$joined"
  fi
  return 0
}

add_path_candidate() {
  local candidate="$1"
  local normalized
  normalized=$(normalize_path_like "$candidate" || true)
  [[ -z "$normalized" ]] && return
  normalized="${normalized#/}"
  while [[ "$normalized" == ./* ]]; do
    normalized="${normalized#./}"
  done
  [[ -z "$normalized" ]] && return
  # Generated output paths do not map to repository-owned source files.
  [[ "$normalized" == bazel-out/* ]] && return
  local existing
  if (( ${#CODEOWNERS_SOURCE_CANDIDATES[@]} > 0 )); then
    for existing in "${CODEOWNERS_SOURCE_CANDIDATES[@]}"; do
      [[ "$existing" == "$normalized" ]] && return
    done
  fi
  CODEOWNERS_SOURCE_CANDIDATES+=("$normalized")
}

add_derived_source_candidate() {
  local candidate="$1"
  if [[ "$candidate" == external/* || "$candidate" == _main/external/* ]]; then
    # Execroot/runfiles derived external paths belong to fetched dependencies,
    # not repository-owned source files. Skip to avoid false owner attribution.
    [[ "$DEBUG" == "1" ]] && dbg "codeowners: skip external source candidate '$candidate'"
    return
  fi
  add_path_candidate "$candidate"
}

strip_workspace_prefix() {
  local path_value="$1"
  local root_value="$2"
  [[ -z "$path_value" || -z "$root_value" ]] && return
  local path_norm root_norm
  path_norm=$(normalize_path_like "$path_value" || true)
  root_norm=$(normalize_path_like "$root_value" || true)
  [[ -z "$path_norm" || -z "$root_norm" ]] && return
  if [[ "$path_norm" == "$root_norm" ]]; then
    echo ""
    return
  fi
  if [[ "$path_norm" == "$root_norm/"* ]]; then
    echo "${path_norm#"$root_norm/"}"
  fi
}

build_source_candidates() {
  local source_path="$1"
  CODEOWNERS_SOURCE_CANDIDATES=()
  local normalized_source stripped
  normalized_source=$(normalize_path_like "$source_path" || true)
  [[ -z "$normalized_source" ]] && return

  stripped=$(strip_workspace_prefix "$normalized_source" "$CODEOWNERS_CONTEXT_WORKSPACE")
  [[ -n "$stripped" ]] && add_path_candidate "$stripped"
  stripped=$(strip_workspace_prefix "$normalized_source" "$CODEOWNERS_WORKSPACE_ROOT")
  [[ -n "$stripped" ]] && add_path_candidate "$stripped"

  if [[ "$normalized_source" =~ /execroot/[^/]+/_main/(.+)$ ]]; then
    add_derived_source_candidate "${BASH_REMATCH[1]}"
  fi
  if [[ "$normalized_source" =~ /execroot/[^/]+/(.+)$ ]]; then
    add_derived_source_candidate "${BASH_REMATCH[1]}"
  fi
  if [[ "$normalized_source" =~ \.runfiles/_main/(.+)$ ]]; then
    add_derived_source_candidate "${BASH_REMATCH[1]}"
  fi
  if [[ "$normalized_source" =~ \.runfiles/[^/]+/(.+)$ ]]; then
    add_derived_source_candidate "${BASH_REMATCH[1]}"
  fi
  # Keep only repository-relative fallback candidates. Absolute paths that are
  # not under known repo roots can incorrectly inherit broad CODEOWNERS rules.
  if [[ "$normalized_source" != /* && ! "$normalized_source" =~ ^[A-Za-z]:/ ]]; then
    add_path_candidate "$normalized_source"
  elif [[ "$DEBUG" == "1" ]]; then
    dbg "codeowners: skip absolute source fallback candidate '$normalized_source'"
  fi
}

glob_to_regex() {
  local pattern="$1"
  local out=""
  local i=0
  local plen="${#pattern}"
  local ch nxt j class_ch class_body class_closed
  while (( i < plen )); do
    ch="${pattern:i:1}"
    # Backslash escapes the next glob metacharacter literally.
    if [[ "$ch" == "\\" ]]; then
      if (( i + 1 < plen )); then
        nxt="${pattern:i+1:1}"
        case "$nxt" in
          "."|"+"|"("|")"|"{"|"}"|"^"|"$"|"|"|"["|"]"|"*"|"?"|"\\")
            if [[ "$nxt" == "\\" ]]; then
              out="$out\\\\"
            else
              out="$out\\$nxt"
            fi
            ;;
          *)
            out="$out$nxt"
            ;;
        esac
        i=$((i + 2))
      else
        out="$out\\\\"
        i=$((i + 1))
      fi
      continue
    fi
    if [[ "$ch" == "*" ]] && (( i + 1 < plen )); then
      nxt="${pattern:i+1:1}"
      if [[ "$nxt" == "*" ]]; then
        if (( i + 2 < plen )) && [[ "${pattern:i+2:1}" == "/" ]]; then
          # CODEOWNERS follows gitignore-style globbing: **/ matches zero or more directories.
          out="${out}(.*/)?"
          i=$((i + 3))
        else
          out="${out}.*"
          i=$((i + 2))
        fi
        continue
      fi
    fi
    if [[ "$ch" == "[" ]]; then
      # Preserve character class semantics (including "!"/"^" negation).
      j=$((i + 1))
      class_body=""
      class_closed=0
      if (( j < plen )) && [[ "${pattern:j:1}" == "!" ]]; then
        class_body="^"
        j=$((j + 1))
      elif (( j < plen )) && [[ "${pattern:j:1}" == "^" ]]; then
        class_body="\\^"
        j=$((j + 1))
      fi
      if (( j < plen )) && [[ "${pattern:j:1}" == "]" ]]; then
        class_body="$class_body\\]"
        j=$((j + 1))
      fi
      while (( j < plen )); do
        class_ch="${pattern:j:1}"
        if [[ "$class_ch" == "]" ]]; then
          class_closed=1
          break
        fi
        case "$class_ch" in
          "\\")
            class_body="$class_body\\\\"
            ;;
          "^")
            class_body="$class_body\\^"
            ;;
          "[")
            class_body="$class_body\\["
            ;;
          *)
            class_body="$class_body$class_ch"
            ;;
        esac
        j=$((j + 1))
      done
      if (( class_closed == 1 )); then
        out="${out}[$class_body]"
        i=$((j + 1))
        continue
      fi
      out="${out}\\["
      i=$((i + 1))
      continue
    fi
    case "$ch" in
      "*")
        out="${out}[^/]*"
        ;;
      "?")
        out="${out}[^/]"
        ;;
      "."|"+"|"("|")"|"{"|"}"|"^"|"$"|"|"|"\\")
        out="${out}\\$ch"
        ;;
      "]")
        out="${out}\\]"
        ;;
      *)
        out="${out}$ch"
        ;;
    esac
    i=$((i + 1))
  done
  echo "$out"
}

compile_codeowners_regex() {
  local pattern="$1"
  local anchored=0
  local dir_only=0
  if [[ "$pattern" == /* ]]; then
    anchored=1
    pattern="${pattern#/}"
  fi
  if [[ "$pattern" == */ ]]; then
    dir_only=1
    pattern="${pattern%/}"
  fi
  [[ -z "$pattern" ]] && return 1

  local has_slash=0
  [[ "$pattern" == */* ]] && has_slash=1
  local body
  body=$(glob_to_regex "$pattern")
  local prefix suffix regex
  # Match semantics:
  # - anchored or slash-containing patterns match from repo root
  # - plain patterns match at any path segment boundary
  if (( anchored == 1 || has_slash == 1 )); then
    prefix="^"
  else
    prefix="(^|.*/)"
  fi
  if (( dir_only == 1 )); then
    suffix="/.*$"
  else
    suffix="($|/.*)"
  fi
  regex="$prefix$body$suffix"
  echo "$regex"
  return 0
}

parse_codeowners_file() {
  local file_path="$1"
  local line pattern rest regex
  local -a owner_tokens=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    # Section headers may include spaces (for example "[Core Team] @org/team").
    # Detect them from the full raw line before splitting on whitespace.
    if is_gitlab_section_header_line "$line"; then
      continue
    fi
    split_codeowners_pattern_and_owners "$line"
    pattern="$CODEOWNERS_SPLIT_PATTERN"
    rest="$CODEOWNERS_SPLIT_OWNERS_RAW"
    # Ignore GitLab section headers while preserving bracket-class glob rules.
    # This keeps patterns like "[xy] @team/owners" valid CODEOWNERS entries.
    if is_gitlab_section_header_pattern "$pattern"; then
      continue
    fi
    # Strip comments in owner segments while preserving '#' inside owner tokens.
    # Example: "@org/team#chat" stays intact, while " @org/team # note" strips note.
    if [[ "$rest" == "#"* ]]; then
      rest=""
    elif [[ "$rest" == *[[:space:]]#* ]]; then
      rest=$(printf '%s
' "$rest" | sed -E 's/[[:space:]]#.*$//')
    fi
    rest="${rest%"${rest##*[![:space:]]}"}"
    [[ -z "$pattern" ]] && continue
    owner_tokens=()
    if [[ -n "$rest" ]]; then
      read -r -a owner_tokens <<< "$rest"
    fi
    regex=$(compile_codeowners_regex "$pattern" || true)
    [[ -z "$regex" ]] && continue
    # Some character-class patterns can produce invalid POSIX ERE fragments
    # (for example "[z-a]"). Validate here so malformed rules are skipped once
    # at parse time instead of repeatedly triggering regex-eval errors later.
    if ! codeowners_regex_is_valid "$regex"; then
      [[ "$DEBUG" == "1" ]] && dbg "codeowners: skipping invalid regex '$regex' from pattern '$pattern'"
      continue
    fi
    CODEOWNERS_RULE_REGEX+=("$regex")
    if (( ${#owner_tokens[@]} == 0 )); then
      CODEOWNERS_RULE_OWNERS+=("")
      CODEOWNERS_RULE_HAS_OWNERS+=("0")
    else
      CODEOWNERS_RULE_OWNERS+=("$rest")
      CODEOWNERS_RULE_HAS_OWNERS+=("1")
    fi
    if [[ "$DEBUG" == "1" ]]; then
      local owners_dbg="<empty>"
      if (( ${#owner_tokens[@]} > 0 )); then
        owners_dbg="$rest"
      fi
      dbg "codeowners: parsed rule pattern='$pattern' regex='$regex' owners='$owners_dbg'"
    fi
  done < "$file_path"
}

is_gitlab_section_header_pattern() {
  local pattern="$1"
  [[ "$pattern" =~ ^\[[^][]+\]$ ]] || return 1
  local inner="${pattern:1:${#pattern}-2}"
  # GitLab section headers can include whitespace (for example [Core Team]).
  if [[ "$inner" == *[[:space:]]* ]]; then
    return 0
  fi
  # Heuristic to avoid class-only glob false positives:
  # keep range-like and short bracket classes (for example [xy], [A-Z]).
  if [[ "$inner" == *"-"* || "$inner" == *"!"* || "$inner" == *"^"* || "$inner" == *"\\"* ]]; then
    return 1
  fi
  # Preserve all-uppercase/digit class sets such as [ABCD] and [A1B2C3].
  if [[ "$inner" =~ ^[A-Z0-9]+$ ]]; then
    return 1
  fi
  # Preserve short alnum bracket classes (for example [xy], [ABC], [Abc]).
  if (( ${#inner} <= 3 )) && [[ "$inner" =~ ^[A-Za-z0-9]+$ ]]; then
    return 1
  fi
  # Preserve plain lowercase/digit class sets such as [abc] and [a1b2].
  if [[ "$inner" =~ ^[a-z0-9]+$ ]]; then
    return 1
  fi
  return 0
}

is_gitlab_section_header_line() {
  local line="$1"
  if [[ "$line" =~ ^(\[[^][]+\])([[:space:]]+.*)?$ ]]; then
    is_gitlab_section_header_pattern "${BASH_REMATCH[1]}"
    return $?
  fi
  return 1
}

codeowners_regex_is_valid() {
  local regex="$1"
  local status=0
  # Run the probe inside `if` so set -e does not abort on a normal no-match.
  if ( [[ "" =~ $regex ]] ) 2>/dev/null; then
    status=0
  else
    status=$?
  fi
  # Bash returns:
  #   0 => matched
  #   1 => valid regex, no match
  #   2 => invalid regex syntax
  if (( status == 0 || status == 1 )); then
    return 0
  fi
  return 1
}

split_codeowners_pattern_and_owners() {
  local line="$1"
  local pattern=""
  local rest=""
  local i ch escaped=0
  local line_len="${#line}"
  for ((i = 0; i < line_len; i++)); do
    ch="${line:i:1}"
    if (( escaped == 1 )); then
      pattern="$pattern$ch"
      escaped=0
      continue
    fi
    if [[ "$ch" == "\\" ]]; then
      pattern="$pattern$ch"
      escaped=1
      continue
    fi
    # Split on the first unescaped whitespace character.
    # We intentionally use a character-class check (instead of only " " and
    # tab) to match CODEOWNERS behavior for any ASCII whitespace separator.
    if [[ "$ch" =~ [[:space:]] ]]; then
      rest="${line:i}"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      CODEOWNERS_SPLIT_PATTERN="$pattern"
      CODEOWNERS_SPLIT_OWNERS_RAW="$rest"
      return 0
    fi
    pattern="$pattern$ch"
  done
  CODEOWNERS_SPLIT_PATTERN="$pattern"
  CODEOWNERS_SPLIT_OWNERS_RAW=""
  return 0
}

init_codeowners() {
  (( CODEOWNERS_INITIALIZED == 1 )) && return
  CODEOWNERS_INITIALIZED=1
  if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
    CODEOWNERS_WORKSPACE_ROOT="$BUILD_WORKSPACE_DIRECTORY"
  elif [[ -n "${TESTLOGS_DIR:-}" && "$TESTLOGS_DIR" == */bazel-testlogs* ]]; then
    CODEOWNERS_WORKSPACE_ROOT="${TESTLOGS_DIR%%/bazel-testlogs*}"
  else
    CODEOWNERS_WORKSPACE_ROOT="$(pwd)"
  fi
  [[ -z "$CODEOWNERS_WORKSPACE_ROOT" ]] && CODEOWNERS_WORKSPACE_ROOT="$(pwd)"
  CODEOWNERS_CONTEXT_WORKSPACE=""
  if (( JQ_AVAILABLE == 1 )) && [[ -n "$CONTEXT_JSON" && -f "$CONTEXT_JSON" ]]; then
    CODEOWNERS_CONTEXT_WORKSPACE=$(jq -r '."ci.workspace_path" // empty' "$CONTEXT_JSON" 2>/dev/null || true)
  fi

  local explicit_codeowners="${DD_TEST_OPTIMIZATION_CODEOWNERS_FILE:-}"
  if [[ -n "$explicit_codeowners" ]]; then
    [[ "$DEBUG" == "1" ]] && dbg "codeowners: explicit path candidate '$explicit_codeowners'"
    if [[ -f "$explicit_codeowners" && -r "$explicit_codeowners" ]]; then
      CODEOWNERS_FILE="$explicit_codeowners"
      dbg "codeowners: using explicit CODEOWNERS file '$CODEOWNERS_FILE'"
    else
      dbg "codeowners: DD_TEST_OPTIMIZATION_CODEOWNERS_FILE is set but not readable: '$explicit_codeowners' (falling back to discovery)"
    fi
  fi

  local script_dir
  script_dir=$(cd "$(dirname "$0")" && pwd -P)
  local -a candidates=()
  if [[ -z "$CODEOWNERS_FILE" ]]; then
    # Lookup order is intentional and mirrored in PowerShell implementation.
    # We prefer `ci.workspace_path` when present, then workspace-derived paths,
    # then process cwd, then script directory fallback.
    if [[ -n "$CODEOWNERS_CONTEXT_WORKSPACE" ]]; then
      candidates+=(
        "$CODEOWNERS_CONTEXT_WORKSPACE/CODEOWNERS"
        "$CODEOWNERS_CONTEXT_WORKSPACE/.github/CODEOWNERS"
        "$CODEOWNERS_CONTEXT_WORKSPACE/.gitlab/CODEOWNERS"
        "$CODEOWNERS_CONTEXT_WORKSPACE/docs/CODEOWNERS"
        "$CODEOWNERS_CONTEXT_WORKSPACE/.docs/CODEOWNERS"
      )
    fi
    if [[ -n "$CODEOWNERS_WORKSPACE_ROOT" ]]; then
      candidates+=(
        "$CODEOWNERS_WORKSPACE_ROOT/CODEOWNERS"
        "$CODEOWNERS_WORKSPACE_ROOT/.github/CODEOWNERS"
        "$CODEOWNERS_WORKSPACE_ROOT/.gitlab/CODEOWNERS"
        "$CODEOWNERS_WORKSPACE_ROOT/docs/CODEOWNERS"
        "$CODEOWNERS_WORKSPACE_ROOT/.docs/CODEOWNERS"
      )
    fi
    candidates+=(
      "./CODEOWNERS"
      "$script_dir/CODEOWNERS"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
      [[ -z "$candidate" ]] && continue
      [[ "$DEBUG" == "1" && -f "$candidate" ]] && dbg "codeowners: discovery candidate hit '$candidate'"
      if [[ -f "$candidate" && -r "$candidate" ]]; then
        CODEOWNERS_FILE="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$CODEOWNERS_FILE" ]]; then
    dbg "codeowners: no CODEOWNERS file found (workspace='$CODEOWNERS_WORKSPACE_ROOT')"
    return
  fi

  parse_codeowners_file "$CODEOWNERS_FILE"
  if (( ${#CODEOWNERS_RULE_REGEX[@]} > 0 )); then
    CODEOWNERS_ENABLED=1
    dbg "codeowners: using '$CODEOWNERS_FILE' with ${#CODEOWNERS_RULE_REGEX[@]} rule(s)"
  else
    dbg "codeowners: file '$CODEOWNERS_FILE' had no usable rules"
  fi
}

dedupe_owners() {
  local owners_line="$1"
  local -a in_tokens=()
  local -a out_tokens=()
  local token existing seen
  read -r -a in_tokens <<< "$owners_line"
  for token in "${in_tokens[@]}"; do
    [[ -z "$token" ]] && continue
    seen=0
    if (( ${#out_tokens[@]} > 0 )); then
      for existing in "${out_tokens[@]}"; do
        if [[ "$existing" == "$token" ]]; then
          seen=1
          break
        fi
      done
    fi
    (( seen == 0 )) && out_tokens+=("$token")
  done
  if (( ${#out_tokens[@]} > 0 )); then
    printf '%s
' "${out_tokens[@]}"
  fi
}

owners_line_to_json() {
  local owners_line="$1"
  local deduped
  deduped=$(dedupe_owners "$owners_line" | jq -R . | jq -s -c '.' 2>/dev/null || true)
  if [[ "$deduped" == "[]" ]]; then
    echo ""
  else
    echo "$deduped"
  fi
}

match_codeowners_owners_line() {
  local candidate="$1"
  local idx regex owners_line rule_has_owners matched="$CODEOWNERS_MATCH_NONE"
  # Last matching CODEOWNERS rule wins.
  for ((idx = 0; idx < ${#CODEOWNERS_RULE_REGEX[@]}; idx++)); do
    regex="${CODEOWNERS_RULE_REGEX[$idx]}"
    owners_line="${CODEOWNERS_RULE_OWNERS[$idx]}"
    rule_has_owners="${CODEOWNERS_RULE_HAS_OWNERS[$idx]}"
    if [[ "$candidate" =~ $regex ]]; then
      if [[ "$rule_has_owners" == "1" ]]; then
        matched="$owners_line"
      else
        matched="$CODEOWNERS_MATCH_EMPTY"
      fi
    fi
  done
  echo "$matched"
}

resolve_codeowners_json_for_source() {
  local source_path="$1"
  build_source_candidates "$source_path"
  local candidate owners_line owners_json
  # Candidate order matters: prefer repo-relative derivations before broader
  # fallbacks so ownership reflects the most likely source path.
  for candidate in "${CODEOWNERS_SOURCE_CANDIDATES[@]}"; do
    owners_line=$(match_codeowners_owners_line "$candidate")
    if [[ "$DEBUG" == "1" ]]; then
      if [[ "$owners_line" == "$CODEOWNERS_MATCH_NONE" ]]; then
        dbg "codeowners: candidate='$candidate' owners='<none>'"
      elif [[ "$owners_line" == "$CODEOWNERS_MATCH_EMPTY" ]]; then
        dbg "codeowners: candidate='$candidate' owners='<empty>'"
      else
        dbg "codeowners: candidate='$candidate' owners='$owners_line'"
      fi
    fi
    if [[ "$owners_line" == "$CODEOWNERS_MATCH_NONE" ]]; then
      continue
    fi
    if [[ "$owners_line" == "$CODEOWNERS_MATCH_EMPTY" ]]; then
      # Explicit "no owners" rule matched; treat as no tag.
      # This preserves CODEOWNERS semantics where later empty-owner rules
      # intentionally clear ownership for matching paths.
      echo ""
      return
    fi
    if [[ -n "$owners_line" ]]; then
      owners_json=$(owners_line_to_json "$owners_line")
      if [[ -n "$owners_json" ]]; then
        echo "$owners_json"
        return
      fi
    fi
  done
  echo ""
}

inject_codeowners_tags() {
  local payload_file="$1"
  init_codeowners
  (( CODEOWNERS_ENABLED == 1 )) || return 0

  local events_len idx event_type has_existing source_path owners_json tmp_payload
  # Skip gracefully on malformed payload shapes; uploader remains best-effort.
  events_len=$(jq '.events | if type=="array" then length else 0 end' "$payload_file" 2>/dev/null || echo 0)
  if ! [[ "$events_len" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  for ((idx = 0; idx < events_len; idx++)); do
    event_type=$(jq -r --argjson idx "$idx" '.events[$idx].type // ""' "$payload_file" 2>/dev/null || true)
    # Spans are intentionally not enriched with CODEOWNERS metadata.
    [[ "$event_type" == "span" ]] && continue
    ((++CO_EVENTS_SCANNED))

    has_existing=$(jq -r --argjson idx "$idx" 'if (.events[$idx].content.meta | type) == "object" and (.events[$idx].content.meta | has("test.codeowners")) then "1" else "0" end' "$payload_file" 2>/dev/null || echo "0")
    if [[ "$has_existing" == "1" ]]; then
      ((++CO_EVENTS_SKIPPED_EXISTING))
      [[ "$DEBUG" == "1" ]] && dbg "codeowners: skip existing tag at event[$idx]"
      continue
    fi

    source_path=$(jq -r --argjson idx "$idx" '.events[$idx].content.meta["test.source.file"] // .events[$idx].content.meta["test.source.path"] // .events[$idx].content.meta["source.file"] // .events[$idx].content.meta["source.path"] // .events[$idx].content.source.file // .events[$idx].content.source.path // ""' "$payload_file" 2>/dev/null || true)
    if [[ -z "$source_path" ]]; then
      ((++CO_EVENTS_SKIPPED_MISSING_SOURCE))
      [[ "$DEBUG" == "1" ]] && dbg "codeowners: skip missing source at event[$idx]"
      continue
    fi

    owners_json=$(resolve_codeowners_json_for_source "$source_path")
    if [[ -z "$owners_json" ]]; then
      ((++CO_EVENTS_SKIPPED_UNMATCHED))
      [[ "$DEBUG" == "1" ]] && dbg "codeowners: skip unmatched source '$source_path' at event[$idx]"
      continue
    fi

    tmp_payload=$(mktemp "$TMP_PAYLOAD_DIR/codeowners_payload.XXXXXX" 2>/dev/null || true)
    if [[ -z "$tmp_payload" ]]; then
      ((++CO_EVENTS_SKIPPED_ERRORS))
      [[ "$DEBUG" == "1" ]] && dbg "codeowners: skip internal error creating temp payload at event[$idx]"
      continue
    fi
    if jq --arg owners "$owners_json" --argjson idx "$idx" '
      .events[$idx].content = (.events[$idx].content // {})
      | .events[$idx].content.meta = ((.events[$idx].content.meta // {}) | .["test.codeowners"] = $owners)
    ' "$payload_file" > "$tmp_payload"; then
      # Atomic replacement prevents partially-written payload files.
      mv "$tmp_payload" "$payload_file"
      ((++CO_EVENTS_ENRICHED))
      [[ "$DEBUG" == "1" ]] && dbg "codeowners: assigned owners '$owners_json' at event[$idx]"
    else
      rm -f "$tmp_payload" 2>/dev/null || true
      ((++CO_EVENTS_SKIPPED_ERRORS))
      [[ "$DEBUG" == "1" ]] && dbg "codeowners: skip jq update failure at event[$idx]"
    fi
  done

  if [[ "$DEBUG" == "1" ]]; then
    dbg "codeowners: scanned=$CO_EVENTS_SCANNED enriched=$CO_EVENTS_ENRICHED skipped_existing=$CO_EVENTS_SKIPPED_EXISTING skipped_missing_source=$CO_EVENTS_SKIPPED_MISSING_SOURCE skipped_unmatched=$CO_EVENTS_SKIPPED_UNMATCHED skipped_errors=$CO_EVENTS_SKIPPED_ERRORS"
  fi
}

# Build common Datadog headers, optionally deriving values from payload metadata["*"].
build_common_headers() {
  local payload_file="${1:-}"
  local lang="$HEADER_LANG_DEFAULT"
  local lang_version="$HEADER_LANG_VERSION_DEFAULT"
  local lang_interpreter="$HEADER_LANG_INTERPRETER_DEFAULT"
  local tracer_version="$HEADER_TRACER_VERSION_DEFAULT"

  if (( JQ_AVAILABLE == 1 )) && [[ -n "$payload_file" && -f "$payload_file" ]]; then
    local meta_values meta_lang meta_tracer meta_lang_version meta_lang_interpreter
    meta_values=$(jq -r '
      [
        .metadata["*"]["language"] // "",
        .metadata["*"]["library_version"] // "",
        (.metadata["*"]["language_version"] // .metadata["*"]["runtime_version"] // ""),
        (.metadata["*"]["language_interpreter"] // .metadata["*"]["runtime_name"] // "")
      ] | @tsv
    ' "$payload_file" 2>/dev/null || true)
    if [[ -n "$meta_values" ]]; then
      IFS=$'	' read -r meta_lang meta_tracer meta_lang_version meta_lang_interpreter <<< "$meta_values"
      [[ -n "$meta_lang" ]] && lang="$meta_lang"
      [[ -n "$meta_tracer" ]] && tracer_version="$meta_tracer"
      [[ -n "$meta_lang_version" ]] && lang_version="$meta_lang_version"
      [[ -n "$meta_lang_interpreter" ]] && lang_interpreter="$meta_lang_interpreter"
    fi
  fi

  COMMON_HDRS=(
    -H "Datadog-Meta-Lang: $lang"
    -H "Datadog-Meta-Lang-Version: $lang_version"
    -H "Datadog-Meta-Lang-Interpreter: $lang_interpreter"
    -H "Datadog-Meta-Tracer-Version: $tracer_version"
    -H "Accept: application/json"
  )
}

# Execute curl in agentless mode while sending DD-API-KEY via stdin (`-H @-`).
# This avoids exposing raw credentials in process arguments.
curl_agentless() {
  if [[ -z "${DD_API_KEY:-}" ]]; then
    return 2
  fi
  printf 'DD-API-KEY: %s
' "$DD_API_KEY" | curl "$@" -H @-
}

# Optional check: verify fetch-time API key fingerprint matches uploader API key.
API_KEY_FINGERPRINT=""
if (( JQ_AVAILABLE == 1 )) && [[ -n "$CONTEXT_JSON" && -f "$CONTEXT_JSON" ]]; then
  API_KEY_FINGERPRINT=$(jq -r '."topt.api_key_fingerprint" // empty' "$CONTEXT_JSON" 2>/dev/null || true)
fi
if [[ -n "$API_KEY_FINGERPRINT" ]]; then
  if (( AGENTLESS == 1 )); then
    # Compare fetch-time and upload-time credentials without exposing raw keys.
    local_fp=$(fnv1a_32 "$DD_API_KEY")
    if [[ -n "$local_fp" && "$local_fp" != "$API_KEY_FINGERPRINT" ]]; then
      log "warning: DD_API_KEY mismatch between fetch and uploader"
    else
      dbg "DD_API_KEY fingerprint match"
    fi
  else
    # EVP mode does not require DD_API_KEY for upload requests.
    log "warning: DD_API_KEY fingerprint present but uploader running in EVP mode; check skipped"
  fi
elif [[ -n "$CONTEXT_JSON" && -f "$CONTEXT_JSON" && "$JQ_AVAILABLE" != "1" ]]; then
  dbg "api key fingerprint check skipped: jq not available"
fi

enrich_with_context() {
  local infile="$1"; local tmpfile="$2"
  dbg "enrich_with_context: infile='$infile' outfile='$tmpfile' ctx='${CONTEXT_JSON:-<none>}' jq=$JQ_AVAILABLE"
  if (( JQ_AVAILABLE == 0 )); then
    # No jq means no structural merge; forward original payload unchanged.
    cp "$infile" "$tmpfile"
    return 0
  fi
  local ctx_file="$CONTEXT_JSON"
  local cleanup_ctx=""
  if [[ -z "$ctx_file" || ! -f "$ctx_file" ]]; then
    # Missing context is non-fatal: use empty object so enrichment still
    # normalizes metadata shape without injecting context tags.
    ctx_file="$(mktemp "$TMP_PAYLOAD_DIR/context.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$ctx_file" ]]; then
      cp "$infile" "$tmpfile"
      return 0
    fi
    echo '{}' > "$ctx_file"
    cleanup_ctx=1
  fi
  jq --slurpfile ctx "$ctx_file"     --arg runtime_id "$RUNTIME_ID"     --arg rules_version "$RULES_VERSION"     --arg language_fallback "bazel" '
    def ctx_val($k): $ctx[0][$k];
    def ctx_str($k): (ctx_val($k) | if type=="string" and length>0 then . else null end);
    def ctx_runtime_id: (ctx_str("runtime-id") // ctx_str("runtime.id") // ctx_str("runtime_id"));
    def ctx_language: (ctx_str("language") // ctx_str("runtime.name") // ctx_str("runtime_name"));
    def ctx_env: ctx_str("env");
    def ctx_filtered: ($ctx[0] | with_entries(select(.key != "topt.api_key_fingerprint")));
    def meta_star: (.metadata["*"] | if type=="object" then . else {} end);
    def runtime_id: (meta_star["runtime-id"] // ctx_runtime_id // $runtime_id);
    def language: (meta_star["language"] // ctx_language // $language_fallback);
    def library_version: (meta_star["library_version"] // $rules_version);
    def env: (meta_star["env"] // ctx_env);
    .metadata = (.metadata // {})
    | .metadata["*"] = (
        { "runtime-id": runtime_id, "language": language, "library_version": library_version }
        + (if (env|type) == "string" then { "env": env } else {} end)
      )
    | .metadata = (
        { "*": .metadata["*"] }
        + (if (.metadata["test"]? != null) then { "test": .metadata["test"] } else {} end)
        + (if (.metadata["test_suite_end"]? != null) then { "test_suite_end": .metadata["test_suite_end"] } else {} end)
        + (if (.metadata["test_module_end"]? != null) then { "test_module_end": .metadata["test_module_end"] } else {} end)
        + (if (.metadata["test_session_end"]? != null) then { "test_session_end": .metadata["test_session_end"] } else {} end)
      )
    | (if .events then
        .events |= map(
          if (.type? == "span") then .
          else
            (
              .content = (.content // {})
              | .content.meta = (if (.content.meta|type) == "object" then .content.meta else {} end)
              | .content.metrics = (if (.content.metrics|type) == "object" then .content.metrics else {} end)
              | reduce (ctx_filtered | to_entries[]) as $e (.;
                  if ($e.value|type) == "number" then
                    .content.metrics[$e.key] = $e.value
                  elif ($e.value|type) == "string" then
                    .content.meta[$e.key] = $e.value
                  else
                    .content.meta[$e.key] = ($e.value|tostring)
                  end
                )
            )
          end
        )
      else .
      end)
  ' "$infile" > "$tmpfile"
  # CODEOWNERS enrichment is applied after metadata/context merge so source-path
  # detection can leverage normalized event structure.
  inject_codeowners_tags "$tmpfile"
  if [[ -n "$cleanup_ctx" ]]; then
    rm -f "$ctx_file" 2>/dev/null || true
  fi
}

# Emit basic startTime statistics (ms) for debugging when jq is available.
log_start_time_stats() {
  local file="$1"
  if (( JQ_AVAILABLE == 0 )); then
    dbg "startTime stats skipped: jq not available"
    return 0
  fi
  local times
  # Prefer startTime; fall back to start if startTime is absent
  times=$(jq -r '.. | objects | (.startTime? // .start?) | select(type=="number")' "$file" 2>/dev/null || true)
  if [[ -z "$times" ]]; then
    dbg "startTime stats: no startTime fields found in $file"
    return 0
  fi
  local min max
  read min max < <(echo "$times" | awk 'NR==1{min=$1;max=$1} {if($1<min)min=$1;if($1>max)max=$1} END{print min,max}')
  local now_ms
  now_ms=$(( $(date +%s) * 1000 ))
  dbg "startTime/ms range for $file: min=$min max=$max now=$now_ms"
}

# Check if file matches prefix filter (when enabled)
matches_filter() {
    local file="$1"
    local expected_prefix="$2"
    if [[ "$FILTER_PREFIX" == "1" ]]; then
        local basename
        basename=$(basename "$file")
        [[ "$basename" == "$expected_prefix"* ]]
    else
        return 0  # No filtering, accept all
    fi
}

# Delete file unless KEEP_PAYLOADS is set
cleanup_file() {
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
}

validate_payload() {
    local file="$1"
    if [[ -z "$SCHEMA_JSON" || ! -f "$SCHEMA_JSON" ]]; then
        # Validation is best-effort and must never block uploads by default.
        dbg "schema validation skipped: schema not available"
        return 0
    fi
    if [[ -z "$SCHEMA_VALIDATOR" || ! -f "$SCHEMA_VALIDATOR" ]]; then
        dbg "schema validation skipped: validator not available"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        dbg "schema validation skipped: python3 not available"
        return 0
    fi
    dbg "schema validate: python3 $SCHEMA_VALIDATOR $SCHEMA_JSON $file"
    if ! python3 "$SCHEMA_VALIDATOR" "$SCHEMA_JSON" "$file"; then
        # Keep warning-only behavior so schema drift does not drop payloads.
        log "warning: schema validation failed for payload: $file"
    fi
    return 0
}

# Track upload failures globally
UPLOAD_FAILURES=0

upload_single_test() {
    local file="$1"
    local body resp payload_file gz http rc
    # Use a temp file to avoid collisions when multiple uploads run in parallel.
    body="$(mktemp "$TMP_PAYLOAD_DIR/test_payload.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$body" ]]; then
        dbg "upload_single_test: failed to create temp file"
        return 1
    fi
    enrich_with_context "$file" "$body"
    validate_payload "$body"
    build_common_headers "$body"
    dbg "upload_single_test: posting '$file' (body '$body')"
    if [[ "$DEBUG" == "1" ]]; then
        local gzip_note=""
        if [[ "$GZIP_PAYLOADS" == "1" ]]; then
            gzip_note="; Content-Encoding=gzip"
        fi
        echo "[dd-uploader][dbg] payload content (enriched) for '$file':" >&2
        cat "$body" >&2
        echo "" >&2
        log_start_time_stats "$body"
        dbg "headers: Content-Type=application/json${gzip_note}"
    fi

    payload_file="$body"
    gz=""
    if [[ "$GZIP_PAYLOADS" == "1" ]]; then
        # Compress enriched payload, but gracefully fall back to plain JSON if
        # gzip is unavailable/fails on the host.
        gz="$body.gz"
        if gzip -c "$body" > "$gz"; then
            payload_file="$gz"
        else
            log "warning: gzip failed; sending uncompressed payload"
            gz=""
        fi
    fi

    resp="$(mktemp "$TMP_PAYLOAD_DIR/test_resp.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$resp" ]]; then
        dbg "upload_single_test: failed to create response temp file"
        rm -f "$body" "$gz" 2>/dev/null || true
        return 1
    fi
    local ce_hdr=()
    if [[ "$payload_file" != "$body" ]]; then
        # Signal compressed body only when gzip output is actually used.
        ce_hdr=(-H "Content-Encoding: gzip")
    fi
    if [[ "$DEBUG" == "1" ]]; then
        dbg "request: POST $TEST_URL"
        dbg_headers "common" "${COMMON_HDRS[@]}"
        if (( AGENTLESS == 0 )); then
            dbg_headers "evp" "${TEST_EVP[@]}"
        fi
        if [[ "$payload_file" != "$body" ]]; then
            dbg "header[content-encoding]: Content-Encoding: gzip"
        fi
    fi
    if (( AGENTLESS == 1 )); then
      http=$(curl_agentless -f -sS --connect-timeout 10 --max-time 60 "${CURL_RETRY_FLAGS[@]}" \
        -X POST "${TEST_URL}" "${COMMON_HDRS[@]}" "${ce_hdr[@]+${ce_hdr[@]}}" -H "Content-Type: application/json" --data-binary @"${payload_file}" -o "$resp" -w "%{http_code}")
    else
      http=$(curl -f -sS --connect-timeout 10 --max-time 60 "${CURL_RETRY_FLAGS[@]}" \
        -X POST "${TEST_URL}" "${COMMON_HDRS[@]}" "${TEST_EVP[@]}" "${ce_hdr[@]+${ce_hdr[@]}}" -H "Content-Type: application/json" --data-binary @"${payload_file}" -o "$resp" -w "%{http_code}")
    fi
    rc=$?
    http="${http:-000}"
    if [[ "$DEBUG" == "1" || $rc -ne 0 || "$http" -lt 200 || "$http" -ge 300 ]]; then
        dbg "upload_single_test: HTTP $http (rc=$rc)"
        if [[ -s "$resp" ]]; then
            dbg "upload_single_test response: $(head -c 2000 "$resp")"
        fi
    fi
    rm -f "$resp" "$body" "$gz" 2>/dev/null || true
    # Cleanup happens before return to avoid temp-file buildup on retries/runs.
    if [[ $rc -ne 0 || "$http" -lt 200 || "$http" -ge 300 ]]; then
        return 1
    fi
    return 0
}

upload_single_coverage() {
    local file="$1"
    # Create event.json for multipart
    local eventjson resp http rc
    # Use a temp file for multipart metadata to avoid leaking into runfiles.
    eventjson="$(mktemp "$TMP_PAYLOAD_DIR/coverage_event.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$eventjson" ]]; then
        dbg "upload_single_coverage: failed to create temp file"
        return 1
    fi
    echo '{"dummy":true}' > "$eventjson"
    build_common_headers ""
    dbg "upload_single_coverage: posting '$file'"
    resp="$(mktemp "$TMP_PAYLOAD_DIR/coverage_resp.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$resp" ]]; then
        dbg "upload_single_coverage: failed to create response temp file"
        rm -f "$eventjson" 2>/dev/null || true
        return 1
    fi
    if [[ "$DEBUG" == "1" ]]; then
        dbg "request: POST $COV_URL"
        dbg_headers "common" "${COMMON_HDRS[@]}"
        if (( AGENTLESS == 0 )); then
            dbg_headers "evp" "${COV_EVP[@]}"
        fi
        dbg "headers: multipart/form-data (event + coveragex)"
    fi
    if (( AGENTLESS == 1 )); then
      http=$(curl_agentless -f -sS --connect-timeout 10 --max-time 60 "${CURL_RETRY_FLAGS[@]}" \
        -X POST "${COV_URL}" "${COMMON_HDRS[@]}" \
        -F "event=@${eventjson};type=application/json;filename=fileevent.json" \
        -F "coveragex=@${file};type=application/json;filename=filecoveragex.json" -o "$resp" -w "%{http_code}")
    else
      http=$(curl -f -sS --connect-timeout 10 --max-time 60 "${CURL_RETRY_FLAGS[@]}" \
        -X POST "${COV_URL}" "${COMMON_HDRS[@]}" "${COV_EVP[@]}" \
        -F "event=@${eventjson};type=application/json;filename=fileevent.json" \
        -F "coveragex=@${file};type=application/json;filename=filecoveragex.json" -o "$resp" -w "%{http_code}")
    fi
    rc=$?
    http="${http:-000}"
    if [[ "$DEBUG" == "1" || $rc -ne 0 || "$http" -lt 200 || "$http" -ge 300 ]]; then
        dbg "upload_single_coverage: HTTP $http (rc=$rc)"
        if [[ -s "$resp" ]]; then
            dbg "upload_single_coverage response: $(head -c 2000 "$resp")"
        fi
    fi
    rm -f "$resp" "$eventjson" 2>/dev/null || true
    if [[ $rc -ne 0 || "$http" -lt 200 || "$http" -ge 300 ]]; then
        return 1
    fi
    return 0
}

upload_all_tests() {
    local total=0
    local failed=0
    local skipped=0
    # Iterate the cached test.outputs list to avoid rescanning the filesystem.
    while IFS= read -r outputs_dir; do
        [[ -z "$outputs_dir" ]] && continue
        local tests_dir="$outputs_dir/payloads/tests"
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
                # Keep uploading subsequent files to maximize successful delivery
                # even when one payload is malformed or temporarily rejected.
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
}

upload_all_coverage() {
    local total=0
    local failed=0
    local skipped=0
    # Iterate the cached test.outputs list to avoid rescanning the filesystem.
    while IFS= read -r outputs_dir; do
        [[ -z "$outputs_dir" ]] && continue
        local cov_dir="$outputs_dir/payloads/coverage"
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
                # Coverage failures are tracked but non-fatal per-file; final
                # exit code reflects aggregate failure count after both passes.
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
}

upload_all_tests
upload_all_coverage

# Exit with appropriate code based on upload results
if (( UPLOAD_FAILURES > 0 )); then
    # Non-zero signals partial/total upload failure to CI orchestration.
    log "done with $UPLOAD_FAILURES upload failures"
    exit 1
else
    # Zero means either complete success or intentional no-op path above.
    log "done"
    exit 0
fi
