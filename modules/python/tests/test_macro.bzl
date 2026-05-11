"""Analysis tests for dd_topt_py_test macro wiring."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@datadog-rules-test-optimization-python//:topt_py_test.bzl",
    "dd_topt_py_test",
    "is_default_py_test_rule_for_tests",
    "resolve_topt_service_key_for_tests",
    "select_service_entry_for_tests",
    "validate_consumer_runner_inputs_for_tests",
    "validate_runner_mode_for_tests",
)
load("@rules_python//python:py_test.bzl", _default_py_test = "py_test")

ToptPyMacroCaptureInfo = provider(
    doc = "Captured arguments forwarded by dd_topt_py_test to py_test_rule.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "deps_labels": "Forwarded dependency labels.",
        "env": "Forwarded environment map.",
        "imports": "Forwarded imports attribute.",
        "importpath": "Forwarded importpath attribute.",
        "tags": "Forwarded tags attribute.",
    },
)

ToptPyMacroExtendedCaptureInfo = provider(
    doc = "Extended capture including main and srcs for consumer_runner tests.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "env": "Forwarded environment map.",
        "imports": "Forwarded imports attribute.",
        "main_basename": "Basename of main file, or empty if not set.",
        "srcs_basenames": "Basenames of srcs files.",
        "dd_requirements": "Custom dd_requirements attr if present.",
    },
)

ToptPyKwargsCaptureInfo = provider(
    doc = "Captured kwargs received by a fake consumer py_test macro.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "dd_requirements": "Custom dd_requirements attr if present.",
        "deps_labels": "Forwarded dependency labels.",
        "env": "Forwarded environment map.",
        "imports": "Forwarded imports attribute.",
        "saw_args": "Whether the fake macro received args.",
        "saw_imports": "Whether the fake macro received imports.",
        "saw_main": "Whether the fake macro received main.",
        "saw_run_pytest": "Whether run_pytest.py was present in srcs or main.",
        "srcs_basenames": "Basenames of srcs files.",
        "tags": "Forwarded tags attribute.",
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
            deps_labels = [str(dep.label) for dep in ctx.attr.deps],
            env = dict(ctx.attr.env),
            imports = list(ctx.attr.imports),
            importpath = ctx.attr.importpath,
            tags = list(ctx.attr.tags),
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
        "main": attr.label(allow_single_file = True),
        "module_path": attr.string(),
        "srcs": attr.label_list(allow_files = True),
    },
    executable = True,
)

# Rule that models a consumer wrapper prohibiting imports and main.
# Has NO imports or main attrs — if the macro tries to pass them, Bazel errors.
def _py_test_forbid_imports_impl(ctx):
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
            deps_labels = [str(dep.label) for dep in ctx.attr.deps],
            env = dict(ctx.attr.env),
            imports = [],
            importpath = "",
            tags = list(ctx.attr.tags),
        ),
    ]

_py_test_forbid_imports_rule = rule(
    implementation = _py_test_forbid_imports_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(),
        "env": attr.string_dict(),
        "srcs": attr.label_list(allow_files = True),
    },
    executable = True,
)

def _py_test_kwargs_capture_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(out, "#!/bin/sh\nexit 0\n", is_executable = True)
    saw_run_pytest = False
    for src in ctx.files.srcs:
        if src.basename == "run_pytest.py":
            saw_run_pytest = True
    if ctx.file.main and ctx.file.main.basename == "run_pytest.py":
        saw_run_pytest = True
    return [
        DefaultInfo(
            files = depset([out]),
            runfiles = ctx.runfiles(files = [out]),
            executable = out,
        ),
        RunEnvironmentInfo(environment = dict(ctx.attr.env)),
        ToptPyKwargsCaptureInfo(
            data_labels = [str(dep.label) for dep in ctx.attr.data],
            dd_requirements = list(ctx.attr.dd_requirements),
            deps_labels = [str(dep.label) for dep in ctx.attr.deps],
            env = dict(ctx.attr.env),
            imports = list(ctx.attr.imports),
            saw_args = ctx.attr.saw_args,
            saw_imports = ctx.attr.saw_imports,
            saw_main = ctx.attr.saw_main,
            saw_run_pytest = saw_run_pytest,
            srcs_basenames = [f.basename for f in ctx.files.srcs],
            tags = list(ctx.attr.captured_tags),
        ),
    ]

_py_test_kwargs_capture_rule = rule(
    implementation = _py_test_kwargs_capture_impl,
    attrs = {
        "captured_tags": attr.string_list(),
        "data": attr.label_list(allow_files = True),
        "dd_requirements": attr.string_list(),
        "deps": attr.label_list(),
        "env": attr.string_dict(),
        "imports": attr.string_list(),
        "main": attr.label(allow_single_file = True),
        "saw_args": attr.bool(),
        "saw_imports": attr.bool(),
        "saw_main": attr.bool(),
        "srcs": attr.label_list(allow_files = True),
    },
    executable = True,
)

def _py_test_kwargs_capture_macro(name, **kwargs):
    """Capture exact kwargs passed by dd_topt_py_test before rule defaults apply."""
    rule_kwargs = {
        "name": name,
        "captured_tags": kwargs.get("tags", []),
        "data": kwargs.get("data", []),
        "dd_requirements": kwargs.get("dd_requirements", []),
        "deps": kwargs.get("deps", []),
        "env": kwargs.get("env", {}),
        "imports": kwargs.get("imports", []),
        "saw_args": "args" in kwargs,
        "saw_imports": "imports" in kwargs,
        "saw_main": "main" in kwargs,
        "srcs": kwargs.get("srcs", []),
        "tags": kwargs.get("tags", []),
    }
    if "main" in kwargs:
        rule_kwargs["main"] = kwargs["main"]
    _py_test_kwargs_capture_rule(**rule_kwargs)

# Extended capture rule that also records main and srcs, plus custom attrs.
def _py_test_extended_capture_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(out, "#!/bin/sh\nexit 0\n", is_executable = True)
    main_basename = ""
    if ctx.file.main:
        main_basename = ctx.file.main.basename
    return [
        DefaultInfo(
            files = depset([out]),
            runfiles = ctx.runfiles(files = [out]),
            executable = out,
        ),
        RunEnvironmentInfo(environment = dict(ctx.attr.env)),
        ToptPyMacroExtendedCaptureInfo(
            data_labels = [str(dep.label) for dep in ctx.attr.data],
            env = dict(ctx.attr.env),
            imports = list(ctx.attr.imports),
            main_basename = main_basename,
            srcs_basenames = [f.basename for f in ctx.files.srcs],
            dd_requirements = list(ctx.attr.dd_requirements),
        ),
    ]

_py_test_extended_capture_rule = rule(
    implementation = _py_test_extended_capture_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "dd_requirements": attr.string_list(),
        "deps": attr.label_list(),
        "env": attr.string_dict(),
        "imports": attr.string_list(),
        "main": attr.label(allow_single_file = True),
        "srcs": attr.label_list(allow_files = True),
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

# -- consumer_runner test targets --

def py_macro_consumer_runner_target(name, tags = None):
    """consumer_runner with forbid-imports rule: proves no imports/main forwarded."""
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_forbid_imports_rule,
        runner_mode = "consumer_runner",
        module_identifier = "example.python.pkg",
        tags = tags,
    )

def py_macro_consumer_runner_with_capture_target(name, tags = None):
    """consumer_runner with capture rule: proves env/data wiring without imports synthesis."""
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_capture_rule,
        runner_mode = "consumer_runner",
        module_identifier = "example.python.pkg",
        tags = tags,
    )

def py_macro_consumer_runner_explicit_imports_target(name, tags = None):
    """consumer_runner with explicit imports: proves user imports are forwarded."""
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_capture_rule,
        runner_mode = "consumer_runner",
        imports = ["my/import"],
        module_identifier = "example.python.pkg",
        tags = tags,
    )

def py_macro_consumer_runner_with_main_target(name, tags = None):
    """consumer_runner with main but no py_test_rule: uses default rule with explicit main."""
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        runner_mode = "consumer_runner",
        main = "consumer_runner_main.py",
        srcs = ["consumer_runner_main.py"],
        module_identifier = "example.python.pkg",
        tags = tags,
    )

def py_macro_consumer_runner_custom_attrs_target(name, tags = None):
    """consumer_runner with custom wrapper attrs: proves dd_requirements passes through."""
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_extended_capture_rule,
        runner_mode = "consumer_runner",
        dd_requirements = ["pytest", "ddtrace"],
        module_identifier = "example.python.pkg",
        tags = tags,
    )

def py_macro_consumer_runner_kwargs_target(name, tags = None):
    """consumer_runner with a fake macro: captures absent kwargs before rule defaults."""
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_kwargs_capture_macro,
        runner_mode = "consumer_runner",
        srcs = ["consumer_runner_main.py"],
        data = [":test_macro.bzl"],
        dd_requirements = ["pytest", "ddtrace"],
        module_identifier = "example.python.pkg",
        args = ["-k", "consumer"],
        tags = tags,
    )

def py_macro_consumer_runner_empty_imports_target(name, tags = None):
    """consumer_runner forwards explicitly empty imports because the caller opted in."""
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_kwargs_capture_macro,
        runner_mode = "consumer_runner",
        srcs = ["consumer_runner_main.py"],
        imports = [],
        module_identifier = "example.python.pkg",
        tags = tags,
    )

def py_macro_consumer_runner_no_ddtrace_target(name, tags = None):
    """consumer_runner respects explicit --no-ddtrace opt-out in PYTEST_ADDOPTS."""
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_kwargs_capture_macro,
        runner_mode = "consumer_runner",
        srcs = ["consumer_runner_main.py"],
        env = {"PYTEST_ADDOPTS": "--no-ddtrace"},
        module_identifier = "example.python.pkg",
        tags = tags,
    )

def py_macro_consumer_runner_select_env_target(name, tags = None):
    """consumer_runner leaves configurable env values for the caller to manage."""
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_kwargs_capture_macro,
        runner_mode = "consumer_runner",
        srcs = ["consumer_runner_main.py"],
        env = select({
            "//conditions:default": {"CUSTOM_ENV": "from_select"},
        }),
        module_identifier = "example.python.pkg",
        tags = tags,
    )

def py_macro_managed_pytest_kwargs_target(name, tags = None):
    """managed_pytest keeps the built-in runner and default package imports."""
    dd_topt_py_test(
        name = name,
        topt_data = _single_service_topt_data(),
        py_test_rule = _py_test_kwargs_capture_macro,
        srcs = ["consumer_runner_main.py"],
        tags = tags,
    )

def _py_macro_consumer_runner_no_rule_no_main_target_impl(_ctx):
    dd_topt_py_test(
        name = "should_not_be_created",
        topt_data = _single_service_topt_data(),
        runner_mode = "consumer_runner",
    )
    return []

py_macro_consumer_runner_no_rule_no_main_target_rule = rule(
    implementation = _py_macro_consumer_runner_no_rule_no_main_target_impl,
)

def _py_macro_consumer_runner_default_rule_no_main_target_impl(_ctx):
    dd_topt_py_test(
        name = "should_not_be_created",
        topt_data = _single_service_topt_data(),
        py_test_rule = _default_py_test,
        runner_mode = "consumer_runner",
    )
    return []

py_macro_consumer_runner_default_rule_no_main_target_rule = rule(
    implementation = _py_macro_consumer_runner_default_rule_no_main_target_impl,
)

def _py_macro_default_rule_detection_target_impl(_ctx):
    if not is_default_py_test_rule_for_tests(_default_py_test):
        fail("rules_python py_test should be recognized as the default py_test rule")
    if is_default_py_test_rule_for_tests(_py_test_capture_rule):
        fail("custom Python test rules must not be treated as the default py_test rule")
    return []

py_macro_default_rule_detection_target_rule = rule(
    implementation = _py_macro_default_rule_detection_target_impl,
)

def _py_macro_invalid_runner_mode_target_impl(_ctx):
    validate_runner_mode_for_tests("bogus")
    return []

py_macro_invalid_runner_mode_target_rule = rule(
    implementation = _py_macro_invalid_runner_mode_target_impl,
)

def _py_macro_consumer_runner_validation_helpers_target_impl(_ctx):
    validate_runner_mode_for_tests("managed_pytest")
    validate_runner_mode_for_tests("consumer_runner")
    validate_consumer_runner_inputs_for_tests(True, False, None)
    validate_consumer_runner_inputs_for_tests(True, True, "consumer_runner_main.py")
    return []

py_macro_consumer_runner_validation_helpers_target_rule = rule(
    implementation = _py_macro_consumer_runner_validation_helpers_target_impl,
)

# -- consumer_runner test implementations --

def _py_macro_consumer_runner_wiring_test_impl(ctx):
    """Verify consumer_runner forbid-imports rule succeeds (no imports/main forwarded)."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyMacroCaptureInfo]

    # Test Optimization wiring is present.
    asserts.true(env, _has_label_suffix(captured.data_labels, ":py_macro_consumer_runner_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "py_macro_consumer_runner_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "py-service", captured.env.get("DD_SERVICE"))

    # PYTEST_ADDOPTS is still injected.
    asserts.equals(env, "--ddtrace", captured.env.get("PYTEST_ADDOPTS"))

    # imports is empty (rule has no imports attr, so provider returns []).
    asserts.equals(env, [], captured.imports)
    return analysistest.end(env)

def _py_macro_consumer_runner_capture_test_impl(ctx):
    """Verify consumer_runner with capture rule: imports not synthesized."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyMacroCaptureInfo]

    # Test Optimization env is present.
    asserts.true(env, captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE") != None)
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "py_macro_consumer_runner_with_capture_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "--ddtrace", captured.env.get("PYTEST_ADDOPTS"))

    # Data has selector and manifest.
    asserts.true(env, _has_label_suffix(captured.data_labels, ":py_macro_consumer_runner_with_capture_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))

    # imports is empty — not synthesized from package path.
    asserts.equals(env, [], captured.imports)
    return analysistest.end(env)

def _py_macro_consumer_runner_explicit_imports_test_impl(ctx):
    """Verify consumer_runner forwards user-provided imports."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyMacroCaptureInfo]
    asserts.equals(env, ["my/import"], captured.imports)
    return analysistest.end(env)

def _py_macro_consumer_runner_custom_attrs_test_impl(ctx):
    """Verify consumer_runner passes custom wrapper attrs through."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyMacroExtendedCaptureInfo]
    asserts.equals(env, ["pytest", "ddtrace"], captured.dd_requirements)

    # run_pytest.py should NOT be in srcs.
    for basename in captured.srcs_basenames:
        asserts.true(env, basename != "run_pytest.py", msg = "run_pytest.py should not be injected in consumer_runner")

    # main should not be set (empty basename).
    asserts.equals(env, "", captured.main_basename)
    return analysistest.end(env)

def _py_macro_consumer_runner_kwargs_test_impl(ctx):
    """Verify consumer_runner forwards only caller-owned raw kwargs."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyKwargsCaptureInfo]

    asserts.false(env, captured.saw_args)
    asserts.false(env, captured.saw_imports)
    asserts.false(env, captured.saw_main)
    asserts.false(env, captured.saw_run_pytest)
    asserts.true(env, "consumer_runner_main.py" in captured.srcs_basenames)
    asserts.equals(env, ["pytest", "ddtrace"], captured.dd_requirements)
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":py_macro_consumer_runner_kwargs_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(env, "--ddtrace", captured.env.get("PYTEST_ADDOPTS"))
    asserts.true(env, "manual" in captured.tags)
    asserts.true(env, "consumer_tag" in captured.tags)
    return analysistest.end(env)

def _py_macro_consumer_runner_empty_imports_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyKwargsCaptureInfo]
    asserts.true(env, captured.saw_imports)
    asserts.equals(env, [], captured.imports)
    return analysistest.end(env)

