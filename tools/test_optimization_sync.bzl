# Datadog Test Optimization repository rule helpers and module extension
#
# This file defines:
# - A repository_rule (`test_optimization_sync`) that performs one or more
#   authenticated HTTP POST requests to Datadog to retrieve Test Optimization
#   metadata.
# - Reusable helpers for building curl commands, ensuring output directories
#   exist, and parsing JSON in Starlark.
# - A first request to the Settings API which always runs and writes
#   `settings_file`.
# - An optional second request to the Known Tests API when the settings say
#   `known_tests_enabled = true`, writing `known_tests_file`. If disabled, an
#   empty JSON stub for known tests is still written so downstream consumers
#   can always depend on the declared outputs.

# ##########################################################################
# Constants and logging
# ##########################################################################

TEST_OPT_DIR = ".testoptimization"

def log_info(message):
    # log_info: user-facing progress messages
    print("test_optimization_sync: %s" % message)

def log_debug(debug_enabled, message):
    # log_debug: gated by the rule/tag `debug` attribute; useful for verbose traces
    if debug_enabled:
        print("test_optimization_sync: %s" % message)

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
    log_debug(debug, "Ensured directory '%s' for output '%s' (rc=%d)" % (dirp, path, res.return_code))
    if res.return_code != 0:
        fail("Failed creating directory %s for output %s: %s" % (dirp, path, (res.stderr or "").strip()))

def _sanitize_label_fragment(name):
    # _sanitize_label_fragment: produce a safe Bazel target name fragment derived from an arbitrary string.
    # - Lowercase
    # - Allowed characters: [a-z0-9_]
    # - All other characters become '_'
    # - Collapse multiple consecutive '_'
    s = (name or "").lower()
    allowed = "abcdefghijklmnopqrstuvwxyz0123456789_"
    out = []
    last_us = False
    n_s = len(s)
    for i in range(n_s):
        ch = s[i]
        if ch in allowed:
            out.append(ch)
            last_us = (ch == "_")
        elif not last_us:
            out.append("_")
            last_us = True

    # Trim leading/trailing underscores without while loops
    n = len(out)
    start = 0
    found_start = False
    for i in range(n):
        if out[i] != "_":
            start = i
            found_start = True
            break
    if not found_start:
        start = n
    end = 0

    # Reverse scan without a negative-step range
    for k in range(n):
        j = n - 1 - k
        if j < 0:
            break
        if out[j] != "_":
            end = j + 1
            break
    result = "".join(out[start:end])
    if not result:
        result = "module"
    return result

def _sanitize_filename_fragment(name):
    # _sanitize_filename_fragment: safe filename fragment for JSON files
    # - Lowercase
    # - Allowed characters: [a-z0-9._-]
    # - Others → '_'
    s = (name or "").lower()
    allowed = "abcdefghijklmnopqrstuvwxyz0123456789._-"
    out = []
    n_s = len(s)
    for i in range(n_s):
        ch = s[i]
        out.append(ch if ch in allowed else "_")
    result = "".join(out)

    # Avoid empty names
    if not result:
        result = "module"
    return result

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
    log_debug(debug, "GO_MODULE_PATH env: %s" % (mod_env or "<unset>"))
    if mod_env:
        log_debug(debug, "Using GO_MODULE_PATH from env")
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
        log_debug(debug, "Checking go.mod at: %s" % go_mod_path)
        content = _try_read_abs_file(ctx, go_mod_path)
        if content:
            mp = _parse_go_module_path(content)
            if mp:
                log_debug(debug, "Detected module path '%s' from %s" % (mp, go_mod_path))
                return mp

    # Fallback: try using git to find toplevel go.mod
    top = ""
    if _is_windows(ctx):
        r = ctx.execute(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "git rev-parse --show-toplevel"], timeout = 10)
    else:
        r = ctx.execute(["bash", "-c", "git rev-parse --show-toplevel"], timeout = 10)
    if r.return_code == 0 and r.stdout:
        top = r.stdout.strip()
    log_debug(debug, "git toplevel: %s" % (top or "<unset>"))
    if top:
        go_mod_path = top.rstrip("/") + "/go.mod"
        log_debug(debug, "Checking go.mod at: %s" % go_mod_path)
        content = _try_read_abs_file(ctx, go_mod_path)
        if content:
            mp = _parse_go_module_path(content)
            if mp:
                log_debug(debug, "Detected module path '%s' from %s" % (mp, go_mod_path))
                return mp
    log_debug(debug, "Go module path not detected; returning empty")
    return ""

