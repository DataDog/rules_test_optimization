"""Datadog Test Optimization repository rule helpers and module extension.

This file defines:
- A repository_rule (`test_optimization_sync`) that performs one or more
  authenticated HTTP POST requests to Datadog to retrieve Test Optimization
  metadata.
- Reusable helpers for building curl commands, ensuring output directories
  exist, and parsing JSON in Starlark.
- A first request to the Settings API which always runs and writes
  `settings_file`.
- An optional second request to the Known Tests API when the settings say
  `known_tests_enabled = true`, writing `known_tests_file`. If disabled, an
  empty JSON stub for known tests is still written so downstream consumers
  can always depend on the declared outputs.

Repository-rule execution model:
- This code runs during Bazel repository/module resolution, not test runtime.
- It must therefore be deterministic given the declared `environ` inputs and
  repository attributes.
- Network and host-tool access happen here so test actions can remain hermetic.

High-level data flow:
1) Resolve env/context metadata (CI + Git + runtime hints)
2) Fetch settings JSON
3) Optionally fetch known-tests and test-management JSON
4) Split module payloads into stable per-module bundles
5) Generate BUILD/export/context/manifest outputs for consumers

Important invariants:
- Secrets are never written to generated files (API key is used only in-memory
  for requests).
- Public label names are stable (`test_optimization_files`,
  `test_optimization_context`, `module_<sanitized>`).
- Output JSONs are generated in deterministic key/order-sensitive paths to keep
  cache behavior predictable.

Troubleshooting guidance for maintainers:
- Failures in this file are often due to environment/configuration drift
  (missing `DD_API_KEY`, wrong `DD_SITE`, stale refs) rather than logic bugs.
- Keep `fail(...)` messages explicit and user-actionable.
"""

# Developer map (quick navigation):
# - Filesystem helpers: `_ensure_parent_directory`, `_dirname`, `_try_read_abs_file`
# - Go/rules metadata helpers: `_detect_go_module_path`, `_build_context_tags`
# - HTTP helpers: `_http_request`, `_http_post_json`
# - API calls: `_perform_dd_settings_request`, `_perform_dd_known_tests_request`,
#              `_perform_dd_test_management_tests_request`
# - Repository entrypoint: `_impl`

load(
    "//tools/core:common_utils.bzl",
    "RULES_VERSION",
    "dedup_keys",
    "fail_with_prefix",
    "log_debug",
    "log_info",
    "sanitize_label_fragment",
    "validate_api_key",
    "validate_runtime_name",
    "validate_runtime_version",
    "validate_service_name",
    _is_dict = "is_dict",
)
load(
    "//tools/core:test_optimization_sync_env.bzl",
    _ALL_SYNC_ENV_KEYS = "ALL_SYNC_ENV_KEYS",
    _apply_dd_git_overrides = "apply_dd_git_overrides",
    _apply_github_event_payload = "apply_github_event_payload",
    _collect_env_from_environ = "collect_env_from_environ",
    _first_env = "first_env",
    _first_env_from_environ = "first_env_from_environ",
    _normalize_ref = "normalize_ref",
    _sanitize_repository_url = "sanitize_repository_url",
    _set_context_tag_from_env = "set_context_tag_from_env",
)

# ##########################################################################
# Constants
# ##########################################################################

TEST_OPT_DIR = ".testoptimization"
TEST_BAZEL_RULE_NAME = "datadog-rules-test-optimization"
TEST_BAZEL_RULE_VERSION = RULES_VERSION

# Shared HTTP timing/retry policy for both curl and Invoke-WebRequest paths.
HTTP_CONNECT_TIMEOUT_SECONDS = 10
HTTP_MAX_TIME_SECONDS = 60
HTTP_RETRY_ATTEMPTS = 3
HTTP_RETRY_DELAY_SECONDS = 2

# Keep outer execute timeout above worst-case retry budget to avoid cutting
# transport retries short on slower hosts/CI workers.
HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS = 60
HTTP_EXECUTE_TIMEOUT_SECONDS = (
    # Curl/PowerShell both do one initial attempt plus `retry_attempts` retries.
    ((HTTP_RETRY_ATTEMPTS + 1) * HTTP_MAX_TIME_SECONDS) +
    (HTTP_RETRY_ATTEMPTS * HTTP_RETRY_DELAY_SECONDS) +
    HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS
)

# Sentinel value used by optional integer attrs where 0 can be meaningful.
HTTP_POLICY_ATTR_UNSET = -1

# ##########################################################################
# Tools functions
# ##########################################################################

def _parse_int_from_env_or_fail(env_key, raw_value):
    """Parse a base-10 integer from an environment variable value."""
    s = (raw_value or "").strip()
    if not s:
        fail_with_prefix("test_optimization_sync", "%s must be a non-empty integer when set" % env_key)
    start = 1 if s.startswith("-") else 0
    if start == len(s):
        fail_with_prefix("test_optimization_sync", "%s must be a valid integer, got %s" % (env_key, repr(raw_value)))
    for i in range(start, len(s)):
        ch = s[i]
        if ch < "0" or ch > "9":
            fail_with_prefix("test_optimization_sync", "%s must be a valid integer, got %s" % (env_key, repr(raw_value)))
    return int(s)

def _resolve_http_int_setting(ctx, attr_name, env_key, default_value, allow_zero = False):
    """Resolve one HTTP policy integer from attr/env/default with validation."""
    attr_value = getattr(ctx.attr, attr_name, HTTP_POLICY_ATTR_UNSET)
    if attr_value != HTTP_POLICY_ATTR_UNSET:
        value = attr_value
        source = "attribute %s" % attr_name
    else:
        env_value = (ctx.os.environ.get(env_key) or "").strip()
        if env_value:
            value = _parse_int_from_env_or_fail(env_key, env_value)
            source = "environment %s" % env_key
        else:
            value = default_value
            source = "default"
    if allow_zero:
        if value < 0:
            fail_with_prefix("test_optimization_sync", "%s must be >= 0 (from %s), got %d" % (attr_name, source, value))
    elif value <= 0:
        fail_with_prefix("test_optimization_sync", "%s must be > 0 (from %s), got %d" % (attr_name, source, value))
    return value

def _resolve_http_policy(ctx):
    """Resolve effective HTTP timeout/retry policy from attrs/env/defaults."""
    connect_timeout_seconds = _resolve_http_int_setting(
        ctx,
        "http_connect_timeout_seconds",
        "DD_TEST_OPTIMIZATION_HTTP_CONNECT_TIMEOUT_SECONDS",
        HTTP_CONNECT_TIMEOUT_SECONDS,
    )
    max_time_seconds = _resolve_http_int_setting(
        ctx,
        "http_max_time_seconds",
        "DD_TEST_OPTIMIZATION_HTTP_MAX_TIME_SECONDS",
        HTTP_MAX_TIME_SECONDS,
    )
    retry_attempts = _resolve_http_int_setting(
        ctx,
        "http_retry_attempts",
        "DD_TEST_OPTIMIZATION_HTTP_RETRY_ATTEMPTS",
        HTTP_RETRY_ATTEMPTS,
    )
    retry_delay_seconds = _resolve_http_int_setting(
        ctx,
        "http_retry_delay_seconds",
        "DD_TEST_OPTIMIZATION_HTTP_RETRY_DELAY_SECONDS",
        HTTP_RETRY_DELAY_SECONDS,
        allow_zero = True,
    )
    execute_timeout_buffer_seconds = _resolve_http_int_setting(
        ctx,
        "http_execute_timeout_buffer_seconds",
        "DD_TEST_OPTIMIZATION_HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS",
        HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS,
        allow_zero = True,
    )
    execute_timeout_seconds = (
        # Retry budget = initial attempt + N retries.
        ((retry_attempts + 1) * max_time_seconds) +
        (retry_attempts * retry_delay_seconds) +
        execute_timeout_buffer_seconds
    )
    return {
        "connect_timeout_seconds": connect_timeout_seconds,
        "max_time_seconds": max_time_seconds,
        "retry_attempts": retry_attempts,
        "retry_delay_seconds": retry_delay_seconds,
        "execute_timeout_buffer_seconds": execute_timeout_buffer_seconds,
        "execute_timeout_seconds": execute_timeout_seconds,
    }

def _curl_base_args(policy):
    """Return the shared curl argument baseline for sync API calls.

    Keep this in one helper so timeout/retry policy stays consistent across
    settings/known-tests/test-management requests.
    """

    # _curl_base_args: returns common curl flags applied to all HTTP requests
    # -f: fail on HTTP errors (>= 400)
    # -sS: silent, but show errors
    # retry/backoff: basic robustness against transient failures
    return [
        "curl",
        "-f",
        "-sS",
        "--connect-timeout",
        str(policy["connect_timeout_seconds"]),
        "--max-time",
        str(policy["max_time_seconds"]),
        "--retry",
        str(policy["retry_attempts"]),
        "--retry-delay",
        str(policy["retry_delay_seconds"]),
        "--retry-connrefused",
    ]

def _is_windows(ctx):
    """Best-effort repository-host Windows detection."""

    # _is_windows: prefer repository_ctx.os.name, then fall back to env heuristics.
    os_name = (getattr(ctx.os, "name", "") or "").lower()
    if "windows" in os_name:
        return True
    os_env = (ctx.os.environ.get("OS") or "").lower()
    comspec = (ctx.os.environ.get("ComSpec") or ctx.os.environ.get("COMSPEC") or "").lower()
    return ("windows" in os_env) or comspec.endswith("cmd.exe")

_FINGERPRINT_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_:/.+@=#%~!$^*()[]{}<>?,;|\\\"'` "

def _powershell_single_quote_literal(value):
    """Escape value for safe use inside a single-quoted PowerShell string."""
    return (value or "").replace("'", "''")

def _fnv1a_32(value):
    """Compute a deterministic non-cryptographic 32-bit hash.

    Used only for context fingerprinting; this is *not* a security primitive.
    """

    # FNV-1a style 32-bit hash for stable fingerprinting (non-cryptographic).
    # Starlark lacks ord()/bytes, so map characters via a fixed alphabet.
    h = 2166136261
    vlen = len(value)
    for i in range(vlen):
        ch = value[i]
        idx = _FINGERPRINT_ALPHABET.find(ch)
        if idx < 0:
            # Spread unknown characters across a few deterministic buckets
            # instead of collapsing all to one index.
            idx = len(_FINGERPRINT_ALPHABET) + (i % 7)
        h = h ^ idx
        h = (h * 16777619) & 0xffffffff
    return h

def _clone_payload_with_detached_attributes(obj):
    """Deep-clone payload object so module mutations never leak to source."""
    return _clone_json_like(obj)

def _clone_json_like(value):
    """Clone dict/list payload nodes via JSON round-trip; scalars pass through."""
    if _is_dict(value) or type(value) == type([]):
        return json.decode(json.encode(value))
    return value

def _hex32(value):
    """Format a 32-bit integer as lowercase 8-char hex."""
    digits = "0123456789abcdef"
    out = ""
    v = value
    for _ in range(8):
        out = digits[v & 0xf] + out
        v = v >> 4
    return out

def _api_key_fingerprint(api_key):
    """Return a non-reversible stable fingerprint for an API key value."""
    if not api_key:
        return ""
    return _hex32(_fnv1a_32(api_key))

def _ensure_parent_directory(ctx, path, debug):
    """Ensure parent directory exists for a generated output file path.

    This helper is cross-platform: Unix uses `mkdir -p`; Windows uses
    PowerShell `New-Item -ItemType Directory -Force`.
    """

    # Create parent directory for a given file path if needed.
    # Starlark has no os.path utilities; use simple split/join.
    if not path:
        return

    normalized_path = path.replace("\\", "/")

    # Normalize path segments and drop empty/"." parts
    segments = [s for s in normalized_path.split("/") if (s != "" and s != ".")]
    if len(segments) <= 1:
        return
    dirp = "/".join(segments[:-1])
    if _is_windows(ctx):
        # On Windows use PowerShell New-Item to create intermediate directories robustly
        win_dir = dirp.replace("/", "\\")
        ps_cmd = [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "New-Item -ItemType Directory -Force -Path '%s' | Out-Null" % _powershell_single_quote_literal(win_dir),
        ]
        res = ctx.execute(ps_cmd)
    else:
        res = ctx.execute(["mkdir", "-p", dirp])
    log_debug(debug, "filesystem", "Ensured directory '%s' for output '%s' (rc=%d)" % (dirp, path, res.return_code))
    if res.return_code != 0:
        fail_with_prefix("test_optimization_sync", "Failed creating directory %s for output %s: %s" % (dirp, path, (res.stderr or "").strip()))

