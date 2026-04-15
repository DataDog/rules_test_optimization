"""Macro: dd_topt_py_test.

Wraps a Python test rule with Datadog Test Optimization wiring and per-module
payload selection.
"""

load(
    "@datadog-rules-test-optimization//tools/core:common_utils.bzl",
    "fail_with_prefix",
)
load(
    "@datadog-rules-test-optimization//tools/core:topt_macro_utils.bzl",
    "append_data_dependencies",
    "build_module_labels",
    "merge_optional_env_defaults",
    "merge_user_env",
    "normalize_user_data",
    "resolve_topt_service_key",
    "select_service_entry_or_fail",
    "service_mapping_entries",
    "split_test_wrapper_kwargs",
    _is_dict = "is_dict",
)
load(
    "@datadog-rules-test-optimization//tools/core:topt_test_wrapper.bzl",
    "topt_bazel_metadata",
    "topt_test_wrapper",
)
load("//:topt_py_infer.bzl", "topt_py_payloads_selector")
load("@datadog_ddtrace//:requirements.bzl", _ddtrace_requirement = "requirement")

_service_mapping_entries = service_mapping_entries
_normalize_user_data = normalize_user_data
_append_data_dependencies = append_data_dependencies
_merge_optional_env_defaults = merge_optional_env_defaults
_merge_user_env = merge_user_env

def _resolve_topt_service_key(service_entries, topt_service):
    return resolve_topt_service_key(service_entries, topt_service, macro_name = "dd_topt_py_test")

def _validate_py_test_rule_or_fail(py_test_rule):
    if py_test_rule == None:
        fail_with_prefix("dd_topt_py_test", "you must pass py_test_rule = py_test from native or rules_python")

def _select_service_entry_or_fail(topt_data, topt_service):
    return select_service_entry_or_fail(topt_data, topt_service, macro_name = "dd_topt_py_test")

# Public aliases for unit tests.
service_mapping_entries_for_tests = _service_mapping_entries
resolve_topt_service_key_for_tests = _resolve_topt_service_key
normalize_user_data_for_tests = _normalize_user_data
validate_py_test_rule_for_tests = _validate_py_test_rule_or_fail
select_service_entry_for_tests = _select_service_entry_or_fail

def _build_module_labels(sync_repo_name, labels):
    return build_module_labels(sync_repo_name, labels, macro_name = "dd_topt_py_test")

build_module_labels_for_tests = _build_module_labels

def _build_python_fallback_identifier(package_path, runtime_info):
    pkg_dotted = (package_path or "").replace("/", ".")
    module_path = ((runtime_info or {}).get("module_path") or "")
    if module_path:
        return (module_path + "." + pkg_dotted) if pkg_dotted else module_path
    return pkg_dotted

def _has_non_empty_value(value):
    if value == None:
        return False
    if type(value) == type(""):
        return value.strip() != ""
    if type(value) == type([]) or type(value) == type(()):
        return len(value) > 0
    return True

