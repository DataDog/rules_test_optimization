# Copyright 2024 The Bazel Authors. All rights reserved.
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

"""Module extension for configuring orchestrion in rules_go."""

def _orchestrion_build_impl(ctx):
    """Build orchestrion from source."""
    version = ctx.attr.version
    binary_name = "orchestrion.exe" if ctx.os.name.lower().startswith("windows") else "orchestrion_bin"
    
    # Download orchestrion source
    ctx.download_and_extract(
        url = "https://github.com/DataDog/orchestrion/archive/refs/tags/%s.zip" % version,
        stripPrefix = "orchestrion-%s" % version.lstrip("v"),
    )

    # The upstream package resolver recursively re-runs `go list` under
    # `-toolexec=orchestrion toolexec`, which causes woven dependency lookups to
    # fail under Bazel's sandbox even when plain `go list -mod=mod` succeeds in
    # the same environment. Mirror the safer non-recursive pattern used by other
    # loader paths in Orchestrion and disable toolexec for dependency resolution.
    resolve_path = "internal/jobserver/pkgs/resolve.go"
    resolve_src = ctx.read(resolve_path)
    resolve_old = """\n\t\tbuildFlags := append(\n\t\t\tgoFlags.Slice(),\n\t\t\tfmt.Sprintf(\"-toolexec=%q toolexec\", binpath.Orchestrion),\n\t\t)\n"""
    resolve_new = """\n\t\tbuildFlags := append(goFlags.Slice(), \"-toolexec=\")\n"""
    if resolve_old not in resolve_src:
        fail("Could not patch Orchestrion resolver in %s" % resolve_path)
    resolve_src = resolve_src.replace(resolve_old, resolve_new)
    resolve_src = resolve_src.replace('\n\t"github.com/DataDog/orchestrion/internal/binpath"', "")
    resolve_imports_old = """\t\"fmt\"\n\t\"os\"\n\t\"slices\"\n"""
    resolve_imports_new = """\t\"fmt\"\n\t\"os\"\n\t\"path/filepath\"\n\t\"slices\"\n"""
    if resolve_imports_old not in resolve_src:
        fail("Could not patch Orchestrion resolver imports in %s" % resolve_path)
    resolve_src = resolve_src.replace(resolve_imports_old, resolve_imports_new, 1)
    resolve_debug_old = """\t\tpkgs, err := packages.Load(\n\t\t\t&packages.Config{\n"""
    resolve_debug_new = """\t\tif log.GetLevel() <= zerolog.TraceLevel {\n\t\t\tlog.Trace().Str(\"dir\", req.Dir).Str(\"tmpdir\", req.TempDir).Strs(\"build_flags\", buildFlags).Msg(\"pkgs.Resolve environment\")\n\t\t\tfor _, probeBase := range []string{req.Dir, req.TempDir} {\n\t\t\t\tif probeBase == \"\" {\n\t\t\t\t\tcontinue\n\t\t\t\t}\n\t\t\t\tprobe := filepath.Join(probeBase, \"external\", \"rules_go++go_sdk+go_default_sdk\", \"pkg\", \"include\", \"textflag.h\")\n\t\t\t\tif info, statErr := os.Stat(probe); statErr == nil {\n\t\t\t\t\tlog.Trace().Str(\"probe\", probe).Bool(\"is_dir\", info.IsDir()).Msg(\"pkgs.Resolve found textflag header\")\n\t\t\t\t} else {\n\t\t\t\t\tlog.Trace().Str(\"probe\", probe).Err(statErr).Msg(\"pkgs.Resolve missing textflag header\")\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\n\t\tpkgs, err := packages.Load(\n\t\t\t&packages.Config{\n"""
    if resolve_debug_old not in resolve_src:
        fail("Could not patch Orchestrion resolver debug block in %s" % resolve_path)
    resolve_src = resolve_src.replace(resolve_debug_old, resolve_debug_new, 1)
    resolve_tempdir_old = """\t\tif req.TempDir != \"\" {\n\t\t\t// Make sure the directory exists (go blindly assumes that...)\n\t\t\tif err := os.MkdirAll(req.TempDir, 0o755); err != nil {\n\t\t\t\treturn nil, fmt.Errorf(\"creating temporary directory %q: %w\", req.TempDir, err)\n\t\t\t}\n\t\t\tenv = append(env, fmt.Sprintf(\"%s=%s\", envVarGotmpdir, req.TempDir))\n\t\t}\n"""
    resolve_tempdir_new = """\t\tif req.TempDir != \"\" {\n\t\t\tabsTempDir, absErr := filepath.Abs(req.TempDir)\n\t\t\tif absErr != nil {\n\t\t\t\treturn nil, fmt.Errorf(\"absolutizing temporary directory %q: %w\", req.TempDir, absErr)\n\t\t\t}\n\t\t\t// Make sure the directory exists (go blindly assumes that...)\n\t\t\tif err := os.MkdirAll(absTempDir, 0o755); err != nil {\n\t\t\t\treturn nil, fmt.Errorf(\"creating temporary directory %q: %w\", absTempDir, err)\n\t\t\t}\n\t\t\tfor _, name := range []string{\"external\", \"bazel-out\"} {\n\t\t\t\tsrcPath := filepath.Join(req.Dir, name)\n\t\t\t\tif !filepath.IsAbs(srcPath) {\n\t\t\t\t\tif srcPath, absErr = filepath.Abs(srcPath); absErr != nil {\n\t\t\t\t\t\treturn nil, fmt.Errorf(\"absolutizing compatibility path %q: %w\", srcPath, absErr)\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t\tif _, statErr := os.Stat(srcPath); statErr != nil {\n\t\t\t\t\tcontinue\n\t\t\t\t}\n\t\t\t\tdstPath := filepath.Join(absTempDir, name)\n\t\t\t\tif _, statErr := os.Lstat(dstPath); statErr == nil {\n\t\t\t\t\tcontinue\n\t\t\t\t} else if !os.IsNotExist(statErr) {\n\t\t\t\t\treturn nil, fmt.Errorf(\"stat temporary compatibility path %q: %w\", dstPath, statErr)\n\t\t\t\t}\n\t\t\t\tlinkTarget, relErr := filepath.Rel(absTempDir, srcPath)\n\t\t\t\tif relErr != nil {\n\t\t\t\t\tif linkTarget, absErr = filepath.Abs(srcPath); absErr != nil {\n\t\t\t\t\t\treturn nil, fmt.Errorf(\"compute temporary compatibility path for %q: %w\", name, relErr)\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t\tif linkErr := os.Symlink(linkTarget, dstPath); linkErr != nil {\n\t\t\t\t\treturn nil, fmt.Errorf(\"create temporary compatibility symlink %q -> %q: %w\", dstPath, linkTarget, linkErr)\n\t\t\t\t}\n\t\t\t\tif log.GetLevel() <= zerolog.TraceLevel {\n\t\t\t\t\tlog.Trace().Str(\"dst\", dstPath).Str(\"target\", linkTarget).Msg(\"pkgs.Resolve created temp compatibility symlink\")\n\t\t\t\t}\n\t\t\t}\n\t\t\tenv = append(env, fmt.Sprintf(\"%s=%s\", envVarGotmpdir, absTempDir))\n\t\t}\n"""
    if resolve_tempdir_old not in resolve_src:
        fail("Could not patch Orchestrion resolver tempdir block in %s" % resolve_path)
    resolve_src = resolve_src.replace(resolve_tempdir_old, resolve_tempdir_new, 1)
    resolve_merge_old = """func (r ResolveResponse) mergeFrom(pkg *packages.Package) error {\n\tif pkg.PkgPath == \"\" || pkg.PkgPath == \"unsafe\" || r[pkg.PkgPath] != \"\" {\n\t\t// Ignore the \"unsafe\" package (no archive file, ever), packages with an empty import path\n\t\t// (standard library), and those already present in the map (already processed previously).\n\t\treturn nil\n\t}\n"""
    resolve_merge_new = """func (r ResolveResponse) mergeFrom(pkg *packages.Package) error {\n\tif pkg.PkgPath == \"\" || pkg.PkgPath == \"unsafe\" || r[pkg.PkgPath] != \"\" {\n\t\t// Ignore the \"unsafe\" package (no archive file, ever), packages with an empty import path\n\t\t// (standard library), and those already present in the map (already processed previously).\n\t\treturn nil\n\t}\n"""
    if resolve_merge_old not in resolve_src:
        fail("Could not patch Orchestrion resolver mergeFrom in %s" % resolve_path)
    resolve_src = resolve_src.replace(resolve_merge_old, resolve_merge_new, 1)
    ctx.file(resolve_path, resolve_src)

    linkdeps_path = "internal/toolexec/aspect/linkdeps/linkdeps.go"
    linkdeps_src = ctx.read(linkdeps_path)
    linkdeps_old = """\n\tdata, err = readArchiveData(archive, Filename)\n\tif err != nil {\n\t\treturn res, fmt.Errorf(\"reading %s from %q: %w\", Filename, archive, err)\n\t}\n"""
    linkdeps_new = """\n\tdata, err = readArchiveData(archive, Filename)\n\tif err != nil {\n\t\tif errors.Is(err, os.ErrNotExist) {\n\t\t\treturn res, nil\n\t\t}\n\t\treturn res, fmt.Errorf(\"reading %s from %q: %w\", Filename, archive, err)\n\t}\n"""
    if linkdeps_old not in linkdeps_src:
        fail("Could not patch Orchestrion linkdeps in %s" % linkdeps_path)
    ctx.file(linkdeps_path, linkdeps_src.replace(linkdeps_old, linkdeps_new))

    compile_proxy_path = "internal/toolexec/proxy/compile.go"
    compile_proxy_src = ctx.read(compile_proxy_path)
    compile_flag_old = """type compileFlagSet struct {\n\tAsmhdr      string `ddflag:\"-asmhdr\"`\n\tBuildID     string `ddflag:\"-buildid\"`\n\tImportCfg   string `ddflag:\"-importcfg\"`\n\tLang        string `ddflag:\"-lang\"`\n\tOutput      string `ddflag:\"-o\"`\n\tPackage     string `ddflag:\"-p\"`\n\tShowVersion bool   `ddflag:\"-V\"`\n}\n"""
    compile_flag_new = """type compileFlagSet struct {\n\tAsmhdr      string `ddflag:\"-asmhdr\"`\n\tBuildID     string `ddflag:\"-buildid\"`\n\tImportCfg   string `ddflag:\"-importcfg\"`\n\tLang        string `ddflag:\"-lang\"`\n\tLinkObj     string `ddflag:\"-linkobj\"`\n\tOutput      string `ddflag:\"-o\"`\n\tPackage     string `ddflag:\"-p\"`\n\tShowVersion bool   `ddflag:\"-V\"`\n}\n"""
    if compile_flag_old not in compile_proxy_src:
        fail("Could not patch Orchestrion compile flags in %s" % compile_proxy_path)
    compile_proxy_src = compile_proxy_src.replace(compile_flag_old, compile_flag_new)
    attach_old = """\tif _, err := os.Stat(cmd.Flags.Output); errors.Is(err, os.ErrNotExist) {\n\t\t// Already failing, not doing anything...\n\t\treturn nil\n\t} else if err != nil {\n\t\treturn err\n\t}\n\n\torchestrionDir := filepath.Join(cmd.Flags.Output, \"..\", \"orchestrion\")\n"""
    attach_new = """\ttargetArchive := cmd.Flags.LinkObj\n\tif targetArchive == \"\" {\n\t\ttargetArchive = cmd.Flags.Output\n\t}\n\n\tif _, err := os.Stat(targetArchive); errors.Is(err, os.ErrNotExist) {\n\t\t// Already failing, not doing anything...\n\t\treturn nil\n\t} else if err != nil {\n\t\treturn err\n\t}\n\n\torchestrionDir := filepath.Join(targetArchive, \"..\", \"orchestrion\")\n"""
    if attach_old not in compile_proxy_src:
        fail("Could not patch Orchestrion attachLinkDeps target in %s" % compile_proxy_path)
    compile_proxy_src = compile_proxy_src.replace(attach_old, attach_new)
    archive_old = """\tlog.Trace().Str(\"archive\", cmd.Flags.Output).Array(linkdeps.Filename, &cmd.LinkDeps).Msg(\"Adding \" + linkdeps.Filename + \" file in archive\")\n\n\tfile, err := os.OpenFile(cmd.Flags.Output, os.O_APPEND|os.O_WRONLY, 0o644)\n"""
    archive_new = """\tlog.Trace().Str(\"archive\", targetArchive).Array(linkdeps.Filename, &cmd.LinkDeps).Msg(\"Adding \" + linkdeps.Filename + \" file in archive\")\n\n\tfile, err := os.OpenFile(targetArchive, os.O_APPEND|os.O_WRONLY, 0o644)\n"""
    if archive_old not in compile_proxy_src:
        fail("Could not patch Orchestrion archive append target in %s" % compile_proxy_path)
    compile_proxy_src = compile_proxy_src.replace(archive_old, archive_new)
    notify_old = """\t\tfiles = make(map[nbt.Label]string, 2)\n\t\tif filename := cmd.Flags.Output; filename != \"\" {\n\t\t\tfiles[nbt.LabelArchive] = filename\n\t\t}\n"""
    notify_new = """\t\tfiles = make(map[nbt.Label]string, 2)\n\t\tif filename := cmd.Flags.LinkObj; filename != \"\" {\n\t\t\tfiles[nbt.LabelArchive] = filename\n\t\t} else if filename := cmd.Flags.Output; filename != \"\" {\n\t\t\tfiles[nbt.LabelArchive] = filename\n\t\t}\n"""
    if notify_old not in compile_proxy_src:
        fail("Could not patch Orchestrion finish archive file in %s" % compile_proxy_path)
    compile_proxy_src = compile_proxy_src.replace(notify_old, notify_new)
    ctx.file(compile_proxy_path, compile_proxy_src)

    compile_flags_path = "internal/toolexec/proxy/compile.flags.go"
    compile_flags_src = ctx.read(compile_flags_path)
    compile_flags_old = """\tflagSet.String(\"linkobj\", \"\", \"write linker-specific object to file\")\n"""
    compile_flags_new = """\tflagSet.StringVar(&f.LinkObj, \"linkobj\", \"\", \"write linker-specific object to file\")\n"""
    if compile_flags_old not in compile_flags_src:
        fail("Could not patch Orchestrion compile parser in %s" % compile_flags_path)
    ctx.file(compile_flags_path, compile_flags_src.replace(compile_flags_old, compile_flags_new))

    aspect_resolve_path = "internal/toolexec/aspect/resolve.go"
    aspect_resolve_src = ctx.read(aspect_resolve_path)
    aspect_resolve_old = """\tif !found {\n\t\treturn nil, fmt.Errorf(\"resolution did not include requested package %q\", importPath)\n\t}\n"""
    aspect_resolve_new = """\tif !found {\n\t\tkeys := make([]string, 0, len(archives))\n\t\tfor ip := range archives {\n\t\t\tkeys = append(keys, ip)\n\t\t}\n\t\tfmt.Fprintf(os.Stderr, \"orchestrion: resolvePackageFiles missing=%s returned=%v\\n\", importPath, keys)\n\t\treturn nil, fmt.Errorf(\"resolution did not include requested package %q\", importPath)\n\t}\n"""
    if aspect_resolve_old not in aspect_resolve_src:
        fail("Could not patch Orchestrion aspect resolver in %s" % aspect_resolve_path)
    ctx.file(aspect_resolve_path, aspect_resolve_src.replace(aspect_resolve_old, aspect_resolve_new, 1))

    oncompile_path = "internal/toolexec/aspect/oncompile.go"
    oncompile_src = ctx.read(oncompile_path)
    oncompile_old = """\t\tdeps, err := resolvePackageFiles(ctx, depImportPath, cmd.WorkDir)\n"""
    oncompile_new = """\t\tcwd, _ := os.Getwd()\n\t\tfmt.Fprintf(os.Stderr, \"orchestrion oncompile: resolving dep=%s cwd=%s workdir=%s\\n\", depImportPath, cwd, cmd.WorkDir)\n\t\tdeps, err := resolvePackageFiles(ctx, depImportPath, \".\")\n\t\tif err == nil {\n\t\t\tif arch, ok := deps[depImportPath]; ok {\n\t\t\t\tfmt.Fprintf(os.Stderr, \"orchestrion oncompile: resolved dep=%s archive=%s\\n\", depImportPath, arch)\n\t\t\t}\n\t\t}\n"""
    if oncompile_old not in oncompile_src:
        fail("Could not patch Orchestrion oncompile resolver context in %s" % oncompile_path)
    ctx.file(oncompile_path, oncompile_src.replace(oncompile_old, oncompile_new, 1))

    onlink_path = "internal/toolexec/aspect/onlink.go"
    onlink_src = ctx.read(onlink_path)
    onlink_old = """\t\t\tdeps, err := resolvePackageFiles(ctx, depPath, cmd.WorkDir)\n"""
    onlink_new = """\t\t\tprevImportPath, hadImportPath := os.LookupEnv(\"TOOLEXEC_IMPORTPATH\")\n\t\t\tif err := os.Setenv(\"TOOLEXEC_IMPORTPATH\", w.ImportPath); err != nil {\n\t\t\t\treturn fmt.Errorf(\"setting TOOLEXEC_IMPORTPATH=%q: %w\", w.ImportPath, err)\n\t\t\t}\n\t\t\tcwd, _ := os.Getwd()\n\t\t\tfmt.Fprintf(os.Stderr, \"orchestrion onlink: resolving dep=%s from archive=%s cwd=%s workdir=%s importpath=%s weaver_importpath=%s\\n\", depPath, archiveImportPath, cwd, cmd.WorkDir, os.Getenv(\"TOOLEXEC_IMPORTPATH\"), w.ImportPath)\n\t\t\tdeps, err := resolvePackageFiles(ctx, depPath, \".\")\n\t\t\tif hadImportPath {\n\t\t\t\t_ = os.Setenv(\"TOOLEXEC_IMPORTPATH\", prevImportPath)\n\t\t\t} else {\n\t\t\t\t_ = os.Unsetenv(\"TOOLEXEC_IMPORTPATH\")\n\t\t\t}\n\t\t\tif err == nil {\n\t\t\t\tif arch, ok := deps[depPath]; ok {\n\t\t\t\t\tfmt.Fprintf(os.Stderr, \"orchestrion onlink: resolved dep=%s archive=%s\\n\", depPath, arch)\n\t\t\t\t} else {\n\t\t\t\t\tfmt.Fprintf(os.Stderr, \"orchestrion onlink: resolved dep=%s missing direct archive keys=%d\\n\", depPath, len(deps))\n\t\t\t\t}\n\t\t\t}\n"""
    if onlink_old not in onlink_src:
        fail("Could not patch Orchestrion onlink resolver context in %s" % onlink_path)
    ctx.file(onlink_path, onlink_src.replace(onlink_old, onlink_new, 1))

    oncompile_main_path = "internal/toolexec/aspect/oncompile-main.go"
    oncompile_main_src = ctx.read(oncompile_main_path)
    oncompile_main_old = """\t\tdeps, err := resolvePackageFiles(ctx, linkDepPath, cmd.WorkDir)\n"""
    oncompile_main_new = """\t\tprevImportPath, hadImportPath := os.LookupEnv(\"TOOLEXEC_IMPORTPATH\")\n\t\tif err := os.Setenv(\"TOOLEXEC_IMPORTPATH\", \"main\"); err != nil {\n\t\t\treturn fmt.Errorf(\"setting TOOLEXEC_IMPORTPATH for synthetic main: %w\", err)\n\t\t}\n\t\tfor archiveImportPath, archivePath := range reg.PackageFile {\n\t\t\tld, ldErr := linkdeps.FromArchive(ctx, archivePath)\n\t\t\tif ldErr != nil || !ld.Contains(linkDepPath) {\n\t\t\t\tcontinue\n\t\t\t}\n\t\t\tif err := os.Setenv(\"TOOLEXEC_IMPORTPATH\", archiveImportPath); err != nil {\n\t\t\t\treturn fmt.Errorf(\"setting TOOLEXEC_IMPORTPATH=%q: %w\", archiveImportPath, err)\n\t\t\t}\n\t\t\tbreak\n\t\t}\n\t\tdeps, err := resolvePackageFiles(ctx, linkDepPath, \".\")\n\t\tif hadImportPath {\n\t\t\t_ = os.Setenv(\"TOOLEXEC_IMPORTPATH\", prevImportPath)\n\t\t} else {\n\t\t\t_ = os.Unsetenv(\"TOOLEXEC_IMPORTPATH\")\n\t\t}\n"""
    if oncompile_main_old not in oncompile_main_src:
        fail("Could not patch Orchestrion oncompile-main resolver context in %s" % oncompile_main_path)
    ctx.file(oncompile_main_path, oncompile_main_src.replace(oncompile_main_old, oncompile_main_new, 1))
    
    # Try to find go binary
    go_path = ctx.which("go")
    if not go_path:
        # Common locations for go binary
        for path in ["/usr/local/go/bin/go", "/opt/homebrew/bin/go", "/usr/bin/go"]:
            if ctx.path(path).exists:
                go_path = path
                break
    
    if not go_path:
        fail("Could not find 'go' binary. Please ensure Go is installed.")
    
    result = ctx.execute(
        [
            str(go_path),
            "build",
            "-trimpath",
            "-ldflags",
            "-s -w",
            "-o",
            binary_name,
            ".",
        ],
        timeout = 600,
        environment = {
            "GO111MODULE": "on",
            "GOPROXY": "https://proxy.golang.org,direct",
            "GOMODCACHE": str(ctx.path(".gomodcache")),
            "GOCACHE": str(ctx.path(".gocache")),
        },
    )
    if result.return_code != 0:
        fail("Failed to build orchestrion: %s\n%s" % (result.stdout, result.stderr))
    
    # Create BUILD file
    ctx.file("BUILD.bazel", """# Generated by rules_go orchestrion extension
filegroup(
    name = "orchestrion",
    srcs = ["{binary_name}"],
    visibility = ["//visibility:public"],
)
""".format(binary_name = binary_name))