def _dirname(path):
    """Return parent directory using simple Starlark path operations."""

    # _dirname: return parent directory component of a path using simple split
    if not path:
        return ""
    segs = [s for s in path.split("/") if (s != "" and s != ".")]
    if len(segs) <= 1:
        return ""
    return "/".join(segs[:-1])

def _normalize_out_dir_or_fail(out_dir):
    """Validate and normalize sync `out_dir` into a safe relative path."""

    # Keep output paths predictable and avoid traversal/absolute path inputs.
    raw = (out_dir or "").strip()
    if not raw:
        fail_with_prefix("test_optimization_sync", "out_dir must be a non-empty relative path")
    for ch in ["\n", "\r", "\t"]:
        if ch in raw:
            fail_with_prefix("test_optimization_sync", "out_dir must not contain control characters: %s" % repr(out_dir))

    normalized = raw.replace("\\", "/")
    if normalized.startswith("/"):
        fail_with_prefix("test_optimization_sync", "out_dir must be relative (absolute paths are not allowed): %s" % repr(out_dir))
    if len(normalized) >= 2 and normalized[1] == ":":
        fail_with_prefix("test_optimization_sync", "out_dir must not include a Windows drive prefix: %s" % repr(out_dir))

    segments = []
    for seg in normalized.split("/"):
        if seg == "" or seg == ".":
            continue
        if seg == "..":
            fail_with_prefix("test_optimization_sync", "out_dir must not contain '..' path traversal segments: %s" % repr(out_dir))
        segments.append(seg)

    if not segments:
        fail_with_prefix("test_optimization_sync", "out_dir must resolve to a non-empty relative path: %s" % repr(out_dir))
    return "/".join(segments)

def _bzl_string_literal(value):
    """Return a safely escaped double-quoted Starlark string literal."""
    return json.encode(str(value or ""))

def _validate_abs_path_command_input_or_fail(abs_path):
    """Fail fast when absolute path contains control characters."""
    if not abs_path:
        return
    if ("\n" in abs_path) or ("\r" in abs_path) or ("\t" in abs_path):
        fail_with_prefix("test_optimization_sync", "absolute path contains unsupported control characters: %s" % repr(abs_path))

def _try_read_abs_file(ctx, abs_path):
    """Best-effort absolute file read with explicit miss/read-error signaling."""

    # Returns a status dict:
    # - ok: bool (read command succeeded)
    # - missing: bool (path does not exist)
    # - value: file content when ok
    # - error: diagnostic for non-missing failures
    if not abs_path:
        return {"ok": False, "missing": True, "value": "", "error": "empty path"}
    if _is_windows(ctx):
        exists_cmd = _build_windows_exists_abs_file_command(abs_path)
        exists_res = ctx.execute([
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            exists_cmd,
        ])
        if exists_res.return_code == 3:
            return {"ok": False, "missing": True, "value": "", "error": ""}
        if exists_res.return_code != 0:
            err = (exists_res.stderr or "").strip() or ("exists-check failed with exit code %d" % exists_res.return_code)
            log_info("warning: unable to check file '%s': %s" % (abs_path, err))
            return {"ok": False, "missing": False, "value": "", "error": err}

        ps_cmd = _build_windows_read_abs_file_command(abs_path)
        cmd = [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            ps_cmd,
        ]
        res = ctx.execute(cmd)
        if res.return_code == 0:
            return {"ok": True, "missing": False, "value": res.stdout or "", "error": ""}
        err = (res.stderr or "").strip() or ("file read failed with exit code %d" % res.return_code)
        log_info("warning: unable to read file '%s': %s" % (abs_path, err))
        return {"ok": False, "missing": False, "value": "", "error": err}
    else:
        exists_cmd = _build_unix_exists_abs_file_command(abs_path)
        exists_res = ctx.execute(["/bin/sh", "-c", exists_cmd])
        if exists_res.return_code == 3:
            return {"ok": False, "missing": True, "value": "", "error": ""}
        if exists_res.return_code != 0:
            err = (exists_res.stderr or "").strip() or ("exists-check failed with exit code %d" % exists_res.return_code)
            log_info("warning: unable to check file '%s': %s" % (abs_path, err))
            return {"ok": False, "missing": False, "value": "", "error": err}

        sh_cmd = _build_unix_read_abs_file_command(abs_path)
        res = ctx.execute(["/bin/sh", "-c", sh_cmd])
        if res.return_code == 0:
            return {"ok": True, "missing": False, "value": res.stdout or "", "error": ""}
        err = (res.stderr or "").strip() or ("file read failed with exit code %d" % res.return_code)
        log_info("warning: unable to read file '%s': %s" % (abs_path, err))
        return {"ok": False, "missing": False, "value": "", "error": err}

def _build_windows_exists_abs_file_command(abs_path):
    """Build PowerShell command string for absolute-file existence checks."""
    _validate_abs_path_command_input_or_fail(abs_path)
    return "$p = '%s'; if (Test-Path -LiteralPath $p -PathType Leaf) { exit 0 } else { exit 3 }" % _powershell_single_quote_literal(abs_path)

def _build_unix_exists_abs_file_command(abs_path):
    """Build POSIX shell command string for absolute-file existence checks."""
    _validate_abs_path_command_input_or_fail(abs_path)
    escaped = abs_path.replace("'", "'\\''")
    return "[ -f '" + escaped + "' ] || exit 3"

def _build_windows_read_abs_file_command(abs_path):
    """Build PowerShell command string for `_try_read_abs_file` reads."""
    _validate_abs_path_command_input_or_fail(abs_path)

    # Security note: single quotes are doubled for PowerShell literal strings.
    return "$p = '%s'; Get-Content -Raw -LiteralPath $p" % _powershell_single_quote_literal(abs_path)

def _build_unix_read_abs_file_command(abs_path):
    """Build shell command string for `_try_read_abs_file` reads."""
    _validate_abs_path_command_input_or_fail(abs_path)

    # Security note: single quotes are escaped using the POSIX '\'' pattern.
    # The escaping contract is covered by `read_abs_file_command_escaping_test`.
    escaped = abs_path.replace("'", "'\\''")
    return "cat '" + escaped + "'"

def _parse_go_module_path(go_mod_content):
    """Extract `module <path>` value from go.mod content."""

    # _parse_go_module_path: extract the module path from a go.mod content string.
    if not go_mod_content:
        return ""
    lines = go_mod_content.split("\n")
    for ln in lines:
        s = ln.strip()
        if not s or s.startswith("//"):
            continue
        if s.startswith("module ") or s.startswith("module\t"):
            rest = s[len("module"):].strip()

            # Trim optional quotes
            if len(rest) >= 2 and rest[0] == '"' and rest[-1] == '"':
                rest = rest[1:-1]
            return rest
    return ""

def _detect_go_module_path(ctx, debug):
    """Best-effort Go module path detection for export metadata.

    Precedence:
    1) `GO_MODULE_PATH` override
    2) go.mod in known CI workspace directories
    3) go.mod under git top-level directory
    """

    # _detect_go_module_path: best-effort detection of Go module path.
    # Precedence: GO_MODULE_PATH env > discover go.mod under known workspace envs > git toplevel go.mod
    mod_env = ctx.os.environ.get("GO_MODULE_PATH") or ""
    log_debug(debug, "go", "GO_MODULE_PATH env: %s" % (mod_env or "<unset>"))
    if mod_env:
        log_debug(debug, "go", "Using GO_MODULE_PATH from env")
        return mod_env

    # Candidate workspace roots
    candidates = []
    for k in [
        "CI_PROJECT_DIR",
        "GITHUB_WORKSPACE",
        "WORKSPACE",
        "BUILDKITE_BUILD_CHECKOUT_PATH",
        "TRAVIS_BUILD_DIR",
    ]:
        v = ctx.os.environ.get(k)
        if v and (v not in candidates):
            candidates.append(v)
    for root in candidates:
        go_mod_path = root.rstrip("/") + "/go.mod"
        log_debug(debug, "go", "Checking go.mod at: %s" % go_mod_path)
        read_result = _try_read_abs_file(ctx, go_mod_path)
        if read_result.get("ok"):
            content = read_result.get("value") or ""
            mp = _parse_go_module_path(content)
            if mp:
                log_debug(debug, "go", "Detected module path '%s' from %s" % (mp, go_mod_path))
                return mp

    # Fallback: try using git to find toplevel go.mod
    top = ""
    if _is_windows(ctx):
        r = ctx.execute(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "git rev-parse --show-toplevel"], timeout = 10)
    else:
        r = ctx.execute(["bash", "-c", "git rev-parse --show-toplevel"], timeout = 10)
    if r.return_code == 0 and r.stdout:
        top = r.stdout.strip()
    log_debug(debug, "go", "git toplevel: %s" % (top or "<unset>"))
    if top:
        go_mod_path = top.rstrip("/") + "/go.mod"
        log_debug(debug, "go", "Checking go.mod at: %s" % go_mod_path)
        read_result = _try_read_abs_file(ctx, go_mod_path)
        if read_result.get("ok"):
            content = read_result.get("value") or ""
            mp = _parse_go_module_path(content)
            if mp:
                log_debug(debug, "go", "Detected module path '%s' from %s" % (mp, go_mod_path))
                return mp
    log_debug(debug, "go", "Go module path not detected; returning empty")
    return ""

def _runtime_module_path_from_environ(environ, env_key):
    """Return a normalized runtime module path override from environment."""
    return (environ.get(env_key) or "").strip()

def _detect_runtime_module_path_from_env(ctx, debug, runtime_name, env_key):
    """Return runtime module path override from env for non-Go runtimes."""
    module_path = _runtime_module_path_from_environ(ctx.os.environ, env_key)
    log_debug(debug, runtime_name, "%s env: %s" % (env_key, module_path or "<unset>"))
    if module_path:
        log_debug(debug, runtime_name, "Using %s from env" % env_key)
    return module_path

def _split_json_payload_by_module(ctx, source_file, debug, module_key, output_filename, label_map = None):
    """Split one payload JSON map into per-module canonical files."""

    specs = []
    src_path = ctx.path(source_file)
    content = ctx.read(src_path)
    if not content or not content.strip():
        return specs

    # Decode and navigate to data.attributes.<module_key> (map: module -> content map)
    obj = _decode_json_object_or_fail(content, source_file)
    data_obj = obj.get("data")
    if not _is_dict(data_obj):
        data_obj = {}
    attrs_obj = data_obj.get("attributes")
    if not _is_dict(attrs_obj):
        attrs_obj = {}
    modules_obj = attrs_obj.get(module_key)
    if not _is_dict(modules_obj):
        modules_obj = {}
    if not _is_dict(modules_obj):
        return specs

    base_dir = _dirname(source_file)

    # Ensure deterministic ordering for reproducible BUILD content
    module_names = sorted([k for k in modules_obj.keys()])

    # Compute sanitized labels and deduplicate (or use provided mapping)
    if label_map:
        deduped_labels = [label_map.get(m) or sanitize_label_fragment(m) for m in module_names]
    else:
        raw_labels = [sanitize_label_fragment(m) for m in module_names]
        deduped_labels = dedup_keys(raw_labels)

    for i in range(len(module_names)):
        module_name = module_names[i]
        label = deduped_labels[i]
        module_content = modules_obj.get(module_name)

        # Guard against non-dict anomalies
        if not _is_dict(module_content):
            continue

        # Place per-module canonical-named file under a dedicated subdirectory to avoid collisions
        per_module_dir = ("%s/%s" % (base_dir, ("module_%s" % label))) if base_dir else ("module_%s" % label)
        out_file = per_module_dir + "/" + output_filename

        # Build a per-module JSON that preserves the full original shape
        # and only narrows data.attributes.<module_key> to the single module.
        new_obj = _clone_payload_with_detached_attributes(obj)
        data_obj2 = new_obj.get("data")
        if not _is_dict(data_obj2):
            data_obj2 = {}
            new_obj["data"] = data_obj2
        attrs_obj2 = data_obj2.get("attributes")
        if not _is_dict(attrs_obj2):
            attrs_obj2 = {}
            data_obj2["attributes"] = attrs_obj2
        attrs_obj2[module_key] = {module_name: module_content}
        mod_obj = new_obj

        _ensure_parent_directory(ctx, out_file, debug)
        ctx.file(out_file, json.encode(mod_obj) + "\n")
        log_debug(
            debug,
            "module",
            "Wrote per-module %s file '%s' for module '%s'" % (output_filename, out_file, module_name),
        )

        specs.append({
            "module": module_name,
            "label": label,
            "file": out_file,
        })

    return specs

