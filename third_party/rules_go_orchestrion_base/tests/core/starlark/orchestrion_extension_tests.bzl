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

    ordered_key = orchestrion_extension_test_helpers.bootstrap_cache_key("v1.6.0", ordered_versions, go_identity)
    reordered_key = orchestrion_extension_test_helpers.bootstrap_cache_key("v1.6.0", reordered_versions, go_identity)

    asserts.equals(env, ordered_key, reordered_key)

    return unittest.end(env)

bootstrap_cache_key_stability_test = unittest.make(_bootstrap_cache_key_stability_test)

def _bootstrap_cache_paths_contract_test(ctx):
    env = unittest.begin(ctx)

    fake_ctx = struct(os = struct(name = "linux"))
    paths = orchestrion_extension_test_helpers.bootstrap_cache_paths(fake_ctx, "/tmp/cache-root", "cache-key", "orchestrion_bin")
    asserts.equals(env, "/tmp/cache-root", paths.cache_root)
    asserts.equals(env, "/tmp/cache-root/bootstrap/cache-key/orchestrion_bin", paths.binary_path)
    asserts.equals(env, "/tmp/cache-root/bootstrap/cache-key/orchestrion_version.txt", paths.tool_version_file_path)
    asserts.equals(env, "/tmp/cache-root/bootstrap/cache-key/module_proxy/root.marker", paths.module_proxy_root_marker)

    required = orchestrion_extension_test_helpers.bootstrap_cache_required_entries(paths)
    asserts.true(env, paths.resolved_modules_file_path in required.files, "resolved module manifest must be required")
    asserts.true(env, paths.seed_go_sum_file_path in required.files, "seed go.sum must be required")
    asserts.true(env, paths.module_proxy_root_marker in required.files, "module proxy marker must be required")

    return unittest.end(env)

bootstrap_cache_paths_contract_test = unittest.make(_bootstrap_cache_paths_contract_test)

def _module_proxy_seed_go_mod_test(ctx):
    env = unittest.begin(ctx)

    go_mod = orchestrion_extension_test_helpers.module_proxy_seed_go_mod(
        "v1.6.0",
        {
            "github.com/DataDog/dd-trace-go/v2": "v2.7.0",
            "github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.7.0",
            "github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.7.0",
        },
    )

    asserts.true(env, "go 1.21" in go_mod, "seed go.mod must keep the compatibility Go version")
    asserts.true(env, "github.com/DataDog/orchestrion v1.6.0" in go_mod, "seed go.mod must use the configured orchestrion version")
    asserts.false(env, "github.com/DataDog/orchestrion v1.5.0" in go_mod, "seed go.mod must not use the old hardcoded orchestrion version")

    return unittest.end(env)

module_proxy_seed_go_mod_test = unittest.make(_module_proxy_seed_go_mod_test)

def _module_proxy_resolved_modules_json_test(ctx):
    env = unittest.begin(ctx)

    manifest = orchestrion_extension_test_helpers.module_proxy_resolved_modules_json({
        "github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.7.0",
        "github.com/DataDog/orchestrion": "v1.6.0",
        "github.com/DataDog/dd-trace-go/v2": "v2.7.0",
    })
    http_index = manifest.find('"github.com/DataDog/dd-trace-go/contrib/net/http/v2"')
    root_index = manifest.find('"github.com/DataDog/dd-trace-go/v2"')
    orchestrion_index = manifest.find('"github.com/DataDog/orchestrion"')

    asserts.true(env, http_index < root_index and root_index < orchestrion_index, "resolved module manifest must be sorted by module path")

    return unittest.end(env)

module_proxy_resolved_modules_json_test = unittest.make(_module_proxy_resolved_modules_json_test)

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
        bootstrap_cache_paths_contract_test,
        fallback_go_tool_identity_test,
        host_platform_normalization_test,
        module_proxy_resolved_modules_json_test,
        module_proxy_seed_go_mod_test,
        parse_certutil_sha256_test,
        powershell_single_quoted_literal_test,
    )
