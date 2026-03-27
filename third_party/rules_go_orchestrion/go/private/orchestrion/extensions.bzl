# Copyright 2024 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Module extension for configuring orchestrion in rules_go."""

DEFAULT_DD_TRACE_GO_VERSION = "v2.6.0"
ORCHESTRION_BOOTSTRAP_CACHE_ABI = "v2"

# Bump this identifier whenever the in-repo Orchestrion patch block changes in
# a way that should invalidate previously cached bootstrap binaries.
ORCHESTRION_PATCHSET_ID = "20260326-bootstrap-cache-v2-no-tool-repin"
_DD_TRACE_GO_MODULES = [
    "github.com/DataDog/dd-trace-go/v2",
    "github.com/DataDog/dd-trace-go/contrib/net/http/v2",
    "github.com/DataDog/dd-trace-go/contrib/log/slog/v2",
]
_DD_TRACE_GO_PREFLIGHT_PACKAGES = [
    "github.com/DataDog/dd-trace-go/v2/orchestrion",
    "github.com/DataDog/dd-trace-go/contrib/net/http/v2",
    "github.com/DataDog/dd-trace-go/contrib/log/slog/v2",
]

def _find_go_binary(ctx):
    go_path = ctx.which("go")
    if go_path:
        return go_path
    for path in ["/usr/local/go/bin/go", "/opt/homebrew/bin/go", "/usr/bin/go"]:
        if ctx.path(path).exists:
            return path
    fail("Could not find 'go' binary. Please ensure Go is installed.")

def _is_windows(ctx):
    return ctx.os.name.lower().startswith("windows")

def _path_join(ctx, *parts):
    sep = "\\" if _is_windows(ctx) else "/"
    cleaned = []
    for index, part in enumerate(parts):
        if part == None:
            continue
        text = str(part)
        if not text:
            continue
        if index == 0:
            cleaned.append(text.rstrip("/\\"))
        else:
            cleaned.append(text.strip("/\\"))
    if not cleaned:
        return ""
    return sep.join(cleaned)

def _bootstrap_repo_local_cache_root(ctx):
    return str(ctx.path(".orchestrion_bootstrap_cache"))

def _bootstrap_host_cache_root(ctx):
    env = ctx.os.environ
    xdg_cache_home = (env.get("XDG_CACHE_HOME") or "").strip()
    if xdg_cache_home:
        return _path_join(ctx, xdg_cache_home, "datadog-orchestrion-go-cache")

    if _is_windows(ctx):
        localappdata = (env.get("LOCALAPPDATA") or "").strip()
        if localappdata:
            return _path_join(ctx, localappdata, "datadog-orchestrion-go-cache")
        userprofile = (env.get("USERPROFILE") or "").strip()
        if userprofile:
            return _path_join(ctx, userprofile, "AppData", "Local", "datadog-orchestrion-go-cache")
        return ""

    home = (env.get("HOME") or "").strip()
    if not home:
        return ""
    if "mac" in ctx.os.name.lower() or "darwin" in ctx.os.name.lower():
        return _path_join(ctx, home, "Library", "Caches", "datadog-orchestrion-go-cache")
    return _path_join(ctx, home, ".cache", "datadog-orchestrion-go-cache")

def _bootstrap_cache_root(ctx):
    host_root = _bootstrap_host_cache_root(ctx)
    if host_root and _host_path_is_writable(ctx, host_root):
        return host_root
    return _bootstrap_repo_local_cache_root(ctx)

def _bootstrap_go_cache_root(ctx):
    return _path_join(ctx, _bootstrap_cache_root(ctx), "go")

def _go_env(ctx):
    go_cache_root = _bootstrap_go_cache_root(ctx)
    return {
        "GO111MODULE": "on",
        "GOWORK": "off",
        "GOTOOLCHAIN": "go1.25.0+auto",
        "GOPROXY": "https://proxy.golang.org,direct",
        "GOSUMDB": "sum.golang.org",
        "GOMODCACHE": _path_join(ctx, go_cache_root, "pkg", "mod"),
        "GOCACHE": _path_join(ctx, go_cache_root, "cache"),
    }

def _probe_enabled(ctx):
    return getattr(ctx.attr, "log_timing", False)

def _probe_now_ms(ctx):
    if not _probe_enabled(ctx):
        return None
    python = ctx.which("python3") or ctx.which("python")
    if not python:
        return None
    result = ctx.execute([str(python), "-c", "import time; print(int(time.time_ns() / 1000000))"], timeout = 10)
    if result.return_code != 0:
        return None
    value = result.stdout.strip()
    if not value:
        return None
    return int(value)

def _probe_emit(ctx, phase, start_ms = None, status = "ok", extra = None):
    if not _probe_enabled(ctx):
        return
    fields = [
        "phase=%r" % phase,
        "status=%r" % status,
    ]
    now_ms = _probe_now_ms(ctx)
    if now_ms != None:
        fields.append("ts_unix_ms=%r" % str(now_ms))
        if start_ms != None:
            fields.append("elapsed_ms=%r" % str(now_ms - start_ms))
    if extra:
        for key in sorted(extra.keys()):
            fields.append("%s=%r" % (key, str(extra[key])))
    print("RULES_GO_ORCHESTRION_PROBE " + " ".join(fields))

def _sanitize_cache_fragment(value):
    result = []
    text = str(value)
    for idx in range(len(text)):
        ch = text[idx]
        if (("a" <= ch and ch <= "z") or
            ("A" <= ch and ch <= "Z") or
            ("0" <= ch and ch <= "9") or
            ch in "._-"):
            result.append(ch)
        else:
            result.append("_")
    return "".join(result).strip("._-") or "default"

def _copy_ctx_env(ctx):
    copied = {}
    for key, value in ctx.os.environ.items():
        copied[key] = value
    return copied

def _ctx_execute_checked(ctx, args, timeout = 600, environment = None):
    if environment == None:
        environment = _copy_ctx_env(ctx)
    return ctx.execute(args, timeout = timeout, environment = environment)

def _go_tool_identity(ctx, go_path):
    version_result = _ctx_execute_checked(ctx, [str(go_path), "version"], timeout = 30)
    if version_result.return_code != 0:
        fail("Failed to detect Go tool version: %s\n%s" % (version_result.stdout, version_result.stderr))
    env_result = _ctx_execute_checked(ctx, [str(go_path), "env", "GOOS", "GOARCH"], timeout = 30)
    if env_result.return_code != 0:
        fail("Failed to detect Go tool target: %s\n%s" % (env_result.stdout, env_result.stderr))
    env_lines = [line.strip() for line in env_result.stdout.splitlines() if line.strip()]
    if len(env_lines) != 2:
        fail("Unexpected output from `go env GOOS GOARCH`: %r" % env_result.stdout)
    return struct(
        version = version_result.stdout.strip(),
        goos = env_lines[0],
        goarch = env_lines[1],
    )

def _dd_trace_go_versions_cache_fragment(version_map):
    root_version = version_map["github.com/DataDog/dd-trace-go/v2"]
    http_version = version_map["github.com/DataDog/dd-trace-go/contrib/net/http/v2"]
    slog_version = version_map["github.com/DataDog/dd-trace-go/contrib/log/slog/v2"]
    if root_version == http_version and root_version == slog_version:
        return "shared-%s" % _sanitize_cache_fragment(root_version)
    return "root-%s__http-%s__slog-%s" % (
        _sanitize_cache_fragment(root_version),
        _sanitize_cache_fragment(http_version),
        _sanitize_cache_fragment(slog_version),
    )

