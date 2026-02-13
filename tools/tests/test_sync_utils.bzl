# Unit tests for sync utilities (DD_SITE normalization + module label mapping).
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//tools:test_optimization_sync.bzl",
    "build_module_label_map_for_tests",
    "compute_dd_api_base_for_tests",
    "dirname_for_tests",
    "http_execute_timeout_seconds_for_tests",
    "normalize_ref_for_tests",
    "parse_go_module_path_for_tests",
    "render_export_bzl_for_tests",
    "resolve_dd_api_base_for_tests",
)

def _dd_site_normalization_test(ctx):
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
    env = unittest.begin(ctx)
    asserts.equals(env, "main", normalize_ref_for_tests("refs/heads/main"))
    asserts.equals(env, "v1.2.3", normalize_ref_for_tests("refs/tags/v1.2.3"))
    asserts.equals(env, "feature/foo", normalize_ref_for_tests("origin/feature/foo"))
    asserts.equals(env, "main", normalize_ref_for_tests("main"))
    return unittest.end(env)

def _parse_go_module_path_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("module github.com/foo/bar"))
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("module\tgithub.com/foo/bar"))
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("module \"github.com/foo/bar\""))
    asserts.equals(env, "github.com/foo/bar", parse_go_module_path_for_tests("// comment\nmodule 'github.com/foo/bar'\n"))
    asserts.equals(env, "", parse_go_module_path_for_tests("// module github.com/foo/bar"))
    asserts.equals(env, "", parse_go_module_path_for_tests(""))
    return unittest.end(env)

def _dirname_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "foo/bar", dirname_for_tests("foo/bar/baz.txt"))
    asserts.equals(env, "foo", dirname_for_tests("/foo/bar"))
    asserts.equals(env, "foo", dirname_for_tests("./foo/bar"))
    asserts.equals(env, "", dirname_for_tests("foo"))
    asserts.equals(env, "", dirname_for_tests(""))
    return unittest.end(env)

def _export_bzl_manifest_path_test(ctx):
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
    env = unittest.begin(ctx)
    # Keep this aligned with curl/Invoke-WebRequest max-time plus startup overhead.
    asserts.equals(env, 120, http_execute_timeout_seconds_for_tests)
    return unittest.end(env)

dd_site_normalization_test = unittest.make(_dd_site_normalization_test)
resolve_dd_api_base_test = unittest.make(_resolve_dd_api_base_test)
module_label_map_collision_test = unittest.make(_module_label_map_collision_test)
normalize_ref_test = unittest.make(_normalize_ref_test)
parse_go_module_path_test = unittest.make(_parse_go_module_path_test)
dirname_test = unittest.make(_dirname_test)
export_bzl_manifest_path_test = unittest.make(_export_bzl_manifest_path_test)
http_execute_timeout_seconds_test = unittest.make(_http_execute_timeout_seconds_test)
