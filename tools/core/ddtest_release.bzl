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
    tag = "pre-release-0de984d",
    runtime_version = "v0.0.0-pre-release-0de984d",
    contract = "1",
    sdk_name = "ddto",
    url = "https://github.com/DataDog/ddtest/releases/download/{tag}/{asset}",
    sha256 = {
        "darwin_amd64": "58584fef8c3c4b489108ed35652c7fef1d492f20b83020d301ad38cf16fa7fe1",
        "darwin_arm64": "95e5f8326ce6f612abee7ff0146cc84b9aa4ab9306e5ee0ba9a501e68ee5e60b",
        "linux_amd64": "b8851f43f9314cefac0bf7e8792458a156c7a945df1b127333d3f3cd2ae466fa",
        "linux_arm64": "44374f86182880479d3c14ca30a38f8420800a192e5febde86e86a17754f9726",
        "windows_amd64": "5ca4272ff6b492f0569d9c74cb8d6565b12d49a7aa2e0a81669b70557c066f05",
        "windows_arm64": "298b6142697d22b7c98e0fda78b7e0740e7476073485c8f5de11ba763fb2e7fc",
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
