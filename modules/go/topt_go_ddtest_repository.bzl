# Unless explicitly stated otherwise all files in this repository are licensed under
# the Apache 2.0 License.
#
# This product includes software developed at Datadog
# (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

"""Repositories that instrument Go tests with `ddtest instrument bazel`.

One ddtest release provides everything. The repository host's executable
writes Mini's repository and, for each exec platform, a copy of a base Go SDK
whose compiler is that platform's executable. Toolchains gated on
`@io_bazel_rules_go//go/toolchain:sdk_name == "ddto"` select those SDKs; only
the test rule's transition sets that value, so no other build fetches them.
"""

load("@io_bazel_rules_go//go:deps.bzl", "go_download_sdk", "go_wrap_sdk")

# The pinned ddtest release. The tag names the release; what ddtest writes
# records the runtime's SemVer version, with v0.0.0- before a pre-release's
# name.
DDTEST_RELEASE = struct(
    tag = "pre-release-f5df4db",
    runtime_version = "v0.0.0-pre-release-f5df4db",
    contract = "1",
    sdk_name = "ddto",
    url = "https://github.com/DataDog/ddtest/releases/download/{tag}/{asset}",
    sha256 = {
        "darwin_amd64": "2757f07ae096d03fd964e61e21c2779650a14ac3e5ed2435dade5fbfef921667",
        "darwin_arm64": "223619f189ee31e3f8a196129c296481c61039d96c4e5aa42d909b053a46bcdb",
        "linux_amd64": "825704a677062196bed79297700c7db25f99f0ccf844d0da01334c2608ffb490",
        "linux_arm64": "a22e86a459265ee033ef9b6279ae39f6eed84dda5daf065c32d6a6274912470c",
        "windows_amd64": "244071964c98fccbf3dad333199dc85a6b147aa2ac4bd78c605b111511618ebb",
        "windows_arm64": "b48a5f769fe341650d8e50d264c828a7457c6d8cfef03b31a5a21cbcdcaa0e89",
    },
)

# ddtest's release platforms, which are both the exec platforms that get an
# instrumented SDK and the target platforms its toolchains build for, with
# their @platforms constraints.
PLATFORMS = {
    "darwin_amd64": ("macos", "x86_64"),
    "darwin_arm64": ("macos", "aarch64"),
    "linux_amd64": ("linux", "x86_64"),
    "linux_arm64": ("linux", "aarch64"),
    "windows_amd64": ("windows", "x86_64"),
    "windows_arm64": ("windows", "aarch64"),
}

_PREFIX = "topt_go_ddtest"

# Bazel files that a base SDK's repository has at its root.
_REPOSITORY_FILES = ["BUILD", "BUILD.bazel", "MODULE.bazel", "REPO.bazel", "ROOT", "WORKSPACE", "WORKSPACE.bazel"]

# Repository names, stable for consumers: Mini's repository is the one that a
# workspace using Mini's Go API passes to override_repo.
MINI_REPO = _PREFIX + "_mini"
TOOLCHAINS_REPO = _PREFIX + "_toolchains"
_HOST_REPO = _PREFIX + "_host"

def _base_repo(platform):
    return "%s_base_%s" % (_PREFIX, platform)

def _files_repo(platform):
    return "%s_sdk_files_%s" % (_PREFIX, platform)

def sdk_repo(platform):
    """Name of the wrapped instrumented SDK for an exec platform."""
    return "%s_sdk_%s" % (_PREFIX, platform)

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

def go_version_from_go_mod(content):
    """The Go SDK version that rules_go's go_sdk.from_file selects.

    The toolchain directive wins, then the go directive; a go directive from
    Go 1.21 on without a patch release means its first release, x.y.0.
    """
    go = None
    toolchain = None
    for line in content.splitlines():
        fields = [field for field in line.strip().replace("\t", " ").split(" ") if field]
        if len(fields) >= 2 and fields[0] == "toolchain" and fields[1].startswith("go"):
            toolchain = fields[1][len("go"):]
        elif len(fields) >= 2 and fields[0] == "go":
            go = fields[1]
    version = toolchain or go
    if not version:
        return None
    parts = version.split(".")
    if len(parts) == 2 and parts[0] == "1" and parts[1].isdigit() and int(parts[1]) >= 21:
        version += ".0"
    return version

def parse_contract(content):
    """Parse a DDTEST_INSTRUMENT file: one key=value per line."""
    values = {}
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        key, sep, value = line.partition("=")
        if sep:
            values[key] = value
    return values

def contract_error(values, what):
    """Return why a DDTEST_INSTRUMENT does not match the pinned release, or None."""
    for key, want in [
        ("contract", DDTEST_RELEASE.contract),
        ("sdk_name", DDTEST_RELEASE.sdk_name),
        ("version", DDTEST_RELEASE.runtime_version),
    ]:
        got = values.get(key)
        if got != want:
            return "%s: DDTEST_INSTRUMENT has %s=%r, want %r (ddtest %s)" % (what, key, got, want, DDTEST_RELEASE.tag)
    return None

