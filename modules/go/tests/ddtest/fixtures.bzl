# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Fixtures and analysis tests of the ddtest instrumentation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//:topt_go_ddtest.bzl", "argument_words_for_tests", "ddtest_transition_impl_for_tests")

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
    asserts.equals(
        env,
        {"@io_bazel_rules_go//go/toolchain:sdk_name": "ddto"},
        ddtest_transition_impl_for_tests(None, None),
    )
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