def _split_known_tests_by_module(ctx, known_tests_file, debug, label_map = None):
    """Split aggregate known-tests payload into one file per module."""
    return _split_json_payload_by_module(
        ctx,
        known_tests_file,
        debug,
        module_key = "tests",
        output_filename = "known_tests.json",
        label_map = label_map,
    )

def _split_test_management_by_module(ctx, test_management_file, debug, label_map = None):
    """Split aggregate test-management payload into one file per module."""
    return _split_json_payload_by_module(
        ctx,
        test_management_file,
        debug,
        module_key = "modules",
        output_filename = "test_management.json",
        label_map = label_map,
    )

def _detect_os_info(ctx, debug):
    """Detect host OS platform/version/arch for request configuration tags."""

    # _detect_os_info: detect OS platform, version, and architecture using host tools.
    # Returns a dict with keys: platform, version, arch
    def _run(args):
        res = ctx.execute(args)
        return res.stdout.strip() if res.return_code == 0 and res.stdout else ""

    if _is_windows(ctx):
        platform = "windows"

        # Windows arch via environment variables
        arch = (
            ctx.os.environ.get("PROCESSOR_ARCHITECTURE") or
            ctx.os.environ.get("PROCESSOR_ARCHITEW6432") or
            "unknown"
        )
        version = ctx.os.environ.get("OS") or ""
        log_debug(debug, "os", "Detected OS → platform='%s', version='%s', arch='%s'" % (platform, version, arch))
        return {"platform": platform, "version": version, "arch": arch}

    raw_platform = _run(["uname", "-s"]) or ""
    raw_arch = _run(["uname", "-m"]) or ""
    raw_version = _run(["uname", "-r"]) or ""

    p = raw_platform.lower()
    if "darwin" in p or p == "macos" or p == "mac" or p == "osx":
        platform = "darwin"
    elif "linux" in p:
        platform = "linux"
    elif "mingw" in p or "msys" in p or "cygwin" in p or p.startswith("windows"):
        platform = "windows"
    else:
        platform = p or "unknown"

    arch = raw_arch or "unknown"
    version = raw_version or ""

    log_debug(debug, "os", "Detected OS → platform='%s', version='%s', arch='%s'" % (platform, version, arch))
    return {"platform": platform, "version": version, "arch": arch}

def _normalize_dd_site_or_fail(site_env):
    """Normalize DD_SITE-like input into a validated hostname."""

    site = (site_env or "").strip()
    if not site:
        return "datadoghq.com"

    # Accept full URLs for compatibility with existing caller behavior.
    if "://" in site:
        site = site.split("://", 1)[1]
    if "/" in site:
        site = site.split("/", 1)[0]
    if "?" in site:
        site = site.split("?", 1)[0]
    if "#" in site:
        site = site.split("#", 1)[0]

    if site.startswith("app."):
        site = site[len("app."):]
    if site.startswith("api."):
        site = site[len("api."):]

    site = site.lower()
    if not site:
        fail_with_prefix("test_optimization_sync", "DD_SITE resolved to an empty hostname: %s" % repr(site_env))
    if "@" in site:
        fail_with_prefix("test_optimization_sync", "DD_SITE must not include credentials/userinfo: %s" % repr(site_env))
    if ":" in site:
        fail_with_prefix("test_optimization_sync", "DD_SITE must be a hostname without an explicit port: %s" % repr(site_env))
    if site.startswith(".") or site.endswith(".") or ".." in site:
        fail_with_prefix("test_optimization_sync", "DD_SITE must be a valid hostname: %s" % repr(site_env))

    labels = site.split(".")
    for label in labels:
        if not label:
            fail_with_prefix("test_optimization_sync", "DD_SITE must be a valid hostname: %s" % repr(site_env))
        if label.startswith("-") or label.endswith("-"):
            fail_with_prefix("test_optimization_sync", "DD_SITE labels must not start/end with '-': %s" % repr(site_env))
        for i in range(len(label)):
            ch = label[i]
            is_alpha = (ch >= "a" and ch <= "z")
            is_num = (ch >= "0" and ch <= "9")
            if not (is_alpha or is_num or ch == "-"):
                fail_with_prefix("test_optimization_sync", "DD_SITE contains unsupported hostname character %s in %s" % (repr(ch), repr(site_env)))
    return site

def _compute_dd_api_base(site_env):
    """Normalize DD_SITE-like input into Datadog API base URL."""

    # _compute_dd_api_base: compute the base Datadog API URL from a site value.
    # - Input examples:
    #   site_env = "app.datadoghq.com"  -> returns https://api.datadoghq.com
    #   site_env = "datadoghq.eu"       -> returns https://api.datadoghq.eu
    #   site_env = None/""               -> returns https://api.datadoghq.com
    # - Rationale: users frequently set DD_SITE to app.*; Datadog APIs are under
    #   api.*. We normalize here for consistency.
    site = _normalize_dd_site_or_fail(site_env)
    return "https://api.%s" % site

def _resolve_dd_api_base(env_data, debug):
    """Resolve API base URL using override-first precedence."""

    # _resolve_dd_api_base: resolve API base URL from overrides or DD_SITE.
    override = env_data.get("dd_api_base") or ""
    if override:
        # Allow tests/dev to point sync requests at a mock server without changing DD_SITE.
        base = override.rstrip("/")
        log_debug(debug, "http", "DD_TEST_OPTIMIZATION_AGENTLESS_URL override set: %s" % _redact_url_userinfo(base))
        return base
    return _compute_dd_api_base(env_data.get("dd_site"))

def _resolve_dd_api_base_for_tests(dd_site, dd_api_base):
    """Test helper wrapper for API base resolution."""

    # Test helper to validate override behavior deterministically.
    env_data = {
        "dd_site": dd_site or "",
        "dd_api_base": dd_api_base or "",
    }
    return _resolve_dd_api_base(env_data, False)

def _redact_url_userinfo(url):
    """Remove URL userinfo to keep logs/errors free from credential leaks."""
    s = (url or "").strip()
    if not s:
        return ""
    scheme_idx = s.find("://")
    if scheme_idx < 0:
        return s
    auth_start = scheme_idx + 3
    end = len(s)
    for sep in ["/", "?", "#"]:
        idx = s.find(sep, auth_start)
        if idx >= 0 and idx < end:
            end = idx
    authority = s[auth_start:end]
    at_idx = -1
    for i in range(len(authority)):
        if authority[i] == "@":
            at_idx = i
    if at_idx < 0:
        return s
    return s[:auth_start] + authority[at_idx + 1:] + s[end:]

def _decode_json_object_or_fail(content, context):
    """Decode JSON and enforce top-level object with actionable failures."""

    # Parse API/file JSON with actionable guardrails for malformed responses.
    trimmed = (content or "").strip()
    if not trimmed:
        fail_with_prefix("test_optimization_sync", "%s response is empty; expected JSON object" % context)

    # Catch common non-JSON responses (HTML/text proxy errors) early.
    if not (trimmed.startswith("{") or trimmed.startswith("[")):
        sample = trimmed[:120].replace("\n", " ").replace("\r", " ")
        fail_with_prefix(
            "test_optimization_sync",
            (
                "%s response is not JSON (starts with: %s). " +
                "Check DD_SITE/DD_TEST_OPTIMIZATION_AGENTLESS_URL, credentials, and endpoint routing."
            ) % (context, repr(sample)),
        )

    obj = json.decode(trimmed)
    if not _is_dict(obj):
        fail_with_prefix("test_optimization_sync", "%s response must be a JSON object, got %s" % (context, type(obj)))
    return obj

def _parse_curl_time_ms(value):
    """Convert a curl-style seconds string into integer milliseconds."""
    text = (value or "").strip()
    if not text:
        return 0
    negative = text.startswith("-")
    if negative:
        text = text[1:]
    if "." in text:
        parts = text.split(".", 1)
        seconds_text = parts[0]
        frac_text = parts[1]
    else:
        seconds_text = text
        frac_text = ""
    seconds = int(seconds_text) if seconds_text else 0
    digits = ""
    for i in range(len(frac_text)):
        ch = frac_text[i]
        if ch < "0" or ch > "9":
            break
        digits += ch
    for _unused in [0, 1, 2]:
        if len(digits) >= 3:
            break
        digits += "0"
    millis = seconds * 1000
    if digits:
        millis += int(digits[:3])
    return -millis if negative else millis

def _parse_positive_int_or_zero(value):
    """Parse a positive integer string or return zero for blank input."""
    text = (value or "").strip()
    if not text:
        return 0
    return int(text)

def _new_telemetry_facts(service_name, runtime_name = "", env = ""):
    """Create the normalized sync telemetry facts document."""
    facts = {
        "schema_version": 1,
        "service_name": service_name or "",
        "counts": [],
        "distributions": [],
    }
    if runtime_name:
        facts["runtime_name"] = runtime_name
    if env:
        facts["env"] = env
    return facts

def _append_telemetry_count(doc, name, value = 1, tags = None):
    """Append one normalized count metric fact."""
    doc["counts"].append({
        "name": name,
        "value": value,
        "tags": list(tags or []),
    })

def _append_telemetry_distribution(doc, name, value, tags = None):
    """Append one normalized distribution metric fact."""
    doc["distributions"].append({
        "name": name,
        "value": value,
        "tags": list(tags or []),
    })

def _build_settings_response_tags(attrs_obj):
    """Build the combined settings-response tags used by dd-trace-go."""
    tags = []
    if attrs_obj.get("code_coverage") == True:
        tags.append("coverage_enabled")
    if attrs_obj.get("tests_skipping") == True:
        tags.append("itrskip_enabled")
    early_flake = attrs_obj.get("early_flake_detection")
    if _is_dict(early_flake) and early_flake.get("enabled") == True:
        tags.append("early_flake_detection_enabled:true")
    if attrs_obj.get("flaky_test_retries_enabled") == True:
        tags.append("flaky_test_retries_enabled:true")
    test_management = attrs_obj.get("test_management")
    if _is_dict(test_management) and test_management.get("enabled") == True:
        tags.append("test_management_enabled:true")
    return tags

def _count_known_tests_response_tests(known_tests_obj):
    """Count the total tests returned by the known-tests response."""
    data_obj = known_tests_obj.get("data")
    if not _is_dict(data_obj):
        return 0
    attrs_obj = data_obj.get("attributes")
    if not _is_dict(attrs_obj):
        return 0
    tests_obj = attrs_obj.get("tests")
    if not _is_dict(tests_obj):
        return 0
    total = 0
    for suites in tests_obj.values():
        if not _is_dict(suites):
            continue
        for tests in suites.values():
            if type(tests) != type([]):
                continue
            total += len(tests)
    return total

def _count_test_management_response_tests(test_management_obj):
    """Count the total tests returned by the test-management response."""
    data_obj = test_management_obj.get("data")
    if not _is_dict(data_obj):
        return 0
    attrs_obj = data_obj.get("attributes")
    if not _is_dict(attrs_obj):
        return 0
    modules_obj = attrs_obj.get("modules")
    if not _is_dict(modules_obj):
        return 0
    total = 0
    for module_obj in modules_obj.values():
        if not _is_dict(module_obj):
            continue
        suites_obj = module_obj.get("suites")
        if not _is_dict(suites_obj):
            continue
        for suite_obj in suites_obj.values():
            if not _is_dict(suite_obj):
                continue
            tests_obj = suite_obj.get("tests")
            if not _is_dict(tests_obj):
                continue
            total += len(tests_obj)
    return total

def _collect_known_tests_modules(ctx, known_tests_file):
    """Return sorted module names present in known_tests payload."""

    # _collect_known_tests_modules: list module names from known_tests.json
    kt_path = ctx.path(known_tests_file)
    content = ctx.read(kt_path)
    if not content or not content.strip():
        return []
    obj = _decode_json_object_or_fail(content, known_tests_file)
    data_obj = obj.get("data")
    if not _is_dict(data_obj):
        data_obj = {}
    attrs_obj = data_obj.get("attributes")
    if not _is_dict(attrs_obj):
        attrs_obj = {}
    tests_obj = attrs_obj.get("tests")
    if not _is_dict(tests_obj):
        tests_obj = {}
    if not _is_dict(tests_obj):
        return []
    modules = []
    for k in tests_obj.keys():
        if _is_dict(tests_obj.get(k)):
            modules.append(k)
    return sorted(modules)

def _collect_test_management_modules(ctx, test_management_file):
    """Return sorted module names present in test_management payload."""

    # _collect_test_management_modules: list module names from test_management.json
    tm_path = ctx.path(test_management_file)
    content = ctx.read(tm_path)
    if not content or not content.strip():
        return []
    obj = _decode_json_object_or_fail(content, test_management_file)
    data_obj = obj.get("data")
    if not _is_dict(data_obj):
        data_obj = {}
    attrs_obj = data_obj.get("attributes")
    if not _is_dict(attrs_obj):
        attrs_obj = {}
    modules_obj = attrs_obj.get("modules")
    if not _is_dict(modules_obj):
        modules_obj = {}
    if not _is_dict(modules_obj):
        return []
    modules = []
    for k in modules_obj.keys():
        if _is_dict(modules_obj.get(k)):
            modules.append(k)
    return sorted(modules)