def _bootstrap_cache_key(version, version_map, go_identity):
    return "__".join([
        "abi-%s" % ORCHESTRION_BOOTSTRAP_CACHE_ABI,
        "patch-%s" % _sanitize_cache_fragment(ORCHESTRION_PATCHSET_ID),
        "orch-%s" % _sanitize_cache_fragment(version),
        "go-%s" % _sanitize_cache_fragment(go_identity.version),
        "target-%s-%s" % (_sanitize_cache_fragment(go_identity.goos), _sanitize_cache_fragment(go_identity.goarch)),
        "dd-%s" % _dd_trace_go_versions_cache_fragment(version_map),
    ])

def _bootstrap_cache_paths(ctx, version, version_map, go_identity, binary_name):
    cache_root = _bootstrap_cache_root(ctx)
    key = _bootstrap_cache_key(version, version_map, go_identity)
    entry_dir = _path_join(ctx, cache_root, "bootstrap", key)
    return struct(
        cache_root = cache_root,
        key = key,
        entry_dir = entry_dir,
        binary_path = _path_join(ctx, entry_dir, binary_name),
        version_file_path = _path_join(ctx, entry_dir, "dd_trace_go_versions.json"),
        manifest_path = _path_join(ctx, entry_dir, "manifest.json"),
        ready_path = _path_join(ctx, entry_dir, "ready"),
    )

def _bootstrap_cache_entry_ready(ctx, paths):
    return (
        ctx.path(paths.binary_path).exists and
        ctx.path(paths.version_file_path).exists and
        ctx.path(paths.manifest_path).exists and
        ctx.path(paths.ready_path).exists
    )

def _dd_trace_go_versions_from_shared(version):
    version_map = {}
    for module_path in _DD_TRACE_GO_MODULES:
        version_map[module_path] = version
    return version_map

def _copy_dd_trace_go_versions(version_map):
    copied = {}
    for module_path in version_map:
        copied[module_path] = version_map[module_path]
    return copied

def _validate_dd_trace_go_versions_keys(version_map):
    missing = [module_path for module_path in _DD_TRACE_GO_MODULES if module_path not in version_map]
    extra = [module_path for module_path in version_map.keys() if module_path not in _DD_TRACE_GO_MODULES]
    if missing or extra:
        details = []
        if missing:
            details.append("missing keys: %s" % ", ".join(missing))
        if extra:
            details.append("unexpected keys: %s" % ", ".join(sorted(extra)))
        fail("dd_trace_go_versions must contain exactly the supported tracer modules (%s)" % "; ".join(details))

def _looks_like_canonical_dd_trace_go_version(version):
    if not version or not version.startswith("v") or version.count(".") < 2:
        return False
    for idx in range(len(version)):
        ch = version[idx]
        if (("a" <= ch and ch <= "z") or
            ("A" <= ch and ch <= "Z") or
            ("0" <= ch and ch <= "9") or
            ch in ".+-"):
            continue
        return False
    return True

def _neutral_dd_trace_check_go_mod(version_map = None):
    if version_map == None:
        return """module ddtraceversioncheck

go 1.21
"""

    lines = [
        "module ddtraceversioncheck",
        "",
        "go 1.21",
        "",
        "require (",
    ]
    for module_path in _DD_TRACE_GO_MODULES:
        lines.append("    %s %s" % (module_path, version_map[module_path]))
    lines.extend([
        ")",
        "",
    ])
    return "\n".join(lines)

def _ctx_execute_or_fail(ctx, args, env, error_prefix):
    result = ctx.execute(args, timeout = 600, environment = env)
    if result.return_code != 0:
        fail("%s: %s\n%s" % (error_prefix, result.stdout, result.stderr))
    return result

def _parse_key_value_lines(output, expected_keys, error_prefix):
    remaining = {key: True for key in expected_keys}
    resolved = {}
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            fail("%s: unexpected output line %r" % (error_prefix, line))
        key = parts[0].strip()
        value = parts[1].strip()
        if key not in remaining:
            fail("%s: unexpected key %r in output" % (error_prefix, key))
        if not value:
            fail("%s: empty value for %r" % (error_prefix, key))
        resolved[key] = value
        remaining.pop(key)
    if remaining:
        fail("%s: missing output for %s" % (error_prefix, ", ".join(sorted(remaining.keys()))))
    return resolved

def _batch_resolve_module_versions(ctx, go_path, check_dir, query_by_module, error_prefix):
    env = _go_env(ctx)
    format_expr = "{{if .Path}}{{.Path}}={{if .Replace}}{{.Replace.Version}}{{else}}{{.Version}}{{end}}{{end}}"
    args = [
        str(go_path),
        "-C",
        check_dir,
        "list",
        "-m",
        "-mod=mod",
        "-f",
        format_expr,
    ]
    for module_path in _DD_TRACE_GO_MODULES:
        args.append("%s@%s" % (module_path, query_by_module[module_path]))
    start_ms = _probe_now_ms(ctx)
    result = _ctx_execute_or_fail(ctx, args, env, error_prefix)
    _probe_emit(
        ctx,
        "extensions.batch_resolve_module_versions",
        start_ms = start_ms,
        extra = {"module_count": len(_DD_TRACE_GO_MODULES)},
    )
    return _parse_key_value_lines(result.stdout, _DD_TRACE_GO_MODULES, error_prefix)

def _run_dd_trace_go_package_preflight(ctx, go_path, version_map):
    env = _go_env(ctx)
    check_dir = ".ddtrace_version_check"
    ctx.file(check_dir + "/go.mod", _neutral_dd_trace_check_go_mod(version_map))

    start_ms = _probe_now_ms(ctx)
    _ctx_execute_or_fail(
        ctx,
        [
            str(go_path),
            "-C",
            check_dir,
            "list",
            "-mod=mod",
        ] + _DD_TRACE_GO_PREFLIGHT_PACKAGES,
        env,
        "Failed dd-trace-go package preflight",
    )
    _probe_emit(
        ctx,
        "extensions.dd_trace_go_package_preflight",
        start_ms = start_ms,
        extra = {"package_count": len(_DD_TRACE_GO_PREFLIGHT_PACKAGES)},
    )

def _validated_shared_dd_trace_go_versions(ctx, go_path, query):
    if _looks_like_canonical_dd_trace_go_version(query):
        return _dd_trace_go_versions_from_shared(query)

    check_dir = ".ddtrace_version_check"
    ctx.file(check_dir + "/go.mod", _neutral_dd_trace_check_go_mod())

    query_by_module = {module_path: query for module_path in _DD_TRACE_GO_MODULES}
    resolved_by_module = _batch_resolve_module_versions(
        ctx,
        go_path,
        check_dir,
        query_by_module,
        "Failed to resolve dd-trace-go query %r" % query,
    )
    resolved_pairs = []
    resolved_versions = []
    for module_path in _DD_TRACE_GO_MODULES:
        version = resolved_by_module[module_path]
        resolved_pairs.append("%s=%s" % (module_path, version))
        resolved_versions.append(version)

    canonical_version = resolved_versions[0]
    for version in resolved_versions[1:]:
        if version != canonical_version:
            fail("dd-trace-go query %r resolved to inconsistent versions: %s" % (query, ", ".join(resolved_pairs)))

    if canonical_version != query:
        fail("dd_trace_go_version %r is not a canonical persisted version (resolved to %r). Use bootstrap with --dd-trace-go-version=%s if you want to pass a branch or commit SHA." % (query, canonical_version, query))

    version_map = _dd_trace_go_versions_from_shared(canonical_version)
    _run_dd_trace_go_package_preflight(ctx, go_path, version_map)
    return version_map

