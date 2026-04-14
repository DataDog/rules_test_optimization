"""Aspect to collect package_info metadata for buildInfo.

This aspect traverses Go binary dependencies and collects version information
from Gazelle-generated package_info targets referenced via the package_metadata
common attribute (inherited from REPO.bazel default_package_metadata).

Implementation based on bazel-contrib/supply-chain gather_metadata pattern.
Currently doesn't use the supply chain tools dep for this as it is not yet
stable and we still need to support WORKSPACE which the supply-chain tools
doesn't have support for.
"""

load(
    "@rules_license//rules:providers.bzl",
    "PackageInfo",
)
load(
    "//go/private:providers.bzl",
    "GoInfo",
)

visibility(["//go/private/..."])

# Simple struct to hold version data extracted from PackageInfo
# Using a struct rather than raw provider allows efficient depset storage
VersionInfo = provider(
    doc = "INTERNAL: Simple version info extracted from PackageInfo. Do not depend on this provider.",
    fields = {
        "module": "string: Module path (package_name from PackageInfo)",
        "version": "string: Version string (package_version from PackageInfo)",
    },
)

BuildInfoMetadata = provider(
    doc = "INTERNAL: Provides dependency version metadata for buildInfo. Do not depend on this provider.",
    fields = {
        "importpaths": "Depset of Go dependency import paths contributing to the linked binary.",
        "version_infos": "Depset of VersionInfo with module path and version data",
    },
)

def _buildinfo_aspect_impl(target, ctx):
    """Collects package_info metadata from dependencies.

    This aspect collects module version information from package_metadata attributes
    (set via REPO.bazel default_package_metadata in go_repository). Version info
    is extracted immediately from PackageInfo providers and stored as VersionInfo structs.

    Args:
        target: The target being visited
        ctx: The aspect context

    Returns:
        List containing BuildInfoMetadata provider
    """
    direct_version_infos = []
    direct_importpaths = []
    transitive_version_infos = []
    transitive_importpaths = []

    if GoInfo in target:
        importpath = target[GoInfo].importpath
        if importpath and importpath != "main":
            direct_importpaths.append(importpath)

    # Access applicable_licenses universal attribute (this is where default_package_metadata targets go)
    attr_value = ctx.rule.attr.applicable_licenses if hasattr(ctx.rule.attr, "applicable_licenses") else []
    if attr_value:
        package_metadata = attr_value if type(attr_value) == type([]) else [attr_value]
        for metadata_target in package_metadata:
            if PackageInfo in metadata_target:
                info = metadata_target[PackageInfo]
                if info.package_name and info.package_version:
                    version = info.package_version
                    if version and not version.startswith("v"):
                        version = "v" + version
                    direct_version_infos.append(VersionInfo(
                        module = info.package_name,
                        version = version,
                    ))

    # Collect transitive metadata from Go dependencies only
    # Only traverse deps and embed to avoid non-Go dependencies
    for attr_name in ["deps", "embed"]:
        if not hasattr(ctx.rule.attr, attr_name):
            continue

        attr_value = getattr(ctx.rule.attr, attr_name)
        if not attr_value:
            continue

        deps = attr_value if type(attr_value) == type([]) else [attr_value]
        for dep in deps:
            # Collect transitive BuildInfoMetadata
            if BuildInfoMetadata in dep:
                transitive_importpaths.append(dep[BuildInfoMetadata].importpaths)
                transitive_version_infos.append(dep[BuildInfoMetadata].version_infos)

    # Build depsets (empty depsets are efficient, no need for early return)
    return [BuildInfoMetadata(
        importpaths = depset(
            direct = direct_importpaths,
            transitive = transitive_importpaths,
        ),
        version_infos = depset(
            direct = direct_version_infos,
            transitive = transitive_version_infos,
        ),
    )]

buildinfo_aspect = aspect(
    doc = "Collects package_info metadata for Go buildInfo",
    implementation = _buildinfo_aspect_impl,
    attr_aspects = ["deps", "embed"],
    provides = [BuildInfoMetadata],
    apply_to_generating_rules = True,
)
