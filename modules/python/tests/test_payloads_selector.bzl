# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Analysis tests for topt_py_payloads_selector selection behavior."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@datadog-rules-test-optimization-python//:topt_py_infer.bzl", "topt_py_payloads_selector")

_COMMON_MODULE_GROUPS = [
    ":module_example_python_explicit_pkg",
    ":module_example_python_imports_pkg",
    ":module_example_python_deps_pkg",
    ":module_example_python_attr_pkg",
    ":module_example_python_fallback_pkg",
    ":module_custom_override",
]

def _payload_marker_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".payload")
    ctx.actions.write(out, ctx.attr.marker + "\n")
    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]),
    )]

_payload_marker = rule(
    implementation = _payload_marker_impl,
    attrs = {
        "marker": attr.string(mandatory = True),
    },
)

def _cache_payload_impl(ctx):
    manifest = ctx.actions.declare_file(ctx.label.name + "/.testoptimization/manifest.txt")
    settings = ctx.actions.declare_file(ctx.label.name + "/.testoptimization/cache/http/settings.json")
    known_tests = ctx.actions.declare_file(ctx.label.name + "/.testoptimization/module_selected/cache/http/known_tests.json")
    test_management = ctx.actions.declare_file(ctx.label.name + "/.testoptimization/module_selected/cache/http/test_management.json")
    flaky_tests = ctx.actions.declare_file(ctx.label.name + "/.testoptimization/module_selected/cache/http/flaky_tests.json")
    files = [manifest, settings, known_tests, test_management, flaky_tests]
    for file in files:
        ctx.actions.write(file, "{}\n")
    return [DefaultInfo(
        files = depset(files),
        runfiles = ctx.runfiles(files = files),
    )]

_cache_payload = rule(
    implementation = _cache_payload_impl,
)

def _py_source_impl(_ctx):
    return []

_py_source = rule(
    implementation = _py_source_impl,
    attrs = {
        "imports": attr.string_list(),
        "importpath": attr.string(),
        "module_path": attr.string(),
        "deps": attr.label_list(),
    },
)

def selector_payload_fixture_targets():
    _payload_marker(
        name = "full_payload",
        marker = "full",
    )
    _payload_marker(
        name = "module_example_python_explicit_pkg",
        marker = "module:explicit",
    )
    _payload_marker(
        name = "module_manifest_context_example_python_explicit_pkg",
        marker = "module:explicit-namespaced",
    )
    _payload_marker(
        name = "module_example_python_imports_pkg",
        marker = "module:imports",
    )
    _payload_marker(
        name = "module_example_python_deps_pkg",
        marker = "module:deps",
    )
    _payload_marker(
        name = "module_example_python_attr_pkg",
        marker = "module:attrs",
    )
    _payload_marker(
        name = "module_example_python_fallback_pkg",
        marker = "module:fallback",
    )
    _payload_marker(
        name = "module_domains_ffe_apps_apis_query_validator_internal_validator_tests",
        marker = "module:dd-source-prefixed-fallback",
    )
    _payload_marker(
        name = "module_custom_override",
        marker = "module:override",
    )
    _cache_payload(
        name = "module_example_python_cache_pkg",
    )
    _py_source(
        name = "imports_leaf",
        imports = ["example/python/imports/pkg"],
    )
    _py_source(
        name = "deps_leaf",
        importpath = "example/python/deps/pkg",
    )
    _py_source(
        name = "deps_wrapper",
        deps = [":deps_leaf"],
    )

def selector_explicit_precedence_target(
        name,
        tags = None,
        module_groups = None,
        module_group_names = None):
    topt_py_payloads_selector(
        name = name,
        explicit_identifier = "example/python/explicit/pkg",
        imports = ["example/python/imports/pkg"],
        deps = [":deps_wrapper"],
        attribute_candidates = ["example/python/attr/pkg"],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_group_names = module_group_names or [],
        module_groups = module_groups or _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_imports_precedence_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = ["example/python/imports/pkg"],
        deps = [":deps_wrapper"],
        attribute_candidates = ["example/python/attr/pkg"],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_deps_precedence_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = [],
        deps = [":deps_wrapper"],
        attribute_candidates = ["example/python/attr/pkg"],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_attr_precedence_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = [],
        deps = [],
        attribute_candidates = ["example/python/attr/pkg"],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_fallback_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_no_match_fallback_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "example/python/no_match/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_prefixed_fallback_target(name, tags = None):
    """Select a dd-source-style module path without falling back to full files."""
    topt_py_payloads_selector(
        name = name,
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "domains.ffe.apps.apis.query_validator.internal.validator.tests",
        full_files = ":full_payload",
        module_groups = [":module_domains_ffe_apps_apis_query_validator_internal_validator_tests"],
        include_per_module = True,
        tags = tags,
    )

def selector_include_disabled_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        explicit_identifier = "example/python/explicit/pkg",
        imports = ["example/python/imports/pkg"],
        deps = [":deps_wrapper"],
        attribute_candidates = ["example/python/attr/pkg"],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = False,
        tags = tags,
    )

def selector_override_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        explicit_identifier = "example/python/not_used/pkg",
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "example/python/no_match/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        module_label_override = "custom_override",
        tags = tags,
    )

def selector_explicit_miss_failure_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        explicit_identifier = "example/python/missing/pkg",
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        tags = tags,
    )

def selector_override_miss_failure_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "example/python/fallback/pkg",
        full_files = ":full_payload",
        module_groups = _COMMON_MODULE_GROUPS,
        include_per_module = True,
        module_label_override = "missing_override",
        tags = tags,
    )

