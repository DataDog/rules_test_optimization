# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Fixtures and analysis tests of the ddtest instrumentation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

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
    return analysistest.end(env)

foreign_mini_failure_test = analysistest.make(
    _foreign_mini_failure_test_impl,
    expect_failure = True,
)
