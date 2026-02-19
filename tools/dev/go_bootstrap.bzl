"""Dev-only bootstrap extension for local Go companion module wiring.

Maintainers:
- This extension is for root-workspace development only.
- It must be used with `dev_dependency = True`.
- The root module must not declare a `bazel_dep` edge to the Go companion;
  this extension provides a local repository instead to avoid core->go->core
  cycles while keeping load paths stable.
"""

load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

def _contains_parent_segment(path):
    """Return True when path includes a `..` segment."""
    for seg in path.replace("\\", "/").split("/"):
        if seg == "..":
            return True
    return False

# Public alias for unit tests.
contains_parent_segment_for_tests = _contains_parent_segment

def _go_bootstrap_extension_impl(module_ctx):
    """Create local companion-module repositories declared by root dev config."""
    for mod in module_ctx.modules:
        for call in mod.tags.local_go_companion:
            path = call.path
            if not path:
                fail("go_bootstrap: local_go_companion.path must be non-empty")
            if path.startswith("/") or path.startswith("\\"):
                fail("go_bootstrap: local_go_companion.path must be relative, got '%s'" % path)
            if len(path) >= 2 and path[1] == ":":
                fail("go_bootstrap: local_go_companion.path must not include drive prefix, got '%s'" % path)
            if _contains_parent_segment(path):
                fail("go_bootstrap: local_go_companion.path must not include '..' traversal segments, got '%s'" % path)
            normalized_path = path.replace("\\", "/").strip("/")
            module_bazel = module_ctx.path(Label("//%s:MODULE.bazel" % normalized_path))
            if not module_bazel.exists:
                fail("go_bootstrap: expected MODULE.bazel under local_go_companion.path: '%s'" % path)
            local_repository(
                name = call.name,
                path = path,
            )

go_bootstrap_extension = module_extension(
    implementation = _go_bootstrap_extension_impl,
    doc = "Dev-only extension exposing local Go companion repo via local_go_companion tags.",
    tag_classes = {
        "local_go_companion": tag_class(attrs = {
            "name": attr.string(mandatory = True),
            "path": attr.string(mandatory = True),
        }),
    },
)
