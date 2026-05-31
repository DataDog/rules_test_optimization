# Copyright 2014 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    "@bazel_skylib//lib:collections.bzl",
    "collections",
)
load(
    "//go/private:common.bzl",
    "GO_TOOLCHAIN_LABEL",
    "count_group_matches",
    "has_shared_lib_extension",
)
load(
    "//go/private:mode.bzl",
    "LINKMODE_NORMAL",
    "LINKMODE_PLUGIN",
    "extld_from_cc_toolchain",
    "extldflags_from_cc_toolchain",
)
load(
    "//go/private:rpath.bzl",
    "rpath",
)
load("//go/private/orchestrion:pin_files.bzl", "OrchestrionPinFilesInfo")

_ORCHESTRION_PROBE_ENV_VARS = (
    "RULES_GO_ORCHESTRION_PROBE",
    "RULES_GO_ORCHESTRION_PROBE_FILE",
)
_ORCHESTRION_MODE_TEST_OPTIMIZATION = "test_optimization"

def _format_archive(d):
    return "{}={}={}".format(d.label, d.importmap, d.file.path)

def _dirname(file):
    return file.dirname

def _orchestrion_action_env(
        go,
        base_env,
        orchestrion_trace_version_file = None,
        orchestrion_proxy_root_marker = None,
        orchestrion_tool_version_file = None):
    env = dict(base_env)
    shell_env = go._ctx.configuration.default_shell_env
    for name in _ORCHESTRION_PROBE_ENV_VARS:
        if name in shell_env:
            env[name] = shell_env[name]
    if orchestrion_trace_version_file:
        env["RULES_GO_ORCHESTRION_VERSION_FILE"] = orchestrion_trace_version_file.path
    if orchestrion_proxy_root_marker:
        env["RULES_GO_ORCHESTRION_MODULE_PROXY_ROOT"] = orchestrion_proxy_root_marker.dirname
    if orchestrion_tool_version_file:
        env["RULES_GO_ORCHESTRION_TOOL_VERSION_FILE"] = orchestrion_tool_version_file.path
    return env

def _orchestrion_data_inputs(go):
    if getattr(go, "orchestrion_mode", "") != _ORCHESTRION_MODE_TEST_OPTIMIZATION:
        return go._ctx.files.data if hasattr(go._ctx.files, "data") else []

    allowed_pin_files = {
        "go.mod": True,
        "go.sum": True,
        "orchestrion.yml": True,
    }
    files = []
    for dep in getattr(go._ctx.attr, "data", []):
        if OrchestrionPinFilesInfo in dep:
            for file in dep[OrchestrionPinFilesInfo].files.to_list():
                if file.basename in allowed_pin_files:
                    files.append(file)
    return files

def _orchestrion_enabled_for_link(go, synthetic_testmain_manifest):
    if not go.orchestrion:
        return False

    # Synthetic testmain compile already produced the Datadog helper packagefile
    # manifest that final link needs. Keep that final test-binary link on the
    # plain rules_go shape so its action key is not tied to unused Orchestrion
    # execution inputs. Generic mode still keeps the stdlib cache input below.
    return synthetic_testmain_manifest == None

def _stdlib_cache_needed_for_link(go, synthetic_testmain_manifest, link_orchestrion):
    if (
        go.orchestrion and
        getattr(go, "orchestrion_mode", "") == _ORCHESTRION_MODE_TEST_OPTIMIZATION and
        synthetic_testmain_manifest != None and
        not link_orchestrion
    ):
        return False
    return True

def _parse_lld_thread_count(extldflags):
    """Extract --threads=N from extldflags to determine lld CPU usage."""
    for flag in extldflags:
        # Flags arrive as -Wl,--threads=N
        for part in flag.split(","):
            if part.startswith("--threads="):
                count = part.removeprefix("--threads=")
                if count.isdigit():
                    return int(count)
    return 1

# Pre-built resource_set callbacks keyed by CPU count. Starlark does not
# support closures, so we select the right function from this dict.
def _golink_resource_set_1(_os, _inputs):
    return {"cpu": 1, "memory": 512}

def _golink_resource_set_2(_os, _inputs):
    return {"cpu": 2, "memory": 512}

