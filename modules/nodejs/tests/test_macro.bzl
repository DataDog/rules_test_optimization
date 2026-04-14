"""Analysis tests for dd_topt_nodejs_test macro wiring."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@datadog-rules-test-optimization-nodejs//:topt_nodejs_test.bzl",
    "dd_topt_nodejs_test",
    "resolve_topt_service_key_for_tests",
    "select_service_entry_for_tests",
    "validate_nodejs_test_rule_for_tests",
)

ToptNodejsMacroCaptureInfo = provider(
    doc = "Captured arguments forwarded by dd_topt_nodejs_test to nodejs_test_rule.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "env": "Forwarded environment map.",
        "package_name": "Forwarded package_name attribute.",
        "entry_point": "Forwarded entry_point attribute.",
    },
)

def _nodejs_test_capture_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(out, "#!/bin/sh\nexit 0\n", is_executable = True)
    return [
        DefaultInfo(
            files = depset([out]),
            runfiles = ctx.runfiles(files = [out]),
            executable = out,
        ),
        RunEnvironmentInfo(environment = dict(ctx.attr.env)),
        ToptNodejsMacroCaptureInfo(
            data_labels = [str(dep.label) for dep in ctx.attr.data],
            env = dict(ctx.attr.env),
            package_name = ctx.attr.package_name,
            entry_point = ctx.attr.entry_point,
        ),
    ]

_nodejs_test_capture_rule = rule(
    implementation = _nodejs_test_capture_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(),
        "env": attr.string_dict(),
        "package_name": attr.string(),
        "module_name": attr.string(),
        "npm_package": attr.string(),
        "entry_point": attr.string(),
    },
    executable = True,
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

def _has_file_basename(items, basename):
    for item in items:
        if item.basename == basename:
            return True
    return False

def _single_service_topt_data():
    return {
        "repo_name": "test_optimization_data",
        "service_name": "nodejs-service",
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
                "module_path": "packages/nodejs",
                "sanitized_module_path": "packages_nodejs",
                "module_included": False,
            },
            "dotnet": {
                "module_path": "Company.Product.Stub",
                "sanitized_module_path": "company_product_stub",
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
    not_selected["service_name"] = "ruby-service"
    return {
        "nodejs_service": selected,
        "ruby_service": not_selected,
        "_meta": {"description": "non-service entry should be ignored"},
    }

def nodejs_macro_single_service_target(name, tags = None):
    dd_topt_nodejs_test(
        name = name,
        topt_data = _single_service_topt_data(),
        nodejs_test_rule = _nodejs_test_capture_rule,
        data = [":test_macro.bzl"],
        env = {
            "CUSTOM_ENV": "1",
            "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
        },
        package_name = "packages/nodejs/pkg",
        entry_point = "src/index.test.js",
        tags = tags,
    )

def nodejs_macro_multi_service_target(name, tags = None):
    dd_topt_nodejs_test(
        name = name,
        topt_data = _multi_service_topt_data(),
        topt_service = "nodejs-service",
        nodejs_test_rule = _nodejs_test_capture_rule,
        package_name = "packages/nodejs/multi",
        entry_point = "src/multi.test.js",
        tags = tags,
    )

def nodejs_macro_env_none_target(name, tags = None):
    dd_topt_nodejs_test(
        name = name,
        topt_data = _single_service_topt_data(),
        nodejs_test_rule = _nodejs_test_capture_rule,
        env = None,
        tags = tags,
    )

def nodejs_macro_explicit_service_target(name, tags = None):
    dd_topt_nodejs_test(
        name = name,
        topt_data = _single_service_topt_data(),
        nodejs_test_rule = _nodejs_test_capture_rule,
        env = {
            "DD_SERVICE": "caller-service",
        },
        tags = tags,
    )

def nodejs_macro_select_inputs_target(name, tags = None):
    dd_topt_nodejs_test(
        name = name,
        topt_data = _single_service_topt_data(),
        nodejs_test_rule = _nodejs_test_capture_rule,
        data = select({
            "//conditions:default": [":test_macro.bzl"],
        }),
        env = select({
            "//conditions:default": {
                "CUSTOM_ENV": "from_select",
                "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
            },
        }),
        package_name = select({
            "//conditions:default": "packages/nodejs/select/pkg",
        }),
        tags = tags,
    )

def _nodejs_macro_single_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptNodejsMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":nodejs_macro_single_service_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_optimization_data"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))

    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    asserts.true(env, "test_optimization_data" in manifest_env)
    asserts.true(env, ".testoptimization/manifest.txt" in manifest_env)
    asserts.equals(
        env,
        "nodejs_macro_single_service_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "1", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "nodejs-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "packages/nodejs/pkg", captured.package_name)
    asserts.equals(env, "src/index.test.js", captured.entry_point)
    return analysistest.end(env)

def _nodejs_macro_multi_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptNodejsMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":nodejs_macro_multi_service_target_topt_payloads"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_optimization_data"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(
        env,
        "nodejs_macro_multi_service_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "nodejs-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "packages/nodejs/multi", captured.package_name)
    asserts.equals(env, "src/multi.test.js", captured.entry_point)
    return analysistest.end(env)

def _nodejs_macro_env_none_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptNodejsMacroCaptureInfo]
    asserts.equals(env, None, captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "nodejs-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "nodejs_macro_env_none_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _nodejs_macro_select_inputs_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptNodejsMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":nodejs_macro_select_inputs_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.equals(env, "from_select", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, None, captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "nodejs_macro_select_inputs_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "packages/nodejs/select/pkg", captured.package_name)
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _nodejs_macro_explicit_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptNodejsMacroCaptureInfo]
    asserts.equals(env, "caller-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "nodejs_macro_explicit_service_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    return analysistest.end(env)

def _nodejs_macro_public_wrapper_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    asserts.equals(env, 2, len(files))
    asserts.true(env, _has_file_basename(files, "nodejs_macro_single_service_target"))
    asserts.true(
        env,
        _has_file_basename(
            files,
            "nodejs_macro_single_service_target__wrapped_nodejs_macro_single_service_target__raw_nodejs_test.sh",
        ),
    )
    run_env = target[RunEnvironmentInfo].environment
    manifest_env = run_env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    asserts.equals(
        env,
        "nodejs_macro_single_service_target_topt_bazel_metadata.json",
        run_env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "true", run_env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "1", run_env.get("CUSTOM_ENV"))
    return analysistest.end(env)

def _resolve_topt_service_key_missing_target_impl(_ctx):
    resolve_topt_service_key_for_tests(
        {
            "nodejs_service": {"repo_name": "repo_nodejs"},
            "ruby_service": {"repo_name": "repo_ruby"},
        },
        None,
    )
    return []

def _resolve_topt_service_key_unknown_target_impl(_ctx):
    resolve_topt_service_key_for_tests(
        {
            "nodejs_service": {"repo_name": "repo_nodejs"},
            "ruby_service": {"repo_name": "repo_ruby"},
        },
        "dotnet-service",
    )
    return []

def _validate_nodejs_test_rule_missing_target_impl(_ctx):
    validate_nodejs_test_rule_for_tests(None)
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

validate_nodejs_test_rule_missing_target_rule = rule(
    implementation = _validate_nodejs_test_rule_missing_target_impl,
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

def _validate_nodejs_test_rule_missing_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "you must pass nodejs_test_rule")
    return analysistest.end(env)

def _select_service_entry_malformed_topt_data_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_data is required and must be the dict")
    return analysistest.end(env)

def _select_service_entry_empty_mapping_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "did not contain any service entries")
    return analysistest.end(env)

nodejs_macro_single_service_wiring_test = analysistest.make(
    _nodejs_macro_single_service_wiring_test_impl,
)
nodejs_macro_multi_service_wiring_test = analysistest.make(
    _nodejs_macro_multi_service_wiring_test_impl,
)
nodejs_macro_env_none_wiring_test = analysistest.make(
    _nodejs_macro_env_none_wiring_test_impl,
)
nodejs_macro_select_inputs_wiring_test = analysistest.make(
    _nodejs_macro_select_inputs_wiring_test_impl,
)
nodejs_macro_explicit_service_wiring_test = analysistest.make(
    _nodejs_macro_explicit_service_wiring_test_impl,
)
nodejs_macro_public_wrapper_test = analysistest.make(
    _nodejs_macro_public_wrapper_test_impl,
)
resolve_topt_service_key_missing_failure_test = analysistest.make(
    _resolve_topt_service_key_missing_failure_test_impl,
    expect_failure = True,
)
resolve_topt_service_key_unknown_failure_test = analysistest.make(
    _resolve_topt_service_key_unknown_failure_test_impl,
    expect_failure = True,
)
validate_nodejs_test_rule_missing_failure_test = analysistest.make(
    _validate_nodejs_test_rule_missing_failure_test_impl,
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
