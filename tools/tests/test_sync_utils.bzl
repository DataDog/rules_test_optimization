# Unit tests for sync utilities (DD_SITE normalization + module label mapping).
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//tools:test_optimization_sync.bzl",
    "build_module_label_map_for_tests",
    "compute_dd_api_base_for_tests",
    "decode_json_object_or_fail_for_tests",
    "dirname_for_tests",
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
    asserts.equals(env, "main", normalize_ref_for_tests("main"))
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
    asserts.equals(env, "", dirname_for_tests("foo"))
    asserts.equals(env, "", dirname_for_tests(""))
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
parse_go_module_path_test = unittest.make(_parse_go_module_path_test)
dirname_test = unittest.make(_dirname_test)
export_bzl_manifest_path_test = unittest.make(_export_bzl_manifest_path_test)
http_execute_timeout_seconds_test = unittest.make(_http_execute_timeout_seconds_test)
render_module_runfiles_bzl_respects_manifest_root_test = unittest.make(_render_module_runfiles_bzl_respects_manifest_root_test)
partition_unix_headers_test = unittest.make(_partition_unix_headers_test)
record_sync_extension_repo_owner_success_test = unittest.make(_record_sync_extension_repo_owner_success_test)
decode_json_object_valid_test = unittest.make(_decode_json_object_valid_test)
decode_json_object_empty_failure_test = analysistest.make(
    _decode_json_object_empty_failure_test_impl,
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
