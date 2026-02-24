"""Analysis tests for topt_nodejs_payloads_selector selection behavior."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@datadog-rules-test-optimization-nodejs//:topt_nodejs_infer.bzl", "topt_nodejs_payloads_selector")

_COMMON_MODULE_GROUPS = [
    ":module_packages_nodejs_explicit_pkg",
    ":module_packages_nodejs_attr_pkg",
    ":module_packages_nodejs_deps_pkg",
    ":module_packages_nodejs_fallback_pkg",
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

def _nodejs_source_impl(_ctx):
    return []

_nodejs_source = rule(
    implementation = _nodejs_source_impl,
    attrs = {
        "package_name": attr.string(),
        "module_name": attr.string(),
        "npm_package": attr.string(),
        "entry_point": attr.string(),
        "deps": attr.label_list(),
    },
)

def selector_payload_fixture_targets():
    _payload_marker(
        name = "full_payload",
        marker = "full",
    )
    _payload_marker(
        name = "module_packages_nodejs_explicit_pkg",
        marker = "module:explicit",
    )
    _payload_marker(
        name = "module_packages_nodejs_attr_pkg",
        marker = "module:attrs",
    )
    _payload_marker(
        name = "module_packages_nodejs_deps_pkg",
        marker = "module:deps",
    )
    _payload_marker(
        name = "module_packages_nodejs_fallback_pkg",
        marker = "module:fallback",
    )
    _payload_marker(
        name = "module_custom_override",
        marker = "module:override",
    )
    _nodejs_source(
        name = "deps_leaf",
        package_name = "packages/nodejs/deps/pkg",
    )
    _nodejs_source(
        name = "deps_wrapper",
        deps = [":deps_leaf"],
    )

def selector_explicit_precedence_target(name, tags = None):
    topt_nodejs_payloads_selector(
        name = name,
        explicit_identifier = "packages/nodejs/explicit/pkg",
        attribute_candidates = ["packages/nodejs/attr/pkg"],
        deps = [":deps_wrapper"],
        fallback_identifier = "packages/nodejs/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_attr_precedence_target(name, tags = None):
    topt_nodejs_payloads_selector(
        name = name,
        attribute_candidates = [
            "packages/nodejs/attr/pkg",
            "packages/nodejs/secondary/pkg",
        ],
        deps = [":deps_wrapper"],
        fallback_identifier = "packages/nodejs/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_deps_precedence_target(name, tags = None):
    topt_nodejs_payloads_selector(
        name = name,
        attribute_candidates = [],
        deps = [":deps_wrapper"],
        fallback_identifier = "packages/nodejs/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_fallback_target(name, tags = None):
    topt_nodejs_payloads_selector(
        name = name,
        attribute_candidates = [],
        deps = [],
        fallback_identifier = "packages/nodejs/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_no_match_fallback_target(name, tags = None):
    topt_nodejs_payloads_selector(
        name = name,
        attribute_candidates = [],
        deps = [],
        fallback_identifier = "packages/nodejs/no_match/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_include_disabled_target(name, tags = None):
    topt_nodejs_payloads_selector(
        name = name,
        explicit_identifier = "packages/nodejs/explicit/pkg",
        attribute_candidates = ["packages/nodejs/attr/pkg"],
        deps = [":deps_wrapper"],
        fallback_identifier = "packages/nodejs/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = False,
        tags = tags,
    )

def selector_override_target(name, tags = None):
    topt_nodejs_payloads_selector(
        name = name,
        explicit_identifier = "packages/nodejs/not_used/pkg",
        attribute_candidates = [],
        deps = [],
        fallback_identifier = "packages/nodejs/no_match/pkg",
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
    _assert_selected(env, target, "module_packages_nodejs_explicit_pkg")
    return analysistest.end(env)

def _selector_attr_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_packages_nodejs_attr_pkg")
    return analysistest.end(env)

def _selector_deps_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_packages_nodejs_deps_pkg")
    return analysistest.end(env)

def _selector_fallback_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_packages_nodejs_fallback_pkg")
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
selector_attr_precedence_test = analysistest.make(
    _selector_attr_precedence_test_impl,
)
selector_deps_precedence_test = analysistest.make(
    _selector_deps_precedence_test_impl,
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
