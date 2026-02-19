"""Analysis tests for topt_go_payloads_selector selection behavior."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//:topt_go_infer.bzl", "topt_go_payloads_selector")

_COMMON_MODULE_GROUPS = [
    ":module_example_com_explicit_pkg",
    ":module_example_com_embed_pkg",
    ":module_example_com_deps_pkg",
    ":module_example_com_fallback_pkg",
    ":module_custom_override",
]

def _payload_marker_impl(ctx):
    """Create a single marker file so selector choice is easy to assert."""
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

def _embed_source_impl(_ctx):
    return []

_embed_source = rule(
    implementation = _embed_source_impl,
    attrs = {
        # Keep attribute names aligned with what _importpath_aspect inspects.
        "importpath": attr.string(),
        "embed": attr.label_list(),
        "deps": attr.label_list(),
    },
)

def selector_payload_fixture_targets():
    """Shared marker and embed fixtures used by selector tests."""
    _payload_marker(
        name = "full_payload",
        marker = "full",
    )
    _payload_marker(
        name = "module_example_com_explicit_pkg",
        marker = "module:explicit",
    )
    _payload_marker(
        name = "module_example_com_embed_pkg",
        marker = "module:embed",
    )
    _payload_marker(
        name = "module_example_com_deps_pkg",
        marker = "module:deps",
    )
    _payload_marker(
        name = "module_example_com_fallback_pkg",
        marker = "module:fallback",
    )
    _payload_marker(
        name = "module_custom_override",
        marker = "module:override",
    )
    _embed_source(
        name = "embed_leaf",
        importpath = "example.com/embed/pkg",
    )
    _embed_source(
        name = "embed_wrapper",
        embed = [":embed_leaf"],
    )
    _embed_source(
        name = "deps_leaf",
        importpath = "example.com/deps/pkg",
    )
    _embed_source(
        name = "deps_wrapper",
        deps = [":deps_leaf"],
    )

def selector_explicit_precedence_target(name, tags = None):
    """explicit_importpath wins over embed-derived and fallback importpaths."""
    topt_go_payloads_selector(
        name = name,
        explicit_importpath = "example.com/explicit/pkg",
        embeds = [":embed_wrapper"],
        fallback_importpath = "example.com/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_embed_precedence_target(name, tags = None):
    """embed-derived importpath wins when explicit_importpath is unset."""
    topt_go_payloads_selector(
        name = name,
        embeds = [":embed_wrapper"],
        fallback_importpath = "example.com/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_deps_precedence_target(name, tags = None):
    """deps-traversal importpath is used when embed chain has deps-only path."""
    topt_go_payloads_selector(
        name = name,
        embeds = [":deps_wrapper"],
        fallback_importpath = "example.com/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_fallback_target(name, tags = None):
    """fallback_importpath is used when explicit and embed are unavailable."""
    topt_go_payloads_selector(
        name = name,
        embeds = [],
        fallback_importpath = "example.com/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_no_match_fallback_target(name, tags = None):
    """Selector falls back to full_files when no module target matches."""
    topt_go_payloads_selector(
        name = name,
        embeds = [],
        fallback_importpath = "example.com/no-match/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_include_disabled_target(name, tags = None):
    """Selector keeps full_files when include_per_module is disabled."""
    topt_go_payloads_selector(
        name = name,
        explicit_importpath = "example.com/explicit/pkg",
        embeds = [":embed_wrapper"],
        fallback_importpath = "example.com/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = False,
        tags = tags,
    )

def selector_override_target(name, tags = None):
    """module_label_override selects module_<override> when provided."""
    topt_go_payloads_selector(
        name = name,
        explicit_importpath = "example.com/not-used/pkg",
        embeds = [],
        fallback_importpath = "example.com/no-match/pkg",
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
    _assert_selected(env, target, "module_example_com_explicit_pkg")
    return analysistest.end(env)

def _selector_embed_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_com_embed_pkg")
    return analysistest.end(env)

def _selector_deps_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_com_deps_pkg")
    return analysistest.end(env)

def _selector_fallback_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_com_fallback_pkg")
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
selector_embed_precedence_test = analysistest.make(
    _selector_embed_precedence_test_impl,
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