UNCONFIGURED_MESSAGE = (
    "Go tests instrumented by dd_topt_go_test need a Go SDK to instrument: add " +
    "topt_go_ddtest.sdk(go_mod = \"//:go.mod\") to the root MODULE.bazel, or " +
    "call topt_go_ddtest_repositories(go_version = ...) in WORKSPACE"
)

def _unconfigured_impl(ctx):
    fail(ctx.attr.message)

topt_go_ddtest_unconfigured = rule(
    implementation = _unconfigured_impl,
    attrs = {"message": attr.string()},
    doc = "Stands in for the instrumented SDK until one is configured, and says so when selected.",
)

def toolchains_build_content(exec_platforms):
    """BUILD file of the toolchains repository: one toolchain per exec/target pair.

    Without exec platforms, one toolchain that fails with what to configure
    stands in, so that only instrumented tests notice.
    """
    lines = [] if exec_platforms else [
        "load(\"@datadog-rules-test-optimization-go//:topt_go_ddtest_repository.bzl\", \"topt_go_ddtest_unconfigured\")",
        "",
    ]
    lines += [
        "# Generated by datadog-rules-test-optimization-go. Every toolchain needs",
        "# sdk_name == \"%s\", which only instrumented tests set." % DDTEST_RELEASE.sdk_name,
        "",
        "config_setting(",
        "    name = \"sdk_name_ddto\",",
        "    flag_values = {\"@io_bazel_rules_go//go/toolchain:sdk_name\": \"%s\"}," % DDTEST_RELEASE.sdk_name,
        ")",
    ]
    if not exec_platforms:
        lines.extend([
            "",
            "topt_go_ddtest_unconfigured(",
            "    name = \"unconfigured\",",
            "    message = %r," % UNCONFIGURED_MESSAGE,
            ")",
            "",
            "toolchain(",
            "    name = \"go_unconfigured\",",
            "    target_settings = [\":sdk_name_ddto\"],",
            "    toolchain = \":unconfigured\",",
            "    toolchain_type = \"@io_bazel_rules_go//go:toolchain\",",
            ")",
        ])
    for exec_platform in sorted(exec_platforms):
        exec_os, exec_cpu = PLATFORMS[exec_platform]
        for target_platform in sorted(PLATFORMS.keys()):
            target_os, target_cpu = PLATFORMS[target_platform]
            lines.extend([
                "",
                "toolchain(",
                "    name = \"go_%s_%s\"," % (exec_platform, target_platform),
                "    exec_compatible_with = [\"@platforms//os:%s\", \"@platforms//cpu:%s\"]," % (exec_os, exec_cpu),
                "    target_compatible_with = [\"@platforms//os:%s\", \"@platforms//cpu:%s\"]," % (target_os, target_cpu),
                "    target_settings = [\":sdk_name_ddto\"],",
                "    toolchain = \"@%s//:go_%s-impl\"," % (sdk_repo(exec_platform), target_platform),
                "    toolchain_type = \"@io_bazel_rules_go//go:toolchain\",",
                ")",
            ])
    return "\n".join(lines) + "\n"

def _download_ddtest(rctx, platform, output):
    rctx.download(
        url = DDTEST_RELEASE.url.format(tag = DDTEST_RELEASE.tag, asset = ddtest_asset(platform)),
        output = output,
        sha256 = DDTEST_RELEASE.sha256[platform],
        executable = True,
    )
    return rctx.path(output)

def _instrument_bazel(rctx, ddtest, args):
    command = [ddtest, "instrument", "bazel"] + args
    result = rctx.execute(command)
    if result.return_code:
        fail("%s exited with %d:\n%s%s" % (" ".join([str(arg) for arg in command]), result.return_code, result.stdout, result.stderr))

def _check_contract(rctx, path, what):
    error = contract_error(parse_contract(rctx.read(path)), what)
    if error:
        fail(error)

def _host_impl(rctx):
    platform = host_platform(rctx.os.name, rctx.os.arch)
    if not platform:
        fail("ddtest instrument has no executable for this host: %s/%s" % (rctx.os.name, rctx.os.arch))
    _download_ddtest(rctx, platform, "ddtest" + (".exe" if platform.startswith("windows") else ""))
    rctx.file("PLATFORM", platform)
    rctx.file("BUILD.bazel", "exports_files([\"PLATFORM\"])\n")

_host = repository_rule(
    implementation = _host_impl,
    doc = "The repository host's ddtest executable, from the pinned release.",
)

def _host_ddtest(rctx):
    """The host's executable and platform, from the host repository's PLATFORM file."""
    marker = rctx.path(rctx.attr.host)
    platform = rctx.read(marker).strip()
    return marker.dirname.get_child("ddtest" + (".exe" if platform.startswith("windows") else "")), platform

# The host repository, passed by label so that the extension's repository
# mapping, which sees its own repositories, resolves it.
_HOST_ATTR = attr.label(mandatory = True, doc = "The host repository's PLATFORM file.")

