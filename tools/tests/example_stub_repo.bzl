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

def _module_known_tests_path(out_dir, label):
    """Return the stub known-tests path used by module_<label> targets."""
    return "%s/module_%s/known_tests.json" % (out_dir, label)

def _module_test_management_path(out_dir, label):
    """Return the stub test-management path used by module_<label> targets."""
    return "%s/module_%s/test_management.json" % (out_dir, label)

def _render_stub_telemetry_facts(service_name):
    """Render telemetry_facts.json content for the stub repository."""
    return (
        '{"schema_version": 1, "service_name": ' +
        _bzl_string_literal(service_name) +
        ', "counts": [], "distributions": []}\n'
    )

def _render_stub_module_runfiles_bzl(repo_name, manifest_root):
    """Render the helper rule used by module_<label> targets in the stub repo.

    The stub keeps the same function signature as the real sync helper even
    though raw-file mode no longer needs `repo_name` or `manifest_root`.
    Keeping that signature aligned makes the stub a closer stand-in for the
    production repository rule.
    """
    return (
        "def _topt_module_files_impl(ctx):\n" +
        "    files = [ctx.file.settings, ctx.file.manifest]\n" +
        "    known_tests = getattr(ctx.file, \"known_tests\", None)\n" +
        "    if known_tests:\n" +
        "        files.append(known_tests)\n" +
        "    test_management = getattr(ctx.file, \"test_management\", None)\n" +
        "    if test_management:\n" +
        "        files.append(test_management)\n" +
        "    return DefaultInfo(files = depset(files), runfiles = ctx.runfiles(files = files))\n" +
        "\n" +
        "topt_module_files = rule(\n" +
        "    implementation = _topt_module_files_impl,\n" +
        "    attrs = {\n" +
        "        \"settings\": attr.label(allow_single_file = True, mandatory = True),\n" +
        "        \"manifest\": attr.label(allow_single_file = True, mandatory = True),\n" +
        "        \"known_tests\": attr.label(allow_single_file = True),\n" +
        "        \"test_management\": attr.label(allow_single_file = True),\n" +
        "    },\n" +
        ")\n"
    )

