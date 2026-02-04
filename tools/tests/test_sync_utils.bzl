load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//tools:test_optimization_sync.bzl", "build_module_label_map_for_tests", "compute_dd_api_base_for_tests")

def _dd_site_normalization_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("datadoghq.com"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("app.datadoghq.com"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("api.datadoghq.com"))
    asserts.equals(env, "https://api.datadoghq.com", compute_dd_api_base_for_tests("https://app.datadoghq.com"))
    asserts.equals(env, "https://api.us5.datadoghq.com", compute_dd_api_base_for_tests("https://api.us5.datadoghq.com/"))
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
    return unittest.end(env)

dd_site_normalization_test = unittest.make(_dd_site_normalization_test)
module_label_map_collision_test = unittest.make(_module_label_map_collision_test)
