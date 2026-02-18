# Unit tests for sync utilities (DD_SITE normalization + module label mapping).
"""Unit tests for sync utility helpers."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//tools/tests:example_stub_repo.bzl",
    "render_stub_build_for_tests",
)
load(
    "//tools/core:test_optimization_sync.bzl",
    "build_unix_read_abs_file_command_for_tests",
    "build_windows_read_abs_file_command_for_tests",
    "build_module_label_map_for_tests",
    "clone_payload_with_detached_attributes_for_tests",
    "collect_env_from_environ_for_tests",
    "compute_dd_api_base_for_tests",
    "decode_json_object_or_fail_for_tests",
    "dirname_for_tests",
    "fnv1a_32_for_tests",
    "normalize_out_dir_or_fail_for_tests",
    "http_execute_timeout_buffer_seconds_for_tests",
    "http_execute_timeout_seconds_for_tests",
    "http_max_time_seconds_for_tests",
    "normalize_ref_for_tests",
    "parse_go_module_path_for_tests",
    "partition_unix_headers_for_tests",
    "record_sync_extension_repo_owner_or_fail_for_tests",
    "render_export_bzl_for_tests",
    "render_module_runfiles_bzl_for_tests",
    "http_retry_attempts_for_tests",
    "http_retry_delay_seconds_for_tests",
    "resolve_dd_api_base_for_tests",
)

def _dd_site_normalization_test(ctx):
    """Validate DD_SITE normalization into canonical API base URL."""
    env = unittest.begin(ctx)
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("datadoghq.com"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("app.datadoghq.com"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("api.datadoghq.com"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("https://app.datadoghq.com"))
    asserts.equals(env, "https://api.us5.datadoghq.com", compute_dd_api_base_for_tests("https://api.us5.datadoghq.com/"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests(""))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("   "))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("https://api.datadoghq.com/path"))
    asserts.equals(env, "https://api.datadoghq.eu", compute_dd_api_base_for_tests("http://app.datadoghq.eu/foo"))
    return unittest.end(env)

def _resolve_dd_api_base_test(ctx):
    """Validate DD_TEST_OPTIMIZATION_API_BASE override precedence."""
    env = unittest.begin(ctx)
    # Ensure overrides take precedence over DD_SITE-derived defaults.
    asserts.equals(
        env,
        "https://api.datadoghq.com",
        resolve_dd_api_base_for_tests("datadoghq.com", ""),
    )
    asserts.equals(
        env,
        "https://api.datadoghq.com",
        resolve_dd_api_base_for_tests("app.datadoghq.com", None),
    )
    asserts.equals(
        env,
        "https://example.com",
        resolve_dd_api_base_for_tests("datadoghq.com", "https://example.com"),
    )
    asserts.equals(
        env,
        "https://example.com",
        resolve_dd_api_base_for_tests("datadoghq.com", "https://example.com/"),
    )
    # None/empty inputs should still resolve to the default site endpoint.
    asserts.equals(
        env,
        "https://api.datadoghq.com",
        resolve_dd_api_base_for_tests(None, None),
    )
    asserts.equals(
        env,
        "https://api.datadoghq.com",
        resolve_dd_api_base_for_tests(None, ""),
    )
    return unittest.end(env)

def _module_label_map_collision_test(ctx):
    """Validate deterministic dedup when module labels collide."""
    env = unittest.begin(ctx)
    label_map = build_module_label_map_for_tests(["Foo-Bar"], ["Foo_Bar"])
    asserts.equals(env, 2, len(label_map))
    label_a = label_map.get("Foo-Bar")
    label_b = label_map.get("Foo_Bar")
    asserts.true(env, label_a != None)
    asserts.true(env, label_b != None)
    asserts.true(env, label_a != label_b)

    # Ensure ordering of inputs does not change the mapping
    label_map_rev = build_module_label_map_for_tests(["Foo_Bar"], ["Foo-Bar"])
    asserts.equals(env, label_a, label_map_rev.get("Foo-Bar"))
    asserts.equals(env, label_b, label_map_rev.get("Foo_Bar"))

    # Multiple collisions should dedup deterministically
    multi = build_module_label_map_for_tests(["a-b", "a_b"], ["a b"])
    asserts.equals(env, 3, len(multi))
    labels = [multi.get("a-b"), multi.get("a_b"), multi.get("a b")]
    asserts.true(env, labels[0] != labels[1])
    asserts.true(env, labels[0] != labels[2])
    asserts.true(env, labels[1] != labels[2])
    return unittest.end(env)

def _normalize_ref_test(ctx):
    """Validate ref-prefix normalization helper."""
    env = unittest.begin(ctx)
    asserts.equals(env, "main", normalize_ref_for_tests("refs/heads/main"))
    asserts.equals(env, "v1.2.3", normalize_ref_for_tests("refs/tags/v1.2.3"))
    asserts.equals(env, "feature/foo", normalize_ref_for_tests("origin/feature/foo"))
    asserts.equals(env, "main", normalize_ref_for_tests("origin/refs/heads/main"))
    asserts.equals(env, "main", normalize_ref_for_tests("refs/remotes/origin/main"))
    asserts.equals(env, "main", normalize_ref_for_tests("main"))
    asserts.equals(env, "", normalize_ref_for_tests(""))
    return unittest.end(env)

def _collect_env_from_environ_provider_mapping_test(ctx):
    """Validate provider extraction and DD_* override precedence."""
    env = unittest.begin(ctx)

    github = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "GITHUB_SHA": "abc123",
        "GITHUB_REPOSITORY": "org/repo",
        "GITHUB_SERVER_URL": "https://github.example",
        "GITHUB_REF": "refs/heads/main",
    }, None)
    asserts.equals(env, "github_actions", github.get("ci_provider_name"))
    asserts.equals(env, "https://github.example/org/repo.git", github.get("repository_url"))
    asserts.equals(env, "main", github.get("branch"))
    asserts.equals(env, "abc123", github.get("sha"))
    asserts.equals(env, "unnamed-service", github.get("service"))

    overridden = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "DD_SERVICE": "service-from-env",
        "GITHUB_SHA": "abc123",
        "GITHUB_REPOSITORY": "org/repo",
        "GITHUB_REF": "refs/heads/main",
        "DD_GIT_REPOSITORY_URL": "https://override/repo.git",
        "DD_GIT_BRANCH": "refs/remotes/origin/release",
        "DD_GIT_COMMIT_SHA": "deadbeef",
    }, "service-from-attr")
    asserts.equals(env, "service-from-attr", overridden.get("service"))
    asserts.equals(env, "https://override/repo.git", overridden.get("repository_url"))
    asserts.equals(env, "release", overridden.get("branch"))
    asserts.equals(env, "deadbeef", overridden.get("sha"))

    appveyor = collect_env_from_environ_for_tests({
        "DD_SITE": "datadoghq.com",
        "APPVEYOR": "True",
        "APPVEYOR_REPO_PROVIDER": "github",
        "APPVEYOR_REPO_NAME": "team/repo",
        "APPVEYOR_REPO_COMMIT": "cafebabe",
        "APPVEYOR_PULL_REQUEST_HEAD_REPO_BRANCH": "refs/heads/pr-branch",
        "APPVEYOR_REPO_BRANCH": "refs/heads/fallback",
    }, None)
    asserts.equals(env, "appveyor", appveyor.get("ci_provider_name"))
    asserts.equals(env, "https://github.com/team/repo.git", appveyor.get("repository_url"))
    asserts.equals(env, "pr-branch", appveyor.get("branch"))
    asserts.equals(env, "cafebabe", appveyor.get("sha"))
    return unittest.end(env)

def _read_abs_file_command_escaping_test(ctx):
    """Validate read-command construction escapes single quotes safely."""
    env = unittest.begin(ctx)
    unix_cmd = build_unix_read_abs_file_command_for_tests("/tmp/it's/test.txt")
    asserts.true(env, "'\\''" in unix_cmd)
    asserts.true(env, unix_cmd.startswith("[ -f '"))
    asserts.true(env, "&& cat '" in unix_cmd)

    ps_cmd = build_windows_read_abs_file_command_for_tests("C:\\tmp\\it's\\file.txt")
    asserts.true(env, "''" in ps_cmd)
    asserts.true(env, "$p = '" in ps_cmd)
    asserts.true(env, "Get-Content -Raw -LiteralPath $p" in ps_cmd)
    return unittest.end(env)

def _parse_go_module_path_test(ctx):
    """Validate go.mod module path extraction helper."""
    env = unittest.begin(ctx)
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("module github.com/foo/bar"))
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("module\tgithub.com/foo/bar"))
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("module \"github.com/foo/bar\""))
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("// comment\nmodule 'github.com/foo/bar'\n"))
    asserts.equals(env, "", parse_go_module_path_for_tests("// module github.com/foo/bar"))
    asserts.equals(env, "", parse_go_module_path_for_tests(""))
    return unittest.end(env)

def _dirname_test(ctx):
    """Validate dirname helper behavior across path forms."""
    env = unittest.begin(ctx)
    asserts.equals(env, "foo/bar", dirname_for_tests("foo/bar/baz.txt"))
    asserts.equals(env, "foo", dirname_for_tests("/foo/bar"))
    asserts.equals(env, "foo", dirname_for_tests("./foo/bar"))
    asserts.equals(env, "", dirname_for_tests("/"))
    asserts.equals(env, "", dirname_for_tests(".."))
    asserts.equals(env, "", dirname_for_tests("foo"))
    asserts.equals(env, "", dirname_for_tests(""))
    return unittest.end(env)

def _normalize_out_dir_or_fail_test(ctx):
    """Validate out_dir normalization and accepted relative-path forms."""
    env = unittest.begin(ctx)
    asserts.equals(env, ".testoptimization", normalize_out_dir_or_fail_for_tests(".testoptimization"))
    asserts.equals(env, "custom_topt", normalize_out_dir_or_fail_for_tests(" custom_topt "))
    asserts.equals(env, "foo/bar", normalize_out_dir_or_fail_for_tests("./foo//bar/"))
    asserts.equals(env, "foo/bar", normalize_out_dir_or_fail_for_tests("foo\\bar"))
    return unittest.end(env)

def _export_bzl_manifest_path_test(ctx):
    """Validate manifest_path emission in generated export.bzl."""
    env = unittest.begin(ctx)
    content = render_export_bzl_for_tests(
        "repo",
        ["a"],
        "{}",
        "example.com/mod",
        "example_com_mod",
        True,
        ".testoptimization/manifest.txt",
    )
    asserts.true(env, "\"manifest_path\": \".testoptimization/manifest.txt\"" in content)
    asserts.true(env, "\"runtimes\": {" in content)
    asserts.true(env, "\"go\": {" in content)
    asserts.false(env, "\n    \"go\": {\n" in content)
    return unittest.end(env)

def _export_bzl_escaping_test(ctx):
    """Validate generated export.bzl escapes quote/backslash safely."""
    env = unittest.begin(ctx)
    content = render_export_bzl_for_tests(
        "repo\"name",
        ["a"],
        "{}",
        "go\"mod",
        "sanitized\\path",
        True,
        "path\\to\\manifest.txt",
    )
    asserts.true(env, "\"repo_name\": \"repo\\\"name\"" in content)
    asserts.true(env, "\"manifest_path\": \"path\\\\to\\\\manifest.txt\"" in content)
    asserts.true(env, "\"module_path\": \"go\\\"mod\"" in content)
    asserts.true(env, "\"sanitized_module_path\": \"sanitized\\\\path\"" in content)
    return unittest.end(env)

def _fnv1a_symbol_distinguishes_common_symbols_test(ctx):
    """Validate common symbols do not collapse to digit-zero hash path."""
    env = unittest.begin(ctx)
    base = fnv1a_32_for_tests("abc0def")
    asserts.true(env, fnv1a_32_for_tests("abc=def") != base)
    asserts.true(env, fnv1a_32_for_tests("abc@def") != base)
    asserts.true(env, fnv1a_32_for_tests("abc#def") != base)
    return unittest.end(env)

def _clone_payload_with_detached_attributes_test(ctx):
    """Validate module-specific mutations do not leak to source payload."""
    env = unittest.begin(ctx)
    original = {
        "data": {
            "attributes": {
                "tests": {
                    "module_a": {"suite_a": ["test_a"]},
                },
                "modules": {
                    "module_a": {"suite_a": {"test_a": {"properties": {"quarantined": False}}}},
                },
            },
            "id": "source-data",
        },
        "meta": {"source": "fixture"},
    }
    cloned = clone_payload_with_detached_attributes_for_tests(original)
    cloned_attrs = ((cloned.get("data") or {}).get("attributes") or {})
    cloned_attrs["tests"] = {
        "module_b": {"suite_b": ["test_b"]},
    }
    cloned_attrs["modules"] = {
        "module_b": {"suite_b": {}},
    }

    original_attrs = ((original.get("data") or {}).get("attributes") or {})
    original_tests = original_attrs.get("tests") or {}
    original_modules = original_attrs.get("modules") or {}
    asserts.true(env, original_tests.get("module_a") != None)
    asserts.equals(env, None, original_tests.get("module_b"))
    asserts.true(env, original_modules.get("module_a") != None)
    asserts.equals(env, None, original_modules.get("module_b"))
    return unittest.end(env)

def _example_stub_includes_manifest_in_files_test(ctx):
    """Ensure stub test_optimization_files includes manifest for contract parity."""
    env = unittest.begin(ctx)
    settings = ".testoptimization/cache/http/settings.json"
    manifest = ".testoptimization/manifest.txt"
    known_tests = ".testoptimization/cache/http/known_tests.json"
    test_management = ".testoptimization/cache/http/test_management.json"
    context = ".testoptimization/context.json"

    content = render_stub_build_for_tests(
        settings,
        manifest,
        known_tests,
        test_management,
        context,
    )
    filegroup_start = content.find('name = "test_optimization_files"')
    context_group_start = content.find('name = "test_optimization_context"')
    asserts.true(env, filegroup_start >= 0)
    asserts.true(env, context_group_start > filegroup_start)
    filegroup_block = content[filegroup_start:context_group_start]
    asserts.true(env, settings in filegroup_block)
    asserts.true(env, manifest in filegroup_block)
    asserts.true(env, known_tests in filegroup_block)
    asserts.true(env, test_management in filegroup_block)
    exports_start = content.find("exports_files(")
    asserts.true(env, exports_start > context_group_start)
    context_group_block = content[context_group_start:exports_start]
    asserts.true(env, context in context_group_block)
    return unittest.end(env)

def _http_execute_timeout_seconds_test(ctx):
    """Guard execute-timeout derivation against retry-policy drift."""
    env = unittest.begin(ctx)
    # Keep execute timeout derived from retry policy + explicit buffer instead
    # of a magic number to avoid accidentally clipping retries in CI.
    expected = (
        (http_retry_attempts_for_tests * http_max_time_seconds_for_tests) +
        ((http_retry_attempts_for_tests - 1) * http_retry_delay_seconds_for_tests) +
        http_execute_timeout_buffer_seconds_for_tests
    )
    asserts.equals(env, expected, http_execute_timeout_seconds_for_tests)
    asserts.true(env, http_execute_timeout_seconds_for_tests > (http_retry_attempts_for_tests * http_max_time_seconds_for_tests))
    return unittest.end(env)

def _render_module_runfiles_bzl_respects_manifest_root_test(ctx):
    """Validate module runfile symlink roots follow manifest root/out_dir."""
    env = unittest.begin(ctx)
    default_content = render_module_runfiles_bzl_for_tests(".testoptimization")
    asserts.true(env, 'syms[".testoptimization/cache/http/settings.json"] = ctx.file.settings' in default_content)
    asserts.true(env, 'syms[".testoptimization/manifest.txt"] = ctx.file.manifest' in default_content)
    asserts.true(env, 'syms[".testoptimization/cache/http/known_tests.json"] = kt' in default_content)
    asserts.true(env, 'syms[".testoptimization/cache/http/test_management.json"] = tm' in default_content)

    custom_content = render_module_runfiles_bzl_for_tests("custom_topt")
    asserts.true(env, 'syms["custom_topt/cache/http/settings.json"] = ctx.file.settings' in custom_content)
    asserts.true(env, 'syms["custom_topt/manifest.txt"] = ctx.file.manifest' in custom_content)
    asserts.true(env, 'syms["custom_topt/cache/http/known_tests.json"] = kt' in custom_content)
    asserts.true(env, 'syms["custom_topt/cache/http/test_management.json"] = tm' in custom_content)
    return unittest.end(env)

def _partition_unix_headers_test(ctx):
    """Validate Unix header partitioning keeps DD-API-KEY out of public headers."""
    env = unittest.begin(ctx)
    out = partition_unix_headers_for_tests({
        "DD-API-KEY": "super-secret",
        "Accept": "application/json",
        "Content-Type": "application/json",
    })
    asserts.true(env, out.get("has_dd_api_key"))
    asserts.equals(env, "super-secret", out.get("dd_api_key"))
    public_headers = out.get("public_headers") or {}
    asserts.equals(env, None, public_headers.get("DD-API-KEY"))
    asserts.equals(env, "application/json", public_headers.get("Accept"))
    asserts.equals(env, "application/json", public_headers.get("Content-Type"))
    return unittest.end(env)

def _record_sync_extension_repo_owner_success_test(ctx):
    """Validate sync-extension repo owner tracking success path."""
    env = unittest.begin(ctx)
    seen = {}
    record_sync_extension_repo_owner_or_fail_for_tests(seen, "repo_a", "module_a")
    record_sync_extension_repo_owner_or_fail_for_tests(seen, "repo_b", "module_a")
    asserts.equals(env, "module_a", seen.get("repo_a"))
    asserts.equals(env, "module_a", seen.get("repo_b"))
    return unittest.end(env)

def _decode_json_object_valid_test(ctx):
    """Validate JSON decode helper success path."""
    env = unittest.begin(ctx)
    obj = decode_json_object_or_fail_for_tests(
        "{\"data\": {\"attributes\": {\"marker\": \"ok\"}}}",
        "settings.json",
    )
    asserts.equals(env, "dict", type(obj))
    attrs = ((obj.get("data") or {}).get("attributes") or {})
    asserts.equals(env, "ok", attrs.get("marker"))
    return unittest.end(env)

def _decode_json_object_empty_target_impl(_ctx):
    """Target expected to fail on empty JSON payload."""
    decode_json_object_or_fail_for_tests("", "settings.json")
    return []

def _normalize_out_dir_empty_target_impl(_ctx):
    """Target expected to fail when out_dir is empty/whitespace."""
    normalize_out_dir_or_fail_for_tests("   ")
    return []

def _normalize_out_dir_absolute_target_impl(_ctx):
    """Target expected to fail when out_dir is absolute."""
    normalize_out_dir_or_fail_for_tests("/tmp/out")
    return []

def _normalize_out_dir_traversal_target_impl(_ctx):
    """Target expected to fail when out_dir includes traversal segments."""
    normalize_out_dir_or_fail_for_tests("foo/../bar")
    return []

def _normalize_out_dir_windows_drive_target_impl(_ctx):
    """Target expected to fail when out_dir includes a drive prefix."""
    normalize_out_dir_or_fail_for_tests("C:/tmp/out")
    return []

def _decode_json_object_non_json_target_impl(_ctx):
    """Target expected to fail on non-JSON payload."""
    decode_json_object_or_fail_for_tests("NOT_JSON", "settings.json")
    return []

def _decode_json_object_array_target_impl(_ctx):
    """Target expected to fail when top-level JSON is an array."""
    decode_json_object_or_fail_for_tests("[]", "settings.json")
    return []

def _decode_json_object_malformed_object_target_impl(_ctx):
    """Target expected to fail on deterministic malformed object-like JSON."""
    decode_json_object_or_fail_for_tests("{bad", "settings.json")
    return []

def _decode_json_object_malformed_array_target_impl(_ctx):
    """Target expected to fail on deterministic malformed array-like JSON."""
    decode_json_object_or_fail_for_tests("[bad", "settings.json")
    return []

def _record_sync_extension_repo_owner_duplicate_target_impl(_ctx):
    """Target expected to fail when sync extension repo names collide."""
    seen = {}
    record_sync_extension_repo_owner_or_fail_for_tests(seen, "repo_a", "module_a")
    record_sync_extension_repo_owner_or_fail_for_tests(seen, "repo_a", "module_b")
    return []

decode_json_object_empty_target_rule = rule(
    implementation = _decode_json_object_empty_target_impl,
)
normalize_out_dir_empty_target_rule = rule(
    implementation = _normalize_out_dir_empty_target_impl,
)
normalize_out_dir_absolute_target_rule = rule(
    implementation = _normalize_out_dir_absolute_target_impl,
)
normalize_out_dir_traversal_target_rule = rule(
    implementation = _normalize_out_dir_traversal_target_impl,
)
normalize_out_dir_windows_drive_target_rule = rule(
    implementation = _normalize_out_dir_windows_drive_target_impl,
)
decode_json_object_non_json_target_rule = rule(
    implementation = _decode_json_object_non_json_target_impl,
)
decode_json_object_array_target_rule = rule(
    implementation = _decode_json_object_array_target_impl,
)
decode_json_object_malformed_object_target_rule = rule(
    implementation = _decode_json_object_malformed_object_target_impl,
)
decode_json_object_malformed_array_target_rule = rule(
    implementation = _decode_json_object_malformed_array_target_impl,
)
record_sync_extension_repo_owner_duplicate_target_rule = rule(
    implementation = _record_sync_extension_repo_owner_duplicate_target_impl,
)

def _decode_json_object_empty_failure_test_impl(ctx):
    """Assert empty-response failure message remains actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "settings.json response is empty; expected JSON object")
    return analysistest.end(env)