def dd_topt_py_test(
        name,
        topt_data,
        py_test_rule,
        topt_service = None,
        module_label_override = None,
        module_identifier = None,
        **kwargs):
    """Define a Python test with Datadog Test Optimization support."""
    _validate_py_test_rule_or_fail(py_test_rule)
    _svc = _select_service_entry_or_fail(topt_data, topt_service)

    wrapper_kwargs, raw_passthrough = split_test_wrapper_kwargs(kwargs)

    user_data = kwargs.pop("data", None)
    data = _append_data_dependencies(user_data, [])

    sync_repo_name = _svc.get("repo_name")
    if not sync_repo_name:
        fail_with_prefix("dd_topt_py_test", "selected topt_data entry is missing required 'repo_name'")

    _runtimes = _svc.get("runtimes") or {}
    _python = _runtimes.get("python") if _is_dict(_runtimes) else {}
    if not _is_dict(_python):
        _python = {}

    user_deps = kwargs.pop("deps", None)
    deps_labels = user_deps if user_deps != None else []
    imports_candidates = kwargs.get("imports")
    if imports_candidates == None:
        imports_candidates = []
    importpath_candidate = kwargs.get("importpath") if "importpath" in kwargs else None
    module_path_candidate = kwargs.get("module_path") if "module_path" in kwargs else None
    attribute_candidates = []
    if type(importpath_candidate) == type("") and importpath_candidate:
        attribute_candidates.append(importpath_candidate)
    if type(module_path_candidate) == type("") and module_path_candidate:
        attribute_candidates.append(module_path_candidate)

    uses_inference = (
        _has_non_empty_value(module_identifier) or
        _has_non_empty_value(imports_candidates) or
        _has_non_empty_value(deps_labels) or
        _has_non_empty_value(importpath_candidate) or
        _has_non_empty_value(module_path_candidate)
    )
    if uses_inference:
        include_per_module_files = True
    else:
        module_included = _python.get("module_included") if _is_dict(_python) else None
        if module_included != None:
            include_per_module_files = bool(module_included)
        else:
            include_per_module_files = bool(_svc.get("labels"))

    files_label = "@%s//:test_optimization_files" % sync_repo_name
    module_labels = _build_module_labels(sync_repo_name, _svc.get("labels"))
    fallback_identifier = _build_python_fallback_identifier(native.package_name(), _python)

    selector_name = name + "_topt_payloads"
    metadata_name = name + "_topt_bazel_metadata"
    topt_py_payloads_selector(
        name = selector_name,
        deps = deps_labels,
        imports = imports_candidates,
        attribute_candidates = attribute_candidates,
        explicit_identifier = module_identifier or "",
        fallback_identifier = fallback_identifier,
        full_files = files_label,
        module_groups = module_labels,
        include_per_module = include_per_module_files,
        module_label_override = module_label_override,
        importpath = importpath_candidate if importpath_candidate != None else "",
        module_path = module_path_candidate if module_path_candidate != None else "",
    )

    pkg_path = native.package_name()
    topt_bazel_metadata(
        name = metadata_name,
        bazel_package = "//%s" % pkg_path if pkg_path else "//",
        bazel_target = "//%s:%s" % (pkg_path, name) if pkg_path else "//:%s" % name,
        repo_name = sync_repo_name,
        service_name = _svc.get("service_name") or "",
        runtime_name = "python",
    )

    user_env = kwargs.pop("env", None)

    # Default DD_SERVICE from sync metadata without overriding caller intent.
    user_env = _merge_optional_env_defaults(
        user_env,
        {"DD_SERVICE": _svc.get("service_name")},
        macro_name = "dd_topt_py_test",
    )

    data = _append_data_dependencies(data, [":" + selector_name])

    manifest_path = _svc.get("manifest_path") or ".testoptimization/manifest.txt"
    manifest_label = "@%s//:%s" % (sync_repo_name, manifest_path)
    data = _append_data_dependencies(data, [manifest_label])
    env = _merge_user_env(
        user_env,
        {
            "DD_TEST_OPTIMIZATION_MANIFEST_FILE": "$(rlocationpath %s)" % manifest_label,
            "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "true",
            "DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME": metadata_name + ".json",
        },
        macro_name = "dd_topt_py_test",
    )

    raw_name = name + "__raw_python_test"
    kwargs["tags"] = (wrapper_kwargs.get("tags") or []) + ["manual"]
    kwargs["visibility"] = ["//visibility:private"]
    for key, value in raw_passthrough.items():
        kwargs[key] = value

    # Inject the companion-managed ddtrace so customers don't have to add it
    # to their own requirements files.
    test_deps = _append_data_dependencies(user_deps, [_ddtrace_requirement("ddtrace")])

    py_test_rule(
        name = raw_name,
        data = data,
        env = env,
        deps = test_deps,
        **kwargs
    )

    topt_test_wrapper(
        name = name,
        actual = ":" + raw_name,
        metadata = ":" + metadata_name,
        **wrapper_kwargs
    )
