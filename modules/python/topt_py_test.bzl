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
load("@rules_python//python:py_test.bzl", _default_py_test = "py_test")
load("//:topt_py_infer.bzl", "topt_py_payloads_selector")

_RUN_PYTEST = Label("//:run_pytest.py")

_RUNNER_MODE_MANAGED_PYTEST = "managed_pytest"
_RUNNER_MODE_CONSUMER_RUNNER = "consumer_runner"
_VALID_RUNNER_MODES = [
    _RUNNER_MODE_MANAGED_PYTEST,
    _RUNNER_MODE_CONSUMER_RUNNER,
]

_service_mapping_entries = service_mapping_entries
_normalize_user_data = normalize_user_data
_append_data_dependencies = append_data_dependencies
_merge_optional_env_defaults = merge_optional_env_defaults
_merge_user_env = merge_user_env

def _resolve_topt_service_key(service_entries, topt_service):
    return resolve_topt_service_key(service_entries, topt_service, macro_name = "dd_topt_py_test")

def _select_service_entry_or_fail(topt_data, topt_service):
    return select_service_entry_or_fail(topt_data, topt_service, macro_name = "dd_topt_py_test")

# Public aliases for unit tests.
service_mapping_entries_for_tests = _service_mapping_entries
resolve_topt_service_key_for_tests = _resolve_topt_service_key
normalize_user_data_for_tests = _normalize_user_data
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
    """Return True when a macro input is present and materially non-empty."""
    if value == None:
        return False
    if type(value) == type(""):
        return value.strip() != ""
    if type(value) == type([]) or type(value) == type(()):
        return len(value) > 0
    return True

def _is_default_py_test_rule(py_test_rule):
    """Return True when a py_test_rule value is the rules_python base py_test macro."""
    return py_test_rule == _default_py_test

# Test-only alias used by analysis tests; consumers should not call it.
is_default_py_test_rule_for_tests = _is_default_py_test_rule

def _validate_consumer_runner_inputs(py_test_rule, main):
    """Validate that consumer_runner has an actual consumer-owned test runner.

    In consumer_runner mode this macro deliberately does not inject run_pytest.py
    or synthesize a main file. Using the base rules_python py_test without main
    would let Bazel execute an implicit script entrypoint instead of a known
    pytest runner, which can create false-positive onboarding results.
    """
    if _is_default_py_test_rule(py_test_rule) and main == None:
        fail_with_prefix(
            "dd_topt_py_test",
            "runner_mode = \"consumer_runner\" requires a consumer-owned Python test runner. " +
            "Pass your repository's Python test wrapper via py_test_rule, pass an explicit main " +
            "that executes pytest with ddtrace enabled, or use runner_mode = \"managed_pytest\" " +
            "for the built-in pytest runner.",
        )

