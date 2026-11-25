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
    tag = "pre-release-29ee9f1",
    runtime_version = "v0.0.0-pre-release-29ee9f1",
    contract = "1",
    sdk_name = "ddto",
    url = "https://github.com/DataDog/ddtest/releases/download/{tag}/{asset}",
    sha256 = {
        "darwin_amd64": "6c71ba0893aa11e44afc1dea5dbc616df516fb199a0b45eaa2ce2ae8f4d68d62",
        "darwin_arm64": "2ed828d557a4e9e0e7d113d25add7a2b555f6cb5d6a6d914f1c788ee2eae55de",
        "linux_amd64": "9a7b9f78eab5f7816a99c3950e266fa8e4e3a34225830da28456d7636f153298",
        "linux_arm64": "5feb68ecdf25145a225c2d972db90ca9f173b6841c0a31f8fed15f5a37cc9d93",
        "windows_amd64": "d33e5bf224b907762abd55bdeaee83fca6c7ab88a0bad17dcd2fce163e4c9183",
        "windows_arm64": "dd9d298621ca09b74f3ae5def7ee9a4d726c67a4bd8fa8beecb4a3287a8c8320",
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