def _normalize_out_dir_empty_failure_test_impl(ctx):
    """Assert empty out_dir failure keeps guidance explicit."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "out_dir must be a non-empty relative path")
    return analysistest.end(env)

def _normalize_out_dir_absolute_failure_test_impl(ctx):
    """Assert absolute out_dir failure stays actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "absolute paths are not allowed")
    return analysistest.end(env)

def _normalize_out_dir_traversal_failure_test_impl(ctx):
    """Assert traversal out_dir failure stays actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "must not contain '..' path traversal segments")
    return analysistest.end(env)

def _normalize_out_dir_windows_drive_failure_test_impl(ctx):
    """Assert drive-prefixed out_dir failure stays actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "must not include a Windows drive prefix")
    return analysistest.end(env)

def _decode_json_object_non_json_failure_test_impl(ctx):
    """Assert non-JSON failure message remains actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "settings.json response is not JSON")
    return analysistest.end(env)

def _decode_json_object_array_failure_test_impl(ctx):
    """Assert non-object JSON failure message remains actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "settings.json response must be a JSON object")
    return analysistest.end(env)

def _decode_json_object_malformed_object_failure_test_impl(ctx):
    """Assert malformed object-like JSON gets actionable diagnostics."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "settings.json response appears malformed JSON object")
    return analysistest.end(env)

def _decode_json_object_malformed_array_failure_test_impl(ctx):
    """Assert malformed array-like JSON gets actionable diagnostics."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "settings.json response appears malformed JSON array")
    return analysistest.end(env)

