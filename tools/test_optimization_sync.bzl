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
    "//tools:common_utils.bzl",
    "dedup_keys",
    "log_debug",
    "log_info",
    "sanitize_label_fragment",
    "validate_api_key",
    "validate_runtime_name",
    "validate_runtime_version",
    "validate_service_name",
)

# ##########################################################################
# Constants
# ##########################################################################

TEST_OPT_DIR = ".testoptimization"
TEST_BAZEL_RULE_NAME = "datadog-rules-test-optimization"
TEST_BAZEL_RULE_VERSION = "1.0.0"
# Upper bound for repository_ctx.execute() around HTTP tooling.
# Keep this above curl/PowerShell per-request max-time to include process startup.
HTTP_EXECUTE_TIMEOUT_SECONDS = 120

# ##########################################################################
# Tools functions
# ##########################################################################

def _curl_base_args():
    # _curl_base_args: returns common curl flags applied to all HTTP requests
    # -f: fail on HTTP errors (>= 400)
    # -sS: silent, but show errors
    # retry/backoff: basic robustness against transient failures
    return [
        "curl",
        "-f",
        "-sS",
        "--connect-timeout",
        "10",
        "--max-time",
        "60",
        "--retry",
        "3",
        "--retry-delay",
        "2",
        "--retry-connrefused",
    ]

def _is_windows(ctx):
    # _is_windows: best-effort host OS detection using environment variables available in repository_ctx.
    os_env = (ctx.os.environ.get("OS") or "").lower()
    comspec = (ctx.os.environ.get("ComSpec") or ctx.os.environ.get("COMSPEC") or "").lower()
    return ("windows" in os_env) or comspec.endswith("cmd.exe")

_FINGERPRINT_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_:/.+"

def _fnv1a_32(value):
    # FNV-1a style 32-bit hash for stable fingerprinting (non-cryptographic).
    # Starlark lacks ord()/bytes, so map characters via a fixed alphabet.
    h = 2166136261
    vlen = len(value)
    for i in range(vlen):
        ch = value[i]
        idx = _FINGERPRINT_ALPHABET.find(ch)
        if idx < 0:
            idx = 0
        h = h ^ idx
        h = (h * 16777619) & 0xffffffff
    return h

def _hex32(value):
    digits = "0123456789abcdef"
    out = ""
    v = value
    for _ in range(8):
        out = digits[v & 0xf] + out
        v = v >> 4
    return out

def _api_key_fingerprint(api_key):
    if not api_key:
        return ""
    return _hex32(_fnv1a_32(api_key))

def _ensure_parent_directory(ctx, path, debug):
    # Create parent directory for a given file path if needed.
    # Starlark has no os.path utilities; use simple split/join.
    if not path:
        return

    # Normalize path segments and drop empty/"." parts
    segments = [s for s in path.split("/") if (s != "" and s != ".")]
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
            "New-Item -ItemType Directory -Force -Path '%s' | Out-Null" % win_dir.replace("'", "''"),
        ]
        res = ctx.execute(ps_cmd)
    else:
        res = ctx.execute(["mkdir", "-p", dirp])
    log_debug(debug, "filesystem", "Ensured directory '%s' for output '%s' (rc=%d)" % (dirp, path, res.return_code))
    if res.return_code != 0:
        fail("Failed creating directory %s for output %s: %s" % (dirp, path, (res.stderr or "").strip()))

def _dirname(path):
    # _dirname: return parent directory component of a path using simple split
    if not path:
        return ""
    segs = [s for s in path.split("/") if (s != "" and s != ".")]
    if len(segs) <= 1:
        return ""
    return "/".join(segs[:-1])

def _try_read_abs_file(ctx, abs_path):
    # _try_read_abs_file: best-effort read of a file at an absolute path using host tools.
    # Returns file content string on success; empty string otherwise.
    if not abs_path:
        return ""
    if _is_windows(ctx):
        cmd = [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "$p = '%s'; if (Test-Path -LiteralPath $p) { Get-Content -Raw -LiteralPath $p }" % abs_path.replace("'", "''"),
        ]
        res = ctx.execute(cmd)
        if res.return_code == 0 and res.stdout:
            return res.stdout
        return ""
    else:
        res = ctx.execute(["/bin/sh", "-c", "[ -f '" + abs_path.replace("'", "'\\''") + "' ] && cat '" + abs_path.replace("'", "'\\''") + "'"])
        if res.return_code == 0 and res.stdout:
            return res.stdout
        return ""

def _parse_go_module_path(go_mod_content):
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
            if len(rest) >= 2 and ((rest[0] == '"' and rest[-1] == '"') or (rest[0] == "'" and rest[-1] == "'")):
                rest = rest[1:-1]
            return rest
    return ""

def _detect_go_module_path(ctx, debug):
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
        content = _try_read_abs_file(ctx, go_mod_path)
        if content:
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
        content = _try_read_abs_file(ctx, go_mod_path)
        if content:
            mp = _parse_go_module_path(content)
            if mp:
                log_debug(debug, "go", "Detected module path '%s' from %s" % (mp, go_mod_path))
                return mp
    log_debug(debug, "go", "Go module path not detected; returning empty")
    return ""

def _split_known_tests_by_module(ctx, known_tests_file, debug, label_map = None):
    # _split_known_tests_by_module: from the combined known_tests JSON, produce
    # one JSON file per module under the same directory as `known_tests_file`.
    # Returns a list of dicts with keys: module, label, file
    specs = []
    kt_path = ctx.path(known_tests_file)
    content = ctx.read(kt_path)
    if not content or not content.strip():
        return specs

    # Decode and navigate to data.attributes.tests (map: module -> suites map)
    obj = _decode_json_object_or_fail(content, known_tests_file)
    data_obj = obj.get("data") or {}
    attrs_obj = data_obj.get("attributes") or {}
    tests_obj = attrs_obj.get("tests") or {}
    if type(tests_obj) != "dict":
        return specs

    base_dir = _dirname(known_tests_file)

    # Ensure deterministic ordering for reproducible BUILD content
    module_names = sorted([k for k in tests_obj.keys()])

    # Compute sanitized labels and deduplicate (or use provided mapping)
    if label_map:
        deduped_labels = [label_map.get(m) or sanitize_label_fragment(m) for m in module_names]
    else:
        raw_labels = [sanitize_label_fragment(m) for m in module_names]
        deduped_labels = dedup_keys(raw_labels)

    for i in range(len(module_names)):
        module_name = module_names[i]
        label = deduped_labels[i]
        suites_map = tests_obj.get(module_name)

        # Guard against non-dict anomalies
        if type(suites_map) != "dict":
            continue

        # Place per-module canonical-named file under a dedicated subdirectory to avoid collisions
        per_module_dir = ("%s/%s" % (base_dir, ("module_%s" % label))) if base_dir else ("module_%s" % label)
        out_file = per_module_dir + "/known_tests.json"

        # Build a per-module JSON that preserves the full original shape
        # and only narrows data.attributes.tests to the single module.
        new_obj = {}
        for _k in obj.keys():
            new_obj[_k] = obj.get(_k)
        data_obj2 = new_obj.get("data")
        if type(data_obj2) != "dict":
            data_obj2 = {}
            new_obj["data"] = data_obj2
        attrs_obj2 = data_obj2.get("attributes")
        if type(attrs_obj2) != "dict":
            attrs_obj2 = {}
            data_obj2["attributes"] = attrs_obj2
        attrs_obj2["tests"] = {module_name: suites_map}
        mod_obj = new_obj

        _ensure_parent_directory(ctx, out_file, debug)
        ctx.file(out_file, json.encode(mod_obj) + "\n")
        log_debug(debug, "module", "Wrote per-module known tests file '%s' for module '%s'" % (out_file, module_name))

        specs.append({
            "module": module_name,
            "label": label,
            "file": out_file,
        })

    return specs

