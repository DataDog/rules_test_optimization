"""Analysis tests for dd_topt_py_test macro wiring."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@datadog-rules-test-optimization-python//:topt_py_test.bzl",
    "dd_topt_py_test",
    "resolve_topt_service_key_for_tests",
    "select_service_entry_for_tests",
    "validate_py_test_rule_for_tests",
)

ToptPyMacroCaptureInfo = provider(
    doc = "Captured arguments forwarded by dd_topt_py_test to py_test_rule.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "env": "Forwarded environment map.",
        "imports": "Forwarded imports attribute.",
        "importpath": "Forwarded importpath attribute.",
    },
)

def _py_test_capture_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(out, "#!/bin/sh\nexit 0\n", is_executable = True)
    return [
        DefaultInfo(
            files = depset([out]),
            runfiles = ctx.runfiles(files = [out]),
            executable = out,
        ),
        RunEnvironmentInfo(environment = dict(ctx.attr.env)),
        ToptPyMacroCaptureInfo(
            data_labels = [str(dep.label) for dep in ctx.attr.data],
            env = dict(ctx.attr.env),
            imports = list(ctx.attr.imports),
            importpath = ctx.attr.importpath,
        ),
    ]

_py_test_capture_rule = rule(
    implementation = _py_test_capture_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(),
        "env": attr.string_dict(),
        "imports": attr.string_list(),
        "importpath": attr.string(),
        "module_path": attr.string(),
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
        "service_name": "py-service",
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
        "py_service": selected,
        "ruby_service": not_selected,
        "_meta": {"description": "non-service entry should be ignored"},
    }

def py_macro_single_service_target(name, tags = None):
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_capture_rule,
        data = [":test_macro.bzl"],
        env = {
            "CUSTOM_ENV": "1",
            "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
        },
        imports = ["example/python/pkg"],
        tags = tags,
    )

def py_macro_multi_service_target(name, tags = None):
    dd_topt_py_test(
        name = name,
        topt_data = _multi_service_topt_data(),
        topt_service = "py-service",
        py_test_rule = _py_test_capture_rule,
        imports = ["example/python/multi"],
        tags = tags,
    )

def py_macro_env_none_target(name, tags = None):
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_capture_rule,
        env = None,
        tags = tags,
    )

def py_macro_explicit_service_target(name, tags = None):
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_capture_rule,
        env = {
            "DD_SERVICE": "caller-service",
        },
        tags = tags,
    )

def py_macro_select_inputs_target(name, tags = None):
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_capture_rule,
        data = select({
            "//conditions:default": [":test_macro.bzl"],
        }),
        env = select({
            "//conditions:default": {
                "CUSTOM_ENV": "from_select",
                "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
            },
        }),
        importpath = select({
            "//conditions:default": "example/python/select/pkg",
        }),
        tags = tags,
    )

def _py_macro_single_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":py_macro_single_service_target_topt_payloads"))
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
        "py_macro_single_service_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "1", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "py-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, ["example/python/pkg"], captured.imports)
    return analysistest.end(env)

def _py_macro_multi_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":py_macro_multi_service_target_topt_payloads"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_optimization_data"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(
        env,
        "py_macro_multi_service_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "py-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, ["example/python/multi"], captured.imports)
    return analysistest.end(env)

def _py_macro_env_none_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyMacroCaptureInfo]
    asserts.equals(env, None, captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "py-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "py_macro_env_none_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _py_macro_select_inputs_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":py_macro_select_inputs_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.equals(env, "from_select", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, None, captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "py_macro_select_inputs_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "example/python/select/pkg", captured.importpath)
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _py_macro_explicit_service_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyMacroCaptureInfo]
    asserts.equals(env, "caller-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "py_macro_explicit_service_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    return analysistest.end(env)

def _py_macro_public_wrapper_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(files))
    asserts.true(env, _has_file_basename(files, "py_macro_single_service_target"))
    run_env = target[RunEnvironmentInfo].environment
    manifest_env = run_env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    asserts.equals(
        env,
        "py_macro_single_service_target_topt_bazel_metadata.json",
        run_env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "true", run_env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "1", run_env.get("CUSTOM_ENV"))
    return analysistest.end(env)

def _resolve_topt_service_key_missing_target_impl(_ctx):
    resolve_topt_service_key_for_tests(
        {
            "py_service": {"repo_name": "repo_py"},
            "ruby_service": {"repo_name": "repo_ruby"},
        },
        None,
    )
    return []

def _resolve_topt_service_key_unknown_target_impl(_ctx):
    resolve_topt_service_key_for_tests(
        {
            "py_service": {"repo_name": "repo_py"},
            "ruby_service": {"repo_name": "repo_ruby"},
        },
        "java-service",
    )
    return []

def _validate_py_test_rule_missing_target_impl(_ctx):
    validate_py_test_rule_for_tests(None)
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

validate_py_test_rule_missing_target_rule = rule(
    implementation = _validate_py_test_rule_missing_target_impl,
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
    asserts.expect_failure(env, "py_service, ruby_service")
    return analysistest.end(env)

def _resolve_topt_service_key_unknown_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_service 'java-service' not found")
    asserts.expect_failure(env, "py_service, ruby_service")
    return analysistest.end(env)

def _validate_py_test_rule_missing_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "you must pass py_test_rule")
    return analysistest.end(env)

def _select_service_entry_malformed_topt_data_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_data is required and must be the dict")
    return analysistest.end(env)

def _select_service_entry_empty_mapping_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "did not contain any service entries")
    return analysistest.end(env)

py_macro_single_service_wiring_test = analysistest.make(
    _py_macro_single_service_wiring_test_impl,
)
py_macro_multi_service_wiring_test = analysistest.make(
    _py_macro_multi_service_wiring_test_impl,
)
py_macro_env_none_wiring_test = analysistest.make(
    _py_macro_env_none_wiring_test_impl,
)
py_macro_select_inputs_wiring_test = analysistest.make(
    _py_macro_select_inputs_wiring_test_impl,
)
py_macro_explicit_service_wiring_test = analysistest.make(
    _py_macro_explicit_service_wiring_test_impl,
)
py_macro_public_wrapper_test = analysistest.make(
    _py_macro_public_wrapper_test_impl,
)
resolve_topt_service_key_missing_failure_test = analysistest.make(
    _resolve_topt_service_key_missing_failure_test_impl,
    expect_failure = True,
)
resolve_topt_service_key_unknown_failure_test = analysistest.make(
    _resolve_topt_service_key_unknown_failure_test_impl,
    expect_failure = True,
)
validate_py_test_rule_missing_failure_test = analysistest.make(
    _validate_py_test_rule_missing_failure_test_impl,
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
