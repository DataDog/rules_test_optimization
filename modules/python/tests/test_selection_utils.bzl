"""Unit tests for Python-specific selection and macro helper functions."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "@datadog-rules-test-optimization-python//:topt_py_infer.bzl",
    "normalize_python_identifier_for_tests",
    "select_module_group_name_for_tests",
)
load(
    "@datadog-rules-test-optimization-python//:topt_py_test.bzl",
    "build_module_labels_for_tests",
    "normalize_user_data_for_tests",
    "resolve_topt_service_key_for_tests",
    "service_mapping_entries_for_tests",
)
load(
    "@datadog-rules-test-optimization-python//tests:example_stub_repo.bzl",
    "render_stub_build_for_tests",
)

def _service_mapping_entries_filters_non_service_test(ctx):
    env = unittest.begin(ctx)
    entries = service_mapping_entries_for_tests({
        "py_service": {"repo_name": "repo_py"},
        "ruby_service": {"repo_name": "repo_ruby"},
        "_meta": {"note": "non-service metadata"},
    })
    asserts.equals(env, 2, len(entries))
    asserts.equals(env, "repo_py", entries["py_service"]["repo_name"])
    asserts.equals(env, "repo_ruby", entries["ruby_service"]["repo_name"])
    return unittest.end(env)

def _resolve_topt_service_key_prefers_exact_then_sanitized_test(ctx):
    env = unittest.begin(ctx)
    entries = {
        "py_service": {"repo_name": "repo_py"},
        "py_service_2": {"repo_name": "repo_py_2"},
    }
    asserts.equals(env, "py_service_2", resolve_topt_service_key_for_tests(entries, "py_service_2"))
    asserts.equals(env, "py_service", resolve_topt_service_key_for_tests(entries, "py-service"))
    return unittest.end(env)

def _select_module_group_name_test(ctx):
    env = unittest.begin(ctx)
    groups = [
        "module_example_python_mod_pkg",
        "module_custom_override",
    ]
    asserts.equals(
        env,
        "module_example_python_mod_pkg",
        select_module_group_name_for_tests("example.python.mod.pkg", groups, True),
    )
    asserts.equals(
        env,
        "module_custom_override",
        select_module_group_name_for_tests("example.python.mod.pkg", groups, True, "custom_override"),
    )
    asserts.equals(
        env,
        "",
        select_module_group_name_for_tests("example.python.mod.pkg", groups, False),
    )
    asserts.equals(
        env,
        "",
        select_module_group_name_for_tests("example.python.other", groups, True),
    )
    return unittest.end(env)

def _normalize_python_identifier_edge_cases_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "pkg.sub.mod", normalize_python_identifier_for_tests(" pkg/sub\\mod "))
    asserts.equals(env, "pkg.sub.mod", normalize_python_identifier_for_tests("pkg..sub....mod"))
    asserts.equals(env, "leading.trailing", normalize_python_identifier_for_tests("/leading/trailing/"))
    asserts.equals(env, "", normalize_python_identifier_for_tests("...."))
    asserts.equals(env, "", normalize_python_identifier_for_tests(None))
    return unittest.end(env)

def _normalize_user_data_handles_none_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], normalize_user_data_for_tests(None))
    asserts.equals(env, [":a", ":b"], normalize_user_data_for_tests([":a", ":b"]))
    asserts.equals(env, [":x", ":y"], normalize_user_data_for_tests((":x", ":y")))
    asserts.equals(env, [":single"], normalize_user_data_for_tests(":single"))
    return unittest.end(env)

def _build_module_labels_valid_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], build_module_labels_for_tests("repo_name", None))
    asserts.equals(env, [], build_module_labels_for_tests("repo_name", []))
    asserts.equals(
        env,
        [
            "@repo_name//:module_mod_a",
            "@repo_name//:module_mod_b",
        ],
        build_module_labels_for_tests("repo_name", ["mod_a", "mod_b"]),
    )
    return unittest.end(env)

def _py_stub_includes_manifest_in_files_test(ctx):
    env = unittest.begin(ctx)
    settings = ".testoptimization/cache/http/settings.json"
    manifest = ".testoptimization/manifest.txt"
    known_tests = ".testoptimization/cache/http/known_tests.json"
    test_management = ".testoptimization/cache/http/test_management.json"
    context = ".testoptimization/context.json"
    telemetry_facts = ".testoptimization/telemetry_facts.json"

    content = render_stub_build_for_tests(
        settings,
        manifest,
        known_tests,
        test_management,
        context,
        telemetry_facts,
    )
    filegroup_start = content.find('name = "test_optimization_files"')
    context_group_start = content.find('name = "test_optimization_context"')
    asserts.true(env, filegroup_start >= 0)
    asserts.true(env, context_group_start > filegroup_start)
    filegroup_block = content[filegroup_start:context_group_start]
    asserts.true(env, settings in filegroup_block)
    asserts.true(env, manifest in filegroup_block)
    asserts.true(env, known_tests in filegroup_block)
    asserts.true(env, test_management in filegroup_block)
    return unittest.end(env)

def _build_module_labels_invalid_shape_target_impl(_ctx):
    build_module_labels_for_tests("repo_name", "mod_a")
    return []

def _build_module_labels_invalid_entry_target_impl(_ctx):
    build_module_labels_for_tests("repo_name", ["mod_a", 7])
    return []

def _build_module_labels_empty_entry_target_impl(_ctx):
    build_module_labels_for_tests("repo_name", [""])
    return []

def _build_module_labels_unsanitized_entry_target_impl(_ctx):
    build_module_labels_for_tests("repo_name", ["mod-a"])
    return []

def _normalize_user_data_invalid_type_target_impl(_ctx):
    normalize_user_data_for_tests({"bad": "shape"})
    return []

build_module_labels_invalid_shape_target_rule = rule(
    implementation = _build_module_labels_invalid_shape_target_impl,
)

build_module_labels_invalid_entry_target_rule = rule(
    implementation = _build_module_labels_invalid_entry_target_impl,
)

build_module_labels_empty_entry_target_rule = rule(
    implementation = _build_module_labels_empty_entry_target_impl,
)

build_module_labels_unsanitized_entry_target_rule = rule(
    implementation = _build_module_labels_unsanitized_entry_target_impl,
)

normalize_user_data_invalid_type_target_rule = rule(
    implementation = _normalize_user_data_invalid_type_target_impl,
)

def _build_module_labels_invalid_shape_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_data['labels'] must be a list or tuple")
    return analysistest.end(env)

def _build_module_labels_invalid_entry_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_data['labels'] entries must be strings")
    return analysistest.end(env)

def _build_module_labels_empty_entry_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_data['labels'] entries must be non-empty")
    return analysistest.end(env)

def _build_module_labels_unsanitized_entry_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_data['labels'] entries must be sanitized")
    return analysistest.end(env)

def _normalize_user_data_invalid_type_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "normalize_user_data: expected None, string, list, tuple, or select")
    return analysistest.end(env)

service_mapping_entries_filters_non_service_test = unittest.make(_service_mapping_entries_filters_non_service_test)
resolve_topt_service_key_prefers_exact_then_sanitized_test = unittest.make(_resolve_topt_service_key_prefers_exact_then_sanitized_test)
select_module_group_name_test = unittest.make(_select_module_group_name_test)
normalize_python_identifier_edge_cases_test = unittest.make(_normalize_python_identifier_edge_cases_test)
normalize_user_data_handles_none_test = unittest.make(_normalize_user_data_handles_none_test)
build_module_labels_valid_test = unittest.make(_build_module_labels_valid_test)
py_stub_includes_manifest_in_files_test = unittest.make(_py_stub_includes_manifest_in_files_test)
build_module_labels_invalid_shape_failure_test = analysistest.make(
    _build_module_labels_invalid_shape_failure_test_impl,
    expect_failure = True,
)
build_module_labels_invalid_entry_failure_test = analysistest.make(
    _build_module_labels_invalid_entry_failure_test_impl,
    expect_failure = True,
)
build_module_labels_empty_entry_failure_test = analysistest.make(
    _build_module_labels_empty_entry_failure_test_impl,
    expect_failure = True,
)
build_module_labels_unsanitized_entry_failure_test = analysistest.make(
    _build_module_labels_unsanitized_entry_failure_test_impl,
    expect_failure = True,
)
normalize_user_data_invalid_type_failure_test = analysistest.make(
    _normalize_user_data_invalid_type_failure_test_impl,
    expect_failure = True,
)
