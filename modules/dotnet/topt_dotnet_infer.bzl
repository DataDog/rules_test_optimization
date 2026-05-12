# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Analysis-time .NET module identifier inference helpers."""

load(
    "@datadog-rules-test-optimization//tools/core:topt_selection_utils.bzl",
    "select_module_group_name",
)

_select_module_group_name = select_module_group_name

# Public aliases for unit tests.
select_module_group_name_for_tests = _select_module_group_name

ToptDotnetModuleInfo = provider(
    doc = "Provider carrying ordered .NET module identifier candidates.",
    fields = {"candidates": "Ordered normalized .NET module identifier candidates."},
)

def _normalize_dotnet_identifier(raw):
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

normalize_dotnet_identifier_for_tests = _normalize_dotnet_identifier

def _append_normalized_candidate(candidates, seen, raw):
    normalized = _normalize_dotnet_identifier(raw)
    if normalized and not seen.get(normalized):
        seen[normalized] = True
        candidates.append(normalized)

def _dotnet_module_aspect_impl(_target, ctx):
    candidates = []
    seen = {}

    if hasattr(ctx, "rule"):
        for attr_name in ["root_namespace", "assembly_name", "project_name", "test_class"]:
            if hasattr(ctx.rule.attr, attr_name):
                _append_normalized_candidate(candidates, seen, getattr(ctx.rule.attr, attr_name))

        for dep in getattr(ctx.rule.attr, "deps", []):
            if ToptDotnetModuleInfo in dep:
                for candidate in dep[ToptDotnetModuleInfo].candidates:
                    _append_normalized_candidate(candidates, seen, candidate)

    if candidates:
        return [ToptDotnetModuleInfo(candidates = candidates)]
    return []

_dotnet_module_aspect = aspect(
    implementation = _dotnet_module_aspect_impl,
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
            failure_context = "topt_dotnet_payloads_selector",
        )
        if selected_name:
            return selected_name
    return ""

def _canonical_payload_symlinks(files):
    """Return canonical cache/http symlinks for selected payload files."""
    settings_file = None
    known_tests_file = None
    test_management_file = None

    for file in files:
        if file.basename == "settings.json":
            settings_file = file
        elif file.basename == "known_tests.json":
            known_tests_file = file
        elif file.basename == "test_management.json":
            test_management_file = file

    if settings_file == None:
        return {}

    cache_http_dir = "/".join(settings_file.short_path.split("/")[:-1])
    if not cache_http_dir:
        return {}

    symlinks = {}
    if known_tests_file != None:
        known_tests_path = cache_http_dir + "/known_tests.json"
        if known_tests_file.short_path != known_tests_path:
            symlinks[known_tests_path] = known_tests_file
    if test_management_file != None:
        test_management_path = cache_http_dir + "/test_management.json"
        if test_management_file.short_path != test_management_path:
            symlinks[test_management_path] = test_management_file
    return symlinks

def _topt_dotnet_payloads_selector_impl(ctx):
    module_group_names = [m.label.name for m in ctx.attr.module_groups]

    explicit_identifier = _normalize_dotnet_identifier(ctx.attr.explicit_identifier)
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

        for candidate in [ctx.attr.root_namespace, ctx.attr.assembly_name, ctx.attr.project_name, ctx.attr.test_class]:
            _append_normalized_candidate(inferred_candidates, seen, candidate)
        for candidate in ctx.attr.attribute_candidates:
            _append_normalized_candidate(inferred_candidates, seen, candidate)
        for dep in ctx.attr.deps:
            if ToptDotnetModuleInfo in dep:
                for candidate in dep[ToptDotnetModuleInfo].candidates:
                    _append_normalized_candidate(inferred_candidates, seen, candidate)

        selected_name = _select_from_candidates(
            inferred_candidates,
            module_group_names,
            ctx.attr.include_per_module,
            ctx.attr.module_label_override,
            strict = strict_selection,
        )

        if not selected_name:
            fallback_identifier = _normalize_dotnet_identifier(ctx.attr.fallback_identifier)
            selected_name = _select_from_candidates(
                [fallback_identifier],
                module_group_names,
                ctx.attr.include_per_module,
                ctx.attr.module_label_override,
            )

    chosen = None
    if selected_name:
        for m in ctx.attr.module_groups:
            if m.label.name == selected_name:
                chosen = m
                break

    source = chosen if chosen != None else ctx.attr.full_files
    src_default = source[DefaultInfo]
    files = src_default.files.to_list()
    return [DefaultInfo(
        files = depset(files),
        runfiles = ctx.runfiles(files = files, symlinks = _canonical_payload_symlinks(files)),
    )]

topt_dotnet_payloads_selector = rule(
    implementation = _topt_dotnet_payloads_selector_impl,
    attrs = {
        "deps": attr.label_list(aspects = [_dotnet_module_aspect]),
        "attribute_candidates": attr.string_list(),
        "root_namespace": attr.string(),
        "assembly_name": attr.string(),
        "project_name": attr.string(),
        "test_class": attr.string(),
        "explicit_identifier": attr.string(),
        "fallback_identifier": attr.string(),
        "full_files": attr.label(),
        "module_groups": attr.label_list(),
        "include_per_module": attr.bool(default = True),
        "module_label_override": attr.string(),
    },
)
