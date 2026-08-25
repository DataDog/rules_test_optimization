# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

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

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@datadog-rules-test-optimization-go//:topt_go_infer.bzl", "ToptGoBazelMetadataInfo")
load(
    "@datadog-rules-test-optimization-go//:topt_go_orchestrion.bzl",
    "orch_go_test",
    "orch_transition_impl_for_tests",
    "select_wrapper_output_name_for_tests",
    "windows_wrapper_content_for_tests",
)
load(
    "@datadog-rules-test-optimization-go//:topt_go_test.bzl",
    "dd_topt_go_test",
    "has_go_mod_pin_for_tests",
    "has_package_local_go_mod_for_tests",
    "resolve_topt_service_key_for_tests",
    "validate_orchestrion_mode_for_tests",
    "validate_test_optimization_pin_files_for_tests",
)
load("@rules_go//go/private/orchestrion:pin_files.bzl", "OrchestrionPinFilesInfo")

_ORCHESTRION_ENABLED_SETTING = str(Label("@rules_go//go/private/orchestrion:enabled"))

ToptGoMacroCaptureInfo = provider(
    doc = "Captured arguments forwarded by dd_topt_go_test to the underlying go_test rule.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "env": "Forwarded environment map.",
        "gc_linkopts": "Forwarded Go linker options.",
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
            gc_linkopts = list(ctx.attr.gc_linkopts),
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
        "embedsrcs": attr.label_list(allow_files = True),
        "env": attr.string_dict(),
        "gc_linkopts": attr.string_list(),
        "importpath": attr.string(),
        "rundir": attr.string(),
        "srcs": attr.label_list(allow_files = True),
    },
    executable = True,
)

def _go_test_transition_mode_impl(ctx):
    """Expose the transitioned Orchestrion mode through the executable basename."""
    mode = ctx.attr._orchestrion_mode[BuildSettingInfo].value
    out = ctx.actions.declare_file(ctx.label.name + "__orchestrion_mode_" + mode + ".sh")
    ctx.actions.write(out, "#!/bin/sh\nexit 0\n", is_executable = True)
    return [
        DefaultInfo(
            files = depset([out]),
            runfiles = ctx.runfiles(files = [out]),
            executable = out,
        ),
    ]

_go_test_transition_mode_rule = rule(
    implementation = _go_test_transition_mode_impl,
    attrs = {
        "data": attr.label_list(allow_files = True),
        "embed": attr.label_list(),
        "embedsrcs": attr.label_list(allow_files = True),
        "env": attr.string_dict(),
        "gc_linkopts": attr.string_list(),
        "importpath": attr.string(),
        "rundir": attr.string(),
        "srcs": attr.label_list(allow_files = True),
        "_orchestrion_mode": attr.label(
            default = "@rules_go//go/private/orchestrion:mode",
            providers = [BuildSettingInfo],
        ),
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

def _fake_metadata_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(out, "{}\n")
    return [DefaultInfo(files = depset([out]))]

fake_metadata_rule = rule(implementation = _fake_metadata_impl)

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

def _single_service_topt_data(enabled = True):
    return {
        "enabled": enabled,
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

def _dynamic_manifest_topt_data():
    """Model one target entry exported by the manifest aggregate repository."""
    data = _single_service_topt_data()
    data.update({
        "repo_name": "virtual_dynamic_repo_that_must_not_resolve",
        "service_name": "dynamic-go-service",
        "files_label": ":full_payload",
        "manifest_label": ":test_macro.bzl",
        "module_labels": [":module_example_com_explicit_pkg"],
        "labels": ["ignored_static_label_that_must_not_resolve"],
        "manifest_path": "ignored/static/manifest.txt",
    })
    return data

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

def go_macro_dynamic_manifest_target(name, tags = None):
    """Target under test for explicit labels from one dynamic manifest entry."""
    dd_topt_go_test(
        name = name,
        topt_data = _dynamic_manifest_topt_data(),
        go_test_rule = _go_test_capture_rule,
        importpath = "example.com/explicit/pkg",
        tags = tags,
    )

def go_macro_disabled_raw_target(name, tags = None):
    """Target under test for the strict disabled raw go_test branch."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(enabled = False),
        go_test_rule = _go_test_capture_rule,
        data = [":test_macro.bzl"],
        env = {"CUSTOM_ENV": "disabled"},
        gc_linkopts = ["-disabled-link-flag"],
        importpath = "example.com/disabled/pkg",
        rundir = "disabled/rundir",
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

def go_macro_ci_visibility_opt_out_target(name, tags = None):
    """Target under test for caller-owned CI Visibility enablement."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        ci_visibility_enabled = False,
        tags = tags,
    )

def go_macro_stage_sources_target(name, tags = None):
    """Target under test for source staging with the default repo-root rundir."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        stage_sources = True,
        data = [":test_macro.bzl"],
        srcs = [":test_selection_utils.bzl"],
        embedsrcs = [":test_payloads_selector.bzl"],
        tags = tags,
    )

def go_macro_stage_sources_rundir_target(name, tags = None):
    """Target under test for source staging with an explicit custom rundir."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        stage_sources = True,
        rundir = "custom/rundir",
        srcs = [":test_macro.bzl"],
        embedsrcs = [":test_selection_utils.bzl"],
        tags = tags,
    )

def go_macro_stage_sources_select_target(name, tags = None):
    """Target under test for configurable source staging inputs."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        stage_sources = True,
        data = select({
            "//conditions:default": [":test_macro.bzl"],
        }),
        srcs = select({
            "//conditions:default": [":test_selection_utils.bzl"],
        }),
        embedsrcs = select({
            "//conditions:default": [":test_payloads_selector.bzl"],
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

def go_macro_test_optimization_mode_target(name, tags = None):
    """Target under test for opt-in Test Optimization Orchestrion mode."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        data = [":test_macro.bzl"],
        orchestrion_mode = "test_optimization",
        orchestrion_pin_files = [":go.mod"],
        tags = tags,
    )

