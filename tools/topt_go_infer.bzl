"""Starlark helpers to infer Go importpath via rules_go providers.

This file provides:
- An aspect that walks the `embed` attribute to find a go_library's
  computed importpath (matching rules_go's logic).
- A rule that uses that aspect result to choose the correct per-module
  filegroup from the synced repository and expose those files as runfiles.
"""

# In rules_go v0.51+, GoLibrary and GoSource were merged into GoInfo.
# GoArchive still exists separately.
load("@rules_go//go/private:providers.bzl", "GoArchive", "GoInfo")
load("//tools:common_utils.bzl", "sanitize_label_fragment")

# Provider carrying the inferred importpath string
ToptGoImportpathInfo = provider(
    doc = "Provider carrying the inferred Go package importpath from rules_go.",
    fields = {"importpath": "Go package importpath"},
)

def _importpath_aspect_impl(target, ctx):
    """Aspect to discover the Go importpath.

    Strategy:
    - If this target provides GoInfo (formerly GoLibrary), read its importpath.
    - Else, if this target provides GoArchive, read its importpath.
    - Else, if rule has an explicit importpath attribute, use it.
    - Else, traverse children via `embed` and propagate first discovered value.
    """

    # Prefer GoInfo provider (rules_go v0.51+, replaces GoLibrary)
    if GoInfo in target:
        info = target[GoInfo]
        ip = getattr(info, "importpath", None)
        if ip:
            return [ToptGoImportpathInfo(importpath = ip)]

    # Fallback: GoArchive may carry importpath
    if GoArchive in target:
        arch = target[GoArchive]
        ip = getattr(arch, "importpath", None)

        # Some versions nest importpath under a 'source' or 'library' field
        if (not ip) and hasattr(arch, "source"):
            ip = getattr(arch.source, "importpath", None)
        if ip:
            return [ToptGoImportpathInfo(importpath = ip)]

    # Explicit attribute on some go_* rules
    if hasattr(ctx, "rule") and hasattr(ctx.rule.attr, "importpath"):
        ip = ctx.rule.attr.importpath
        if ip:
            return [ToptGoImportpathInfo(importpath = ip)]

    # Propagate from `embed` deps
    for dep in getattr(ctx.rule.attr, "embed", []):
        if ToptGoImportpathInfo in dep:
            ip = dep[ToptGoImportpathInfo].importpath
            if ip:
                return [ToptGoImportpathInfo(importpath = ip)]

    # No information found at this node
    return []

_importpath_aspect = aspect(
    implementation = _importpath_aspect_impl,
    attr_aspects = ["embed"],
)

def _topt_go_payloads_selector_impl(ctx):
    # Decide which payload files to expose as runfiles based on the inferred importpath.
    ip = ctx.attr.explicit_importpath or ""
    if not ip:
        for dep in ctx.attr.embeds:
            if ToptGoImportpathInfo in dep:
                ip = dep[ToptGoImportpathInfo].importpath or ""
                if ip:
                    break
    if not ip:
        ip = ctx.attr.fallback_importpath or ""

    # Optional override when caller knows better
    if ctx.attr.module_label_override:
        sanitized = ctx.attr.module_label_override
    else:
        sanitized = sanitize_label_fragment(ip)

    chosen = None
    if ctx.attr.include_per_module and sanitized:
        expected_name = "module_%s" % sanitized
        for m in ctx.attr.module_groups:
            if m.label.name == expected_name:
                chosen = m
                break

    # Fallback to the full bundle when no per-module group matches
    source = chosen if chosen != None else ctx.attr.full_files

    # Expose selected files via runfiles
    # Merge runfiles so we can always depend on this single target.
    src_default = source[DefaultInfo]
    runfiles = src_default.default_runfiles
    files = src_default.files
    return [DefaultInfo(files = files, runfiles = runfiles)]

topt_go_payloads_selector = rule(
    implementation = _topt_go_payloads_selector_impl,
    attrs = {
        # The libraries embedded by the go_test; the aspect walks these to find importpath.
        "embeds": attr.label_list(aspects = [_importpath_aspect]),

        # Optional importpath explicitly set on go_test; takes precedence.
        "explicit_importpath": attr.string(),

        # Optional fallback importpath when providers are not available.
        "fallback_importpath": attr.string(),

        # The aggregate filegroup with all JSONs (fallback)
        "full_files": attr.label(),

        # All per-module filegroups (e.g., @repo//:module_<sanitized>)
        "module_groups": attr.label_list(),

        # Whether to prefer per-module files when available
        "include_per_module": attr.bool(default = True),

        # Optional override for the sanitized module label suffix
        "module_label_override": attr.string(),
    },
)
