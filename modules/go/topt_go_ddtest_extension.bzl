# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Bzlmod extension for the ddtest instrumentation of Go tests.

The root module configures the Go SDK to instrument:

    topt_go_ddtest = use_extension(
        "@datadog-rules-test-optimization-go//:topt_go_ddtest_extension.bzl",
        "topt_go_ddtest",
    )
    topt_go_ddtest.sdk(go_mod = "//:go.mod")

The Go companion module registers the toolchains, so the root module
registers none.
"""

load(
    ":topt_go_ddtest_repository.bzl",
    "go_version_from_go_mod",
    "topt_go_ddtest_repositories",
    "topt_go_ddtest_unconfigured_repositories",
)

def sdk_config(tags, read_go_mod):
    """The configuration of the root module's sdk tags, or None without one.

    read_go_mod returns the content of a go.mod label.
    """
    if not tags:
        return None
    if len(tags) > 1:
        fail("topt_go_ddtest: set one sdk tag in the root module")
    tag = tags[0]
    go_version = tag.go_version
    if not go_version and tag.go_mod:
        go_version = go_version_from_go_mod(read_go_mod(tag.go_mod))
        if not go_version:
            fail("topt_go_ddtest: %s has neither a toolchain nor a go directive" % tag.go_mod)
    return struct(
        go_version = go_version,
        base_sdk_roots = dict(tag.base_sdk_roots),
        exec_platforms = list(tag.exec_platforms) or None,
        experiments = list(tag.experiments),
        panic_hook = tag.panic_hook,
    )

def _topt_go_ddtest_impl(module_ctx):
    tags = []
    for mod in module_ctx.modules:
        if mod.is_root:
            tags.extend(mod.tags.sdk)
    config = sdk_config(tags, module_ctx.read)
    if not config:
        topt_go_ddtest_unconfigured_repositories()
        return
    topt_go_ddtest_repositories(
        go_version = config.go_version,
        base_sdk_roots = config.base_sdk_roots,
        exec_platforms = config.exec_platforms,
        experiments = config.experiments,
        panic_hook = config.panic_hook,
    )

topt_go_ddtest = module_extension(
    implementation = _topt_go_ddtest_impl,
    tag_classes = {
        "sdk": tag_class(
            attrs = {
                "go_mod": attr.label(doc = "go.mod whose toolchain directive, then go directive, gives the Go version, as rules_go's go_sdk.from_file reads it."),
                "go_version": attr.string(doc = "Go version of the official SDK to instrument; overrides go_mod."),
                "base_sdk_roots": attr.string_keyed_label_dict(doc = "Exec platform, such as linux_amd64, to a file at the root of the Go SDK to instrument there, such as @go_sdk//:ROOT; other exec platforms download the official SDK."),
                "exec_platforms": attr.string_list(doc = "Exec platforms to instrument; all of ddtest's by default. Bazel fetches only the SDKs of selected toolchains."),
                "experiments": attr.string_list(doc = "GOEXPERIMENT values of the base SDKs."),
                "panic_hook": attr.bool(doc = "Record an unrecovered panic as the running test's failure before the process ends."),
            },
            doc = "The Go SDK that instrumented tests build with.",
        ),
    },
)
