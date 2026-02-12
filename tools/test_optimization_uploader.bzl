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
# Rules version used for payload metadata defaults
RULES_VERSION = "1.0.0"

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

def _codeowners_glob_to_regex_for_tests(pattern):
    out = []
    plen = len(pattern)
    skip = {}
    for i in range(plen):
        if skip.get(i):
            continue
        ch = pattern[i]
        if ch == "\\":
            if i + 1 < plen:
                esc = pattern[i + 1]
                if esc in [".", "+", "(", ")", "{", "}", "^", "$", "|", "\\", "[", "]", "*", "?"]:
                    out.append("\\" + esc)
                else:
                    out.append(esc)
                skip[i + 1] = True
            else:
                out.append("\\\\")
            continue
        if ch == "*" and i + 1 < plen and pattern[i + 1] == "*":
            if i + 2 < plen and pattern[i + 2] == "/":
                # `**/` matches zero or more directories.
                out.append("(.*/)?")
                skip[i + 1] = True
                skip[i + 2] = True
            else:
                out.append(".*")
                skip[i + 1] = True
            continue
        if ch == "[":
            j = i + 1
            class_parts = []
            if j < plen and pattern[j] == "!":
                class_parts.append("^")
                j += 1
            elif j < plen and pattern[j] == "^":
                class_parts.append("\\^")
                j += 1
            if j < plen and pattern[j] == "]":
                class_parts.append("\\]")
                j += 1

            closed_at = -1
            for k in range(j, plen):
                class_ch = pattern[k]
                if class_ch == "]":
                    closed_at = k
                    break
                if class_ch == "\\":
                    class_parts.append("\\\\")
                elif class_ch == "^":
                    class_parts.append("\\^")
                elif class_ch == "[":
                    class_parts.append("\\[")
                else:
                    class_parts.append(class_ch)

            if closed_at >= 0:
                out.append("[" + "".join(class_parts) + "]")
                for k in range(i + 1, closed_at + 1):
                    skip[k] = True
                continue
            out.append("\\[")
            continue
        if ch == "*":
            out.append("[^/]*")
        elif ch == "?":
            out.append("[^/]")
        elif ch in [".", "+", "(", ")", "{", "}", "^", "$", "|", "\\", "]"]:
            out.append("\\" + ch)
        else:
            out.append(ch)
    return "".join(out)

def _compile_codeowners_regex_for_tests(pattern):
    anchored = pattern.startswith("/")
    dir_only = pattern.endswith("/")
    if anchored:
        pattern = pattern[1:]
    if dir_only:
        pattern = pattern[:-1]
    if not pattern:
        return ""

    has_slash = "/" in pattern
    body = _codeowners_glob_to_regex_for_tests(pattern)
    prefix = "^" if (anchored or has_slash) else "(^|.*/)"
    suffix = "/.*$" if dir_only else "($|/.*)"
    return prefix + body + suffix

def _build_codeowners_lookup_order_for_tests(context_workspace, workspace_root, script_dir):
    candidates = []
    if context_workspace:
        candidates.extend([
            context_workspace + "/CODEOWNERS",
            context_workspace + "/.github/CODEOWNERS",
            context_workspace + "/.gitlab/CODEOWNERS",
            context_workspace + "/docs/CODEOWNERS",
            context_workspace + "/.docs/CODEOWNERS",
        ])
    if workspace_root:
        candidates.extend([
            workspace_root + "/CODEOWNERS",
            workspace_root + "/.github/CODEOWNERS",
            workspace_root + "/.gitlab/CODEOWNERS",
            workspace_root + "/docs/CODEOWNERS",
            workspace_root + "/.docs/CODEOWNERS",
        ])
    candidates.append("./CODEOWNERS")
    candidates.append((script_dir + "/CODEOWNERS") if script_dir else "CODEOWNERS")
    return candidates

glob_to_regex_for_tests = _codeowners_glob_to_regex_for_tests
compile_codeowners_regex_for_tests = _compile_codeowners_regex_for_tests
build_codeowners_lookup_order_for_tests = _build_codeowners_lookup_order_for_tests

def _uploader_impl(ctx):
    quiescent_sec = ctx.attr.quiescent_sec
    max_wait_sec = ctx.attr.max_wait_sec
    fail_on_error = ctx.attr.fail_on_error
    debug = ctx.attr.debug
    keep_payloads = ctx.attr.keep_payloads
    filter_prefix = ctx.attr.filter_prefix
    gzip_payloads = ctx.attr.gzip_payloads

    # Find context.json in data files (supports any repo alias)
    context_json_rloc = ""
    context_json_path = ""
    for f in ctx.files.data:
        if f.basename == "context.json":
            context_json_rloc = f.short_path
            context_json_path = f.path
            break
    schema_json_rloc = ctx.file._schema.short_path if ctx.file._schema else ""
    schema_json_path = ctx.file._schema.path if ctx.file._schema else ""
    schema_validator_rloc = ctx.file._schema_validator.short_path if ctx.file._schema_validator else ""
    schema_validator_path = ctx.file._schema_validator.path if ctx.file._schema_validator else ""

    # High-level debug of rule inputs
    log_info("Generating uploader scripts (Option 2: TEST_UNDECLARED_OUTPUTS_DIR)")
    log_debug(
        debug,
        "Attributes → quiescent_sec=%s, max_wait_sec=%s, fail_on_error=%s, debug=%s, keep_payloads=%s, filter_prefix=%s, gzip_payloads=%s" %
        (
            quiescent_sec,
            max_wait_sec,
            fail_on_error,
            debug,
            keep_payloads,
            filter_prefix,
            gzip_payloads,
        ),
    )
    if context_json_rloc:
        log_debug(debug, "context.json found at: %s" % context_json_rloc)
        log_debug(debug, "context.json artifact path: %s" % context_json_path)
    else:
        log_debug(debug, "context.json not found in data files; enrichment disabled")
    if schema_json_rloc:
        log_debug(debug, "schema found at: %s" % schema_json_rloc)
        log_debug(debug, "schema artifact path: %s" % schema_json_path)
    else:
        log_debug(debug, "schema not found in data files; validation disabled")
    if schema_validator_rloc:
        log_debug(debug, "schema validator found at: %s" % schema_validator_rloc)
        log_debug(debug, "schema validator artifact path: %s" % schema_validator_path)
    else:
        log_debug(debug, "schema validator not found in data files; validation disabled")
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
DEBUG_BOOTSTRAP=$(echo "${{DD_TOPT_DEBUG:-0}}" | tr '[:upper:]' '[:lower:]')
dbg() {{
    local dbg_val="${{DEBUG:-$DEBUG_BOOTSTRAP}}"
    dbg_val=$(echo "$dbg_val" | tr '[:upper:]' '[:lower:]')
    if [[ "$dbg_val" == "1" || "$dbg_val" == "true" || "$dbg_val" == "yes" ]]; then
        echo "[dd-uploader][dbg] $1" >&2
    fi
}}
dbg "startup runfiles env: RUNFILES_DIR='${{RUNFILES_DIR:-<unset>}}' RUNFILES_MANIFEST_FILE='${{RUNFILES_MANIFEST_FILE:-<unset>}}' script='$0'"

