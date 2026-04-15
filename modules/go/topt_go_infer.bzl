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

def _resolved_importpath(explicit_importpath, embeds, fallback_importpath):
    """Resolve the effective importpath and record which source supplied it."""
    if explicit_importpath:
        return explicit_importpath, "explicit"

    for dep in embeds:
        if ToptGoImportpathInfo in dep:
            ip = dep[ToptGoImportpathInfo].importpath or ""
            if ip:
                return ip, "inferred"

    if fallback_importpath:
        return fallback_importpath, "fallback"

    return "", "empty"

def _resolve_payload_selection(ctx):
    """Resolve importpath and module-selection details for payload wiring."""
    ip, importpath_source = _resolved_importpath(
        ctx.attr.explicit_importpath or "",
        ctx.attr.embeds,
        ctx.attr.fallback_importpath or "",
    )

    module_group_names = [m.label.name for m in ctx.attr.module_groups]
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
        for module_group in ctx.attr.module_groups:
            if module_group.label.name == selected_name:
                chosen = module_group
                break

    if chosen != None:
        selection = "module_override" if ctx.attr.module_label_override else "module"
    elif ctx.attr.include_per_module and len(module_group_names) > 0:
        selection = "full_bundle_no_match"
    else:
        selection = "full_bundle_disabled"

    return struct(
        importpath = ip,
        importpath_source = importpath_source,
        selected_name = selected_name or "",
        chosen = chosen,
        selection = selection,
    )

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

def _canonical_payload_symlinks(files):
    """Return canonical cache/http symlinks for selected payload files.

    Module-specific payload groups are produced in the generated sync
    repository, but their raw runfiles paths can pick up workspace-prefixed
    roots when consumed from another repository. The Go companion normalizes
    those runfiles here so code that starts from `DD_TEST_OPTIMIZATION_MANIFEST_FILE`
    can always find `cache/http/*` next to the exported manifest path.
    """
    settings_file = None
    known_tests_file = None
    test_management_file = None

    for file in files:
        if file.basename == "settings.json":
            settings_file = file
        elif file.basename == "known_tests.json":
            known_tests_file = file
        elif file.basename == "test_management.json":
            test_management_file = file

    if settings_file == None:
        return {}

    cache_http_dir = "/".join(settings_file.short_path.split("/")[:-1])
    if not cache_http_dir:
        return {}

    symlinks = {}

    def maybe_add(filename, file):
        if file == None:
            return
        canonical_path = cache_http_dir + "/" + filename
        if file.short_path != canonical_path:
            symlinks[canonical_path] = file

    maybe_add("known_tests.json", known_tests_file)
    maybe_add("test_management.json", test_management_file)
    return symlinks

def _topt_go_payloads_selector_impl(ctx):
    """Rule implementation that exposes selected payload files as runfiles.

    This keeps selection logic in analysis phase while presenting a simple
    `DefaultInfo` data target for consuming macros (`dd_topt_go_test`).
    """

    # Decide which payload files to expose as runfiles based on the inferred importpath.
    # This rule deliberately returns a plain DefaultInfo so downstream macros
    # can treat it like a normal data dependency.
    selection = _resolve_payload_selection(ctx)

    # Fallback to the full bundle when no per-module group matches.
    # This avoids surprising build/test failures when module mapping drifts.
    source = selection.chosen if selection.chosen != None else ctx.attr.full_files

    # Rebuild runfiles here so the main workspace controls the canonical
    # manifest-adjacent paths that downstream test code reads at runtime.
    src_default = source[DefaultInfo]
    files = src_default.files.to_list()
    symlinks = _canonical_payload_symlinks(files)
    return [DefaultInfo(
        files = depset(files),
        runfiles = ctx.runfiles(files = files, symlinks = symlinks),
    )]

def _topt_go_bazel_metadata_impl(ctx):
    """Emit a single JSON file with Bazel-owned Go target metadata."""
    selection = _resolve_payload_selection(ctx)
    out = ctx.actions.declare_file(ctx.label.name + ".json")
    orchestrion_configured = _orchestrion_metadata_enabled(
        ctx.attr.orchestrion_requested,
        ctx.files._orchestrion_tool,
    )

    metadata = {
        "bazel.package": ctx.attr.bazel_package,
        "bazel.target": ctx.attr.bazel_target,
        "bazel.test_optimization.repo_name": ctx.attr.repo_name,
        "bazel.test_optimization.service_name": ctx.attr.service_name,
        "bazel.test_optimization.runtime_name": "go",
        "bazel.go.importpath": selection.importpath,
        "bazel.go.importpath_source": selection.importpath_source,
        "bazel.go.payload_selection": selection.selection,
        "bazel.go.orchestrion.enabled": orchestrion_configured,
        "bazel.go.attr.cgo": ctx.attr.cgo,
        "bazel.go.attr.pure": ctx.attr.pure,
        "bazel.go.attr.race": ctx.attr.race,
        "bazel.go.attr.msan": ctx.attr.msan,
        "bazel.go.attr.linkmode": ctx.attr.linkmode,
    }
    if ctx.attr.goos:
        metadata["bazel.go.attr.goos"] = ctx.attr.goos
    if ctx.attr.goarch:
        metadata["bazel.go.attr.goarch"] = ctx.attr.goarch

    ctx.actions.write(
        output = out,
        content = json.encode(metadata) + "\n",
    )
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out]))]

def _orchestrion_metadata_enabled(orchestrion_requested, orchestrion_tool_files):
    """Return True when metadata should report Orchestrion as actually enabled."""
    return orchestrion_requested and len(orchestrion_tool_files) > 0

orchestrion_metadata_enabled_for_tests = _orchestrion_metadata_enabled

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

topt_go_bazel_metadata = rule(
    implementation = _topt_go_bazel_metadata_impl,
    attrs = {
        "embeds": attr.label_list(aspects = [_importpath_aspect]),
        "explicit_importpath": attr.string(),
        "fallback_importpath": attr.string(),
        "module_groups": attr.label_list(),
        "include_per_module": attr.bool(default = True),
        "module_label_override": attr.string(),
        "bazel_package": attr.string(mandatory = True),
        "bazel_target": attr.string(mandatory = True),
        "repo_name": attr.string(mandatory = True),
        "service_name": attr.string(mandatory = True),
        "orchestrion_requested": attr.bool(default = True),
        "cgo": attr.bool(default = False),
        "pure": attr.string(default = "auto"),
        "race": attr.string(default = "auto"),
        "msan": attr.string(default = "auto"),
        "linkmode": attr.string(default = "auto"),
        "goos": attr.string(),
        "goarch": attr.string(),
        "_orchestrion_tool": attr.label(
            allow_files = True,
            default = "@rules_go//go/private/orchestrion:tool_binary",
        ),
    },
)