def _mini_impl(rctx):
    ddtest, _ = _host_ddtest(rctx)

    # The repository's directory is empty: Mini's packages go at its root.
    _instrument_bazel(rctx, ddtest, ["--mini", "--rules-go=io_bazel_rules_go", "."])
    _check_contract(rctx, "DDTEST_INSTRUMENT", "Mini's repository")

_mini = repository_rule(
    implementation = _mini_impl,
    attrs = {"host": _HOST_ATTR},
    doc = "Mini's packages, written by the pinned ddtest release.",
)

def _sdk_files_impl(rctx):
    ddtest, host = _host_ddtest(rctx)
    platform = rctx.attr.exec_platform
    compiler = ddtest if platform == host else _download_ddtest(rctx, platform, "compiler/" + ddtest_asset(platform))
    goroot = rctx.path(rctx.attr.base_sdk_root).dirname
    args = ["--goroot=%s" % goroot, "--compiler=%s" % compiler]
    if rctx.attr.panic_hook:
        args.append("--panic-hook")
    _instrument_bazel(rctx, ddtest, args + ["sdk"])
    _check_contract(rctx, "sdk/DDTEST_INSTRUMENT", "the instrumented SDK for %s" % platform)
    if platform != host:
        rctx.delete("compiler")

    # A base SDK from another repository brings its Bazel files, which would
    # make sdk/ a package; go_wrap_sdk links the SDK's entries and writes its own.
    for name in _REPOSITORY_FILES:
        rctx.delete("sdk/" + name)
    rctx.file("BUILD.bazel", "exports_files([\"sdk/DDTEST_INSTRUMENT\"])\n")

_sdk_files = repository_rule(
    implementation = _sdk_files_impl,
    attrs = {
        "base_sdk_root": attr.label(mandatory = True, doc = "A file at the root of the base Go SDK for exec_platform."),
        "exec_platform": attr.string(mandatory = True, values = sorted(PLATFORMS.keys())),
        "panic_hook": attr.bool(),
        "host": _HOST_ATTR,
    },
    doc = "A copy of a base Go SDK whose compiler is ddtest.",
)

def _toolchains_impl(rctx):
    rctx.file("BUILD.bazel", toolchains_build_content(rctx.attr.exec_platforms))

_toolchains = repository_rule(
    implementation = _toolchains_impl,
    attrs = {"exec_platforms": attr.string_list()},
    doc = "Toolchain declarations for the instrumented SDKs; it downloads nothing.",
)

def _host_and_mini():
    _host(name = _HOST_REPO)
    host = "@%s//:PLATFORM" % _HOST_REPO
    _mini(name = MINI_REPO, host = host)
    return host

def topt_go_ddtest_unconfigured_repositories():
    """Declare Mini's repository, and toolchains that say what to configure."""
    _host_and_mini()
    _toolchains(name = TOOLCHAINS_REPO, exec_platforms = [])

def topt_go_ddtest_repositories(
        go_version = None,
        base_sdk_roots = {},
        exec_platforms = None,
        experiments = [],
        panic_hook = False):
    """Declare the repositories of the ddtest instrumentation.

    Args:
      go_version: Version of the official Go SDK to instrument on exec
        platforms that base_sdk_roots does not name, such as "1.26.3".
      base_sdk_roots: Exec platform, such as "linux_amd64", to a file at the
        root of the Go SDK to instrument, such as "@go_sdk//:ROOT".
      exec_platforms: The exec platforms to instrument; all of ddtest's by
        default. Bazel fetches only those whose toolchains it selects.
      experiments: GOEXPERIMENT values of the base SDKs.
      panic_hook: Record unrecovered panics as test failures before the
        process ends.
    """
    platforms = exec_platforms or sorted(PLATFORMS.keys())
    for platform in platforms:
        if platform not in PLATFORMS:
            fail("topt_go_ddtest: unsupported exec platform %r; supported: %s" % (platform, ", ".join(sorted(PLATFORMS.keys()))))
    host = _host_and_mini()
    for platform in platforms:
        root = base_sdk_roots.get(platform)
        if not root:
            if not go_version:
                fail("topt_go_ddtest: set go_version, or base_sdk_roots for %s" % platform)
            goos, goarch = platform.split("_")
            go_download_sdk(
                name = _base_repo(platform),
                version = go_version,
                goos = goos,
                goarch = goarch,
                experiments = experiments,
                register_toolchains = False,
            )
            root = "@%s//:ROOT" % _base_repo(platform)
        _sdk_files(
            name = _files_repo(platform),
            base_sdk_root = root,
            exec_platform = platform,
            panic_hook = panic_hook,
            host = host,
        )
        go_wrap_sdk(
            name = sdk_repo(platform),
            root_file = "@%s//:sdk/DDTEST_INSTRUMENT" % _files_repo(platform),
            experiments = experiments,
            register_toolchains = False,
        )
    _toolchains(name = TOOLCHAINS_REPO, exec_platforms = platforms)
