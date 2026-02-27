"""Starlark helpers to infer Go importpath via rules_go providers.

This file provides:
- An aspect that walks the `embed` attribute to find a go_library's
  computed importpath (matching rules_go's logic).
- A rule that uses that aspect result to choose the correct per-module
  filegroup from the synced repository and expose those files as runfiles.

Why this rule/aspect exists:
- A macro alone cannot reliably inspect provider values from dependencies.
- By using an aspect + analysis-time rule, selection follows Bazel's normal
  analysis graph and remains cache/incrementality friendly.

Selection model:
1) explicit importpath (highest precedence)
2) inferred importpath from embed providers
3) fallback importpath supplied by caller
4) module label sanitization + lookup against `module_<label>` targets
5) fallback to full bundle when no module match exists

Maintenance notes:
- This file belongs to the Go companion module and is the only place that
  should read rules_go providers for orchestration selection.
- Keep provider access defensive (`getattr` / `hasattr`) because rules_go
  provider internals can vary across versions.
- Explicit selector inputs should fail fast when they cannot map to any
  exported `module_<sanitized>` filegroup; inferred/fallback paths still use
  the safe full-bundle fallback.
"""

load(
    "@datadog-rules-test-optimization//tools/core:topt_selection_utils.bzl",
    "select_module_group_name",
)

# In rules_go v0.51+, GoLibrary and GoSource were merged into GoInfo.
# GoArchive still exists separately.
load("@rules_go//go:def.bzl", "GoArchive", "GoInfo")

_select_module_group_name = select_module_group_name

# Public alias for unit tests.
select_module_group_name_for_tests = _select_module_group_name

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
        if type(ip) == type("") and ip:
            return [ToptGoImportpathInfo(importpath = ip)]

    # Fallback: GoArchive may carry importpath
    if GoArchive in target:
        arch = target[GoArchive]
        ip = getattr(arch, "importpath", None)

        # Some versions nest importpath under a 'source' or 'library' field
        if (not ip) and hasattr(arch, "source"):
            ip = getattr(arch.source, "importpath", None)
        if (not ip) and hasattr(arch, "library"):
            ip = getattr(arch.library, "importpath", None)
        if type(ip) == type("") and ip:
            return [ToptGoImportpathInfo(importpath = ip)]

    # Explicit attribute on some go_* rules
    if hasattr(ctx, "rule") and hasattr(ctx.rule.attr, "importpath"):
        ip = ctx.rule.attr.importpath
        if type(ip) == type("") and ip:
            return [ToptGoImportpathInfo(importpath = ip)]

    # Propagate from transitive deps.
    # Returning the first non-empty importpath preserves deterministic behavior.
    for attr_name in ["embed", "deps"]:
        for dep in getattr(ctx.rule.attr, attr_name, []):
            if ToptGoImportpathInfo in dep:
                ip = dep[ToptGoImportpathInfo].importpath
                if type(ip) == type("") and ip:
                    return [ToptGoImportpathInfo(importpath = ip)]

    # No information found at this node
    return []

_importpath_aspect = aspect(
    implementation = _importpath_aspect_impl,
    attr_aspects = ["embed", "deps"],
)

def _topt_go_payloads_selector_impl(ctx):
    """Rule implementation that exposes selected payload files as runfiles.

    This keeps selection logic in analysis phase while presenting a simple
    `DefaultInfo` data target for consuming macros (`dd_topt_go_test`).
    """

    # Decide which payload files to expose as runfiles based on the inferred importpath.
    # This rule deliberately returns a plain DefaultInfo so downstream macros
    # can treat it like a normal data dependency.
    ip = ctx.attr.explicit_importpath or ""
    if not ip:
        # Prefer provider-derived importpath when available from embedded deps.
        for dep in ctx.attr.embeds:
            if ToptGoImportpathInfo in dep:
                ip = dep[ToptGoImportpathInfo].importpath or ""
                if ip:
                    break
    if not ip:
        # Final fallback comes from macro-computed module/package synthesis.
        ip = ctx.attr.fallback_importpath or ""

    module_group_names = [m.label.name for m in ctx.attr.module_groups]

    # Compute target name first, then resolve to actual label object below.
    strict_selection = ctx.attr.include_per_module and len(module_group_names) > 0 and (
        bool(ctx.attr.explicit_importpath) or bool(ctx.attr.module_label_override)
    )
    selected_name = _select_module_group_name(
        ip,
        module_group_names,
        ctx.attr.include_per_module,
        ctx.attr.module_label_override,
        fail_on_miss = strict_selection,
        failure_context = "topt_go_payloads_selector",
    )
    chosen = None
    if selected_name:
        # Resolve selected name back to its label to preserve runfiles/files
        # providers exactly as exported by upstream generated targets.
        for m in ctx.attr.module_groups:
            if m.label.name == selected_name:
                chosen = m
                break

    # Fallback to the full bundle when no per-module group matches.
    # This avoids surprising build/test failures when module mapping drifts.
    source = chosen if chosen != None else ctx.attr.full_files

    # Expose selected files via runfiles.
    # Using a single selector target keeps consuming macros simple.
    # `default_runfiles` preserves any symlink mapping behavior from the chosen
    # upstream filegroup/rule instead of rebuilding runfiles manually here.
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