def _split_known_tests_by_module(ctx, known_tests_file, debug):
    # _split_known_tests_by_module: from the combined known_tests JSON, produce
    # one JSON file per module under the same directory as `known_tests_file`.
    # Returns a list of dicts with keys: module, label, file
    specs = []
    kt_path = ctx.path(known_tests_file)
    content = ctx.read(kt_path)
    if not content or not content.strip():
        return specs

    # Decode and navigate to data.attributes.tests (map: module -> suites map)
    obj = json.decode(content)
    data_obj = obj.get("data") or {}
    attrs_obj = data_obj.get("attributes") or {}
    tests_obj = attrs_obj.get("tests") or {}
    if type(tests_obj) != "dict":
        return specs

    base_dir = _dirname(known_tests_file)

    # Ensure deterministic ordering for reproducible BUILD content
    module_names = sorted([k for k in tests_obj.keys()])

    # Counters to create deterministic de-dup suffixed names without while loops
    label_counts = {}
    file_counts = {}

    for module_name in module_names:
        suites_map = tests_obj.get(module_name)

        # Guard against non-dict anomalies
        if type(suites_map) != "dict":
            continue

        # Compute unique, sanitized target name and filename fragments
        base_label = _sanitize_label_fragment(module_name)
        c = label_counts.get(base_label, 0) + 1
        label_counts[base_label] = c
        label = base_label if c == 1 else ("%s_%d" % (base_label, c))

        base_file = _sanitize_filename_fragment(module_name)
        fc = file_counts.get(base_file, 0) + 1
        file_counts[base_file] = fc

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
        log_debug(debug, "Wrote per-module known tests file '%s' for module '%s'" % (out_file, module_name))

        specs.append({
            "module": module_name,
            "label": label,
            "file": out_file,
        })

    return specs

def _split_test_management_by_module(ctx, test_management_file, debug):
    # _split_test_management_by_module: from the combined test_management JSON, produce
    # one JSON file per module under the same directory as `test_management_file`.
    # Returns a list of dicts with keys: module, label, file
    specs = []
    tm_path = ctx.path(test_management_file)
    content = ctx.read(tm_path)
    if not content or not content.strip():
        return specs

    # Decode and navigate to data.attributes.modules (map: module -> module suites/tests object)
    obj = json.decode(content)
    data_obj = obj.get("data") or {}
    attrs_obj = data_obj.get("attributes") or {}
    modules_obj = attrs_obj.get("modules") or {}
    if type(modules_obj) != "dict":
        return specs

    base_dir = _dirname(test_management_file)
    module_names = sorted([k for k in modules_obj.keys()])

    # Counters to create deterministic de-dup suffixed names without while loops (local scope)
    label_counts = {}
    file_counts = {}

    for module_name in module_names:
        module_content = modules_obj.get(module_name)
        if type(module_content) != "dict":
            continue

        base_label = _sanitize_label_fragment(module_name)
        c = label_counts.get(base_label, 0) + 1
        label_counts[base_label] = c
        label = base_label if c == 1 else ("%s_%d" % (base_label, c))

        base_file = _sanitize_filename_fragment(module_name)
        fc = file_counts.get(base_file, 0) + 1
        file_counts[base_file] = fc

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
        log_debug(debug, "Wrote per-module test_management file '%s' for module '%s'" % (out_file, module_name))

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
        log_debug(debug, "Detected OS → platform='%s', version='%s', arch='%s'" % (platform, version, arch))
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

    log_debug(debug, "Detected OS → platform='%s', version='%s', arch='%s'" % (platform, version, arch))
    return {"platform": platform, "version": version, "arch": arch}

def _safe_json_string(value):
    # _safe_json_string: minimal JSON string escaping for simple values.
    if value == None:
        return ""

    # Only escape backslashes and double quotes; input values are expected
    # to be short ASCII tokens (service/env/branch/SHA/URL).
    s = str(value)
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    return s

def _compute_dd_api_base(site_env):
    # _compute_dd_api_base: compute the base Datadog API URL from a site value.
    # - Input examples:
    #   site_env = "app.datadoghq.com"  -> returns https://api.datadoghq.com
    #   site_env = "datadoghq.eu"       -> returns https://api.datadoghq.eu
    #   site_env = None/""               -> returns https://api.datadoghq.com
    # - Rationale: users frequently set DD_SITE to app.*; Datadog APIs are under
    #   api.*. We normalize here for consistency.
    site = site_env or "datadoghq.com"

    # Branch: normalize app.* hostnames to api.* equivalents
    if site.startswith("app."):
        site = site[len("app."):]
    return "https://api.%s" % site

