"""Analysis tests for topt_py_payloads_selector selection behavior."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@datadog-rules-test-optimization-python//:topt_py_infer.bzl", "topt_py_payloads_selector")

_COMMON_MODULE_GROUPS = [
    ":module_example_python_explicit_pkg",
    ":module_example_python_imports_pkg",
    ":module_example_python_deps_pkg",
    ":module_example_python_attr_pkg",
    ":module_example_python_fallback_pkg",
    ":module_custom_override",
]

def _payload_marker_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".payload")
    ctx.actions.write(out, ctx.attr.marker + "\n")
    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]),
    )]

_payload_marker = rule(
    implementation = _payload_marker_impl,
    attrs = {
        "marker": attr.string(mandatory = True),
    },
)

def _py_source_impl(_ctx):
    return []

_py_source = rule(
    implementation = _py_source_impl,
    attrs = {
        "imports": attr.string_list(),
        "importpath": attr.string(),
        "module_path": attr.string(),
        "deps": attr.label_list(),
    },
)

def selector_payload_fixture_targets():
    _payload_marker(
        name = "full_payload",
        marker = "full",
    )
    _payload_marker(
        name = "module_example_python_explicit_pkg",
        marker = "module:explicit",
    )
    _payload_marker(
        name = "module_example_python_imports_pkg",
        marker = "module:imports",
    )
    _payload_marker(
        name = "module_example_python_deps_pkg",
        marker = "module:deps",
    )
    _payload_marker(
        name = "module_example_python_attr_pkg",
        marker = "module:attrs",
    )
    _payload_marker(
        name = "module_example_python_fallback_pkg",
        marker = "module:fallback",
    )
    _payload_marker(
        name = "module_custom_override",
        marker = "module:override",
    )
    _py_source(
        name = "imports_leaf",
        imports = ["example/python/imports/pkg"],
    )
    _py_source(
        name = "deps_leaf",
        importpath = "example/python/deps/pkg",
    )
    _py_source(
        name = "deps_wrapper",
        deps = [":deps_leaf"],
    )

def selector_explicit_precedence_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        explicit_identifier = "example/python/explicit/pkg",
        imports = ["example/python/imports/pkg"],
        deps = [":deps_wrapper"],
        attribute_candidates = ["example/python/attr/pkg"],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_imports_precedence_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = ["example/python/imports/pkg"],
        deps = [":deps_wrapper"],
        attribute_candidates = ["example/python/attr/pkg"],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_deps_precedence_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = [],
        deps = [":deps_wrapper"],
        attribute_candidates = ["example/python/attr/pkg"],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_attr_precedence_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = [],
        deps = [],
        attribute_candidates = ["example/python/attr/pkg"],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_fallback_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_no_match_fallback_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "example/python/no_match/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_include_disabled_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        explicit_identifier = "example/python/explicit/pkg",
        imports = ["example/python/imports/pkg"],
        deps = [":deps_wrapper"],
        attribute_candidates = ["example/python/attr/pkg"],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = False,
        tags = tags,
    )

def selector_override_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        explicit_identifier = "example/python/not_used/pkg",
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "example/python/no_match/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        module_label_override = "custom_override",
        tags = tags,
    )

def _has_fragment(items, fragment):
    for item in items:
        if fragment in item:
            return True
    return False

def _assert_selected(env, target, expected_fragment):
    files = [f.basename for f in target[DefaultInfo].files.to_list()]
    asserts.equals(env, 1, len(files))
    asserts.true(
        env,
        _has_fragment(files, expected_fragment),
        "expected selected payload fragment '%s' in files %s" % (expected_fragment, files),
    )

def _selector_explicit_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_python_explicit_pkg")
    return analysistest.end(env)

def _selector_imports_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_python_imports_pkg")
    return analysistest.end(env)

def _selector_deps_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_python_deps_pkg")
    return analysistest.end(env)

def _selector_attr_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_python_attr_pkg")
    return analysistest.end(env)

def _selector_fallback_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_python_fallback_pkg")
    return analysistest.end(env)

def _selector_no_match_fallback_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "full_payload")
    return analysistest.end(env)

def _selector_include_disabled_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "full_payload")
    return analysistest.end(env)

def _selector_override_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_custom_override")
    return analysistest.end(env)

selector_explicit_precedence_test = analysistest.make(
    _selector_explicit_precedence_test_impl,
)
selector_imports_precedence_test = analysistest.make(
    _selector_imports_precedence_test_impl,
)
selector_deps_precedence_test = analysistest.make(
    _selector_deps_precedence_test_impl,
)
selector_attr_precedence_test = analysistest.make(
    _selector_attr_precedence_test_impl,
)
selector_fallback_test = analysistest.make(
    _selector_fallback_test_impl,
)
selector_no_match_fallback_test = analysistest.make(
    _selector_no_match_fallback_test_impl,
)
selector_include_disabled_test = analysistest.make(
    _selector_include_disabled_test_impl,
)
selector_override_test = analysistest.make(
    _selector_override_test_impl,
)
