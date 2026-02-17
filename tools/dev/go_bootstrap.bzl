"""Dev-only bootstrap extension for local Go companion module wiring.

Maintainers:
- This extension is for root-workspace development only.
- It must be used with `dev_dependency = True`.
- The root module must not declare a `bazel_dep` edge to the Go companion;
  this extension provides a local repository instead to avoid core->go->core
  cycles while keeping load paths stable.
"""

load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

def _go_bootstrap_extension_impl(module_ctx):
    """Create local companion-module repositories declared by root dev config."""
    for mod in module_ctx.modules:
        for call in mod.tags.local_go_companion:
            local_repository(
                name = call.name,
                path = call.path,
            )

go_bootstrap_extension = module_extension(
    implementation = _go_bootstrap_extension_impl,
    tag_classes = {
        "local_go_companion": tag_class(attrs = {
            "name": attr.string(mandatory = True),
            "path": attr.string(mandatory = True),
        }),
    },
)