def _py_macro_consumer_runner_no_ddtrace_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyKwargsCaptureInfo]
    asserts.equals(env, "--no-ddtrace", captured.env.get("PYTEST_ADDOPTS"))
    return analysistest.end(env)

def _py_macro_consumer_runner_select_env_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyKwargsCaptureInfo]
    asserts.equals(env, "from_select", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, None, captured.env.get("PYTEST_ADDOPTS"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    return analysistest.end(env)

def _py_macro_managed_pytest_kwargs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptPyKwargsCaptureInfo]
    asserts.false(env, captured.saw_args)
    asserts.true(env, captured.saw_imports)
    asserts.true(env, captured.saw_main)
    asserts.true(env, captured.saw_run_pytest)
    asserts.equals(env, ["modules/python/tests"], captured.imports)
    return analysistest.end(env)

def _py_macro_consumer_runner_no_rule_no_main_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "requires a consumer-owned Python test runner")
    return analysistest.end(env)

def _py_macro_consumer_runner_default_rule_no_main_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "requires a consumer-owned Python test runner")
    asserts.expect_failure(env, "Pass your repository's Python test wrapper via py_test_rule")
    return analysistest.end(env)

def _py_macro_consumer_runner_default_rule_with_main_test_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

def _py_macro_invalid_runner_mode_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "runner_mode must be one of")
    return analysistest.end(env)

