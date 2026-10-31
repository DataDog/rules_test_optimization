# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Unit tests for the ddtest repositories' pure helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//:topt_go_ddtest_extension.bzl", "sdk_config")
load(
    "//:topt_go_ddtest_repository.bzl",
    "DDTEST_RELEASE",
    "PLATFORMS",
    "base_sdk_version_error",
    "contract_error",
    "ddtest_asset",
    "go_version_from_go_mod",
    "host_platform",
    "parse_contract",
    "sdk_variant_id",
    "sdk_variants_error",
    "sdk_version_matches",
    "toolchains_build_content",
)

def _go_version_from_go_mod_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "1.26.3", go_version_from_go_mod("module x\n\ngo 1.25.0\n\ntoolchain go1.26.3\n"))
    asserts.equals(env, "1.25.4", go_version_from_go_mod("module x\ngo 1.25.4\n"))
    asserts.equals(env, "1.25.0", go_version_from_go_mod("module x\ngo 1.25\n"))
    asserts.equals(env, "1.20", go_version_from_go_mod("module x\ngo 1.20\n"))
    asserts.equals(env, None, go_version_from_go_mod("module x\n"))
    return unittest.end(env)

go_version_from_go_mod_test = unittest.make(_go_version_from_go_mod_test)

def _contract_test(ctx):
    env = unittest.begin(ctx)
    good = "version=%s\ncontract=%s\nsdk_name=%s\n" % (DDTEST_RELEASE.runtime_version, DDTEST_RELEASE.contract, DDTEST_RELEASE.sdk_name)
    asserts.equals(env, None, contract_error(parse_contract(good), "test"))

    # The release tag is not what the runtime records.
    tagged = good.replace(DDTEST_RELEASE.runtime_version, DDTEST_RELEASE.tag)
    asserts.true(env, "version" in contract_error(parse_contract(tagged), "test"))
    asserts.true(env, "contract" in contract_error(parse_contract(good.replace("contract=1", "contract=2")), "test"))
    asserts.true(env, "sdk_name" in contract_error(parse_contract(good.replace("sdk_name=ddto", "sdk_name=go")), "test"))
    asserts.true(env, "contract" in contract_error(parse_contract(""), "test"))
    return unittest.end(env)

contract_test = unittest.make(_contract_test)

def _platforms_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "ddtest-windows-arm64.exe", ddtest_asset("windows_arm64"))
    asserts.equals(env, "ddtest-linux-amd64", ddtest_asset("linux_amd64"))
    asserts.equals(env, "darwin_arm64", host_platform("Mac OS X", "aarch64"))
    asserts.equals(env, "linux_amd64", host_platform("linux", "amd64"))
    asserts.equals(env, "windows_amd64", host_platform("Windows 11", "amd64"))
    asserts.equals(env, None, host_platform("freebsd", "amd64"))
    asserts.equals(env, None, host_platform("linux", "s390x"))
    for platform in PLATFORMS:
        asserts.true(env, platform in DDTEST_RELEASE.sha256, "no checksum for %s" % platform)
    return unittest.end(env)

platforms_test = unittest.make(_platforms_test)

def _toolchains_build_content_test(ctx):
    env = unittest.begin(ctx)
    content = toolchains_build_content([
        {"id": "", "matches": sdk_version_matches("1.26.3"), "exec_platforms": ["linux_amd64"]},
        {"id": "v1_26_3fips", "matches": ["1.26.3fips"], "exec_platforms": ["linux_amd64", "linux_arm64"]},
    ])

    # One toolchain per SDK, exec and target platform, and the catch-all.
    asserts.equals(env, 3 * len(PLATFORMS) + 1, content.count("toolchain("))
    asserts.true(env, "toolchain = \"@topt_go_ddtest_sdk_linux_amd64//:go_darwin_arm64-impl\"" in content)
    asserts.true(env, "toolchain = \"@topt_go_ddtest_sdk_v1_26_3fips_linux_arm64//:go_darwin_arm64-impl\"" in content)
    asserts.true(env, "exec_compatible_with = [\"@platforms//os:linux\", \"@platforms//cpu:x86_64\"]" in content)
    asserts.equals(env, len(PLATFORMS), content.count("target_settings = [\":sdk_name_ddto\", \":sdk_version\"]"))
    asserts.equals(env, 2 * len(PLATFORMS), content.count("target_settings = [\":sdk_name_ddto\", \":v1_26_3fips_sdk_version\"]"))
    asserts.true(env, "\"@io_bazel_rules_go//go/toolchain:sdk_name\": \"ddto\"" in content)
    for value in ["", "1", "1.26", "1.26.3", "1.26.3fips"]:
        asserts.true(env, "\"@io_bazel_rules_go//go/toolchain:sdk_version\": \"%s\"" % value in content, "no setting for %r" % value)

    # The catch-all matches only a value that no SDK serves, whatever the
    # order of registration and of exec platforms.
    asserts.true(env, "target_settings = [\":sdk_name_ddto\", \":sdk_version_unserved\"]" in content)
    asserts.true(env, "\":sdk_version_served\": \":sdk_name_unset\"" in content)
    served = content.split("name = \"sdk_version_served\",")[1].split(")")[0]
    asserts.equals(env, 5, served.count(":"))
    asserts.true(env, "No instrumented Go SDK matches sdk_version \\\"{sdk_version}\\\"" in content)
    asserts.true(env, "sdk_version \\\"1.26.3fips\\\" on linux_amd64, linux_arm64" in content)

    unconfigured = toolchains_build_content([])
    asserts.equals(env, 1, unconfigured.count("toolchain("))
    asserts.true(env, "topt_go_ddtest_unconfigured(" in unconfigured)
    asserts.true(env, "target_settings = [\":sdk_name_ddto\"]" in unconfigured)
    asserts.true(env, "selects" not in unconfigured)
    return unittest.end(env)