def _build_module_label_map(known_modules, test_management_modules):
    """Build stable deduplicated module->label mapping across both features."""

    # _build_module_label_map: build a stable module->label mapping across the union.
    # This prevents cross-feature label collisions when modules sanitize to the same label.
    seen = {}
    all_modules = []
    for m in (known_modules or []):
        if not seen.get(m):
            seen[m] = True
            all_modules.append(m)
    for m in (test_management_modules or []):
        if not seen.get(m):
            seen[m] = True
            all_modules.append(m)
    all_modules = sorted(all_modules)
    raw_labels = [sanitize_label_fragment(m) for m in all_modules]
    deduped = dedup_keys(raw_labels)
    label_map = {}
    for i in range(len(all_modules)):
        label_map[all_modules[i]] = deduped[i]
    return label_map

# Public aliases for tests (avoid importing private symbols)
def _render_export_bzl(
        repo_name,
        service_name,
        labels,
        set_literal,
        go_module_path,
        sanitized_go_module_path,
        go_module_included,
        manifest_file,
        python_module_path = "",
        sanitized_python_module_path = "",
        python_module_included = False,
        java_module_path = "",
        sanitized_java_module_path = "",
        java_module_included = False,
        nodejs_module_path = "",
        sanitized_nodejs_module_path = "",
        nodejs_module_included = False,
        dotnet_module_path = "",
        sanitized_dotnet_module_path = "",
        dotnet_module_included = False,
        ruby_module_path = "",
        sanitized_ruby_module_path = "",
        ruby_module_included = False):
    """Render export.bzl content consumed by macros and BUILD files."""
    repo_name_lit = json.encode(repo_name or "")
    service_name_lit = json.encode(service_name or "")
    manifest_file_lit = json.encode(manifest_file or "")

    runtime_entries = []
    for runtime_name, module_path, sanitized_module_path, module_included in [
        ("go", go_module_path, sanitized_go_module_path, go_module_included),
        ("python", python_module_path, sanitized_python_module_path, python_module_included),
        ("java", java_module_path, sanitized_java_module_path, java_module_included),
        ("nodejs", nodejs_module_path, sanitized_nodejs_module_path, nodejs_module_included),
        ("dotnet", dotnet_module_path, sanitized_dotnet_module_path, dotnet_module_included),
        ("ruby", ruby_module_path, sanitized_ruby_module_path, ruby_module_included),
    ]:
        runtime_entries.append(
            "        \"%s\": {\n" % runtime_name +
            "            \"module_path\": %s,\n" % json.encode(module_path or "") +
            "            \"sanitized_module_path\": %s,\n" % json.encode(sanitized_module_path or "") +
            "            \"module_included\": %s,\n" % ("True" if module_included else "False") +
            "        },\n",
        )

    return (
        "# Generated by test_optimization_sync; unified exports for test optimization info\n" +
        "topt_data = {\n" +
        "    \"repo_name\": %s,\n" % repo_name_lit +
        "    \"service_name\": %s,\n" % service_name_lit +
        "    \"manifest_path\": %s,\n" % manifest_file_lit +
        "    \"labels\": %s,\n" % repr(labels) +
        "    \"set\": %s,\n" % set_literal +
        "    \"runtimes\": {\n" +
        "".join(runtime_entries) +
        "    },\n" +
        "}\n"
    )

def _render_module_runfiles_bzl(manifest_root):
    """Render helper rule exposing module payloads under manifest-rooted runfiles.

    Maintainers: keep runfile keys rooted under `manifest_root` so custom
    `out_dir` layouts remain consistent with `manifest_path`.
    """
    settings_rloc = "%s/cache/http/settings.json" % manifest_root
    manifest_rloc = "%s/manifest.txt" % manifest_root
    known_tests_rloc = "%s/cache/http/known_tests.json" % manifest_root
    test_management_rloc = "%s/cache/http/test_management.json" % manifest_root
    settings_rloc_lit = _bzl_string_literal(settings_rloc)
    manifest_rloc_lit = _bzl_string_literal(manifest_rloc)
    known_tests_rloc_lit = _bzl_string_literal(known_tests_rloc)
    test_management_rloc_lit = _bzl_string_literal(test_management_rloc)
    return (
        "def _topt_module_files_impl(ctx):\n" +
        "    syms = {}\n" +
        ("    syms[%s] = ctx.file.settings\n" % settings_rloc_lit) +
        ("    syms[%s] = ctx.file.manifest\n" % manifest_rloc_lit) +
        "    kt = getattr(ctx.file, \"known_tests\", None)\n" +
        "    if kt:\n" +
        ("        syms[%s] = kt\n" % known_tests_rloc_lit) +
        "    tm = getattr(ctx.file, \"test_management\", None)\n" +
        "    if tm:\n" +
        ("        syms[%s] = tm\n" % test_management_rloc_lit) +
        "    return DefaultInfo(runfiles = ctx.runfiles(symlinks = syms))\n" +
        "\n" +
        "topt_module_files = rule(\n" +
        "    implementation = _topt_module_files_impl,\n" +
        "    attrs = {\n" +
        "        \"settings\": attr.label(allow_single_file = True, mandatory = True),\n" +
        "        \"manifest\": attr.label(allow_single_file = True, mandatory = True),\n" +
        "        \"known_tests\": attr.label(allow_single_file = True),\n" +
        "        \"test_management\": attr.label(allow_single_file = True),\n" +
        "    },\n" +
        ")\n"
    )

def _partition_unix_headers(headers):
    """Split public headers from DD-API-KEY for secure Unix curl transport."""
    public_headers = {}
    dd_api_key = ""
    has_dd_api_key = False
    for header_key, header_value in headers.items():
        hk = str(header_key)
        hv = str(header_value)
        if hk.lower() == "dd-api-key":
            dd_api_key = hv
            has_dd_api_key = True
        else:
            public_headers[hk] = hv
    return {
        "public_headers": public_headers,
        "dd_api_key": dd_api_key,
        "has_dd_api_key": has_dd_api_key,
    }

def _record_sync_extension_repo_owner_or_fail(seen_repo_owners, repo_name, owner):
    """Record extension repo owner and fail on duplicate repository names."""
    prev_owner = seen_repo_owners.get(repo_name)
    if prev_owner != None:
        fail_with_prefix(
            "test_optimization_sync_extension",
            "duplicate repository name '%s' declared by modules '%s' and '%s'. Use unique names for each test_optimization_sync tag." %
            (repo_name, prev_owner, owner),
        )
    seen_repo_owners[repo_name] = owner

def _http_request(ctx, method, url, headers, out_file, debug, data_file = None, request_debug_payload = None, http_policy = None):
    """Execute cross-platform HTTP request and write response to `out_file`.

    Uses curl on Unix and Invoke-WebRequest on Windows with aligned timeout and
    retry behavior. Any transport error is raised with actionable context.
    """

    # _http_request: executes an HTTP call and writes response metadata plus
    # the response body to `out_file`.
    # - On Windows: uses PowerShell Invoke-WebRequest for portability.
    # - On Linux/macOS: uses curl with retries.
    # - Returns a metadata dict with HTTP status, duration, and byte count.
    #
    # Why this helper exists:
    # - repository_ctx has no native HTTP primitive with consistent behavior
    #   across all host platforms we support.
    # - We centralize retry/timeouts/error formatting here so callers can focus
    #   on request construction and response handling.
    #
    # Error-handling contract:
    # - Any non-zero tool return code triggers `fail(...)` with a message that
    #   includes method, URL, return code, response path, and request body
    #   context when available.
    # - Request-body text is appended as a plain `%s` argument to avoid format
    #   string hazards when payloads contain `%` characters.
    #
    # Security contract:
    # - Never print secrets directly. Headers are passed by callers; this
    #   function should only log method/URL and coarse status details.
    # Ensure output directory exists if a subdirectory is provided
    _ensure_parent_directory(ctx, out_file, debug)

    is_win = _is_windows(ctx)
    http_method = method or "GET"
    policy = http_policy if http_policy != None else _resolve_http_policy(ctx)
    redacted_url = _redact_url_userinfo(url)

    # Avoid logging secrets; only log method and URL
    log_info("http %s %s" % (http_method, redacted_url))

    if is_win:
        # Build a small PowerShell script to perform the request with basic retries.
        # We prefer a script file to avoid complex quoting issues.
        # Script writes response metadata to stdout on success.
        script_name = "_http_request_%s.ps1" % (out_file.replace("/", "_").replace("\\", "_") or "out")
        lines = []
        lines.append("$ErrorActionPreference = 'Stop'")
        lines.append("$ProgressPreference = 'SilentlyContinue'")
        lines.append("$Url = '%s'" % _powershell_single_quote_literal(url))
        lines.append("$OutFile = '%s'" % _powershell_single_quote_literal(out_file))
        lines.append("$Method = '%s'" % http_method)
        lines.append("$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()")

        # Headers hashtable (PowerShell expects IDictionary-like; hashtable is safest)
        lines.append("$Headers = @{}")
        ps_env = {}
        for hk, hv in headers.items():
            header_key = str(hk)
            header_value = str(hv)
            if header_key.lower() == "dd-api-key":
                # Keep API keys out of generated script files; inject at execute-time only.
                ps_env["DD_TEST_OPTIMIZATION_API_KEY"] = header_value
                lines.append("$apiKey = $env:DD_TEST_OPTIMIZATION_API_KEY")
                lines.append("if ([string]::IsNullOrEmpty($apiKey)) { Write-Error 'missing DD_TEST_OPTIMIZATION_API_KEY for DD-API-KEY header'; exit 2 }")
                lines.append("$Headers['%s'] = $apiKey" % _powershell_single_quote_literal(header_key))
            else:
                lines.append("$Headers['%s'] = '%s'" % (_powershell_single_quote_literal(header_key), _powershell_single_quote_literal(header_value)))

        # Optional body file
        if data_file:
            # Keep body on disk and pass `-InFile` to avoid quoting/encoding
            # drift for JSON payloads that may contain special characters.
            lines.append("$BodyFile = '%s'" % _powershell_single_quote_literal(data_file))
        lines.append("$max = %d; $attempt = 0" % policy["retry_attempts"])
        lines.append("while ($true) {")
        lines.append("  try {")
        if data_file:
            lines.append("    $resp = Invoke-WebRequest -Uri $Url -Headers $Headers -Method $Method -InFile $BodyFile -OutFile $OutFile -ContentType 'application/json' -TimeoutSec %d" % policy["max_time_seconds"])
        else:
            lines.append("    $resp = Invoke-WebRequest -Uri $Url -Headers $Headers -Method $Method -OutFile $OutFile -TimeoutSec %d" % policy["max_time_seconds"])

        # Emulate curl -f: treat HTTP >= 400 as failure
        lines.append("    $stopwatch.Stop()")
        lines.append("    $code = if ($resp.StatusCode) { [int]$resp.StatusCode } else { 200 }")
        lines.append("    if ($code -ge 400) { Write-Error ('HTTP {0} returned') -f $code; exit 1 }")
        lines.append("    $fileInfo = Get-Item -LiteralPath $OutFile")
        lines.append("    $size = if ($fileInfo) { [int64]$fileInfo.Length } else { 0 }")
        lines.append("    Write-Output ('http_status={0}' -f $code)")
        lines.append("    Write-Output ('duration_ms={0}' -f [int64]$stopwatch.ElapsedMilliseconds)")
        lines.append("    Write-Output ('response_bytes={0}' -f $size)")
        lines.append("    exit 0")
        lines.append("  } catch { if ($attempt -lt $max) { Start-Sleep -Seconds %d; $attempt = $attempt + 1 } else { Write-Error $_; exit 1 } }" % policy["retry_delay_seconds"])
        lines.append("}")
        script_content = "\n".join(lines) + "\n"
        ctx.file(script_name, script_content)
        if ps_env:
            result = ctx.execute(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script_name],
                environment = ps_env,
                timeout = policy["execute_timeout_seconds"],
            )
        else:
            result = ctx.execute(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script_name],
                timeout = policy["execute_timeout_seconds"],
            )
    else:
        # Unix path: keep curl invocation centralized and aligned with
        # `_curl_base_args()` so timeout/retry behavior stays consistent.
        args = [] + _curl_base_args(policy)
        if http_method and http_method != "GET":
            args.extend(["-X", http_method])
        split_headers = _partition_unix_headers(headers)
        for header_key, header_value in split_headers.get("public_headers", {}).items():
            args.extend(["-H", "%s: %s" % (header_key, header_value)])
        if data_file:
            args.extend(["--data-binary", "@%s" % data_file])
        args.extend([url, "-o", out_file, "-w", "http_status=%{http_code}\nduration_ms=%{time_total}\nresponse_bytes=%{size_download}\n"])
        if split_headers.get("has_dd_api_key"):
            # Provide DD-API-KEY via stdin (`-H @-`) to avoid exposing the raw
            # secret in process arguments.
            args_with_stdin_header = args + ["-H", "@-"]
            unix_env = {}
            for env_key, env_value in ctx.os.environ.items():
                unix_env[env_key] = env_value
            unix_env["DD_TEST_OPTIMIZATION_API_KEY"] = split_headers.get("dd_api_key") or ""

            result = ctx.execute(
                ["/bin/sh", "-c", "printf 'DD-API-KEY: %s\\n' \"$DD_TEST_OPTIMIZATION_API_KEY\" | curl \"$@\"", "curl"] + args_with_stdin_header[1:],
                environment = unix_env,
                timeout = policy["execute_timeout_seconds"],
            )
        else:
            result = ctx.execute(args, timeout = policy["execute_timeout_seconds"])

    # Parse response metadata captured by tool stdout. On network errors it may be empty.
    meta_lines = []
    for line in (result.stdout or "").splitlines():
        stripped = line.strip()
        if stripped:
            meta_lines.append(stripped)
    http_status = "000"
    duration_ms = 0
    response_bytes = 0
    for line in meta_lines:
        if line.startswith("http_status="):
            http_status = line[len("http_status="):]
        elif line.startswith("duration_ms="):
            duration_ms = _parse_curl_time_ms(line[len("duration_ms="):])
        elif line.startswith("response_bytes="):
            response_bytes = _parse_positive_int_or_zero(line[len("response_bytes="):])

    if not meta_lines and result.return_code == 0:
        http_status = "200"

    # Branch: network error or tool failure
    if result.return_code != 0:
        request_body = request_debug_payload if request_debug_payload else "<none>"
        if (not debug) and request_body != "<none>" and len(request_body) > 500:
            request_body = request_body[:500] + "...(truncated; enable debug for full body)"
        stderr_text = (result.stderr or "").strip()
        if stderr_text and url and (redacted_url != url):
            stderr_text = stderr_text.replace(url, redacted_url)

        # Include response file path in failures so developers can inspect
        # partial payloads produced by proxies/gateways.
        fail_with_prefix(
            "test_optimization_sync",
            "HTTP request failed (status=%s, method=%s, url=%s, code=%d). stderr=%s\nresponse_file=%s\nrequest_body=%s" %
            (
                http_status,
                http_method,
                redacted_url,
                result.return_code,
                stderr_text,
                out_file,
                request_body,
            ),
        )
    else:
        # Branch: success path; emit a concise size summary using captured metadata.
        if response_bytes > 0:
            log_info("Downloaded %s (%s bytes) from %s" % (out_file, response_bytes, redacted_url))
        else:
            log_info("Downloaded %s from %s" % (out_file, redacted_url))

        # Emit full response body when debug is enabled, similar to request logging
        if debug:
            try_body = ctx.read(ctx.path(out_file))
            if try_body != None:
                log_debug(
                    debug,
                    "http",
                    "HTTP response body (%s %s): %s" % (http_method, redacted_url, try_body),
                )

    return {
        "return_code": result.return_code,
        "http_status": http_status,
        "duration_ms": duration_ms,
        "response_bytes": response_bytes,
    }

