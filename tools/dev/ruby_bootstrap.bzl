"""Dev-only bootstrap extension for local Ruby companion module wiring."""

load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

def _contains_parent_segment(path):
    for seg in path.replace("\\", "/").split("/"):
        if seg == "..":
            return True
    return False

def _ruby_bootstrap_extension_impl(module_ctx):
    for mod in module_ctx.modules:
        for call in mod.tags.local_ruby_companion:
            path = call.path
            if not path:
                fail("ruby_bootstrap: local_ruby_companion.path must be non-empty")
            if path.startswith("/") or path.startswith("\\"):
                fail("ruby_bootstrap: local_ruby_companion.path must be relative, got '%s'" % path)
            if len(path) >= 2 and path[1] == ":":
                fail("ruby_bootstrap: local_ruby_companion.path must not include drive prefix, got '%s'" % path)
            if _contains_parent_segment(path):
                fail("ruby_bootstrap: local_ruby_companion.path must not include '..' traversal segments, got '%s'" % path)
            normalized_path = path.replace("\\", "/").strip("/")

            module_bazel = module_ctx.path(Label("//%s:MODULE.bazel" % normalized_path))
            if not module_bazel.exists:
                fail("ruby_bootstrap: expected MODULE.bazel under local_ruby_companion.path: '%s'" % path)
            local_repository(
                name = call.name,
                path = path,
            )

ruby_bootstrap_extension = module_extension(
    implementation = _ruby_bootstrap_extension_impl,
    doc = "Dev-only extension exposing local Ruby companion repo via local_ruby_companion tags.",
    tag_classes = {
        "local_ruby_companion": tag_class(attrs = {
            "name": attr.string(mandatory = True),
            "path": attr.string(mandatory = True),
        }),
    },
)