def _split_test_management_by_module(ctx, test_management_file, debug, label_map = None):
    # _split_test_management_by_module: from the combined test_management JSON, produce
    # one JSON file per module under the same directory as `test_management_file`.
    # Returns a list of dicts with keys: module, label, file
    specs = []
    tm_path = ctx.path(test_management_file)
    content = ctx.read(tm_path)
    if not content or not content.strip():
        return specs

    # Decode and navigate to data.attributes.modules (map: module -> module suites/tests object)
    obj = _decode_json_object_or_fail(content, test_management_file)
    data_obj = obj.get("data") or {}
    attrs_obj = data_obj.get("attributes") or {}
    modules_obj = attrs_obj.get("modules") or {}
    if type(modules_obj) != "dict":
        return specs

    base_dir = _dirname(test_management_file)
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
        
        if type(module_content) != "dict":
            continue

        # Place per-module canonical-named file under a dedicated subdirectory to avoid collisions
        per_module_dir = ("%s/%s" % (base_dir, ("module_%s" % label))) if base_dir else ("module_%s" % label)
        out_file = per_module_dir + "/test_management.json"

        # Build a per-module JSON that preserves the full original shape
        # and only narrows data.attributes.modules to the single module.
        new_obj = {}
        for _k in obj.keys():
            new_obj[_k] = obj.get(_k)
        data_obj2 = new_obj.get("data")
        if type(data_obj2) != "dict":
            data_obj2 = {}
            new_obj["data"] = data_obj2
        attrs_obj2 = data_obj2.get("attributes")
        if type(attrs_obj2) != "dict":
            attrs_obj2 = {}
            data_obj2["attributes"] = attrs_obj2
        attrs_obj2["modules"] = {module_name: module_content}
        mod_obj = new_obj

        _ensure_parent_directory(ctx, out_file, debug)
        ctx.file(out_file, json.encode(mod_obj) + "\n")
        log_debug(debug, "module", "Wrote per-module test_management file '%s' for module '%s'" % (out_file, module_name))

        specs.append({
            "module": module_name,
            "label": label,
            "file": out_file,
        })

    return specs

def _detect_os_info(ctx, debug):
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

def _compute_dd_api_base(site_env):
    # _compute_dd_api_base: compute the base Datadog API URL from a site value.
    # - Input examples:
    #   site_env = "app.datadoghq.com"  -> returns https://api.datadoghq.com
    #   site_env = "datadoghq.eu"       -> returns https://api.datadoghq.eu
    #   site_env = None/""               -> returns https://api.datadoghq.com
    # - Rationale: users frequently set DD_SITE to app.*; Datadog APIs are under
    #   api.*. We normalize here for consistency.
    site = (site_env or "").strip()

    # Strip scheme if present (e.g., https://app.datadoghq.com)
    if "://" in site:
        site = site.split("://", 1)[1]

    # Strip any path/query fragments
    if "/" in site:
        site = site.split("/", 1)[0]

    # Normalize common prefixes
    if site.startswith("app."):
        site = site[len("app."):]
    if site.startswith("api."):
        site = site[len("api."):]

    if not site:
        # If input was empty or became empty after normalization, fall back to default.
        site = "datadoghq.com"
    return "https://api.%s" % site

def _resolve_dd_api_base(env_data, debug):
    # _resolve_dd_api_base: resolve API base URL from overrides or DD_SITE.
    override = env_data.get("dd_api_base") or ""
    if override:
        # Allow tests/dev to point sync requests at a mock server without changing DD_SITE.
        base = override.rstrip("/")
        log_debug(debug, "http", "DD_TOPT_API_BASE override set: %s" % base)
        return base
    return _compute_dd_api_base(env_data.get("dd_site"))

def _resolve_dd_api_base_for_tests(dd_site, dd_api_base):
    # Test helper to validate override behavior deterministically.
    env_data = {
        "dd_site": dd_site or "",
        "dd_api_base": dd_api_base or "",
    }
    return _resolve_dd_api_base(env_data, False)

def _decode_json_object_or_fail(content, context):
    # Parse API/file JSON with actionable guardrails for malformed responses.
    trimmed = (content or "").strip()
    if not trimmed:
        fail("test_optimization: %s response is empty; expected JSON object" % context)

    # Catch common non-JSON responses (HTML/text proxy errors) early.
    if not (trimmed.startswith("{") or trimmed.startswith("[")):
        sample = trimmed[:120].replace("\n", " ").replace("\r", " ")
        fail(
            (
                "test_optimization: %s response is not JSON (starts with: %s). " +
                "Check DD_SITE/DD_TOPT_API_BASE, credentials, and endpoint routing."
            ) %
            (context, repr(sample)),
        )

    obj = json.decode(trimmed)
    if type(obj) != "dict":
        fail("test_optimization: %s response must be a JSON object, got %s" % (context, type(obj)))
    return obj

def _collect_known_tests_modules(ctx, known_tests_file):
    # _collect_known_tests_modules: list module names from known_tests.json
    kt_path = ctx.path(known_tests_file)
    content = ctx.read(kt_path)
    if not content or not content.strip():
        return []
    obj = _decode_json_object_or_fail(content, known_tests_file)
    data_obj = obj.get("data") or {}
    attrs_obj = data_obj.get("attributes") or {}
    tests_obj = attrs_obj.get("tests") or {}
    if type(tests_obj) != "dict":
        return []
    modules = []
    for k in tests_obj.keys():
        if type(tests_obj.get(k)) == "dict":
            modules.append(k)
    return sorted(modules)

def _collect_test_management_modules(ctx, test_management_file):
    # _collect_test_management_modules: list module names from test_management.json
    tm_path = ctx.path(test_management_file)
    content = ctx.read(tm_path)
    if not content or not content.strip():
        return []
    obj = _decode_json_object_or_fail(content, test_management_file)
    data_obj = obj.get("data") or {}
    attrs_obj = data_obj.get("attributes") or {}
    modules_obj = attrs_obj.get("modules") or {}
    if type(modules_obj) != "dict":
        return []
    modules = []
    for k in modules_obj.keys():
        if type(modules_obj.get(k)) == "dict":
            modules.append(k)
    return sorted(modules)

