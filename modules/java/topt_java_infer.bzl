"""Analysis-time Java package identifier inference helpers."""

load(
    "@datadog-rules-test-optimization//tools/core:topt_selection_utils.bzl",
    "select_module_group_name",
)

_select_module_group_name = select_module_group_name

# Public aliases for unit tests.
select_module_group_name_for_tests = _select_module_group_name

ToptJavaModuleInfo = provider(
    doc = "Provider carrying ordered Java package identifier candidates.",
    fields = {"candidates": "Ordered normalized Java package identifier candidates."},
)

def _normalize_java_identifier(raw):
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

normalize_java_identifier_for_tests = _normalize_java_identifier

def _java_package_from_test_class(test_class):
    s = (test_class or "").strip()
    if not s:
        return ""
    if s.endswith("."):
        s = s[:-1]
    dot = s.rfind(".")
    if dot <= 0:
        return ""
    return s[:dot]

java_package_from_test_class_for_tests = _java_package_from_test_class

def _append_normalized_candidate(candidates, seen, raw):
    normalized = _normalize_java_identifier(raw)
    if normalized and not seen.get(normalized):
        seen[normalized] = True
        candidates.append(normalized)

def _java_module_aspect_impl(_target, ctx):
    candidates = []
    seen = {}

    if hasattr(ctx, "rule"):
        for dep in getattr(ctx.rule.attr, "deps", []):
            if ToptJavaModuleInfo in dep:
                for candidate in dep[ToptJavaModuleInfo].candidates:
                    _append_normalized_candidate(candidates, seen, candidate)

        for attr_name in ["java_package", "package"]:
            if hasattr(ctx.rule.attr, attr_name):
                _append_normalized_candidate(candidates, seen, getattr(ctx.rule.attr, attr_name))

    if candidates:
        return [ToptJavaModuleInfo(candidates = candidates)]
    return []

_java_module_aspect = aspect(
    implementation = _java_module_aspect_impl,
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
            failure_context = "topt_java_payloads_selector",
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

def _topt_java_payloads_selector_impl(ctx):
    module_group_names = [m.label.name for m in ctx.attr.module_groups]

    explicit_identifier = _normalize_java_identifier(ctx.attr.explicit_identifier)
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

        test_class_package = _java_package_from_test_class(ctx.attr.test_class)
        _append_normalized_candidate(inferred_candidates, seen, test_class_package)

        for dep in ctx.attr.deps:
            if ToptJavaModuleInfo in dep:
                for candidate in dep[ToptJavaModuleInfo].candidates:
                    _append_normalized_candidate(inferred_candidates, seen, candidate)
        for candidate in [ctx.attr.java_package, ctx.attr.package]:
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
            fallback_identifier = _normalize_java_identifier(ctx.attr.fallback_identifier)
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

topt_java_payloads_selector = rule(
    implementation = _topt_java_payloads_selector_impl,
    attrs = {
        "deps": attr.label_list(aspects = [_java_module_aspect]),
        "test_class": attr.string(),
        "attribute_candidates": attr.string_list(),
        "java_package": attr.string(),
        "package": attr.string(),
        "explicit_identifier": attr.string(),
        "fallback_identifier": attr.string(),
        "full_files": attr.label(),
        "module_groups": attr.label_list(),
        "include_per_module": attr.bool(default = True),
        "module_label_override": attr.string(),
    },
)