def _validated_per_module_dd_trace_go_versions(ctx, go_path, version_map):
    _validate_dd_trace_go_versions_keys(version_map)
    if all([_looks_like_canonical_dd_trace_go_version(version_map[module_path]) for module_path in _DD_TRACE_GO_MODULES]):
        return _copy_dd_trace_go_versions(version_map)

    check_dir = ".ddtrace_version_check"
    ctx.file(check_dir + "/go.mod", _neutral_dd_trace_check_go_mod())

    resolved_versions = _batch_resolve_module_versions(
        ctx,
        go_path,
        check_dir,
        version_map,
        "Failed to validate dd_trace_go_versions",
    )
    for module_path in _DD_TRACE_GO_MODULES:
        query = version_map[module_path]
        resolved = resolved_versions[module_path]
        if not resolved:
            fail("Failed to validate dd_trace_go_versions[%r]=%r: empty resolved version" % (module_path, query))
        if resolved != query:
            fail("dd_trace_go_versions[%r] must already be canonical (resolved %r to %r)" % (module_path, query, resolved))

    _run_dd_trace_go_package_preflight(ctx, go_path, version_map)
    return _copy_dd_trace_go_versions(version_map)

def _validated_dd_trace_go_versions(ctx, go_path, shared_query, version_map):
    if shared_query and version_map:
        fail("dd_trace_go_version and dd_trace_go_versions cannot both be set")
    if version_map:
        return _validated_per_module_dd_trace_go_versions(ctx, go_path, version_map)
    if shared_query:
        return _validated_shared_dd_trace_go_versions(ctx, go_path, shared_query)
    return _dd_trace_go_versions_from_shared(DEFAULT_DD_TRACE_GO_VERSION)

def _dd_trace_go_versions_json(version_map):
    entries = []
    for module_path in _DD_TRACE_GO_MODULES:
        entries.append('    "%s": "%s"' % (module_path, version_map[module_path]))
    return "{\n  \"modules\": {\n%s\n  }\n}\n" % ",\n".join(entries)

def _host_copy_file(ctx, src, dst, error_prefix):
    copied, stdout, stderr = _host_copy_file_result(ctx, src, dst)
    if not copied:
        fail("%s: %s\n%s" % (error_prefix, stdout, stderr))