def _http_post_json(ctx, url, headers, json_body_str, tmp_body_file, out_file, debug, http_policy = None):
    """POST JSON payload by delegating to `_http_request`."""

    # Write the request body to a temp file for curl --data-binary
    # Keeping body materialized improves debuggability when a request fails.
    ctx.file(tmp_body_file, json_body_str)

    # Merge content headers with caller-provided headers
    # Caller-provided keys overwrite defaults below when duplicated.
    merged_headers = {"Content-Type": "application/json", "Accept": "application/json"}
    for k, v in headers.items():
        merged_headers[k] = v

    # Delegate to generic HTTP execution helper
    return _http_request(
        ctx,
        "POST",
        url,
        merged_headers,
        out_file,
        debug,
        data_file = tmp_body_file,
        request_debug_payload = json_body_str,
        http_policy = http_policy,
    )

# Public aliases for tests (avoid importing private symbols)
compute_dd_api_base_for_tests = _compute_dd_api_base
resolve_dd_api_base_for_tests = _resolve_dd_api_base_for_tests
redact_url_userinfo_for_tests = _redact_url_userinfo
build_module_label_map_for_tests = _build_module_label_map
normalize_ref_for_tests = _normalize_ref
first_env_for_tests = _first_env
first_env_from_environ_for_tests = _first_env_from_environ
sanitize_repository_url_for_tests = _sanitize_repository_url
apply_dd_git_overrides_for_tests = _apply_dd_git_overrides
set_context_tag_from_env_for_tests = _set_context_tag_from_env
parse_go_module_path_for_tests = _parse_go_module_path
runtime_module_path_from_environ_for_tests = _runtime_module_path_from_environ
dirname_for_tests = _dirname
normalize_out_dir_or_fail_for_tests = _normalize_out_dir_or_fail
render_export_bzl_for_tests = _render_export_bzl
fnv1a_32_for_tests = _fnv1a_32
clone_payload_with_detached_attributes_for_tests = _clone_payload_with_detached_attributes
http_connect_timeout_seconds_for_tests = HTTP_CONNECT_TIMEOUT_SECONDS
http_max_time_seconds_for_tests = HTTP_MAX_TIME_SECONDS
http_retry_attempts_for_tests = HTTP_RETRY_ATTEMPTS
http_retry_delay_seconds_for_tests = HTTP_RETRY_DELAY_SECONDS
http_execute_timeout_buffer_seconds_for_tests = HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS
http_execute_timeout_seconds_for_tests = HTTP_EXECUTE_TIMEOUT_SECONDS
decode_json_object_or_fail_for_tests = _decode_json_object_or_fail
collect_known_tests_modules_for_tests = _collect_known_tests_modules
collect_test_management_modules_for_tests = _collect_test_management_modules
partition_unix_headers_for_tests = _partition_unix_headers
record_sync_extension_repo_owner_or_fail_for_tests = _record_sync_extension_repo_owner_or_fail
render_module_runfiles_bzl_for_tests = _render_module_runfiles_bzl
parse_curl_time_ms_for_tests = _parse_curl_time_ms
new_telemetry_facts_for_tests = _new_telemetry_facts
append_telemetry_count_for_tests = _append_telemetry_count
append_telemetry_distribution_for_tests = _append_telemetry_distribution
build_settings_response_tags_for_tests = _build_settings_response_tags
count_known_tests_response_tests_for_tests = _count_known_tests_response_tests
count_test_management_response_tests_for_tests = _count_test_management_response_tests

# ##########################################################################
# CI environment detection
# ##########################################################################

def _load_github_event_payload(ctx):
    """Best-effort load the GitHub Actions event payload JSON text."""
    event_path = ctx.os.environ.get("GITHUB_EVENT_PATH") or ""
    if not event_path:
        return None
    read_result = _try_read_abs_file(ctx, event_path)
    if not read_result.get("ok"):
        return None
    content = (read_result.get("value") or "").strip()
    if not content:
        return None
    return content

def _collect_env(ctx):
    """Collect CI/git/service context into a normalized metadata dict."""
    return _collect_env_from_environ(
        ctx.os.environ,
        getattr(ctx.attr, "service", None),
        _load_github_event_payload(ctx),
    )

# Public aliases for tests (helpers defined after the first alias section).
collect_env_for_tests = _collect_env
collect_env_from_environ_for_tests = _collect_env_from_environ
load_github_event_payload_for_tests = _load_github_event_payload
build_windows_read_abs_file_command_for_tests = _build_windows_read_abs_file_command
build_unix_read_abs_file_command_for_tests = _build_unix_read_abs_file_command
apply_github_event_payload_for_tests = _apply_github_event_payload
all_sync_env_keys_for_tests = _ALL_SYNC_ENV_KEYS

def _build_configurations_json(ctx, debug, osinfo = None):
    """Build Datadog `configurations` payload from OS/runtime attributes."""

    # _build_configurations_json: builds a testConfigurations structure with
    # auto-detected os.* fields plus simple runtime fields.
    #
    # Note: runtime name and runtime version have different semantics. Keep
    # dedicated validators so future constraints can evolve independently.
    if osinfo == None:
        osinfo = _detect_os_info(ctx, debug)
    runtime_name = validate_runtime_name(ctx.attr.runtime_name, debug) or "unknown"
    runtime_version = validate_runtime_version(ctx.attr.runtime_version, debug) or "unknown"

    # Explicit runtime_arch override wins; otherwise inherit detected host arch.
    runtime_arch = ctx.attr.runtime_arch or osinfo["arch"]

    # Build configuration object using json.encode for proper escaping
    conf = {
        "os.platform": osinfo["platform"],
        "os.version": osinfo["version"],
        "os.architecture": osinfo["arch"],
        "runtime.name": runtime_name,
        "runtime.architecture": runtime_arch,
        "runtime.version": runtime_version,
    }
    conf_json = json.encode(conf)
    log_debug(debug, "config", "Configurations JSON: %s" % conf_json)
    return conf_json

def _build_context_tags(ctx, env_data, api_key, debug, osinfo = None):
    """Build non-secret context tags stored in generated `context.json`."""

    # _build_context_tags: aggregates CI, git, OS, and runtime tags for context.json
    tags = {}

    # OS tags
    if osinfo == None:
        osinfo = _detect_os_info(ctx, debug)
    if osinfo.get("platform"):
        tags["os.platform"] = osinfo.get("platform")
    if osinfo.get("version"):
        tags["os.version"] = osinfo.get("version")
    if osinfo.get("arch"):
        tags["os.architecture"] = osinfo.get("arch")

    # Runtime tags
    if ctx.attr.runtime_name:
        tags["runtime.name"] = ctx.attr.runtime_name
    if ctx.attr.runtime_version:
        tags["runtime.version"] = ctx.attr.runtime_version
    if ctx.attr.runtime_arch:
        tags["runtime.architecture"] = ctx.attr.runtime_arch

    # Bazel rules identity tags (stable constants for this ruleset).
    tags["test.bazel.rule_name"] = TEST_BAZEL_RULE_NAME
    tags["test.bazel.rule_version"] = TEST_BAZEL_RULE_VERSION

    # Git tags
    if env_data.get("repository_url"):
        tags["git.repository_url"] = env_data.get("repository_url")
    if env_data.get("branch"):
        tags["git.branch"] = env_data.get("branch")
    if env_data.get("tag"):
        tags["git.tag"] = env_data.get("tag")
    if env_data.get("sha"):
        tags["git.commit.sha"] = env_data.get("sha")
    if env_data.get("head_sha"):
        tags["git.commit.head.sha"] = env_data.get("head_sha")
    if env_data.get("commit_message"):
        tags["git.commit.message"] = env_data.get("commit_message")
    if env_data.get("head_message"):
        tags["git.commit.head.message"] = env_data.get("head_message")
    if env_data.get("commit_author_name"):
        tags["git.commit.author.name"] = env_data.get("commit_author_name")
    if env_data.get("commit_author_email"):
        tags["git.commit.author.email"] = env_data.get("commit_author_email")
    if env_data.get("commit_author_date"):
        tags["git.commit.author.date"] = env_data.get("commit_author_date")
    if env_data.get("commit_committer_name"):
        tags["git.commit.committer.name"] = env_data.get("commit_committer_name")
    if env_data.get("commit_committer_email"):
        tags["git.commit.committer.email"] = env_data.get("commit_committer_email")
    if env_data.get("commit_committer_date"):
        tags["git.commit.committer.date"] = env_data.get("commit_committer_date")
    if env_data.get("head_author_name"):
        tags["git.commit.head.author.name"] = env_data.get("head_author_name")
    if env_data.get("head_author_email"):
        tags["git.commit.head.author.email"] = env_data.get("head_author_email")
    if env_data.get("head_author_date"):
        tags["git.commit.head.author.date"] = env_data.get("head_author_date")
    if env_data.get("head_committer_name"):
        tags["git.commit.head.committer.name"] = env_data.get("head_committer_name")
    if env_data.get("head_committer_email"):
        tags["git.commit.head.committer.email"] = env_data.get("head_committer_email")
    if env_data.get("head_committer_date"):
        tags["git.commit.head.committer.date"] = env_data.get("head_committer_date")
    if env_data.get("pr_base_branch"):
        tags["git.pull_request.base_branch"] = env_data.get("pr_base_branch")
    if env_data.get("pr_base_branch_sha"):
        tags["git.pull_request.base_branch_sha"] = env_data.get("pr_base_branch_sha")
    if env_data.get("pr_base_branch_head_sha"):
        tags["git.pull_request.base_branch_head_sha"] = env_data.get("pr_base_branch_head_sha")
    if env_data.get("pr_number"):
        tags["pr.number"] = env_data.get("pr_number")

    # CI provider/name
    if env_data.get("ci_provider_name"):
        tags["ci.provider.name"] = env_data.get("ci_provider_name")

    # Service and environment (non-secret)
    if env_data.get("service"):
        tags["service.name"] = env_data.get("service")
    if env_data.get("environment"):
        tags["env"] = env_data.get("environment")

    if env_data.get("ci_workspace_path"):
        tags["ci.workspace_path"] = env_data.get("ci_workspace_path")
    if env_data.get("ci_pipeline_id"):
        tags["ci.pipeline.id"] = env_data.get("ci_pipeline_id")
    if env_data.get("ci_pipeline_number"):
        tags["ci.pipeline.number"] = env_data.get("ci_pipeline_number")
    if env_data.get("ci_pipeline_url"):
        tags["ci.pipeline.url"] = env_data.get("ci_pipeline_url")
    if env_data.get("ci_pipeline_name"):
        tags["ci.pipeline.name"] = env_data.get("ci_pipeline_name")
    if env_data.get("ci_job_id"):
        tags["ci.job.id"] = env_data.get("ci_job_id")
    if env_data.get("ci_job_name"):
        tags["ci.job.name"] = env_data.get("ci_job_name")
    if env_data.get("ci_job_url"):
        tags["ci.job.url"] = env_data.get("ci_job_url")
    if env_data.get("ci_stage_name"):
        tags["ci.stage.name"] = env_data.get("ci_stage_name")
    if env_data.get("ci_node_name"):
        tags["ci.node.name"] = env_data.get("ci_node_name")
    if env_data.get("ci_node_labels"):
        tags["ci.node.labels"] = env_data.get("ci_node_labels")
    if env_data.get("ci_env_vars_json"):
        tags["ci.env_vars"] = env_data.get("ci_env_vars_json")

    # Embed a non-reversible fingerprint to validate uploader key parity.
    # This is intentionally low-entropy/non-secret metadata that lets tests
    # assert sync/uploader key consistency without exposing raw credentials.
    fingerprint = _api_key_fingerprint(api_key)
    if fingerprint:
        tags["topt.api_key_fingerprint"] = fingerprint
        log_debug(debug, "context", "api key fingerprint enabled")

    log_debug(debug, "context", "context.json tags: %s" % json.encode(tags))
    return tags