def _build_module_label_map(known_modules, test_management_modules):
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
def _render_export_bzl(repo_name, labels, set_literal, go_module_path, sanitized_go_module_path, go_module_included, manifest_file):
    return (
        "# Generated by test_optimization_sync; unified exports for test optimization info\n" +
        "topt_data = {\n" +
        "    \"repo_name\": \"%s\",\n" % repo_name +
        "    \"manifest_path\": \"%s\",\n" % manifest_file +
        "    \"labels\": %s,\n" % repr(labels) +
        "    \"set\": %s,\n" % set_literal +
        "    \"go\": {\n" +
        "        \"module_path\": \"%s\",\n" % (go_module_path or "") +
        "        \"sanitized_module_path\": \"%s\",\n" % sanitized_go_module_path +
        "        \"module_included\": %s,\n" % ("True" if go_module_included else "False") +
        "    },\n" +
        "}\n"
    )

def _http_request(ctx, method, url, headers, out_file, debug, data_file = None, request_debug_payload = None):
    # _http_request: executes an HTTP call and writes the response to `out_file`.
    # - On Windows: uses PowerShell Invoke-WebRequest for portability.
    # - On Linux/macOS: uses curl with retries.
    # - Returns tool exit code (0=success) and prints HTTP status code to stdout when possible.
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

    # Avoid logging secrets; only log method and URL
    log_info("http %s %s" % (http_method, url))

    if is_win:
        # Build a small PowerShell script to perform the request with basic retries.
        # We prefer a script file to avoid complex quoting issues.
        # Script writes the HTTP status code to stdout on success.
        script_name = "_http_request_%s.ps1" % (out_file.replace("/", "_").replace("\\", "_") or "out")
        lines = []
        lines.append("$ErrorActionPreference = 'Stop'")
        lines.append("$ProgressPreference = 'SilentlyContinue'")
        lines.append("$Url = '%s'" % url.replace("'", "''"))
        lines.append("$OutFile = '%s'" % out_file.replace("'", "''"))
        lines.append("$Method = '%s'" % http_method)

        # Headers hashtable (PowerShell expects IDictionary-like; hashtable is safest)
        lines.append("$Headers = @{}")
        ps_env = {}
        for hk, hv in headers.items():
            header_key = str(hk)
            header_value = str(hv)
            if header_key.lower() == "dd-api-key":
                # Keep API keys out of generated script files; inject at execute-time only.
                ps_env["DD_TOPT_API_KEY"] = header_value
                lines.append("$apiKey = $env:DD_TOPT_API_KEY")
                lines.append("if ([string]::IsNullOrEmpty($apiKey)) { Write-Error 'missing DD_TOPT_API_KEY for DD-API-KEY header'; exit 2 }")
                lines.append("$Headers['%s'] = $apiKey" % header_key.replace("'", "''"))
            else:
                lines.append("$Headers['%s'] = '%s'" % (header_key.replace("'", "''"), header_value.replace("'", "''")))

        # Optional body file
        if data_file:
            lines.append("$BodyFile = '%s'" % data_file.replace("'", "''"))
        lines.append("$max = 3; $attempt = 0")
        lines.append("while ($true) {")
        lines.append("  try {")
        if data_file:
            lines.append("    $resp = Invoke-WebRequest -Uri $Url -Headers $Headers -Method $Method -InFile $BodyFile -OutFile $OutFile -ContentType 'application/json' -TimeoutSec 60")
        else:
            lines.append("    $resp = Invoke-WebRequest -Uri $Url -Headers $Headers -Method $Method -OutFile $OutFile -TimeoutSec 60")

        # Emulate curl -f: treat HTTP >= 400 as failure
        lines.append("    $code = if ($resp.StatusCode) { [int]$resp.StatusCode } else { 200 }")
        lines.append("    if ($code -ge 400) { Write-Error ('HTTP {0} returned for ' + $Url) -f $code; exit 1 }")
        lines.append("    Write-Output $code")
        lines.append("    exit 0")
        lines.append("  } catch { if ($attempt -lt ($max - 1)) { Start-Sleep -Seconds 2; $attempt = $attempt + 1 } else { Write-Error $_; exit 1 } }")
        lines.append("}")
        script_content = "\n".join(lines) + "\n"
        ctx.file(script_name, script_content)
        if ps_env:
            result = ctx.execute(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script_name],
                environment = ps_env,
                timeout = HTTP_EXECUTE_TIMEOUT_SECONDS,
            )
        else:
            result = ctx.execute(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script_name],
                timeout = HTTP_EXECUTE_TIMEOUT_SECONDS,
            )
    else:
        args = [] + _curl_base_args()
        if http_method and http_method != "GET":
            args.extend(["-X", http_method])
        for header_key, header_value in headers.items():
            args.extend(["-H", "%s: %s" % (header_key, header_value)])
        if data_file:
            args.extend(["--data-binary", "@%s" % data_file])
        args.extend([url, "-o", out_file, "-w", "%{http_code}"])
        result = ctx.execute(args, timeout = HTTP_EXECUTE_TIMEOUT_SECONDS)

    # Parse HTTP status code captured by tool stdout. On network errors it may be empty.
    http_status = (result.stdout or "").strip() or "000"

    # Branch: network error or tool failure
    if result.return_code != 0:
        request_body = request_debug_payload if request_debug_payload else "<none>"
        fail(
            "HTTP request failed (status=%s, method=%s, url=%s, code=%d). stderr=%s\nresponse_file=%s\nrequest_body=%s" %
            (
                http_status,
                http_method,
                url,
                result.return_code,
                (result.stderr or "").strip(),
                out_file,
                request_body,
            ),
        )
    else:
        # Branch: success path; try to emit a concise size summary
        if _is_windows(ctx):
            size_cmd = [
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "$fi = Get-Item -LiteralPath '%s'; if ($fi) { Write-Output $fi.Length }" % out_file.replace("'", "''"),
            ]
            size_result = ctx.execute(size_cmd)
            if size_result.return_code == 0 and size_result.stdout:
                bytes_str = size_result.stdout.strip()
                log_info("Downloaded %s (%s bytes) from %s" % (out_file, bytes_str, url))
            else:
                log_info("Downloaded %s from %s" % (out_file, url))
        else:
            size_result = ctx.execute(["wc", "-c", out_file])
            if size_result.return_code == 0 and size_result.stdout:
                parts = [p for p in size_result.stdout.strip().split(" ") if p]
                bytes_str = parts[0] if parts else "unknown"
                log_info("Downloaded %s (%s bytes) from %s" % (out_file, bytes_str, url))
            else:
                log_info("Downloaded %s from %s" % (out_file, url))

        # Emit full response body when debug is enabled, similar to request logging
        if debug:
            try_body = ctx.read(ctx.path(out_file))
            if try_body != None:
                log_debug(
                    debug,
                    "http",
                    "HTTP response body (%s %s): %s" % (http_method, url, try_body),
                )

    return result.return_code

def _http_post_json(ctx, url, headers, json_body_str, tmp_body_file, out_file, debug):
    # Write the request body to a temp file for curl --data-binary
    ctx.file(tmp_body_file, json_body_str)

    # Merge content headers with caller-provided headers
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
    )

