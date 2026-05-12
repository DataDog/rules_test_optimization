# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Dev-only bootstrap extension for local Java companion module wiring."""

load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

def _contains_parent_segment(path):
    for seg in path.replace("\\", "/").split("/"):
        if seg == "..":
            return True
    return False

def _java_bootstrap_extension_impl(module_ctx):
    for mod in module_ctx.modules:
        for call in mod.tags.local_java_companion:
            path = call.path
            if not path:
                fail("java_bootstrap: local_java_companion.path must be non-empty")
            if path.startswith("/") or path.startswith("\\"):
                fail("java_bootstrap: local_java_companion.path must be relative, got '%s'" % path)
            if len(path) >= 2 and path[1] == ":":
                fail("java_bootstrap: local_java_companion.path must not include drive prefix, got '%s'" % path)
            if _contains_parent_segment(path):
                fail("java_bootstrap: local_java_companion.path must not include '..' traversal segments, got '%s'" % path)
            normalized_path = path.replace("\\", "/").strip("/")

            module_bazel = module_ctx.path(Label("//%s:MODULE.bazel" % normalized_path))
            if not module_bazel.exists:
                fail("java_bootstrap: expected MODULE.bazel under local_java_companion.path: '%s'" % path)
            local_repository(
                name = call.name,
                path = path,
            )

java_bootstrap_extension = module_extension(
    implementation = _java_bootstrap_extension_impl,
    doc = "Dev-only extension exposing local Java companion repo via local_java_companion tags.",
    tag_classes = {
        "local_java_companion": tag_class(attrs = {
            "name": attr.string(mandatory = True),
            "path": attr.string(mandatory = True),
        }),
    },
)
