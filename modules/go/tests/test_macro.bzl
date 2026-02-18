"""Analysis tests for dd_topt_go_test macro wiring.

Maintainer goals covered here:
- Guard the macro contract for `data`/`env` wiring.
- Verify default vs custom `rundir` behavior.
- Verify multi-service key resolution (including sanitized keys).
- Keep service-resolution failure messages actionable for users.

Why this harness exists:
`dd_topt_go_test` requires a `go_test_rule` symbol from callers. These tests
inject a lightweight fake rule to capture what the macro forwards, so we can
assert behavior at analysis time without compiling Go code.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "//:topt_go_test.bzl",
    "dd_topt_go_test",
    "resolve_topt_service_key_for_tests",
)

ToptGoMacroCaptureInfo = provider(
    doc = "Captured arguments forwarded by dd_topt_go_test to go_test_rule.",
    fields = {
        "data_labels": "Forwarded data dependency labels.",
        "env": "Forwarded environment map.",
        "importpath": "Forwarded importpath attribute.",
        "rundir": "Forwarded runtime working directory.",
    },
)

def _go_test_capture_impl(ctx):
    """Capture macro-forwarded attributes for analysistest assertions."""
    return [ToptGoMacroCaptureInfo(
        data_labels = [str(dep.label) for dep in ctx.attr.data],
        env = dict(ctx.attr.env),
        importpath = ctx.attr.importpath,
        rundir = ctx.attr.rundir,
    )]

def _has_fragment(items, fragment):
    for item in items:
        if fragment in item:
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
)

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
        },
    }

def _multi_service_topt_data():
    selected = _single_service_topt_data()
    not_selected = dict(selected)
    not_selected["repo_name"] = "unused_repo_for_selection_test"
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
    """Target expected to fail when rundir drifts from package name."""
    dd_topt_go_test(
        name = name,
        topt_data = _single_service_topt_data(),
        go_test_rule = _go_test_capture_rule,
        rundir = "custom/rundir",
        tags = tags,
    )

def _go_macro_single_service_wiring_test_impl(ctx):
    """Assert env/data/rundir contract for single-service macro usage."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]

    asserts.true(env, _has_fragment(captured.data_labels, "go_macro_single_service_target_topt_payloads"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_macro.bzl"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_optimization_data"))
    asserts.true(env, _has_fragment(captured.data_labels, ".testoptimization/manifest.txt"))

    manifest_env = captured.env.get("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
    asserts.true(env, manifest_env != None)
    asserts.true(env, "rlocationpath" in manifest_env)
    asserts.true(env, "test_optimization_data" in manifest_env)
    asserts.true(env, ".testoptimization/manifest.txt" in manifest_env)
    asserts.equals(env, "true", captured.env.get("DD_TEST_OPTIMIZATION_PAYLOADS_IN_FILES"))
    asserts.equals(env, "1", captured.env.get("CUSTOM_ENV"))
    asserts.equals(env, "tests", captured.rundir)
    return analysistest.end(env)

def _go_macro_multi_service_wiring_test_impl(ctx):
    """Assert multi-service key resolution and passthrough attributes."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]

    asserts.true(env, _has_fragment(captured.data_labels, "go_macro_multi_service_target_topt_payloads"))
    asserts.true(env, _has_fragment(captured.data_labels, "test_optimization_data"))
    asserts.true(env, _has_fragment(captured.data_labels, ".testoptimization/manifest.txt"))
    asserts.equals(env, "example.com/override/pkg", captured.importpath)
    asserts.equals(env, "tests", captured.rundir)
    return analysistest.end(env)

def _go_macro_rundir_mismatch_wiring_test_impl(ctx):
    """Assert custom rundir is normalized back to package default."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    captured = target[ToptGoMacroCaptureInfo]
    asserts.equals(env, "tests", captured.rundir)
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

go_macro_single_service_wiring_test = analysistest.make(
    _go_macro_single_service_wiring_test_impl,
)
go_macro_multi_service_wiring_test = analysistest.make(
    _go_macro_multi_service_wiring_test_impl,
)
go_macro_rundir_mismatch_wiring_test = analysistest.make(
    _go_macro_rundir_mismatch_wiring_test_impl,
)
resolve_topt_service_key_missing_failure_test = analysistest.make(
    _resolve_topt_service_key_missing_failure_test_impl,
    expect_failure = True,
)
resolve_topt_service_key_unknown_failure_test = analysistest.make(
    _resolve_topt_service_key_unknown_failure_test_impl,
    expect_failure = True,
)