def _first_env(ctx, keys):
    # _first_env: returns the first non-empty environment variable value
    for k in keys:
        v = ctx.os.environ.get(k)
        if v:
            return v
    return ""

def _normalize_ref(name):
    # _normalize_ref: removes common ref prefixes from branch/tag names
    if not name:
        return name
    prefixes = ["refs/heads/", "refs/", "origin/", "tags/"]
    for p in prefixes:
        if name.startswith(p):
            name = name[len(p):]
    return name

# Public aliases for tests (avoid importing private symbols)
compute_dd_api_base_for_tests = _compute_dd_api_base
resolve_dd_api_base_for_tests = _resolve_dd_api_base_for_tests
build_module_label_map_for_tests = _build_module_label_map
normalize_ref_for_tests = _normalize_ref
parse_go_module_path_for_tests = _parse_go_module_path
dirname_for_tests = _dirname
render_export_bzl_for_tests = _render_export_bzl
http_execute_timeout_seconds_for_tests = HTTP_EXECUTE_TIMEOUT_SECONDS

# ##########################################################################
# CI environment detection
# ##########################################################################

def _collect_env(ctx):
    # _collect_env: reads CI provider env once and returns a unified dict used
    # by request helpers. Detection order mirrors Datadog's providers list.
    env_data = {
        "dd_site": ctx.os.environ.get("DD_SITE") or "",
        # Optional override to point API calls at a mock server (tests/dev).
        "dd_api_base": ctx.os.environ.get("DD_TOPT_API_BASE") or "",
        # Service can be provided via attr first, then DD_SERVICE, else default
        "service": (getattr(ctx.attr, "service", None) or ctx.os.environ.get("DD_SERVICE") or "unnamed-service"),
        "environment": ctx.os.environ.get("DD_ENV") or "CI",
        "repository_url": "",
        "branch": "",
        "sha": "",
        "head_sha": "",
        "commit_message": "",
        "head_message": "",
    }

    # Provider detection and extraction
    provider = ""
    if ctx.os.environ.get("APPVEYOR"):
        provider = "appveyor"
        repo_name = ctx.os.environ.get("APPVEYOR_REPO_NAME") or ""
        if (ctx.os.environ.get("APPVEYOR_REPO_PROVIDER") or "") == "github" and repo_name:
            env_data["repository_url"] = "https://github.com/%s.git" % repo_name
        else:
            env_data["repository_url"] = repo_name
        env_data["sha"] = ctx.os.environ.get("APPVEYOR_REPO_COMMIT") or ""
        env_data["branch"] = _first_env(ctx, ["APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH", "APPVEYOR_REPO_BRANCH"]) or ""
    elif ctx.os.environ.get("TF_BUILD"):
        provider = "azure_pipelines"
        env_data["repository_url"] = ctx.os.environ.get("BUILD_REPOSITORY_URI") or ""
        env_data["sha"] = ctx.os.environ.get("BUILD_SOURCEVERSION") or ""
        env_data["branch"] = ctx.os.environ.get("BUILD_SOURCEBRANCH") or ""
        env_data["commit_message"] = ctx.os.environ.get("BUILD_SOURCEVERSIONMESSAGE") or ""
    elif ctx.os.environ.get("BITBUCKET_COMMIT"):
        provider = "bitbucket"
        env_data["repository_url"] = (
            ctx.os.environ.get("BITBUCKET_GIT_HTTP_ORIGIN") or
            ("https://bitbucket.org/%s.git" % (ctx.os.environ.get("BITBUCKET_REPO_SLUG") or ""))
        )
        env_data["sha"] = ctx.os.environ.get("BITBUCKET_COMMIT") or ""
        env_data["branch"] = ctx.os.environ.get("BITBUCKET_BRANCH") or ""
    elif ctx.os.environ.get("BUDDY"):
        provider = "buddy"
        # Buddy variables vary; keep placeholders

    elif ctx.os.environ.get("BUILDKITE"):
        provider = "buildkite"
        env_data["repository_url"] = ctx.os.environ.get("BUILDKITE_REPO") or ""
        env_data["sha"] = ctx.os.environ.get("BUILDKITE_COMMIT") or ""
        env_data["branch"] = ctx.os.environ.get("BUILDKITE_BRANCH") or ""
        env_data["commit_message"] = ctx.os.environ.get("BUILDKITE_MESSAGE") or ""
    elif ctx.os.environ.get("CIRCLECI"):
        provider = "circleci"
        env_data["repository_url"] = ctx.os.environ.get("CIRCLE_REPOSITORY_URL") or ""
        env_data["sha"] = ctx.os.environ.get("CIRCLE_SHA1") or ""
        env_data["branch"] = ctx.os.environ.get("CIRCLE_BRANCH") or ""
    elif ctx.os.environ.get("GITHUB_SHA"):
        provider = "github_actions"
        gh_repo = ctx.os.environ.get("GITHUB_REPOSITORY") or ""
        gh_server = ctx.os.environ.get("GITHUB_SERVER_URL") or "https://github.com"
        if gh_repo:
            env_data["repository_url"] = "%s/%s.git" % (gh_server, gh_repo)
        env_data["sha"] = ctx.os.environ.get("GITHUB_SHA") or ""
        env_data["branch"] = _normalize_ref(ctx.os.environ.get("GITHUB_REF") or "")
    elif ctx.os.environ.get("GITLAB_CI"):
        provider = "gitlab"
        env_data["repository_url"] = ctx.os.environ.get("CI_REPOSITORY_URL") or ""
        env_data["sha"] = ctx.os.environ.get("CI_COMMIT_SHA") or ""
        env_data["branch"] = ctx.os.environ.get("CI_COMMIT_BRANCH") or ""
        env_data["commit_message"] = ctx.os.environ.get("CI_COMMIT_MESSAGE") or ""
        env_data["head_sha"] = ctx.os.environ.get("CI_MERGE_REQUEST_SOURCE_BRANCH_SHA") or ""
    elif ctx.os.environ.get("JENKINS_URL"):
        provider = "jenkins"
        env_data["repository_url"] = _first_env(ctx, ["GIT_URL", "GIT_URL_1"]) or ""
        env_data["sha"] = ctx.os.environ.get("GIT_COMMIT") or ""
        env_data["branch"] = ctx.os.environ.get("GIT_BRANCH") or ""
    elif ctx.os.environ.get("TEAMCITY_VERSION"):
        provider = "teamcity"
        env_data["repository_url"] = ctx.os.environ.get("GIT_URL") or ""
        env_data["sha"] = ctx.os.environ.get("GIT_COMMIT") or ""
        env_data["branch"] = ctx.os.environ.get("GIT_BRANCH") or ""
    elif ctx.os.environ.get("TRAVIS"):
        provider = "travisci"
        slug = ctx.os.environ.get("TRAVIS_REPO_SLUG") or ""
        if slug:
            env_data["repository_url"] = "https://github.com/%s.git" % slug
        env_data["sha"] = ctx.os.environ.get("TRAVIS_COMMIT") or ""
        env_data["branch"] = _first_env(ctx, ["TRAVIS_PULL_REQUEST_BRANCH", "TRAVIS_BRANCH"]) or ""
        env_data["commit_message"] = ctx.os.environ.get("TRAVIS_COMMIT_MESSAGE") or ""
    elif ctx.os.environ.get("BITRISE_BUILD_SLUG"):
        provider = "bitrise"
        env_data["repository_url"] = ctx.os.environ.get("BITRISE_GIT_REPOSITORY_URL") or ""
        env_data["sha"] = ctx.os.environ.get("BITRISE_GIT_COMMIT") or ""
        env_data["branch"] = ctx.os.environ.get("BITRISE_GIT_BRANCH") or ""
    elif ctx.os.environ.get("CF_BUILD_ID"):
        provider = "codefresh"
        env_data["branch"] = ctx.os.environ.get("CF_BRANCH") or ""
    elif ctx.os.environ.get("CODEBUILD_INITIATOR"):
        provider = "awscodepipeline"
        # Limited extraction by default

    elif ctx.os.environ.get("DRONE"):
        provider = "drone"
        env_data["repository_url"] = ctx.os.environ.get("DRONE_GIT_HTTP_URL") or ""
        env_data["sha"] = ctx.os.environ.get("DRONE_COMMIT_SHA") or ""
        env_data["branch"] = ctx.os.environ.get("DRONE_BRANCH") or ""
        env_data["commit_message"] = ctx.os.environ.get("DRONE_COMMIT_MESSAGE") or ""

    # Normalize ref formats
    env_data["branch"] = _normalize_ref(env_data.get("branch"))

    # Overlay with user-specific DD_* overrides when present (highest precedence)
    dd_repo = ctx.os.environ.get("DD_GIT_REPOSITORY_URL") or ""
    dd_branch = ctx.os.environ.get("DD_GIT_BRANCH") or ""
    dd_sha = ctx.os.environ.get("DD_GIT_COMMIT_SHA") or ""
    dd_head_sha = ctx.os.environ.get("DD_GIT_HEAD_COMMIT") or ""
    dd_commit_msg = ctx.os.environ.get("DD_GIT_COMMIT_MESSAGE") or ""
    dd_head_msg = ctx.os.environ.get("DD_GIT_HEAD_MESSAGE") or ""
    if dd_repo:
        env_data["repository_url"] = dd_repo
    if dd_branch:
        env_data["branch"] = _normalize_ref(dd_branch)
    if dd_sha:
        env_data["sha"] = dd_sha
    if dd_head_sha:
        env_data["head_sha"] = dd_head_sha
    if dd_commit_msg:
        env_data["commit_message"] = dd_commit_msg
    if dd_head_msg:
        env_data["head_message"] = dd_head_msg

    # Expose provider name to callers (e.g., for context tags)
    env_data["ci_provider_name"] = provider
    return env_data

