# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Build target for warming the Test Optimization Go standard library."""

load("@rules_go//go/private:providers.bzl", "GoStdLib")
load("@rules_go//go/private/rules:transition.bzl", "go_transition")

_ORCHESTRION_ENABLED_SETTING = "@rules_go//go/private/orchestrion:enabled"
_ORCHESTRION_MODE_SETTING = "@rules_go//go/private/orchestrion:mode"
_ORCHESTRION_MODE_TEST_OPTIMIZATION = "test_optimization"

def _stdlib_warmup_transition_impl(_settings, _attr):
    return {
        _ORCHESTRION_ENABLED_SETTING: True,
        _ORCHESTRION_MODE_SETTING: _ORCHESTRION_MODE_TEST_OPTIMIZATION,
    }

stdlib_warmup_transition_impl_for_tests = _stdlib_warmup_transition_impl

def _with_manual_tag(tags):
    tags = list(tags or [])
    if "manual" not in tags:
        tags.append("manual")
    return tags

stdlib_warmup_tags_for_tests = _with_manual_tag

_stdlib_warmup_transition = transition(
    implementation = _stdlib_warmup_transition_impl,
    inputs = [],
    outputs = [
        _ORCHESTRION_ENABLED_SETTING,
        _ORCHESTRION_MODE_SETTING,
    ],
)

def _first_target(dep):
    if type(dep) == "list":
        if not dep:
            fail("dd_topt_go_stdlib_warmup: stdlib transition produced no targets")
        return dep[0]
    return dep

def _go_transition_stdlib_warmup_impl(ctx):
    stdlib = ctx.attr._stdlib[GoStdLib]
    return [DefaultInfo(files = depset(transitive = [stdlib.libs, stdlib.cache_dir]))]

_go_transition_stdlib_warmup = rule(
    implementation = _go_transition_stdlib_warmup_impl,
    attrs = {
        "_stdlib": attr.label(
            default = "@rules_go//:stdlib",
            providers = [GoStdLib],
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    cfg = go_transition,
)

def _dd_topt_go_stdlib_warmup_impl(ctx):
    return [DefaultInfo(files = _first_target(ctx.attr.actual)[DefaultInfo].files)]

_dd_topt_go_stdlib_warmup = rule(
    implementation = _dd_topt_go_stdlib_warmup_impl,
    attrs = {
        "actual": attr.label(
            mandatory = True,
            cfg = _stdlib_warmup_transition,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Builds the Orchestrion-instrumented Go standard library used by Test Optimization.",
)

def dd_topt_go_stdlib_warmup(name, **kwargs):
    """Creates a warmup target with the same Go transitions as a real go_test."""
    transitioned_name = name + "__go_transition"
    _go_transition_stdlib_warmup(
        name = transitioned_name,
        tags = ["manual"],
        visibility = ["//visibility:private"],
    )
    kwargs["tags"] = _with_manual_tag(kwargs.get("tags"))
    _dd_topt_go_stdlib_warmup(
        name = name,
        actual = ":" + transitioned_name,
        **kwargs
    )
