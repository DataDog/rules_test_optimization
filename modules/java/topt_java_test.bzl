"""Macro: dd_topt_java_test.

Wraps a Java test rule with Datadog Test Optimization wiring and per-module
payload selection.
"""

load(
    "@datadog-rules-test-optimization//tools/core:common_utils.bzl",
    "fail_with_prefix",
)
load(
    "@datadog-rules-test-optimization//tools/core:topt_macro_utils.bzl",
    "append_data_dependencies",
    "append_list_attribute",
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
load("@rules_java//java:defs.bzl", _default_java_test = "java_test")
load("//:topt_java_infer.bzl", "topt_java_payloads_selector")

_service_mapping_entries = service_mapping_entries
_normalize_user_data = normalize_user_data
_append_data_dependencies = append_data_dependencies
_append_list_attribute = append_list_attribute
_merge_optional_env_defaults = merge_optional_env_defaults
_merge_user_env = merge_user_env

def _resolve_topt_service_key(service_entries, topt_service):
    return resolve_topt_service_key(service_entries, topt_service, macro_name = "dd_topt_java_test")

def _select_service_entry_or_fail(topt_data, topt_service):
    return select_service_entry_or_fail(topt_data, topt_service, macro_name = "dd_topt_java_test")

# Public aliases for unit tests.
service_mapping_entries_for_tests = _service_mapping_entries
resolve_topt_service_key_for_tests = _resolve_topt_service_key
normalize_user_data_for_tests = _normalize_user_data
select_service_entry_for_tests = _select_service_entry_or_fail

def _build_module_labels(sync_repo_name, labels):
    return build_module_labels(sync_repo_name, labels, macro_name = "dd_topt_java_test")

build_module_labels_for_tests = _build_module_labels

def _build_java_fallback_identifier(package_path, runtime_info):
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

def dd_topt_java_test(
        name,
        topt_data,
        agent_jar,
        java_test_rule = _default_java_test,
        topt_service = None,
        module_label_override = None,
        module_identifier = None,
        ci_visibility_enabled = True,
        **kwargs):
    """Define a Java test with Datadog Test Optimization support.

    Args:
      agent_jar: Required label pointing to the dd-java-agent JAR. The macro
        injects ``-javaagent:$(rootpath <label>)`` into ``jvm_flags`` and adds
        the JAR to ``data`` so it is available at runtime. The customer is
        responsible for making this label available (e.g. via ``http_file``,
        ``maven_install``, or a local filegroup).
      java_test_rule: Optional override for the underlying ``java_test`` rule.
        Defaults to ``java_test`` from ``@rules_java//java:defs.bzl``. Override
        only when wrapping a custom test macro (e.g. a junit5 wrapper).
      ci_visibility_enabled: Optional boolean. When true (default), the macro
        forces ``DD_CIVISIBILITY_ENABLED=true`` on the generated test
        environment so payload-to-files mode works without extra env wiring.
        Set false only when the caller intentionally owns this tracer switch.
    """
    if not agent_jar:
        fail_with_prefix("dd_topt_java_test", "agent_jar is required and must be a label pointing to the dd-java-agent JAR")
    _svc = _select_service_entry_or_fail(topt_data, topt_service)

    wrapper_kwargs, raw_passthrough = split_test_wrapper_kwargs(kwargs)

    user_data = kwargs.pop("data", None)
    data = _append_data_dependencies(user_data, [])

    sync_repo_name = _svc.get("repo_name")
    if not sync_repo_name:
        fail_with_prefix("dd_topt_java_test", "selected topt_data entry is missing required 'repo_name'")

    _runtimes = _svc.get("runtimes") or {}
    _java = _runtimes.get("java") if _is_dict(_runtimes) else {}
    if not _is_dict(_java):
        _java = {}

    deps_labels = kwargs.get("deps")
    if deps_labels == None:
        deps_labels = []
    test_class = kwargs.get("test_class")
    if test_class == None:
        test_class = ""
    java_package_candidate = kwargs.get("java_package") if "java_package" in kwargs else None
    package_candidate = kwargs.get("package") if "package" in kwargs else None
    attribute_candidates = []
    if type(java_package_candidate) == type("") and java_package_candidate:
        attribute_candidates.append(java_package_candidate)
    if type(package_candidate) == type("") and package_candidate:
        attribute_candidates.append(package_candidate)

    uses_inference = (
        _has_non_empty_value(module_identifier) or
        _has_non_empty_value(test_class) or
        _has_non_empty_value(deps_labels) or
        _has_non_empty_value(java_package_candidate) or
        _has_non_empty_value(package_candidate)
    )
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
    metadata_name = name + "_topt_bazel_metadata"
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
        java_package = java_package_candidate if java_package_candidate != None else "",
        package = package_candidate if package_candidate != None else "",
    )

    pkg_path = native.package_name()
    topt_bazel_metadata(
        name = metadata_name,
        bazel_package = "//%s" % pkg_path if pkg_path else "//",
        bazel_target = "//%s:%s" % (pkg_path, name) if pkg_path else "//:%s" % name,
        repo_name = sync_repo_name,
        service_name = _svc.get("service_name") or "",
        runtime_name = "java",
    )

    user_env = kwargs.pop("env", None)

    # Default DD_SERVICE from sync metadata without overriding caller intent.
    user_env = _merge_optional_env_defaults(
        user_env,
        {"DD_SERVICE": _svc.get("service_name")},
        macro_name = "dd_topt_java_test",
    )

    data = _append_data_dependencies(data, [":" + selector_name])

    manifest_path = _svc.get("manifest_path") or ".testoptimization/manifest.txt"
    manifest_label = "@%s//:%s" % (sync_repo_name, manifest_path)
    data = _append_data_dependencies(data, [manifest_label])
    required_env = {
        "DD_TEST_OPTIMIZATION_MANIFEST_FILE": "$(rlocationpath %s)" % manifest_label,
        "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "true",
        "DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME": metadata_name + ".json",
    }
    if ci_visibility_enabled:
        required_env["DD_CIVISIBILITY_ENABLED"] = "true"
    env = _merge_user_env(
        user_env,
        required_env,
        macro_name = "dd_topt_java_test",
    )

    # Inject -javaagent flag pointing at the mandatory agent JAR label.
    user_jvm_flags = kwargs.pop("jvm_flags", None)
    agent_flag = "-javaagent:$(rootpath %s)" % agent_jar
    jvm_flags = _append_list_attribute(user_jvm_flags, [agent_flag])
    data = _append_data_dependencies(data, [agent_jar])

    raw_name = name + "__raw_java_test"
    kwargs["tags"] = (wrapper_kwargs.get("tags") or []) + ["manual"]
    kwargs["visibility"] = ["//visibility:private"]
    for key, value in raw_passthrough.items():
        kwargs[key] = value

    kwargs["jvm_flags"] = jvm_flags

    java_test_rule(
        name = raw_name,
        data = data,
        env = env,
        **kwargs
    )

    topt_test_wrapper(
        name = name,
        actual = ":" + raw_name,
        metadata = ":" + metadata_name,
        **wrapper_kwargs
    )
