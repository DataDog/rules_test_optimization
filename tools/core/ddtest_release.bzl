# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""The pinned ddtest release and the repository of the host's executable.

One ddtest executable serves the whole module: the uploader runs it to send
payloads, and the Go companion runs it to write Mini and the instrumented
SDKs. The repository downloads it once, for the host that runs Bazel.
"""

# The pinned ddtest release. The tag names the release; what ddtest writes
# records the runtime's SemVer version, with v0.0.0- before a pre-release's
# name.
DDTEST_RELEASE = struct(
    tag = "pre-release-adf721e",
    runtime_version = "v0.0.0-pre-release-adf721e",
    contract = "1",
    sdk_name = "ddto",
    url = "https://github.com/DataDog/ddtest/releases/download/{tag}/{asset}",
    sha256 = {
        "darwin_amd64": "9129e2f7dc082b621cd22542ba255403c4810ac9c3ba0699cce33815dd769493",
        "darwin_arm64": "023e723c2a7a13720d56f5c1ad1d482eb03dee2822407d6f1b9a928879938980",
        "linux_amd64": "944719a0c108e7c0a5513d080eab390c1e1b339df9715a2d2be02b9d37d5f2a7",
        "linux_arm64": "d4ef4aca2076f74ef69db350a31bf0ce7efe3a65a0dfa7183203d12de0e8b12f",
        "windows_amd64": "ea939e13bc265af2eea5f1b5ad84a7db4b2600c6708b2319a03230648e6a862f",
        "windows_arm64": "d43496f10f1c00205649b77fce1f47db6a8d00d3d261445dccb0ff7fc0d1f2d5",
    },
)

# The repository of the host's executable. Its name is stable: the Go
# companion and WORKSPACE helpers refer to it.
DDTEST_REPO = "topt_ddtest"

def ddtest_asset(platform):
    """Release asset name of ddtest's executable for a platform."""
    goos, goarch = platform.split("_")
    return "ddtest-%s-%s%s" % (goos, goarch, ".exe" if goos == "windows" else "")

def host_platform(os_name, os_arch):
    """Map repository_ctx.os values to a ddtest platform, or None."""
    os_name = os_name.lower()
    if os_name.startswith("mac os"):
        goos = "darwin"
    elif os_name.startswith("linux"):
        goos = "linux"
    elif os_name.startswith("windows"):
        goos = "windows"
    else:
        return None
    goarch = {"amd64": "amd64", "x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(os_arch)
    if not goarch:
        return None
    return goos + "_" + goarch

def download_ddtest(rctx, platform, output):
    """Download the pinned release's executable for platform to output."""
    rctx.download(
        url = DDTEST_RELEASE.url.format(tag = DDTEST_RELEASE.tag, asset = ddtest_asset(platform)),
        output = output,
        sha256 = DDTEST_RELEASE.sha256[platform],
        executable = True,
    )
    return rctx.path(output)

def _ddtest_host_impl(rctx):
    platform = host_platform(rctx.os.name, rctx.os.arch)
    if not platform:
        fail("ddtest has no executable for this host: %s/%s" % (rctx.os.name, rctx.os.arch))
    download_ddtest(rctx, platform, "ddtest" + (".exe" if platform.startswith("windows") else ""))
    rctx.file("PLATFORM", platform)
    rctx.file("BUILD.bazel", "\n".join([
        'package(default_visibility = ["//visibility:public"])',
        "",
        'exports_files(["PLATFORM"])',
        "",
        "# The host's executable, whatever its file name on the host.",
        "filegroup(",
        '    name = "executable",',
        '    srcs = ["ddtest%s"],' % (".exe" if platform.startswith("windows") else ""),
        ")",
        "",
    ]))

ddtest_host_repository = repository_rule(
    implementation = _ddtest_host_impl,
    doc = "The host's ddtest executable, from the pinned release, and a PLATFORM file that names its platform.",
)

def datadog_test_optimization_ddtest_repositories():
    """Declare the ddtest repository in WORKSPACE, unless it exists already.

    Language helpers call it; a WORKSPACE that declares the module's
    repositories itself calls it once, after the core module.
    """
    if not native.existing_rule(DDTEST_REPO):
        ddtest_host_repository(name = DDTEST_REPO)