def _host_copy_file_result(ctx, src, dst):
    # Bootstrap cache restore is best-effort, so callers sometimes need the raw
    # copy result instead of an immediate repository-rule failure.
    src_path = str(ctx.path(src))
    dst_path = str(ctx.path(dst))
    parent = str(ctx.path(dst_path).dirname)
    if _is_windows(ctx):
        powershell = ctx.which("powershell.exe") or ctx.which("pwsh") or ctx.which("powershell")
        if not powershell:
            return (False, "", "could not find PowerShell")
        command = "$ErrorActionPreference = 'Stop'; New-Item -ItemType Directory -Force -Path %s | Out-Null; Copy-Item -LiteralPath %s -Destination %s -Force" % (
            _powershell_single_quoted_literal(parent),
            _powershell_single_quoted_literal(src_path),
            _powershell_single_quoted_literal(dst_path),
        )
        result = _ctx_execute_checked(
            ctx,
            [str(powershell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
            timeout = 120,
        )
    else:
        shell = ctx.which("sh") or "/bin/sh"
        result = _ctx_execute_checked(
            ctx,
            [str(shell), "-c", "mkdir -p \"$1\" && cp \"$2\" \"$3\"", "bootstrap-copy", parent, src_path, dst_path],
            timeout = 120,
        )
    if result.return_code != 0:
        return (False, result.stdout, result.stderr)
    return (True, result.stdout, result.stderr)

def _host_path_is_writable(ctx, path):
    # Repository rules may see HOME/XDG cache paths that exist but are mounted
    # read-only in CI or hermetic environments. Probe writability before using
    # them so bootstrap can fall back to the repo-local cache root.
    probe_dir = _path_join(ctx, path, ".bootstrap-write-check")
    if _is_windows(ctx):
        powershell = ctx.which("powershell.exe") or ctx.which("pwsh") or ctx.which("powershell")
        if not powershell:
            return False
        command = "$ErrorActionPreference = 'Stop'; New-Item -ItemType Directory -Force -Path %s | Out-Null; $probe = Join-Path %s '.probe'; Set-Content -LiteralPath $probe -Value 'ok'; Remove-Item -LiteralPath $probe -Force" % (
            _powershell_single_quoted_literal(probe_dir),
            _powershell_single_quoted_literal(probe_dir),
        )
        result = _ctx_execute_checked(
            ctx,
            [str(powershell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
            timeout = 30,
        )
    else:
        shell = ctx.which("sh") or "/bin/sh"
        result = _ctx_execute_checked(
            ctx,
            [
                str(shell),
                "-c",
                "mkdir -p \"$1\" && touch \"$1/.probe\" && rm -f \"$1/.probe\"",
                "bootstrap-write-check",
                probe_dir,
            ],
            timeout = 30,
        )
    return result.return_code == 0

def _powershell_single_quoted_literal(value):
    """Render a string as a PowerShell single-quoted literal."""
    return "'%s'" % value.replace("'", "''")

def _parse_certutil_sha256(output):
    """Extract a SHA-256 digest from certutil -hashfile output."""
    digest = ""
    for line in output.splitlines():
        candidate = line.strip().lower().replace(" ", "")
        is_hex = bool(candidate)
        for idx in range(len(candidate)):
            if candidate[idx] not in "0123456789abcdef":
                is_hex = False
                break
        if is_hex:
            digest += candidate
            if len(digest) >= 64:
                return digest[:64]
    return digest if len(digest) == 64 else ""

def _binary_sha256(ctx, path):
    file_path = str(ctx.path(path))
    if _is_windows(ctx):
        certutil = ctx.which("certutil.exe") or ctx.which("certutil")
        if certutil:
            result = _ctx_execute_checked(
                ctx,
                [str(certutil), "-hashfile", file_path, "SHA256"],
                timeout = 120,
            )
            if result.return_code != 0:
                fail("Failed to hash Orchestrion bootstrap binary %s with certutil: %s\n%s" % (file_path, result.stdout, result.stderr))
            digest = _parse_certutil_sha256(result.stdout)
            if digest:
                return digest
            fail("Failed to parse certutil SHA-256 output for %s: %s" % (file_path, result.stdout))

        powershell = ctx.which("powershell.exe") or ctx.which("pwsh") or ctx.which("powershell")
        if not powershell:
            fail("Could not find certutil or PowerShell to hash %s" % file_path)
        command = "$ErrorActionPreference = 'Stop'; (Get-FileHash -Algorithm SHA256 -LiteralPath %s).Hash.ToLowerInvariant()" % _powershell_single_quoted_literal(file_path)
        result = _ctx_execute_checked(
            ctx,
            [str(powershell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
            timeout = 120,
        )
    elif ctx.which("shasum"):
        result = _ctx_execute_checked(ctx, [str(ctx.which("shasum")), "-a", "256", file_path], timeout = 120)
    elif ctx.which("sha256sum"):
        result = _ctx_execute_checked(ctx, [str(ctx.which("sha256sum")), file_path], timeout = 120)
    elif ctx.which("openssl"):
        result = _ctx_execute_checked(ctx, [str(ctx.which("openssl")), "dgst", "-sha256", file_path], timeout = 120)
    else:
        fail("Could not find a SHA-256 tool to hash %s" % file_path)
    if result.return_code != 0:
        fail("Failed to hash Orchestrion bootstrap binary %s: %s\n%s" % (file_path, result.stdout, result.stderr))
    digest = result.stdout.strip().lower()
    if "=" in digest:
        digest = digest.split("=")[-1].strip()
    else:
        digest = digest.split(" ")[0].strip()
    return digest

def _orchestrion_build_file(binary_name):
    return """# Generated by rules_go orchestrion extension
filegroup(
    name = "orchestrion",
    srcs = ["{binary_name}"],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "dd_trace_go_version_file",
    srcs = ["dd_trace_go_versions.json"],
    visibility = ["//visibility:public"],
)
""".format(binary_name = binary_name)

def _write_orchestrion_repo_files(ctx, binary_name, dd_trace_go_versions):
    ctx.file("dd_trace_go_versions.json", _dd_trace_go_versions_json(dd_trace_go_versions))
    ctx.file("BUILD.bazel", _orchestrion_build_file(binary_name))

def _write_bootstrap_cache(ctx, paths, version, version_map, go_identity, binary_name):
    manifest_repo_path = ".orchestrion_bootstrap_manifest.json"
    ready_repo_path = ".orchestrion_bootstrap_ready"
    manifest = json.encode({
        "abi": ORCHESTRION_BOOTSTRAP_CACHE_ABI,
        "patchset_id": ORCHESTRION_PATCHSET_ID,
        "cache_key": paths.key,
        "orchestrion_version": version,
        "go_identity": {
            "version": go_identity.version,
            "goos": go_identity.goos,
            "goarch": go_identity.goarch,
        },
        "dd_trace_go_versions": version_map,
        "binary_name": binary_name,
        "binary_sha256": _binary_sha256(ctx, binary_name),
    })
    ctx.file(manifest_repo_path, manifest + "\n")
    ctx.file(ready_repo_path, "ready\n")
    _host_copy_file(ctx, binary_name, paths.binary_path, "Failed to persist cached Orchestrion binary")
    _host_copy_file(ctx, "dd_trace_go_versions.json", paths.version_file_path, "Failed to persist cached Orchestrion version file")
    _host_copy_file(ctx, manifest_repo_path, paths.manifest_path, "Failed to persist Orchestrion bootstrap manifest")
    _host_copy_file(ctx, ready_repo_path, paths.ready_path, "Failed to persist Orchestrion bootstrap ready sentinel")

def _restore_bootstrap_cache(ctx, paths, binary_name):
    if not _bootstrap_cache_entry_ready(ctx, paths):
        return False
    binary_restored, _, _ = _host_copy_file_result(ctx, paths.binary_path, binary_name)
    if not binary_restored:
        return False
    versions_restored, _, _ = _host_copy_file_result(ctx, paths.version_file_path, "dd_trace_go_versions.json")
    if not versions_restored:
        return False
    ctx.file("BUILD.bazel", _orchestrion_build_file(binary_name))
    return True

orchestrion_extension_test_helpers = struct(
    bootstrap_cache_key = _bootstrap_cache_key,
    host_path_is_writable = _host_path_is_writable,
    parse_certutil_sha256 = _parse_certutil_sha256,
    powershell_single_quoted_literal = _powershell_single_quoted_literal,
)

def _orchestrion_build_impl(ctx):
    """Build orchestrion from source."""
    total_start_ms = _probe_now_ms(ctx)
    version = ctx.attr.version
    go_path = _find_go_binary(ctx)
    version_start_ms = _probe_now_ms(ctx)
    dd_trace_go_versions = _validated_dd_trace_go_versions(ctx, go_path, ctx.attr.dd_trace_go_version, ctx.attr.dd_trace_go_versions)
    _probe_emit(ctx, "extensions.validate_dd_trace_go_versions", start_ms = version_start_ms)
    binary_name = "orchestrion.exe" if _is_windows(ctx) else "orchestrion_bin"
    go_identity = _go_tool_identity(ctx, go_path)
    bootstrap_cache = _bootstrap_cache_paths(ctx, version, dd_trace_go_versions, go_identity, binary_name)
    if _restore_bootstrap_cache(ctx, bootstrap_cache, binary_name):
        _probe_emit(
            ctx,
            "extensions.bootstrap_cache_hit",
            extra = {
                "cache_key": bootstrap_cache.key,
                "cache_root": bootstrap_cache.cache_root,
            },
        )
        _probe_emit(
            ctx,
            "extensions.orchestrion_build_total",
            start_ms = total_start_ms,
            extra = {"dd_trace_go_version": dd_trace_go_versions["github.com/DataDog/dd-trace-go/v2"]},
        )
        return
    _probe_emit(
        ctx,
        "extensions.bootstrap_cache_miss",
        extra = {
            "cache_key": bootstrap_cache.key,
            "cache_root": bootstrap_cache.cache_root,
        },
    )

    # Download orchestrion source
    ctx.report_progress("rules_go_orchestrion: downloading orchestrion source")
    download_start_ms = _probe_now_ms(ctx)
    ctx.download_and_extract(
        url = "https://github.com/DataDog/orchestrion/archive/refs/tags/%s.zip" % version,
        stripPrefix = "orchestrion-%s" % version.lstrip("v"),
    )
    _probe_emit(ctx, "extensions.download_and_extract", start_ms = download_start_ms, extra = {"version": version})

    # Resolver / tempdir compatibility patches for Bazel sandboxes and the
    # synthetic temp-module layout used by the vendored builders.
    ctx.report_progress("rules_go_orchestrion: patching orchestrion source")
    patch_start_ms = _probe_now_ms(ctx)

    # The upstream package resolver recursively re-runs `go list` under
    # `-toolexec=orchestrion toolexec`, which causes woven dependency lookups to
    # fail under Bazel's sandbox even when plain `go list -mod=mod` succeeds in
    # the same environment. Mirror the safer non-recursive pattern used by other
    # loader paths in Orchestrion and disable toolexec for dependency resolution.
    resolve_path = "internal/jobserver/pkgs/resolve.go"
    resolve_src = ctx.read(resolve_path)
    resolve_old = """\n\t\tbuildFlags := append(\n\t\t\tgoFlags.Slice(),\n\t\t\tfmt.Sprintf(\"-toolexec=%q toolexec\", binpath.Orchestrion),\n\t\t)\n"""
    resolve_new = """\n\t\tbuildFlags := append(goFlags.Slice(), \"-toolexec=\")\n"""
    if resolve_old not in resolve_src:
        fail("Could not patch Orchestrion resolver in %s" % resolve_path)
    resolve_src = resolve_src.replace(resolve_old, resolve_new)
    resolve_src = resolve_src.replace('\n\t"github.com/DataDog/orchestrion/internal/binpath"', "")
    resolve_imports_old = """\t\"fmt\"\n\t\"os\"\n\t\"slices\"\n"""
    resolve_imports_new = """\t\"fmt\"\n\t\"os\"\n\t\"path/filepath\"\n\t\"slices\"\n"""
    if resolve_imports_old not in resolve_src:
        fail("Could not patch Orchestrion resolver imports in %s" % resolve_path)
    resolve_src = resolve_src.replace(resolve_imports_old, resolve_imports_new, 1)
    resolve_tempdir_old = """\t\tif req.TempDir != \"\" {\n\t\t\t// Make sure the directory exists (go blindly assumes that...)\n\t\t\tif err := os.MkdirAll(req.TempDir, 0o755); err != nil {\n\t\t\t\treturn nil, fmt.Errorf(\"creating temporary directory %q: %w\", req.TempDir, err)\n\t\t\t}\n\t\t\tenv = append(env, fmt.Sprintf(\"%s=%s\", envVarGotmpdir, req.TempDir))\n\t\t}\n"""
    resolve_tempdir_new = """\t\tif req.TempDir != \"\" {\n\t\t\tabsTempDir, absErr := filepath.Abs(req.TempDir)\n\t\t\tif absErr != nil {\n\t\t\t\treturn nil, fmt.Errorf(\"absolutizing temporary directory %q: %w\", req.TempDir, absErr)\n\t\t\t}\n\t\t\t// Make sure the directory exists (go blindly assumes that...)\n\t\t\tif err := os.MkdirAll(absTempDir, 0o755); err != nil {\n\t\t\t\treturn nil, fmt.Errorf(\"creating temporary directory %q: %w\", absTempDir, err)\n\t\t\t}\n\t\t\tfor _, name := range []string{\"external\", \"bazel-out\"} {\n\t\t\t\tsrcPath := filepath.Join(req.Dir, name)\n\t\t\t\tif !filepath.IsAbs(srcPath) {\n\t\t\t\t\tif srcPath, absErr = filepath.Abs(srcPath); absErr != nil {\n\t\t\t\t\t\treturn nil, fmt.Errorf(\"absolutizing compatibility path %q: %w\", srcPath, absErr)\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t\tif _, statErr := os.Stat(srcPath); statErr != nil {\n\t\t\t\t\tcontinue\n\t\t\t\t}\n\t\t\t\tdstPath := filepath.Join(absTempDir, name)\n\t\t\t\tif _, statErr := os.Lstat(dstPath); statErr == nil {\n\t\t\t\t\tcontinue\n\t\t\t\t} else if !os.IsNotExist(statErr) {\n\t\t\t\t\treturn nil, fmt.Errorf(\"stat temporary compatibility path %q: %w\", dstPath, statErr)\n\t\t\t\t}\n\t\t\t\tlinkTarget, relErr := filepath.Rel(absTempDir, srcPath)\n\t\t\t\tif relErr != nil {\n\t\t\t\t\tif linkTarget, absErr = filepath.Abs(srcPath); absErr != nil {\n\t\t\t\t\t\treturn nil, fmt.Errorf(\"compute temporary compatibility path for %q: %w\", name, relErr)\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t\tif linkErr := os.Symlink(linkTarget, dstPath); linkErr != nil {\n\t\t\t\t\treturn nil, fmt.Errorf(\"create temporary compatibility symlink %q -> %q: %w\", dstPath, linkTarget, linkErr)\n\t\t\t\t}\n\t\t\t\tif log.GetLevel() <= zerolog.TraceLevel {\n\t\t\t\t\tlog.Trace().Str(\"dst\", dstPath).Str(\"target\", linkTarget).Msg(\"pkgs.Resolve created temp compatibility symlink\")\n\t\t\t\t}\n\t\t\t}\n\t\t\tenv = append(env, fmt.Sprintf(\"%s=%s\", envVarGotmpdir, absTempDir))\n\t\t}\n"""
    if resolve_tempdir_old not in resolve_src:
        fail("Could not patch Orchestrion resolver tempdir block in %s" % resolve_path)
    resolve_src = resolve_src.replace(resolve_tempdir_old, resolve_tempdir_new, 1)
    resolve_merge_old = """func (r ResolveResponse) mergeFrom(pkg *packages.Package) error {\n\tif pkg.PkgPath == \"\" || pkg.PkgPath == \"unsafe\" || r[pkg.PkgPath] != \"\" {\n\t\t// Ignore the \"unsafe\" package (no archive file, ever), packages with an empty import path\n\t\t// (standard library), and those already present in the map (already processed previously).\n\t\treturn nil\n\t}\n"""
    resolve_merge_new = """func (r ResolveResponse) mergeFrom(pkg *packages.Package) error {\n\tif pkg.PkgPath == \"\" || pkg.PkgPath == \"unsafe\" || r[pkg.PkgPath] != \"\" {\n\t\t// Ignore the \"unsafe\" package (no archive file, ever), packages with an empty import path\n\t\t// (standard library), and those already present in the map (already processed previously).\n\t\treturn nil\n\t}\n"""
    if resolve_merge_old not in resolve_src:
        fail("Could not patch Orchestrion resolver mergeFrom in %s" % resolve_path)
    resolve_src = resolve_src.replace(resolve_merge_old, resolve_merge_new, 1)
    ctx.file(resolve_path, resolve_src)

    # Compile-proxy / archive metadata patches for the synthetic testmain flow.
    linkdeps_path = "internal/toolexec/aspect/linkdeps/linkdeps.go"
    linkdeps_src = ctx.read(linkdeps_path)
    linkdeps_old = """\n\tdata, err = readArchiveData(archive, Filename)\n\tif err != nil {\n\t\treturn res, fmt.Errorf(\"reading %s from %q: %w\", Filename, archive, err)\n\t}\n"""
    linkdeps_new = """\n\tdata, err = readArchiveData(archive, Filename)\n\tif err != nil {\n\t\tif errors.Is(err, os.ErrNotExist) {\n\t\t\treturn res, nil\n\t\t}\n\t\treturn res, fmt.Errorf(\"reading %s from %q: %w\", Filename, archive, err)\n\t}\n"""
    if linkdeps_old not in linkdeps_src:
        fail("Could not patch Orchestrion linkdeps in %s" % linkdeps_path)
    ctx.file(linkdeps_path, linkdeps_src.replace(linkdeps_old, linkdeps_new))

    compile_proxy_path = "internal/toolexec/proxy/compile.go"
    compile_proxy_src = ctx.read(compile_proxy_path)
    compile_flag_old = """type compileFlagSet struct {\n\tAsmhdr      string `ddflag:\"-asmhdr\"`\n\tBuildID     string `ddflag:\"-buildid\"`\n\tImportCfg   string `ddflag:\"-importcfg\"`\n\tLang        string `ddflag:\"-lang\"`\n\tOutput      string `ddflag:\"-o\"`\n\tPackage     string `ddflag:\"-p\"`\n\tShowVersion bool   `ddflag:\"-V\"`\n}\n"""
    compile_flag_new = """type compileFlagSet struct {\n\tAsmhdr      string `ddflag:\"-asmhdr\"`\n\tBuildID     string `ddflag:\"-buildid\"`\n\tImportCfg   string `ddflag:\"-importcfg\"`\n\tLang        string `ddflag:\"-lang\"`\n\tLinkObj     string `ddflag:\"-linkobj\"`\n\tOutput      string `ddflag:\"-o\"`\n\tPackage     string `ddflag:\"-p\"`\n\tShowVersion bool   `ddflag:\"-V\"`\n}\n"""
    if compile_flag_old not in compile_proxy_src:
        fail("Could not patch Orchestrion compile flags in %s" % compile_proxy_path)
    compile_proxy_src = compile_proxy_src.replace(compile_flag_old, compile_flag_new)
    compile_nbt_old = """\tjobs, err := client.FromEnvironment(ctx, cmd.WorkDir)\n\tif err != nil {\n\t\treturn nil, err\n\t}\n\n\tres, err := client.Request(ctx, jobs, nbt.StartRequest{ImportPath: importPath, BuildID: cmd.Flags.BuildID})\n"""
    compile_nbt_new = """\tif cmd.Flags.BuildID == \"\" {\n\t\tzerolog.Ctx(ctx).Trace().Str(\"import-path\", importPath).Msg(\"Skipping never-build-twice request because build ID is empty\")\n\t\treturn cmd, nil\n\t}\n\n\tjobs, err := client.FromEnvironment(ctx, cmd.WorkDir)\n\tif err != nil {\n\t\treturn nil, err\n\t}\n\n\tres, err := client.Request(ctx, jobs, nbt.StartRequest{ImportPath: importPath, BuildID: cmd.Flags.BuildID})\n"""
    if compile_nbt_old not in compile_proxy_src:
        fail("Could not patch Orchestrion compile NBT guard in %s" % compile_proxy_path)
    compile_proxy_src = compile_proxy_src.replace(compile_nbt_old, compile_nbt_new, 1)
    attach_old = """\tif _, err := os.Stat(cmd.Flags.Output); errors.Is(err, os.ErrNotExist) {\n\t\t// Already failing, not doing anything...\n\t\treturn nil\n\t} else if err != nil {\n\t\treturn err\n\t}\n\n\torchestrionDir := filepath.Join(cmd.Flags.Output, \"..\", \"orchestrion\")\n"""
    attach_new = """\ttargetArchive := cmd.Flags.LinkObj\n\tif targetArchive == \"\" {\n\t\ttargetArchive = cmd.Flags.Output\n\t}\n\n\tif _, err := os.Stat(targetArchive); errors.Is(err, os.ErrNotExist) {\n\t\t// Already failing, not doing anything...\n\t\treturn nil\n\t} else if err != nil {\n\t\treturn err\n\t}\n\n\torchestrionDir := filepath.Join(targetArchive, \"..\", \"orchestrion\")\n"""
    if attach_old not in compile_proxy_src:
        fail("Could not patch Orchestrion attachLinkDeps target in %s" % compile_proxy_path)
    compile_proxy_src = compile_proxy_src.replace(attach_old, attach_new)
    archive_old = """\tlog.Trace().Str(\"archive\", cmd.Flags.Output).Array(linkdeps.Filename, &cmd.LinkDeps).Msg(\"Adding \" + linkdeps.Filename + \" file in archive\")\n\n\tfile, err := os.OpenFile(cmd.Flags.Output, os.O_APPEND|os.O_WRONLY, 0o644)\n"""
    archive_new = """\tlog.Trace().Str(\"archive\", targetArchive).Array(linkdeps.Filename, &cmd.LinkDeps).Msg(\"Adding \" + linkdeps.Filename + \" file in archive\")\n\n\tfile, err := os.OpenFile(targetArchive, os.O_APPEND|os.O_WRONLY, 0o644)\n"""
    if archive_old not in compile_proxy_src:
        fail("Could not patch Orchestrion archive append target in %s" % compile_proxy_path)
    compile_proxy_src = compile_proxy_src.replace(archive_old, archive_new)
    notify_old = """\t\tfiles = make(map[nbt.Label]string, 2)\n\t\tif filename := cmd.Flags.Output; filename != \"\" {\n\t\t\tfiles[nbt.LabelArchive] = filename\n\t\t}\n"""
    notify_new = """\t\tfiles = make(map[nbt.Label]string, 2)\n\t\tif filename := cmd.Flags.LinkObj; filename != \"\" {\n\t\t\tfiles[nbt.LabelArchive] = filename\n\t\t} else if filename := cmd.Flags.Output; filename != \"\" {\n\t\t\tfiles[nbt.LabelArchive] = filename\n\t\t}\n"""
    if notify_old not in compile_proxy_src:
        fail("Could not patch Orchestrion finish archive file in %s" % compile_proxy_path)
    compile_proxy_src = compile_proxy_src.replace(notify_old, notify_new)
    ctx.file(compile_proxy_path, compile_proxy_src)

    compile_flags_path = "internal/toolexec/proxy/compile.flags.go"
    compile_flags_src = ctx.read(compile_flags_path)
    compile_flags_old = """\tflagSet.String(\"linkobj\", \"\", \"write linker-specific object to file\")\n"""
    compile_flags_new = """\tflagSet.StringVar(&f.LinkObj, \"linkobj\", \"\", \"write linker-specific object to file\")\n"""
    if compile_flags_old not in compile_flags_src:
        fail("Could not patch Orchestrion compile parser in %s" % compile_flags_path)
    ctx.file(compile_flags_path, compile_flags_src.replace(compile_flags_old, compile_flags_new))

    oncompile_path = "internal/toolexec/aspect/oncompile.go"
    oncompile_src = ctx.read(oncompile_path)
    oncompile_old = """\t\tdeps, err := resolvePackageFiles(ctx, depImportPath, cmd.WorkDir)\n"""
    oncompile_new = """\t\tdeps, err := resolvePackageFiles(ctx, depImportPath, \".\")\n"""
    if oncompile_old not in oncompile_src:
        fail("Could not patch Orchestrion oncompile resolver context in %s" % oncompile_path)
    ctx.file(oncompile_path, oncompile_src.replace(oncompile_old, oncompile_new, 1))

    # Resolver-context patches for onlink / oncompile-main so dependency lookups
    # run under Bazel's import-path context instead of synthetic package names.
    onlink_path = "internal/toolexec/aspect/onlink.go"
    onlink_src = ctx.read(onlink_path)
    onlink_old = """\t\t\tdeps, err := resolvePackageFiles(ctx, depPath, cmd.WorkDir)\n"""
    onlink_new = """\t\t\tprevImportPath, hadImportPath := os.LookupEnv(\"TOOLEXEC_IMPORTPATH\")\n\t\t\tif err := os.Setenv(\"TOOLEXEC_IMPORTPATH\", w.ImportPath); err != nil {\n\t\t\t\treturn fmt.Errorf(\"setting TOOLEXEC_IMPORTPATH=%q: %w\", w.ImportPath, err)\n\t\t\t}\n\t\t\tdeps, err := resolvePackageFiles(ctx, depPath, \".\")\n\t\t\tif hadImportPath {\n\t\t\t\t_ = os.Setenv(\"TOOLEXEC_IMPORTPATH\", prevImportPath)\n\t\t\t} else {\n\t\t\t\t_ = os.Unsetenv(\"TOOLEXEC_IMPORTPATH\")\n\t\t\t}\n"""
    if onlink_old not in onlink_src:
        fail("Could not patch Orchestrion onlink resolver context in %s" % onlink_path)
    ctx.file(onlink_path, onlink_src.replace(onlink_old, onlink_new, 1))

    oncompile_main_path = "internal/toolexec/aspect/oncompile-main.go"
    oncompile_main_src = ctx.read(oncompile_main_path)
    oncompile_main_old = """\t\tdeps, err := resolvePackageFiles(ctx, linkDepPath, cmd.WorkDir)\n"""
    oncompile_main_new = """\t\tprevImportPath, hadImportPath := os.LookupEnv(\"TOOLEXEC_IMPORTPATH\")\n\t\tif err := os.Setenv(\"TOOLEXEC_IMPORTPATH\", \"main\"); err != nil {\n\t\t\treturn fmt.Errorf(\"setting TOOLEXEC_IMPORTPATH for synthetic main: %w\", err)\n\t\t}\n\t\tfor archiveImportPath, archivePath := range reg.PackageFile {\n\t\t\tld, ldErr := linkdeps.FromArchive(ctx, archivePath)\n\t\t\tif ldErr != nil || !ld.Contains(linkDepPath) {\n\t\t\t\tcontinue\n\t\t\t}\n\t\t\tif err := os.Setenv(\"TOOLEXEC_IMPORTPATH\", archiveImportPath); err != nil {\n\t\t\t\treturn fmt.Errorf(\"setting TOOLEXEC_IMPORTPATH=%q: %w\", archiveImportPath, err)\n\t\t\t}\n\t\t\tbreak\n\t\t}\n\t\tdeps, err := resolvePackageFiles(ctx, linkDepPath, \".\")\n\t\tif hadImportPath {\n\t\t\t_ = os.Setenv(\"TOOLEXEC_IMPORTPATH\", prevImportPath)\n\t\t} else {\n\t\t\t_ = os.Unsetenv(\"TOOLEXEC_IMPORTPATH\")\n\t\t}\n"""
    if oncompile_main_old not in oncompile_main_src:
        fail("Could not patch Orchestrion oncompile-main resolver context in %s" % oncompile_main_path)
    ctx.file(oncompile_main_path, oncompile_main_src.replace(oncompile_main_old, oncompile_main_new, 1))

    # Process-tree and injector prefilter patches that keep Orchestrion stable
    # under Bazel's parent process graph and stdlib weaving path.
    goflags_path = "internal/goflags/flags.go"
    goflags_src = ctx.read(goflags_path)
    goflags_old = """\t\tif err != nil {\n\t\t\treturn flags, fmt.Errorf(\"failed to resolve argv0 (%q) of %d: %w\", args[0], p.Pid, err)\n\t\t}\n"""
    goflags_new = """\t\tif err != nil {\n\t\t\tlog.Trace().Err(err).Int32(\"process.pid\", p.Pid).Strs(\"args\", args).Msg(\"Skipping parent process with unresolvable argv0\")\n\t\t\tcontinue\n\t\t}\n"""
    if goflags_old not in goflags_src:
        fail("Could not patch Orchestrion parent argv0 resolution in %s" % goflags_path)
    goflags_src = goflags_src.replace(goflags_old, goflags_new, 1)
    goflags_cmdline_old = """\t\targs, err = p.CmdlineSliceWithContext(ctx)\n\t\tif err != nil {\n\t\t\treturn flags, fmt.Errorf(\"failed to get command line of %d: %w\", p.Pid, err)\n\t\t}\n"""
    goflags_cmdline_new = """\t\targs, err = p.CmdlineSliceWithContext(ctx)\n\t\tif err != nil {\n\t\t\tlog.Trace().Err(err).Int32(\"process.pid\", p.Pid).Msg(\"Skipping parent process with unreadable command line\")\n\t\t\tif p.Pid == 1 {\n\t\t\t\treturn flags, nil\n\t\t\t}\n\t\t\tcontinue\n\t\t}\n"""
    if goflags_cmdline_old not in goflags_src:
        fail("Could not patch Orchestrion parent cmdline resolution in %s" % goflags_path)
    goflags_src = goflags_src.replace(goflags_cmdline_old, goflags_cmdline_new, 1)
    goflags_parent_old = """\t\tp, err = p.ParentWithContext(ctx)\n\t\tif err != nil {\n\t\t\treturn flags, fmt.Errorf(\"failed to find parent process of %d: %w\", p.Pid, err)\n\t\t}\n"""
    goflags_parent_new = """\t\tp, err = p.ParentWithContext(ctx)\n\t\tif err != nil {\n\t\t\tlog.Trace().Err(err).Int32(\"process.pid\", p.Pid).Msg(\"Stopping parent process walk\")\n\t\t\treturn flags, nil\n\t\t}\n"""
    if goflags_parent_old not in goflags_src:
        fail("Could not patch Orchestrion parent walk termination in %s" % goflags_path)
    ctx.file(goflags_path, goflags_src.replace(goflags_parent_old, goflags_parent_new, 1))

    inject_path = "internal/injector/aspect/advice/inject.go"
    inject_src = ctx.read(inject_path)
    inject_old = """func (a injectDeclarations) AddedImports() []string {\n\treturn append(a.Template.AddedImports(), a.Links...)\n}\n"""
    inject_new = """func (a injectDeclarations) AddedImports() []string {\n\t// Link-only dependencies are not source imports. Treating them as imports\n\t// makes the package-level prefilter drop aspects for stdlib packages whose\n\t// importcfg cannot list Datadog helper archives ahead of weaving.\n\treturn a.Template.AddedImports()\n}\n"""
    if inject_old not in inject_src:
        fail("Could not patch Orchestrion inject-declarations imports in %s" % inject_path)
    ctx.file(inject_path, inject_src.replace(inject_old, inject_new, 1))

    # Stdlib lookup patch so Bazel-built stdlib/testmain compiles can fall back
    # to the correct archive family when importcfg alone is insufficient.
    oncompile_diag_path = "internal/toolexec/aspect/oncompile.go"
    oncompile_diag_src = ctx.read(oncompile_diag_path)
    oncompile_imports_old = """\t\"context\"\n\t\"fmt\"\n\t\"os\"\n\t\"path/filepath\"\n\t\"slices\"\n\t\"strings\"\n"""
    oncompile_imports_new = """\t\"context\"\n\t\"fmt\"\n\t\"io\"\n\t\"os\"\n\t\"os/exec\"\n\t\"path/filepath\"\n\t\"slices\"\n\t\"strings\"\n"""
    if oncompile_imports_old not in oncompile_diag_src:
        fail("Could not patch Orchestrion oncompile imports in %s" % oncompile_diag_path)
    oncompile_diag_src = oncompile_diag_src.replace(oncompile_imports_old, oncompile_imports_new, 1)
    oncompile_diag_old = """\tlog := zerolog.Ctx(ctx).With().Str(\"phase\", \"compile\").Str(\"import-path\", w.ImportPath).Logger()\n\tctx = log.WithContext(ctx)\n\n\timports, err := importcfg.ParseFile(ctx, cmd.Flags.ImportCfg)\n"""
    oncompile_diag_new = """\tlog := zerolog.Ctx(ctx).With().Str(\"phase\", \"compile\").Str(\"import-path\", w.ImportPath).Logger()\n\tctx = log.WithContext(ctx)\n\n\timports, err := importcfg.ParseFile(ctx, cmd.Flags.ImportCfg)\n"""
    if oncompile_diag_old not in oncompile_diag_src:
        fail("Could not patch Orchestrion oncompile diagnostics in %s" % oncompile_diag_path)
    oncompile_diag_src = oncompile_diag_src.replace(oncompile_diag_old, oncompile_diag_new, 1)
    oncompile_lookup_old = """\t\tLookup:     imports.Lookup,\n"""
    oncompile_lookup_new = """\t\tLookup:     fallbackLookup(imports.Lookup),\n"""
    if oncompile_lookup_old not in oncompile_diag_src:
        fail("Could not patch Orchestrion oncompile lookup in %s" % oncompile_diag_path)
    oncompile_diag_src = oncompile_diag_src.replace(oncompile_lookup_old, oncompile_lookup_new, 1)
    oncompile_helper = """
func fallbackLookup(primary func(string) (io.ReadCloser, error)) func(string) (io.ReadCloser, error) {
	return func(path string) (io.ReadCloser, error) {
		if goroot := strings.TrimSpace(os.Getenv("GOROOT")); goroot != "" && !strings.Contains(path, ".") {
			installSuffix := strings.TrimSpace(os.Getenv("GOOS")) + "_" + strings.TrimSpace(os.Getenv("GOARCH"))
			if installSuffix != "_" {
				pkgArchive := filepath.Join(goroot, "pkg", installSuffix, filepath.FromSlash(path)+".a")
				if _, statErr := os.Stat(pkgArchive); statErr == nil {
					return os.Open(pkgArchive)
				}
			}
		}
		if rc, err := primary(path); err == nil {
			return rc, nil
		} else if strings.Contains(path, ".") {
			return nil, err
		}
		cmd := exec.Command("go", "list", "-export", "-find", "-f", "{{.Export}}", path)
		cmd.Env = os.Environ()
		cmd.Env = append(cmd.Env, "GO111MODULE=off")
		out, err := cmd.CombinedOutput()
		if err != nil {
			return nil, err
		}
		exportFile := strings.TrimSpace(string(out))
		return os.Open(exportFile)
	}
}

"""
    oncompile_insert_after = """var OrchestrionDirPathElement = filepath.Join(\"orchestrion\", \"src\")\n\n"""
    if oncompile_insert_after not in oncompile_diag_src:
        fail("Could not patch Orchestrion oncompile helper insertion point in %s" % oncompile_diag_path)
    oncompile_diag_src = oncompile_diag_src.replace(oncompile_insert_after, oncompile_insert_after + oncompile_helper, 1)
    ctx.file(oncompile_diag_path, oncompile_diag_src)
    _probe_emit(ctx, "extensions.patch_source_tree", start_ms = patch_start_ms)

    # Build the patched Orchestrion tool from its upstream module graph. The
    # configured tracer versions are written to dd_trace_go_versions.json and
    # enforced later against the target module by the builder/runtime path.
    go_env = _go_env(ctx)
    build_args = [
        str(go_path),
        "build",
        "-trimpath",
        "-ldflags",
        "-s -w",
        "-o",
        binary_name,
        ".",
    ]
    ctx.report_progress("rules_go_orchestrion: building orchestrion binary")
    build_start_ms = _probe_now_ms(ctx)
    result = ctx.execute(
        build_args,
        timeout = 600,
        environment = go_env,
    )
    _probe_emit(ctx, "extensions.go_build_initial", start_ms = build_start_ms, status = "ok" if result.return_code == 0 else "error")
    if result.return_code == 0:
        _probe_emit(ctx, "extensions.go_build", start_ms = build_start_ms, status = "ok")
    else:
        fail("Failed to build orchestrion from upstream module graph: %s\n%s" % (result.stdout, result.stderr))

    _write_orchestrion_repo_files(ctx, binary_name, dd_trace_go_versions)
    cache_write_start_ms = _probe_now_ms(ctx)
    _write_bootstrap_cache(ctx, bootstrap_cache, version, dd_trace_go_versions, go_identity, binary_name)
    _probe_emit(
        ctx,
        "extensions.bootstrap_cache_write",
        start_ms = cache_write_start_ms,
        extra = {
            "cache_key": bootstrap_cache.key,
            "cache_root": bootstrap_cache.cache_root,
        },
    )
    _probe_emit(ctx, "extensions.orchestrion_build_total", start_ms = total_start_ms, extra = {"dd_trace_go_version": dd_trace_go_versions["github.com/DataDog/dd-trace-go/v2"]})

_orchestrion_build = repository_rule(
    implementation = _orchestrion_build_impl,
    attrs = {
        "version": attr.string(mandatory = True, doc = "Orchestrion version to build"),
        "dd_trace_go_version": attr.string(default = "", doc = "dd-trace-go version to validate against the target module for Orchestrion-backed instrumentation"),
        "dd_trace_go_versions": attr.string_dict(doc = "Per-module dd-trace-go versions to validate against the target module for Orchestrion-backed instrumentation"),
        "log_timing": attr.bool(default = False, doc = "Emit structured timing probes while building Orchestrion"),
    },
)

def _orchestrion_empty_impl(ctx):
    """Create an empty placeholder repo."""
    ctx.file("BUILD.bazel", """# Generated by rules_go orchestrion extension
# No orchestrion configured
filegroup(
    name = "orchestrion",
    srcs = [],
    visibility = ["//visibility:public"],
)

filegroup(
    name = "dd_trace_go_version_file",
    srcs = [],
    visibility = ["//visibility:public"],
)
""")

_orchestrion_empty = repository_rule(
    implementation = _orchestrion_empty_impl,
)

def _orchestrion_ext_impl(module_ctx):
    # Look for orchestrion.from_source() calls from any module
    version = ""
    dd_trace_go_version = ""
    dd_trace_go_versions = {}
    log_timing = False
    for mod in module_ctx.modules:
        for from_source in mod.tags.from_source:
            if from_source.version:
                if from_source.dd_trace_go_version and from_source.dd_trace_go_versions:
                    fail("dd_trace_go_version and dd_trace_go_versions cannot both be set in orchestrion.from_source()")
                version = from_source.version
                log_timing = from_source.log_timing
                if from_source.dd_trace_go_version:
                    dd_trace_go_version = from_source.dd_trace_go_version
                if from_source.dd_trace_go_versions:
                    dd_trace_go_versions = from_source.dd_trace_go_versions
                break
        if version:
            break

    if version:
        _orchestrion_build(
            name = "rules_go_orchestrion_tool",
            version = version,
            dd_trace_go_version = dd_trace_go_version,
            dd_trace_go_versions = dd_trace_go_versions,
            log_timing = log_timing,
        )
    else:
        _orchestrion_empty(
            name = "rules_go_orchestrion_tool",
        )

_from_source = tag_class(
    attrs = {
        "version": attr.string(
            mandatory = True,
            doc = "Orchestrion version to build (e.g., 'v1.5.0')",
        ),
        "dd_trace_go_version": attr.string(
            default = "",
            doc = "dd-trace-go version to validate against the target module for Orchestrion-backed instrumentation.",
        ),
        "dd_trace_go_versions": attr.string_dict(
            doc = "Per-module dd-trace-go versions to validate against the target module for Orchestrion-backed instrumentation.",
        ),
        "log_timing": attr.bool(
            default = False,
            doc = "Emit structured timing probes while building the Orchestrion tool repository.",
        ),
    },
)

orchestrion_ext = module_extension(
    implementation = _orchestrion_ext_impl,
    tag_classes = {
        "from_source": _from_source,
    },
)