def selector_omits_flaky_tests_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        explicit_identifier = "example/python/cache/pkg",
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "example/python/cache/pkg",
        full_files = ":full_payload",
        module_groups = [":module_example_python_cache_pkg"],
        include_per_module = True,
        tags = tags,
    )

def selector_external_module_runfiles_target(name, tags = None):
    topt_py_payloads_selector(
        name = name,
        explicit_identifier = "example/python/pkg",
        imports = [],
        deps = [],
        attribute_candidates = [],
        fallback_identifier = "example/python/pkg",
        full_files = "@test_optimization_data//:test_optimization_files",
        module_group_names = ["module_example_python_pkg"],
        module_groups = ["@test_optimization_data//:module_example_python_pkg"],
        include_per_module = True,
        tags = tags,
    )

def _has_fragment(items, fragment):
    for item in items:
        if fragment in item:
            return True
    return False

def _has_suffix(items, suffix):
    for item in items:
        if item.endswith(suffix):
            return True
    return False

def _assert_core_cache_paths(env, paths):
    asserts.true(
        env,
        _has_fragment(paths, "/.testoptimization/cache/http/known_tests.json"),
        "expected canonical known_tests.json in paths: %s" % paths,
    )
    asserts.true(
        env,
        _has_fragment(paths, "/.testoptimization/cache/http/test_management.json"),
        "expected canonical test_management.json in paths: %s" % paths,
    )

def _assert_selected(env, target, expected_fragment):
    files = [f.basename for f in target[DefaultInfo].files.to_list()]
    asserts.equals(env, 1, len(files))
    asserts.true(
        env,
        _has_fragment(files, expected_fragment),
        "expected selected payload fragment '%s' in files %s" % (expected_fragment, files),
    )

def _selector_explicit_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_python_explicit_pkg")
    return analysistest.end(env)

def _selector_explicit_namespaced_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_manifest_context_example_python_explicit_pkg")
    return analysistest.end(env)

def _selector_imports_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_python_imports_pkg")
    return analysistest.end(env)

def _selector_deps_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_python_deps_pkg")
    return analysistest.end(env)

def _selector_attr_precedence_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_python_attr_pkg")
    return analysistest.end(env)

def _selector_fallback_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_example_python_fallback_pkg")
    return analysistest.end(env)

def _selector_no_match_fallback_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "full_payload")
    return analysistest.end(env)

def _selector_prefixed_fallback_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_domains_ffe_apps_apis_query_validator_internal_validator_tests")
    return analysistest.end(env)

def _selector_include_disabled_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "full_payload")
    return analysistest.end(env)

def _selector_override_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    _assert_selected(env, target, "module_custom_override")
    return analysistest.end(env)

def _selector_explicit_miss_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "explicit module identifier")
    asserts.expect_failure(env, "Available module groups")
    return analysistest.end(env)

def _selector_override_miss_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "module_label_override")
    asserts.expect_failure(env, "Available module groups")
    return analysistest.end(env)

def _selector_omits_flaky_tests_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    file_paths = [f.short_path for f in target[DefaultInfo].files.to_list()]
    runfile_paths = [f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()]
    _assert_core_cache_paths(env, file_paths)
    asserts.false(env, _has_fragment(file_paths, "flaky_tests.json"), "unexpected flaky_tests.json in files: %s" % file_paths)
    asserts.false(env, _has_fragment(runfile_paths, "flaky_tests.json"), "unexpected flaky_tests.json in runfiles: %s" % runfile_paths)
    return analysistest.end(env)

def _selector_external_module_runfiles_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    file_paths = [f.short_path for f in target[DefaultInfo].files.to_list()]
    symlink_paths = [s.path for s in target[DefaultInfo].default_runfiles.symlinks.to_list()]
    root_symlink_paths = [s.path for s in target[DefaultInfo].default_runfiles.root_symlinks.to_list()]
    _assert_core_cache_paths(env, file_paths)
    asserts.equals(env, [], symlink_paths)
    asserts.equals(env, [], root_symlink_paths)
    asserts.false(
        env,
        _has_suffix(file_paths, "/flaky_tests.json"),
        "unexpected flaky_tests.json in files: %s" % file_paths,
    )
    return analysistest.end(env)

selector_explicit_precedence_test = analysistest.make(
    _selector_explicit_precedence_test_impl,
)
selector_explicit_namespaced_test = analysistest.make(
    _selector_explicit_namespaced_test_impl,
)
selector_imports_precedence_test = analysistest.make(
    _selector_imports_precedence_test_impl,
)
selector_deps_precedence_test = analysistest.make(
    _selector_deps_precedence_test_impl,
)
selector_attr_precedence_test = analysistest.make(
    _selector_attr_precedence_test_impl,
)
selector_fallback_test = analysistest.make(
    _selector_fallback_test_impl,
)
selector_no_match_fallback_test = analysistest.make(
    _selector_no_match_fallback_test_impl,
)
selector_prefixed_fallback_test = analysistest.make(
    _selector_prefixed_fallback_test_impl,
)
selector_include_disabled_test = analysistest.make(
    _selector_include_disabled_test_impl,
)
selector_override_test = analysistest.make(
    _selector_override_test_impl,
)
selector_explicit_miss_failure_test = analysistest.make(
    _selector_explicit_miss_failure_test_impl,
    expect_failure = True,
)
selector_override_miss_failure_test = analysistest.make(
    _selector_override_miss_failure_test_impl,
    expect_failure = True,
)
selector_omits_flaky_tests_test = analysistest.make(
    _selector_omits_flaky_tests_test_impl,
)
selector_external_module_runfiles_test = analysistest.make(
    _selector_external_module_runfiles_test_impl,
)
