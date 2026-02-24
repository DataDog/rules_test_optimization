"""Analysis tests for dd_topt_dotnet_test macro wiring."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@datadog-rules-test-optimization-dotnet//:topt_dotnet_test.bzl",
    "dd_topt_dotnet_test",
    "resolve_topt_service_key_for_tests",
    "select_service_entry_for_tests",
    "validate_dotnet_test_rule_for_tests",
)

ToptDotnetMacroCaptureInfo = provider(
    doc = "Captured arguments forwarded by dd_topt_dotnet_test to dotnet_test_rule.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "env": "Forwarded environment map.",
        "root_namespace": "Forwarded root_namespace attribute.",
        "test_class": "Forwarded test_class attribute.",
    },
)

def _dotnet_test_capture_impl(ctx):
    return [ToptDotnetMacroCaptureInfo(
        data_labels = [str(dep.label) for dep in ctx.attr.data],
        env = dict(ctx.attr.env),
        root_namespace = ctx.attr.root_namespace,
        test_class = ctx.attr.test_class,
    )]

_dotnet_test_capture_rule = rule(
    implementation = _dotnet_test_capture_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(),
        "env": attr.string_dict(),
        "root_namespace": attr.string(),
        "assembly_name": attr.string(),
        "project_name": attr.string(),
        "test_class": attr.string(),
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
                "module_path": "example.python.stub",
                "sanitized_module_path": "example_python_stub",
                "module_included": False,
            },
            "java": {
                "module_path": "com.example.stub",
                "sanitized_module_path": "com_example_stub",
                "module_included": False,
            },
            "nodejs": {
                "module_path": "packages/stub",
                "sanitized_module_path": "packages_stub",
                "module_included": False,
            },
            "dotnet": {
                "module_path": "Company.Product",
                "sanitized_module_path": "company_product",
                "module_included": False,
            },
            "ruby": {
                "module_path": "apps/stub",
                "sanitized_module_path": "apps_stub",
                "module_included": False,
            },
        },
    }

def _multi_service_topt_data():
    selected = _single_service_topt_data()
    not_selected = dict(selected)
    not_selected["repo_name"] = "unused_repo_for_selection_test"
    return {
        "dotnet_service": selected,
        "ruby_service": not_selected,
        "_meta": {"description": "non-service entry should be ignored"},
    }

def dotnet_macro_single_service_target(name, tags = None):
    dd_topt_dotnet_test(
        name = name,
        topt_data = _single_service_topt_data(),
        dotnet_test_rule = _dotnet_test_capture_rule,
        data = [":test_macro.bzl"],
        env = {
            "CUSTOM_ENV": "1",
            "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
        },
        root_namespace = "Company.Product.Tests",
        test_class = "Company.Product.Tests.SampleTest",
        tags = tags,
    )

def dotnet_macro_multi_service_target(name, tags = None):
    dd_topt_dotnet_test(
        name = name,
        topt_data = _multi_service_topt_data(),
        topt_service = "dotnet-service",
        dotnet_test_rule = _dotnet_test_capture_rule,
        root_namespace = "Company.Product.Multi",
        test_class = "Company.Product.Multi.MultiTest",
        tags = tags,
    )

def dotnet_macro_env_none_target(name, tags = None):
    dd_topt_dotnet_test(
        name = name,
        topt_data = _single_service_topt_data(),
        dotnet_test_rule = _dotnet_test_capture_rule,
        env = None,
        tags = tags,
    )

def _dotnet_macro_single_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptDotnetMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":dotnet_macro_single_service_target_topt_payloads"))
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
    asserts.equals(env, "Company.Product.Tests", captured.root_namespace)
    asserts.equals(env, "Company.Product.Tests.SampleTest", captured.test_class)
    return analysistest.end(env)

def _dotnet_macro_multi_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptDotnetMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":dotnet_macro_multi_service_target_topt_payloads"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_optimization_data"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(env, "Company.Product.Multi", captured.root_namespace)
    asserts.equals(env, "Company.Product.Multi.MultiTest", captured.test_class)
    return analysistest.end(env)

def _dotnet_macro_env_none_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptDotnetMacroCaptureInfo]
    asserts.equals(env, None, captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _resolve_topt_service_key_missing_target_impl(_ctx):
    resolve_topt_service_key_for_tests(
        {
            "dotnet_service": {"repo_name": "repo_dotnet"},
            "ruby_service": {"repo_name": "repo_ruby"},
        },
        None,
    )
    return []

def _resolve_topt_service_key_unknown_target_impl(_ctx):
    resolve_topt_service_key_for_tests(
        {
            "dotnet_service": {"repo_name": "repo_dotnet"},
            "ruby_service": {"repo_name": "repo_ruby"},
        },
        "python-service",
    )
    return []

def _validate_dotnet_test_rule_missing_target_impl(_ctx):
    validate_dotnet_test_rule_for_tests(None)
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

validate_dotnet_test_rule_missing_target_rule = rule(
    implementation = _validate_dotnet_test_rule_missing_target_impl,
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
    asserts.expect_failure(env, "dotnet_service, ruby_service")
    return analysistest.end(env)

def _resolve_topt_service_key_unknown_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_service 'python-service' not found")
    asserts.expect_failure(env, "dotnet_service, ruby_service")
    return analysistest.end(env)

def _validate_dotnet_test_rule_missing_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "you must pass dotnet_test_rule")
    return analysistest.end(env)

def _select_service_entry_malformed_topt_data_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_data is required and must be the dict")
    return analysistest.end(env)

def _select_service_entry_empty_mapping_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "did not contain any service entries")
    return analysistest.end(env)

dotnet_macro_single_service_wiring_test = analysistest.make(
    _dotnet_macro_single_service_wiring_test_impl,
)
dotnet_macro_multi_service_wiring_test = analysistest.make(
    _dotnet_macro_multi_service_wiring_test_impl,
)
dotnet_macro_env_none_wiring_test = analysistest.make(
    _dotnet_macro_env_none_wiring_test_impl,
)
resolve_topt_service_key_missing_failure_test = analysistest.make(
    _resolve_topt_service_key_missing_failure_test_impl,
    expect_failure = True,
)
resolve_topt_service_key_unknown_failure_test = analysistest.make(
    _resolve_topt_service_key_unknown_failure_test_impl,
    expect_failure = True,
)
validate_dotnet_test_rule_missing_failure_test = analysistest.make(
    _validate_dotnet_test_rule_missing_failure_test_impl,
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
