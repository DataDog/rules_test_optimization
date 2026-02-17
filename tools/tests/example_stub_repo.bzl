"""Dev-only module extension providing a local example data repository.

This exists so `bazel build //examples/...` can analyze from this repository's
root workspace without requiring network fetches or external env vars.
"""

def _render_stub_build(settings, manifest, known_tests, test_management, context):
    """Render BUILD content for stub repo targets."""
    return (
        "filegroup(\n" +
        '    name = "test_optimization_files",\n' +
        ("    srcs = %s,\n" % repr([settings, manifest, known_tests, test_management])) +
        '    visibility = ["//visibility:public"],\n' +
        ")\n\n" +
        "filegroup(\n" +
        '    name = "test_optimization_context",\n' +
        ("    srcs = %s,\n" % repr([context])) +
        '    visibility = ["//visibility:public"],\n' +
        ")\n\n" +
        ('exports_files(["export.bzl", %s], visibility = ["//visibility:public"])\n' % repr(manifest))
    )

# Public alias for tests.
render_stub_build_for_tests = _render_stub_build

def _example_stub_repo_impl(ctx):
    manifest = ".testoptimization/manifest.txt"
    settings = ".testoptimization/cache/http/settings.json"
    known_tests = ".testoptimization/cache/http/known_tests.json"
    test_management = ".testoptimization/cache/http/test_management.json"
    context = ".testoptimization/context.json"

    ctx.file(manifest, manifest + "\n")
    ctx.file(settings, "{}\n")
    ctx.file(known_tests, '{"data": {"attributes": {"modules": {}}}}\n')
    ctx.file(test_management, '{"data": {"attributes": {"modules": {}}}}\n')
    ctx.file(context, "{}\n")

    service_keys = list(ctx.attr.service_keys or [])
    if not service_keys:
        service_keys = ["go_service", "ruby_service"]
    mapping_lines = []
    for key in service_keys:
        mapping_lines.append('    "%s": topt_data,\n' % key)

    export = (
        "topt_data = {\n" +
        '    "repo_name": "%s",\n' % ctx.attr.repo_alias +
        '    "manifest_path": ".testoptimization/manifest.txt",\n' +
        '    "labels": [],\n' +
        '    "set": {},\n' +
        '    "runtimes": {\n' +
        '        "go": {\n' +
        '            "module_path": "example.com/stub",\n' +
        '            "sanitized_module_path": "example_com_stub",\n' +
        '            "module_included": False,\n' +
        '        },\n' +
        '    },\n' +
        "}\n\n" +
        "topt_data_by_service = {\n" +
        "".join(mapping_lines) +
        "}\n"
    )
    ctx.file("export.bzl", export)

    build = _render_stub_build(
        settings,
        manifest,
        known_tests,
        test_management,
        context,
    )
    ctx.file("BUILD", build)

example_stub_repo = repository_rule(
    implementation = _example_stub_repo_impl,
    attrs = {
        "repo_alias": attr.string(mandatory = True),
        "service_keys": attr.string_list(),
    },
)

def _example_stub_repo_extension_impl(module_ctx):
    for mod in module_ctx.modules:
        for call in mod.tags.example_stub_repo:
            example_stub_repo(
                name = call.name,
                repo_alias = call.name,
                service_keys = list(call.service_keys or []),
            )

example_stub_repo_extension = module_extension(
    implementation = _example_stub_repo_extension_impl,
    tag_classes = {
        "example_stub_repo": tag_class(attrs = {
            "name": attr.string(mandatory = True),
            "service_keys": attr.string_list(),
        }),
    },
)
