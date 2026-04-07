"""Analysis tests for dd_topt_java_test macro wiring."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@datadog-rules-test-optimization-java//:topt_java_test.bzl",
    "dd_topt_java_test",
    "resolve_topt_service_key_for_tests",
    "select_service_entry_for_tests",
    "validate_java_test_rule_for_tests",
)

ToptJavaMacroCaptureInfo = provider(
    doc = "Captured arguments forwarded by dd_topt_java_test to java_test_rule.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "env": "Forwarded environment map.",
        "test_class": "Forwarded test_class attribute.",
        "java_package": "Forwarded java_package attribute.",
    },
)

def _java_test_capture_impl(ctx):
    return [ToptJavaMacroCaptureInfo(
        data_labels = [str(dep.label) for dep in ctx.attr.data],
        env = dict(ctx.attr.env),
        test_class = ctx.attr.test_class,
        java_package = ctx.attr.java_package,
    )]

_java_test_capture_rule = rule(
    implementation = _java_test_capture_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(),
        "env": attr.string_dict(),
        "test_class": attr.string(),
        "java_package": attr.string(),
        "package": attr.string(),
    },
)

def _has_fragment(items, fragment):
    for item in items:
        if fragment in item:
            return True
    return False

def _has_label_suffix(items, suffix):
    for item in items:
        if item.endswith(suffix):
            return True
    return False

def _single_service_topt_data():
    return {
        "repo_name": "test_optimization_data",
        "service_name": "java-service",
        "manifest_path": ".testoptimization/manifest.txt",
        "labels": [],
        "set": {},
        "runtimes": {
            "go": {
                "module_path": "example.com/stub",
                "sanitized_module_path": "example_com_stub",
                "module_included": False,
            },
            "python": {
                "module_path": "example.python",
                "sanitized_module_path": "example_python",
                "module_included": False,
            },
            "java": {
                "module_path": "com.example",
                "sanitized_module_path": "com_example",
                "module_included": False,
            },
        },
    }

def _multi_service_topt_data():
    selected = _single_service_topt_data()
    not_selected = dict(selected)
    not_selected["repo_name"] = "unused_repo_for_selection_test"
    not_selected["service_name"] = "ruby-service"
    return {
        "java_service": selected,
        "ruby_service": not_selected,
        "_meta": {"description": "non-service entry should be ignored"},
    }

def java_macro_single_service_target(name, tags = None):
    dd_topt_java_test(
        name = name,
        topt_data = _single_service_topt_data(),
        java_test_rule = _java_test_capture_rule,
        data = [":test_macro.bzl"],
        env = {
            "CUSTOM_ENV": "1",
            "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
        },
        test_class = "com.example.tests.SampleTest",
        tags = tags,
    )

def java_macro_multi_service_target(name, tags = None):
    dd_topt_java_test(
        name = name,
        topt_data = _multi_service_topt_data(),
        topt_service = "java-service",
        java_test_rule = _java_test_capture_rule,
        test_class = "com.example.tests.MultiTest",
        tags = tags,
    )

def java_macro_env_none_target(name, tags = None):
    dd_topt_java_test(
        name = name,
        topt_data = _single_service_topt_data(),
        java_test_rule = _java_test_capture_rule,
        env = None,
        tags = tags,
    )

def java_macro_explicit_service_target(name, tags = None):
    dd_topt_java_test(
        name = name,
        topt_data = _single_service_topt_data(),
        java_test_rule = _java_test_capture_rule,
        env = {
            "DD_SERVICE": "caller-service",
        },
        tags = tags,
    )

def java_macro_select_inputs_target(name, tags = None):
    dd_topt_java_test(
        name = name,
        topt_data = _single_service_topt_data(),
        java_test_rule = _java_test_capture_rule,
        data = select({
            "//conditions:default": [":test_macro.bzl"],
        }),
        env = select({
            "//conditions:default": {
                "CUSTOM_ENV": "from_select",
                "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
            },
        }),
        java_package = select({
            "//conditions:default": "com.example.select.pkg",
        }),
        tags = tags,
    )

def _java_macro_single_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptJavaMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":java_macro_single_service_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_optimization_data"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))

    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    asserts.true(env, "test_optimization_data" in manifest_env)
    asserts.true(env, ".testoptimization/manifest.txt" in manifest_env)
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "1", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "java-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "com.example.tests.SampleTest", captured.test_class)
    return analysistest.end(env)

def _java_macro_multi_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptJavaMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":java_macro_multi_service_target_topt_payloads"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_optimization_data"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(env, "java-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "com.example.tests.MultiTest", captured.test_class)
    return analysistest.end(env)

def _java_macro_env_none_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptJavaMacroCaptureInfo]
    asserts.equals(env, None, captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "java-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _java_macro_select_inputs_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptJavaMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":java_macro_select_inputs_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.equals(env, "from_select", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, None, captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "com.example.select.pkg", captured.java_package)
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _java_macro_explicit_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptJavaMacroCaptureInfo]
    asserts.equals(env, "caller-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    return analysistest.end(env)

def _resolve_topt_service_key_missing_target_impl(_ctx):
    resolve_topt_service_key_for_tests(
        {
            "java_service": {"repo_name": "repo_java"},
            "ruby_service": {"repo_name": "repo_ruby"},
        },
        None,
    )
    return []

def _resolve_topt_service_key_unknown_target_impl(_ctx):
    resolve_topt_service_key_for_tests(
        {
            "java_service": {"repo_name": "repo_java"},
            "ruby_service": {"repo_name": "repo_ruby"},
        },
        "python-service",
    )
    return []

def _validate_java_test_rule_missing_target_impl(_ctx):
    validate_java_test_rule_for_tests(None)
    return []

def _select_service_entry_malformed_topt_data_target_impl(_ctx):
    select_service_entry_for_tests("bad-shape", None)
    return []

def _select_service_entry_empty_mapping_target_impl(_ctx):
    select_service_entry_for_tests({"_meta": {"note": "not a service"}}, None)
    return []

resolve_topt_service_key_missing_target_rule = rule(
    implementation = _resolve_topt_service_key_missing_target_impl,
)

resolve_topt_service_key_unknown_target_rule = rule(
    implementation = _resolve_topt_service_key_unknown_target_impl,
)

validate_java_test_rule_missing_target_rule = rule(
    implementation = _validate_java_test_rule_missing_target_impl,
)

select_service_entry_malformed_topt_data_target_rule = rule(
    implementation = _select_service_entry_malformed_topt_data_target_impl,
)

select_service_entry_empty_mapping_target_rule = rule(
    implementation = _select_service_entry_empty_mapping_target_impl,
)

def _resolve_topt_service_key_missing_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "please pass topt_service")
    asserts.expect_failure(env, "java_service, ruby_service")
    return analysistest.end(env)

def _resolve_topt_service_key_unknown_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_service 'python-service' not found")
    asserts.expect_failure(env, "java_service, ruby_service")
    return analysistest.end(env)

def _validate_java_test_rule_missing_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "you must pass java_test_rule")
    return analysistest.end(env)

def _select_service_entry_malformed_topt_data_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_data is required and must be the dict")
    return analysistest.end(env)

def _select_service_entry_empty_mapping_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "did not contain any service entries")
    return analysistest.end(env)

java_macro_single_service_wiring_test = analysistest.make(
    _java_macro_single_service_wiring_test_impl,
)
java_macro_multi_service_wiring_test = analysistest.make(
    _java_macro_multi_service_wiring_test_impl,
)
java_macro_env_none_wiring_test = analysistest.make(
    _java_macro_env_none_wiring_test_impl,
)
java_macro_select_inputs_wiring_test = analysistest.make(
    _java_macro_select_inputs_wiring_test_impl,
)
java_macro_explicit_service_wiring_test = analysistest.make(
    _java_macro_explicit_service_wiring_test_impl,
)
resolve_topt_service_key_missing_failure_test = analysistest.make(
    _resolve_topt_service_key_missing_failure_test_impl,
    expect_failure = True,
)
resolve_topt_service_key_unknown_failure_test = analysistest.make(
    _resolve_topt_service_key_unknown_failure_test_impl,
    expect_failure = True,
)
validate_java_test_rule_missing_failure_test = analysistest.make(
    _validate_java_test_rule_missing_failure_test_impl,
    expect_failure = True,
)
select_service_entry_malformed_topt_data_failure_test = analysistest.make(
    _select_service_entry_malformed_topt_data_failure_test_impl,
    expect_failure = True,
)
select_service_entry_empty_mapping_failure_test = analysistest.make(
    _select_service_entry_empty_mapping_failure_test_impl,
    expect_failure = True,
)