_orchestrion_build = repository_rule(
    implementation = _orchestrion_build_impl,
    attrs = {
        "version": attr.string(mandatory = True, doc = "Orchestrion version to build"),
    },
)

def _orchestrion_empty_impl(ctx):
    """Create an empty placeholder repo."""
    ctx.file("BUILD.bazel", """# Generated by rules_go orchestrion extension
# No orchestrion configured
filegroup(
    name = "orchestrion",
    srcs = [],
    visibility = ["//visibility:public"],
)
""")

_orchestrion_empty = repository_rule(
    implementation = _orchestrion_empty_impl,
)

def _orchestrion_ext_impl(module_ctx):
    # Look for orchestrion.from_source() calls from any module
    version = ""
    for mod in module_ctx.modules:
        for from_source in mod.tags.from_source:
            if from_source.version:
                version = from_source.version
                break
        if version:
            break
    
    if version:
        _orchestrion_build(
            name = "rules_go_orchestrion_tool",
            version = version,
        )
    else:
        _orchestrion_empty(
            name = "rules_go_orchestrion_tool",
        )

_from_source = tag_class(
    attrs = {
        "version": attr.string(
            mandatory = True,
            doc = "Orchestrion version to build (e.g., 'v1.5.0')",
        ),
    },
)

orchestrion_ext = module_extension(
    implementation = _orchestrion_ext_impl,
    tag_classes = {
        "from_source": _from_source,
    },
)