def _render_stub_export(
        repo_name,
        service_name,
        service_keys,
        labels,
        manifest_path,
        go_module_path,
        go_sanitized_module_path,
        go_module_included):
    """Render export.bzl content for the stub repository."""
    mapping_lines = []
    for key in service_keys:
        mapping_lines.append("    %s: topt_data,\n" % _bzl_string_literal(key))

    return (
        "topt_data = {\n" +
        "    \"repo_name\": %s,\n" % _bzl_string_literal(repo_name) +
        "    \"service_name\": %s,\n" % _bzl_string_literal(service_name) +
        "    \"manifest_path\": %s,\n" % _bzl_string_literal(manifest_path) +
        ("    \"labels\": %s,\n" % repr(labels)) +
        '    "set": {},\n' +
        '    "runtimes": {\n' +
        '        "go": {\n' +
        ("            \"module_path\": %s,\n" % _bzl_string_literal(go_module_path)) +
        ("            \"sanitized_module_path\": %s,\n" % _bzl_string_literal(go_sanitized_module_path)) +
        ("            \"module_included\": %s,\n" % ("True" if go_module_included else "False")) +
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

def _render_stub_build(
        settings,
        manifest,
        known_tests,
        test_management,
        context,
        telemetry_facts,
        service_keys = None,
        module_labels = None,
        manifest_root = ".testoptimization"):
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
    lines = ['load(":module_runfiles.bzl", "topt_module_files")\n\n']
    _append_filegroups("", files_srcs)
    for key in list(service_keys or []):
        _append_filegroups("_%s" % key, files_srcs)
    for label in list(module_labels or []):
        lines.append(
            "topt_module_files(\n" +
            ('    name = "module_%s",\n' % label) +
            ("    settings = %s,\n" % repr(settings)) +
            ("    manifest = %s,\n" % repr(manifest)) +
            ("    known_tests = %s,\n" % repr(_module_known_tests_path(manifest_root, label))) +
            ("    test_management = %s,\n" % repr(_module_test_management_path(manifest_root, label))) +
            '    visibility = ["//visibility:public"],\n' +
            ")\n\n",
        )
    lines.append('exports_files(["export.bzl", %s], visibility = ["//visibility:public"])\n' % repr(manifest))
    return "".join(lines)

# Public alias for tests.
render_stub_build_for_tests = _render_stub_build
bzl_string_literal_for_tests = _bzl_string_literal
render_stub_telemetry_facts_for_tests = _render_stub_telemetry_facts
render_stub_export_for_tests = _render_stub_export

def _example_stub_repo_impl(ctx):
    """Implement example stub repo impl behavior."""
    out_dir = ctx.attr.out_dir or ".testoptimization"
    exported_repo_name = ctx.attr.repo_alias or ctx.name
    manifest = "%s/manifest.txt" % out_dir
    settings = "%s/cache/http/settings.json" % out_dir
    known_tests = "%s/cache/http/known_tests.json" % out_dir
    test_management = "%s/cache/http/test_management.json" % out_dir
    context = "%s/context.json" % out_dir
    telemetry_facts = "%s/telemetry_facts.json" % out_dir

    ctx.file(manifest, manifest + "\n")
    ctx.file(settings, "{}\n")
    ctx.file(known_tests, '{"data": {"attributes": {"tests": {}}}}\n')
    ctx.file(test_management, '{"data": {"attributes": {"modules": {}}}}\n')
    ctx.file(context, "{}\n")
    ctx.file(telemetry_facts, _render_stub_telemetry_facts(ctx.attr.service_name))

    service_keys = list(ctx.attr.service_keys or [])
    if not service_keys:
        service_keys = ["go_service", "ruby_service"]
    module_labels = list(ctx.attr.labels or [])
    for label in module_labels:
        ctx.file(
            _module_known_tests_path(out_dir, label),
            '{"data": {"attributes": {"tests": {"module:%s": {}}}}}\n' % label,
        )
        ctx.file(
            _module_test_management_path(out_dir, label),
            '{"data": {"attributes": {"modules": {"%s": {}}}}}\n' % label,
        )

    export = _render_stub_export(
        # Module-extension repository rules receive canonical internal names
        # like `+extension+repo` at execution time. Export the user-visible
        # alias instead so consuming macros keep resolving `@test_optimization_data`
        # style labels the same way the real sync repository does.
        repo_name = exported_repo_name,
        service_name = ctx.attr.service_name,
        service_keys = service_keys,
        labels = module_labels,
        manifest_path = manifest,
        go_module_path = ctx.attr.go_module_path,
        go_sanitized_module_path = ctx.attr.go_sanitized_module_path,
        go_module_included = ctx.attr.go_module_included,
    )
    ctx.file("export.bzl", export)
    ctx.file("module_runfiles.bzl", _render_stub_module_runfiles_bzl(ctx.name, out_dir))

    build = _render_stub_build(
        settings,
        manifest,
        known_tests,
        test_management,
        context,
        telemetry_facts,
        service_keys = service_keys,
        module_labels = module_labels,
        manifest_root = out_dir,
    )
    ctx.file("BUILD", build)

example_stub_repo = repository_rule(
    implementation = _example_stub_repo_impl,
    attrs = {
        "go_module_included": attr.bool(default = False),
        "go_module_path": attr.string(default = "example.com/stub"),
        "go_sanitized_module_path": attr.string(default = "example_com_stub"),
        "labels": attr.string_list(),
        "out_dir": attr.string(default = ".testoptimization"),
        "repo_alias": attr.string(),
        "service_name": attr.string(default = "stub-service"),
        "service_keys": attr.string_list(),
    },
)

def _example_stub_repo_extension_impl(module_ctx):
    """Implement example stub repo extension impl behavior."""
    for mod in module_ctx.modules:
        for call in mod.tags.example_stub_repo:
            example_stub_repo(
                name = call.name,
                go_module_included = call.go_module_included,
                go_module_path = call.go_module_path,
                go_sanitized_module_path = call.go_sanitized_module_path,
                labels = list(call.labels or []),
                out_dir = call.out_dir,
                repo_alias = call.name,
                service_name = call.service_name,
                service_keys = list(call.service_keys or []),
            )

example_stub_repo_extension = module_extension(
    implementation = _example_stub_repo_extension_impl,
    tag_classes = {
        "example_stub_repo": tag_class(attrs = {
            "go_module_included": attr.bool(default = False),
            "go_module_path": attr.string(default = "example.com/stub"),
            "go_sanitized_module_path": attr.string(default = "example_com_stub"),
            "labels": attr.string_list(),
            "name": attr.string(mandatory = True),
            "out_dir": attr.string(default = ".testoptimization"),
            "service_name": attr.string(default = "stub-service"),
            "service_keys": attr.string_list(),
        }),
    },
)
