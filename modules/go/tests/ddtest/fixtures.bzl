# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Fixtures and analysis tests of the ddtest instrumentation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//:topt_go_ddtest.bzl", "argument_words_for_tests", "ddtest_restore_transition_impl_for_tests", "ddtest_transition_impl_for_tests")

# The stub sync repository's export, as the macro tests use it.
TOPT_DATA = {
    "enabled": True,
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

def _foreign_mini_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "would link Mini's packages twice")
    asserts.expect_failure(env, "override_repo(go_deps, com_github_datadog_ddtest_ddto")
    asserts.expect_failure(env, "In WORKSPACE, depend on @topt_go_ddtest_mini labels")
    return analysistest.end(env)

foreign_mini_failure_test = analysistest.make(
    _foreign_mini_failure_test_impl,
    expect_failure = True,
)

def _ddtest_transition_test_impl(ctx):
    env = unittest.begin(ctx)
    sdk = "@io_bazel_rules_go//go/toolchain:sdk_name"
    skip = "@io_bazel_rules_go//go/private:bootstrap_nogo"
    original_sdk = "@io_bazel_rules_go//go/toolchain:original_sdk_name"
    original_skip = "@io_bazel_rules_go//go/private:original_bootstrap_nogo"

    # The stdlib warmup also uses this transition, without a nogo attribute.
    asserts.equals(env, {sdk: "ddto", skip: False}, ddtest_transition_impl_for_tests({skip: False}, struct()))
    for nogo in [False, True]:
        for incoming_skip in [False, True]:
            attr = struct(nogo = nogo)
            incoming = {skip: incoming_skip}
            expected = {sdk: "ddto", skip: incoming_skip or not nogo}
            values = ddtest_transition_impl_for_tests(incoming, attr)
            asserts.equals(env, expected, values)
            asserts.equals(env, values, ddtest_transition_impl_for_tests(values, attr))

            for incoming_sdk in ["", "custom-sdk", "ddto"]:
                for saved_sdk, saved_skip in [("", ""), (json.encode("parent-sdk"), "false")]:
                    incoming = {sdk: incoming_sdk, skip: incoming_skip, original_sdk: saved_sdk, original_skip: saved_skip}
                    restored = ddtest_restore_transition_impl_for_tests(incoming, attr)
                    expected = dict(values)
                    expected[original_sdk] = saved_sdk or (json.encode(incoming_sdk) if incoming_sdk != "ddto" else "")
                    expected[original_skip] = saved_skip or (json.encode(incoming_skip) if values[skip] != incoming_skip else "")
                    asserts.equals(env, expected, restored)
                    asserts.equals(env, restored, ddtest_restore_transition_impl_for_tests(restored, attr))
    return unittest.end(env)

ddtest_transition_test = unittest.make(_ddtest_transition_test_impl)

def _argument_contract_test_impl(ctx):
    env = unittest.begin(ctx)
    for value, expected in [
        ("one two", ["one", "two"]),
        ("'one two'", ["one two"]),
        ("''", [""]),
        ('a"b"c', ["abc"]),
        ("a\\ b", ["a b"]),
        ('"a\\q"', ["a\\q"]),
        ("'a\\b'", ["a\\b"]),
        ('"a\\\"b"', ['a"b']),
        ("a\tb", ["a", "b"]),
        ("a\nb", ["a\nb"]),
    ]:
        asserts.equals(env, expected, argument_words_for_tests(value))
    return unittest.end(env)

argument_contract_test = unittest.make(_argument_contract_test_impl)

def _nested_executable_depth_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    binaries = [file for file in target[DefaultInfo].files.to_list() if "__wrapped_/" in file.short_path]
    asserts.equals(env, 1, len(binaries))
    if binaries:
        asserts.equals(
            env,
            "tests/ddtest/nested/shared_answer_test__wrapped_/nested/shared_answer_test__raw_go_test",
            binaries[0].short_path,
        )
    return analysistest.end(env)

nested_executable_depth_test = analysistest.make(_nested_executable_depth_test_impl)
