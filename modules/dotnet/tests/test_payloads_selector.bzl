"""Analysis tests for topt_dotnet_payloads_selector selection behavior."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@datadog-rules-test-optimization-dotnet//:topt_dotnet_infer.bzl", "topt_dotnet_payloads_selector")

_COMMON_MODULE_GROUPS = [
    ":module_company_product_explicit_tests",
    ":module_company_product_attr_tests",
    ":module_company_product_deps_tests",
    ":module_company_product_fallback_tests",
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

def _dotnet_source_impl(_ctx):
    return []

_dotnet_source = rule(
    implementation = _dotnet_source_impl,
    attrs = {
        "root_namespace": attr.string(),
        "assembly_name": attr.string(),
        "project_name": attr.string(),
        "test_class": attr.string(),
        "deps": attr.label_list(),
    },
)

def selector_payload_fixture_targets():
    _payload_marker(
        name = "full_payload",
        marker = "full",
    )
    _payload_marker(
        name = "module_company_product_explicit_tests",
        marker = "module:explicit",
    )
    _payload_marker(
        name = "module_company_product_attr_tests",
        marker = "module:attrs",
    )
    _payload_marker(
        name = "module_company_product_deps_tests",
        marker = "module:deps",
    )
    _payload_marker(
        name = "module_company_product_fallback_tests",
        marker = "module:fallback",
    )
    _payload_marker(
        name = "module_custom_override",
        marker = "module:override",
    )
    _dotnet_source(
        name = "deps_leaf",
        root_namespace = "Company.Product.Deps.Tests",
    )
    _dotnet_source(
        name = "deps_wrapper",
        deps = [":deps_leaf"],
    )

def selector_explicit_precedence_target(name, tags = None):
    topt_dotnet_payloads_selector(
        name = name,
        explicit_identifier = "Company.Product.Explicit.Tests",
        attribute_candidates = ["Company.Product.Attr.Tests"],
        deps = [":deps_wrapper"],
        fallback_identifier = "Company.Product.Fallback.Tests",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_attr_precedence_target(name, tags = None):
    topt_dotnet_payloads_selector(
        name = name,
        attribute_candidates = [
            "Company.Product.Attr.Tests",
            "Company.Product.Secondary.Tests",
        ],
        deps = [":deps_wrapper"],
        fallback_identifier = "Company.Product.Fallback.Tests",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_deps_precedence_target(name, tags = None):
    topt_dotnet_payloads_selector(
        name = name,
        attribute_candidates = [],
        deps = [":deps_wrapper"],
        fallback_identifier = "Company.Product.Fallback.Tests",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_fallback_target(name, tags = None):
    topt_dotnet_payloads_selector(
        name = name,
        attribute_candidates = [],
        deps = [],
        fallback_identifier = "Company.Product.Fallback.Tests",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_no_match_fallback_target(name, tags = None):
    topt_dotnet_payloads_selector(
        name = name,
        attribute_candidates = [],
        deps = [],
        fallback_identifier = "Company.Product.NoMatch.Tests",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_include_disabled_target(name, tags = None):
    topt_dotnet_payloads_selector(
        name = name,
        explicit_identifier = "Company.Product.Explicit.Tests",
        attribute_candidates = ["Company.Product.Attr.Tests"],
        deps = [":deps_wrapper"],
        fallback_identifier = "Company.Product.Fallback.Tests",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = False,
        tags = tags,
    )

def selector_override_target(name, tags = None):
    topt_dotnet_payloads_selector(
        name = name,
        explicit_identifier = "Company.Product.NotUsed.Tests",
        attribute_candidates = [],
        deps = [],
        fallback_identifier = "Company.Product.NoMatch.Tests",
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
    _assert_selected(env, target, "module_company_product_explicit_tests")
    return analysistest.end(env)

def _selector_attr_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_company_product_attr_tests")
    return analysistest.end(env)

def _selector_deps_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_company_product_deps_tests")
    return analysistest.end(env)

def _selector_fallback_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_company_product_fallback_tests")
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
