load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//go/private/orchestrion:extensions.bzl", "orchestrion_extension_test_helpers")

def _needs_tidy_retry_cases_test(ctx):
    env = unittest.begin(ctx)

    asserts.true(
        env,
        orchestrion_extension_test_helpers.needs_tidy_retry(
            "",
            "go: missing go.sum entry for module providing package github.com/DataDog/dd-trace-go/v2",
        ),
    )
    asserts.true(
        env,
        orchestrion_extension_test_helpers.needs_tidy_retry(
            "",
            "go: updates to go.mod needed; to update it:\n\tgo mod tidy",
        ),
    )
    asserts.true(
        env,
        orchestrion_extension_test_helpers.needs_tidy_retry(
            "",
            "go: github.com/DataDog/dd-trace-go/v2@v2.7.0: go.mod file indicates go 1.24, but maximum supported version is 1.23",
        ),
    )
    asserts.true(
        env,
        orchestrion_extension_test_helpers.needs_tidy_retry(
            "",
            "internal/bootstrap.go:12:2: no required module provides package github.com/DataDog/dd-trace-go/v2/orchestrion; to add it:\n\tgo get github.com/DataDog/dd-trace-go/v2/orchestrion",
        ),
    )

    asserts.false(
        env,
        orchestrion_extension_test_helpers.needs_tidy_retry(
            "",
            "internal/bootstrap.go:15:2: undefined: someIdentifier",
        ),
    )
    asserts.false(
        env,
        orchestrion_extension_test_helpers.needs_tidy_retry(
            "",
            "Could not patch Orchestrion resolver in internal/jobserver/pkgs/resolve.go",
        ),
    )

    return unittest.end(env)

needs_tidy_retry_cases_test = unittest.make(_needs_tidy_retry_cases_test)

def _bootstrap_cache_key_stability_test(ctx):
    env = unittest.begin(ctx)

    go_identity = struct(
        version = "go version go1.24.0 darwin/arm64",
        goos = "darwin",
        goarch = "arm64",
    )
    ordered_versions = {
        "github.com/DataDog/dd-trace-go/v2": "v2.7.0",
        "github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.7.0",
        "github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.7.0",
    }
    reordered_versions = {
        "github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.7.0",
        "github.com/DataDog/dd-trace-go/v2": "v2.7.0",
        "github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.7.0",
    }

    ordered_key = orchestrion_extension_test_helpers.bootstrap_cache_key("v1.5.0", ordered_versions, go_identity)
    reordered_key = orchestrion_extension_test_helpers.bootstrap_cache_key("v1.5.0", reordered_versions, go_identity)

    asserts.equals(env, ordered_key, reordered_key)

    return unittest.end(env)

bootstrap_cache_key_stability_test = unittest.make(_bootstrap_cache_key_stability_test)

def orchestrion_extension_test_suite():
    unittest.suite(
        "orchestrion_extension_tests",
        needs_tidy_retry_cases_test,
        bootstrap_cache_key_stability_test,
    )
