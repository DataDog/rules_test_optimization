# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Package misses may reuse a bundle only inside its canonical Go module."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@datadog-rules-test-optimization//tools/core:test_optimization_repository_state.bzl", "test_optimization_repository_state")
load("@datadog-rules-test-optimization-go//:topt_go_infer.bzl", "ToptGoBazelMetadataInfo", "topt_go_bazel_metadata", "topt_go_payloads_selector")
load(":test_macro.bzl", "go_macro_dynamic_manifest_target")

def _fallback_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, ["full_payload.payload"], [f.basename for f in target[DefaultInfo].files.to_list()])
    return analysistest.end(env)

def _metadata_impl(ctx):
    env = analysistest.begin(ctx)
    metadata = analysistest.target_under_test(env)[ToptGoBazelMetadataInfo].metadata
    asserts.equals(env, "full_bundle_importpath_miss", metadata["bazel.go.payload_selection"])
    return analysistest.end(env)

def _failure_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Available module groups")
    return analysistest.end(env)

_fallback_test = analysistest.make(_fallback_impl)
_metadata_test = analysistest.make(_metadata_impl)
_failure_test = analysistest.make(_failure_impl, expect_failure = True)

def module_boundary_tests():
    """Cover real boundaries, unknown roots, inference and strict overrides."""
    cases = [
        ("root", "example.com/app", "example.com/app", "", True),
        ("subpackage", "example.com/app/new", "example.com/app", "", True),
        ("lookalike", "example.com/application/new", "example.com/app", "", False),
        ("foreign", "other.example/pkg", "example.com/app", "", False),
        ("unknown", "example.com/app/new", "", "", False),
        ("override", "example.com/app/new", "example.com/app", "missing", False),
    ]
    for name, importpath, root, override, accepted in cases:
        attrs = dict(
            module_groups = [":module_example_com_explicit_pkg"],
            module_group_by_identifier = {"example.com/app/known": "module_example_com_explicit_pkg"},
            explicit_importpath = importpath,
            runtime_module_path = root,
            module_label_override = override,
            tags = ["manual"],
        )
        topt_go_payloads_selector(name = "boundary_" + name, full_files = ":full_payload", **attrs)
        (_fallback_test if accepted else _failure_test)(
            name = "boundary_" + name + "_test",
            target_under_test = ":boundary_" + name,
        )
        if accepted:
            topt_go_bazel_metadata(
                name = "boundary_" + name + "_metadata",
                bazel_package = "//tests",
                bazel_target = "//tests:new_test",
                repo_name = "test_optimization_data",
                service_name = "boundary-service",
                **attrs
            )
            _metadata_test(name = "boundary_" + name + "_metadata_test", target_under_test = ":boundary_" + name + "_metadata")
    topt_go_payloads_selector(
        name = "boundary_inferred",
        embeds = [":explicit_embed_library"],
        module_groups = [":module_example_com_explicit_pkg"],
        runtime_module_path = "example.com/embed",
        full_files = ":full_payload",
        tags = ["manual"],
    )
    _fallback_test(name = "boundary_inferred_test", target_under_test = ":boundary_inferred")

    test_optimization_repository_state(
        name = "boundary_state",
        enabled = True,
        runtime_module_included = False,
        repo_name = "boundary_sync",
        runtime_name = "go",
        service_name = "boundary-service",
        runtime_module_path = "example.com/app",
        module_groups = [":module_example_com_explicit_pkg"],
        module_group_names = ["module_example_com_explicit_pkg"],
    )
    topt_go_payloads_selector(
        name = "boundary_static",
        explicit_importpath = "example.com/app/new",
        full_files = ":full_payload",
        repository_state = ":boundary_state",
        expected_repo_name = "boundary_sync",
        expected_service_name = "boundary-service",
        expected_runtime_module_path = "example.com/app",
        # A dynamic attribute cannot replace the repository's validated state.
        runtime_module_path = "other.example/untrusted",
        tags = ["manual"],
    )
    _fallback_test(name = "boundary_static_test", target_under_test = ":boundary_static")
    go_macro_dynamic_manifest_target(name = "boundary_dynamic", importpath = "example.com/stub/new", tags = ["manual"])
    _metadata_test(name = "boundary_dynamic_metadata_test", target_under_test = ":boundary_dynamic_topt_bazel_metadata")
    _fallback_test(name = "boundary_dynamic_test", target_under_test = ":boundary_dynamic_topt_payloads")