def dd_topt_py_test(
        name,
        topt_data,
        py_test_rule = None,
        topt_service = None,
        module_label_override = None,
        module_identifier = None,
        runner_mode = "managed_pytest",
        **kwargs):
    """Define a Python test with Datadog Test Optimization support.

    Args:
        name: Target name.
        topt_data: Test Optimization sync data dict or mapping.
        py_test_rule: Custom py_test rule implementation. Defaults to rules_python py_test.
        topt_service: Service key for multi-service mappings.
        module_label_override: Override for the sanitized module label name.
        module_identifier: Explicit module identifier for per-module payload selection.
        runner_mode: How the test is executed. One of:
            - "managed_pytest" (default): injects run_pytest.py, controls main, synthesizes
              imports and args. Best for repos without a custom Python test wrapper.
            - "consumer_runner": does NOT inject run_pytest.py, does NOT set main or imports
              unless the caller passes them explicitly. Delegates test execution to the
              consumer's py_test_rule. Requires either a custom py_test_rule or an
              explicit main that runs pytest with ddtrace enabled.
              Best for monorepos with an internal Python test wrapper.
        **kwargs: Forwarded to the underlying py_test_rule.
    """
    if runner_mode not in _VALID_RUNNER_MODES:
        fail_with_prefix(
            "dd_topt_py_test",
            "runner_mode must be one of: %s" % ", ".join(_VALID_RUNNER_MODES),
        )

    if py_test_rule == None:
        py_test_rule = _default_py_test
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

    user_srcs = kwargs.pop("srcs", None)
    user_main = kwargs.pop("main", None)

    if runner_mode == _RUNNER_MODE_CONSUMER_RUNNER:
        _validate_consumer_runner_inputs(py_test_rule, user_main)

    # args is a wrapper-only attr; split_test_wrapper_kwargs already moved it to wrapper_kwargs.
    user_args = wrapper_kwargs.pop("args", None)

    user_imports = kwargs.pop("imports", None)
    user_imports_was_explicit = user_imports != None
    imports_candidates = user_imports if user_imports != None else []
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

    # Activate the ddtrace pytest plugin via PYTEST_ADDOPTS:
    # - Not set → inject "--ddtrace" as a default.
    # - Set to a plain string without "--no-ddtrace" → append " --ddtrace".
    # - Set to a plain string containing "--no-ddtrace" → leave unchanged.
    # - Set to a select() value → leave unchanged (caller is responsible).
    _existing_pytest_addopts = user_env.get("PYTEST_ADDOPTS") if _is_dict(user_env) else None
    if _existing_pytest_addopts == None:
        user_env = _merge_optional_env_defaults(
            user_env,
            {"PYTEST_ADDOPTS": "--ddtrace"},
            macro_name = "dd_topt_py_test",
        )
    elif type(_existing_pytest_addopts) == type("") and "--no-ddtrace" not in _existing_pytest_addopts.split():
        user_env = dict(user_env)
        user_env["PYTEST_ADDOPTS"] = _existing_pytest_addopts + " --ddtrace"

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

    if runner_mode == _RUNNER_MODE_MANAGED_PYTEST:
        if user_main == None:
            # No custom runner: inject the bundled run_pytest.py into srcs and set it as main.
            srcs = _append_data_dependencies(user_srcs, [_RUN_PYTEST])
            main = _RUN_PYTEST

            # Default args to the package path for pytest test-file discovery.
            # args goes on the wrapper (which forwards them to the raw test via "$@").
            if user_args != None:
                wrapper_kwargs["args"] = user_args
            elif pkg_path:
                wrapper_kwargs["args"] = [pkg_path]
            else:
                wrapper_kwargs["args"] = []
        else:
            # Caller supplied their own runner: leave srcs and args alone.
            srcs = _append_data_dependencies(user_srcs, [])
            main = user_main
            if user_args != None:
                wrapper_kwargs["args"] = user_args

        # Default imports to the package path for correct module resolution.
        if user_imports_was_explicit:
            imports_for_test = imports_candidates
        elif pkg_path:
            imports_for_test = [pkg_path]
        else:
            imports_for_test = []
    else:
        # consumer_runner: delegate execution to the consumer's wrapper.
        srcs = _append_data_dependencies(user_srcs, [])
        main = user_main  # None if not passed by user.
        if user_args != None:
            wrapper_kwargs["args"] = user_args

        # Only forward imports if the user explicitly passed them.
        imports_for_test = imports_candidates if user_imports_was_explicit else None

    raw_name = name + "__raw_python_test"
    kwargs["tags"] = (wrapper_kwargs.get("tags") or []) + ["manual"]
    kwargs["visibility"] = ["//visibility:private"]
    for key, value in raw_passthrough.items():
        kwargs[key] = value

    kwargs["name"] = raw_name
    kwargs["srcs"] = srcs
    kwargs["data"] = data
    kwargs["env"] = env
    kwargs["deps"] = deps_labels
    if main != None:
        kwargs["main"] = main
    if imports_for_test != None:
        kwargs["imports"] = imports_for_test

    py_test_rule(**kwargs)

    topt_test_wrapper(
        name = name,
        actual = ":" + raw_name,
        metadata = ":" + metadata_name,
        **wrapper_kwargs
    )
