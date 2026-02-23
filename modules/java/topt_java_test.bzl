"""Macro: dd_topt_java_test.

Wraps a Java test rule with Datadog Test Optimization wiring and per-module
payload selection.
"""

load(
    "@datadog-rules-test-optimization//tools/core:common_utils.bzl",
    _LABEL_FRAGMENT_ALLOWED_CHARS = "LABEL_FRAGMENT_ALLOWED_CHARS",
)
load(
    "@datadog-rules-test-optimization//tools/core:topt_macro_utils.bzl",
    "normalize_user_data",
    "resolve_topt_service_key",
    "service_mapping_entries",
    _is_dict = "is_dict",
    _is_list = "is_list",
    _is_string = "is_string",
)
load("//:topt_java_infer.bzl", "topt_java_payloads_selector")

_service_mapping_entries = service_mapping_entries
_normalize_user_data = normalize_user_data

def _resolve_topt_service_key(service_entries, topt_service):
    return resolve_topt_service_key(service_entries, topt_service, macro_name = "dd_topt_java_test")

def _validate_java_test_rule_or_fail(java_test_rule):
    if java_test_rule == None:
        fail("dd_topt_java_test: you must pass java_test_rule = java_test from native rules")

def _select_service_entry_or_fail(topt_data, topt_service):
    if topt_data == None or not _is_dict(topt_data):
        fail("dd_topt_java_test: topt_data is required and must be the dict from @<repo>//:export.bzl (single-service) or the aggregator mapping")

    if topt_data.get("repo_name"):
        return topt_data

    service_entries = _service_mapping_entries(topt_data)
    if not service_entries:
        fail("dd_topt_java_test: topt_data mapping did not contain any service entries")
    selected_key = _resolve_topt_service_key(service_entries, topt_service)
    return service_entries[selected_key]

# Public aliases for unit tests.
service_mapping_entries_for_tests = _service_mapping_entries
resolve_topt_service_key_for_tests = _resolve_topt_service_key
normalize_user_data_for_tests = _normalize_user_data
validate_java_test_rule_for_tests = _validate_java_test_rule_or_fail
select_service_entry_for_tests = _select_service_entry_or_fail

def _build_module_labels(sync_repo_name, labels):
    if labels == None:
        return []
    if not _is_list(labels):
        fail("dd_topt_java_test: selected service topt_data['labels'] must be a list or tuple")

    module_labels = []
    for lab in labels:
        if not _is_string(lab):
            fail("dd_topt_java_test: selected service topt_data['labels'] entries must be strings")
        if not lab:
            fail("dd_topt_java_test: selected service topt_data['labels'] entries must be non-empty")
        for i in range(len(lab)):
            ch = lab[i]
            if ch not in _LABEL_FRAGMENT_ALLOWED_CHARS:
                fail("dd_topt_java_test: selected service topt_data['labels'] entries must be sanitized ([a-z0-9_]): '%s'" % lab)
        module_labels.append("@%s//:module_%s" % (sync_repo_name, lab))
    return module_labels

build_module_labels_for_tests = _build_module_labels

def _build_java_fallback_identifier(package_path, runtime_info):
    pkg_dotted = (package_path or "").replace("/", ".")
    module_path = ((runtime_info or {}).get("module_path") or "")
    if module_path:
        return (module_path + "." + pkg_dotted) if pkg_dotted else module_path
    return pkg_dotted

def dd_topt_java_test(
        name,
        topt_data,
        java_test_rule,
        topt_service = None,
        module_label_override = None,
        module_identifier = None,
        **kwargs):
    """Define a Java test with Datadog Test Optimization support."""
    _validate_java_test_rule_or_fail(java_test_rule)
    _svc = _select_service_entry_or_fail(topt_data, topt_service)

    user_data = kwargs.pop("data", None)
    data = _normalize_user_data(user_data)

    sync_repo_name = _svc.get("repo_name")
    if not sync_repo_name:
        fail("dd_topt_java_test: selected topt_data entry is missing required 'repo_name'")

    _runtimes = _svc.get("runtimes") or {}
    _java = _runtimes.get("java") if _is_dict(_runtimes) else {}
    if not _is_dict(_java):
        _java = {}

    deps_labels = kwargs.get("deps", []) or []
    test_class = kwargs.get("test_class") or ""
    attribute_candidates = []
    if kwargs.get("java_package") != None:
        attribute_candidates.append(kwargs.get("java_package"))
    if kwargs.get("package") != None:
        attribute_candidates.append(kwargs.get("package"))

    uses_inference = bool(module_identifier) or bool(test_class) or bool(deps_labels) or bool(attribute_candidates)
    if uses_inference:
        include_per_module_files = True
    else:
        module_included = _java.get("module_included") if _is_dict(_java) else None
        if module_included != None:
            include_per_module_files = bool(module_included)
        else:
            include_per_module_files = bool(_svc.get("labels"))

    files_label = "@%s//:test_optimization_files" % sync_repo_name
    module_labels = _build_module_labels(sync_repo_name, _svc.get("labels"))
    fallback_identifier = _build_java_fallback_identifier(native.package_name(), _java)

    selector_name = name + "_topt_payloads"
    topt_java_payloads_selector(
        name = selector_name,
        deps = deps_labels,
        test_class = test_class,
        attribute_candidates = attribute_candidates,
        explicit_identifier = module_identifier or "",
        fallback_identifier = fallback_identifier,
        full_files = files_label,
        module_groups = module_labels,
        include_per_module = include_per_module_files,
        module_label_override = module_label_override,
    )

    user_env = kwargs.pop("env", None) or {}
    env = dict(user_env)

    data.append(":" + selector_name)

    manifest_path = _svc.get("manifest_path") or ".testoptimization/manifest.txt"
    manifest_label = "@%s//:%s" % (sync_repo_name, manifest_path)
    data.append(manifest_label)
    env["DD_TEST_OPTIMIZATION_MANIFEST_FILE"] = "$(rlocationpath %s)" % manifest_label
    env["DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"] = "true"

    java_test_rule(
        name = name,
        data = data,
        env = env,
        **kwargs
    )
