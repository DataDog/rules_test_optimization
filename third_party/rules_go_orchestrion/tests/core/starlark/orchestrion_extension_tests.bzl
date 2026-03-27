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

def _parse_certutil_sha256_test(ctx):
    env = unittest.begin(ctx)

    output = """SHA256 hash of C:\\Users\\runneradmin\\orchestrion.exe:
58 91 b5 b5 22 d5 df 08 6d 0f f0 b1 10 fb d9 d2
1b b4 fc 71 63 af 34 d0 82 86 a2 e8 46 f6 be 03
CertUtil: -hashfile command completed successfully.
"""

    digest = orchestrion_extension_test_helpers.parse_certutil_sha256(output)
    asserts.equals(env, "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03", digest)

    return unittest.end(env)

parse_certutil_sha256_test = unittest.make(_parse_certutil_sha256_test)

def _powershell_single_quoted_literal_test(ctx):
    env = unittest.begin(ctx)

    path = "C:/Users/O'Reilly Runner/orchestrion.exe"
    quoted = orchestrion_extension_test_helpers.powershell_single_quoted_literal(path)

    asserts.equals(env, "'C:/Users/O''Reilly Runner/orchestrion.exe'", quoted)

    return unittest.end(env)

powershell_single_quoted_literal_test = unittest.make(_powershell_single_quoted_literal_test)

def _host_platform_normalization_test(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "darwin", orchestrion_extension_test_helpers.normalize_host_goos("mac os x"))
    asserts.equals(env, "windows", orchestrion_extension_test_helpers.normalize_host_goos("windows_nt"))
    asserts.equals(env, "linux", orchestrion_extension_test_helpers.normalize_host_goos("linux"))
    asserts.equals(env, "arm64", orchestrion_extension_test_helpers.normalize_host_goarch("aarch64"))
    asserts.equals(env, "amd64", orchestrion_extension_test_helpers.normalize_host_goarch("x86_64"))
    asserts.equals(env, "riscv64", orchestrion_extension_test_helpers.normalize_host_goarch("riscv64"))

    return unittest.end(env)

host_platform_normalization_test = unittest.make(_host_platform_normalization_test)

def _fallback_go_tool_identity_test(ctx):
    env = unittest.begin(ctx)

    fallback = orchestrion_extension_test_helpers.fallback_go_tool_identity(
        struct(
            os = struct(
                name = "mac os x",
                arch = "aarch64",
            ),
        ),
    )
    asserts.equals(env, "unknown-go-version", fallback.version)
    asserts.equals(env, "darwin", fallback.goos)
    asserts.equals(env, "arm64", fallback.goarch)

    return unittest.end(env)

fallback_go_tool_identity_test = unittest.make(_fallback_go_tool_identity_test)

def orchestrion_extension_test_suite():
    unittest.suite(
        "orchestrion_extension_tests",
        bootstrap_cache_key_stability_test,
        fallback_go_tool_identity_test,
        host_platform_normalization_test,
        parse_certutil_sha256_test,
        powershell_single_quoted_literal_test,
    )
