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
#   `known_tests_enabled = true`, writing `knowntests_file`. If disabled, an
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
        "-f", "-sS",
        "--connect-timeout", "10",
        "--max-time", "60",
        "--retry", "3",
        "--retry-delay", "2",
        "--retry-connrefused",
    ]

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
    res = ctx.execute(["mkdir", "-p", dirp])
    log_debug(debug, "Ensured directory '%s' for output '%s' (rc=%d)" % (dirp, path, res.return_code))
    if res.return_code != 0:
        fail("Failed creating directory %s for output %s: %s" % (dirp, path, (res.stderr or "").strip()))

def _resolve_output_path(out_dir, filename_attr, default_name):
    # _resolve_output_path: compute concrete path for an output file.
    # Rules:
    # - If filename_attr is empty, use out_dir/default_name
    # - If filename_attr contains a '/', treat it as an explicit path and keep it
    # - Otherwise, join out_dir/filename_attr
    if not filename_attr:
        return "%s/%s" % (out_dir, default_name)
    if "/" in filename_attr or filename_attr.startswith("./") or filename_attr.startswith("/"):
        return filename_attr
    return "%s/%s" % (out_dir, filename_attr)

def _detect_os_info(ctx, debug):
    # _detect_os_info: detect OS platform, version, and architecture using host tools.
    # Returns a dict with keys: platform, version, arch
    def _run(args):
        res = ctx.execute(args)
        return res.stdout.strip() if res.return_code == 0 and res.stdout else ""

    raw_platform = _run(["uname", "-s"]) or ""
    raw_arch = _run(["uname", "-m"]) or ""
    raw_version = _run(["uname", "-r"]) or ""

    p = raw_platform.lower()
    if "mingw" in p or "msys" in p or "cygwin" in p or p.startswith("windows"):
        platform = "windows"
    elif "darwin" in p or p == "macos" or p == "mac" or p == "osx":
        platform = "darwin"
    elif "linux" in p:
        platform = "linux"
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

def _http_request(ctx, method, url, headers, out_file, debug, data_file=None, request_debug_payload=None):
    # _http_request: executes a curl call and writes the response to `out_file`.
    # - method: HTTP verb (GET/POST)
    # - url: target endpoint
    # - headers: map of header -> value
    # - data_file: path to a file used as the request body (optional)
    # - request_debug_payload: raw JSON string only used for error logging (optional)
    # - on success: returns curl's exit code 0; logs output size if possible
    # - on failure: raises fail() with detailed diagnostics
    # Ensure output directory exists if a subdirectory is provided
    _ensure_parent_directory(ctx, out_file, debug)
    args = [] + _curl_base_args()
    # Branch: explicit HTTP method if not GET
    if method and method != "GET":
        args.extend(["-X", method])
    # Append headers (do not log them to avoid secrets in logs)
    for header_key, header_value in headers.items():
        args.extend(["-H", "%s: %s" % (header_key, header_value)])
    # Branch: attach a request body if provided
    if data_file:
        args.extend(["--data-binary", "@%s" % data_file])
    # Write response to file and capture HTTP status code on stdout
    args.extend([url, "-o", out_file, "-w", "%{http_code}"])

    # Avoid logging secrets; only log method and URL
    log_info("curl %s %s" % ((method or "GET"), url))
    result = ctx.execute(args)

    log_debug(debug, "Curl return code: %d" % result.return_code)
    if result.stdout:
        log_debug(debug, "Curl stdout: %s" % result.stdout)
    if result.stderr:
        log_debug(debug, "Curl stderr: %s" % result.stderr)

    # Parse HTTP status code captured by -w. On network errors it may be empty.
    http_status = (result.stdout or "").strip() or "000"
    # Branch: network error or curl failure
    if result.return_code != 0:
        fail(
            (
                "HTTP request failed (status=%s, method=%s, url=%s, code=%d). stderr=%s\n"
                + "response_file=%s\n"
                + ("request_body=%s" % request_debug_payload if request_debug_payload else "request_body=<none>")
            )
            % (
                http_status,
                method or "GET",
                url,
                result.return_code,
                (result.stderr or "").strip(),
                out_file,
            )
        )
    else:
        # Branch: success path; try to emit a concise size summary
        size_result = ctx.execute(["wc", "-c", out_file])
        if size_result.return_code == 0 and size_result.stdout:
            # wc -c prints: "<bytes> <filename>"; Starlark split requires an explicit sep
            parts = [p for p in size_result.stdout.strip().split(" ") if p]
            bytes_str = parts[0] if parts else "unknown"
            log_info("Downloaded %s (%s bytes) from %s" % (out_file, bytes_str, url))
        else:
            # Fallback if wc is unavailable or returns unexpected output
            log_info("Downloaded %s from %s" % (out_file, url))

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
            ctx.os.environ.get("BITBUCKET_GIT_HTTP_ORIGIN")
            or ("https://bitbucket.org/%s.git" % (ctx.os.environ.get("BITBUCKET_REPO_SLUG") or ""))
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

    return env_data