def _build_configurations_json(ctx, debug):
    # _build_configurations_json: builds a testConfigurations structure with
    # auto-detected os.* fields plus simple runtime fields.
    #
    # Note: runtime name and runtime version have different semantics. Keep
    # dedicated validators so future constraints can evolve independently.
    osinfo = _detect_os_info(ctx, debug)
    runtime_name = validate_runtime_name(ctx.attr.runtime_name, debug) or "unknown"
    runtime_version = validate_runtime_version(ctx.attr.runtime_version, debug) or "unknown"
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

def _build_context_tags(ctx, env_data, api_key, debug):
    # _build_context_tags: aggregates CI, git, OS, and runtime tags for context.json
    tags = {}

    # OS tags
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

    # Git tags (base)
    if env_data.get("repository_url"):
        tags["git.repository_url"] = env_data.get("repository_url")
    if env_data.get("branch"):
        tags["git.branch"] = env_data.get("branch")
    if env_data.get("sha"):
        tags["git.commit.sha"] = env_data.get("sha")
    if env_data.get("head_sha"):
        tags["git.commit.head.sha"] = env_data.get("head_sha")
    if env_data.get("commit_message"):
        tags["git.commit.message"] = env_data.get("commit_message")
    if env_data.get("head_message"):
        tags["git.commit.head.message"] = env_data.get("head_message")

    # Git overrides / extended tags via DD_* env
    def _opt(env_key, tag_key):
        v = ctx.os.environ.get(env_key)
        if v:
            tags[tag_key] = v

    _opt("DD_GIT_TAG", "git.tag")

    _opt("DD_GIT_COMMIT_AUTHOR_NAME", "git.commit.author.name")
    _opt("DD_GIT_COMMIT_AUTHOR_EMAIL", "git.commit.author.email")
    _opt("DD_GIT_COMMIT_AUTHOR_DATE", "git.commit.author.date")
    _opt("DD_GIT_COMMIT_COMMITTER_NAME", "git.commit.committer.name")
    _opt("DD_GIT_COMMIT_COMMITTER_EMAIL", "git.commit.committer.email")
    _opt("DD_GIT_COMMIT_COMMITTER_DATE", "git.commit.committer.date")

    _opt("DD_GIT_HEAD_AUTHOR_NAME", "git.commit.head.author.name")
    _opt("DD_GIT_HEAD_AUTHOR_EMAIL", "git.commit.head.author.email")
    _opt("DD_GIT_HEAD_AUTHOR_DATE", "git.commit.head.author.date")
    _opt("DD_GIT_HEAD_COMMITTER_NAME", "git.commit.head.committer.name")
    _opt("DD_GIT_HEAD_COMMITTER_EMAIL", "git.commit.head.committer.email")
    _opt("DD_GIT_HEAD_COMMITTER_DATE", "git.commit.head.committer.date")

    _opt("DD_GIT_PR_BASE_BRANCH", "git.pull_request.base_branch")
    _opt("DD_GIT_PR_BASE_BRANCH_SHA", "git.pull_request.base_branch_sha")
    _opt("DD_GIT_PR_BASE_BRANCH_HEAD_SHA", "git.pull_request.base_branch_head_sha")
    _opt("DD_PR_NUMBER", "pr.number")

    # CI provider/name
    if env_data.get("ci_provider_name"):
        tags["ci.provider.name"] = env_data.get("ci_provider_name")

    # Service and environment (non-secret)
    if env_data.get("service"):
        tags["service.name"] = env_data.get("service")
    if env_data.get("environment"):
        tags["env"] = env_data.get("environment")

    # CI workspace path
    ws = _first_env(ctx, [
        "CI_PROJECT_DIR",
        "GITHUB_WORKSPACE",
        "WORKSPACE",
        "BUILDKITE_BUILD_CHECKOUT_PATH",
        "TRAVIS_BUILD_DIR",
    ])
    if ws:
        tags["ci.workspace_path"] = ws

    # CI pipeline identifiers
    pipeline_id = _first_env(ctx, [
        "CI_PIPELINE_ID",
        "GITHUB_RUN_ID",
        "TRAVIS_BUILD_ID",
        "BUILDKITE_BUILD_ID",
        "BUILD_BUILDID",
        "CIRCLE_WORKFLOW_ID",
    ])
    if pipeline_id:
        tags["ci.pipeline.id"] = pipeline_id

    pipeline_number = _first_env(ctx, [
        "CI_PIPELINE_IID",
        "GITHUB_RUN_NUMBER",
        "TRAVIS_BUILD_NUMBER",
        "BUILDKITE_BUILD_NUMBER",
        "BUILD_BUILDNUMBER",
    ])
    if pipeline_number:
        tags["ci.pipeline.number"] = pipeline_number

    # CI pipeline URL: prefer provider URL then synthesize for GitHub
    pipeline_url = _first_env(ctx, [
        "CI_PIPELINE_URL",
        "TRAVIS_BUILD_WEB_URL",
        "CIRCLE_BUILD_URL",
        "BUILDKITE_BUILD_URL",
        "BUILD_BUILDURI",
    ])
    if not pipeline_url:
        gh_server = ctx.os.environ.get("GITHUB_SERVER_URL") or ""
        gh_repo = ctx.os.environ.get("GITHUB_REPOSITORY") or ""
        gh_run_id = ctx.os.environ.get("GITHUB_RUN_ID") or ""
        if gh_server and gh_repo and gh_run_id:
            pipeline_url = "%s/%s/actions/runs/%s" % (gh_server, gh_repo, gh_run_id)
    if pipeline_url:
        tags["ci.pipeline.url"] = pipeline_url

    # CI pipeline name (best-effort)
    pipeline_name = _first_env(ctx, [
        "GITHUB_WORKFLOW",
        "CI_PROJECT_PATH",
    ])
    if pipeline_name:
        tags["ci.pipeline.name"] = pipeline_name

    # CI job identifiers
    job_id = _first_env(ctx, [
        "CI_JOB_ID",
        "BUILD_ID",
        "TRAVIS_JOB_ID",
    ])
    if job_id:
        tags["ci.job.id"] = job_id

    job_name = _first_env(ctx, [
        "CI_JOB_NAME",
        "GITHUB_JOB",
        "JOB_NAME",
    ])
    if job_name:
        tags["ci.job.name"] = job_name

    job_url = _first_env(ctx, [
        "CI_JOB_URL",
        "TRAVIS_JOB_WEB_URL",
        "BUILD_URL",
    ])
    if job_url:
        tags["ci.job.url"] = job_url

    # CI stage, node
    stage_name = ctx.os.environ.get("CI_JOB_STAGE")
    if stage_name:
        tags["ci.stage.name"] = stage_name
    node_name = ctx.os.environ.get("NODE_NAME")
    if node_name:
        tags["ci.node.name"] = node_name
    node_labels = ctx.os.environ.get("NODE_LABELS")
    if node_labels:
        tags["ci.node.labels"] = node_labels

    # Embed a non-reversible fingerprint to validate uploader key parity.
    fingerprint = _api_key_fingerprint(api_key)
    if fingerprint:
        tags["topt.api_key_fingerprint"] = fingerprint
        log_debug(debug, "context", "api key fingerprint enabled")

    log_debug(debug, "context", "context.json tags: %s" % json.encode(tags))
    return tags