def _http_request(ctx, method, url, headers, out_file, debug, data_file = None, request_debug_payload = None):
    # _http_request: executes an HTTP call and writes the response to `out_file`.
    # - On Windows: uses PowerShell Invoke-WebRequest for portability.
    # - On Linux/macOS: uses curl with retries.
    # - Returns tool exit code (0=success) and prints HTTP status code to stdout when possible.
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
        for hk, hv in headers.items():
            lines.append("$Headers['%s'] = '%s'" % (str(hk).replace("'", "''"), str(hv).replace("'", "''")))

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
        result = ctx.execute(["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script_name])
    else:
        args = [] + _curl_base_args()
        if http_method and http_method != "GET":
            args.extend(["-X", http_method])
        for header_key, header_value in headers.items():
            args.extend(["-H", "%s: %s" % (header_key, header_value)])
        if data_file:
            args.extend(["--data-binary", "@%s" % data_file])
        args.extend([url, "-o", out_file, "-w", "%{http_code}"])
        result = ctx.execute(args)

    # Parse HTTP status code captured by tool stdout. On network errors it may be empty.
    http_status = (result.stdout or "").strip() or "000"

    # Branch: network error or tool failure
    if result.return_code != 0:
        fail(
            (
                "HTTP request failed (status=%s, method=%s, url=%s, code=%d). stderr=%s\n" +
                "response_file=%s\n" +
                ("request_body=%s" % request_debug_payload if request_debug_payload else "request_body=<none>")
            ) %
            (
                http_status,
                http_method,
                url,
                result.return_code,
                (result.stderr or "").strip(),
                out_file,
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

# ##########################################################################
# CI environment detection
# ##########################################################################

def _collect_env(ctx):
    # _collect_env: reads CI provider env once and returns a unified dict used
    # by request helpers. Detection order mirrors Datadog's providers list.
    env_data = {
        "dd_site": ctx.os.environ.get("DD_SITE") or "",
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
    osinfo = _detect_os_info(ctx, debug)
    runtime_name = ctx.attr.runtime_name or "unknown"
    runtime_version = ctx.attr.runtime_version or "unknown"
    runtime_arch = ctx.attr.runtime_arch or osinfo["arch"]
    conf_json = (
        "{" +
        ' "os.platform": "%s",' % _safe_json_string(osinfo["platform"]) +
        ' "os.version": "%s",' % _safe_json_string(osinfo["version"]) +
        ' "os.architecture": "%s",' % _safe_json_string(osinfo["arch"]) +
        ' "runtime.name": "%s",' % _safe_json_string(runtime_name) +
        ' "runtime.architecture": "%s",' % _safe_json_string(runtime_arch) +
        ' "runtime.version": "%s"' % _safe_json_string(runtime_version) +
        "}"
    )
    log_debug(debug, "Configurations JSON: %s" % conf_json)
    return conf_json

def _build_context_tags(ctx, env_data, debug):
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

    log_debug(debug, "context.json tags: %s" % json.encode(tags))
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
    base = _compute_dd_api_base(env_data.get("dd_site"))
    url = "%s/%s" % (base, "api/v2/libraries/tests/services/setting")

    # Correlation id is arbitrary
    req_id = "1"

    # Gather request attributes from environment; keep minimal and optional
    # Service and environment defaults
    # - service: DD_SERVICE or "unnamed-service"
    # - env: DD_ENV or "CI"
    service = env_data.get("service")
    environment = env_data.get("environment")
    repository_url = env_data.get("repository_url")
    branch = env_data.get("branch")
    sha = env_data.get("sha")

    # Debug print of the resolved attributes for traceability
    log_debug(
        debug,
        "Settings attributes → service='%s', env='%s', repo='%s', branch='%s', sha='%s'" % (
            service,
            environment,
            repository_url,
            branch,
            sha,
        ),
    )

    # Build minimal JSON body (configurations omitted for now)
    body = (
        "{\n" +
        "  \"data\": {\n" +
        "    \"id\": \"%s\",\n" % _safe_json_string(req_id) +
        "    \"type\": \"ci_app_test_service_libraries_settings\",\n" +
        "    \"attributes\": {\n" +
        "      \"service\": \"%s\",\n" % _safe_json_string(service) +
        "      \"env\": \"%s\",\n" % _safe_json_string(environment) +
        "      \"repository_url\": \"%s\",\n" % _safe_json_string(repository_url) +
        "      \"branch\": \"%s\",\n" % _safe_json_string(branch) +
        "      \"sha\": \"%s\"\n" % _safe_json_string(sha) +
        "    }\n" +
        "  }\n" +
        "}\n"
    )

    log_debug(debug, "Settings request body: %s" % body)

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
    base = _compute_dd_api_base(env_data.get("dd_site"))
    url = "%s/%s" % (base, "api/v2/ci/libraries/tests")

    req_id = "1"

    # Same attributes as settings request
    service = env_data.get("service")
    environment = env_data.get("environment")
    repository_url = env_data.get("repository_url")

    body = (
        "{\n" +
        "  \"data\": {\n" +
        "    \"id\": \"%s\",\n" % _safe_json_string(req_id) +
        "    \"type\": \"ci_app_libraries_tests_request\",\n" +
        "    \"attributes\": {\n" +
        "      \"service\": \"%s\",\n" % _safe_json_string(service) +
        "      \"env\": \"%s\",\n" % _safe_json_string(environment) +
        "      \"repository_url\": \"%s\",\n" % _safe_json_string(repository_url) +
        "      \"configurations\": %s\n" % _build_configurations_json(ctx, debug) +
        "    }\n" +
        "  }\n" +
        "}\n"
    )

    # Log the request body for debugging when enabled
    log_debug(debug, "KnownTests request body: %s" % body)

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
    base = _compute_dd_api_base(env_data.get("dd_site"))
    url = "%s/%s" % (base, "api/v2/test/libraries/test-management/tests")

    # Required attributes per API
    repository_url = env_data.get("repository_url")

    # Prefer head commit if present; else fall back
    sha = env_data.get("head_sha") or env_data.get("sha") or ""

    # Commit message: prefer head message then commit message; else empty
    commit_message = env_data.get("head_message") or env_data.get("commit_message") or ""

    # Build attributes JSON with optional module field only if set
    attrs = (
        "      \"repository_url\": \"%s\",\n" % _safe_json_string(repository_url) +
        "      \"sha\": \"%s\",\n" % _safe_json_string(sha) +
        "      \"commit_message\": \"%s\"\n" % _safe_json_string(commit_message)
    )

    body = (
        "{\n" +
        "  \"data\": {\n" +
        "    \"id\": \"%s\",\n" % _safe_json_string("1") +
        "    \"type\": \"ci_app_libraries_tests_request\",\n" +
        "    \"attributes\": {\n" +
        attrs +
        "    }\n" +
        "  }\n" +
        "}\n"
    )

    log_debug(debug, "TestManagementTests request body: %s" % body)

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
    debug = ctx.attr.debug
    log_info("Starting repository rule implementation")
    ctx.report_progress("test_optimization_sync: starting")

    # Read the DD_API_KEY from the environment; fail if missing
    api_key = ctx.os.environ.get("DD_API_KEY")
    log_debug(debug, "DD_API_KEY present: %s" % bool(api_key))
    if not api_key:
        fail("fetch_data: environment variable DD_API_KEY is not set")

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
    log_debug(debug, "Env data: %s" % env_data)
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
        settings_obj = json.decode(settings_content)
        data_obj = settings_obj.get("data") or {}
        attrs_obj = data_obj.get("attributes") or {}
        enabled_val = attrs_obj.get("known_tests_enabled")
        known_tests_enabled = (enabled_val == True)

        tm_obj = attrs_obj.get("test_management") or {}
        test_management_enabled = (tm_obj.get("enabled") == True)
        log_debug(debug, "known_tests_enabled parsed as: %s" % known_tests_enabled)

        log_debug(debug, "test_management.enabled parsed as: %s" % test_management_enabled)

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
        log_debug(debug, "Settings file is empty; cannot determine feature flags")

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
        log_debug(debug, "known_tests_enabled is false; writing empty known tests file")

        # Minimal valid JSON structure
        ctx.file(known_tests_file, '{"data": {"attributes": {"tests": {}}}}\n')

    # Split known tests by module into dedicated files (no-op if empty)
    module_specs_known = _split_known_tests_by_module(ctx, known_tests_file, debug)

    if test_management_enabled:
        ctx.report_progress("test_optimization_sync: downloading test management tests")
        _perform_dd_test_management_tests_request(ctx, api_key, env_data, test_management_file, debug)
        ctx.report_progress("test_optimization_sync: test management tests complete")
    else:
        log_debug(debug, "test_management.enabled is false; writing empty test management tests file")

        # Minimal valid JSON structure for test management tests
        ctx.file(test_management_file, '{"data": {"attributes": {"modules": {}}}}\n')

    # Split test_management by module into dedicated files (no-op if empty)
    module_specs_tm = _split_test_management_by_module(ctx, test_management_file, debug)

    # Build and write context.json (non-secret metadata) in the same repo
    context_tags = _build_context_tags(ctx, env_data, debug)
    ctx.file("context.json", json.encode(context_tags) + "\n")

    # Emit a small helper .bzl with detected Go module path (if any) for downstream macros
    go_module_path = _detect_go_module_path(ctx, debug)
    sanitized_go_module_path = _sanitize_label_fragment(go_module_path) if go_module_path else ""

    # Build a modules index for per-module filegroups (labels are sanitized suffixes)
    # Collect unique labels from both known-tests and tm-tests
    label_seen = {}
    labels = []
    for _s in module_specs_known:
        _lab = _s.get("label")
        if _lab and not label_seen.get(_lab):
            label_seen[_lab] = True
            labels.append(_lab)
    for _s in module_specs_tm:
        _lab = _s.get("label")
        if _lab and not label_seen.get(_lab):
            label_seen[_lab] = True
            labels.append(_lab)
    labels = sorted(labels)

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
    export_bzl = (
        "# Generated by test_optimization_sync; unified exports for test optimization info\n" +
        "topt_data = {\n" +
        "    \"repo_name\": \"%s\",\n" % repo_name +
        "    \"labels\": %s,\n" % repr(labels) +
        "    \"set\": %s,\n" % set_literal +
        "    \"go\": {\n" +
        "        \"module_path\": \"%s\",\n" % (go_module_path or "") +
        "        \"sanitized_module_path\": \"%s\",\n" % sanitized_go_module_path +
        "        \"module_included\": %s,\n" % ("True" if go_module_included else "False") +
        "    },\n" +
        "}\n"
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
        '\nexports_files(["export.bzl"])\n'
    )

    # Append one filegroup per module so consumers can depend on individual modules
    if module_specs_known or module_specs_tm:
        # Deterministic order by label without using set (not available in Starlark)
        label_seen = {}
        labels = []
        for s in module_specs_known:
            lab = s["label"]
            if not label_seen.get(lab):
                label_seen[lab] = True
                labels.append(lab)
        for s in module_specs_tm:
            lab = s["label"]
            if not label_seen.get(lab):
                label_seen[lab] = True
                labels.append(lab)
        labels = sorted(labels)

        # Map module labels to their per-module files
        known_by_label = {}
        for s in module_specs_known:
            known_by_label[s["label"]] = s["file"]
        tm_by_label = {}
        for s in module_specs_tm:
            tm_by_label[s["label"]] = s["file"]

        # Ensure per-module stubs exist for the missing side so consumers always
        # see both canonical filenames in the per-module runfiles
        for lab in labels:
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

        for lab in labels:
            build_content += ("\ntopt_module_files(\n" +
                ('    name = "module_%s",\n' % lab) +
                ('    settings = "%s",\n' % settings_file) +
                ('    manifest = "%s",\n' % manifest_file) +
                (('    known_tests = "%s",\n' % known_by_label.get(lab)) if known_by_label.get(lab) else "") +
                (('    test_management = "%s",\n' % tm_by_label.get(lab)) if tm_by_label.get(lab) else "") +
                '    visibility = ["//visibility:public"],\n' +
                ")\n")
    log_debug(debug, "Creating BUILD file with content: %s" % build_content)
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
        "FETCH_SALT",  # Optional: cache-busting salt to force re-fetch
        "GIT_DIRTY",  # Optional: working tree state; triggers refetch on change
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
        "GITHUB_WORKSPACE",
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

    log_debug(extension_debug, "test_optimization_sync_extension: Starting module extension implementation")
    log_debug(extension_debug, "test_optimization_sync_extension: Number of modules: %d" % len(module_ctx.modules))

    for mod in module_ctx.modules:
        log_debug(extension_debug, "test_optimization_sync_extension: Processing module: %s" % mod.name)
        log_debug(extension_debug, "test_optimization_sync_extension: Module is_root: %s" % mod.is_root)
        log_debug(extension_debug, "test_optimization_sync_extension: Number of test_optimization_sync tags: %d" % len(mod.tags.test_optimization_sync))

        for test_optimization_call in mod.tags.test_optimization_sync:
            call_debug = hasattr(test_optimization_call, "debug") and test_optimization_call.debug
            log_debug(call_debug, "test_optimization_sync_extension: Processing test_optimization_sync call: %s" % test_optimization_call.name)
            log_debug(
                call_debug,
                "test_optimization_sync_extension: Calling test_optimization_sync with name=%s, out_dir=%s, service=%s, debug=%s" %
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