# ##########################################################################
# Request builders
# ##########################################################################

def _perform_dd_settings_request(ctx, api_key, env_data, settings_file, debug, http_policy = None):
    """Build and execute CI Visibility settings request."""

    # _perform_dd_settings_request: build and send the CI Visibility Settings request.
    # - Writes the JSON response body to `settings_file`.
    # - Returns structured response metadata for telemetry reconstruction.
    # Datadog CI Visibility settings endpoint
    # Path: api/v2/libraries/tests/services/setting
    # Type: ci_app_test_service_libraries_settings
    base = _resolve_dd_api_base(env_data, debug)
    url = "%s/%s" % (base, "api/v2/libraries/tests/services/setting")

    # Gather request attributes from environment
    service = env_data.get("service")
    environment = env_data.get("environment")
    repository_url = env_data.get("repository_url")

    # Settings endpoint uses branch+sha pair; head_sha is not required here.
    branch = env_data.get("branch")
    sha = env_data.get("sha")

    # Debug print of the resolved attributes for traceability
    log_debug(
        debug,
        "http",
        "Settings attributes → service='%s', env='%s', repo='%s', branch='%s', sha='%s'" % (
            service,
            environment,
            repository_url,
            branch,
            sha,
        ),
    )

    # Build request payload using json.encode for proper escaping
    payload = {
        "data": {
            "id": "1",
            "type": "ci_app_test_service_libraries_settings",
            "attributes": {
                "service": service,
                "env": environment,
                "repository_url": repository_url,
                "branch": branch,
                "sha": sha,
            },
        },
    }
    body = json.encode(payload)

    log_debug(debug, "http", "Settings request body: %s" % body)

    headers = {
        "DD-API-KEY": api_key,
    }

    return _http_post_json(
        ctx,
        url,
        headers,
        body,
        "settings.request.json",
        settings_file,
        debug,
        http_policy = http_policy,
    )

def _perform_dd_known_tests_request(ctx, api_key, env_data, known_tests_file, debug, osinfo = None, http_policy = None):
    """Build and execute CI Visibility known-tests request."""

    # _perform_dd_known_tests_request: build and send the Known Tests request.
    # - Writes the JSON response body to `known_tests_file`.
    # - Returns structured response metadata for telemetry reconstruction.
    # Datadog Known Tests endpoint
    # Path: api/v2/ci/libraries/tests
    # Type: ci_app_libraries_tests_request
    base = _resolve_dd_api_base(env_data, debug)
    url = "%s/%s" % (base, "api/v2/ci/libraries/tests")

    # Same attributes as settings request
    service = env_data.get("service")
    environment = env_data.get("environment")
    repository_url = env_data.get("repository_url")

    # Configurations is a JSON object, decode it to embed properly
    # Keep this decode explicit to avoid double-encoding nested JSON payloads.
    configurations_json = _build_configurations_json(ctx, debug, osinfo = osinfo)
    configurations = json.decode(configurations_json)

    # Build request payload using json.encode for proper escaping
    payload = {
        "data": {
            "id": "1",
            "type": "ci_app_libraries_tests_request",
            "attributes": {
                "service": service,
                "env": environment,
                "repository_url": repository_url,
                "configurations": configurations,
            },
        },
    }
    body = json.encode(payload)

    # Log the request body for debugging when enabled
    log_debug(debug, "http", "KnownTests request body: %s" % body)

    headers = {
        "DD-API-KEY": api_key,
    }

    return _http_post_json(
        ctx,
        url,
        headers,
        body,
        "known_tests.request.json",
        known_tests_file,
        debug,
        http_policy = http_policy,
    )

def _perform_dd_test_management_tests_request(ctx, api_key, env_data, test_management_file, debug, http_policy = None):
    """Build and execute CI Visibility test-management request."""

    # _perform_dd_test_management_tests_request: build and send the Test Management Tests request.
    # - Writes the JSON response body to `test_management_file`.
    # - Returns structured response metadata for telemetry reconstruction.
    # Datadog Test Management Tests endpoint
    # Path: api/v2/test/libraries/test-management/tests
    # Type: ci_app_libraries_tests_request
    base = _resolve_dd_api_base(env_data, debug)
    url = "%s/%s" % (base, "api/v2/test/libraries/test-management/tests")

    # Required attributes per API
    repository_url = env_data.get("repository_url")

    # Prefer head commit if present; else fall back
    # This mirrors PR/MR pipelines where head SHA can differ from merge SHA.
    sha = env_data.get("head_sha") or env_data.get("sha") or ""

    # Commit message: prefer head message then commit message; else empty
    # Head message improves change attribution for branch-tip evaluation.
    commit_message = env_data.get("head_message") or env_data.get("commit_message") or ""

    # Build request payload using json.encode for proper escaping
    payload = {
        "data": {
            "id": "1",
            "type": "ci_app_libraries_tests_request",
            "attributes": {
                "repository_url": repository_url,
                "sha": sha,
                "commit_message": commit_message,
            },
        },
    }
    body = json.encode(payload)

    log_debug(debug, "http", "TestManagementTests request body: %s" % body)

    headers = {"DD-API-KEY": api_key}

    return _http_post_json(
        ctx,
        url,
        headers,
        body,
        "test_management.request.json",
        test_management_file,
        debug,
        http_policy = http_policy,
    )

# ##########################################################################
# Repository rule implementation
# ##########################################################################