def go_macro_test_optimization_public_wrapper_mode_target(name, tags = None):
    """Target under test for public wrapper Orchestrion mode forwarding."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_transition_mode_rule,
        orchestrion_mode = "test_optimization",
        orchestrion_pin_files = [":go.mod"],
        tags = tags,
    )

def go_macro_default_general_public_wrapper_mode_target(name, tags = None):
    """Target under test for omitted Orchestrion mode defaulting to general."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_transition_mode_rule,
        tags = tags,
    )

def go_macro_test_optimization_linker_default_target(name, tags = None):
    """Target under test for default Test Optimization linker flags."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        data = [":test_macro.bzl"],
        orchestrion_mode = "test_optimization",
        orchestrion_pin_files = [":go.mod"],
        tags = tags,
    )

def go_macro_test_optimization_linker_opt_out_target(name, tags = None):
    """Target under test for disabling Test Optimization linker flags."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        data = [":test_macro.bzl"],
        orchestrion_mode = "test_optimization",
        orchestrion_pin_files = [":go.mod"],
        enable_test_binary_linker_optimization = False,
        gc_linkopts = ["-custom-link-flag"],
        tags = tags,
    )

def go_macro_general_mode_linker_flags_target(name, tags = None):
    """Target under test for preserving linker flags outside Test Optimization."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        data = [":test_macro.bzl"],
        orchestrion_mode = "general",
        gc_linkopts = ["-custom-link-flag"],
        tags = tags,
    )

def orch_wrapper_materialized_actual_non_windows_target(name, tags = None):
    """Target under test for non-Windows sibling executable materialization."""
    fake_executable_rule(
        name = name + "_actual",
        executable_name = "hello_test__raw_go_test",
        tags = ["manual"],
    )
    fake_metadata_rule(
        name = name + "_metadata",
        tags = ["manual"],
    )
    orch_go_test(
        name = name,
        actual = ":" + name + "_actual",
        metadata = ":" + name + "_metadata",
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
    fake_metadata_rule(
        name = name + "_metadata",
        tags = ["manual"],
    )
    orch_go_test(
        name = name,
        actual = ":" + name + "_actual",
        metadata = ":" + name + "_metadata",
        tags = tags,
    )

def go_macro_orchestrion_enablement_mismatch_target(name, tags = None):
    """Target under test for an incomplete config-gated Go upgrade."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(enabled = True),
        go_test_rule = _go_test_capture_rule,
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
    asserts.equals(env, "true", captured.env.get("DD_CIVISIBILITY_ENABLED"))
    asserts.equals(env, None, captured.env.get("DD_TRACE_AGENT_URL"))
    asserts.equals(env, None, captured.env.get("DD_CIVISIBILITY_AGENTLESS_ENABLED"))
    asserts.equals(env, None, captured.env.get("DD_CIVISIBILITY_AGENTLESS_URL"))
    asserts.equals(env, "1", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "go-service", captured.env.get("DD_SERVICE"))
    asserts.equals(env, "true", captured.env.get("DD_CIVISIBILITY_ENABLED"))
    asserts.true(env, captured.rundir.endswith("tests"))
    return analysistest.end(env)

