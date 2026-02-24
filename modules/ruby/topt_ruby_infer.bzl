"""Analysis-time Ruby module identifier inference helpers."""

load(
    "@datadog-rules-test-optimization//tools/core:topt_selection_utils.bzl",
    "select_module_group_name",
)

_select_module_group_name = select_module_group_name

# Public aliases for unit tests.
select_module_group_name_for_tests = _select_module_group_name

ToptRubyModuleInfo = provider(
    doc = "Provider carrying ordered Ruby module identifier candidates.",
    fields = {"candidates": "Ordered normalized Ruby module identifier candidates."},
)

def _normalize_ruby_identifier(raw):
    if type(raw) != type(""):
        return ""
    value = raw.strip()
    if not value:
        return ""
    value = value.replace("\\", "/")
    parts = [part for part in value.split("/") if part]
    if not parts:
        return ""
    return "/".join(parts)

normalize_ruby_identifier_for_tests = _normalize_ruby_identifier

def _append_normalized_candidate(candidates, seen, raw):
    normalized = _normalize_ruby_identifier(raw)
    if normalized and not seen.get(normalized):
        seen[normalized] = True
        candidates.append(normalized)

def _ruby_module_aspect_impl(_target, ctx):
    candidates = []
    seen = {}

    if hasattr(ctx, "rule"):
        for attr_name in ["require_path", "gem_name", "library_name", "main"]:
            if hasattr(ctx.rule.attr, attr_name):
                _append_normalized_candidate(candidates, seen, getattr(ctx.rule.attr, attr_name))

        for dep in getattr(ctx.rule.attr, "deps", []):
            if ToptRubyModuleInfo in dep:
                for candidate in dep[ToptRubyModuleInfo].candidates:
                    _append_normalized_candidate(candidates, seen, candidate)

    if candidates:
        return [ToptRubyModuleInfo(candidates = candidates)]
    return []

_ruby_module_aspect = aspect(
    implementation = _ruby_module_aspect_impl,
    attr_aspects = ["deps"],
)

def _select_from_candidates(candidates, module_group_names, include_per_module, module_label_override):
    if not candidates:
        candidates = [""]
    for candidate in candidates:
        selected_name = _select_module_group_name(
            candidate,
            module_group_names,
            include_per_module,
            module_label_override,
        )
        if selected_name:
            return selected_name
    return ""

def _topt_ruby_payloads_selector_impl(ctx):
    module_group_names = [m.label.name for m in ctx.attr.module_groups]

    explicit_identifier = _normalize_ruby_identifier(ctx.attr.explicit_identifier)
    selected_name = ""
    if explicit_identifier:
        selected_name = _select_from_candidates(
            [explicit_identifier],
            module_group_names,
            ctx.attr.include_per_module,
            ctx.attr.module_label_override,
        )
    else:
        inferred_candidates = []
        seen = {}

        for candidate in ctx.attr.attribute_candidates:
            _append_normalized_candidate(inferred_candidates, seen, candidate)
        for dep in ctx.attr.deps:
            if ToptRubyModuleInfo in dep:
                for candidate in dep[ToptRubyModuleInfo].candidates:
                    _append_normalized_candidate(inferred_candidates, seen, candidate)

        selected_name = _select_from_candidates(
            inferred_candidates,
            module_group_names,
            ctx.attr.include_per_module,
            ctx.attr.module_label_override,
        )

        if not selected_name:
            fallback_identifier = _normalize_ruby_identifier(ctx.attr.fallback_identifier)
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

topt_ruby_payloads_selector = rule(
    implementation = _topt_ruby_payloads_selector_impl,
    attrs = {
        "deps": attr.label_list(aspects = [_ruby_module_aspect]),
        "attribute_candidates": attr.string_list(),
        "explicit_identifier": attr.string(),
        "fallback_identifier": attr.string(),
        "full_files": attr.label(),
        "module_groups": attr.label_list(),
        "include_per_module": attr.bool(default = True),
        "module_label_override": attr.string(),
    },
)