def _impl(ctx):
    """Repository rule orchestration entrypoint.

    Maintainers: treat this function as a phase coordinator. Keep cross-cutting
    logic in helpers above so unit tests can validate behavior without executing
    the full repository rule.
    """

    # _impl: repository_rule entrypoint orchestrating the full flow.
    # Steps:
    # 1) Validate required env and log cache-busting inputs for traceability
    # 2) Ensure parent directories exist for declared outputs
    # 3) POST Settings and write `settings_file`
    # 4) Parse settings to read data.attributes.known_tests_enabled
    # 5) If enabled, POST Known Tests and write `known_tests_file` (known_tests.json); else write an empty stub
    # 6) Emit a BUILD file exporting both outputs
    #
    # Implementation notes for maintainers:
    # - Keep this function mostly orchestration; move reusable logic into
    #   helpers so tests can target behavior in isolation.
    # - Any new environment-driven behavior must be declared in `environ`
    #   on the repository_rule to keep Bazel cache keys correct.
    # - When adding new generated files, preserve deterministic ordering and
    #   stable public labels to avoid downstream breakage.
    debug = ctx.attr.debug
    log_info("Starting repository rule implementation")
    ctx.report_progress("test_optimization_sync: starting")

    # ------------------------------------------------------------------
    # Phase 1: Resolve/validate required inputs and output paths.
    # ------------------------------------------------------------------
    # Validate DD_API_KEY from the environment; fail with helpful message if missing
    api_key = ctx.os.environ.get("DD_API_KEY")
    log_debug(debug, "validation", "DD_API_KEY present: %s" % bool(api_key))
    api_key = validate_api_key(api_key)

    # Emit salt info if present to trace cache-busting input
    salt = ctx.os.environ.get("FETCH_SALT")
    log_info("FETCH_SALT: %s" % (salt if salt else "<unset>"))

    # Git-related inputs (optional) to influence repository cache key
    git_dirty = ctx.os.environ.get("GIT_DIRTY")
    log_info("GIT_DIRTY: %s" % (git_dirty if git_dirty else "<unset>"))

    # Perform the settings request (compute and ensure directories exist for outputs)
    out_dir = _normalize_out_dir_or_fail(ctx.attr.out_dir or TEST_OPT_DIR)
    settings_file = "%s/%s" % (out_dir, "cache/http/settings.json")
    known_tests_file = "%s/%s" % (out_dir, "cache/http/known_tests.json")
    test_management_file = "%s/%s" % (out_dir, "cache/http/test_management.json")
    manifest_file = "%s/%s" % (out_dir, "manifest.txt")
    context_file = "%s/%s" % (out_dir, "context.json")
    telemetry_facts_file = "%s/%s" % (out_dir, "telemetry_facts.json")
    _ensure_parent_directory(ctx, settings_file, debug)
    _ensure_parent_directory(ctx, known_tests_file, debug)
    _ensure_parent_directory(ctx, test_management_file, debug)
    _ensure_parent_directory(ctx, manifest_file, debug)
    _ensure_parent_directory(ctx, context_file, debug)
    _ensure_parent_directory(ctx, telemetry_facts_file, debug)

    log_info("Settings file: %s" % settings_file)
    ctx.report_progress("test_optimization_sync: downloading")
    env_data = _collect_env(ctx)

    # Validate and normalize service name
    raw_service = env_data.get("service")
    validated_service = validate_service_name(raw_service, debug)
    env_data["service"] = validated_service

    log_debug(debug, "validation", "Env data collected and validated")

    runtime_name = validate_runtime_name(ctx.attr.runtime_name, debug) or ""
    telemetry_facts = _new_telemetry_facts(
        validated_service,
        runtime_name = runtime_name,
        env = env_data.get("environment") or "",
    )

    # Cache per-run expensive helpers and pass them through request/tag builders.
    http_policy = _resolve_http_policy(ctx)
    osinfo = _detect_os_info(ctx, debug)
    settings_result = _perform_dd_settings_request(ctx, api_key, env_data, settings_file, debug, http_policy = http_policy)
    ctx.report_progress("test_optimization_sync: download complete")

    # ------------------------------------------------------------------
    # Phase 2: Parse settings and determine feature enablement.
    # ------------------------------------------------------------------
    # Decide whether to fetch known tests/test-management based on settings (use repository_ctx.read + json.decode)
    # Additionally, support local kill-switches exposed as rule attributes to force-disable
    # any of these features regardless of server-side configuration.
    known_tests_enabled = False

    test_management_enabled = False
    settings_path = ctx.path(settings_file)
    settings_content = ctx.read(settings_path)
    settings_obj = _decode_json_object_or_fail(settings_content, settings_file)
    data_obj = settings_obj.get("data")
    if not _is_dict(data_obj):
        data_obj = {}
    attrs_obj = data_obj.get("attributes")
    if not _is_dict(attrs_obj):
        attrs_obj = {}
    enabled_val = attrs_obj.get("known_tests_enabled")
    known_tests_enabled = (enabled_val == True)

    tm_obj = attrs_obj.get("test_management")
    if not _is_dict(tm_obj):
        tm_obj = {}
    test_management_enabled = (tm_obj.get("enabled") == True)
    log_debug(debug, "settings", "known_tests_enabled parsed as: %s" % known_tests_enabled)

    log_debug(debug, "settings", "test_management.enabled parsed as: %s" % test_management_enabled)

    # ------------------------------------------------------------------
    # Kill-switch overrides
    # ------------------------------------------------------------------
    # If any kill-switch is set to False via rule attributes, we:
    # 1) Force the local enablement variable to False to prevent the HTTP
    #    request for that feature.
    # 2) Mutate the downloaded settings JSON to reflect the override so
    #    any downstream consumer that reads the settings file will observe
    #    the feature as disabled as well.
    #
    # All three kill-switch attributes default to True, which preserves the
    # server-provided behavior when not explicitly set by the user.
    if hasattr(ctx.attr, "known_tests") and ctx.attr.known_tests == False:
        known_tests_enabled = False

        # Ensure attributes dict exists and update the flag
        if not _is_dict(settings_obj.get("data")):
            settings_obj["data"] = {"attributes": {}}
            data_obj = settings_obj["data"]
            attrs_obj = data_obj["attributes"]
        elif ("attributes" not in settings_obj["data"]) or (not _is_dict(settings_obj["data"].get("attributes"))):
            data_obj["attributes"] = {}
            attrs_obj = data_obj["attributes"]

        # Persist explicit disablement so downstream consumers relying on
        # settings.json (instead of rule attrs) see the same effective state.
        attrs_obj["known_tests_enabled"] = False

    if hasattr(ctx.attr, "test_management") and ctx.attr.test_management == False:
        test_management_enabled = False
        if not _is_dict(settings_obj.get("data")):
            settings_obj["data"] = {"attributes": {}}
            data_obj = settings_obj["data"]
            attrs_obj = data_obj["attributes"]
        elif ("attributes" not in settings_obj["data"]) or (not _is_dict(settings_obj["data"].get("attributes"))):
            data_obj["attributes"] = {}
            attrs_obj = data_obj["attributes"]

        # Ensure nested test_management object exists and set enabled=false
        tm_mut = attrs_obj.get("test_management")
        if not _is_dict(tm_mut):
            tm_mut = {}

        # Mirror settings API shape: `test_management` is nested object.
        tm_mut["enabled"] = False
        attrs_obj["test_management"] = tm_mut

    # Persist the possibly-updated settings back to disk so that the
    # overridden disablement is reflected to later phases.
    ctx.file(settings_file, json.encode(settings_obj) + "\n")

    # Sync telemetry facts are only materialized for requests that completed
    # successfully enough for repository generation to continue. A hard fetch
    # failure still aborts repo resolution before the uploader can replay any
    # stored facts, so request-error restoration remains a follow-up concern.
    _append_telemetry_count(telemetry_facts, "git_requests.settings")
    _append_telemetry_distribution(telemetry_facts, "git_requests.settings_ms", settings_result.get("duration_ms", 0))
    _append_telemetry_count(
        telemetry_facts,
        "git_requests.settings_response",
        tags = _build_settings_response_tags(attrs_obj),
    )

    # ------------------------------------------------------------------
    # Phase 3: Materialize primary payload files (real fetches or stubs).
    # ------------------------------------------------------------------
    # Always produce known tests and test-management files; write empty stubs when disabled
    # Write manifest version (v1) to manifest.txt for change tracking
    ctx.file(manifest_file, "version=1\n")

    exports = [settings_file, manifest_file]
    module_specs_known = []
    module_specs_tm = []
    if known_tests_enabled:
        ctx.report_progress("test_optimization_sync: downloading known tests")
        known_tests_result = _perform_dd_known_tests_request(
            ctx,
            api_key,
            env_data,
            known_tests_file,
            debug,
            osinfo = osinfo,
            http_policy = http_policy,
        )
        ctx.report_progress("test_optimization_sync: known tests complete")
        known_tests_obj = _decode_json_object_or_fail(ctx.read(ctx.path(known_tests_file)), known_tests_file)
        _append_telemetry_count(telemetry_facts, "known_tests.request")
        _append_telemetry_distribution(telemetry_facts, "known_tests.request_ms", known_tests_result.get("duration_ms", 0))
        _append_telemetry_distribution(telemetry_facts, "known_tests.response_bytes", known_tests_result.get("response_bytes", 0))
        _append_telemetry_distribution(telemetry_facts, "known_tests.response_tests", _count_known_tests_response_tests(known_tests_obj))
    else:
        log_debug(debug, "known_tests", "known_tests_enabled is false; writing empty known tests file")

        # Minimal valid JSON structure
        # Keep canonical envelope shape so downstream code can parse uniformly.
        ctx.file(known_tests_file, '{"data": {"attributes": {"tests": {}}}}\n')

    # Always add known_tests.json to exports (either real data or stub)
    exports.append(known_tests_file)

    if test_management_enabled:
        ctx.report_progress("test_optimization_sync: downloading test management tests")
        test_management_result = _perform_dd_test_management_tests_request(
            ctx,
            api_key,
            env_data,
            test_management_file,
            debug,
            http_policy = http_policy,
        )
        ctx.report_progress("test_optimization_sync: test management tests complete")
        test_management_obj = _decode_json_object_or_fail(ctx.read(ctx.path(test_management_file)), test_management_file)
        _append_telemetry_count(telemetry_facts, "test_management_tests.request")
        _append_telemetry_distribution(telemetry_facts, "test_management_tests.request_ms", test_management_result.get("duration_ms", 0))
        _append_telemetry_distribution(telemetry_facts, "test_management_tests.response_bytes", test_management_result.get("response_bytes", 0))
        _append_telemetry_distribution(
            telemetry_facts,
            "test_management_tests.response_tests",
            _count_test_management_response_tests(test_management_obj),
        )
    else:
        log_debug(debug, "test_management", "test_management.enabled is false; writing empty test management tests file")

        # Minimal valid JSON structure for test management tests
        # Keep canonical envelope shape so module splitting logic can run.
        ctx.file(test_management_file, '{"data": {"attributes": {"modules": {}}}}\n')

    # Always add test_management.json to exports (either real data or stub)
    exports.append(test_management_file)

    # ------------------------------------------------------------------
    # Phase 4: Derive per-module splits and context metadata.
    # ------------------------------------------------------------------
    # Build unified module label mapping to avoid cross-feature collisions
    known_modules = _collect_known_tests_modules(ctx, known_tests_file)
    tm_modules = _collect_test_management_modules(ctx, test_management_file)
    label_map = _build_module_label_map(known_modules, tm_modules)

    # Split known tests and test management by module into dedicated files
    module_specs_known = _split_known_tests_by_module(ctx, known_tests_file, debug, label_map = label_map)
    module_specs_tm = _split_test_management_by_module(ctx, test_management_file, debug, label_map = label_map)

    # Build and write context.json (non-secret metadata) under `out_dir`
    # so all manifest-relative payload files share a single root.
    context_tags = _build_context_tags(ctx, env_data, api_key, debug, osinfo = osinfo)
    ctx.file(context_file, json.encode(context_tags) + "\n")
    ctx.file(telemetry_facts_file, json.encode(telemetry_facts) + "\n")

    # Emit helper runtime metadata for downstream macros.
    go_module_path = _detect_go_module_path(ctx, debug)
    sanitized_go_module_path = sanitize_label_fragment(go_module_path) if go_module_path else ""
    python_module_path = _detect_runtime_module_path_from_env(ctx, debug, "python", "PYTHON_MODULE_PATH")
    sanitized_python_module_path = sanitize_label_fragment(python_module_path) if python_module_path else ""
    java_module_path = _detect_runtime_module_path_from_env(ctx, debug, "java", "JAVA_MODULE_PATH")
    sanitized_java_module_path = sanitize_label_fragment(java_module_path) if java_module_path else ""
    nodejs_module_path = _detect_runtime_module_path_from_env(ctx, debug, "nodejs", "NODEJS_MODULE_PATH")
    sanitized_nodejs_module_path = sanitize_label_fragment(nodejs_module_path) if nodejs_module_path else ""
    dotnet_module_path = _detect_runtime_module_path_from_env(ctx, debug, "dotnet", "DOTNET_MODULE_PATH")
    sanitized_dotnet_module_path = sanitize_label_fragment(dotnet_module_path) if dotnet_module_path else ""
    ruby_module_path = _detect_runtime_module_path_from_env(ctx, debug, "ruby", "RUBY_MODULE_PATH")
    sanitized_ruby_module_path = sanitize_label_fragment(ruby_module_path) if ruby_module_path else ""

    # Build a modules index for per-module filegroups (labels are sanitized suffixes)
    labels = sorted([v for v in label_map.values()]) if label_map else []
    label_seen = {}
    for _lab in labels:
        label_seen[_lab] = True

    # Emit modules_index.bzl with both a list and a set-like dict for membership checks
    entries = []
    for _lab in labels:
        entries.append('"%s": True' % _lab)
    set_literal = "{" + (", ".join(entries)) + "}"

    # Compute whether the detected go module is included in the per-module set
    go_module_included = False
    if sanitized_go_module_path:
        if label_seen.get(sanitized_go_module_path):
            # This flag is consumed by fallback macro path selection logic.
            go_module_included = True
    python_module_included = False
    if sanitized_python_module_path:
        if label_seen.get(sanitized_python_module_path):
            python_module_included = True
    java_module_included = False
    if sanitized_java_module_path:
        if label_seen.get(sanitized_java_module_path):
            java_module_included = True
    nodejs_module_included = False
    if sanitized_nodejs_module_path:
        if label_seen.get(sanitized_nodejs_module_path):
            nodejs_module_included = True
    dotnet_module_included = False
    if sanitized_dotnet_module_path:
        if label_seen.get(sanitized_dotnet_module_path):
            dotnet_module_included = True
    ruby_module_included = False
    if sanitized_ruby_module_path:
        if label_seen.get(sanitized_ruby_module_path):
            ruby_module_included = True

    # Unified export file for simpler loading from user repos
    # Prefer the apparent repo name passed by the extension/WORKSPACE helper; fallback to ctx.name
    repo_name = (getattr(ctx.attr, "repo_name", None) or ctx.name or "")
    export_bzl = _render_export_bzl(
        repo_name,
        validated_service,
        labels,
        set_literal,
        go_module_path,
        sanitized_go_module_path,
        go_module_included,
        manifest_file,
        python_module_path = python_module_path,
        sanitized_python_module_path = sanitized_python_module_path,
        python_module_included = python_module_included,
        java_module_path = java_module_path,
        sanitized_java_module_path = sanitized_java_module_path,
        java_module_included = java_module_included,
        nodejs_module_path = nodejs_module_path,
        sanitized_nodejs_module_path = sanitized_nodejs_module_path,
        nodejs_module_included = nodejs_module_included,
        dotnet_module_path = dotnet_module_path,
        sanitized_dotnet_module_path = sanitized_dotnet_module_path,
        dotnet_module_included = dotnet_module_included,
        ruby_module_path = ruby_module_path,
        sanitized_ruby_module_path = sanitized_ruby_module_path,
        ruby_module_included = ruby_module_included,
    )
    ctx.file("export.bzl", export_bzl)

    # ------------------------------------------------------------------
    # Phase 5: Emit generated helper files and public BUILD targets.
    # ------------------------------------------------------------------
    # Rule to present per-module files with canonical runfile names via symlinks
    # We generate this helper rule as source text to keep repository-rule output
    # self-contained and avoid hard-coding additional checked-in helper files.
    module_runfiles_bzl = _render_module_runfiles_bzl(_dirname(manifest_file))
    ctx.file("module_runfiles.bzl", module_runfiles_bzl)

    # 6. Create a BUILD file with two public filegroup targets.
    # - test_optimization_files: the JSONs returned or stubbed from HTTP (existing)
    # - test_optimization_context: the context.json (separate, so consumers can opt-in)
    exp = repr(exports)
    build_content = (
        'load(":module_runfiles.bzl", "topt_module_files")\n' +
        "filegroup(\n" +
        '    name = "test_optimization_files",\n' +
        ("    srcs = %s,\n" % exp) +
        '    visibility = ["//visibility:public"],\n' +
        ")\n\n" +
        "filegroup(\n" +
        '    name = "test_optimization_context",\n' +
        ("    srcs = %s,\n" % repr([context_file, telemetry_facts_file])) +
        '    visibility = ["//visibility:public"],\n' +
        ")\n" +
        ('\nexports_files(["export.bzl", %s], visibility = ["//visibility:public"])\n' % repr(manifest_file))
    )

    # Append one filegroup per module so consumers can depend on individual modules
    if module_specs_known or module_specs_tm:
        labels_for_modules = labels
        if not labels_for_modules:
            # Fallback: derive labels from specs if mapping is unavailable
            # This path should be rare, but keeps BUILD generation resilient
            # when upstream payloads are partially populated.
            label_seen = {}
            labels_for_modules = []
            for s in module_specs_known:
                lab = s["label"]
                if not label_seen.get(lab):
                    label_seen[lab] = True
                    labels_for_modules.append(lab)
            for s in module_specs_tm:
                lab = s["label"]
                if not label_seen.get(lab):
                    label_seen[lab] = True
                    labels_for_modules.append(lab)
            labels_for_modules = sorted(labels_for_modules)

        # Map module labels to their per-module files
        known_by_label = {}
        for s in module_specs_known:
            known_by_label[s["label"]] = s["file"]
        tm_by_label = {}
        for s in module_specs_tm:
            tm_by_label[s["label"]] = s["file"]

        # Ensure per-module stubs exist for the missing side so consumers always
        # see both canonical filenames in the per-module runfiles
        for lab in labels_for_modules:
            if not known_by_label.get(lab):
                per_dir = ("%s/%s" % (out_dir, ("module_%s" % lab)))
                kfile = per_dir + "/known_tests.json"
                _ensure_parent_directory(ctx, kfile, debug)
                ctx.file(kfile, '{"data": {"attributes": {"tests": {}}}}\n')
                known_by_label[lab] = kfile
            if not tm_by_label.get(lab):
                per_dir = ("%s/%s" % (out_dir, ("module_%s" % lab)))
                tfile = per_dir + "/test_management.json"
                _ensure_parent_directory(ctx, tfile, debug)
                ctx.file(tfile, '{"data": {"attributes": {"modules": {}}}}\n')
                tm_by_label[lab] = tfile

        for lab in labels_for_modules:
            # Emit a dedicated target per module so macro consumers can select
            # narrow runfiles while preserving canonical filenames via symlinks.
            known_tests_file = known_by_label.get(lab)
            test_management_file = tm_by_label.get(lab)
            build_content += ("\ntopt_module_files(\n" +
                              ('    name = "module_%s",\n' % lab) +
                              ("    settings = %s,\n" % _bzl_string_literal(settings_file)) +
                              ("    manifest = %s,\n" % _bzl_string_literal(manifest_file)) +
                              (("    known_tests = %s,\n" % _bzl_string_literal(known_tests_file)) if known_tests_file else "") +
                              (("    test_management = %s,\n" % _bzl_string_literal(test_management_file)) if test_management_file else "") +
                              '    visibility = ["//visibility:public"],\n' +
                              ")\n")
    log_debug(debug, "build", "Creating BUILD file with content: %s" % build_content)
    ctx.report_progress("test_optimization_sync: writing BUILD")
    ctx.file("BUILD", build_content)

    log_info("Repository rule completed successfully")
    ctx.report_progress("test_optimization_sync: done")

