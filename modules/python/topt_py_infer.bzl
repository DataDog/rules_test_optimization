# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Analysis-time Python module identifier inference helpers.

This companion mirrors the Go selector flow:
- infer candidate identifiers during analysis,
- choose a per-module group when possible,
- fall back safely to the full payload bundle.
"""

load(
    "@datadog-rules-test-optimization//tools/core:topt_selection_utils.bzl",
    "select_module_group_name",
    "selected_payload_runfiles",
)

_select_module_group_name = select_module_group_name
_selected_payload_runfiles = selected_payload_runfiles

# Public aliases for unit tests.
select_module_group_name_for_tests = _select_module_group_name

ToptPyModuleInfo = provider(
    doc = "Provider carrying ordered Python module identifier candidates.",
    fields = {"candidates": "Ordered normalized Python module identifier candidates."},
)

def _normalize_python_identifier(raw):
    if type(raw) != type(""):
        return ""
    value = raw.strip()
    if not value:
        return ""
    value = value.replace("\\", ".").replace("/", ".")
    parts = [part for part in value.split(".") if part]
    if not parts:
        return ""
    return ".".join(parts)

normalize_python_identifier_for_tests = _normalize_python_identifier

def _append_normalized_candidate(candidates, seen, raw):
    normalized = _normalize_python_identifier(raw)
    if normalized and not seen.get(normalized):
        seen[normalized] = True
        candidates.append(normalized)

def _py_module_aspect_impl(_target, ctx):
    candidates = []
    seen = {}

    if hasattr(ctx, "rule"):
        if hasattr(ctx.rule.attr, "imports"):
            for imp in (ctx.rule.attr.imports or []):
                _append_normalized_candidate(candidates, seen, imp)

        for dep in getattr(ctx.rule.attr, "deps", []):
            if ToptPyModuleInfo in dep:
                for candidate in dep[ToptPyModuleInfo].candidates:
                    _append_normalized_candidate(candidates, seen, candidate)

        for attr_name in ["importpath", "module_path"]:
            if hasattr(ctx.rule.attr, attr_name):
                _append_normalized_candidate(candidates, seen, getattr(ctx.rule.attr, attr_name))

    if candidates:
        return [ToptPyModuleInfo(candidates = candidates)]
    return []

_py_module_aspect = aspect(
    implementation = _py_module_aspect_impl,
    attr_aspects = ["deps"],
)

def _select_from_candidates(candidates, module_group_names, include_per_module, module_label_override, strict = False):
    if not candidates:
        candidates = [""]
    for idx in range(len(candidates)):
        candidate = candidates[idx]
        selected_name = _select_module_group_name(
            candidate,
            module_group_names,
            include_per_module,
            module_label_override,
            fail_on_miss = strict and idx == 0,
            failure_context = "topt_py_payloads_selector",
        )
        if selected_name:
            return selected_name
    return ""

def _materialize_selected_payloads(ctx, files):
    """Materialize the selected metadata under one physical manifest root."""
    sources_by_basename = {file.basename: file for file in files}
    manifest_source = sources_by_basename.get("manifest.txt")
    if manifest_source == None:
        return struct(files = files, manifest = None)

    output_paths = {
        "manifest.txt": ".testoptimization/manifest.txt",
        "settings.json": ".testoptimization/cache/http/settings.json",
        "known_tests.json": ".testoptimization/cache/http/known_tests.json",
        "test_management.json": ".testoptimization/cache/http/test_management.json",
        "flaky_tests.json": ".testoptimization/cache/http/flaky_tests.json",
    }
    outputs = []
    replaced_paths = {}
    manifest = None
    for basename, relative_path in output_paths.items():
        source = sources_by_basename.get(basename)
        if source == None:
            continue
        output = ctx.actions.declare_file(ctx.label.name + "/" + relative_path)
        ctx.actions.symlink(output = output, target_file = source)
        outputs.append(output)
        replaced_paths[source.path] = True
        if basename == "manifest.txt":
            manifest = output

    return struct(
        files = outputs + [file for file in files if not replaced_paths.get(file.path)],
        manifest = manifest,
    )

def _topt_py_payloads_selector_impl(ctx):
    module_group_names = ctx.attr.module_group_names
    if module_group_names:
        if len(module_group_names) != len(ctx.attr.module_groups):
            fail("module_group_names must contain one entry per module_groups entry")
    else:
        module_group_names = [m.label.name for m in ctx.attr.module_groups]

    explicit_identifier = _normalize_python_identifier(ctx.attr.explicit_identifier)
    selected_name = ""
    strict_selection = ctx.attr.include_per_module and len(module_group_names) > 0 and (
        bool(explicit_identifier) or bool(ctx.attr.module_label_override)
    )
    if explicit_identifier:
        selected_name = _select_from_candidates(
            [explicit_identifier],
            module_group_names,
            ctx.attr.include_per_module,
            ctx.attr.module_label_override,
            strict = strict_selection,
        )
    else:
        inferred_candidates = []
        seen = {}

        for imp in ctx.attr.imports:
            _append_normalized_candidate(inferred_candidates, seen, imp)
        for dep in ctx.attr.deps:
            if ToptPyModuleInfo in dep:
                for candidate in dep[ToptPyModuleInfo].candidates:
                    _append_normalized_candidate(inferred_candidates, seen, candidate)
        for candidate in [ctx.attr.importpath, ctx.attr.module_path]:
            _append_normalized_candidate(inferred_candidates, seen, candidate)
        for candidate in ctx.attr.attribute_candidates:
            _append_normalized_candidate(inferred_candidates, seen, candidate)

        selected_name = _select_from_candidates(
            inferred_candidates,
            module_group_names,
            ctx.attr.include_per_module,
            ctx.attr.module_label_override,
            strict = strict_selection,
        )

        if not selected_name:
            fallback_identifier = _normalize_python_identifier(ctx.attr.fallback_identifier)
            selected_name = _select_from_candidates(
                [fallback_identifier],
                module_group_names,
                ctx.attr.include_per_module,
                ctx.attr.module_label_override,
            )

    chosen = None
    if selected_name:
        for index in range(len(module_group_names)):
            if module_group_names[index] == selected_name:
                chosen = ctx.attr.module_groups[index]
                break

    source = chosen if chosen != None else ctx.attr.full_files
    src_default = source[DefaultInfo]
    payload = _selected_payload_runfiles(
        src_default.files.to_list(),
        include_flaky_tests = False,
    )
    materialized = _materialize_selected_payloads(ctx, payload.files)
    providers = [DefaultInfo(
        files = depset(materialized.files),
        runfiles = ctx.runfiles(
            files = materialized.files,
        ),
    )]
    if materialized.manifest != None:
        providers.append(OutputGroupInfo(
            selected_manifest = depset([materialized.manifest]),
        ))
    return providers

topt_py_payloads_selector = rule(
    implementation = _topt_py_payloads_selector_impl,
    attrs = {
        "deps": attr.label_list(aspects = [_py_module_aspect]),
        "imports": attr.string_list(),
        "attribute_candidates": attr.string_list(),
        "importpath": attr.string(),
        "module_path": attr.string(),
        "explicit_identifier": attr.string(),
        "fallback_identifier": attr.string(),
        "full_files": attr.label(),
        "module_group_names": attr.string_list(),
        "module_groups": attr.label_list(),
        "include_per_module": attr.bool(default = True),
        "module_label_override": attr.string(),
    },
)
