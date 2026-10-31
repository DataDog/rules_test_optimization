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

More sdk tags, each with the sdk_version value that selects it, add SDK
variants for Go targets that a transition below an instrumented test moves to
another SDK, such as go_cross_binary(sdk_version = "1.26.3fips"):

    topt_go_ddtest.sdk(
        experiments = ["boringcrypto"],
        go_version = "1.26.3",
        sdk_version = "1.26.3fips",
    )

The Go companion module registers the toolchains, so the root module
registers none.
"""

load(
    ":topt_go_ddtest_repository.bzl",
    "go_version_from_go_mod",
    "topt_go_ddtest_repositories",
    "topt_go_ddtest_unconfigured_repositories",
)

def _tag_config(tag, read_go_mod):
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

def sdk_config(tags, read_go_mod):
    """The configuration of the root module's sdk tags, or None without one.

    The tag without sdk_version configures the default SDK; the others become
    sdk_variants. read_go_mod returns the content of a go.mod label.
    """
    if not tags:
        return None
    defaults = [tag for tag in tags if not tag.sdk_version]
    if len(defaults) != 1:
        fail("topt_go_ddtest: set one sdk tag without sdk_version, for the default SDK, in the root module; found %d" % len(defaults))
    config = _tag_config(defaults[0], read_go_mod)
    variants = []
    for tag in tags:
        if tag.sdk_version:
            variant = _tag_config(tag, read_go_mod)
            variants.append({
                "sdk_version": tag.sdk_version,
                "go_version": variant.go_version,
                "base_sdk_roots": variant.base_sdk_roots,
                "exec_platforms": variant.exec_platforms,
                "experiments": variant.experiments,
                "panic_hook": variant.panic_hook,
            })
    return struct(
        go_version = config.go_version,
        base_sdk_roots = config.base_sdk_roots,
        exec_platforms = config.exec_platforms,
        experiments = config.experiments,
        panic_hook = config.panic_hook,
        sdk_variants = variants,
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
        sdk_variants = config.sdk_variants,
    )

topt_go_ddtest = module_extension(
    implementation = _topt_go_ddtest_impl,
    tag_classes = {
        "sdk": tag_class(
            attrs = {
                "sdk_version": attr.string(doc = "Value of @io_bazel_rules_go//go/toolchain:sdk_version that selects this SDK, such as 1.26.3fips, for a variant. The tag without it configures the default SDK, which serves an unset value and the prefixes of its Go version."),
                "go_mod": attr.label(doc = "go.mod whose toolchain directive, then go directive, gives the Go version, as rules_go's go_sdk.from_file reads it."),
                "go_version": attr.string(doc = "Go version of the SDK: the official SDK that exec platforms without base_sdk_roots download, and for the default SDK the version whose sdk_version requests it serves; overrides go_mod."),
                "base_sdk_roots": attr.string_keyed_label_dict(doc = "Exec platform, such as linux_amd64, to a file at the root of the Go SDK to instrument there, such as @go_sdk//:ROOT; other exec platforms download the official SDK."),
                "exec_platforms": attr.string_list(doc = "Exec platforms to instrument; all of ddtest's by default. Bazel fetches only the SDKs of selected toolchains."),
                "experiments": attr.string_list(doc = "GOEXPERIMENT values of the base SDKs."),
                "panic_hook": attr.bool(doc = "Record an unrecovered panic as the running test's failure before the process ends."),
            },
            doc = "A Go SDK that instrumented tests build with: the default one, or a variant with sdk_version.",
        ),
    },
)