def _build_configurations_json(ctx, debug):
    # _build_configurations_json: builds a testConfigurations structure with
    # auto-detected os.* fields plus simple runtime fields.
    osinfo = _detect_os_info(ctx, debug)
    runtime_name = ctx.attr.runtime_name or "unknown"
    runtime_version = ctx.attr.runtime_version or "unknown"
    runtime_arch = ctx.attr.runtime_arch or osinfo["arch"]
    return (
        "{"
        + ' "os.platform": "%s",' % _safe_json_string(osinfo["platform"])
        + ' "os.version": "%s",' % _safe_json_string(osinfo["version"])
        + ' "os.architecture": "%s",' % _safe_json_string(osinfo["arch"])
        + ' "runtime.name": "%s",' % _safe_json_string(runtime_name)
        + ' "runtime.architecture": "%s",' % _safe_json_string(runtime_arch)
        + ' "runtime.version": "%s"' % _safe_json_string(runtime_version)
        + "}"
    )

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
        "{\n"
        + "  \"data\": {\n"
        + "    \"id\": \"%s\",\n" % _safe_json_string(req_id)
        + "    \"type\": \"ci_app_test_service_libraries_settings\",\n"
        + "    \"attributes\": {\n"
        + "      \"service\": \"%s\",\n" % _safe_json_string(service)
        + "      \"env\": \"%s\",\n" % _safe_json_string(environment)
        + "      \"repository_url\": \"%s\",\n" % _safe_json_string(repository_url)
        + "      \"branch\": \"%s\",\n" % _safe_json_string(branch)
        + "      \"sha\": \"%s\"\n" % _safe_json_string(sha)
        + "    }\n"
        + "  }\n"
        + "}\n"
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
        "{\n"
        + "  \"data\": {\n"
        + "    \"id\": \"%s\",\n" % _safe_json_string(req_id)
        + "    \"type\": \"ci_app_libraries_tests_request\",\n"
        + "    \"attributes\": {\n"
        + "      \"service\": \"%s\",\n" % _safe_json_string(service)
        + "      \"env\": \"%s\",\n" % _safe_json_string(environment)
        + "      \"repository_url\": \"%s\",\n" % _safe_json_string(repository_url)
        + "      \"configurations\": %s\n" % _build_configurations_json(ctx, debug)
        + "    }\n"
        + "  }\n"
        + "}\n"
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
        "knowntests.request.json",
        known_tests_file,
        debug,
    )

def _perform_dd_skippable_tests_request(ctx, api_key, env_data, skippables_file, debug):
    # _perform_dd_skippable_tests_request: build and send the Skippable Tests request.
    # - Writes the JSON response body to `skippables_file`.
    # Datadog Skippable Tests endpoint
    # Path: api/v2/ci/tests/skippable
    # Type: test_params
    base = _compute_dd_api_base(env_data.get("dd_site"))
    url = "%s/%s" % (base, "api/v2/ci/tests/skippable")

    # Attributes aligned with Datadog API
    service = env_data.get("service")
    environment = env_data.get("environment")
    repository_url = env_data.get("repository_url")
    sha = env_data.get("sha")

    body = (
        "{\n"
        + "  \"data\": {\n"
        + "    \"type\": \"test_params\",\n"
        + "    \"attributes\": {\n"
        + "      \"test_level\": \"test\",\n"
        + "      \"configurations\": %s,\n" % _build_configurations_json(ctx, debug)
        + "      \"service\": \"%s\",\n" % _safe_json_string(service)
        + "      \"env\": \"%s\",\n" % _safe_json_string(environment)
        + "      \"repository_url\": \"%s\",\n" % _safe_json_string(repository_url)
        + "      \"sha\": \"%s\"\n" % _safe_json_string(sha)
        + "    }\n"
        + "  }\n"
        + "}\n"
    )

    log_debug(debug, "SkippableTests request body: %s" % body)

    headers = { "DD-API-KEY": api_key }

    return _http_post_json(
        ctx,
        url,
        headers,
        body,
        "skippables.request.json",
        skippables_file,
        debug,
    )