def _go_macro_inferred_importpath_metadata_test_impl(ctx):
    """Assert fallback metadata mirrors the hidden rules_go test label."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    metadata = target[ToptGoBazelMetadataInfo].metadata
    asserts.equals(
        env,
        target.label.package + "/go_macro_single_service_target__raw_go_test",
        metadata["bazel.go.importpath"],
    )
    asserts.equals(env, "fallback", metadata["bazel.go.importpath_source"])
    return analysistest.end(env)

def _go_macro_disabled_raw_wiring_test_impl(ctx):
    """Assert disabled metadata forwards caller kwargs to one raw public test."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]

    asserts.equals(env, 1, len(captured.data_labels))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.equals(env, {"CUSTOM_ENV": "disabled"}, captured.env)
    asserts.equals(env, ["-disabled-link-flag"], captured.gc_linkopts)
    asserts.equals(env, "example.com/disabled/pkg", captured.importpath)
    asserts.equals(env, "disabled/rundir", captured.rundir)
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

def _go_macro_dynamic_manifest_wiring_test_impl(ctx):
    """Assert dynamic target entries avoid virtual-repository label fallback."""
    env = analysistest.begin(ctx)
    captured = analysistest.target_under_test(env)[ToptGoMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_dynamic_manifest_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.false(env, _has_fragment(captured.data_labels, "virtual_dynamic_repo_that_must_not_resolve"))
    asserts.equals(env, "dynamic-go-service", captured.env.get("DD_SERVICE"))
    return analysistest.end(env)

def _go_macro_dynamic_manifest_payloads_test_impl(ctx):
    """Assert only the selected explicit module files reach the selector."""
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(files))
    asserts.true(env, _has_file_basename(files, "module_example_com_explicit_pkg.payload"))
    asserts.false(env, _has_file_basename(files, "full_payload.payload"))
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
    asserts.equals(env, "true", captured.env.get("DD_CIVISIBILITY_ENABLED"))
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
    asserts.equals(env, "true", captured.env.get("DD_CIVISIBILITY_ENABLED"))
    asserts.equals(
        env,
        "go_macro_select_inputs_target_topt_bazel_metadata.json",
        captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"),
    )
    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    return analysistest.end(env)

def _go_macro_ci_visibility_opt_out_wiring_test_impl(ctx):
    """Assert callers can intentionally own the CI Visibility tracer switch."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.equals(env, None, captured.env.get("DD_CIVISIBILITY_ENABLED"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    return analysistest.end(env)

def _go_macro_stage_sources_wiring_test_impl(ctx):
    """Assert source staging adds direct sources and uses repo-root rundir."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_selection_utils.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_payloads_selector.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_stage_sources_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_stage_sources_target_topt_bazel_metadata"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(env, ".", captured.rundir)
    return analysistest.end(env)

def _go_macro_stage_sources_rundir_wiring_test_impl(ctx):
    """Assert explicit rundir still wins when source staging is enabled."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_selection_utils.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_stage_sources_rundir_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_stage_sources_rundir_target_topt_bazel_metadata"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(env, "custom/rundir", captured.rundir)
    return analysistest.end(env)

def _go_macro_stage_sources_select_wiring_test_impl(ctx):
    """Assert configurable source staging still preserves selected labels."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_selection_utils.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_payloads_selector.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_stage_sources_select_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_stage_sources_select_target_topt_bazel_metadata"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(env, ".", captured.rundir)
    return analysistest.end(env)

def _go_macro_orchestrion_pin_files_wiring_test_impl(ctx):
    """Assert explicit Orchestrion pin files are forwarded through the provider target."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_orchestrion_pin_files_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_orchestrion_pin_files_target_topt_bazel_metadata"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_orchestrion_pin_files_target_orchestrion_pin_files"))
    asserts.false(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.false(env, _has_label_suffix(captured.data_labels, ":test_selection_utils.bzl"))
    return analysistest.end(env)

def _go_macro_orchestrion_pin_files_provider_test_impl(ctx):
    """Assert the hidden pin-files target carries only Orchestrion pin files."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    pin_files = target[OrchestrionPinFilesInfo].files.to_list()
    asserts.equals(env, 3, len(pin_files))
    asserts.true(env, _has_file_basename(pin_files, "go.mod"))
    asserts.true(env, _has_file_basename(pin_files, "test_macro.bzl"))
    asserts.true(env, _has_file_basename(pin_files, "test_selection_utils.bzl"))
    return analysistest.end(env)

