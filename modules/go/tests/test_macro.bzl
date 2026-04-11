"""Analysis tests for dd_topt_go_test macro wiring.

Maintainer goals covered here:
- Guard the macro contract for `data`/`env` wiring.
- Verify default vs custom `rundir` behavior.
- Verify multi-service key resolution (including sanitized keys).
- Keep service-resolution failure messages actionable for users.

Why this harness exists:
`dd_topt_go_test` defaults to rules_go's `go_test`, but these tests override it
with a lightweight fake executable rule so we can capture what the macro
forwards at analysis time without compiling Go code.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@datadog-rules-test-optimization-go//:topt_go_orchestrion.bzl",
    "orch_go_test",
    "select_wrapper_output_name_for_tests",
)
load(
    "@datadog-rules-test-optimization-go//:topt_go_test.bzl",
    "dd_topt_go_test",
    "resolve_topt_service_key_for_tests",
)

ToptGoMacroCaptureInfo = provider(
    doc = "Captured arguments forwarded by dd_topt_go_test to the underlying go_test rule.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "env": "Forwarded environment map.",
        "importpath": "Forwarded importpath attribute.",
        "rundir": "Forwarded runtime working directory.",
    },
)

WrapperOutputNameInfo = provider(
    doc = "Computed wrapper output file name for Orchestrion wrapper tests.",
    fields = {
        "output_name": "The output file name selected by the wrapper helper.",
    },
)

def _go_test_capture_impl(ctx):
    """Capture macro-forwarded attributes for analysistest assertions."""
    out = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(out, "#!/bin/sh\nexit 0\n", is_executable = True)
    return [
        DefaultInfo(
            files = depset([out]),
            runfiles = ctx.runfiles(files = [out]),
            executable = out,
        ),
        RunEnvironmentInfo(environment = dict(ctx.attr.env)),
        ToptGoMacroCaptureInfo(
            data_labels = [str(dep.label) for dep in ctx.attr.data],
            env = dict(ctx.attr.env),
            importpath = ctx.attr.importpath,
            rundir = ctx.attr.rundir,
        ),
    ]

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

_go_test_capture_rule = rule(
    implementation = _go_test_capture_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "embed": attr.label_list(),
        "env": attr.string_dict(),
        "importpath": attr.string(),
        "rundir": attr.string(),
    },
    executable = True,
)

def _fake_executable_impl(ctx):
    """Create a lightweight executable target for wrapper analysis tests."""
    out = ctx.actions.declare_file(ctx.attr.executable_name)
    content = "@echo off\r\nexit /b 0\r\n" if ctx.attr.is_windows else "#!/bin/sh\nexit 0\n"
    ctx.actions.write(out, content, is_executable = True)
    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]),
        executable = out,
    )]

fake_executable_rule = rule(
    implementation = _fake_executable_impl,
    attrs = {
        "executable_name": attr.string(mandatory = True),
        "is_windows": attr.bool(default = False),
    },
    executable = True,
)

def _wrapper_output_name_target_impl(ctx):
    return [WrapperOutputNameInfo(
        output_name = select_wrapper_output_name_for_tests(
            ctx.attr.label_name,
            ctx.attr.executable_basename,
            ctx.attr.is_windows,
        ),
    )]

wrapper_output_name_target_rule = rule(
    implementation = _wrapper_output_name_target_impl,
    attrs = {
        "label_name": attr.string(mandatory = True),
        "executable_basename": attr.string(mandatory = True),
        "is_windows": attr.bool(mandatory = True),
    },
)

def _single_service_topt_data():
    return {
        "repo_name": "test_optimization_data",
        "service_name": "go-service",
        "manifest_path": ".testoptimization/manifest.txt",
        "labels": [],
        "set": {},
        "runtimes": {
            "go": {
                "module_path": "example.com/stub",
                "sanitized_module_path": "example_com_stub",
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
        "go_service": selected,
        "ruby_service": not_selected,
        "_meta": {"description": "non-service entry should be ignored"},
    }

def go_macro_single_service_target(name, tags = None):
    """Target-under-test: single-service wiring + default rundir path."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        data = [":test_macro.bzl"],
        env = {
            "CUSTOM_ENV": "1",
            # Macro must force this to true regardless of user input.
            "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
        },
        tags = tags,
    )

def go_macro_multi_service_target(name, tags = None):
    """Target-under-test: sanitized service-key selection wiring."""
    dd_topt_go_test(
        name = name,
        topt_data = _multi_service_topt_data(),
        topt_service = "go-service",
        go_test_rule = _go_test_capture_rule,
        importpath = "example.com/override/pkg",
        # Keep default rundir behavior when caller does not set it.
        tags = tags,
    )

def go_macro_rundir_mismatch_target(name, tags = None):
    """Target under test for caller-provided custom rundir passthrough."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        rundir = "custom/rundir",
        tags = tags,
    )

def go_macro_env_none_target(name, tags = None):
    """Target under test for explicit env=None handling."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        env = None,
        tags = tags,
    )

