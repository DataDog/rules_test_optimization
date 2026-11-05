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

Like rules_go's own toolchains, they also honor
`@io_bazel_rules_go//go/toolchain:sdk_version`, which go_cross_binary and
other transitions below a test set: the default SDK serves an unset value and
the prefixes of its Go version, and each SDK variant serves its own value.
Any other value selects a toolchain that fails and says what to configure.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@io_bazel_rules_go//go:deps.bzl", "go_download_sdk", "go_wrap_sdk")

# The pinned ddtest release. The tag names the release; what ddtest writes
# records the runtime's SemVer version, with v0.0.0- before a pre-release's
# name.
DDTEST_RELEASE = struct(
    tag = "v1.15.0",
    runtime_version = "v1.15.0",
    contract = "1",
    sdk_name = "ddto",
    url = "https://github.com/DataDog/ddtest/releases/download/{tag}/{asset}",
    sha256 = {
        "darwin_amd64": "e83d5bff5aada7b0fd7a46cfa3ea6ede819125584eec7da72cbfa0b03caef3a2",
        "darwin_arm64": "4470c3064c0b5baf1b294fbdc893b13b73a1b4f95f00c593b48ec2148e2c32a6",
        "linux_amd64": "d8f8452ac6827d26b5637d75f412efaf4e638182d7e1a800261f33f079e67741",
        "linux_arm64": "c4b8a53054714a1680b885245eee23819022249e4c12ec2f2f9a6c9fe42c3fbd",
        "windows_amd64": "b612fcb068523dde93061c2eaecabe3e0fa3ed2853c89cd85eb4122bab60802e",
        "windows_arm64": "ba5db11589dd00a5b1d4723cb8ef9e2ba7a60498c20c61592b9d61bc7411a2bb",
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

def _repo(kind, sdk_id, platform):
    return "%s_%s_%s%s" % (_PREFIX, kind, sdk_id + "_" if sdk_id else "", platform)

def sdk_repo(platform, sdk_id = ""):
    """Name of the wrapped instrumented SDK for an exec platform.

    sdk_id is "" for the default SDK and sdk_variant_id(...) for a variant.
    """
    return _repo("sdk", sdk_id, platform)

def sdk_variant_id(sdk_version):
    """The part of a variant's repository and target names that its sdk_version gives."""
    return "v" + "".join([c if c.isalnum() else "_" for c in sdk_version.elems()])

def sdk_version_matches(go_version):
    """The sdk_version values that select an SDK of go_version.

    As rules_go's declare_bazel_toolchains matches its own SDKs: unset, the
    major, major.minor and major.minor.patch versions, and with a prerelease
    suffix, such as 1.26rc2, major.minor.patch and major.minor followed by it.
    Without a version, only unset.
    """
    matches = [""]
    if not go_version:
        return matches
    numeric = ""
    for c in go_version.elems():
        if not (c.isdigit() or c == "."):
            break
        numeric += c
    prerelease = go_version[len(numeric):]
    parts = numeric.split(".")
    major = parts[0]
    minor = parts[1] if len(parts) > 1 else "0"
    patch = parts[2] if len(parts) > 2 else "0"
    for value in [
        major,
        "%s.%s" % (major, minor),
        "%s.%s.%s" % (major, minor, patch),
        "%s.%s.%s%s" % (major, minor, patch, prerelease),
        "%s.%s%s" % (major, minor, prerelease),
    ]:
        if value not in matches:
            matches.append(value)
    return matches

_VARIANT_KEYS = ["sdk_version", "go_version", "base_sdk_roots", "exec_platforms", "experiments", "panic_hook"]

def sdk_variants_error(go_version, sdk_variants):
    """Why sdk_variants cannot sit beside a default SDK of go_version, or None."""
    default_matches = sdk_version_matches(go_version)
    ids = {}
    for variant in sdk_variants:
        for key in variant.keys():
            if key not in _VARIANT_KEYS:
                return "topt_go_ddtest: unknown SDK variant field %r; supported: %s" % (key, ", ".join(_VARIANT_KEYS))
        sdk_version = variant.get("sdk_version", "")
        if not sdk_version:
            return "topt_go_ddtest: an SDK variant needs the sdk_version that selects it"
        if sdk_version in default_matches:
            return "topt_go_ddtest: sdk_version %r already selects the default SDK (Go %s)" % (sdk_version, go_version)
        variant_id = sdk_variant_id(sdk_version)
        if variant_id in ids:
            return "topt_go_ddtest: SDK variants %r and %r need distinct repository names" % (ids[variant_id], sdk_version)
        ids[variant_id] = sdk_version
    return None

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
    "call topt_go_ddtest_workspace_repositories(go_version = ...) in WORKSPACE"
)

def _unconfigured_impl(ctx):
    fail(ctx.attr.message.replace("{sdk_version}", ctx.attr._sdk_version[BuildSettingInfo].value))

topt_go_ddtest_unconfigured = rule(
    implementation = _unconfigured_impl,
    attrs = {
        "message": attr.string(doc = "What to configure; {sdk_version} stands for the requested sdk_version."),
        "_sdk_version": attr.label(default = Label("@io_bazel_rules_go//go/toolchain:sdk_version")),
    },
    doc = "Stands in for an instrumented SDK that is not configured, and says so when selected.",
)

def _unmatched_message(sdks):
    configured = []
    for sdk in sdks:
        versions = ", ".join([repr(v) for v in sdk["matches"]])
        configured.append("sdk_version %s on %s" % (versions, ", ".join(sdk["exec_platforms"])))
    return (
        "No instrumented Go SDK matches sdk_version \"{sdk_version}\". " +
        "Configured: " + "; ".join(configured) + ". Add an SDK variant with that sdk_version: " +
        "topt_go_ddtest.sdk(sdk_version = ...) in MODULE.bazel, or sdk_variants in " +
        "topt_go_ddtest_workspace_repositories(...) in WORKSPACE"
    )

def toolchains_build_content(sdks):
    """BUILD file of the toolchains repository: one toolchain per SDK and exec/target pair.

    sdks holds one dict per configured SDK, the default first: its id, the
    sdk_version values that select it and its exec platforms. A toolchain
    that fails with what to configure catches an sdk_version that no SDK
    serves, so that only instrumented tests notice; without SDKs, it is the
    only one.
    """
    lines = [
        "load(\"@datadog-rules-test-optimization-go//:topt_go_ddtest_repository.bzl\", \"topt_go_ddtest_unconfigured\")",
    ]
    if sdks:
        lines.append("load(\"@bazel_skylib//lib:selects.bzl\", \"selects\")")
    lines += [
        "",
        "# Generated by datadog-rules-test-optimization-go. Every toolchain needs",
        "# sdk_name == \"%s\", which only instrumented tests set." % DDTEST_RELEASE.sdk_name,
        "",
        "config_setting(",
        "    name = \"sdk_name_ddto\",",
        "    flag_values = {\"@io_bazel_rules_go//go/toolchain:sdk_name\": \"%s\"}," % DDTEST_RELEASE.sdk_name,
        ")",
    ]
    served = []
    for sdk in sdks:
        prefix = sdk["id"] + "_" if sdk["id"] else ""
        version_setting = prefix + "sdk_version"
        conditions = []
        for i, value in enumerate(sdk["matches"]):
            # selects.config_setting_group names its own targets <group>_<n>.
            conditions.append(":%s_value_%d" % (version_setting, i))
            served.append(":%s_value_%d" % (version_setting, i))
            lines.extend([
                "",
                "config_setting(",
                "    name = \"%s_value_%d\"," % (version_setting, i),
                "    flag_values = {\"@io_bazel_rules_go//go/toolchain:sdk_version\": %r}," % value,
                ")",
            ])
        lines.extend([
            "",
            "selects.config_setting_group(",
            "    name = \"%s\"," % version_setting,
            "    match_any = [%s]," % ", ".join(["\"%s\"" % c for c in conditions]),
            ")",
        ])
        for exec_platform in sorted(sdk["exec_platforms"]):
            exec_os, exec_cpu = PLATFORMS[exec_platform]
            for target_platform in sorted(PLATFORMS.keys()):
                target_os, target_cpu = PLATFORMS[target_platform]
                lines.extend([
                    "",
                    "toolchain(",
                    "    name = \"go_%s%s_%s\"," % (prefix, exec_platform, target_platform),
                    "    exec_compatible_with = [\"@platforms//os:%s\", \"@platforms//cpu:%s\"]," % (exec_os, exec_cpu),
                    "    target_compatible_with = [\"@platforms//os:%s\", \"@platforms//cpu:%s\"]," % (target_os, target_cpu),
                    "    target_settings = [\":sdk_name_ddto\", \":%s\"]," % version_setting,
                    "    toolchain = \"@%s//:go_%s-impl\"," % (sdk_repo(exec_platform, sdk["id"]), target_platform),
                    "    toolchain_type = \"@io_bazel_rules_go//go:toolchain\",",
                    ")",
                ])

    # The stand-in matches only an sdk_version that no SDK serves, so that it
    # never makes an exec platform eligible that has no SDK for a served one:
    # Bazel picks the first exec platform where every toolchain type resolves.
    # sdk_version_unserved negates sdk_version_served the way
    # selects.config_setting_group combines settings, with an alias whose
    # select picks a setting that does or does not match.
    unconfigured_settings = ["\":sdk_name_ddto\""]
    if sdks:
        unconfigured_settings.append("\":sdk_version_unserved\"")
        lines.extend([
            "",
            "selects.config_setting_group(",
            "    name = \"sdk_version_served\",",
            "    match_any = [%s]," % ", ".join(["\"%s\"" % s for s in served]),
            ")",
            "",
            "config_setting(",
            "    name = \"sdk_name_unset\",",
            "    flag_values = {\"@io_bazel_rules_go//go/toolchain:sdk_name\": \"\"},",
            ")",
            "",
            "alias(",
            "    name = \"sdk_version_unserved\",",
            "    actual = select({",
            "        \":sdk_version_served\": \":sdk_name_unset\",",
            "        \"//conditions:default\": \":sdk_name_ddto\",",
            "    }),",
            ")",
        ])
    lines.extend([
        "",
        "topt_go_ddtest_unconfigured(",
        "    name = \"unconfigured\",",
        "    message = %r," % (_unmatched_message(sdks) if sdks else UNCONFIGURED_MESSAGE),
        ")",
        "",
        "toolchain(",
        "    name = \"unconfigured_toolchain\",",
        "    target_settings = [%s]," % ", ".join(unconfigured_settings),
        "    toolchain = \":unconfigured\",",
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

def base_sdk_version_error(version_file, go_version, platform, sdk_version):
    """Why a base SDK's VERSION file contradicts go_version, or None."""
    lines = version_file.splitlines()
    fields = lines[0].split(" ") if lines else []
    version = fields[0][len("go"):] if fields and fields[0].startswith("go") else None
    if not go_version or not version or version == go_version:
        return None
    sdk = "SDK variant %r" % sdk_version if sdk_version else "default SDK"
    return "topt_go_ddtest: the %s's base SDK for %s is Go %s, but its go_version is %s; set go_version to the base SDK's version, or point base_sdk_roots at a Go %s SDK" % (sdk, platform, version, go_version, go_version)

def _sdk_files_impl(rctx):
    ddtest, host = _host_ddtest(rctx)
    platform = rctx.attr.exec_platform
    goroot = rctx.path(rctx.attr.base_sdk_root).dirname
    version_file = goroot.get_child("VERSION")
    if version_file.exists:
        error = base_sdk_version_error(rctx.read(version_file), rctx.attr.go_version, platform, rctx.attr.sdk_version)
        if error:
            fail(error)
    compiler = ddtest if platform == host else _download_ddtest(rctx, platform, "compiler/" + ddtest_asset(platform))
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
        "go_version": attr.string(doc = "The Go version that the base SDK must have, if set."),
        "sdk_version": attr.string(doc = "The SDK variant's sdk_version, for messages."),
        "panic_hook": attr.bool(),
        "host": _HOST_ATTR,
    },
    doc = "A copy of a base Go SDK whose compiler is ddtest.",
)

def _toolchains_impl(rctx):
    rctx.file("BUILD.bazel", toolchains_build_content(json.decode(rctx.attr.sdks)))

_toolchains = repository_rule(
    implementation = _toolchains_impl,
    attrs = {"sdks": attr.string(default = "[]", doc = "JSON list of the configured SDKs, as toolchains_build_content takes them.")},
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
    _toolchains(name = TOOLCHAINS_REPO)

def _declare_sdk(host, sdk_id, sdk_version, go_version, base_sdk_roots, exec_platforms, experiments, panic_hook):
    """Declare one instrumented SDK's repositories per exec platform; return its toolchains entry."""
    platforms = exec_platforms or sorted(PLATFORMS.keys())
    what = "the SDK variant %r" % sdk_version if sdk_version else "the default SDK"
    for platform in platforms:
        if platform not in PLATFORMS:
            fail("topt_go_ddtest: unsupported exec platform %r for %s; supported: %s" % (platform, what, ", ".join(sorted(PLATFORMS.keys()))))
    for platform in platforms:
        root = base_sdk_roots.get(platform)
        if not root:
            if not go_version:
                fail("topt_go_ddtest: set go_version, or base_sdk_roots for %s, for %s" % (platform, what))
            goos, goarch = platform.split("_")
            go_download_sdk(
                name = _repo("base", sdk_id, platform),
                version = go_version,
                goos = goos,
                goarch = goarch,
                experiments = experiments,
                register_toolchains = False,
            )
            root = "@%s//:ROOT" % _repo("base", sdk_id, platform)
        _sdk_files(
            name = _repo("sdk_files", sdk_id, platform),
            base_sdk_root = root,
            exec_platform = platform,
            go_version = go_version or "",
            sdk_version = sdk_version,
            panic_hook = panic_hook,
            host = host,
        )

        # With a version, go_wrap_sdk also checks the SDK, through `go version`
        # when it has no VERSION file for _sdk_files to read.
        go_wrap_sdk(
            name = sdk_repo(platform, sdk_id),
            root_file = "@%s//:sdk/DDTEST_INSTRUMENT" % _repo("sdk_files", sdk_id, platform),
            experiments = experiments,
            register_toolchains = False,
            version = go_version or "",
        )
    return {
        "id": sdk_id,
        "matches": [sdk_version] if sdk_version else sdk_version_matches(go_version),
        "exec_platforms": platforms,
    }

def topt_go_ddtest_repositories(
        go_version = None,
        base_sdk_roots = {},
        exec_platforms = None,
        experiments = [],
        panic_hook = False,
        sdk_variants = []):
    """Declare the repositories of the ddtest instrumentation.

    Args:
      go_version: Go version of the default SDK, such as "1.26.3": the
        official SDK that exec platforms without base_sdk_roots download, and
        the version whose sdk_version requests the default SDK serves.
      base_sdk_roots: Exec platform, such as "linux_amd64", to a file at the
        root of the Go SDK to instrument, such as "@go_sdk//:ROOT".
      exec_platforms: The exec platforms to instrument; all of ddtest's by
        default. Bazel fetches only those whose toolchains it selects.
      experiments: GOEXPERIMENT values of the base SDKs.
      panic_hook: Record unrecovered panics as test failures before the
        process ends.
      sdk_variants: Other SDKs, each a dict with the sdk_version value that
        selects it, such as "1.26.3fips", and its own go_version,
        base_sdk_roots, exec_platforms, experiments and panic_hook.
    """
    error = sdk_variants_error(go_version, sdk_variants)
    if error:
        fail(error)
    host = _host_and_mini()
    sdks = [_declare_sdk(host, "", "", go_version, base_sdk_roots, exec_platforms, experiments, panic_hook)]
    for variant in sdk_variants:
        sdks.append(_declare_sdk(
            host,
            sdk_variant_id(variant["sdk_version"]),
            variant["sdk_version"],
            variant.get("go_version"),
            variant.get("base_sdk_roots", {}),
            variant.get("exec_platforms"),
            variant.get("experiments", []),
            variant.get("panic_hook", False),
        ))
    _toolchains(name = TOOLCHAINS_REPO, sdks = json.encode(sdks))

def topt_go_ddtest_workspace_repositories(**kwargs):
    """WORKSPACE: declare the ddtest repositories and register their toolchains.

    In Bzlmod, the Go companion module registers the toolchains itself. In
    WORKSPACE, call this after rules_go's go_rules_dependencies; rules_go must
    be named io_bazel_rules_go, as the SDK repositories load it so.

    Args:
      **kwargs: The arguments of topt_go_ddtest_repositories; go_version or
        base_sdk_roots is required, and sdk_variants adds SDKs that other
        sdk_version values select.
    """
    topt_go_ddtest_repositories(**kwargs)
    native.register_toolchains("@%s//:all" % TOOLCHAINS_REPO)