# ##########################################################################
# Rule and extension declarations
# ##########################################################################

# Define a repository rule `test_optimization_sync` to pull data from Datadog's servers.
# - Runs outside the sandbox in the repository-loading phase
# - Always re-executes locally to fetch fresh content
# - Downstream actions cache based on the fetched file's content hash

test_optimization_sync = repository_rule(
    implementation = _impl,  # Points to the implementation function above
    attrs = {
        # Optional output directory; defaults to TEST_OPT_DIR (".testoptimization")
        "out_dir": attr.string(),
        # Repository name to expose in exports (alias created by use_repo)
        "repo_name": attr.string(),
        # Optional explicit service name to use (overrides DD_SERVICE)
        "service": attr.string(),
        # Optional runtime.* overrides used in configurations
        "runtime_name": attr.string(),
        "runtime_version": attr.string(),
        "runtime_arch": attr.string(),
        # Optional HTTP timeout/retry policy overrides.
        # Use -1 to keep default/env behavior.
        "http_connect_timeout_seconds": attr.int(default = HTTP_POLICY_ATTR_UNSET),
        "http_max_time_seconds": attr.int(default = HTTP_POLICY_ATTR_UNSET),
        "http_retry_attempts": attr.int(default = HTTP_POLICY_ATTR_UNSET),
        "http_retry_delay_seconds": attr.int(default = HTTP_POLICY_ATTR_UNSET),
        "http_execute_timeout_buffer_seconds": attr.int(default = HTTP_POLICY_ATTR_UNSET),
        # Kill-switches for feature requests
        # - known_tests: when False, do not request Known Tests and write a minimal stub; also set
        #               settings.data.attributes.known_tests_enabled=false in the settings file.
        # - test_management: when False, do not request Test Management Tests and write a minimal stub; also set
        #                    settings.data.attributes.test_management.enabled=false in the settings file.
        "known_tests": attr.bool(default = True),
        "test_management": attr.bool(default = True),
        "debug": attr.bool(default = False),  # Toggle verbose debug logging
    },
    environ = [
        # Keep this list intentionally broad: every env var that can influence
        # generated outputs must be declared so Bazel cache keys stay correct.
        # Environment variables treated as rule inputs
        "DD_API_KEY",  # Required: Datadog API key for authentication
        "DD_SITE",  # Optional: Datadog site; ex: app.datadoghq.com, datadoghq.eu
        "DD_TEST_OPTIMIZATION_AGENTLESS_URL",  # Optional: override Datadog API base URL (test/dev)
        "DD_TEST_OPTIMIZATION_HTTP_CONNECT_TIMEOUT_SECONDS",  # Optional: override connect timeout
        "DD_TEST_OPTIMIZATION_HTTP_MAX_TIME_SECONDS",  # Optional: override request max time
        "DD_TEST_OPTIMIZATION_HTTP_RETRY_ATTEMPTS",  # Optional: override retry attempts
        "DD_TEST_OPTIMIZATION_HTTP_RETRY_DELAY_SECONDS",  # Optional: override retry delay
        "DD_TEST_OPTIMIZATION_HTTP_EXECUTE_TIMEOUT_BUFFER_SECONDS",  # Optional: override outer timeout buffer
        "FETCH_SALT",  # Optional: cache-busting salt to force re-fetch
        "GIT_DIRTY",  # Optional: working tree state; triggers refetch on change
        "GO_MODULE_PATH",  # Optional: explicit Go module path override for export.bzl
        "PYTHON_MODULE_PATH",  # Optional: explicit Python module path override for export.bzl
        "JAVA_MODULE_PATH",  # Optional: explicit Java module path override for export.bzl
        "NODEJS_MODULE_PATH",  # Optional: explicit NodeJS module path override for export.bzl
        "DOTNET_MODULE_PATH",  # Optional: explicit Dotnet module path override for export.bzl
        "RUBY_MODULE_PATH",  # Optional: explicit Ruby module path override for export.bzl
        # Host OS hints used for cross-platform behavior and request configuration
        "OS",  # Windows OS marker (used in _is_windows and _detect_os_info)
        "ComSpec",  # Windows command processor path
        "COMSPEC",  # Alternate casing for Windows command processor
        "PROCESSOR_ARCHITECTURE",  # Windows arch detection
        "PROCESSOR_ARCHITEW6432",  # Windows WOW64 arch detection
        # Shared CI/git metadata inputs are centralized in test_optimization_sync_env.bzl
        # so provider extraction and repository_rule cache keys cannot drift apart.
    ] + _ALL_SYNC_ENV_KEYS,
    # Repository rules run during workspace/module resolution; keep local=True
    # so host tooling/env detection remains predictable across environments.
    local = True,
)

# Module extension implementation for Bazel 6+ MODULE.bazel system
def _test_optimization_sync_extension_impl(module_ctx):
    """Instantiate `test_optimization_sync` repositories from extension tags.

    This function intentionally mirrors extension tag fields to repository rule
    attrs with minimal transformation so behavior stays predictable between
    bzlmod and WORKSPACE usage.
    """

    # Determine if any tag has debug enabled to gate high-level logging
    extension_debug = False
    for _mod in module_ctx.modules:
        for _call in _mod.tags.test_optimization_sync:
            if hasattr(_call, "debug") and _call.debug:
                extension_debug = True
                break
        if extension_debug:
            break

    log_debug(extension_debug, "extension", "Starting module extension implementation")
    log_debug(extension_debug, "extension", "Number of modules: %d" % len(module_ctx.modules))

    seen_repo_owners = {}
    for mod in module_ctx.modules:
        owner = mod.name or "<unnamed-module>"
        log_debug(extension_debug, "extension", "Processing module: %s" % mod.name)
        log_debug(extension_debug, "extension", "Module is_root: %s" % mod.is_root)
        log_debug(extension_debug, "extension", "Number of test_optimization_sync tags: %d" % len(mod.tags.test_optimization_sync))

        for test_optimization_call in mod.tags.test_optimization_sync:
            repo_name = test_optimization_call.name
            _record_sync_extension_repo_owner_or_fail(seen_repo_owners, repo_name, owner)

            # Tag-level debug allows one noisy callsite without enabling verbose
            # logging for all extension users in the dependency graph.
            call_debug = hasattr(test_optimization_call, "debug") and test_optimization_call.debug
            log_debug(call_debug, "extension", "Processing test_optimization_sync call: %s" % test_optimization_call.name)
            log_debug(
                call_debug,
                "extension",
                "Calling test_optimization_sync with name=%s, out_dir=%s, service=%s, debug=%s" %
                (
                    test_optimization_call.name,
                    (test_optimization_call.out_dir or "<default>"),
                    (test_optimization_call.service or "<env/DD_SERVICE>"),
                    call_debug,
                ),
            )

            test_optimization_sync(
                name = test_optimization_call.name,
                repo_name = test_optimization_call.name,
                # Keep `repo_name` aligned with extension repo alias so exported
                # labels in `export.bzl` remain intuitive for consumers.
                # Forward extension attrs nearly 1:1 to preserve parity between
                # bzlmod usage and direct WORKSPACE/repo_rule usage.
                out_dir = test_optimization_call.out_dir,
                service = test_optimization_call.service,
                runtime_name = test_optimization_call.runtime_name,
                runtime_version = test_optimization_call.runtime_version,
                runtime_arch = test_optimization_call.runtime_arch,
                http_connect_timeout_seconds = test_optimization_call.http_connect_timeout_seconds,
                http_max_time_seconds = test_optimization_call.http_max_time_seconds,
                http_retry_attempts = test_optimization_call.http_retry_attempts,
                http_retry_delay_seconds = test_optimization_call.http_retry_delay_seconds,
                http_execute_timeout_buffer_seconds = test_optimization_call.http_execute_timeout_buffer_seconds,
                known_tests = test_optimization_call.known_tests,
                test_management = test_optimization_call.test_management,
                debug = call_debug,
            )

# Define the module extension with the test_optimization_sync tag
test_optimization_sync_extension = module_extension(
    implementation = _test_optimization_sync_extension_impl,
    tag_classes = {
        "test_optimization_sync": tag_class(attrs = {
            "name": attr.string(mandatory = True),
            # Optional: base output directory (defaults to TEST_OPT_DIR)
            "out_dir": attr.string(),
            # Optional explicit service name to use (overrides DD_SERVICE)
            "service": attr.string(),
            # Optional runtime.* overrides used in configurations
            "runtime_name": attr.string(),
            "runtime_version": attr.string(),
            "runtime_arch": attr.string(),
            # Optional HTTP timeout/retry policy overrides.
            # Use -1 to keep default/env behavior.
            "http_connect_timeout_seconds": attr.int(default = HTTP_POLICY_ATTR_UNSET),
            "http_max_time_seconds": attr.int(default = HTTP_POLICY_ATTR_UNSET),
            "http_retry_attempts": attr.int(default = HTTP_POLICY_ATTR_UNSET),
            "http_retry_delay_seconds": attr.int(default = HTTP_POLICY_ATTR_UNSET),
            "http_execute_timeout_buffer_seconds": attr.int(default = HTTP_POLICY_ATTR_UNSET),
            # Optional kill-switches (default True keeps server behavior; False disables feature locally)
            "known_tests": attr.bool(default = True),
            "test_management": attr.bool(default = True),
            "debug": attr.bool(default = False),
        }),
    },
)