# ##########################################################################
# Request builders
# ##########################################################################

def _perform_dd_settings_request(ctx, api_key, env_data, settings_file, debug):
    # _perform_dd_settings_request: build and send the CI Visibility Settings request.
    # - Writes the JSON response body to `settings_file`.
    # - Returns curl's exit code (0 on success, otherwise fail() already raised inside helper).
    # Datadog CI Visibility settings endpoint
    # Path: api/v2/libraries/tests/services/setting
    # Type: ci_app_test_service_libraries_settings
    base = _resolve_dd_api_base(env_data, debug)
    url = "%s/%s" % (base, "api/v2/libraries/tests/services/setting")

    # Gather request attributes from environment
    service = env_data.get("service")
    environment = env_data.get("environment")
    repository_url = env_data.get("repository_url")
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

    return_code = _http_post_json(
        ctx,
        url,
        headers,
        body,
        "settings.request.json",
        settings_file,
        debug,
    )
    return return_code

def _perform_dd_known_tests_request(ctx, api_key, env_data, known_tests_file, debug):
    # _perform_dd_known_tests_request: build and send the Known Tests request.
    # - Writes the JSON response body to `known_tests_file`.
    # - Returns curl's exit code (0 on success, otherwise fail() already raised inside helper).
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
    configurations_json = _build_configurations_json(ctx, debug)
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
    )

def _perform_dd_test_management_tests_request(ctx, api_key, env_data, test_management_file, debug):
    # _perform_dd_test_management_tests_request: build and send the Test Management Tests request.
    # - Writes the JSON response body to `test_management_file`.
    # Datadog Test Management Tests endpoint
    # Path: api/v2/test/libraries/test-management/tests
    # Type: ci_app_libraries_tests_request
    base = _resolve_dd_api_base(env_data, debug)
    url = "%s/%s" % (base, "api/v2/test/libraries/test-management/tests")

    # Required attributes per API
    repository_url = env_data.get("repository_url")

    # Prefer head commit if present; else fall back
    sha = env_data.get("head_sha") or env_data.get("sha") or ""

    # Commit message: prefer head message then commit message; else empty
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
    )

# ##########################################################################
# Repository rule implementation
# ##########################################################################

