load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//go/private/actions:link.bzl",
    "golink_resource_set_for_test",
    "parse_lld_thread_count_for_test",
)

def _parse_lld_thread_count_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, 1, parse_lld_thread_count_for_test([]))
    asserts.equals(env, 2, parse_lld_thread_count_for_test(["-Wl,--threads=2"]))
    asserts.equals(env, 4, parse_lld_thread_count_for_test(["-Wl,--threads=4"]))
    asserts.equals(env, 1, parse_lld_thread_count_for_test(["-Wl,--threads=bogus"]))
    return unittest.end(env)

def _golink_resource_set_callback_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, {"cpu": 1, "memory": 512}, golink_resource_set_for_test([])("macos", []))
    asserts.equals(env, {"cpu": 2, "memory": 512}, golink_resource_set_for_test(["-Wl,--threads=2"])("macos", []))
    asserts.equals(env, {"cpu": 4, "memory": 512}, golink_resource_set_for_test(["-Wl,--threads=4"])("macos", []))
    asserts.equals(env, {"cpu": 1, "memory": 512}, golink_resource_set_for_test(["-Wl,--threads=9"])("macos", []))
    return unittest.end(env)

parse_lld_thread_count_test = unittest.make(_parse_lld_thread_count_test)
golink_resource_set_callback_test = unittest.make(_golink_resource_set_callback_test)

def link_test_suite():
    unittest.suite(
        "link_tests",
        parse_lld_thread_count_test,
        golink_resource_set_callback_test,
    )
