"""Dev-only module extension providing a local example data repository.

This exists so `bazel build //examples/...` can analyze from this repository's
root workspace without requiring network fetches or external env vars.
"""

def _bzl_string_literal(value):
    """Return a safely escaped double-quoted Starlark string literal."""
    s = str(value)
    s = s.replace("\\", "\\\\")
    s = s.replace("\"", "\\\"")
    s = s.replace("\n", "\\n")
    s = s.replace("\r", "\\r")
    return "\"" + s + "\""

def _render_stub_build(settings, manifest, known_tests, test_management, context, telemetry_facts, service_keys = None):
    """Render BUILD content for stub repo targets."""

    def _append_filegroups(name_suffix, srcs):
        lines.append(
            "filegroup(\n" +
            ('    name = "test_optimization_files%s",\n' % name_suffix) +
            ("    srcs = %s,\n" % repr(srcs)) +
            '    visibility = ["//visibility:public"],\n' +
            ")\n\n",
        )
        lines.append(
            "filegroup(\n" +
            ('    name = "test_optimization_context%s",\n' % name_suffix) +
            ("    srcs = %s,\n" % repr([context, telemetry_facts])) +
            '    visibility = ["//visibility:public"],\n' +
            ")\n\n",
        )

    files_srcs = [settings, manifest, known_tests, test_management]
    lines = []
    _append_filegroups("", files_srcs)
    for key in list(service_keys or []):
        _append_filegroups("_%s" % key, files_srcs)
    lines.append('exports_files(["export.bzl", %s], visibility = ["//visibility:public"])\n' % repr(manifest))
    return "".join(lines)

# Public alias for tests.
render_stub_build_for_tests = _render_stub_build
bzl_string_literal_for_tests = _bzl_string_literal

def _example_stub_repo_impl(ctx):
    """Implement example stub repo impl behavior."""
    manifest = ".testoptimization/manifest.txt"
    settings = ".testoptimization/cache/http/settings.json"
    known_tests = ".testoptimization/cache/http/known_tests.json"
    test_management = ".testoptimization/cache/http/test_management.json"
    context = ".testoptimization/context.json"
    telemetry_facts = ".testoptimization/telemetry_facts.json"

    ctx.file(manifest, manifest + "\n")
    ctx.file(settings, "{}\n")
    ctx.file(known_tests, '{"data": {"attributes": {"tests": {}}}}\n')
    ctx.file(test_management, '{"data": {"attributes": {"modules": {}}}}\n')
    ctx.file(context, "{}\n")
    ctx.file(telemetry_facts, '{"schema_version": 1, "service_name": "stub", "counts": [], "distributions": []}\n')

    service_keys = list(ctx.attr.service_keys or [])
    if not service_keys:
        service_keys = ["go_service", "ruby_service"]
    mapping_lines = []
    for key in service_keys:
        mapping_lines.append("    %s: topt_data,\n" % _bzl_string_literal(key))

    export = (
        "topt_data = {\n" +
        "    \"repo_name\": %s,\n" % _bzl_string_literal(ctx.attr.repo_alias) +
        '    "manifest_path": ".testoptimization/manifest.txt",\n' +
        '    "labels": [],\n' +
        '    "set": {},\n' +
        '    "runtimes": {\n' +
        '        "go": {\n' +
        '            "module_path": "example.com/stub",\n' +
        '            "sanitized_module_path": "example_com_stub",\n' +
        '            "module_included": False,\n' +
        "        },\n" +
        '        "python": {\n' +
        '            "module_path": "example.python.stub",\n' +
        '            "sanitized_module_path": "example_python_stub",\n' +
        '            "module_included": False,\n' +
        "        },\n" +
        '        "java": {\n' +
        '            "module_path": "com.example.stub",\n' +
        '            "sanitized_module_path": "com_example_stub",\n' +
        '            "module_included": False,\n' +
        "        },\n" +
        '        "nodejs": {\n' +
        '            "module_path": "packages/stub",\n' +
        '            "sanitized_module_path": "packages_stub",\n' +
        '            "module_included": False,\n' +
        "        },\n" +
        '        "dotnet": {\n' +
        '            "module_path": "Company.Product.Stub",\n' +
        '            "sanitized_module_path": "company_product_stub",\n' +
        '            "module_included": False,\n' +
        "        },\n" +
        '        "ruby": {\n' +
        '            "module_path": "apps/stub",\n' +
        '            "sanitized_module_path": "apps_stub",\n' +
        '            "module_included": False,\n' +
        "        },\n" +
        "    },\n" +
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
        telemetry_facts,
        service_keys = service_keys,
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
    """Implement example stub repo extension impl behavior."""
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
