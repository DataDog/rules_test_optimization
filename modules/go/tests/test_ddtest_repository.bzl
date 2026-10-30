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
    "contract_error",
    "ddtest_asset",
    "go_version_from_go_mod",
    "host_platform",
    "parse_contract",
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
    content = toolchains_build_content(["linux_amd64"])
    asserts.equals(env, len(PLATFORMS), content.count("toolchain("))
    asserts.true(env, "toolchain = \"@topt_go_ddtest_sdk_linux_amd64//:go_darwin_arm64-impl\"" in content)
    asserts.true(env, "exec_compatible_with = [\"@platforms//os:linux\", \"@platforms//cpu:x86_64\"]" in content)
    asserts.equals(env, len(PLATFORMS), content.count("target_settings = [\":sdk_name_ddto\"]"))
    asserts.true(env, "\"@io_bazel_rules_go//go/toolchain:sdk_name\": \"ddto\"" in content)

    unconfigured = toolchains_build_content([])
    asserts.equals(env, 1, unconfigured.count("toolchain("))
    asserts.true(env, "topt_go_ddtest_unconfigured(" in unconfigured)
    asserts.true(env, "target_settings = [\":sdk_name_ddto\"]" in unconfigured)
    return unittest.end(env)

toolchains_build_content_test = unittest.make(_toolchains_build_content_test)

def _sdk_tag(go_version = "", go_mod = None):
    return struct(
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
    return unittest.end(env)

sdk_config_test = unittest.make(_sdk_config_test)