def go_macro_explicit_service_target(name, tags = None):
    """Target under test for explicit DD_SERVICE passthrough."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        env = {
            "DD_SERVICE": "caller-service",
        },
        tags = tags,
    )

def go_macro_select_inputs_target(name, tags = None):
    """Target under test for configurable data/env handling."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        data = select({
            "//conditions:default": [":test_macro.bzl"],
        }),
        env = select({
            "//conditions:default": {
                "CUSTOM_ENV": "from_select",
                "DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES": "false",
            },
        }),
        tags = tags,
    )

def go_macro_orchestrion_pin_files_target(name, tags = None):
    """Target under test for explicit module-root Orchestrion pin-file labels."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        orchestrion_pin_files = [
            ":test_macro.bzl",
            ":test_selection_utils.bzl",
        ],
        tags = tags,
    )

def orch_wrapper_materialized_actual_non_windows_target(name, tags = None):
    """Target under test for non-Windows sibling executable materialization."""
    fake_executable_rule(
        name = name + "_actual",
        executable_name = "hello_test__raw_go_test",
        tags = ["manual"],
    )
    orch_go_test(
        name = name,
        actual = ":" + name + "_actual",
        tags = tags,
    )

def orch_wrapper_materialized_actual_windows_target(name, tags = None):
    """Target under test for Windows sibling executable materialization."""
    fake_executable_rule(
        name = name + "_actual",
        executable_name = "hello_test__raw_go_test.exe",
        is_windows = True,
        tags = ["manual"],
    )
    orch_go_test(
        name = name,
        actual = ":" + name + "_actual",
        tags = tags,
    )

def _go_macro_single_service_wiring_test_impl(ctx):
    """Assert env/data/rundir contract for single-service macro usage."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_single_service_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_single_service_target_topt_bazel_metadata"))
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
        "go_macro_single_service_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "1", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "go-service", captured.env.get("DD_SERVICE"))
    asserts.true(env, captured.rundir.endswith("tests"))
    return analysistest.end(env)

def _go_macro_multi_service_wiring_test_impl(ctx):
    """Assert multi-service key resolution and passthrough attributes."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]

    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_multi_service_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_multi_service_target_topt_bazel_metadata"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_optimization_data"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(env, "go-service", captured.env.get("DD_SERVICE"))
    asserts.equals(
        env,
        "go_macro_multi_service_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "example.com/override/pkg", captured.importpath)
    asserts.true(env, captured.rundir.endswith("tests"))
    return analysistest.end(env)

def _go_macro_rundir_mismatch_wiring_test_impl(ctx):
    """Assert custom rundir is honored when explicitly provided."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.equals(env, "custom/rundir", captured.rundir)
    return analysistest.end(env)