def _go_macro_test_optimization_mode_wiring_test_impl(ctx):
    """Assert opt-in mode preserves raw test runtime data and env wiring."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.true(env, _has_label_suffix(captured.data_labels, ":test_macro.bzl"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_test_optimization_mode_target_topt_payloads"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_test_optimization_mode_target_topt_bazel_metadata"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":go_macro_test_optimization_mode_target_orchestrion_pin_files"))
    asserts.true(env, _has_label_suffix(captured.data_labels, ":.testoptimization/manifest.txt"))
    asserts.equals(env, "$(rlocationpath @test_optimization_data//:.testoptimization/manifest.txt)", captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE"))
    asserts.equals(env, "go_macro_test_optimization_mode_target_topt_bazel_metadata.json", captured.env.get("DD_TEST_OPTIMIZATION_BAZEL_TARGET_METADATA_BASENAME"))
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "true", captured.env.get("DD_CIVISIBILITY_ENABLED"))
    return analysistest.end(env)

def _go_macro_test_optimization_linker_opt_out_wiring_test_impl(ctx):
    """Assert opt-out preserves caller-provided linker flags exactly."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.equals(env, ["-custom-link-flag"], captured.gc_linkopts)
    return analysistest.end(env)

def _go_macro_test_optimization_linker_default_wiring_test_impl(ctx):
    """Assert optimized tests receive default strip linker flags in opt mode."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.equals(env, ["-s", "-w"], captured.gc_linkopts)
    return analysistest.end(env)

def _go_macro_test_optimization_linker_metadata_true_test_impl(ctx):
    """Assert metadata reports the default optimization only when applied."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    metadata = target[ToptGoBazelMetadataInfo].metadata
    asserts.equals(env, True, metadata["bazel.go.test_binary_linker_optimization"])
    return analysistest.end(env)

def _go_macro_test_optimization_linker_metadata_false_test_impl(ctx):
    """Assert metadata reports false when the default optimization is inactive."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    metadata = target[ToptGoBazelMetadataInfo].metadata
    asserts.equals(env, False, metadata["bazel.go.test_binary_linker_optimization"])
    return analysistest.end(env)

def _go_macro_general_mode_linker_flags_wiring_test_impl(ctx):
    """Assert non-Test Optimization mode preserves caller-provided linker flags."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.equals(env, ["-custom-link-flag"], captured.gc_linkopts)
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
    materialized_metadata = (
        "go_macro_single_service_target__wrapped_" +
        "go_macro_single_service_target_topt_bazel_metadata.json"
    )
    asserts.equals(env, 3, len(files))
    asserts.true(env, _has_file_basename(files, "go_macro_single_service_target"))
    asserts.true(env, _has_file_basename(files, "go_macro_single_service_target__wrapped_go_macro_single_service_target__raw_go_test.sh"))
    asserts.true(env, _has_file_basename(files, materialized_metadata))
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
    asserts.equals(env, "true", run_env.get("DD_CIVISIBILITY_ENABLED"))
    asserts.equals(env, None, run_env.get("DD_TRACE_AGENT_URL"))
    asserts.equals(env, None, run_env.get("DD_CIVISIBILITY_AGENTLESS_ENABLED"))
    asserts.equals(env, None, run_env.get("DD_CIVISIBILITY_AGENTLESS_URL"))
    asserts.equals(env, "1", run_env.get("CUSTOM_ENV"))
    return analysistest.end(env)

def _go_macro_test_optimization_public_wrapper_mode_test_impl(ctx):
    """Assert dd_topt_go_test forwards the optimized mode to the public wrapper."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    asserts.true(
        env,
        _has_file_basename(
            files,
            (
                "go_macro_test_optimization_public_wrapper_mode_target__wrapped_" +
                "go_macro_test_optimization_public_wrapper_mode_target__raw_go_test" +
                "__orchestrion_mode_test_optimization.sh"
            ),
        ),
    )
    return analysistest.end(env)

def _go_macro_default_general_public_wrapper_mode_test_impl(ctx):
    """Assert omitted orchestrion_mode forwards the default general mode."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    asserts.true(
        env,
        _has_file_basename(
            files,
            (
                "go_macro_default_general_public_wrapper_mode_target__wrapped_" +
                "go_macro_default_general_public_wrapper_mode_target__raw_go_test" +
                "__orchestrion_mode_general.sh"
            ),
        ),
    )
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