def _impl(ctx):
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
    out_dir = ctx.attr.out_dir or TEST_OPT_DIR
    settings_file = "%s/%s" % (out_dir, "settings.json")
    known_tests_file = "%s/%s" % (out_dir, "known_tests.json")
    test_management_file = "%s/%s" % (out_dir, "test_management.json")
    manifest_file = "%s/%s" % (out_dir, "manifest.txt")
    _ensure_parent_directory(ctx, settings_file, debug)
    _ensure_parent_directory(ctx, known_tests_file, debug)
    _ensure_parent_directory(ctx, test_management_file, debug)
    _ensure_parent_directory(ctx, manifest_file, debug)

    log_info("Settings file: %s" % settings_file)
    ctx.report_progress("test_optimization_sync: downloading")
    env_data = _collect_env(ctx)
    
    # Validate and normalize service name
    raw_service = env_data.get("service")
    validated_service = validate_service_name(raw_service, debug)
    env_data["service"] = validated_service
    
    log_debug(debug, "validation", "Env data collected and validated")
    _perform_dd_settings_request(ctx, api_key, env_data, settings_file, debug)
    ctx.report_progress("test_optimization_sync: download complete")

    # Decide whether to fetch known tests/test-management based on settings (use repository_ctx.read + json.decode)
    # Additionally, support local kill-switches exposed as rule attributes to force-disable
    # any of these features regardless of server-side configuration.
    known_tests_enabled = False

    test_management_enabled = False
    settings_path = ctx.path(settings_file)
    settings_content = ctx.read(settings_path)
    if settings_content and settings_content.strip():
        settings_obj = _decode_json_object_or_fail(settings_content, settings_file)
        data_obj = settings_obj.get("data") or {}
        attrs_obj = data_obj.get("attributes") or {}
        enabled_val = attrs_obj.get("known_tests_enabled")
        known_tests_enabled = (enabled_val == True)

        tm_obj = attrs_obj.get("test_management") or {}
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
            if type(data_obj) != "dict":
                settings_obj["data"] = {"attributes": {}}
                data_obj = settings_obj["data"]
                attrs_obj = data_obj["attributes"]
            elif ("attributes" not in data_obj) or (type(data_obj.get("attributes")) != "dict"):
                data_obj["attributes"] = {}
                attrs_obj = data_obj["attributes"]
            attrs_obj["known_tests_enabled"] = False

        if hasattr(ctx.attr, "test_management") and ctx.attr.test_management == False:
            test_management_enabled = False
            if type(data_obj) != "dict":
                settings_obj["data"] = {"attributes": {}}
                data_obj = settings_obj["data"]
                attrs_obj = data_obj["attributes"]
            elif ("attributes" not in data_obj) or (type(data_obj.get("attributes")) != "dict"):
                data_obj["attributes"] = {}
                attrs_obj = data_obj["attributes"]

            # Ensure nested test_management object exists and set enabled=false
            tm_mut = attrs_obj.get("test_management")
            if type(tm_mut) != "dict":
                tm_mut = {}
            tm_mut["enabled"] = False
            attrs_obj["test_management"] = tm_mut

        # Persist the possibly-updated settings back to disk so that the
        # overridden disablement is reflected to later phases.
        ctx.file(settings_file, json.encode(settings_obj) + "\n")
    else:
        log_debug(debug, "settings", "Settings file is empty; cannot determine feature flags")

    # Always produce known tests and test-management files; write empty stubs when disabled
    # Write manifest version (v1) to manifest.txt for change tracking
    ctx.file(manifest_file, "version=1\n")

    exports = [settings_file, manifest_file]
    module_specs_known = []
    module_specs_tm = []
    if known_tests_enabled:
        ctx.report_progress("test_optimization_sync: downloading known tests")
        _perform_dd_known_tests_request(ctx, api_key, env_data, known_tests_file, debug)
        ctx.report_progress("test_optimization_sync: known tests complete")
    else:
        log_debug(debug, "known_tests", "known_tests_enabled is false; writing empty known tests file")

        # Minimal valid JSON structure
        ctx.file(known_tests_file, '{"data": {"attributes": {"tests": {}}}}\n')

    # Always add known_tests.json to exports (either real data or stub)
    exports.append(known_tests_file)

    if test_management_enabled:
        ctx.report_progress("test_optimization_sync: downloading test management tests")
        _perform_dd_test_management_tests_request(ctx, api_key, env_data, test_management_file, debug)
        ctx.report_progress("test_optimization_sync: test management tests complete")
    else:
        log_debug(debug, "test_management", "test_management.enabled is false; writing empty test management tests file")

        # Minimal valid JSON structure for test management tests
        ctx.file(test_management_file, '{"data": {"attributes": {"modules": {}}}}\n')

    # Always add test_management.json to exports (either real data or stub)
    exports.append(test_management_file)

    # Build unified module label mapping to avoid cross-feature collisions
    known_modules = _collect_known_tests_modules(ctx, known_tests_file)
    tm_modules = _collect_test_management_modules(ctx, test_management_file)
    label_map = _build_module_label_map(known_modules, tm_modules)

    # Split known tests and test management by module into dedicated files
    module_specs_known = _split_known_tests_by_module(ctx, known_tests_file, debug, label_map = label_map)
    module_specs_tm = _split_test_management_by_module(ctx, test_management_file, debug, label_map = label_map)

    # Build and write context.json (non-secret metadata) in the same repo
    context_tags = _build_context_tags(ctx, env_data, api_key, debug)
    ctx.file("context.json", json.encode(context_tags) + "\n")

    # Emit a small helper .bzl with detected Go module path (if any) for downstream macros
    go_module_path = _detect_go_module_path(ctx, debug)
    sanitized_go_module_path = sanitize_label_fragment(go_module_path) if go_module_path else ""

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
            go_module_included = True

    # Unified export file for simpler loading from user repos
    # Prefer the apparent repo name passed by the extension/WORKSPACE helper; fallback to ctx.name
    repo_name = (getattr(ctx.attr, "repo_name", None) or ctx.name or "")
    export_bzl = _render_export_bzl(
        repo_name,
        labels,
        set_literal,
        go_module_path,
        sanitized_go_module_path,
        go_module_included,
        manifest_file,
    )
    ctx.file("export.bzl", export_bzl)

    # Rule to present per-module files with canonical runfile names via symlinks
    module_runfiles_bzl = (
        "def _topt_module_files_impl(ctx):\n" +
        "    syms = {}\n" +
        "    syms[\".testoptimization/settings.json\"] = ctx.file.settings\n" +
        "    syms[\".testoptimization/manifest.txt\"] = ctx.file.manifest\n" +
        "    kt = getattr(ctx.file, \"known_tests\", None)\n" +
        "    if kt:\n" +
        "        syms[\".testoptimization/known_tests.json\"] = kt\n" +
        "    tm = getattr(ctx.file, \"test_management\", None)\n" +
        "    if tm:\n" +
        "        syms[\".testoptimization/test_management.json\"] = tm\n" +
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
        '    srcs = ["context.json"],\n' +
        '    visibility = ["//visibility:public"],\n' +
        ")\n" +
        '\nexports_files(["export.bzl", ".testoptimization/manifest.txt"])\n'
    )

    # Append one filegroup per module so consumers can depend on individual modules
    if module_specs_known or module_specs_tm:
        labels_for_modules = labels
        if not labels_for_modules:
            # Fallback: derive labels from specs if mapping is unavailable
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
            build_content += ("\ntopt_module_files(\n" +
                ('    name = "module_%s",\n' % lab) +
                ('    settings = "%s",\n' % settings_file) +
                ('    manifest = "%s",\n' % manifest_file) +
                (('    known_tests = "%s",\n' % known_by_label.get(lab)) if known_by_label.get(lab) else "") +
                (('    test_management = "%s",\n' % tm_by_label.get(lab)) if tm_by_label.get(lab) else "") +
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
        # Environment variables treated as rule inputs
        "DD_API_KEY",  # Required: Datadog API key for authentication
        "DD_SITE",  # Optional: Datadog site; ex: app.datadoghq.com, datadoghq.eu
        "DD_TOPT_API_BASE",  # Optional: override Datadog API base URL (test/dev)
        "FETCH_SALT",  # Optional: cache-busting salt to force re-fetch
        "GIT_DIRTY",  # Optional: working tree state; triggers refetch on change
        "GO_MODULE_PATH",  # Optional: explicit Go module path override for export.bzl
        # Host OS hints used for cross-platform behavior and request configuration
        "OS",  # Windows OS marker (used in _is_windows and _detect_os_info)
        "ComSpec",  # Windows command processor path
        "COMSPEC",  # Alternate casing for Windows command processor
        "PROCESSOR_ARCHITECTURE",  # Windows arch detection
        "PROCESSOR_ARCHITEW6432",  # Windows WOW64 arch detection
        "DD_ENV",  # Optional: settings payload attribute "env"
        "DD_SERVICE",  # Optional: settings payload attribute "service"
        # If the following are unset, they will be inferred via git in the workspace
        "DD_GIT_REPOSITORY_URL",  # Optional: settings payload "repository_url" (fallback: git remote.origin.url)
        "DD_GIT_BRANCH",  # Optional: settings payload "branch" (fallback: git rev-parse --abbrev-ref HEAD)
        "DD_GIT_COMMIT_SHA",  # Optional: settings payload "sha" (fallback: git rev-parse HEAD)
        # Additional optional context used by requests (test management prefers head values)
        "DD_GIT_HEAD_COMMIT",  # Optional: preferred head commit SHA
        "DD_GIT_COMMIT_MESSAGE",  # Optional: commit message
        "DD_GIT_HEAD_MESSAGE",  # Optional: preferred head commit message
        # Extended git tags used for context.json (non-secret)
        "DD_GIT_TAG",
        "DD_GIT_COMMIT_AUTHOR_NAME",
        "DD_GIT_COMMIT_AUTHOR_EMAIL",
        "DD_GIT_COMMIT_AUTHOR_DATE",
        "DD_GIT_COMMIT_COMMITTER_NAME",
        "DD_GIT_COMMIT_COMMITTER_EMAIL",
        "DD_GIT_COMMIT_COMMITTER_DATE",
        "DD_GIT_HEAD_AUTHOR_NAME",
        "DD_GIT_HEAD_AUTHOR_EMAIL",
        "DD_GIT_HEAD_AUTHOR_DATE",
        "DD_GIT_HEAD_COMMITTER_NAME",
        "DD_GIT_HEAD_COMMITTER_EMAIL",
        "DD_GIT_HEAD_COMMITTER_DATE",
        "DD_GIT_PR_BASE_BRANCH",
        "DD_GIT_PR_BASE_BRANCH_SHA",
        "DD_GIT_PR_BASE_BRANCH_HEAD_SHA",
        "DD_PR_NUMBER",
        # CI provider detection envs (adds robustness to repo rule caching)
        "APPVEYOR",
        "APPVEYOR_REPO_NAME",
        "APPVEYOR_REPO_PROVIDER",
        "APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH",
        "APPVEYOR_REPO_BRANCH",
        "APPVEYOR_REPO_COMMIT",
        "TF_BUILD",
        "BUILD_REPOSITORY_URI",
        "BUILD_SOURCEVERSION",
        "BUILD_SOURCEBRANCH",
        "BUILD_SOURCEVERSIONMESSAGE",
        "BITBUCKET_COMMIT",
        "BITBUCKET_REPO_SLUG",
        "BITBUCKET_BRANCH",
        "BITBUCKET_GIT_HTTP_ORIGIN",
        "BUDDY",
        "BUILDKITE",
        "BUILDKITE_REPO",
        "BUILDKITE_COMMIT",
        "BUILDKITE_BRANCH",
        "BUILDKITE_MESSAGE",
        "CIRCLECI",
        "CIRCLE_REPOSITORY_URL",
        "CIRCLE_SHA1",
        "CIRCLE_BRANCH",
        "GITHUB_SHA",
        "GITHUB_REPOSITORY",
        "GITHUB_SERVER_URL",
        "GITHUB_REF",
        "GITLAB_CI",
        "CI_REPOSITORY_URL",
        "CI_COMMIT_SHA",
        "CI_COMMIT_BRANCH",
        "CI_COMMIT_MESSAGE",
        "CI_MERGE_REQUEST_SOURCE_BRANCH_SHA",
        "JENKINS_URL",
        "GIT_URL",
        "GIT_URL_1",
        "GIT_COMMIT",
        "GIT_BRANCH",
        "TEAMCITY_VERSION",
        "TRAVIS",
        "TRAVIS_REPO_SLUG",
        "TRAVIS_COMMIT",
        "TRAVIS_PULL_REQUEST_BRANCH",
        "TRAVIS_BRANCH",
        "TRAVIS_COMMIT_MESSAGE",
        "BITRISE_BUILD_SLUG",
        "BITRISE_GIT_REPOSITORY_URL",
        "BITRISE_GIT_COMMIT",
        "BITRISE_GIT_BRANCH",
        "CF_BUILD_ID",
        "CF_BRANCH",
        "CODEBUILD_INITIATOR",
        "DRONE",
        "DRONE_GIT_HTTP_URL",
        "DRONE_COMMIT_SHA",
        "DRONE_BRANCH",
        "DRONE_COMMIT_MESSAGE",
        # Additional CI and workspace envs used in context.json
        "CI_PROJECT_DIR",
        "CI_PROJECT_PATH",
        "GITHUB_WORKSPACE",
        "GITHUB_WORKFLOW",
        "WORKSPACE",
        "BUILDKITE_BUILD_CHECKOUT_PATH",
        "TRAVIS_BUILD_DIR",
        "CI_PIPELINE_ID",
        "GITHUB_RUN_ID",
        "TRAVIS_BUILD_ID",
        "BUILDKITE_BUILD_ID",
        "BUILD_BUILDID",
        "CIRCLE_WORKFLOW_ID",
        "CI_PIPELINE_IID",
        "GITHUB_RUN_NUMBER",
        "TRAVIS_BUILD_NUMBER",
        "BUILDKITE_BUILD_NUMBER",
        "BUILD_BUILDNUMBER",
        "CI_PIPELINE_URL",
        "TRAVIS_BUILD_WEB_URL",
        "CIRCLE_BUILD_URL",
        "BUILDKITE_BUILD_URL",
        "BUILD_BUILDURI",
        "CI_JOB_ID",
        "BUILD_ID",
        "TRAVIS_JOB_ID",
        "CI_JOB_NAME",
        "GITHUB_JOB",
        "JOB_NAME",
        "CI_JOB_URL",
        "TRAVIS_JOB_WEB_URL",
        "BUILD_URL",
        "CI_JOB_STAGE",
        "NODE_NAME",
        "NODE_LABELS",
    ],
    local = True,  # Always run this rule locally, bypassing repository cache
)

# Module extension implementation for Bazel 6+ MODULE.bazel system
def _test_optimization_sync_extension_impl(module_ctx):
    """Implementation of the test_optimization_sync module extension."""

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

    for mod in module_ctx.modules:
        log_debug(extension_debug, "extension", "Processing module: %s" % mod.name)
        log_debug(extension_debug, "extension", "Module is_root: %s" % mod.is_root)
        log_debug(extension_debug, "extension", "Number of test_optimization_sync tags: %d" % len(mod.tags.test_optimization_sync))

        for test_optimization_call in mod.tags.test_optimization_sync:
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
                out_dir = test_optimization_call.out_dir,
                service = test_optimization_call.service,
                runtime_name = test_optimization_call.runtime_name,
                runtime_version = test_optimization_call.runtime_version,
                runtime_arch = test_optimization_call.runtime_arch,
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
            # Optional kill-switches (default True keeps server behavior; False disables feature locally)
            "known_tests": attr.bool(default = True),
            "test_management": attr.bool(default = True),
            "debug": attr.bool(default = False),
        }),
    },
)