def _go_macro_env_none_wiring_test_impl(ctx):
    """Assert env=None does not crash and macro still injects required keys."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.equals(env, None, captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "go-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "go_macro_env_none_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _go_macro_select_inputs_wiring_test_impl(ctx):
    """Assert configurable data/env still get Datadog-required wiring."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_select_inputs_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_select_inputs_target_topt_bazel_metadata"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.equals(env, "from_select", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, None, captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "go_macro_select_inputs_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _go_macro_orchestrion_pin_files_wiring_test_impl(ctx):
    """Assert explicit Orchestrion pin-file labels are forwarded to data."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_orchestrion_pin_files_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_orchestrion_pin_files_target_topt_bazel_metadata"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_selection_utils.bzl"))
    return analysistest.end(env)

def _go_macro_explicit_service_wiring_test_impl(ctx):
    """Assert explicit caller DD_SERVICE is preserved."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.equals(env, "caller-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(
        env,
        "go_macro_explicit_service_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    return analysistest.end(env)

def _go_macro_public_wrapper_test_impl(ctx):
    """Assert the public target is now the wrapper executable."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    asserts.equals(env, 2, len(files))
    asserts.true(env, _has_file_basename(files, "go_macro_single_service_target"))
    asserts.true(env, _has_file_basename(files, "go_macro_single_service_target__wrapped_go_macro_single_service_target__raw_go_test.sh"))
    run_env = target[RunEnvironmentInfo].environment
    manifest_env = run_env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    asserts.equals(
        env,
        "go_macro_single_service_target_topt_bazel_metadata.json",
        run_env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    asserts.equals(env, "true", run_env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "1", run_env.get("CUSTOM_ENV"))
    return analysistest.end(env)

def _resolve_topt_service_key_missing_target_impl(_ctx):
    """Analysis target expected to fail on missing service in multi-service map."""
    resolve_topt_service_key_for_tests(
        {
            "go_service": {"repo_name": "repo_go"},
            "ruby_service": {"repo_name": "repo_ruby"},
        },
        None,
    )
    return []

def _resolve_topt_service_key_unknown_target_impl(_ctx):
    """Analysis target expected to fail on unknown service key."""
    resolve_topt_service_key_for_tests(
        {
            "go_service": {"repo_name": "repo_go"},
            "ruby_service": {"repo_name": "repo_ruby"},
        },
        "java-service",
    )
    return []

resolve_topt_service_key_missing_target_rule = rule(
    implementation = _resolve_topt_service_key_missing_target_impl,
)

resolve_topt_service_key_unknown_target_rule = rule(
    implementation = _resolve_topt_service_key_unknown_target_impl,
)

def _resolve_topt_service_key_missing_failure_test_impl(ctx):
    """Assert missing-service failure message keeps next-step guidance."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "please pass topt_service")
    asserts.expect_failure(env, "go_service, ruby_service")
    return analysistest.end(env)

def _resolve_topt_service_key_unknown_failure_test_impl(ctx):
    """Assert unknown-service failure lists available service keys."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "topt_service 'java-service' not found")
    asserts.expect_failure(env, "go_service, ruby_service")
    return analysistest.end(env)

def _wrapper_output_name_non_windows_test_impl(ctx):
    """Assert non-Windows wrapper names remain extensionless."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, "hello_test", target[WrapperOutputNameInfo].output_name)
    return analysistest.end(env)

def _wrapper_output_name_windows_test_impl(ctx):
    """Assert Windows wrapper names use the batch launcher suffix."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, "hello_test.bat", target[WrapperOutputNameInfo].output_name)
    return analysistest.end(env)

def _orch_wrapper_materialized_actual_non_windows_test_impl(ctx):
    """Assert the wrapper target ships the sibling raw executable."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    runfiles = target[DefaultInfo].default_runfiles.files.to_list()
    asserts.true(env, _has_file_basename(files, "orch_wrapper_materialized_actual_non_windows_target"))
    asserts.true(env, _has_file_basename(files, "orch_wrapper_materialized_actual_non_windows_target__wrapped_hello_test__raw_go_test"))
    asserts.true(env, _has_file_basename(runfiles, "orch_wrapper_materialized_actual_non_windows_target__wrapped_hello_test__raw_go_test"))
    return analysistest.end(env)

def _orch_wrapper_materialized_actual_windows_test_impl(ctx):
    """Assert the Windows wrapper target carries the sibling raw executable."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    runfiles = target[DefaultInfo].default_runfiles.files.to_list()
    asserts.true(env, _has_file_basename(files, "orch_wrapper_materialized_actual_windows_target.bat"))
    asserts.true(env, _has_file_basename(files, "orch_wrapper_materialized_actual_windows_target__wrapped_hello_test__raw_go_test.exe"))
    asserts.true(env, _has_file_basename(runfiles, "orch_wrapper_materialized_actual_windows_target__wrapped_hello_test__raw_go_test.exe"))
    return analysistest.end(env)

go_macro_single_service_wiring_test = analysistest.make(
    _go_macro_single_service_wiring_test_impl,
)
go_macro_multi_service_wiring_test = analysistest.make(
    _go_macro_multi_service_wiring_test_impl,
)
go_macro_rundir_mismatch_wiring_test = analysistest.make(
    _go_macro_rundir_mismatch_wiring_test_impl,
)
go_macro_env_none_wiring_test = analysistest.make(
    _go_macro_env_none_wiring_test_impl,
)
go_macro_select_inputs_wiring_test = analysistest.make(
    _go_macro_select_inputs_wiring_test_impl,
)
go_macro_orchestrion_pin_files_wiring_test = analysistest.make(
    _go_macro_orchestrion_pin_files_wiring_test_impl,
)
go_macro_explicit_service_wiring_test = analysistest.make(
    _go_macro_explicit_service_wiring_test_impl,
)
go_macro_public_wrapper_test = analysistest.make(
    _go_macro_public_wrapper_test_impl,
)
resolve_topt_service_key_missing_failure_test = analysistest.make(
    _resolve_topt_service_key_missing_failure_test_impl,
    expect_failure = True,
)
resolve_topt_service_key_unknown_failure_test = analysistest.make(
    _resolve_topt_service_key_unknown_failure_test_impl,
    expect_failure = True,
)
wrapper_output_name_non_windows_test = analysistest.make(
    _wrapper_output_name_non_windows_test_impl,
)
wrapper_output_name_windows_test = analysistest.make(
    _wrapper_output_name_windows_test_impl,
)
orch_wrapper_materialized_actual_non_windows_test = analysistest.make(
    _orch_wrapper_materialized_actual_non_windows_test_impl,
)
orch_wrapper_materialized_actual_windows_test = analysistest.make(
    _orch_wrapper_materialized_actual_windows_test_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label("@rules_go//go/toolchain:windows_amd64")),
    },
)