# Resolve runfile path for context.json lookup
# Since `bazel run` does NOT set TEST_SRCDIR, we use RUNFILES_DIR or RUNFILES_MANIFEST_FILE
resolve_runfile() {{
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
    local manifest_file="${{RUNFILES_MANIFEST_FILE:-}}"
    dbg "resolve_runfile: input='$input_rloc' normalized='$rloc' candidates='${{candidates[*]}}'"
    if [[ -n "${{RUNFILES_DIR:-}}" ]]; then
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
    for cand in "${{candidates[@]}}"; do
        dbg "resolve_runfile: trying candidate '$cand'"
        # Try RUNFILES_DIR first (Unix default)
        if [[ -n "${{RUNFILES_DIR:-}}" && -f "$RUNFILES_DIR/$cand" ]]; then
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
            # Use awk + substr() for regex-free extraction, so candidate labels
            # containing regex metacharacters are treated as plain text.
            # We also strip a UTF-8 BOM from the first manifest key for parity
            # with PowerShell and editors/tools that emit BOM-prefixed files.
            path=$(awk -v key="$cand" '
                BEGIN {{ bom = sprintf("%c%c%c", 239, 187, 191) }}
                {{
                    k = $1
                    if (NR == 1 && index(k, bom) == 1) {{
                        k = substr(k, 4)
                    }}
                    if (k == key) {{
                        print substr($0, length($1) + 2)
                        exit
                    }}
                }}
            ' "$manifest_file")
            if [[ -n "$path" ]]; then
                if [[ -f "$path" ]]; then
                    dbg "resolve_runfile: hit manifest exact key '$cand' -> '$path'"
                    echo "$path"
                    return
                fi
                dbg "resolve_runfile: manifest exact key '$cand' -> '$path' (not a file)"
            fi
            # Fallback: some manifests prefix keys with repo names (for example "<repo>/path/to/file").
            # Match entries whose key ends with "/<candidate>" or "\\<candidate>".
            path=$(awk -v key="$cand" '
                BEGIN {{ bom = sprintf("%c%c%c", 239, 187, 191) }}
                {{
                    k = $1
                    if (NR == 1 && index(k, bom) == 1) {{
                        k = substr(k, 4)
                    }}
                    if (length(k) > length(key) && substr(k, length(k) - length(key) + 1) == key) {{
                        sep = substr(k, length(k) - length(key), 1)
                        if (sep == "/" || sep == "\\\\") {{
                            print substr($0, length($1) + 2)
                            exit
                        }}
                    }}
                }}
            ' "$manifest_file")
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
}}

# Resolve execroot-relative artifact path (File.path).
# Bazel commonly provides paths like "external/<repo>/..." relative to execroot.
resolve_artifact_path() {{
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
}}

# Resolve context.json path (used by upload functions for payload enrichment)
# Path is determined at rule implementation time from data files
CONTEXT_JSON_RLOC="{context_json_rloc}"
CONTEXT_JSON_PATH="{context_json_path}"
dbg "context.json resolution inputs: path='$CONTEXT_JSON_PATH' rloc='$CONTEXT_JSON_RLOC'"
CONTEXT_JSON=$(resolve_artifact_path "$CONTEXT_JSON_PATH")
if [[ -n "$CONTEXT_JSON" ]]; then
    dbg "context.json resolved via direct path: '$CONTEXT_JSON'"
elif [[ -n "$CONTEXT_JSON_RLOC" ]]; then
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
SCHEMA_JSON_RLOC="{schema_json_rloc}"
SCHEMA_JSON_PATH="{schema_json_path}"
SCHEMA_VALIDATOR_RLOC="{schema_validator_rloc}"
SCHEMA_VALIDATOR_PATH="{schema_validator_path}"
dbg "schema resolution inputs: schema_path='$SCHEMA_JSON_PATH' schema_rloc='$SCHEMA_JSON_RLOC' validator_path='$SCHEMA_VALIDATOR_PATH' validator_rloc='$SCHEMA_VALIDATOR_RLOC'"
SCHEMA_JSON=$(resolve_artifact_path "$SCHEMA_JSON_PATH")
if [[ -n "$SCHEMA_JSON" ]]; then
    dbg "schema resolved via direct path: '$SCHEMA_JSON'"
elif [[ -n "$SCHEMA_JSON_RLOC" ]]; then
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

# Generate UUID (best effort). Uses uuidgen, python3, or /dev/urandom.
generate_uuid() {{
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
        hex=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
        echo "${{hex:0:8}}-${{hex:8:4}}-${{hex:12:4}}-${{hex:16:4}}-${{hex:20:12}}"
        return
    fi
    echo "00000000-0000-0000-0000-000000000000"
}}

# Compute FNV-1a 32-bit hex fingerprint (non-cryptographic, for parity checks only)
fnv1a_32() {{
    local input="$1"
    if [[ -z "$input" ]]; then
        echo ""
        return
    fi
    local alphabet='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_:/.+'
    local hash=2166136261
    local input_len="${{#input}}"
    local alpha_len="${{#alphabet}}"
    local i j idx found ch ach
    for ((i = 0; i < input_len; i++)); do
        ch="${{input:i:1}}"
        idx=0
        found=0
        for ((j = 0; j < alpha_len; j++)); do
            ach="${{alphabet:j:1}}"
            if [[ "$ach" == "$ch" ]]; then
                idx=$j
                found=1
                break
            fi
        done
        if (( found == 0 )); then
            idx=0
        fi
        hash=$((hash ^ idx))
        hash=$(( (hash * 16777619) & 0xffffffff ))
    done
    printf '%08x' "$hash"
}}

# Rule attributes (can be overridden via environment variables)
QUIESCENT_SEC=${{DD_TOPT_QUIESCENT_SEC:-{quiescent_sec}}}
MAX_WAIT_SEC=${{DD_TOPT_MAX_WAIT_SEC:-{max_wait_sec}}}
FAIL_ON_ERROR=$(normalize_bool "{fail_on_error}")
KEEP_PAYLOADS=$(normalize_bool "${{DD_TOPT_KEEP_PAYLOADS:-{keep_payloads}}}")
FILTER_PREFIX=$(normalize_bool "${{DD_TOPT_FILTER_PREFIX:-{filter_prefix}}}")
DEBUG=$(normalize_bool "${{DD_TOPT_DEBUG:-{debug}}}")
GZIP_PAYLOADS=$(normalize_bool "${{DD_TOPT_GZIP:-{gzip_payloads}}}")
RULES_VERSION="{rules_version}"
RUNTIME_ID=$(generate_uuid)

# Validate numeric environment variables
validate_numeric "QUIESCENT_SEC" "$QUIESCENT_SEC"
validate_numeric "MAX_WAIT_SEC" "$MAX_WAIT_SEC"
if [[ -n "${{DD_TOPT_MAX_DEPTH:-}}" ]]; then
    validate_numeric "DD_TOPT_MAX_DEPTH" "$DD_TOPT_MAX_DEPTH"
fi
if [[ "$GZIP_PAYLOADS" == "1" ]]; then
    if ! command -v gzip >/dev/null 2>&1; then
        log "warning: DD_TOPT_GZIP=1 but gzip not found; disabling gzip"
        GZIP_PAYLOADS=0
    fi
fi
dbg "gzip enabled: $GZIP_PAYLOADS"

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
LOCK_ACQUIRED=0

lock_dir_age_seconds() {{
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
}}

acquire_lock() {{
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
    # Only the lock owner may remove LOCK_DIR. This avoids deleting an active
    # uploader's lock when the current process failed to acquire it.
    if [[ "$LOCK_ACQUIRED" == "1" ]]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
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
        if (( MAX_WAIT_SEC == 0 )); then
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

HEADER_LANG_DEFAULT="bazel-starlark"
HEADER_LANG_VERSION_DEFAULT="n/a"
HEADER_LANG_INTERPRETER_DEFAULT="bazel-run"
HEADER_TRACER_VERSION_DEFAULT="{uploader_version}"
if (( AGENTLESS == 1 )); then
  if [[ -z "${{DD_API_KEY:-}}" ]]; then
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
redact_header() {{
  local h="$1"
  local name="${{h%%:*}}"
  if [[ "$name" == "DD-API-KEY" ]]; then
    local val="${{h#*:}}"
    val="${{val# }}"; val="${{val% }}"; val="${{val%%$'\\r'}}"
    if (( ${{#val}} > 4 )); then
      echo "DD-API-KEY: ****${{val: -4}}"
    else
      echo "DD-API-KEY: $val"
    fi
  else
    echo "$h"
  fi
}}

dbg_headers() {{
  local label="$1"; shift
  local arr=("$@")
  local i=0
  while (( i < ${{#arr[@]}} )); do
    if [[ "${{arr[$i]}}" == "-H" && $((i+1)) -lt ${{#arr[@]}} ]]; then
      dbg "header[$label]: $(redact_header "${{arr[$((i+1))]}}")"
      i=$((i+2))
      continue
    fi
    dbg "header[$label]: ${{arr[$i]}}"
    i=$((i+1))
  done
}}

# Load context.json for enrichment
JQ_AVAILABLE=0
if command -v jq >/dev/null 2>&1; then JQ_AVAILABLE=1; fi
dbg "jq available: $JQ_AVAILABLE"
dbg "context.json: ${{CONTEXT_JSON:-<none>}}"

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

decode_percent_path() {{
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
  decoded=$(printf '%b' "${{value//%/\\\\x}}" 2>/dev/null || true)
  if [[ -n "$decoded" ]]; then
    echo "$decoded"
  else
    echo "$value"
  fi
}}

normalize_path_like() {{
  local raw="$1"
  if [[ "$raw" == file://* ]]; then
    raw="${{raw#file://}}"
  fi
  raw=$(decode_percent_path "$raw")
  # Decode can re-introduce backslashes (for example %5C on Windows paths).
  # Normalize after decoding so slash-based matching stays consistent.
  raw="${{raw//\\\\//}}"
  # Collapse duplicated separators to improve matching stability.
  while [[ "$raw" == *"//"* ]]; do
    raw=$(echo "$raw" | sed -E 's#/{2,}#/#g')
  done
  while [[ "$raw" == ./* ]]; do
    raw="${{raw#./}}"
  done
  if [[ "$raw" =~ ^/[A-Za-z]:/ ]]; then
    # file:///C:/... style paths become /C:/... after scheme removal.
    # Drop only the leading slash to preserve the drive-qualified path.
    raw="${{raw:1}}"
  fi

  local is_abs=0
  if [[ "$raw" == /* ]]; then
    is_abs=1
    raw="${{raw#/}}"
  fi

  # Canonicalize dot segments. If normalization would escape above root,
  # return failure so caller can skip unsafe/invalid candidates.
  local -a parts=()
  local -a stack=()
  local part idx
  IFS='/' read -r -a parts <<< "$raw"
  for part in "${{parts[@]}}"; do
    case "$part" in
      ""|".")
        continue
        ;;
      "..")
        if (( ${{#stack[@]}} > 0 )); then
          idx=$(( ${{#stack[@]}} - 1 ))
          unset "stack[$idx]"
          stack=("${{stack[@]}}")
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
  if (( ${{#stack[@]}} > 0 )); then
    joined="${{stack[0]}}"
    for ((idx = 1; idx < ${{#stack[@]}}; idx++)); do
      joined="$joined/${{stack[$idx]}}"
    done
  fi

  if (( is_abs == 1 )); then
    echo "/$joined"
  else
    echo "$joined"
  fi
  return 0
}}

add_path_candidate() {{
  local candidate="$1"
  local normalized
  normalized=$(normalize_path_like "$candidate" || true)
  [[ -z "$normalized" ]] && return
  normalized="${{normalized#/}}"
  while [[ "$normalized" == ./* ]]; do
    normalized="${{normalized#./}}"
  done
  [[ -z "$normalized" ]] && return
  # Generated output paths do not map to repository-owned source files.
  [[ "$normalized" == bazel-out/* ]] && return
  local existing
  if (( ${{#CODEOWNERS_SOURCE_CANDIDATES[@]}} > 0 )); then
    for existing in "${{CODEOWNERS_SOURCE_CANDIDATES[@]}}"; do
      [[ "$existing" == "$normalized" ]] && return
    done
  fi
  CODEOWNERS_SOURCE_CANDIDATES+=("$normalized")
}}

strip_workspace_prefix() {{
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
    echo "${{path_norm#"$root_norm/"}}"
  fi
}}

build_source_candidates() {{
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
    add_path_candidate "${{BASH_REMATCH[1]}}"
  fi
  if [[ "$normalized_source" =~ /execroot/[^/]+/(.+)$ ]]; then
    add_path_candidate "${{BASH_REMATCH[1]}}"
  fi
  if [[ "$normalized_source" =~ \\.runfiles/_main/(.+)$ ]]; then
    add_path_candidate "${{BASH_REMATCH[1]}}"
  fi
  if [[ "$normalized_source" =~ \\.runfiles/[^/]+/(.+)$ ]]; then
    add_path_candidate "${{BASH_REMATCH[1]}}"
  fi
  # Keep only repository-relative fallback candidates. Absolute paths that are
  # not under known repo roots can incorrectly inherit broad CODEOWNERS rules.
  if [[ "$normalized_source" != /* && ! "$normalized_source" =~ ^[A-Za-z]:/ ]]; then
    add_path_candidate "$normalized_source"
  elif [[ "$DEBUG" == "1" ]]; then
    dbg "codeowners: skip absolute source fallback candidate '$normalized_source'"
  fi
}}

glob_to_regex() {{
  local pattern="$1"
  local out=""
  local i=0
  local plen="${{#pattern}}"
  local ch nxt j class_ch class_body class_closed
  while (( i < plen )); do
    ch="${{pattern:i:1}}"
    # Backslash escapes the next glob metacharacter literally.
    if [[ "$ch" == "\\\\" ]]; then
      if (( i + 1 < plen )); then
        nxt="${{pattern:i+1:1}}"
        case "$nxt" in
          "."|"+"|"("|")"|"{"|"}"|"^"|"$"|"|"|"["|"]"|"*"|"?"|"\\\\")
            if [[ "$nxt" == "\\\\" ]]; then
              out="$out\\\\\\\\"
            else
              out="$out\\\\$nxt"
            fi
            ;;
          *)
            out="$out$nxt"
            ;;
        esac
        i=$((i + 2))
      else
        out="$out\\\\\\\\"
        i=$((i + 1))
      fi
      continue
    fi
    if [[ "$ch" == "*" ]] && (( i + 1 < plen )); then
      nxt="${{pattern:i+1:1}}"
      if [[ "$nxt" == "*" ]]; then
        if (( i + 2 < plen )) && [[ "${{pattern:i+2:1}}" == "/" ]]; then
          # CODEOWNERS follows gitignore-style globbing: **/ matches zero or more directories.
          out="$out(.*/)?"
          i=$((i + 3))
        else
          out="$out.*"
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
      if (( j < plen )) && [[ "${{pattern:j:1}}" == "!" ]]; then
        class_body="^"
        j=$((j + 1))
      elif (( j < plen )) && [[ "${{pattern:j:1}}" == "^" ]]; then
        class_body="\\\\^"
        j=$((j + 1))
      fi
      if (( j < plen )) && [[ "${{pattern:j:1}}" == "]" ]]; then
        class_body="$class_body\\\\]"
        j=$((j + 1))
      fi
      while (( j < plen )); do
        class_ch="${{pattern:j:1}}"
        if [[ "$class_ch" == "]" ]]; then
          class_closed=1
          break
        fi
        case "$class_ch" in
          "\\\\")
            class_body="$class_body\\\\\\\\"
            ;;
          "^")
            class_body="$class_body\\\\^"
            ;;
          "[")
            class_body="$class_body\\\\["
            ;;
          *)
            class_body="$class_body$class_ch"
            ;;
        esac
        j=$((j + 1))
      done
      if (( class_closed == 1 )); then
        out="$out[$class_body]"
        i=$((j + 1))
        continue
      fi
      out="$out\\\\["
      i=$((i + 1))
      continue
    fi
    case "$ch" in
      "*")
        out="$out[^/]*"
        ;;
      "?")
        out="$out[^/]"
        ;;
      "."|"+"|"("|")"|"{"|"}"|"^"|"$"|"|"|"\\\\")
        out="$out\\\\$ch"
        ;;
      "]")
        out="$out\\\\]"
        ;;
      *)
        out="$out$ch"
        ;;
    esac
    i=$((i + 1))
  done
  echo "$out"
}}

compile_codeowners_regex() {{
  local pattern="$1"
  local anchored=0
  local dir_only=0
  if [[ "$pattern" == /* ]]; then
    anchored=1
    pattern="${{pattern#/}}"
  fi
  if [[ "$pattern" == */ ]]; then
    dir_only=1
    pattern="${{pattern%/}}"
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
}}

parse_codeowners_file() {{
  local file_path="$1"
  local line pattern rest regex
  local -a owner_tokens=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${{line%$'\\r'}}"
    line="${{line#"${{line%%[![:space:]]*}}"}}"
    [[ -z "$line" || "${{line:0:1}}" == "#" ]] && continue
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
      rest=$(printf '%s\n' "$rest" | sed -E 's/[[:space:]]#.*$//')
    fi
    rest="${{rest%"${{rest##*[![:space:]]}}"}}"
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
    if (( ${{#owner_tokens[@]}} == 0 )); then
      CODEOWNERS_RULE_OWNERS+=("")
      CODEOWNERS_RULE_HAS_OWNERS+=("0")
    else
      CODEOWNERS_RULE_OWNERS+=("$rest")
      CODEOWNERS_RULE_HAS_OWNERS+=("1")
    fi
    if [[ "$DEBUG" == "1" ]]; then
      local owners_dbg="<empty>"
      if (( ${{#owner_tokens[@]}} > 0 )); then
        owners_dbg="$rest"
      fi
      dbg "codeowners: parsed rule pattern='$pattern' regex='$regex' owners='$owners_dbg'"
    fi
  done < "$file_path"
}}

is_gitlab_section_header_pattern() {{
  local pattern="$1"
  [[ "$pattern" =~ ^\\[[^][]+\\]$ ]] || return 1
  local inner="${{pattern:1:${{#pattern}}-2}}"
  # GitLab section headers can include whitespace (for example [Core Team]).
  if [[ "$inner" == *[[:space:]]* ]]; then
    return 0
  fi
  # Heuristic to avoid class-only glob false positives:
  # keep range-like and short bracket classes (for example [xy], [A-Z]).
  if [[ "$inner" == *"-"* || "$inner" == *"!"* || "$inner" == *"^"* || "$inner" == *"\\\\"* ]]; then
    return 1
  fi
  if (( ${{#inner}} <= 2 )); then
    return 1
  fi
  # Preserve plain lowercase/digit class sets such as [abc] and [a1b2].
  if [[ "$inner" =~ ^[a-z0-9]+$ ]]; then
    return 1
  fi
  return 0
}}

is_gitlab_section_header_line() {{
  local line="$1"
  if [[ "$line" =~ ^(\\[[^][]+\\])([[:space:]]+.*)?$ ]]; then
    is_gitlab_section_header_pattern "${{BASH_REMATCH[1]}}"
    return $?
  fi
  return 1
}}

codeowners_regex_is_valid() {{
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
}}

split_codeowners_pattern_and_owners() {{
  local line="$1"
  local pattern=""
  local rest=""
  local i ch escaped=0
  local line_len="${{#line}}"
  for ((i = 0; i < line_len; i++)); do
    ch="${{line:i:1}}"
    if (( escaped == 1 )); then
      pattern="$pattern$ch"
      escaped=0
      continue
    fi
    if [[ "$ch" == "\\\\" ]]; then
      pattern="$pattern$ch"
      escaped=1
      continue
    fi
    # Split on the first unescaped whitespace character.
    # We intentionally use a character-class check (instead of only " " and
    # tab) to match CODEOWNERS behavior for any ASCII whitespace separator.
    if [[ "$ch" =~ [[:space:]] ]]; then
      rest="${{line:i}}"
      rest="${{rest#"${{rest%%[![:space:]]*}}"}}"
      CODEOWNERS_SPLIT_PATTERN="$pattern"
      CODEOWNERS_SPLIT_OWNERS_RAW="$rest"
      return 0
    fi
    pattern="$pattern$ch"
  done
  CODEOWNERS_SPLIT_PATTERN="$pattern"
  CODEOWNERS_SPLIT_OWNERS_RAW=""
  return 0
}}

init_codeowners() {{
  (( CODEOWNERS_INITIALIZED == 1 )) && return
  CODEOWNERS_INITIALIZED=1
  if [[ -n "${{BUILD_WORKSPACE_DIRECTORY:-}}" ]]; then
    CODEOWNERS_WORKSPACE_ROOT="$BUILD_WORKSPACE_DIRECTORY"
  elif [[ -n "${{TESTLOGS_DIR:-}}" && "$TESTLOGS_DIR" == */bazel-testlogs* ]]; then
    CODEOWNERS_WORKSPACE_ROOT="${{TESTLOGS_DIR%%/bazel-testlogs*}}"
  else
    CODEOWNERS_WORKSPACE_ROOT="$(pwd)"
  fi
  [[ -z "$CODEOWNERS_WORKSPACE_ROOT" ]] && CODEOWNERS_WORKSPACE_ROOT="$(pwd)"
  CODEOWNERS_CONTEXT_WORKSPACE=""
  if (( JQ_AVAILABLE == 1 )) && [[ -n "$CONTEXT_JSON" && -f "$CONTEXT_JSON" ]]; then
    CODEOWNERS_CONTEXT_WORKSPACE=$(jq -r '."ci.workspace_path" // empty' "$CONTEXT_JSON" 2>/dev/null || true)
  fi

  local script_dir
  script_dir=$(cd "$(dirname "$0")" && pwd -P)
  local -a candidates=()
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
  for candidate in "${{candidates[@]}}"; do
    [[ -z "$candidate" ]] && continue
    if [[ -f "$candidate" && -r "$candidate" ]]; then
      CODEOWNERS_FILE="$candidate"
      break
    fi
  done

  if [[ -z "$CODEOWNERS_FILE" ]]; then
    dbg "codeowners: no CODEOWNERS file found (workspace='$CODEOWNERS_WORKSPACE_ROOT')"
    return
  fi

  parse_codeowners_file "$CODEOWNERS_FILE"
  if (( ${{#CODEOWNERS_RULE_REGEX[@]}} > 0 )); then
    CODEOWNERS_ENABLED=1
    dbg "codeowners: using '$CODEOWNERS_FILE' with ${{#CODEOWNERS_RULE_REGEX[@]}} rule(s)"
  else
    dbg "codeowners: file '$CODEOWNERS_FILE' had no usable rules"
  fi
}}

dedupe_owners() {{
  local owners_line="$1"
  local -a in_tokens=()
  local -a out_tokens=()
  local token existing seen
  read -r -a in_tokens <<< "$owners_line"
  for token in "${{in_tokens[@]}}"; do
    [[ -z "$token" ]] && continue
    seen=0
    if (( ${{#out_tokens[@]}} > 0 )); then
      for existing in "${{out_tokens[@]}}"; do
        if [[ "$existing" == "$token" ]]; then
          seen=1
          break
        fi
      done
    fi
    (( seen == 0 )) && out_tokens+=("$token")
  done
  if (( ${{#out_tokens[@]}} > 0 )); then
    printf '%s\n' "${{out_tokens[@]}}"
  fi
}}

owners_line_to_json() {{
  local owners_line="$1"
  local deduped
  deduped=$(dedupe_owners "$owners_line" | jq -R . | jq -s -c '.' 2>/dev/null || true)
  if [[ "$deduped" == "[]" ]]; then
    echo ""
  else
    echo "$deduped"
  fi
}}

match_codeowners_owners_line() {{
  local candidate="$1"
  local idx regex owners_line rule_has_owners matched="$CODEOWNERS_MATCH_NONE"
  # Last matching CODEOWNERS rule wins.
  for ((idx = 0; idx < ${{#CODEOWNERS_RULE_REGEX[@]}}; idx++)); do
    regex="${{CODEOWNERS_RULE_REGEX[$idx]}}"
    owners_line="${{CODEOWNERS_RULE_OWNERS[$idx]}}"
    rule_has_owners="${{CODEOWNERS_RULE_HAS_OWNERS[$idx]}}"
    if [[ "$candidate" =~ $regex ]]; then
      if [[ "$rule_has_owners" == "1" ]]; then
        matched="$owners_line"
      else
        matched="$CODEOWNERS_MATCH_EMPTY"
      fi
    fi
  done
  echo "$matched"
}}

resolve_codeowners_json_for_source() {{
  local source_path="$1"
  build_source_candidates "$source_path"
  local candidate owners_line owners_json
  # Candidate order matters: prefer repo-relative derivations before broader
  # fallbacks so ownership reflects the most likely source path.
  for candidate in "${{CODEOWNERS_SOURCE_CANDIDATES[@]}}"; do
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
}}

inject_codeowners_tags() {{
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
}}

# Build common Datadog headers, optionally deriving values from payload metadata["*"].
build_common_headers() {{
  local payload_file="${{1:-}}"
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
      IFS=$'\t' read -r meta_lang meta_tracer meta_lang_version meta_lang_interpreter <<< "$meta_values"
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
  if (( AGENTLESS == 1 )); then
    COMMON_HDRS+=( -H "DD-API-KEY: $DD_API_KEY" )
  fi
}}

# Optional check: verify fetch-time API key fingerprint matches uploader API key.
API_KEY_FINGERPRINT=""
if (( JQ_AVAILABLE == 1 )) && [[ -n "$CONTEXT_JSON" && -f "$CONTEXT_JSON" ]]; then
  API_KEY_FINGERPRINT=$(jq -r '."topt.api_key_fingerprint" // empty' "$CONTEXT_JSON" 2>/dev/null || true)
fi
if [[ -n "$API_KEY_FINGERPRINT" ]]; then
  if (( AGENTLESS == 1 )); then
    local_fp=$(fnv1a_32 "$DD_API_KEY")
    if [[ -n "$local_fp" && "$local_fp" != "$API_KEY_FINGERPRINT" ]]; then
      log "warning: DD_API_KEY mismatch between fetch and uploader"
    else
      dbg "DD_API_KEY fingerprint match"
    fi
  else
    log "warning: DD_API_KEY fingerprint present but uploader running in EVP mode; check skipped"
  fi
elif [[ -n "$CONTEXT_JSON" && -f "$CONTEXT_JSON" && "$JQ_AVAILABLE" != "1" ]]; then
  dbg "api key fingerprint check skipped: jq not available"
fi

enrich_with_context() {{
  local infile="$1"; local tmpfile="$2"
  dbg "enrich_with_context: infile='$infile' outfile='$tmpfile' ctx='${{CONTEXT_JSON:-<none>}}' jq=$JQ_AVAILABLE"
  if (( JQ_AVAILABLE == 0 )); then
    cp "$infile" "$tmpfile"
    return 0
  fi
  local ctx_file="$CONTEXT_JSON"
  local cleanup_ctx=""
  if [[ -z "$ctx_file" || ! -f "$ctx_file" ]]; then
    ctx_file="$(mktemp "$TMP_PAYLOAD_DIR/context.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$ctx_file" ]]; then
      cp "$infile" "$tmpfile"
      return 0
    fi
    echo '{}' > "$ctx_file"
    cleanup_ctx=1
  fi
  jq --slurpfile ctx "$ctx_file" \
    --arg runtime_id "$RUNTIME_ID" \
    --arg rules_version "$RULES_VERSION" \
    --arg language_fallback "bazel" '
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
  inject_codeowners_tags "$tmpfile"
  if [[ -n "$cleanup_ctx" ]]; then
    rm -f "$ctx_file" 2>/dev/null || true
  fi
}}

# Emit basic startTime statistics (ms) for debugging when jq is available.
log_start_time_stats() {{
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
  read min max < <(echo "$times" | awk 'NR==1{{min=$1;max=$1}} {{if($1<min)min=$1;if($1>max)max=$1}} END{{print min,max}}')
  local now_ms
  now_ms=$(( $(date +%s) * 1000 ))
  dbg "startTime/ms range for $file: min=$min max=$max now=$now_ms"
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

validate_payload() {{
    local file="$1"
    if [[ -z "$SCHEMA_JSON" || ! -f "$SCHEMA_JSON" ]]; then
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
        log "warning: schema validation failed for payload: $file"
    fi
    return 0
}}

# Track upload failures globally
UPLOAD_FAILURES=0

upload_single_test() {{
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
      http=$(curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \\
        -X POST "${{TEST_URL}}" "${{COMMON_HDRS[@]}}" "${{ce_hdr[@]+${{ce_hdr[@]}}}}" -H "Content-Type: application/json" --data-binary @"${{payload_file}}" -o "$resp" -w "%{{http_code}}")
    else
      http=$(curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \\
        -X POST "${{TEST_URL}}" "${{COMMON_HDRS[@]}}" "${{TEST_EVP[@]}}" "${{ce_hdr[@]+${{ce_hdr[@]}}}}" -H "Content-Type: application/json" --data-binary @"${{payload_file}}" -o "$resp" -w "%{{http_code}}")
    fi
    rc=$?
    http="${{http:-000}}"
    if [[ "$DEBUG" == "1" || $rc -ne 0 || "$http" -lt 200 || "$http" -ge 300 ]]; then
        dbg "upload_single_test: HTTP $http (rc=$rc)"
        if [[ -s "$resp" ]]; then
            dbg "upload_single_test response: $(head -c 2000 "$resp")"
        fi
    fi
    rm -f "$resp" "$body" "$gz" 2>/dev/null || true
    if [[ $rc -ne 0 || "$http" -lt 200 || "$http" -ge 300 ]]; then
        return 1
    fi
    return 0
}}

upload_single_coverage() {{
    local file="$1"
    # Create event.json for multipart
    local eventjson resp http rc
    # Use a temp file for multipart metadata to avoid leaking into runfiles.
    eventjson="$(mktemp "$TMP_PAYLOAD_DIR/coverage_event.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$eventjson" ]]; then
        dbg "upload_single_coverage: failed to create temp file"
        return 1
    fi
    echo '{{"dummy":true}}' > "$eventjson"
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
      http=$(curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \\
        -X POST "${{COV_URL}}" "${{COMMON_HDRS[@]}}" \\
        -F "event=@${{eventjson}};type=application/json;filename=fileevent.json" \\
        -F "coveragex=@${{file}};type=application/json;filename=filecoveragex.json" -o "$resp" -w "%{{http_code}}")
    else
      http=$(curl -f -sS --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 --retry-connrefused --retry-all-errors \\
        -X POST "${{COV_URL}}" "${{COMMON_HDRS[@]}}" "${{COV_EVP[@]}}" \\
        -F "event=@${{eventjson}};type=application/json;filename=fileevent.json" \\
        -F "coveragex=@${{file}};type=application/json;filename=filecoveragex.json" -o "$resp" -w "%{{http_code}}")
    fi
    rc=$?
    http="${{http:-000}}"
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
            "gzip_payloads": _bool_to_str(gzip_payloads),
            "uploader_version": UPLOADER_VERSION,
            "context_json_rloc": context_json_rloc,
            "context_json_path": context_json_path,
            "schema_json_rloc": schema_json_rloc,
            "schema_json_path": schema_json_path,
            "schema_validator_rloc": schema_validator_rloc,
            "schema_validator_path": schema_validator_path,
            "rules_version": RULES_VERSION,
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
    param([string]$InputRloc)

    $Rloc = $InputRloc
    $Rloc = $Rloc.Replace('\', '/')
    # Normalize relative prefixes that can appear in bzlmod runfile paths
    if ($Rloc.StartsWith("./")) {{ $Rloc = $Rloc.Substring(2) }}
    while ($Rloc.StartsWith("../")) {{ $Rloc = $Rloc.Substring(3) }}
    # Defensive guard: runfile labels must remain repository-relative.
    # We reject absolute/drive-qualified and parent-traversal paths so lookups
    # cannot accidentally resolve outside runfiles roots.
    if ([string]::IsNullOrEmpty($Rloc) -or $Rloc.StartsWith("/") -or ($Rloc -match '^[A-Za-z]:/') -or $Rloc -eq ".." -or $Rloc.EndsWith("/..") -or $Rloc.Contains("/../")) {{
        Dbg "Resolve-Runfile rejected suspicious runfile label '$InputRloc' (normalized='$Rloc')"
        return $null
    }}

    $candidates = @($Rloc)
    if ($Rloc.StartsWith("external/")) {{
        $candidates += $Rloc.Substring(9)
    }} else {{
        # Try the external/ prefix when short_path omits it under bzlmod.
        $candidates += "external/$Rloc"
    }}
    if (-not $Rloc.StartsWith("_main/")) {{
        $candidates += "_main/$Rloc"
    }}
    Dbg "Resolve-Runfile input='$InputRloc' normalized='$Rloc' candidates='$($candidates -join ',')'"

    if ($env:RUNFILES_DIR) {{
        $rfExists = Test-Path -LiteralPath $env:RUNFILES_DIR
        Dbg "Resolve-Runfile RUNFILES_DIR='$($env:RUNFILES_DIR)' exists=$rfExists"
    }} else {{
        Dbg "Resolve-Runfile RUNFILES_DIR=<unset>"
    }}

    $manifest = $null
    if ($env:RUNFILES_MANIFEST_FILE) {{
        $mfExists = Test-Path -LiteralPath $env:RUNFILES_MANIFEST_FILE
        Dbg "Resolve-Runfile RUNFILES_MANIFEST_FILE='$($env:RUNFILES_MANIFEST_FILE)' exists=$mfExists"
        if ($mfExists) {{
            $manifest = Get-Content -LiteralPath $env:RUNFILES_MANIFEST_FILE -Encoding UTF8
            Dbg "Resolve-Runfile manifest entries loaded=$($manifest.Count)"
        }}
    }} else {{
        Dbg "Resolve-Runfile RUNFILES_MANIFEST_FILE=<unset>"
    }}

    foreach ($cand in $candidates) {{
        Dbg "Resolve-Runfile trying candidate '$cand'"
        # Try RUNFILES_DIR first
        if ($env:RUNFILES_DIR) {{
            $candidate = Join-Path $env:RUNFILES_DIR $cand
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {{
                Dbg "Resolve-Runfile hit RUNFILES_DIR -> '$candidate'"
                return $candidate
            }}
        }}

        # Try local runfiles directory fallbacks when RUNFILES_DIR is unavailable.
        # Depending on launcher/platform we may see:
        #   - <script>.runfiles
        #   - <script>.bat.runfiles
        #   - legacy $PSScriptRoot.runfiles path
        $scriptBase = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
        $runfilesDirs = @(
            "$PSScriptRoot.runfiles",
            (Join-Path $PSScriptRoot "$scriptBase.runfiles"),
            (Join-Path $PSScriptRoot "$scriptBase.bat.runfiles")
        ) | Where-Object { -not [string]::IsNullOrEmpty($_) }
        foreach ($runfilesDir in $runfilesDirs) {{
            $candidate = Join-Path $runfilesDir $cand
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {{
                Dbg "Resolve-Runfile hit script runfiles -> '$candidate'"
                return $candidate
            }}
        }}

        # Try RUNFILES_MANIFEST_FILE (Windows default)
        if ($manifest) {{
            foreach ($line in $manifest) {{
                $lineNorm = $line
                # Some tools write manifests with UTF-8 BOM; strip it from key.
                if ($lineNorm.Length -gt 0 -and [int][char]$lineNorm[0] -eq 0xFEFF) {{
                    $lineNorm = $lineNorm.Substring(1)
                }}
                if ($lineNorm.Length -gt $cand.Length -and $lineNorm.StartsWith($cand, [System.StringComparison]::Ordinal)) {{
                    $sep = $lineNorm.Substring($cand.Length, 1)
                    if ($sep -ne ' ' -and $sep -ne "`t") {{ continue }}
                    $path = $lineNorm.Substring($cand.Length + 1).TrimStart().TrimEnd()
                    if (Test-Path -LiteralPath $path -PathType Leaf) {{
                        Dbg "Resolve-Runfile hit manifest exact key '$cand' -> '$path'"
                        return $path
                    }}
                    Dbg "Resolve-Runfile manifest exact key '$cand' -> '$path' (not a file)"
                }}
            }}
            # Fallback: some manifests prefix keys with repo names (for example "<repo>/path/to/file").
            # Match entries whose key ends with "/<candidate>" or "\\<candidate>".
            foreach ($line in $manifest) {{
                $lineNorm = $line
                # Same BOM handling for suffix-key fallback.
                if ($lineNorm.Length -gt 0 -and [int][char]$lineNorm[0] -eq 0xFEFF) {{
                    $lineNorm = $lineNorm.Substring(1)
                }}
                $spaceIdx = $lineNorm.IndexOf(' ')
                $tabIdx = $lineNorm.IndexOf("`t")
                if ($spaceIdx -lt 0) {{
                    $i = $tabIdx
                }} elseif ($tabIdx -lt 0) {{
                    $i = $spaceIdx
                }} else {{
                    $i = [Math]::Min($spaceIdx, $tabIdx)
                }}
                if ($i -le 0) {{ continue }}
                $key = $lineNorm.Substring(0, $i)
                if ($key.Length -le $cand.Length) {{ continue }}
                if ($key.EndsWith("/$cand", [System.StringComparison]::Ordinal) -or $key.EndsWith("\\$cand", [System.StringComparison]::Ordinal)) {{
                    $path = $lineNorm.Substring($i + 1).TrimStart().TrimEnd()
                    if (Test-Path -LiteralPath $path -PathType Leaf) {{
                        Dbg "Resolve-Runfile hit manifest suffix key '$cand' -> '$path'"
                        return $path
                    }}
                    Dbg "Resolve-Runfile manifest suffix key '$cand' -> '$path' (not a file)"
                }}
            }}
        }}
    }}

    Dbg "Resolve-Runfile miss for input '$InputRloc'"
    return $null  # Not found
}}

function Resolve-ArtifactPath {{
    param([string]$InputPath)

    if (-not $InputPath) {{ return $null }}
    Dbg "Resolve-ArtifactPath input='$InputPath'"

    if (Test-Path -LiteralPath $InputPath -PathType Leaf) {{
        Dbg "Resolve-ArtifactPath hit direct -> '$InputPath'"
        return $InputPath
    }}

    $execRoot = $null
    try {{
        $execRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\\..\\.."))
    }} catch {{
        $execRoot = $null
    }}
    if ($execRoot) {{
        $candidate = Join-Path $execRoot $InputPath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {{
            Dbg "Resolve-ArtifactPath hit execroot-relative -> '$candidate'"
            return $candidate
        }}
    }}

    Dbg "Resolve-ArtifactPath miss for input '$InputPath'"
    return $null
}}

# Logging functions (defined early so other functions can use them)
# Note: $Debug is set later, so Dbg checks the variable at runtime
$script:DebugMode = $false  # Will be set properly after Normalize-Bool is defined
if ($env:DD_TOPT_DEBUG) {{
    switch ($env:DD_TOPT_DEBUG.ToLower()) {{
        {{ $_ -in '1', 'true', 'yes' }} {{ $script:DebugMode = $true }}
    }}
}}
function Log([string]$msg) {{ Write-Output "[dd-uploader] $msg" }}
function Dbg([string]$msg) {{ if ($script:DebugMode) {{ Write-Host "[dd-uploader][dbg] $msg" }} }}
function Write-Utf8NoBomFile([string]$Path, [string]$Content) {{
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}}
$script:HttpAssemblyReady = $false
function Ensure-HttpClientTypes {{
    if ($script:HttpAssemblyReady) {{ return $true }}
    try {{
        if (-not ("System.Net.Http.HttpClient" -as [type])) {{
            Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        }}
        if (-not ("System.Net.Http.HttpClient" -as [type])) {{
            Dbg "System.Net.Http.HttpClient type unavailable after Add-Type"
            return $false
        }}
        $script:HttpAssemblyReady = $true
        return $true
    }} catch {{
        Dbg "failed to load System.Net.Http assembly: $_"
        return $false
    }}
}}
Dbg "startup runfiles env: RUNFILES_DIR='$(if ($env:RUNFILES_DIR) {{ $env:RUNFILES_DIR }} else {{ '<unset>' }})' RUNFILES_MANIFEST_FILE='$(if ($env:RUNFILES_MANIFEST_FILE) {{ $env:RUNFILES_MANIFEST_FILE }} else {{ '<unset>' }})' PSScriptRoot='$PSScriptRoot'"

function Redact-HeaderValue([string]$name, [string]$value) {{
    if ($name -ne 'DD-API-KEY') {{ return $value }}
    if ([string]::IsNullOrEmpty($value)) {{ return $value }}
    if ($value.Length -gt 4) {{
        return ("****" + $value.Substring($value.Length - 4))
    }}
    return $value
}}

function Dbg-Headers([string]$label, $headers) {{
    if (-not $script:DebugMode) {{ return }}
    foreach ($k in $headers.Keys) {{
        $v = Redact-HeaderValue $k ($headers[$k].ToString())
        Dbg "header[$label]: ${{k}}: $v"
    }}
}}

# Emit basic startTime statistics (ms) for debugging.
function Get-StartTimes($obj, [ref]$acc) {{
    if ($null -eq $obj) {{ return }}
    if ($obj -is [System.Collections.IDictionary]) {{
    if ($obj.Contains("startTime")) {{
        $v = $obj["startTime"]
        if ($v -is [int] -or $v -is [long] -or $v -is [double]) {{
            $acc.Value += [double]$v
        }}
    }} elseif ($obj.Contains("start")) {{
        $v = $obj["start"]
        if ($v -is [int] -or $v -is [long] -or $v -is [double]) {{
            $acc.Value += [double]$v
        }}
    }}
        foreach ($val in $obj.Values) {{ Get-StartTimes $val ([ref]$acc) }}
        return
    }}
    if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {{
        foreach ($item in $obj) {{ Get-StartTimes $item ([ref]$acc) }}
    }}
}}

function Log-StartTimeStats([string]$FilePath) {{
    try {{
        $payload = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $times = @()
        Get-StartTimes $payload ([ref]$times)
        if ($times.Count -eq 0) {{
            Dbg "startTime stats: no startTime fields found in $FilePath"
            return
        }}
        $min = ($times | Measure-Object -Minimum).Minimum
        $max = ($times | Measure-Object -Maximum).Maximum
        $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Dbg "startTime/ms range for ${{FilePath}}: min=$min max=$max now=$nowMs"
    }} catch {{
        Dbg "startTime stats failed for ${{FilePath}}: $_"
    }}
}}

# Resolve context.json path (used by upload functions for payload enrichment)
# Path is determined at rule implementation time from data files
$ContextJsonRloc = "{context_json_rloc}"
$ContextJsonPath = "{context_json_path}"
Dbg "context.json resolution inputs: path='$ContextJsonPath' rloc='$ContextJsonRloc'"
$script:ContextJson = Resolve-ArtifactPath $ContextJsonPath
if ($script:ContextJson) {{
    Dbg "context.json resolved via direct path: '$script:ContextJson'"
}} elseif ($ContextJsonRloc) {{
    $script:ContextJson = Resolve-Runfile $ContextJsonRloc
    if (-not $script:ContextJson) {{
        Log "warning: context.json not found in runfiles; payloads will not be enriched"
    }} else {{
        Dbg "context.json resolved via runfiles: '$script:ContextJson'"
    }}
}} else {{
    $script:ContextJson = $null
    Dbg "context.json not configured in data files; enrichment disabled"
}}

# Resolve schema + validator paths (used for payload validation)
$SchemaJsonRloc = "{schema_json_rloc}"
$SchemaJsonPath = "{schema_json_path}"
Dbg "schema resolution inputs: schema_path='$SchemaJsonPath' schema_rloc='$SchemaJsonRloc'"
$script:SchemaJson = Resolve-ArtifactPath $SchemaJsonPath
if ($script:SchemaJson) {{
    Dbg "schema resolved via direct path: '$script:SchemaJson'"
}} elseif ($SchemaJsonRloc) {{
    $script:SchemaJson = Resolve-Runfile $SchemaJsonRloc
    if (-not $script:SchemaJson) {{
        Log "warning: schema not found in runfiles; validation disabled"
    }} else {{
        Dbg "schema resolved via runfiles: '$script:SchemaJson'"
    }}
}} else {{
    $script:SchemaJson = $null
    Dbg "schema not configured in data files; validation disabled"
}}

$SchemaValidatorRloc = "{schema_validator_rloc}"
$SchemaValidatorPath = "{schema_validator_path}"
Dbg "schema validator resolution inputs: validator_path='$SchemaValidatorPath' validator_rloc='$SchemaValidatorRloc'"
$script:SchemaValidator = Resolve-ArtifactPath $SchemaValidatorPath
if ($script:SchemaValidator) {{
    Dbg "schema validator resolved via direct path: '$script:SchemaValidator'"
}} elseif ($SchemaValidatorRloc) {{
    $script:SchemaValidator = Resolve-Runfile $SchemaValidatorRloc
    if (-not $script:SchemaValidator) {{
        Log "warning: schema validator not found in runfiles; validation disabled"
    }} else {{
        Dbg "schema validator resolved via runfiles: '$script:SchemaValidator'"
    }}
}} else {{
    $script:SchemaValidator = $null
    Dbg "schema validator not configured in data files; validation disabled"
}}

# Parse context.json once (best effort)
$script:ContextObj = $null
if ($script:ContextJson -and (Test-Path -LiteralPath $script:ContextJson)) {{
    try {{
        $script:ContextObj = Get-Content -LiteralPath $script:ContextJson -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }} catch {{
        $script:ContextObj = $null
    }}
}}

# Runtime defaults
$script:RulesVersion = "{rules_version}"
$script:RuntimeId = [guid]::NewGuid().ToString()

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

# Compute FNV-1a 32-bit hex fingerprint (non-cryptographic, for parity checks only)
function Get-Fnv1a32Hex([string]$value) {{
    if ([string]::IsNullOrEmpty($value)) {{ return "" }}
    $alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_:/.+"
    [uint32]$hash = 2166136261
    foreach ($ch in $value.ToCharArray()) {{
        $idx = $alphabet.IndexOf([string]$ch)
        if ($idx -lt 0) {{ $idx = 0 }}
        $hash = $hash -bxor ([uint32]$idx)
        # Keep arithmetic in uint64 and wrap to 32 bits explicitly.
        # This avoids signed-mask behavior differences on PowerShell.
        $hash = [uint32](([uint64]$hash * [uint64]16777619) % [uint64]4294967296)
    }}
    return ("{0:x8}" -f $hash)
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
$Debug = if ($env:DD_TOPT_DEBUG) { Normalize-Bool $env:DD_TOPT_DEBUG } else { Normalize-Bool "{debug}" }
$GzipPayloads = if ($env:DD_TOPT_GZIP) {{ Normalize-Bool $env:DD_TOPT_GZIP }} else {{ Normalize-Bool "{gzip_payloads}" }}

# Now that $Debug is set, update the script-level debug mode for Dbg function
$script:DebugMode = $Debug
$script:GzipPayloads = $GzipPayloads
Dbg "gzip enabled: $GzipPayloads"

# Acquire exclusive lock to prevent concurrent uploaders
# Lock is scoped to workspace to allow parallel uploads in different workspaces
$WorkspacePath = if ($env:BUILD_WORKSPACE_DIRECTORY) {{ $env:BUILD_WORKSPACE_DIRECTORY }} else {{ (Get-Location).Path }}
$WorkspaceHash = [System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($WorkspacePath))).Replace("-","").Substring(0,8)
$LockFile = Join-Path $env:TEMP "dd_upload_payloads_$WorkspaceHash.lock"

function Acquire-Lock {{
    $maxAttempts = 3
    for ($attempt = 0; $attempt -lt $maxAttempts; $attempt++) {{
        try {{
            # FileShare.None provides process-wide mutual exclusion while this
            # handle stays open. If another uploader holds it, Open will throw.
            $script:LockStream = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
            Dbg "acquired lock: $LockFile (workspace hash: $WorkspaceHash)"
            return $true
        }} catch {{
            # If the lock were truly stale (unheld), OpenOrCreate with FileShare.None
            # would succeed. In the catch path, prefer bounded retries over deleting
            # lock files, which can race with another active uploader.
            Dbg "lock acquisition attempt $($attempt + 1)/$maxAttempts failed: $_"
            Start-Sleep -Seconds 1
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
    # Release lock handle first, then best-effort remove lock file and temp dir.
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
        if ($MaxWaitSec -eq 0) {{
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

$script:HeaderLangDefault = 'bazel-starlark'
$script:HeaderLangVersionDefault = 'n/a'
$script:HeaderLangInterpreterDefault = 'bazel-run'
$script:HeaderTracerVersionDefault = '{uploader_version}'
if ($Agentless) {{
  if ([string]::IsNullOrEmpty($env:DD_API_KEY)) {{
    Log "error: DD_API_KEY required for agentless uploads"
    Log "hint: pass credentials via environment: `$env:DD_API_KEY=... `$env:DD_SITE=... bazel run //:dd_upload_payloads"
    Release-Lock
    exit 2  # Configuration error
  }}
}} else {{
  $TestEvp = @{{ 'X-Datadog-EVP-Subdomain' = 'citestcycle-intake' }}
  $CovEvp  = @{{ 'X-Datadog-EVP-Subdomain' = 'citestcov-intake' }}
}}
Dbg "headers prepared (agentless=$Agentless; test headers can be derived from metadata)"

Dbg "context.json: $(if ([string]::IsNullOrEmpty($script:ContextJson)) {{ '<none>' }} else {{ $script:ContextJson }})"

# Optional check: verify fetch-time API key fingerprint matches uploader API key.
$ContextFingerprint = $null
if ($script:ContextJson -and (Test-Path -LiteralPath $script:ContextJson)) {{
  try {{
    $ctxForCheck = Get-Content -LiteralPath $script:ContextJson -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $ContextFingerprint = $ctxForCheck.'topt.api_key_fingerprint'
  }} catch {{
    $ContextFingerprint = $null
  }}
}}
if ($ContextFingerprint) {{
  if ($Agentless) {{
    $LocalFp = Get-Fnv1a32Hex $env:DD_API_KEY
    if ($LocalFp -and ($LocalFp -ne $ContextFingerprint)) {{
      Log "warning: DD_API_KEY mismatch between fetch and uploader"
    }} else {{
      Dbg "DD_API_KEY fingerprint match"
    }}
  }} else {{
    Log "warning: DD_API_KEY fingerprint present but uploader running in EVP mode; check skipped"
  }}
}}

function Get-CommonHeaders([string]$PayloadPath) {{
  $lang = $script:HeaderLangDefault
  $langVersion = $script:HeaderLangVersionDefault
  $langInterpreter = $script:HeaderLangInterpreterDefault
  $tracerVersion = $script:HeaderTracerVersionDefault

  if (-not [string]::IsNullOrEmpty($PayloadPath) -and (Test-Path -LiteralPath $PayloadPath)) {{
    try {{
      $payloadObj = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $metaStar = $null
      if ($payloadObj.metadata) {{ $metaStar = $payloadObj.metadata.'*' }}
      if ($metaStar) {{
        $metaLang = $metaStar.language
        if (-not [string]::IsNullOrEmpty($metaLang)) {{ $lang = [string]$metaLang }}

        $metaTracerVersion = $metaStar.library_version
        if (-not [string]::IsNullOrEmpty($metaTracerVersion)) {{ $tracerVersion = [string]$metaTracerVersion }}

        $metaLangVersion = $metaStar.language_version
        if ([string]::IsNullOrEmpty($metaLangVersion)) {{ $metaLangVersion = $metaStar.runtime_version }}
        if (-not [string]::IsNullOrEmpty($metaLangVersion)) {{ $langVersion = [string]$metaLangVersion }}

        $metaLangInterpreter = $metaStar.language_interpreter
        if ([string]::IsNullOrEmpty($metaLangInterpreter)) {{ $metaLangInterpreter = $metaStar.runtime_name }}
        if (-not [string]::IsNullOrEmpty($metaLangInterpreter)) {{ $langInterpreter = [string]$metaLangInterpreter }}
      }}
    }} catch {{
      Dbg "Get-CommonHeaders: failed to parse payload metadata from '$PayloadPath' ($_)"
    }}
  }}

  $headers = @{{
    'Datadog-Meta-Lang' = $lang
    'Datadog-Meta-Lang-Version' = $langVersion
    'Datadog-Meta-Lang-Interpreter' = $langInterpreter
    'Datadog-Meta-Tracer-Version' = $tracerVersion
    'Accept' = 'application/json'
  }}
  if ($Agentless) {{ $headers['DD-API-KEY'] = $env:DD_API_KEY }}
  return $headers
}}

function Convert-ToMutableObject($Value) {{
  if ($null -eq $Value) {{ return $null }}
  if ($Value -is [System.Collections.IDictionary]) {{
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($k in $Value.Keys) {{
      $map[[string]$k] = Convert-ToMutableObject $Value[$k]
    }}
    return $map
  }}
  if ($Value -is [PSCustomObject]) {{
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    foreach ($p in $Value.PSObject.Properties) {{
      $map[$p.Name] = Convert-ToMutableObject $p.Value
    }}
    return $map
  }}
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {{
    $arr = @()
    foreach ($item in $Value) {{
      $arr += ,(Convert-ToMutableObject $item)
    }}
    return $arr
  }}
  return $Value
}}

function Ensure-Hashtable($Value) {{
  $converted = Convert-ToMutableObject $Value
  if ($converted -is [System.Collections.IDictionary]) {{
    return $converted
  }}
  return [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
}}

function Get-MapValue($MapObj, [string]$Key) {{
  if ($null -eq $MapObj -or [string]::IsNullOrEmpty($Key)) {{ return $null }}
  if ($MapObj -is [System.Collections.IDictionary]) {{
    if ($MapObj.Contains($Key)) {{ return $MapObj[$Key] }}
    return $null
  }}
  $prop = $MapObj.PSObject.Properties[$Key]
  if ($prop) {{ return $prop.Value }}
  return $null
}}

$script:CodeOwnersInitialized = $false
$script:CodeOwnersEnabled = $false
$script:CodeOwnersPath = $null
$script:CodeOwnersRules = @()
$script:CodeOwnersStats = @{{
  scanned = 0
  enriched = 0
  skipped_existing = 0
  skipped_missing_source = 0
  skipped_unmatched = 0
  skipped_errors = 0
}}

function Normalize-PathLike([string]$PathValue) {{
  if ([string]::IsNullOrEmpty($PathValue)) {{ return $null }}
  $v = $PathValue
  if ($v.StartsWith("file://")) {{ $v = $v.Substring(7) }}
  if ($v.Contains('%')) {{
    # Keep behavior aligned with Bash: avoid decoding NUL (%00) into paths.
    $containsNullEscape = ($v -match '(?i)%00')
    $stripped = [regex]::Replace($v, '%[0-9A-Fa-f]{{2}}', '')
    if (-not $containsNullEscape -and -not $stripped.Contains('%')) {{
      try {{ $v = [Uri]::UnescapeDataString($v) }} catch {{}}
    }}
  }}
  # Decode can re-introduce backslashes (for example %5C on Windows paths).
  # Normalize after decoding so slash-based matching stays consistent.
  $v = $v.Replace('\', '/')
  # Normalize duplicate separators and leading "./" fragments first.
  while ($v.Contains("//")) {{ $v = $v.Replace("//", "/") }}
  while ($v.StartsWith("./")) {{ $v = $v.Substring(2) }}
  if ($v -match '^/[A-Za-z]:/') {{
    # file:///C:/... style paths become /C:/... after scheme removal.
    # Drop only the leading slash to preserve the drive-qualified path.
    $v = $v.Substring(1)
  }}

  # Resolve dot segments. If ".." would traverse above root, return null so
  # callers can safely ignore this candidate.
  $isAbs = $v.StartsWith("/")
  if ($isAbs) {{ $v = $v.Substring(1) }}
  $parts = @($v.Split('/', [System.StringSplitOptions]::None))
  $stack = New-Object System.Collections.Generic.List[string]
  foreach ($part in $parts) {{
    if ([string]::IsNullOrEmpty($part) -or $part -eq ".") {{ continue }}
    if ($part -eq "..") {{
      if ($stack.Count -gt 0) {{
        $stack.RemoveAt($stack.Count - 1)
        continue
      }}
      return $null
    }}
    $stack.Add($part)
  }}
  $joined = [string]::Join("/", $stack.ToArray())
  if ($isAbs) {{ return "/$joined" }}
  return $joined
}}

function Add-PathCandidate([System.Collections.Generic.List[string]]$Candidates, [string]$Candidate) {{
  $normalized = Normalize-PathLike $Candidate
  if ([string]::IsNullOrEmpty($normalized)) {{ return }}
  if ($normalized.StartsWith("/")) {{ $normalized = $normalized.Substring(1) }}
  while ($normalized.StartsWith("./")) {{ $normalized = $normalized.Substring(2) }}
  if ([string]::IsNullOrEmpty($normalized)) {{ return }}
  # Generated artifacts should not be matched against repo CODEOWNERS.
  if ($normalized.StartsWith("bazel-out/")) {{ return }}
  if (-not $Candidates.Contains($normalized)) {{ $Candidates.Add($normalized) | Out-Null }}
}}

function Strip-WorkspacePrefix([string]$PathValue, [string]$WorkspaceRoot) {{
  if ([string]::IsNullOrEmpty($PathValue) -or [string]::IsNullOrEmpty($WorkspaceRoot)) {{ return $null }}
  $pathNorm = Normalize-PathLike $PathValue
  $rootNorm = Normalize-PathLike $WorkspaceRoot
  if ([string]::IsNullOrEmpty($pathNorm) -or [string]::IsNullOrEmpty($rootNorm)) {{ return $null }}
  if ($pathNorm -ceq $rootNorm) {{ return "" }}
  if ($pathNorm.StartsWith("$rootNorm/", [System.StringComparison]::Ordinal)) {{
    return $pathNorm.Substring($rootNorm.Length + 1)
  }}
  return $null
}}

function Get-PathCandidates([string]$SourcePath) {{
  $candidates = New-Object System.Collections.Generic.List[string]
  $normalized = Normalize-PathLike $SourcePath
  if ([string]::IsNullOrEmpty($normalized)) {{ return $candidates }}

  $workspaceRoot = $null
  if ($env:BUILD_WORKSPACE_DIRECTORY) {{
    $workspaceRoot = $env:BUILD_WORKSPACE_DIRECTORY
  }} elseif ($TestlogsDir -and ($TestlogsDir -match '^(.*?)[/\\]bazel-testlogs(?:[/\\].*)?$')) {{
    $workspaceRoot = $Matches[1]
  }} else {{
    $workspaceRoot = (Get-Location).Path
  }}

  # Candidate order is deliberate: try repo-relative variants first, then
  # runfiles/execroot-derived forms, then absolute normalized fallback.
  $workspaceRoots = @(
    $(if ($script:ContextObj) {{ $script:ContextObj.'ci.workspace_path' }} else {{ $null }}),
    $workspaceRoot
  )
  foreach ($root in $workspaceRoots) {{
    $stripped = Strip-WorkspacePrefix $normalized $root
    if ($stripped -ne $null) {{ Add-PathCandidate $candidates $stripped }}
  }}

  if ($normalized -match '/execroot/[^/]+/_main/(.+)$') {{
    Add-PathCandidate $candidates $Matches[1]
  }}
  if ($normalized -match '/execroot/[^/]+/(.+)$') {{
    Add-PathCandidate $candidates $Matches[1]
  }}
  if ($normalized -match '\\.runfiles/_main/(.+)$') {{
    Add-PathCandidate $candidates $Matches[1]
  }}
  if ($normalized -match '\\.runfiles/[^/]+/(.+)$') {{
    Add-PathCandidate $candidates $Matches[1]
  }}
  # Keep only repository-relative fallback candidates. Absolute paths that are
  # not under known repo roots can incorrectly inherit broad CODEOWNERS rules.
  if (-not $normalized.StartsWith("/") -and -not ($normalized -match '^[A-Za-z]:/')) {{
    Add-PathCandidate $candidates $normalized
  }} elseif ($script:DebugMode) {{
    Dbg "codeowners: skip absolute source fallback candidate '$normalized'"
  }}
  return $candidates
}}

function Convert-CodeOwnersGlobToRegex([string]$Pattern) {{
  $sb = New-Object System.Text.StringBuilder
  $i = 0
  while ($i -lt $Pattern.Length) {{
    $ch = $Pattern.Substring($i, 1)
    # Backslash escapes a literal glob metacharacter.
    if ($ch -eq '\') {{
      if (($i + 1) -lt $Pattern.Length) {{
        $escapedCh = $Pattern.Substring($i + 1, 1)
        [void]$sb.Append([Regex]::Escape($escapedCh))
        $i += 2
      }} else {{
        [void]$sb.Append("\\\\")
        $i++
      }}
      continue
    }}
    if ($ch -eq '*' -and ($i + 1) -lt $Pattern.Length -and $Pattern.Substring($i + 1, 1) -eq '*') {{
      if (($i + 2) -lt $Pattern.Length -and $Pattern.Substring($i + 2, 1) -eq '/') {{
        # CODEOWNERS follows gitignore-style globbing: **/ matches zero or more directories.
        [void]$sb.Append("(.*/)?")
        $i += 3
      }} else {{
        [void]$sb.Append(".*")
        $i += 2
      }}
      continue
    }}
    if ($ch -eq '*') {{
      [void]$sb.Append("[^/]*")
      $i++
      continue
    }} elseif ($ch -eq '?') {{
      [void]$sb.Append("[^/]")
      $i++
      continue
    }}
    if ($ch -eq '[') {{
      # Preserve character classes (including negation), because repositories
      # frequently use patterns like [Tt]est*.cs in CODEOWNERS.
      $j = $i + 1
      $classSb = New-Object System.Text.StringBuilder
      $closed = $false
      if ($j -lt $Pattern.Length -and $Pattern.Substring($j, 1) -eq '!') {{
        [void]$classSb.Append("^")
        $j++
      }} elseif ($j -lt $Pattern.Length -and $Pattern.Substring($j, 1) -eq '^') {{
        [void]$classSb.Append("\\^")
        $j++
      }}
      if ($j -lt $Pattern.Length -and $Pattern.Substring($j, 1) -eq ']') {{
        [void]$classSb.Append("\\]")
        $j++
      }}
      while ($j -lt $Pattern.Length) {{
        $classCh = $Pattern.Substring($j, 1)
        if ($classCh -eq ']') {{
          $closed = $true
          break
        }}
        if ($classCh -eq '\') {{
          [void]$classSb.Append("\\\\")
        }} elseif ($classCh -eq '^') {{
          [void]$classSb.Append("\\^")
        }} elseif ($classCh -eq '[') {{
          [void]$classSb.Append("\\[")
        }} elseif ($classCh -eq '-') {{
          [void]$classSb.Append("-")
        }} else {{
          [void]$classSb.Append([Regex]::Escape($classCh))
        }}
        $j++
      }}
      if ($closed) {{
        [void]$sb.Append("[$classSb]")
        $i = $j + 1
        continue
      }}
      [void]$sb.Append("\\[")
      $i++
      continue
    }}
    if ($ch -eq '.') {{
      [void]$sb.Append("\\.")
    }} elseif ($ch -eq '+') {{
      [void]$sb.Append("\\+")
    }} elseif ($ch -eq '(') {{
      [void]$sb.Append("\\(")
    }} elseif ($ch -eq ')') {{
      [void]$sb.Append("\\)")
    }} elseif ($ch -eq '{') {{
      [void]$sb.Append("\\{")
    }} elseif ($ch -eq '}') {{
      [void]$sb.Append("\\}")
    }} elseif ($ch -eq '^') {{
      [void]$sb.Append("\\^")
    }} elseif ($ch -eq '$') {{
      [void]$sb.Append("\\$")
    }} elseif ($ch -eq '|') {{
      [void]$sb.Append("\\|")
    }} elseif ($ch -eq '\') {{
      [void]$sb.Append("\\\\")
    }} elseif ($ch -eq ']') {{
      [void]$sb.Append("\\]")
    }} else {{
      [void]$sb.Append($ch)
    }}
    $i++
  }}
  return $sb.ToString()
}}

function Convert-CodeOwnersPatternToRegex([string]$Pattern) {{
  if ([string]::IsNullOrEmpty($Pattern)) {{ return $null }}
  $anchored = $false
  $dirOnly = $false
  $raw = $Pattern
  if ($raw.StartsWith("/")) {{
    $anchored = $true
    $raw = $raw.Substring(1)
  }}
  if ($raw.EndsWith("/")) {{
    $dirOnly = $true
    $raw = $raw.Substring(0, $raw.Length - 1)
  }}
  if ([string]::IsNullOrEmpty($raw)) {{ return $null }}
  $hasSlash = $raw.Contains("/")
  $body = Convert-CodeOwnersGlobToRegex $raw

  # Match semantics:
  # - anchored or slash-containing rules start at repo root
  # - simple names can match at any path segment boundary
  $prefix = if ($anchored -or $hasSlash) {{ "^" }} else {{ "(^|.*/)" }}
  $suffix = if ($dirOnly) {{ "/.*$" }} else {{ "($|/.*)" }}
  return "$prefix$body$suffix"
}}

function Split-CodeOwnersLine([string]$Line) {{
  if ([string]::IsNullOrEmpty($Line)) {{
    return [PSCustomObject]@{{ Pattern = ""; OwnersRaw = "" }}
  }}
  $sb = New-Object System.Text.StringBuilder
  $escaped = $false
  for ($i = 0; $i -lt $Line.Length; $i++) {{
    $ch = $Line.Substring($i, 1)
    if ($escaped) {{
      [void]$sb.Append($ch)
      $escaped = $false
      continue
    }}
    if ($ch -eq '\') {{
      [void]$sb.Append($ch)
      $escaped = $true
      continue
    }}
    if ([char]::IsWhiteSpace($Line[$i])) {{
      $ownersRaw = $Line.Substring($i).TrimStart()
      return [PSCustomObject]@{{ Pattern = $sb.ToString(); OwnersRaw = $ownersRaw }}
    }}
    [void]$sb.Append($ch)
  }}
  return [PSCustomObject]@{{ Pattern = $sb.ToString(); OwnersRaw = "" }}
}}

function Test-IsGitLabSectionHeaderPattern([string]$Pattern) {{
  if ([string]::IsNullOrEmpty($Pattern)) {{ return $false }}
  if ($Pattern -notmatch '^\\[[^\\[\\]]+\\]$') {{ return $false }}
  $inner = $Pattern.Substring(1, $Pattern.Length - 2)
  # GitLab section headers can include whitespace (for example [Core Team]).
  if ($inner.Contains(" ") -or $inner.Contains("`t")) {{
    return $true
  }}
  # Heuristic to avoid class-only glob false positives:
  # keep range-like and short bracket classes (for example [xy], [A-Z]).
  if ($inner.Contains('-') -or $inner.Contains('!') -or $inner.Contains('^') -or $inner.Contains('\')) {{
    return $false
  }}
  if ($inner.Length -le 2) {{ return $false }}
  # Preserve plain lowercase/digit class sets such as [abc] and [a1b2].
  if ($inner -cmatch '^[a-z0-9]+$') {{ return $false }}
  return $true
}}

function Test-IsGitLabSectionHeaderLine([string]$Line) {{
  if ([string]::IsNullOrEmpty($Line)) {{ return $false }}
  if ($Line -notmatch '^(\\[[^\\[\\]]+\\])(?:\\s+.*)?$') {{ return $false }}
  return (Test-IsGitLabSectionHeaderPattern $Matches[1])
}}

function Initialize-CodeOwnersRules {{
  if ($script:CodeOwnersInitialized) {{ return }}
  $script:CodeOwnersInitialized = $true

  $workspace = $null
  if ($env:BUILD_WORKSPACE_DIRECTORY) {{
    $workspace = $env:BUILD_WORKSPACE_DIRECTORY
  }} elseif ($TestlogsDir -and ($TestlogsDir -match '^(.*?)[/\\]bazel-testlogs(?:[/\\].*)?$')) {{
    $workspace = $Matches[1]
  }} else {{
    $workspace = (Get-Location).Path
  }}
  $compatWorkspace = if ($script:ContextObj) {{ $script:ContextObj.'ci.workspace_path' }} else {{ $null }}
  # Lookup order must mirror Bash implementation for cross-platform parity.
  $lookupPaths = @(
    $(if ($compatWorkspace) {{ Join-Path $compatWorkspace "CODEOWNERS" }} else {{ $null }}),
    $(if ($compatWorkspace) {{ Join-Path $compatWorkspace ".github/CODEOWNERS" }} else {{ $null }}),
    $(if ($compatWorkspace) {{ Join-Path $compatWorkspace ".gitlab/CODEOWNERS" }} else {{ $null }}),
    $(if ($compatWorkspace) {{ Join-Path $compatWorkspace "docs/CODEOWNERS" }} else {{ $null }}),
    $(if ($compatWorkspace) {{ Join-Path $compatWorkspace ".docs/CODEOWNERS" }} else {{ $null }}),
    (Join-Path $workspace "CODEOWNERS"),
    (Join-Path $workspace ".github/CODEOWNERS"),
    (Join-Path $workspace ".gitlab/CODEOWNERS"),
    (Join-Path $workspace "docs/CODEOWNERS"),
    (Join-Path $workspace ".docs/CODEOWNERS"),
    (Join-Path (Get-Location).Path "CODEOWNERS"),
    (Join-Path $PSScriptRoot "CODEOWNERS")
  )

  foreach ($candidate in $lookupPaths) {{
    if ([string]::IsNullOrEmpty($candidate)) {{ continue }}
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {{
      $script:CodeOwnersPath = $candidate
      break
    }}
  }}
  if (-not $script:CodeOwnersPath) {{
    Dbg "codeowners: no CODEOWNERS file found (workspace='$workspace')"
    return
  }}

  try {{
    $lines = Get-Content -LiteralPath $script:CodeOwnersPath -Encoding UTF8 -ErrorAction Stop
  }} catch {{
    Dbg "codeowners: failed to read '$script:CodeOwnersPath' ($_)"
    return
  }}

  foreach ($line in $lines) {{
    $trimmed = $line.Trim()
    if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith("#")) {{ continue }}
    # Section headers may include spaces (for example "[Core Team] @org/team").
    # Detect them from the full raw line before splitting on whitespace.
    if (Test-IsGitLabSectionHeaderLine $trimmed) {{
      continue
    }}
    $split = Split-CodeOwnersLine $trimmed
    $pattern = [string]$split.Pattern
    if ([string]::IsNullOrEmpty($pattern)) {{ continue }}
    $ownersRaw = [string]$split.OwnersRaw
    # Ignore GitLab-style section headers while preserving bracket-class globs.
    if (Test-IsGitLabSectionHeaderPattern $pattern) {{
      continue
    }}
    $ownersRaw = $ownersRaw.Trim()
    # Strip inline comments only when '#' begins a comment segment.
    if ($ownersRaw.StartsWith("#")) {{
      $ownersRaw = ""
    }} elseif ($ownersRaw -match '\\s#') {{
      $ownersRaw = ($ownersRaw -replace '\\s#.*$', '').TrimEnd()
    }}
    $ownerTokens = @()
    if (-not [string]::IsNullOrWhiteSpace($ownersRaw)) {{
      $ownerTokens = @($ownersRaw -split '\\s+' | Where-Object {{ -not [string]::IsNullOrEmpty($_) }})
    }}
    $regex = Convert-CodeOwnersPatternToRegex $pattern
    if ([string]::IsNullOrEmpty($regex)) {{ continue }}
    # Best-effort hardening: malformed character classes can produce invalid
    # .NET regexes (for example "[z-a]"). Skip those rules here so one bad
    # line cannot force all candidate evaluations into catch paths.
    try {{
      [void][System.Text.RegularExpressions.Regex]::new($regex)
    }} catch {{
      Dbg "codeowners: skipping invalid regex '$regex' from pattern '$pattern'"
      continue
    }}
    $script:CodeOwnersRules += [PSCustomObject]@{{
      Regex = $regex
      Owners = $ownerTokens
      HasOwners = ($ownerTokens.Count -gt 0)
    }}
  }}

  if ($script:CodeOwnersRules.Count -gt 0) {{
    $script:CodeOwnersEnabled = $true
    Dbg "codeowners: using '$script:CodeOwnersPath' with $($script:CodeOwnersRules.Count) rule(s)"
  }} else {{
    Dbg "codeowners: file '$script:CodeOwnersPath' had no usable rules"
  }}
}}

function Get-CodeOwnersMatchForCandidate([string]$Candidate) {{
  $matched = $false
  $matchOwners = @()
  $matchHasOwners = $false
  # Last matching rule wins (GitHub CODEOWNERS behavior).
  foreach ($rule in $script:CodeOwnersRules) {{
    if ($Candidate -cmatch $rule.Regex) {{
      $matched = $true
      $matchOwners = @($rule.Owners)
      $matchHasOwners = [bool]$rule.HasOwners
    }}
  }}
  return [PSCustomObject]@{{
    Matched = $matched
    Owners = $matchOwners
    HasOwners = $matchHasOwners
  }}
}}

function Convert-OwnersToJsonString($Owners) {{
  if (-not $Owners -or $Owners.Count -eq 0) {{ return $null }}
  $dedup = New-Object System.Collections.Generic.List[string]
  foreach ($owner in $Owners) {{
    if (-not [string]::IsNullOrEmpty($owner) -and -not $dedup.Contains([string]$owner)) {{
      $dedup.Add([string]$owner) | Out-Null
    }}
  }}
  if ($dedup.Count -eq 0) {{ return $null }}
  # Keep JSON shape stable: always emit an array string, including a single owner.
  $dedupArr = @($dedup.ToArray())
  return (ConvertTo-Json -InputObject $dedupArr -Compress)
}}

function Get-CodeOwnersJsonForSource([string]$SourcePath) {{
  Initialize-CodeOwnersRules
  if (-not $script:CodeOwnersEnabled) {{ return $null }}
  $candidates = Get-PathCandidates $SourcePath
  # Return first candidate hit (candidate list is already priority-ordered).
  foreach ($candidate in $candidates) {{
    $match = Get-CodeOwnersMatchForCandidate $candidate
    if (-not $match.Matched) {{ continue }}
    if (-not $match.HasOwners) {{ return $null }}
    $jsonOwners = Convert-OwnersToJsonString $match.Owners
    if (-not [string]::IsNullOrEmpty($jsonOwners)) {{
      return $jsonOwners
    }}
  }}
  return $null
}}

function Get-EventSourcePath($EventObj) {{
  if (-not $EventObj) {{ return $null }}
  $content = Get-MapValue $EventObj 'content'
  if ($null -eq $content) {{ return $null }}
  $contentMap = Ensure-Hashtable $content

  # Accept both flattened meta keys and nested source objects.
  $meta = Ensure-Hashtable (Get-MapValue $contentMap 'meta')
  foreach ($k in @('test.source.file', 'test.source.path', 'source.file', 'source.path')) {{
    $v = Get-MapValue $meta $k
    if ($v -is [string] -and -not [string]::IsNullOrEmpty($v)) {{ return $v }}
  }}

  $source = Ensure-Hashtable (Get-MapValue $contentMap 'source')
  foreach ($k in @('file', 'path')) {{
    $v = Get-MapValue $source $k
    if ($v -is [string] -and -not [string]::IsNullOrEmpty($v)) {{ return $v }}
  }}
  return $null
}}

function Merge-With-Context([string]$infile, [string]$outfile) {{
  try {{
    $payload = Get-Content -LiteralPath $infile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  }} catch {{
    Copy-Item -LiteralPath $infile -Destination $outfile -Force
    return
  }}

  if (-not $payload.metadata) {{ $payload | Add-Member -NotePropertyName metadata -NotePropertyValue @{{}} -Force }}
  $meta = Ensure-Hashtable $payload.metadata
  $star = Ensure-Hashtable (Get-MapValue $meta '*')

  # Compute runtime-id, language, library_version, env (fill missing only)
  $runtimeId = Get-MapValue $star 'runtime-id'
  if ([string]::IsNullOrEmpty($runtimeId)) {{
    if ($script:ContextObj) {{
      $runtimeId = $script:ContextObj.'runtime-id'
      if ([string]::IsNullOrEmpty($runtimeId)) {{ $runtimeId = $script:ContextObj.'runtime.id' }}
      if ([string]::IsNullOrEmpty($runtimeId)) {{ $runtimeId = $script:ContextObj.'runtime_id' }}
    }}
    if ([string]::IsNullOrEmpty($runtimeId)) {{ $runtimeId = $script:RuntimeId }}
  }}

  $language = Get-MapValue $star 'language'
  if ([string]::IsNullOrEmpty($language)) {{
    if ($script:ContextObj) {{
      $language = $script:ContextObj.language
      if ([string]::IsNullOrEmpty($language)) {{ $language = $script:ContextObj.'runtime.name' }}
      if ([string]::IsNullOrEmpty($language)) {{ $language = $script:ContextObj.'runtime_name' }}
    }}
    if ([string]::IsNullOrEmpty($language)) {{ $language = 'bazel' }}
  }}

  $libraryVersion = Get-MapValue $star 'library_version'
  if ([string]::IsNullOrEmpty($libraryVersion)) {{ $libraryVersion = $script:RulesVersion }}

  $envVal = Get-MapValue $star 'env'
  if ([string]::IsNullOrEmpty($envVal) -and $script:ContextObj) {{ $envVal = $script:ContextObj.env }}

  $newStar = @{{ 'runtime-id' = $runtimeId; 'language' = $language; 'library_version' = $libraryVersion }}
  if (-not [string]::IsNullOrEmpty($envVal)) {{ $newStar['env'] = $envVal }}

  # Prune top-level metadata keys
  $newMeta = @{{ '*' = $newStar }}
  foreach ($k in @('test', 'test_suite_end', 'test_module_end', 'test_session_end')) {{
    $metaVal = Get-MapValue $meta $k
    if ($null -ne $metaVal) {{ $newMeta[$k] = $metaVal }}
  }}
  $payload.metadata = $newMeta

  # Copy context tags into event meta/metrics, then inject CODEOWNERS.
  # Span events are intentionally excluded from enrichment.
  if ($payload.events) {{
    foreach ($evt in $payload.events) {{
      $evtType = Get-MapValue $evt 'type'
      if ($evtType -eq 'span') {{ continue }}
      if (-not (Get-MapValue $evt 'content')) {{ $evt | Add-Member -NotePropertyName content -NotePropertyValue @{{}} -Force }}
      $evt.content = Ensure-Hashtable $evt.content
      $evt.content.meta = Ensure-Hashtable $evt.content.meta
      $evt.content.metrics = Ensure-Hashtable $evt.content.metrics

      if ($script:ContextObj) {{
        foreach ($prop in $script:ContextObj.PSObject.Properties) {{
          # Keep API key fingerprint out of uploaded event content.
          if ($prop.Name -eq 'topt.api_key_fingerprint') {{ continue }}
          $val = $prop.Value
          if ($val -is [string]) {{
            $evt.content.meta[$prop.Name] = $val
          }} elseif ($val -is [int] -or $val -is [long] -or $val -is [double] -or $val -is [decimal]) {{
            $evt.content.metrics[$prop.Name] = [double]$val
          }} else {{
            try {{
              $evt.content.meta[$prop.Name] = ($val | ConvertTo-Json -Compress -Depth 100)
            }} catch {{
              $evt.content.meta[$prop.Name] = $val.ToString()
            }}
          }}
        }}
      }}

      $script:CodeOwnersStats.scanned++
      # Respect upstream/producer-specified ownership tags.
      if ($evt.content.meta.Contains('test.codeowners')) {{
        $script:CodeOwnersStats.skipped_existing++
        if ($script:DebugMode) {{ Dbg "codeowners: skip existing tag for event type '$evtType'" }}
        continue
      }}
      $sourcePath = Get-EventSourcePath $evt
      if ([string]::IsNullOrEmpty($sourcePath)) {{
        $script:CodeOwnersStats.skipped_missing_source++
        if ($script:DebugMode) {{ Dbg "codeowners: skip missing source for event type '$evtType'" }}
        continue
      }}
      try {{
        $ownersJson = Get-CodeOwnersJsonForSource $sourcePath
        if ([string]::IsNullOrEmpty($ownersJson)) {{
          $script:CodeOwnersStats.skipped_unmatched++
          if ($script:DebugMode) {{ Dbg "codeowners: skip unmatched source '$sourcePath' for event type '$evtType'" }}
          continue
        }}
        $evt.content.meta['test.codeowners'] = $ownersJson
        $script:CodeOwnersStats.enriched++
        if ($script:DebugMode) {{ Dbg "codeowners: assigned owners '$ownersJson' for event type '$evtType'" }}
      }} catch {{
        $script:CodeOwnersStats.skipped_errors++
        Dbg "codeowners: failed to resolve owners for '$sourcePath' ($_)"
      }}
    }}
  }}

  if ($script:DebugMode) {{
    Dbg "codeowners: scanned=$($script:CodeOwnersStats.scanned) enriched=$($script:CodeOwnersStats.enriched) skipped_existing=$($script:CodeOwnersStats.skipped_existing) skipped_missing_source=$($script:CodeOwnersStats.skipped_missing_source) skipped_unmatched=$($script:CodeOwnersStats.skipped_unmatched) skipped_errors=$($script:CodeOwnersStats.skipped_errors)"
  }}

  Dbg "Merge-With-Context: wrote enriched '$outfile'"
  $jsonPayload = $payload | ConvertTo-Json -Depth 100
  Write-Utf8NoBomFile -Path $outfile -Content $jsonPayload
}}

function Validate-Payload([string]$FilePath) {{
    if (-not $script:SchemaJson -or -not (Test-Path -LiteralPath $script:SchemaJson)) {{
        Dbg "schema validation skipped: schema not available"
        return
    }}
    if (-not $script:SchemaValidator -or -not (Test-Path -LiteralPath $script:SchemaValidator)) {{
        Dbg "schema validation skipped: validator not available"
        return
    }}
    $py = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py) {{
        Dbg "schema validation skipped: python3 not available"
        return
    }}
    Dbg "schema validate: python3 $script:SchemaValidator $script:SchemaJson $FilePath"
    try {{
        & $py.Source $script:SchemaValidator $script:SchemaJson $FilePath | Out-Null
        if ($LASTEXITCODE -ne 0) {{
            Log "warning: schema validation failed for payload: $FilePath"
        }}
    }} catch {{
        Log "warning: schema validation failed for payload: $FilePath"
    }}
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
  if (-not (Ensure-HttpClientTypes)) {{
    Log "upload failed: System.Net.Http.HttpClient unavailable in this PowerShell runtime"
    return $false
  }}
  for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {{
    $client = $null
    try {{
      $client = New-Object System.Net.Http.HttpClient
      $client.Timeout = [TimeSpan]::FromSeconds(60)
      foreach ($k in $headers.Keys) {{ $client.DefaultRequestHeaders.Add($k, [string]$headers[$k]) }}
      Dbg "Send-PostJson: POST $url (file '$file'; attempt $attempt/$maxRetries)"
      if ($script:GzipPayloads) {{
        $bytes = [IO.File]::ReadAllBytes($file)
        $ms = New-Object System.IO.MemoryStream
        $gz = New-Object System.IO.Compression.GzipStream($ms, [System.IO.Compression.CompressionMode]::Compress)
        $gz.Write($bytes, 0, $bytes.Length)
        $gz.Close()
        $compressed = $ms.ToArray()
        $content = New-Object System.Net.Http.ByteArrayContent($compressed)
        $content.Headers.ContentType = 'application/json'
        $content.Headers.ContentEncoding.Add('gzip')
        Dbg "Send-PostJson: Content-Type=application/json; Content-Encoding=gzip (bytes=$($compressed.Length))"
      }} else {{
        $content = New-Object System.Net.Http.StringContent([IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8))
        $content.Headers.ContentType = 'application/json'
        Dbg "Send-PostJson: Content-Type=application/json"
      }}
      $resp = $client.PostAsync($url, $content).GetAwaiter().GetResult()
      if ($resp.IsSuccessStatusCode) {{
        if ($script:DebugMode) {{
          $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
          if ($body) {{ Dbg "Send-PostJson response: $body" }}
        }}
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
    Validate-Payload $body
    $hdrs = Get-CommonHeaders $body
    if (-not $Agentless) {{ $hdrs['X-Datadog-EVP-Subdomain'] = 'citestcycle-intake' }}
    Dbg "Upload-SingleTest: posting '$FilePath' (body '$body')"
    if ($script:DebugMode) {{
        Write-Host "[dd-uploader][dbg] payload content (enriched) for '$FilePath':"
        Write-Host (Get-Content -LiteralPath $body -Raw)
        Dbg "request: POST $TestUrl"
        Dbg-Headers "common" $hdrs
        Log-StartTimeStats $body
    }}
    $result = Send-PostJson $TestUrl $hdrs $body
    Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue
    return $result
}}

function Upload-SingleCoverage([string]$FilePath) {{
    $eventFile = Join-Path $script:TmpPayloadDir ("coverage_event_" + [System.Guid]::NewGuid().ToString("N") + ".json")
    Write-Utf8NoBomFile -Path $eventFile -Content '{{"dummy":true}}'

    $client = $null
    $fs = $null
    $maxRetries = 3
    $retryDelay = 2
    $uploaded = $false

    try {{
        if (-not (Ensure-HttpClientTypes)) {{
            Log "coverage upload failed: System.Net.Http.HttpClient unavailable in this PowerShell runtime"
            return $false
        }}
        $covHeaders = Get-CommonHeaders $null
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        foreach ($k in $covHeaders.Keys) {{ $client.DefaultRequestHeaders.Add($k, [string]$covHeaders[$k]) }}
        if (-not $Agentless) {{ $client.DefaultRequestHeaders.Add('X-Datadog-EVP-Subdomain','citestcov-intake') }}
        if ($script:DebugMode) {{
            Dbg "request: POST $CovUrl"
            Dbg-Headers "common" $covHeaders
            if (-not $Agentless) {{ Dbg "header[evp]: X-Datadog-EVP-Subdomain: citestcov-intake" }}
        }}

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
                Dbg "Upload-SingleCoverage: posting '$FilePath' (attempt $attempt/$maxRetries; Content-Type=multipart/form-data)"
                $resp = $client.PostAsync($CovUrl, $content).GetAwaiter().GetResult()
                if ($resp.IsSuccessStatusCode) {{
                    $uploaded = $true
                    if ($script:DebugMode) {{
                        $respBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        if ($respBody) {{ Dbg "Upload-SingleCoverage response: $respBody" }}
                    }}
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
            "gzip_payloads": _bool_to_str(gzip_payloads),
            "uploader_version": UPLOADER_VERSION,
            "context_json_rloc": context_json_rloc,
            "context_json_path": context_json_path,
            "schema_json_rloc": schema_json_rloc,
            "schema_json_path": schema_json_path,
            "schema_validator_rloc": schema_validator_rloc,
            "schema_validator_path": schema_validator_path,
            "rules_version": RULES_VERSION,
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
    extra_files = []
    if ctx.file._schema:
        extra_files.append(ctx.file._schema)
    if ctx.file._schema_validator:
        extra_files.append(ctx.file._schema_validator)
    runfiles = ctx.runfiles(files = [ps_file, bat_file] + ctx.files.data + extra_files)
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
        "max_wait_sec": attr.int(default = 300, doc = "Maximum seconds to wait for payloads (env: DD_TOPT_MAX_WAIT_SEC). Set to 0 to skip waiting when no payloads are present."),
        "fail_on_error": attr.bool(default = False, doc = "Exit with error if no payloads found when tests ran"),
        "debug": attr.bool(default = False, doc = "Enable debug logging"),
        "keep_payloads": attr.bool(default = False, doc = "Keep payload files after successful upload (env: DD_TOPT_KEEP_PAYLOADS)"),
        "filter_prefix": attr.bool(default = False, doc = "Only upload files matching span_events_*.json or coverage_*.json (env: DD_TOPT_FILTER_PREFIX)"),
        "gzip_payloads": attr.bool(default = False, doc = "Gzip test payloads before upload (env: DD_TOPT_GZIP)"),
        # Optional files to place in runfiles (e.g., a generated context.json)
        "data": attr.label_list(allow_files = True, doc = "Data files to include in runfiles (e.g., context.json for enrichment)"),
        # Schema + validator bundled for best-effort payload validation
        "_schema": attr.label(default = "//tools:schemas/agentless-schema.json", allow_single_file = True),
        "_schema_validator": attr.label(default = "//tools:validate_payload_schema.py", allow_single_file = True),
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
    DD_TOPT_MAX_WAIT_SEC - Override max wait time (0 skips waiting when no payloads are present)
    DD_TOPT_QUIESCENT_SEC - Override quiescence wait time
    DD_TOPT_MAX_DEPTH - Limit find depth for large testlogs trees
""",
)
