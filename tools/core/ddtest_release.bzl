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
    tag = "pre-release-489b45d",
    runtime_version = "v0.0.0-pre-release-489b45d",
    contract = "1",
    sdk_name = "ddto",
    url = "https://github.com/DataDog/ddtest/releases/download/{tag}/{asset}",
    sha256 = {
        "darwin_amd64": "ca1b8dad08f09bc0223086fb710d92b54423545da1b32faa8b46802d51ed5131",
        "darwin_arm64": "ee87297a018348158827bb67490790f50c2ad125edcecc69c854e6ceed32877c",
        "linux_amd64": "051380281af992171ddd6194559ef59308633d8037ed9323bf7f70df77f57be5",
        "linux_arm64": "9244269e886bc2878fd693a1fdbcaecf411a38f9f90ac95e11d41c5a1c7ed7ac",
        "windows_amd64": "56c054b9cbd9c1427fc50395fd27b0eb7dbb91499c0f7a7830103935b5ed9c51",
        "windows_arm64": "123fb4520edaf823c35273a8ad54a0c1af9755344d3c40b0559bc37c085068cc",
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
