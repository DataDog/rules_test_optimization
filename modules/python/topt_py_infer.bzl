"""Analysis-time Python module identifier inference helpers.

This companion mirrors the Go selector flow:
- infer candidate identifiers during analysis,
- choose a per-module group when possible,
- fall back safely to the full payload bundle.
"""

load(
    "@datadog-rules-test-optimization//tools/core:topt_selection_utils.bzl",
    "select_module_group_name",
)

_select_module_group_name = select_module_group_name

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

def _topt_py_payloads_selector_impl(ctx):
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
        for m in ctx.attr.module_groups:
            if m.label.name == selected_name:
                chosen = m
                break

    source = chosen if chosen != None else ctx.attr.full_files
    src_default = source[DefaultInfo]
    return [DefaultInfo(files = src_default.files, runfiles = src_default.default_runfiles)]

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
        "module_groups": attr.label_list(),
        "include_per_module": attr.bool(default = True),
        "module_label_override": attr.string(),
    },
)