def _validate_orchestrion_mode_invalid_target_impl(_ctx):
    """Analysis target expected to fail on invalid Orchestrion mode."""
    validate_orchestrion_mode_for_tests("invalid")
    return []

def _validate_test_optimization_pin_files_missing_go_mod_target_impl(_ctx):
    """Analysis target expected to fail when optimized mode has no go.mod pin."""
    validate_test_optimization_pin_files_for_tests(
        "test_optimization",
        ["go.sum"],
        [":test_selection_utils.bzl"],
        [":test_selection_utils.bzl"],
    )
    return []

resolve_topt_service_key_missing_target_rule = rule(
    implementation = _resolve_topt_service_key_missing_target_impl,
)

resolve_topt_service_key_unknown_target_rule = rule(
    implementation = _resolve_topt_service_key_unknown_target_impl,
)

validate_orchestrion_mode_invalid_target_rule = rule(
    implementation = _validate_orchestrion_mode_invalid_target_impl,
)

validate_test_optimization_pin_files_missing_go_mod_target_rule = rule(
    implementation = _validate_test_optimization_pin_files_missing_go_mod_target_impl,
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

def _validate_orchestrion_mode_invalid_failure_test_impl(ctx):
    """Assert invalid Orchestrion mode failures use the public attr name."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "orchestrion_mode must be one of general, test_optimization")
    return analysistest.end(env)

def _validate_test_optimization_pin_files_missing_go_mod_failure_test_impl(ctx):
    """Assert optimized mode requires a real go.mod pin."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "requires a package-local go.mod or explicit orchestrion_pin_files")
    return analysistest.end(env)

def _go_macro_orchestrion_enablement_mismatch_failure_test_impl(ctx):
    """Assert a partial upgrade fails instead of silently dropping instrumentation."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Test Optimization metadata is enabled but Orchestrion is disabled")
    asserts.expect_failure(env, "--config=test-optimization")
    asserts.expect_failure(env, "--write-bazelrc")
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

def _windows_wrapper_uses_file_payload_mode_test_impl(ctx):
    """Assert Windows launchers preserve Bazel file mode instead of proxying uploads."""
    env = unittest.begin(ctx)
    content = windows_wrapper_content_for_tests("raw.exe", "target_metadata.json")
    asserts.true(env, "bazel_target_metadata.json" in content)
    asserts.true(env, '"%SCRIPT_DIR%target_metadata.json"' in content)
    asserts.false(env, "META_BASENAME" in content)
    asserts.true(env, '"%ACTUAL%" %*' in content)
    asserts.true(env, "exit /b %ERRORLEVEL%" in content)
    asserts.false(env, "DD_TRACE_AGENT_URL" in content)
    asserts.false(env, "DD_CIVISIBILITY_AGENTLESS_ENABLED" in content)
    asserts.false(env, "DD_CIVISIBILITY_AGENTLESS_URL" in content)
    asserts.false(env, "CAPTURE_PORT" in content)
    asserts.false(env, "HELPER" in content)
    return unittest.end(env)

def _has_package_local_go_mod_test_impl(ctx):
    """Assert auto-discovered pin-file validation requires the module file."""
    env = unittest.begin(ctx)
    asserts.true(env, has_package_local_go_mod_for_tests(["go.mod", "go.sum"]))
    asserts.false(env, has_package_local_go_mod_for_tests(["go.sum", "orchestrion.yml"]))
    asserts.false(env, has_package_local_go_mod_for_tests([]))
    return unittest.end(env)

def _has_go_mod_pin_test_impl(ctx):
    """Assert explicit optimized-mode pin validation looks for go.mod labels."""
    env = unittest.begin(ctx)
    asserts.true(env, has_go_mod_pin_for_tests(["//:go.mod"]))
    asserts.true(env, has_go_mod_pin_for_tests([":go.mod"]))
    asserts.true(env, has_go_mod_pin_for_tests(["nested/go.mod"]))
    asserts.false(env, has_go_mod_pin_for_tests([":test_selection_utils.bzl"]))
    asserts.false(env, has_go_mod_pin_for_tests([]))
    return unittest.end(env)

def _validate_orchestrion_mode_test_impl(ctx):
    """Assert the public mode accepts only supported values."""
    env = unittest.begin(ctx)
    validate_orchestrion_mode_for_tests("general")
    validate_orchestrion_mode_for_tests("test_optimization")
    return unittest.end(env)

def _orch_transition_forwards_mode_test_impl(ctx):
    """Assert the wrapper transition forwards only the Orchestrion mode."""
    env = unittest.begin(ctx)
    result = orch_transition_impl_for_tests(None, struct(orchestrion_mode = "test_optimization"))
    asserts.equals(env, 1, len(result))
    asserts.equals(env, "test_optimization", result["@rules_go//go/private/orchestrion:mode"])
    asserts.false(env, "@rules_go//go/private/orchestrion:enabled" in result)
    return unittest.end(env)

def _orch_wrapper_materialized_actual_non_windows_test_impl(ctx):
    """Assert the wrapper target ships transitioned inputs as siblings."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    runfiles = target[DefaultInfo].default_runfiles.files.to_list()
    materialized_metadata = (
        "orch_wrapper_materialized_actual_non_windows_target__wrapped_" +
        "orch_wrapper_materialized_actual_non_windows_target_metadata.json"
    )
    asserts.equals(env, 3, len(files))
    asserts.true(env, _has_file_basename(files, "orch_wrapper_materialized_actual_non_windows_target"))
    asserts.true(env, _has_file_basename(files, "orch_wrapper_materialized_actual_non_windows_target__wrapped_hello_test__raw_go_test"))
    asserts.true(env, _has_file_basename(files, materialized_metadata))
    asserts.true(env, _has_file_basename(runfiles, "orch_wrapper_materialized_actual_non_windows_target__wrapped_hello_test__raw_go_test"))
    asserts.true(env, _has_file_basename(runfiles, materialized_metadata))
    return analysistest.end(env)

def _orch_wrapper_materialized_actual_windows_test_impl(ctx):
    """Assert the Windows wrapper target ships transitioned inputs as siblings."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = target[DefaultInfo].files.to_list()
    runfiles = target[DefaultInfo].default_runfiles.files.to_list()
    materialized_metadata = (
        "orch_wrapper_materialized_actual_windows_target__wrapped_" +
        "orch_wrapper_materialized_actual_windows_target_metadata.json"
    )
    asserts.equals(env, 3, len(files))
    asserts.true(env, _has_file_basename(files, "orch_wrapper_materialized_actual_windows_target.bat"))
    asserts.true(env, _has_file_basename(files, "orch_wrapper_materialized_actual_windows_target__wrapped_hello_test__raw_go_test.exe"))
    asserts.true(env, _has_file_basename(files, materialized_metadata))
    asserts.true(env, _has_file_basename(runfiles, "orch_wrapper_materialized_actual_windows_target__wrapped_hello_test__raw_go_test.exe"))
    asserts.true(env, _has_file_basename(runfiles, materialized_metadata))
    return analysistest.end(env)

go_macro_single_service_wiring_test = analysistest.make(
    _go_macro_single_service_wiring_test_impl,
)
go_macro_inferred_importpath_metadata_test = analysistest.make(
    _go_macro_inferred_importpath_metadata_test_impl,
)
go_macro_disabled_raw_wiring_test = analysistest.make(
    _go_macro_disabled_raw_wiring_test_impl,
)
go_macro_multi_service_wiring_test = analysistest.make(
    _go_macro_multi_service_wiring_test_impl,
)
go_macro_dynamic_manifest_wiring_test = analysistest.make(
    _go_macro_dynamic_manifest_wiring_test_impl,
)
go_macro_dynamic_manifest_payloads_test = analysistest.make(
    _go_macro_dynamic_manifest_payloads_test_impl,
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
go_macro_ci_visibility_opt_out_wiring_test = analysistest.make(
    _go_macro_ci_visibility_opt_out_wiring_test_impl,
)
go_macro_stage_sources_wiring_test = analysistest.make(
    _go_macro_stage_sources_wiring_test_impl,
)
go_macro_stage_sources_rundir_wiring_test = analysistest.make(
    _go_macro_stage_sources_rundir_wiring_test_impl,
)
go_macro_stage_sources_select_wiring_test = analysistest.make(
    _go_macro_stage_sources_select_wiring_test_impl,
)
go_macro_orchestrion_pin_files_wiring_test = analysistest.make(
    _go_macro_orchestrion_pin_files_wiring_test_impl,
)
go_macro_orchestrion_pin_files_provider_test = analysistest.make(
    _go_macro_orchestrion_pin_files_provider_test_impl,
)
go_macro_test_optimization_mode_wiring_test = analysistest.make(
    _go_macro_test_optimization_mode_wiring_test_impl,
)
go_macro_test_optimization_linker_default_wiring_test = analysistest.make(
    _go_macro_test_optimization_linker_default_wiring_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
    },
)
go_macro_test_optimization_linker_metadata_opt_test = analysistest.make(
    _go_macro_test_optimization_linker_metadata_true_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
    },
)
go_macro_test_optimization_linker_metadata_default_test = analysistest.make(
    _go_macro_test_optimization_linker_metadata_false_test_impl,
)
go_macro_test_optimization_linker_metadata_dbg_test = analysistest.make(
    _go_macro_test_optimization_linker_metadata_false_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
    },
)
go_macro_test_optimization_linker_metadata_strip_never_test = analysistest.make(
    _go_macro_test_optimization_linker_metadata_false_test_impl,
    config_settings = {
        "//command_line_option:strip": "never",
    },
)
go_macro_test_optimization_linker_metadata_opt_out_test = analysistest.make(
    _go_macro_test_optimization_linker_metadata_false_test_impl,
)
go_macro_test_optimization_linker_opt_out_wiring_test = analysistest.make(
    _go_macro_test_optimization_linker_opt_out_wiring_test_impl,
)
go_macro_general_mode_linker_flags_wiring_test = analysistest.make(
    _go_macro_general_mode_linker_flags_wiring_test_impl,
)
go_macro_explicit_service_wiring_test = analysistest.make(
    _go_macro_explicit_service_wiring_test_impl,
)
go_macro_public_wrapper_test = analysistest.make(
    _go_macro_public_wrapper_test_impl,
    config_settings = {
        _ORCHESTRION_ENABLED_SETTING: True,
    },
)
go_macro_test_optimization_public_wrapper_mode_test = analysistest.make(
    _go_macro_test_optimization_public_wrapper_mode_test_impl,
    config_settings = {
        _ORCHESTRION_ENABLED_SETTING: True,
    },
)
go_macro_default_general_public_wrapper_mode_test = analysistest.make(
    _go_macro_default_general_public_wrapper_mode_test_impl,
    config_settings = {
        _ORCHESTRION_ENABLED_SETTING: True,
    },
)
resolve_topt_service_key_missing_failure_test = analysistest.make(
    _resolve_topt_service_key_missing_failure_test_impl,
    expect_failure = True,
)
resolve_topt_service_key_unknown_failure_test = analysistest.make(
    _resolve_topt_service_key_unknown_failure_test_impl,
    expect_failure = True,
)
validate_orchestrion_mode_invalid_failure_test = analysistest.make(
    _validate_orchestrion_mode_invalid_failure_test_impl,
    expect_failure = True,
)
validate_test_optimization_pin_files_missing_go_mod_failure_test = analysistest.make(
    _validate_test_optimization_pin_files_missing_go_mod_failure_test_impl,
    expect_failure = True,
)
go_macro_orchestrion_enablement_mismatch_failure_test = analysistest.make(
    _go_macro_orchestrion_enablement_mismatch_failure_test_impl,
    expect_failure = True,
)
wrapper_output_name_non_windows_test = analysistest.make(
    _wrapper_output_name_non_windows_test_impl,
)
wrapper_output_name_windows_test = analysistest.make(
    _wrapper_output_name_windows_test_impl,
)
windows_wrapper_uses_file_payload_mode_test = unittest.make(
    _windows_wrapper_uses_file_payload_mode_test_impl,
)
has_package_local_go_mod_test = unittest.make(
    _has_package_local_go_mod_test_impl,
)
has_go_mod_pin_test = unittest.make(
    _has_go_mod_pin_test_impl,
)
validate_orchestrion_mode_test = unittest.make(
    _validate_orchestrion_mode_test_impl,
)
orch_transition_forwards_mode_test = unittest.make(
    _orch_transition_forwards_mode_test_impl,
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