def _perform_dd_test_management_tests_request(ctx, api_key, env_data, tmtests_file, debug):
    # _perform_dd_test_management_tests_request: build and send the Test Management Tests request.
    # - Writes the JSON response body to `tmtests_file`.
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
        "      \"repository_url\": \"%s\",\n" % _safe_json_string(repository_url)
        + "      \"sha\": \"%s\",\n" % _safe_json_string(sha)
        + "      \"commit_message\": \"%s\"\n" % _safe_json_string(commit_message)
    )

    body = (
        "{\n"
        + "  \"data\": {\n"
        + "    \"id\": \"%s\",\n" % _safe_json_string("1")
        + "    \"type\": \"ci_app_libraries_tests_request\",\n"
        + "    \"attributes\": {\n"
        + attrs
        + "    }\n"
        + "  }\n"
        + "}\n"
    )

    log_debug(debug, "TestManagementTests request body: %s" % body)

    headers = { "DD-API-KEY": api_key }

    return _http_post_json(
        ctx,
        url,
        headers,
        body,
        "tmtests.request.json",
        tmtests_file,
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
    # 5) If enabled, POST Known Tests and write `knowntests_file`; else write an empty stub
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
    settings_file = _resolve_output_path(out_dir, ctx.attr.settings_file, "settings.json")
    knowntests_file = _resolve_output_path(out_dir, ctx.attr.knowntests_file, "knowntests.json")
    skippables_file = _resolve_output_path(out_dir, ctx.attr.skippables_file, "skippabletests.json")
    tmtests_file = _resolve_output_path(out_dir, ctx.attr.tmtests_file, "tmtests.json")
    _ensure_parent_directory(ctx, settings_file, debug)
    _ensure_parent_directory(ctx, knowntests_file, debug)
    _ensure_parent_directory(ctx, skippables_file, debug)
    _ensure_parent_directory(ctx, tmtests_file, debug)

    log_info("Settings file: %s" % settings_file)
    ctx.report_progress("test_optimization_sync: downloading")
    env_data = _collect_env(ctx)
    _perform_dd_settings_request(ctx, api_key, env_data, settings_file, debug)
    ctx.report_progress("test_optimization_sync: download complete")

    # Decide whether to fetch known tests/skippables/test-management based on settings (use repository_ctx.read + json.decode)
    known_tests_enabled = False
    tests_skipping_enabled = False
    test_management_enabled = False
    settings_path = ctx.path(settings_file)
    settings_content = ctx.read(settings_path)
    if settings_content and settings_content.strip():
        settings_obj = json.decode(settings_content)
        data_obj = settings_obj.get("data") or {}
        attrs_obj = data_obj.get("attributes") or {}
        enabled_val = attrs_obj.get("known_tests_enabled")
        known_tests_enabled = (enabled_val == True)
        tests_skipping_val = attrs_obj.get("tests_skipping")
        tests_skipping_enabled = (tests_skipping_val == True)
        tm_obj = attrs_obj.get("test_management") or {}
        test_management_enabled = (tm_obj.get("enabled") == True)
        log_debug(debug, "known_tests_enabled parsed as: %s" % known_tests_enabled)
        log_debug(debug, "tests_skipping parsed as: %s" % tests_skipping_enabled)
        log_debug(debug, "test_management.enabled parsed as: %s" % test_management_enabled)
    else:
        log_debug(debug, "Settings file is empty; cannot determine feature flags")

    # Always produce known tests, skippables, and test-management files; write empty stubs when disabled
    exports = [settings_file, knowntests_file, skippables_file, tmtests_file]
    if known_tests_enabled:
        ctx.report_progress("test_optimization_sync: downloading known tests")
        _perform_dd_known_tests_request(ctx, api_key, env_data, knowntests_file, debug)
        ctx.report_progress("test_optimization_sync: known tests complete")
    else:
        log_debug(debug, "known_tests_enabled is false; writing empty known tests file")
        # Minimal valid JSON structure
        ctx.file(knowntests_file, '{"data": {"attributes": {"tests": {}}}}\n')

    if tests_skipping_enabled:
        ctx.report_progress("test_optimization_sync: downloading skippable tests")
        _perform_dd_skippable_tests_request(ctx, api_key, env_data, skippables_file, debug)
        ctx.report_progress("test_optimization_sync: skippable tests complete")
    else:
        log_debug(debug, "tests_skipping is false; writing empty skippables file")
        # Minimal valid JSON structure for skippables
        ctx.file(skippables_file, '{"meta": {"correlation_id": ""}, "data": []}\n')

    if test_management_enabled:
        ctx.report_progress("test_optimization_sync: downloading test management tests")
        _perform_dd_test_management_tests_request(ctx, api_key, env_data, tmtests_file, debug)
        ctx.report_progress("test_optimization_sync: test management tests complete")
    else:
        log_debug(debug, "test_management.enabled is false; writing empty test management tests file")
        # Minimal valid JSON structure for test management tests
        ctx.file(tmtests_file, '{"data": {"attributes": {"modules": {}}}}\n')

    # 6. Create a BUILD file with a single public filegroup target. We do not
    #    export individual files; consumers should depend on the filegroup.
    exp = repr(exports)
    build_content = (
        'filegroup(\n'
        + '    name = "test_optimization_files",\n'
        + ('    srcs = %s,\n' % exp)
        + '    visibility = ["//visibility:public"],\n'
        + ')\n'
    )
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
    implementation = _impl,                     # Points to the implementation function above
    attrs = {
        # Optional file names; if relative, they will be placed under `out_dir`
        # Defaults: settings.json, knowntests.json, skippabletests.json, tmtests.json
        "settings_file": attr.string(),
        "knowntests_file": attr.string(),
        "skippables_file": attr.string(),
        "tmtests_file": attr.string(),
        # Optional output directory; defaults to TEST_OPT_DIR (".testoptimization")
        "out_dir": attr.string(),
        # Optional explicit service name to use (overrides DD_SERVICE)
        "service": attr.string(),
        # Optional runtime.* overrides used in configurations
        "runtime_name": attr.string(),
        "runtime_version": attr.string(),
        "runtime_arch": attr.string(),
        "debug": attr.bool(default = False),                # Toggle verbose debug logging
    },
    environ = [                                 # Environment variables treated as rule inputs
        "DD_API_KEY",                           # Required: Datadog API key for authentication
        "DD_SITE",                              # Optional: Datadog site; ex: app.datadoghq.com, datadoghq.eu
        "FETCH_SALT",                           # Optional: cache-busting salt to force re-fetch
        "GIT_DIRTY",                            # Optional: working tree state; triggers refetch on change
        "DD_ENV",                               # Optional: settings payload attribute "env"
        "DD_SERVICE",                           # Optional: settings payload attribute "service"
        # If the following are unset, they will be inferred via git in the workspace
        "DD_GIT_REPOSITORY_URL",                # Optional: settings payload "repository_url" (fallback: git remote.origin.url)
        "DD_GIT_BRANCH",                        # Optional: settings payload "branch" (fallback: git rev-parse --abbrev-ref HEAD)
        "DD_GIT_COMMIT_SHA",                    # Optional: settings payload "sha" (fallback: git rev-parse HEAD)
        # Additional optional context used by requests (test management prefers head values)
        "DD_GIT_HEAD_COMMIT",                    # Optional: preferred head commit SHA
        "DD_GIT_COMMIT_MESSAGE",                 # Optional: commit message
        "DD_GIT_HEAD_MESSAGE",                   # Optional: preferred head commit message
        # CI provider detection envs (adds robustness to repo rule caching)
        "APPVEYOR", "APPVEYOR_REPO_NAME", "APPVEYOR_REPO_PROVIDER", "APPVEYOR_REPO_BRANCH", "APPVEYOR_REPO_COMMIT",
        "TF_BUILD", "BUILD_REPOSITORY_URI", "BUILD_SOURCEVERSION", "BUILD_SOURCEBRANCH", "BUILD_SOURCEVERSIONMESSAGE",
        "BITBUCKET_COMMIT", "BITBUCKET_REPO_SLUG", "BITBUCKET_BRANCH", "BITBUCKET_GIT_HTTP_ORIGIN",
        "BUDDY",
        "BUILDKITE", "BUILDKITE_REPO", "BUILDKITE_COMMIT", "BUILDKITE_BRANCH", "BUILDKITE_MESSAGE",
        "CIRCLECI", "CIRCLE_REPOSITORY_URL", "CIRCLE_SHA1", "CIRCLE_BRANCH",
        "GITHUB_SHA", "GITHUB_REPOSITORY", "GITHUB_SERVER_URL", "GITHUB_REF",
        "GITLAB_CI", "CI_REPOSITORY_URL", "CI_COMMIT_SHA", "CI_COMMIT_BRANCH", "CI_COMMIT_MESSAGE", "CI_MERGE_REQUEST_SOURCE_BRANCH_SHA",
        "JENKINS_URL", "GIT_URL", "GIT_URL_1", "GIT_COMMIT", "GIT_BRANCH",
        "TEAMCITY_VERSION",
        "TRAVIS", "TRAVIS_REPO_SLUG", "TRAVIS_COMMIT", "TRAVIS_PULL_REQUEST_BRANCH", "TRAVIS_BRANCH", "TRAVIS_COMMIT_MESSAGE",
        "BITRISE_BUILD_SLUG", "BITRISE_GIT_REPOSITORY_URL", "BITRISE_GIT_COMMIT", "BITRISE_GIT_BRANCH",
        "CF_BUILD_ID", "CF_BRANCH",
        "CODEBUILD_INITIATOR",
        "DRONE", "DRONE_GIT_HTTP_URL", "DRONE_COMMIT_SHA", "DRONE_BRANCH", "DRONE_COMMIT_MESSAGE",
    ],
    local = True,                               # Always run this rule locally, bypassing repository cache
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

    if extension_debug:
        print("test_optimization_sync_extension: Starting module extension implementation")
        print("test_optimization_sync_extension: Number of modules: %d" % len(module_ctx.modules))
    
    for mod in module_ctx.modules:
        if extension_debug:
            print("test_optimization_sync_extension: Processing module: %s" % mod.name)
            print("test_optimization_sync_extension: Module is_root: %s" % mod.is_root)
            print("test_optimization_sync_extension: Number of test_optimization_sync tags: %d" % len(mod.tags.test_optimization_sync))
        
        for test_optimization_call in mod.tags.test_optimization_sync:
            call_debug = hasattr(test_optimization_call, "debug") and test_optimization_call.debug
            if call_debug:
                print("test_optimization_sync_extension: Processing test_optimization_sync call: %s" % test_optimization_call.name)
                print(
                    "test_optimization_sync_extension: Calling test_optimization_sync with name=%s, out_dir=%s, service=%s, settings_file=%s, knowntests_file=%s, skippables_file=%s, tmtests_file=%s, debug=%s"
                    % (
                        test_optimization_call.name,
                        (test_optimization_call.out_dir or "<default>"),
                        (test_optimization_call.service or "<env/DD_SERVICE>"),
                        test_optimization_call.settings_file,
                        test_optimization_call.knowntests_file,
                        test_optimization_call.skippables_file,
                        test_optimization_call.tmtests_file,
                        call_debug,
                    )
                )
            
            test_optimization_sync(
                name = test_optimization_call.name,
                out_dir = test_optimization_call.out_dir,
                service = test_optimization_call.service,
                settings_file = test_optimization_call.settings_file,
                knowntests_file = test_optimization_call.knowntests_file,
                skippables_file = test_optimization_call.skippables_file,
                tmtests_file = test_optimization_call.tmtests_file,
                runtime_name = test_optimization_call.runtime_name,
                runtime_version = test_optimization_call.runtime_version,
                runtime_arch = test_optimization_call.runtime_arch,
                debug = call_debug,
            )

# Define the module extension with the test_optimization_sync tag
test_optimization_sync_extension = module_extension(
    implementation = _test_optimization_sync_extension_impl,
    tag_classes = {
        "test_optimization_sync": tag_class(attrs = {
            "name": attr.string(mandatory = True),
            # Optional: individual file names (can be bare names; placed under out_dir)
            "settings_file": attr.string(),
            "knowntests_file": attr.string(),
            "skippables_file": attr.string(),
            "tmtests_file": attr.string(),
            # Optional: base output directory (defaults to TEST_OPT_DIR)
            "out_dir": attr.string(),
            # Optional explicit service name to use (overrides DD_SERVICE)
            "service": attr.string(),
            # Optional runtime.* overrides used in configurations
            "runtime_name": attr.string(),
            "runtime_version": attr.string(),
            "runtime_arch": attr.string(),
            "debug": attr.bool(default = False),
        }),
    },
)
