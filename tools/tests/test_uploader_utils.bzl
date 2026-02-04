load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//tools:test_optimization_uploader.bzl", "render_template_for_tests")

def _render_template_substitution_test(ctx):
    env = unittest.begin(ctx)
    template = "A {x} B {{y}} C {z}"
    out = render_template_for_tests(template, {"x": 1, "z": "Z"})
    asserts.equals(env, "A 1 B {y} C Z", out)
    return unittest.end(env)

def _render_template_unescape_only_test(ctx):
    env = unittest.begin(ctx)
    template = "hello {{world}}"
    out = render_template_for_tests(template, {})
    asserts.equals(env, "hello {world}", out)
    return unittest.end(env)

def _render_template_missing_placeholder_test(ctx):
    env = unittest.begin(ctx)
    template = "X {missing} Y {value} Z"
    out = render_template_for_tests(template, {"value": "V"})
    asserts.equals(env, "X {missing} Y V Z", out)
    return unittest.end(env)

render_template_substitution_test = unittest.make(_render_template_substitution_test)
render_template_unescape_only_test = unittest.make(_render_template_unescape_only_test)
render_template_missing_placeholder_test = unittest.make(_render_template_missing_placeholder_test)
