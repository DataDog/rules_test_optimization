"""Analysis tests for dd_topt_ruby_test macro wiring."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@datadog-rules-test-optimization-ruby//:topt_ruby_test.bzl",
    "dd_topt_ruby_test",
    "resolve_topt_service_key_for_tests",
    "select_service_entry_for_tests",
    "validate_ruby_test_rule_for_tests",
)

ToptRubyMacroCaptureInfo = provider(
    doc = "Captured arguments forwarded by dd_topt_ruby_test to ruby_test_rule.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "env": "Forwarded environment map.",
        "require_path": "Forwarded require_path attribute.",
        "main": "Forwarded main attribute.",
    },
)

def _ruby_test_capture_impl(ctx):
    return [ToptRubyMacroCaptureInfo(
        data_labels = [str(dep.label) for dep in ctx.attr.data],
        env = dict(ctx.attr.env),
        require_path = ctx.attr.require_path,
        main = ctx.attr.main,
    )]

_ruby_test_capture_rule = rule(
    implementation = _ruby_test_capture_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(),
        "env": attr.string_dict(),
        "require_path": attr.string(),
        "gem_name": attr.string(),
        "library_name": attr.string(),
        "main": attr.string(),
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
                "module_path": "Company.Product.Stub",
                "sanitized_module_path": "company_product_stub",
                "module_included": False,
            },
            "ruby": {
                "module_path": "apps/ruby",
                "sanitized_module_path": "apps_ruby",
                "module_included": False,
            },
        },
    }

def _multi_service_topt_data():
    selected = _single_service_topt_data()
    not_selected = dict(selected)
    not_selected["repo_name"] = "unused_repo_for_selection_test"
    return {
        "ruby_service": selected,
        "nodejs_service": not_selected,
        "_meta": {"description": "non-service entry should be ignored"},
    }

def ruby_macro_single_service_target(name, tags = None):
    dd_topt_ruby_test(
        name = name,
        topt_data = _single_service_topt_data(),
        ruby_test_rule = _ruby_test_capture_rule,
        data = [":test_macro.bzl"],
        env = {
            "CUSTOM_ENV": "1",
            "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
        },
        require_path = "apps/ruby/pkg",
        main = "spec/pkg_spec.rb",
        tags = tags,
    )

def ruby_macro_multi_service_target(name, tags = None):
    dd_topt_ruby_test(
        name = name,
        topt_data = _multi_service_topt_data(),
        topt_service = "ruby-service",
        ruby_test_rule = _ruby_test_capture_rule,
        require_path = "apps/ruby/multi",
        main = "spec/multi_spec.rb",
        tags = tags,
    )

def ruby_macro_env_none_target(name, tags = None):
    dd_topt_ruby_test(
        name = name,
        topt_data = _single_service_topt_data(),
        ruby_test_rule = _ruby_test_capture_rule,
        env = None,
        tags = tags,
    )

def ruby_macro_select_inputs_target(name, tags = None):
    dd_topt_ruby_test(
        name = name,
        topt_data = _single_service_topt_data(),
        ruby_test_rule = _ruby_test_capture_rule,
        data = select({
            "//conditions:default": [":test_macro.bzl"],
        }),
        env = select({
            "//conditions:default": {
                "CUSTOM_ENV": "from_select",
                "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
            },
        }),
        require_path = select({
            "//conditions:default": "apps/ruby/select/pkg",
        }),
        tags = tags,
    )

def _ruby_macro_single_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptRubyMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":ruby_macro_single_service_target_topt_payloads"))
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
    asserts.equals(env, "apps/ruby/pkg", captured.require_path)
    asserts.equals(env, "spec/pkg_spec.rb", captured.main)
    return analysistest.end(env)

def _ruby_macro_multi_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptRubyMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":ruby_macro_multi_service_target_topt_payloads"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_optimization_data"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(env, "apps/ruby/multi", captured.require_path)
    asserts.equals(env, "spec/multi_spec.rb", captured.main)
    return analysistest.end(env)

def _ruby_macro_env_none_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptRubyMacroCaptureInfo]
    asserts.equals(env, None, captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _ruby_macro_select_inputs_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptRubyMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":ruby_macro_select_inputs_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.equals(env, "from_select", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "apps/ruby/select/pkg", captured.require_path)
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _resolve_topt_service_key_missing_target_impl(_ctx):
    resolve_topt_service_key_for_tests(
        {
            "ruby_service": {"repo_name": "repo_ruby"},
            "nodejs_service": {"repo_name": "repo_nodejs"},
        },
        None,
    )
    return []

def _resolve_topt_service_key_unknown_target_impl(_ctx):
    resolve_topt_service_key_for_tests(
        {
            "ruby_service": {"repo_name": "repo_ruby"},
            "nodejs_service": {"repo_name": "repo_nodejs"},
        },
        "dotnet-service",
    )
    return []

def _validate_ruby_test_rule_missing_target_impl(_ctx):
    validate_ruby_test_rule_for_tests(None)
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

validate_ruby_test_rule_missing_target_rule = rule(
    implementation = _validate_ruby_test_rule_missing_target_impl,
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
    asserts.expect_failure(env, "nodejs_service, ruby_service")
    return analysistest.end(env)

def _resolve_topt_service_key_unknown_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_service 'dotnet-service' not found")
    asserts.expect_failure(env, "nodejs_service, ruby_service")
    return analysistest.end(env)

def _validate_ruby_test_rule_missing_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "you must pass ruby_test_rule")
    return analysistest.end(env)

def _select_service_entry_malformed_topt_data_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_data is required and must be the dict")
    return analysistest.end(env)

def _select_service_entry_empty_mapping_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "did not contain any service entries")
    return analysistest.end(env)

ruby_macro_single_service_wiring_test = analysistest.make(
    _ruby_macro_single_service_wiring_test_impl,
)
ruby_macro_multi_service_wiring_test = analysistest.make(
    _ruby_macro_multi_service_wiring_test_impl,
)
ruby_macro_env_none_wiring_test = analysistest.make(
    _ruby_macro_env_none_wiring_test_impl,
)
ruby_macro_select_inputs_wiring_test = analysistest.make(
    _ruby_macro_select_inputs_wiring_test_impl,
)
resolve_topt_service_key_missing_failure_test = analysistest.make(
    _resolve_topt_service_key_missing_failure_test_impl,
    expect_failure = True,
)
resolve_topt_service_key_unknown_failure_test = analysistest.make(
    _resolve_topt_service_key_unknown_failure_test_impl,
    expect_failure = True,
)
validate_ruby_test_rule_missing_failure_test = analysistest.make(
    _validate_ruby_test_rule_missing_failure_test_impl,
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
