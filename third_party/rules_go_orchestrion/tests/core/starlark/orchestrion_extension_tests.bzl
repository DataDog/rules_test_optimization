load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//go/private/orchestrion:extensions.bzl", "orchestrion_extension_test_helpers")

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

def _powershell_single_quoted_literal_test(ctx):
    env = unittest.begin(ctx)

    path = "C:/Users/O'Reilly Runner/orchestrion.exe"
    quoted = orchestrion_extension_test_helpers.powershell_single_quoted_literal(path)

    asserts.equals(env, "'C:/Users/O''Reilly Runner/orchestrion.exe'", quoted)

    return unittest.end(env)

powershell_single_quoted_literal_test = unittest.make(_powershell_single_quoted_literal_test)

def orchestrion_extension_test_suite():
    unittest.suite(
        "orchestrion_extension_tests",
        bootstrap_cache_key_stability_test,
        powershell_single_quoted_literal_test,
    )