def _py_macro_default_rule_detection_test_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

def _py_macro_consumer_runner_validation_helpers_test_impl(ctx):
    env = analysistest.begin(ctx)
    return analysistest.end(env)

py_macro_consumer_runner_wiring_test = analysistest.make(
    _py_macro_consumer_runner_wiring_test_impl,
)
py_macro_consumer_runner_capture_test = analysistest.make(
    _py_macro_consumer_runner_capture_test_impl,
)
py_macro_consumer_runner_explicit_imports_test = analysistest.make(
    _py_macro_consumer_runner_explicit_imports_test_impl,
)
py_macro_consumer_runner_custom_attrs_test = analysistest.make(
    _py_macro_consumer_runner_custom_attrs_test_impl,
)
py_macro_consumer_runner_kwargs_test = analysistest.make(
    _py_macro_consumer_runner_kwargs_test_impl,
)
py_macro_consumer_runner_empty_imports_test = analysistest.make(
    _py_macro_consumer_runner_empty_imports_test_impl,
)
py_macro_consumer_runner_no_ddtrace_test = analysistest.make(
    _py_macro_consumer_runner_no_ddtrace_test_impl,
)
py_macro_consumer_runner_select_env_test = analysistest.make(
    _py_macro_consumer_runner_select_env_test_impl,
)
py_macro_managed_pytest_kwargs_test = analysistest.make(
    _py_macro_managed_pytest_kwargs_test_impl,
)
py_macro_consumer_runner_no_rule_no_main_failure_test = analysistest.make(
    _py_macro_consumer_runner_no_rule_no_main_failure_test_impl,
    expect_failure = True,
)
py_macro_consumer_runner_default_rule_no_main_failure_test = analysistest.make(
    _py_macro_consumer_runner_default_rule_no_main_failure_test_impl,
    expect_failure = True,
)
py_macro_consumer_runner_default_rule_with_main_test = analysistest.make(
    _py_macro_consumer_runner_default_rule_with_main_test_impl,
)
py_macro_invalid_runner_mode_failure_test = analysistest.make(
    _py_macro_invalid_runner_mode_failure_test_impl,
    expect_failure = True,
)
py_macro_default_rule_detection_test = analysistest.make(
    _py_macro_default_rule_detection_test_impl,
)
py_macro_consumer_runner_validation_helpers_test = analysistest.make(
    _py_macro_consumer_runner_validation_helpers_test_impl,
)

# -- existing test implementations --

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
    asserts.equals(env, 2, len(files))
    asserts.true(env, _has_file_basename(files, "py_macro_single_service_target"))
    asserts.true(
        env,
        _has_file_basename(
            files,
            "py_macro_single_service_target__wrapped_py_macro_single_service_target__raw_python_test.sh",
        ),
    )
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
select_service_entry_malformed_topt_data_failure_test = analysistest.make(
    _select_service_entry_malformed_topt_data_failure_test_impl,
    expect_failure = True,
)
select_service_entry_empty_mapping_failure_test = analysistest.make(
    _select_service_entry_empty_mapping_failure_test_impl,
    expect_failure = True,
)
