# Unit tests for go_bootstrap path validation helpers.

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//tools/dev:go_bootstrap.bzl", "contains_parent_segment_for_tests")

def _contains_parent_segment_test(ctx):
    """Validate traversal-segment detection across slash styles."""
    env = unittest.begin(ctx)
    asserts.equals(env, False, contains_parent_segment_for_tests("modules/go"))
    asserts.equals(env, False, contains_parent_segment_for_tests("nested/path"))
    asserts.equals(env, False, contains_parent_segment_for_tests("segment..name"))
    asserts.equals(env, True, contains_parent_segment_for_tests("../modules/go"))
    asserts.equals(env, True, contains_parent_segment_for_tests("modules/../go"))
    asserts.equals(env, True, contains_parent_segment_for_tests("modules\\..\\go"))
    return unittest.end(env)

contains_parent_segment_test = unittest.make(_contains_parent_segment_test)