toolchains_build_content_test = unittest.make(_toolchains_build_content_test)

def _sdk_versions_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ["", "1", "1.26", "1.26.3"], sdk_version_matches("1.26.3"))
    asserts.equals(env, ["", "1", "1.26", "1.26.0", "1.26.0rc2", "1.26rc2"], sdk_version_matches("1.26rc2"))
    asserts.equals(env, [""], sdk_version_matches(None))
    asserts.equals(env, "v1_26_3fips", sdk_variant_id("1.26.3fips"))
    asserts.equals(env, None, sdk_variants_error("1.26.3", [{"sdk_version": "1.25.9"}, {"sdk_version": "1.26.3fips", "experiments": ["boringcrypto"]}]))

    # A value that the default SDK serves, two variants with one repository
    # name, a variant without sdk_version and an unknown field.
    asserts.true(env, "already selects the default SDK" in sdk_variants_error("1.26.3", [{"sdk_version": "1.26"}]))
    asserts.true(env, "distinct repository names" in sdk_variants_error("1.26.3", [{"sdk_version": "1.25.9"}, {"sdk_version": "1_25_9"}]))
    asserts.true(env, "needs the sdk_version" in sdk_variants_error("1.26.3", [{"go_version": "1.25.9"}]))
    asserts.true(env, "unknown SDK variant field \"version\"" in sdk_variants_error("1.26.3", [{"version": "1.25.9"}]))
    return unittest.end(env)

sdk_versions_test = unittest.make(_sdk_versions_test)

def _base_sdk_version_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, base_sdk_version_error("go1.26.3\ntime 2026-01-01\n", "1.26.3", "linux_amd64", ""))
    asserts.equals(env, None, base_sdk_version_error("go1.26.3 X:boringcrypto\n", "1.26.3", "linux_amd64", "1.26.3fips"))

    # Without go_version, or a VERSION file to read, there is nothing to check.
    asserts.equals(env, None, base_sdk_version_error("go1.25.9\n", "", "linux_amd64", ""))
    asserts.equals(env, None, base_sdk_version_error("", "1.26.3", "linux_amd64", ""))
    error = base_sdk_version_error("go1.25.9\n", "1.26.3", "linux_amd64", "")
    asserts.true(env, "default SDK's base SDK for linux_amd64 is Go 1.25.9, but its go_version is 1.26.3" in error)
    asserts.true(env, "SDK variant \"1.26.3fips\"" in base_sdk_version_error("go1.25.9\n", "1.26.3", "linux_amd64", "1.26.3fips"))
    return unittest.end(env)

base_sdk_version_test = unittest.make(_base_sdk_version_test)

def _sdk_tag(go_version = "", go_mod = None, sdk_version = ""):
    return struct(
        sdk_version = sdk_version,
        go_version = go_version,
        go_mod = go_mod,
        base_sdk_roots = {},
        exec_platforms = [],
        experiments = ["nocoverageredesign"],
        panic_hook = True,
    )

def _sdk_config_test(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, sdk_config([], None))
    config = sdk_config([_sdk_tag(go_version = "1.26.3")], None)
    asserts.equals(env, "1.26.3", config.go_version)
    asserts.equals(env, None, config.exec_platforms)
    asserts.equals(env, ["nocoverageredesign"], config.experiments)
    asserts.true(env, config.panic_hook)
    config = sdk_config([_sdk_tag(go_mod = "//:go.mod")], lambda label: "module x\ngo 1.25\n")
    asserts.equals(env, "1.25.0", config.go_version)

    # go_version overrides go_mod.
    config = sdk_config([_sdk_tag(go_version = "1.27.1", go_mod = "//:go.mod")], lambda label: "module x\ngo 1.25\n")
    asserts.equals(env, "1.27.1", config.go_version)
    asserts.equals(env, [], config.sdk_variants)

    # The tag without sdk_version is the default SDK, wherever it is.
    config = sdk_config([
        _sdk_tag(sdk_version = "1.26.3fips", go_version = "1.26.3"),
        _sdk_tag(go_version = "1.27.1"),
    ], None)
    asserts.equals(env, "1.27.1", config.go_version)
    asserts.equals(env, 1, len(config.sdk_variants))
    asserts.equals(env, "1.26.3fips", config.sdk_variants[0]["sdk_version"])
    asserts.equals(env, "1.26.3", config.sdk_variants[0]["go_version"])
    asserts.equals(env, ["nocoverageredesign"], config.sdk_variants[0]["experiments"])
    return unittest.end(env)

sdk_config_test = unittest.make(_sdk_config_test)