def _golink_resource_set_4(_os, _inputs):
    return {"cpu": 4, "memory": 512}

_GOLINK_RESOURCE_SETS = {
    1: _golink_resource_set_1,
    2: _golink_resource_set_2,
    4: _golink_resource_set_4,
}

def _golink_resource_set_for(extldflags):
    """Return a resource_set callback matching the lld --threads value."""
    threads = _parse_lld_thread_count(extldflags)
    return _GOLINK_RESOURCE_SETS.get(threads, _golink_resource_set_1)

def emit_link(
        go,
        archive = None,
        test_archives = [],
        executable = None,
        gc_linkopts = [],
        version_file = None,
        info_file = None,
        buildinfo_metadata = None,
        target_label = None):
    """See go/toolchains.rst#link for full documentation."""

    if archive == None:
        fail("archive is a required parameter")
    if executable == None:
        fail("executable is a required parameter")

    # Generate buildinfo dependency file for Go 1.18+ buildInfo support
    buildinfo_file = None
    version_map_file = None
    if buildinfo_metadata:
        buildinfo_file = go.declare_file(go, path = executable.basename + ".buildinfo.txt")

        # Materialize depsets at link time
        version_infos = buildinfo_metadata.version_infos.to_list()

        # Build version map from VersionInfo structs
        # Data was already extracted from PackageInfo providers at aspect time
        # Deduplicate modules by keeping first version found (depset order is deterministic)
        version_map = {}
        for info in version_infos:
            module = info.module
            version = info.version
            if module and module not in version_map:
                version_map[module] = version

        # Write version map to file for Go builder
        version_map_file = go.declare_file(go, path = executable.basename + ".versions.txt")
        version_lines = ["{}\t{}".format(module, ver) for module, ver in sorted(version_map.items())]
        go.actions.write(
            output = version_map_file,
            content = "\n".join(version_lines) + "\n" if version_lines else "",
        )

        # Build buildinfo content
        content_lines = []

        # Add main package path
        if archive.data.importpath:
            content_lines.append("path\t{}".format(archive.data.importpath))

        # Add dependencies with versions
        # Sort modules for deterministic output, which is required for:
        # 1. Bazel action caching - identical inputs must produce identical outputs
        # 2. Reproducible builds across different machines
        # 3. Easier debugging and testing with predictable output order
        # Only output one entry per module (not per package)
        for module in sorted(version_map.keys()):
            version = version_map[module]
            content_lines.append("dep\t{}\t{}".format(module, version))

        go.actions.write(
            output = buildinfo_file,
            content = "\n".join(content_lines) + "\n" if content_lines else "",
        )

    # Exclude -lstdc++ from link options. We don't want to link against it
    # unless we actually have some C++ code. _cgo_codegen will include it
    # in archives via CGO_LDFLAGS if it's needed.
    extldflags = [f for f in extldflags_from_cc_toolchain(go) if f not in ("-lstdc++", "-lc++", "-static")]

    if go.coverage_enabled:
        extldflags.append("--coverage")
    gc_linkopts = gc_linkopts + go.mode.gc_linkopts
    gc_linkopts, extldflags = _extract_extldflags(gc_linkopts, extldflags)
    builder_args = go.builder_args(go, "link")
    tool_args = go.tool_args(go)

    # use ar tool from cc toolchain if cc toolchain provides it
    if go.cgo_tools and go.cgo_tools.ar_path and go.cgo_tools.ar_path.endswith("ar"):
        tool_args.add("-extar", go.cgo_tools.ar_path)

    # Add in any mode specific behaviours
    if go.mode.race:
        tool_args.add("-race")
    if go.mode.msan:
        tool_args.add("-msan")

    extld = extld_from_cc_toolchain(go)
    tool_args.add_all(extld)
    if extld:
        tool_args.add("-linkmode", "external")

    if go.mode.static:
        extldflags.append("-static")
    if go.mode.linkmode != LINKMODE_NORMAL:
        builder_args.add("-buildmode", go.mode.linkmode)
    if go.mode.linkmode == LINKMODE_PLUGIN:
        tool_args.add("-pluginpath", archive.data.importpath)

    # TODO(zbarsky): Bazel versions older than 7.2.0 do not properly deduplicate this dep
    # Can replace with the following once we support Bazel 7.2.0+ only:
    #    if go.coverage_enabled and go.coverdata:
    #        test_archives = list(test_archives) + [go.coverdata.data]
    #    arcs = depset(test_archives, transitive = [d.transitive for d in archive.direct])

    if go.coverage_enabled and go.coverdata:
        potentially_duplicated_arcs = depset(test_archives + [go.coverdata.data], transitive = [d.transitive for d in archive.direct]).to_list()
        importmaps = {}
        arcs = []
        for arc in potentially_duplicated_arcs:
            if arc.importmap in importmaps:
                continue
            importmaps[arc.importmap] = True
            arcs.append(arc)
    else:
        arcs = depset(test_archives, transitive = [d.transitive for d in archive.direct])

    builder_args.add_all(arcs, before_each = "-arc", map_each = _format_archive)
    builder_args.add("-package_list", go.sdk.package_list)

    # Build a list of rpaths for dynamic libraries we need to find.
    # rpaths are relative paths from the binary to directories where libraries
    # are stored. Binaries that require these will only work when installed in
    # the bazel execroot. Most binaries are only dynamically linked against
    # system libraries though.
    cgo_rpaths = sorted(collections.uniq([
        f
        for d in archive.cgo_deps.to_list()
        if has_shared_lib_extension(d.basename)
        for f in rpath.flags(go, d, executable = executable)
    ]))
    extldflags.extend(cgo_rpaths)

    # Process x_defs, and record whether stamping is used.
    stamp_x_defs_volatile = False
    stamp_x_defs_stable = False
    for k, v in archive.x_defs.items():
        builder_args.add("-X", "%s=%s" % (k, v))
        if go.mode.stamp:
            stable_vars_count = (count_group_matches(v, "{STABLE_", "}") +
                                 v.count("{BUILD_EMBED_LABEL}") +
                                 v.count("{BUILD_USER}") +
                                 v.count("{BUILD_HOST}"))
            if stable_vars_count > 0:
                stamp_x_defs_stable = True
            if count_group_matches(v, "{", "}") != stable_vars_count:
                stamp_x_defs_volatile = True

    # Stamping support
    stamp_inputs = []
    if stamp_x_defs_stable:
        stamp_inputs.append(info_file)
    if stamp_x_defs_volatile:
        stamp_inputs.append(version_file)
    if stamp_inputs:
        builder_args.add_all(stamp_inputs, before_each = "-stamp")

    builder_args.add("-o", executable)
    builder_args.add("-main", archive.data.file)
    builder_args.add("-p", archive.data.importmap)
    synthetic_testmain_manifest = getattr(archive.data, "_synthetic_testmain_manifest", None)
    orchestrion_mode = getattr(go, "orchestrion_mode", "general")
    link_orchestrion = _orchestrion_enabled_for_link(go, synthetic_testmain_manifest)
    stdlib_cache_needed_for_link = _stdlib_cache_needed_for_link(go, synthetic_testmain_manifest, link_orchestrion)
    if stdlib_cache_needed_for_link:
        builder_args.add_all("-stdlib_cache", go.stdlib.cache_dir.to_list(), expand_directories = False)

    # Pass buildinfo file to builder if available
    if buildinfo_file:
        builder_args.add("-buildinfo", buildinfo_file)
    if version_map_file:
        builder_args.add("-versionmap", version_map_file)
    if target_label:
        builder_args.add("-bazeltarget", target_label)

    tool_args.add_all(gc_linkopts)
    tool_args.add_all(go.toolchain.flags.link)

    # Do not remove, somehow this is needed when building for darwin/arm only.
    tool_args.add("-buildid=redacted")
    if go.mode.strip:
        tool_args.add("-s", "-w")
    tool_args.add_joined("-extldflags", extldflags, join_with = " ")

    inputs_direct = stamp_inputs + [go.sdk.package_list]
    if synthetic_testmain_manifest:
        inputs_direct.append(synthetic_testmain_manifest)
    if buildinfo_file:
        inputs_direct.append(buildinfo_file)
    if version_map_file:
        inputs_direct.append(version_map_file)
    if go.coverage_enabled and go.coverdata:
        inputs_direct.append(go.coverdata.data.file)
    orchestrion_trace_version_file = getattr(go, "orchestrion_version_file", None) if link_orchestrion else None
    orchestrion_proxy_root_marker = getattr(go, "orchestrion_module_proxy_root_marker", None) if link_orchestrion else None
    orchestrion_tool_version_file = getattr(go, "orchestrion_tool_version_file", None) if link_orchestrion else None

    inputs_transitive = [
        archive.libs,
        archive.cgo_deps,
        go.cc_toolchain_files,
        go.sdk.tools,
        go.stdlib.libs,
    ]
    if stdlib_cache_needed_for_link:
        inputs_transitive.append(go.stdlib.cache_dir)

    # Add orchestrion for toolexec instrumentation if enabled
    if go.orchestrion:
        builder_args.add("-orchestrion_mode", orchestrion_mode)
    if link_orchestrion:
        builder_args.add("-orchestrion", go.orchestrion)
        inputs_direct.append(go.orchestrion)
        if orchestrion_trace_version_file:
            inputs_direct.append(orchestrion_trace_version_file)
        if orchestrion_proxy_root_marker:
            inputs_direct.append(orchestrion_proxy_root_marker)
        if orchestrion_tool_version_file:
            inputs_direct.append(orchestrion_tool_version_file)

        # Orchestrion needs the go binary to run `go env GOMOD`
        inputs_direct.append(go.sdk.go)

        # The toolexec path may resolve woven dependencies during linking too,
        # so keep the SDK source tree available in sandboxed executions.
        inputs_transitive.append(go.sdk.srcs)
        if getattr(go, "orchestrion_module_proxy_files", None):
            inputs_transitive.append(go.orchestrion_module_proxy_files)

        # Stage rule data files for the link builder too so it can reuse the
        # same pinned module files seen during compile (for example go.mod,
        # go.sum, orchestrion.tool.go, orchestrion.yml).
        orchestrion_data_inputs = _orchestrion_data_inputs(go)
        if orchestrion_data_inputs:
            builder_args.add_all(
                orchestrion_data_inputs,
                map_each = _dirname,
                before_each = "-orchsrc",
                uniquify = True,
                expand_directories = False,
            )
            inputs_direct.extend(orchestrion_data_inputs)
    inputs = depset(direct = inputs_direct, transitive = inputs_transitive)

    go.actions.run(
        inputs = inputs,
        outputs = [executable],
        mnemonic = "GoLink",
        executable = go.toolchain._builder,
        arguments = [builder_args, "--", tool_args],
        env = _orchestrion_action_env(
            go,
            go.env,
            orchestrion_trace_version_file = orchestrion_trace_version_file,
            orchestrion_proxy_root_marker = orchestrion_proxy_root_marker,
            orchestrion_tool_version_file = orchestrion_tool_version_file,
        ),
        toolchain = GO_TOOLCHAIN_LABEL,
        resource_set = _golink_resource_set_for(extldflags),
    )

def _extract_extldflags(gc_linkopts, extldflags):
    """Extracts -extldflags from gc_linkopts and combines them into a single list.

    Args:
      gc_linkopts: a list of flags passed in through the gc_linkopts attributes.
        ctx.expand_make_variables should have already been applied. -extldflags
        may appear multiple times in this list.
      extldflags: a list of flags to be passed to the external linker.

    Return:
      A tuple containing the filtered gc_linkopts with external flags removed,
      and a combined list of external flags. Each string in the returned
      extldflags list may contain multiple flags, separated by whitespace.
    """
    filtered_gc_linkopts = []
    is_extldflags = False
    skip_next = False

    for i, opt in enumerate(gc_linkopts):
        if skip_next:
            skip_next = False
            continue

        if is_extldflags:
            if opt == "-Wl" and i + 1 < len(gc_linkopts):
                # Merge '-Wl,' and next value
                extldflags.append("-Wl," + gc_linkopts[i + 1])
                skip_next = True
            else:
                extldflags.append(opt)
            is_extldflags = False
        elif opt == "-extldflags":
            is_extldflags = True
        else:
            filtered_gc_linkopts.append(opt)
    return filtered_gc_linkopts, extldflags