def _record_sync_extension_repo_owner_duplicate_failure_test_impl(ctx):
    """Assert sync extension duplicate-repo failure remains actionable."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "duplicate repository name 'repo_a' declared")
    return analysistest.end(env)

dd_site_normalization_test = unittest.make(_dd_site_normalization_test)
resolve_dd_api_base_test = unittest.make(_resolve_dd_api_base_test)
module_label_map_collision_test = unittest.make(_module_label_map_collision_test)
normalize_ref_test = unittest.make(_normalize_ref_test)
collect_env_from_environ_provider_mapping_test = unittest.make(_collect_env_from_environ_provider_mapping_test)
read_abs_file_command_escaping_test = unittest.make(_read_abs_file_command_escaping_test)
parse_go_module_path_test = unittest.make(_parse_go_module_path_test)
dirname_test = unittest.make(_dirname_test)
normalize_out_dir_or_fail_test = unittest.make(_normalize_out_dir_or_fail_test)
export_bzl_manifest_path_test = unittest.make(_export_bzl_manifest_path_test)
export_bzl_escaping_test = unittest.make(_export_bzl_escaping_test)
fnv1a_symbol_distinguishes_common_symbols_test = unittest.make(_fnv1a_symbol_distinguishes_common_symbols_test)
clone_payload_with_detached_attributes_test = unittest.make(_clone_payload_with_detached_attributes_test)
example_stub_includes_manifest_in_files_test = unittest.make(_example_stub_includes_manifest_in_files_test)
http_execute_timeout_seconds_test = unittest.make(_http_execute_timeout_seconds_test)
render_module_runfiles_bzl_respects_manifest_root_test = unittest.make(_render_module_runfiles_bzl_respects_manifest_root_test)
partition_unix_headers_test = unittest.make(_partition_unix_headers_test)
record_sync_extension_repo_owner_success_test = unittest.make(_record_sync_extension_repo_owner_success_test)
decode_json_object_valid_test = unittest.make(_decode_json_object_valid_test)
decode_json_object_empty_failure_test = analysistest.make(
    _decode_json_object_empty_failure_test_impl,
    expect_failure = True,
)
normalize_out_dir_empty_failure_test = analysistest.make(
    _normalize_out_dir_empty_failure_test_impl,
    expect_failure = True,
)
normalize_out_dir_absolute_failure_test = analysistest.make(
    _normalize_out_dir_absolute_failure_test_impl,
    expect_failure = True,
)
normalize_out_dir_traversal_failure_test = analysistest.make(
    _normalize_out_dir_traversal_failure_test_impl,
    expect_failure = True,
)
normalize_out_dir_windows_drive_failure_test = analysistest.make(
    _normalize_out_dir_windows_drive_failure_test_impl,
    expect_failure = True,
)
decode_json_object_non_json_failure_test = analysistest.make(
    _decode_json_object_non_json_failure_test_impl,
    expect_failure = True,
)
decode_json_object_array_failure_test = analysistest.make(
    _decode_json_object_array_failure_test_impl,
    expect_failure = True,
)
decode_json_object_malformed_object_failure_test = analysistest.make(
    _decode_json_object_malformed_object_failure_test_impl,
    expect_failure = True,
)
decode_json_object_malformed_array_failure_test = analysistest.make(
    _decode_json_object_malformed_array_failure_test_impl,
    expect_failure = True,
)
record_sync_extension_repo_owner_duplicate_failure_test = analysistest.make(
    _record_sync_extension_repo_owner_duplicate_failure_test_impl,
    expect_failure = True,
)
