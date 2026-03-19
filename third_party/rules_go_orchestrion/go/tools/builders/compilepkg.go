// Copyright 2019 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// compilepkg compiles a complete Go package from Go, C, and assembly files.  It
// supports cgo, coverage, and nogo. It is invoked by the Go rules as an action.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

var syntheticTestmainRootPackages = []struct {
	alias       string
	packagePath string
}{
	{
		alias:       "example.com/__orchestrion/gotesting",
		packagePath: "github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting",
	},
	{
		alias:       "example.com/__orchestrion/integrations",
		packagePath: "github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations",
	},
	{
		alias:       "example.com/__orchestrion/tracer",
		packagePath: "github.com/DataDog/dd-trace-go/v2/ddtrace/tracer",
	},
	{
		alias:       "example.com/__orchestrion/profiler",
		packagePath: "github.com/DataDog/dd-trace-go/v2/profiler",
	},
	{
		alias:       "example.com/__orchestrion/http",
		packagePath: "github.com/DataDog/dd-trace-go/contrib/net/http/v2",
	},
	{
		alias:       "example.com/__orchestrion/httpinternal",
		packagePath: "github.com/DataDog/dd-trace-go/contrib/net/http/v2/internal/orchestrion",
	},
	{
		alias:       "example.com/__orchestrion/slog",
		packagePath: "github.com/DataDog/dd-trace-go/contrib/log/slog/v2",
	},
}

var syntheticTestmainSourceCompiledPackages = map[string]bool{
	"github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting":          true,
	"github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting/coverage": true,
	"github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations":                    true,
	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer":                                        true,
	"github.com/DataDog/dd-trace-go/v2/internal":                                              true,
	"github.com/DataDog/dd-trace-go/v2/profiler":                                              true,
	"github.com/DataDog/dd-trace-go/contrib/net/http/v2":                                      true,
	"github.com/DataDog/dd-trace-go/contrib/net/http/v2/internal/orchestrion":                 true,
	"github.com/DataDog/dd-trace-go/contrib/log/slog/v2":                                      true,
}

const syntheticTestmainPackagefileManifestName = "orchestrion.pack"
const syntheticTestmainPackagefileManifestSidecarSuffix = "." + syntheticTestmainPackagefileManifestName

func syntheticTestmainPackagefileManifestSidecarPath(archivePath string) string {
	return archivePath + syntheticTestmainPackagefileManifestSidecarSuffix
}

func writeSyntheticTestmainPackagefileManifest(outputPath, sourcePath string) error {
	if strings.TrimSpace(outputPath) == "" {
		return nil
	}
	data := []byte{}
	if strings.TrimSpace(sourcePath) != "" {
		var err error
		data, err = os.ReadFile(sourcePath)
		if err != nil {
			return fmt.Errorf("read synthetic testmain packagefile manifest %s: %w", sourcePath, err)
		}
	}
	if err := os.WriteFile(outputPath, data, 0o644); err != nil {
		return fmt.Errorf("write synthetic testmain packagefile manifest %s: %w", outputPath, err)
	}
	return nil
}

func compilePkg(args []string) error {
	// Parse arguments.
	args, _, err := expandParamsFiles(args)
	if err != nil {
		return err
	}

	fs := flag.NewFlagSet("GoCompilePkg", flag.ExitOnError)
	goenv := envFlags(fs)
	var pack string
	var unfilteredSrcs, coverSrcs, embedSrcs, embedLookupDirs, embedRoots, recompileInternalDeps multiFlag
	var deps archiveMultiFlag
	var importPath, packagePath, packageListPath, coverMode string
	var outLinkobjPath, outInterfacePath, outSyntheticTestmainManifestPath, cgoExportHPath, cgoGoSrcsPath string
	var testFilter string
	var gcFlags, asmFlags, cppFlags, cFlags, cxxFlags, objcFlags, objcxxFlags, ldFlags quoteMultiFlag
	var coverFormat string
	var pgoprofile string
	var orchestrion string
	fs.StringVar(&pack, "pack", "", "Path of the pack tool.")
	fs.StringVar(&orchestrion, "orchestrion", "", "Path to orchestrion binary for toolexec instrumentation")
	fs.Var(&unfilteredSrcs, "src", ".go, .c, .cc, .m, .mm, .s, or .S file to be filtered and compiled")
	fs.Var(&coverSrcs, "cover", ".go file that should be instrumented for coverage (must also be a -src)")
	fs.Var(&embedSrcs, "embedsrc", "file that may be compiled into the package with a //go:embed directive")
	fs.Var(&embedLookupDirs, "embedlookupdir", "Root-relative paths to directories relative to which //go:embed directives are resolved")
	fs.Var(&embedRoots, "embedroot", "Bazel output root under which a file passed via -embedsrc resides")
	fs.Var(&deps, "arc", "Import path, package path, and file name of a direct dependency, separated by '='")
	fs.StringVar(&importPath, "importpath", "", "The import path of the package being compiled. Not passed to the compiler, but may be displayed in debug data.")
	fs.StringVar(&packagePath, "p", "", "The package path (importmap) of the package being compiled")
	fs.Var(&gcFlags, "gcflags", "Go compiler flags")
	fs.Var(&asmFlags, "asmflags", "Go assembler flags")
	fs.Var(&cppFlags, "cppflags", "C preprocessor flags")
	fs.Var(&cFlags, "cflags", "C compiler flags")
	fs.Var(&cxxFlags, "cxxflags", "C++ compiler flags")
	fs.Var(&objcFlags, "objcflags", "Objective-C compiler flags")
	fs.Var(&objcxxFlags, "objcxxflags", "Objective-C++ compiler flags")
	fs.Var(&ldFlags, "ldflags", "C linker flags")
	fs.StringVar(&packageListPath, "package_list", "", "The file containing the list of standard library packages")
	fs.StringVar(&coverMode, "cover_mode", "", "The coverage mode to use. Empty if coverage instrumentation should not be added.")
	fs.StringVar(&outLinkobjPath, "lo", "", "The full output archive file required by the linker")
	fs.StringVar(&outInterfacePath, "o", "", "The export-only output archive required to compile dependent packages")
	fs.StringVar(&outSyntheticTestmainManifestPath, "synthetic_testmain_manifest", "", "Sidecar manifest that records compile-time Datadog helper packagefiles for synthetic Bazel testmain archives")
	fs.StringVar(&cgoExportHPath, "cgoexport", "", "The _cgo_exports.h file to write")
	fs.StringVar(&cgoGoSrcsPath, "cgo_go_srcs", "", "The directory to emit cgo-generated Go sources for nogo consumption to")
	fs.StringVar(&testFilter, "testfilter", "off", "Controls test package filtering")
	fs.StringVar(&coverFormat, "cover_format", "", "Emit source file paths in coverage instrumentation suitable for the specified coverage format")
	fs.Var(&recompileInternalDeps, "recompile_internal_deps", "The import path of the direct dependencies that needs to be recompiled.")
	fs.StringVar(&pgoprofile, "pgoprofile", "", "The pprof profile to consider for profile guided optimization.")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if err := goenv.checkFlagsAndSetGoroot(); err != nil {
		return err
	}
	if importPath == "" {
		importPath = packagePath
	}
	cgoEnabled := os.Getenv("CGO_ENABLED") == "1"
	cc := os.Getenv("CC")
	outLinkobjPath = abs(outLinkobjPath)
	for i := range unfilteredSrcs {
		unfilteredSrcs[i] = abs(unfilteredSrcs[i])
	}
	for i := range embedSrcs {
		embedSrcs[i] = abs(embedSrcs[i])
	}
	if pgoprofile != "" {
		pgoprofile = abs(pgoprofile)
	}

	// Filter sources.
	srcs, err := filterAndSplitFiles(unfilteredSrcs)
	if err != nil {
		return err
	}

	err = applyTestFilter(testFilter, &srcs)
	if err != nil {
		return err
	}

	return compileArchive(
		goenv,
		pack,
		importPath,
		packagePath,
		srcs,
		deps,
		coverMode,
		coverSrcs,
		embedSrcs,
		embedLookupDirs,
		embedRoots,
		cgoEnabled,
		cc,
		gcFlags,
		asmFlags,
		cppFlags,
		cFlags,
		cxxFlags,
		objcFlags,
		objcxxFlags,
		ldFlags,
		packageListPath,
		outLinkobjPath,
		outInterfacePath,
		outSyntheticTestmainManifestPath,
		cgoExportHPath,
		cgoGoSrcsPath,
		coverFormat,
		recompileInternalDeps,
		pgoprofile,
		orchestrion)
}

func compileArchive(
	goenv *env,
	pack string,
	orchImportPath string,
	packagePath string,
	srcs archiveSrcs,
	deps []archive,
	coverMode string,
	coverSrcs []string,
	embedSrcs []string,
	embedLookupDirs []string,
	embedRoots []string,
	cgoEnabled bool,
	cc string,
	gcFlags []string,
	asmFlags []string,
	cppFlags []string,
	cFlags []string,
	cxxFlags []string,
	objcFlags []string,
	objcxxFlags []string,
	ldFlags []string,
	packageListPath string,
	outLinkObj string,
	outInterfacePath string,
	outSyntheticTestmainManifestPath string,
	cgoExportHPath string,
	cgoGoSrcsForNogoPath string,
	coverFormat string,
	recompileInternalDeps []string,
	pgoprofile string,
	orchestrion string,
) error {
	var syntheticTestmainPackagefiles string
	workDir, cleanup, err := goenv.workDir()
	if err != nil {
		return err
	}
	defer cleanup()

	if len(srcs.goSrcs) == 0 {
		// We need to run the compiler to create a valid archive, even if there's nothing in it.
		// Otherwise, GoPack will complain if we try to add assembly or cgo objects.
		// A truly empty archive does not include any references to source file paths, which
		// ensures hermeticity even though the temp file path is random.
		emptyGoFile, err := os.CreateTemp(filepath.Dir(outLinkObj), "*.go")
		if err != nil {
			return err
		}
		defer os.Remove(emptyGoFile.Name())
		defer emptyGoFile.Close()
		if _, err := emptyGoFile.WriteString("package empty\n"); err != nil {
			return err
		}
		if err := emptyGoFile.Close(); err != nil {
			return err
		}

		srcs.goSrcs = append(srcs.goSrcs, fileInfo{
			filename: emptyGoFile.Name(),
			ext:      goExt,
			matched:  true,
			pkg:      "empty",
		})
	}
	packageName := srcs.goSrcs[0].pkg
	var goSrcs, cgoSrcs []string
	for _, src := range srcs.goSrcs {
		if src.isCgo {
			cgoSrcs = append(cgoSrcs, src.filename)
		} else {
			goSrcs = append(goSrcs, src.filename)
		}
	}
	cSrcs := make([]string, len(srcs.cSrcs))
	for i, src := range srcs.cSrcs {
		cSrcs[i] = src.filename
	}
	cxxSrcs := make([]string, len(srcs.cxxSrcs))
	for i, src := range srcs.cxxSrcs {
		cxxSrcs[i] = src.filename
	}
	objcSrcs := make([]string, len(srcs.objcSrcs))
	for i, src := range srcs.objcSrcs {
		objcSrcs[i] = src.filename
	}
	objcxxSrcs := make([]string, len(srcs.objcxxSrcs))
	for i, src := range srcs.objcxxSrcs {
		objcxxSrcs[i] = src.filename
	}
	sSrcs := make([]string, len(srcs.sSrcs))
	for i, src := range srcs.sSrcs {
		sSrcs[i] = src.filename
	}
	hSrcs := make([]string, len(srcs.hSrcs))
	for i, src := range srcs.hSrcs {
		hSrcs[i] = src.filename
	}

	// haveCgo is true if the package contains Cgo files.
	haveCgo := len(cgoSrcs)+len(cSrcs)+len(cxxSrcs)+len(objcSrcs)+len(objcxxSrcs) > 0
	// compilingWithCgo is true if the package contains Cgo files AND Cgo is enabled. A package
	// containing Cgo files can also be built with Cgo disabled, and will work if there are build
	// constraints.
	compilingWithCgo := haveCgo && cgoEnabled

	// When coverage is set, source files will be modified during instrumentation. We should only run static analysis
	// over original source files and not the modified ones.
	// goSrcsNogo and cgoSrcsNogo are copies of the original source files for nogo to run static analysis.
	// TODO: Use slices.Clone when 1.21 is the minimal supported version.
	goSrcsNogo := append([]string{}, goSrcs...)
	cgoSrcsNogo := append([]string{}, cgoSrcs...)

	// Instrument source files in a package for coverage.
	var coverageCfg string
	if coverMode != "" {
		relCoverPath := make(map[string]string)
		for _, s := range coverSrcs {
			relCoverPath[abs(s)] = s
		}

		combined := append([]string{}, goSrcs...)
		if cgoEnabled {
			combined = append(combined, cgoSrcs...)
		}

		var (
			coverIn        []string
			coverOut       []string
			srcPathMapping = make(map[string]string)
		)
		for i, origSrc := range combined {
			if _, ok := relCoverPath[origSrc]; !ok {
				continue
			}

			var srcName string
			switch coverFormat {
			case "go_cover":
				srcName = origSrc
				if orchImportPath != "" {
					srcName = path.Join(orchImportPath, filepath.Base(origSrc))
				}
			case "lcov":
				// Bazel merges lcov reports across languages and thus assumes
				// that the source file paths are relative to the exec root.
				//
				// In the go's coverageredesign, rules_go no longer is able to
				// set the filepath key generated to Go's coverage output files
				// so we keep a mapping from importpath/filename format emitted
				// by the go runtime in the coverageredesign to the exec root
				// relative source path required by lcov. We will use this mapping
				// to write the lcov file with the expected exec root relative source
				// path.
				srcName = relCoverPath[origSrc]
				srcPathMapping[srcName] = path.Join(orchImportPath, filepath.Base(srcName))
			default:
				return fmt.Errorf("invalid value for -cover_format: %q", coverFormat)
			}

			stem := filepath.Base(origSrc)
			if ext := filepath.Ext(stem); ext != "" {
				stem = stem[:len(stem)-len(ext)]
			}
			coverSrc := filepath.Join(workDir, fmt.Sprintf("cover_%d.go", i))

			coverIn = append(coverIn, origSrc)
			coverOut = append(coverOut, coverSrc)

			if i < len(goSrcs) {
				goSrcs[i] = coverSrc
				continue
			}

			cgoSrcs[i-len(goSrcs)] = coverSrc
		}

		// Modeled after go toolchain's coverage variables configuration.
		// https://github.com/golang/go/blob/go1.24.5/src/cmd/go/internal/work/exec.go#L1932
		sum := sha256.Sum256([]byte(orchImportPath))
		coverVar := fmt.Sprintf("goCover_%x_", sum[:6])
		if len(coverOut) > 0 {
			coverageCfg = workDir + "pkgcfg.txt"
			coverOut, err := instrumentForCoverage(goenv, orchImportPath, packageName, coverIn, coverVar, coverMode, coverOut, workDir, relCoverPath, srcPathMapping)
			if err != nil {
				return err
			}
			goSrcs = append(goSrcs, coverOut[0])
		}
	}

	syntheticTestmain := isSyntheticTestmainCompile(packagePath, goSrcs)
	if syntheticTestmain && orchestrion != "" {
		srcs, deps, syntheticTestmainPackagefiles, err = augmentSyntheticTestmainRoots(goenv, pack, workDir, srcs, deps, embedLookupDirs, orchestrion)
		if err != nil {
			return err
		}
		goSrcs = make([]string, len(srcs.goSrcs))
		for i, src := range srcs.goSrcs {
			goSrcs[i] = src.filename
		}
	}

	// If we have cgo, generate separate C and go files, and compile the
	// C files.
	var objFiles []string
	if compilingWithCgo {
		var srcDir string
		if coverMode != "" && cgoGoSrcsForNogoPath != "" {
			// If the package uses Cgo, compile .s and .S files with cgo2, not the Go assembler.
			// Otherwise: the .s/.S files will be compiled with the Go assembler later
			srcDir, goSrcs, objFiles, err = cgo2(goenv, goSrcs, cgoSrcs, cSrcs, cxxSrcs, objcSrcs, objcxxSrcs, sSrcs, hSrcs, packagePath, packageName, cc, cppFlags, cFlags, cxxFlags, objcFlags, objcxxFlags, ldFlags, cgoExportHPath, "")
			if err != nil {
				return err
			}
			// Also run cgo on original source files, not coverage instrumented, if using nogo.
			// The compilation outputs are only used to run cgo, but the generated sources are
			// passed to the separate nogo action via cgoGoSrcsForNogoPath.
			_, _, _, err = cgo2(goenv, goSrcsNogo, cgoSrcsNogo, cSrcs, cxxSrcs, objcSrcs, objcxxSrcs, sSrcs, hSrcs, packagePath, packageName, cc, cppFlags, cFlags, cxxFlags, objcFlags, objcxxFlags, ldFlags, "", cgoGoSrcsForNogoPath)
			if err != nil {
				return err
			}
		} else {
			// If the package uses Cgo, compile .s and .S files with cgo2, not the Go assembler.
			// Otherwise: the .s/.S files will be compiled with the Go assembler later
			srcDir, goSrcs, objFiles, err = cgo2(goenv, goSrcs, cgoSrcs, cSrcs, cxxSrcs, objcSrcs, objcxxSrcs, sSrcs, hSrcs, packagePath, packageName, cc, cppFlags, cFlags, cxxFlags, objcFlags, objcxxFlags, ldFlags, cgoExportHPath, cgoGoSrcsForNogoPath)
			if err != nil {
				return err
			}
		}
		gcFlags = append(gcFlags, "-trimpath="+srcDir)
	} else {
		if cgoExportHPath != "" {
			if err := os.WriteFile(cgoExportHPath, nil, 0o666); err != nil {
				return err
			}
		}
		trimPath, err := createTrimPath()
		if err != nil {
			return err
		}
		// Preserve an existing -trimpath argument, applying abs() to each prefix.
		for i, flag := range gcFlags {
			if strings.HasPrefix(flag, "-trimpath=") {
				gcFlags = append(gcFlags[:i], gcFlags[i+1:]...)
				rewrites := strings.Split(flag[len("-trimpath="):], ";")
				for j, rewrite := range rewrites {
					prefix, replace := rewrite, ""
					if p := strings.LastIndex(rewrite, "=>"); p >= 0 {
						prefix, replace = rewrite[:p], rewrite[p:]
					}
					rewrites[j] = abs(prefix) + replace
				}
				rewrites = append(rewrites, trimPath)
				trimPath = strings.Join(rewrites, ";")
				break
			}
		}
		gcFlags = append(gcFlags, "-trimpath="+trimPath)
	}

	importcfgPath, err := checkImportsAndBuildCfg(goenv, orchImportPath, srcs, deps, packageListPath, recompileInternalDeps, compilingWithCgo, coverMode, workDir, orchestrion)
	if err != nil {
		return err
	}

	// Build an embedcfg file mapping embed patterns to filenames.
	// Embed patterns are relative to any one of a list of root directories
	// that may contain embeddable files. Source files containing embed patterns
	// must be in one of these root directories so the pattern appears to be
	// relative to the source file. Due to transitions, source files can reside
	// under Bazel roots different from both those of the go srcs and those of
	// the compilation output. Thus, we have to consider all combinations of
	// Bazel roots embedsrcs and root-relative paths of source files and the
	// output binary.
	var embedRootDirs []string
	for _, root := range embedRoots {
		for _, lookupDir := range embedLookupDirs {
			embedRootDir := abs(filepath.Join(root, lookupDir))
			// Since we are iterating over all combinations of roots and
			// root-relative paths, some resulting paths may not exist and
			// should be filtered out before being passed to buildEmbedcfgFile.
			// Since Bazel uniquified both the roots and the root-relative
			// paths, the combinations are automatically unique.
			if _, err := os.Stat(embedRootDir); err == nil {
				embedRootDirs = append(embedRootDirs, embedRootDir)
			}
		}
	}
	embedcfgPath, err := buildEmbedcfgFile(srcs.goSrcs, embedSrcs, embedRootDirs, workDir)
	if err != nil {
		return err
	}
	if embedcfgPath != "" {
		if !goenv.shouldPreserveWorkDir {
			defer os.Remove(embedcfgPath)
		}
	}

	// If there are Go assembly files and this is go1.12+: generate symbol ABIs.
	// This excludes Cgo packages: they use the C compiler for assembly.
	asmHdrPath := ""
	if len(srcs.sSrcs) > 0 {
		asmHdrPath = filepath.Join(workDir, "go_asm.h")
	}
	var symabisPath string
	if !haveCgo {
		symabisPath, err = buildSymabisFile(goenv, packagePath, srcs.sSrcs, srcs.hSrcs, asmHdrPath)
		if symabisPath != "" {
			if !goenv.shouldPreserveWorkDir {
				defer os.Remove(symabisPath)
			}
		}
		if err != nil {
			return err
		}
	}

	// Compile the filtered .go files.
	if err := compileGo(goenv, goSrcs, embedLookupDirs, orchImportPath, packagePath, importcfgPath, embedcfgPath, asmHdrPath, symabisPath, gcFlags, pgoprofile, outLinkObj, outInterfacePath, coverageCfg, orchestrion); err != nil {
		return err
	}
	if syntheticTestmain {
		if outSyntheticTestmainManifestPath == "" {
			outSyntheticTestmainManifestPath = syntheticTestmainPackagefileManifestSidecarPath(outLinkObj)
		}
		if err := writeSyntheticTestmainPackagefileManifest(outSyntheticTestmainManifestPath, syntheticTestmainPackagefiles); err != nil {
			if !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
	}

	// Compile the .s files with Go's assembler, if this is not a cgo package.
	// Cgo is assembled by cc above.
	if len(srcs.sSrcs) > 0 && !haveCgo {
		includeSet := map[string]struct{}{
			filepath.Join(os.Getenv("GOROOT"), "pkg", "include"): {},
			workDir: {},
		}
		for _, hdr := range srcs.hSrcs {
			includeSet[filepath.Dir(hdr.filename)] = struct{}{}
		}
		includes := make([]string, 0, len(includeSet))
		for inc := range includeSet {
			includes = append(includes, inc)
		}
		sort.Strings(includes)
		for _, inc := range includes {
			asmFlags = append(asmFlags, "-I", inc)
		}
		for i, sSrc := range srcs.sSrcs {
			obj := filepath.Join(workDir, fmt.Sprintf("s%d.o", i))
			if err := asmFile(goenv, sSrc.filename, packagePath, asmFlags, obj); err != nil {
				return err
			}
			objFiles = append(objFiles, obj)
		}
	}

	// Windows resource files (.syso) are treated the same as object files.
	for _, src := range srcs.sysoSrcs {
		objFiles = append(objFiles, src.filename)
	}

	// Pack .o and .syso files into the archive. These may come from cgo generated code,
	// cgo dependencies (cdeps), windows resource file generation, or assembly.
	if len(objFiles) > 0 {
		if err := appendToArchive(goenv, pack, outLinkObj, objFiles); err != nil {
			return err
		}
	}

	return nil
}

func augmentSyntheticTestmainRoots(goenv *env, pack, workDir string, srcs archiveSrcs, deps []archive, embedLookupDirs []string, orchestrion string) (archiveSrcs, []archive, string, error) {
	packages := make([]string, 0, len(syntheticTestmainRootPackages)+len(orchestrionLinkClosurePackages))
	for _, root := range syntheticTestmainRootPackages {
		packages = append(packages, root.packagePath)
	}
	for _, pkg := range orchestrionLinkClosurePackages {
		if pkg == "" {
			continue
		}
		packages = append(packages, pkg)
	}
	moduleDir := ""
	for _, dir := range embedLookupDirs {
		moduleDir = findContainingOrchestrionDir(dir)
		if moduleDir != "" {
			break
		}
	}
	if moduleDir == "" {
		for _, src := range srcs.goSrcs {
			moduleDir = findContainingOrchestrionDir(src.filename)
			if moduleDir != "" {
				break
			}
		}
	}
	exports := make(map[string]string)
	compileExports := make(map[string]string)
	exportPackages := make([]string, 0, len(packages))
	for _, pkg := range packages {
		if syntheticTestmainSourceCompiledPackages[pkg] {
			continue
		}
		exportPackages = append(exportPackages, pkg)
	}

	forcedExportRoot := ""
	if sourceCompiledExports, exportRoot, err := compileSyntheticTestmainSourcePackages(goenv, pack, workDir, moduleDir, packages); err != nil {
		return srcs, deps, "", fmt.Errorf("compile synthetic testmain source packages: %w", err)
	} else {
		forcedExportRoot = exportRoot
		for pkg, archive := range sourceCompiledExports {
			compileExports[pkg] = archive.compilePath
			exports[pkg] = archive.linkPath
			for depPkg, depPath := range archive.linkClosure {
				if strings.TrimSpace(depPath) == "" {
					continue
				}
				if _, ok := compileExports[depPkg]; ok {
					continue
				}
				if _, ok := exports[depPkg]; !ok {
					exports[depPkg] = depPath
				}
			}
		}
	}
	if len(exportPackages) > 0 {
		resolvedExports, err := resolveModuleExportsForPackagesWithRoot(goenv, exportPackages, orchestrion, moduleDir, forcedExportRoot)
		if err != nil {
			return srcs, deps, "", fmt.Errorf("resolve synthetic testmain root exports: %w", err)
		}
		for pkg, exportPath := range resolvedExports {
			exports[pkg] = exportPath
		}
	}

	var importLines []string
	manifestLines := make(map[string]struct{}, len(exports)*2)
	addManifestLine := func(line string) {
		line = strings.TrimSpace(line)
		if line == "" {
			return
		}
		manifestLines[line] = struct{}{}
	}
	for _, root := range syntheticTestmainRootPackages {
		compilePath := strings.TrimSpace(compileExports[root.packagePath])
		linkPath := strings.TrimSpace(exports[root.packagePath])
		if compilePath == "" {
			compilePath = linkPath
		}
		if compilePath == "" || linkPath == "" {
			return srcs, deps, "", fmt.Errorf("missing export for synthetic testmain root package %s", root.packagePath)
		}
		deps = append(deps, archive{
			importPath:  root.alias,
			packagePath: root.packagePath,
			file:        compilePath,
		})
		importLines = append(importLines, fmt.Sprintf("\t_ %q", root.alias))
		addManifestLine(fmt.Sprintf("importmap %s=%s", root.alias, root.packagePath))
		addManifestLine(fmt.Sprintf("packagefile %s=%s", root.packagePath, linkPath))
	}
	for pkg, exportPath := range exports {
		pkg = strings.TrimSpace(pkg)
		exportPath = strings.TrimSpace(exportPath)
		if pkg == "" || exportPath == "" {
			continue
		}
		if !strings.Contains(pkg, ".") {
			continue
		}
		addManifestLine(fmt.Sprintf("packagefile %s=%s", pkg, exportPath))
	}

	source := "package main\n\nimport (\n" + strings.Join(importLines, "\n") + "\n)\n"
	filename := filepath.Join(workDir, "orchestrion_testmain_linkdeps.go")
	if err := os.WriteFile(filename, []byte(source), 0o644); err != nil {
		return srcs, deps, "", fmt.Errorf("write synthetic testmain linkdeps source: %w", err)
	}
	extraSrcs, err := filterAndSplitFiles([]string{filename})
	if err != nil {
		return srcs, deps, "", fmt.Errorf("parse synthetic testmain linkdeps source: %w", err)
	}
	manifestEntries := make([]string, 0, len(manifestLines))
	for line := range manifestLines {
		manifestEntries = append(manifestEntries, line)
	}
	sort.Strings(manifestEntries)
	manifestPath := filepath.Join(workDir, syntheticTestmainPackagefileManifestName)
	if err := os.WriteFile(manifestPath, []byte(strings.Join(manifestEntries, "\n")+"\n"), 0o644); err != nil {
		return srcs, deps, "", fmt.Errorf("write synthetic testmain packagefile manifest: %w", err)
	}
	srcs.goSrcs = append(srcs.goSrcs, extraSrcs.goSrcs...)
	return srcs, deps, manifestPath, nil
}

type modulePackageMetadata struct {
	Dir        string
	ImportPath string
	Name       string
	Root       string
	GoFiles    []string
	CgoFiles   []string
	HFiles     []string
	SFiles     []string
	SysoFiles  []string
	EmbedFiles []string
	Imports    []string
	Module     struct {
		Dir string
	}
}

type compiledModuleArchive struct {
	compilePath string
	linkPath    string
	linkClosure map[string]string
}

func compileSyntheticTestmainSourcePackages(goenv *env, pack, workDir, moduleDir string, packages []string) (map[string]compiledModuleArchive, string, error) {
	selected := make([]string, 0, len(packages))
	for _, pkg := range packages {
		if syntheticTestmainSourceCompiledPackages[pkg] {
			selected = append(selected, pkg)
		}
	}
	if len(selected) == 0 {
		return nil, "", nil
	}

	resolveModuleDir, err := prepareSyntheticTestmainModuleDir(workDir)
	if err != nil {
		return nil, "", err
	}
	exportRoot, err := prepareModuleExportRoot(goenv, resolveModuleDir)
	if err != nil {
		return nil, "", err
	}
	compiled := make(map[string]compiledModuleArchive, len(selected))
	metaCache := make(map[string]*modulePackageMetadata)
	sourceDecisions := make(map[string]bool)
	sourceCompiledSet := make(map[string]bool, len(selected))
	for _, pkg := range selected {
		sourceCompiledSet[pkg] = true
	}
	for _, pkg := range selected {
		if _, _, err := compileSyntheticTestmainSourcePackage(goenv, pack, workDir, resolveModuleDir, exportRoot, sourceCompiledSet, sourceDecisions, metaCache, compiled, pkg); err != nil {
			return nil, "", err
		}
	}
	exports := make(map[string]compiledModuleArchive, len(compiled))
	for pkg, archive := range compiled {
		exports[pkg] = archive
	}
	return exports, exportRoot, nil
}

func prepareSyntheticTestmainModuleDir(workDir string) (string, error) {
	versions, err := configuredDDTraceGoVersions()
	if err != nil {
		return "", err
	}
	moduleDir := filepath.Join(workDir, "synthetic_testmain_module")
	if err := os.MkdirAll(moduleDir, 0o755); err != nil {
		return "", fmt.Errorf("prepare synthetic testmain module dir: %w", err)
	}
	goModPath := filepath.Join(moduleDir, "go.mod")
	if err := os.WriteFile(goModPath, []byte(syntheticOrchestrionGoMod(versions)), 0o644); err != nil {
		return "", fmt.Errorf("write synthetic testmain go.mod: %w", err)
	}
	return moduleDir, nil
}

func prepareModuleExportRoot(goenv *env, moduleDir string) (string, error) {
	env := append([]string{}, os.Environ()...)
	gopath := getEnv(env, "GOPATH")
	if gopath == "" {
		gopath = filepath.Join(os.TempDir(), "datadog-orchestrion-go-cache")
	}
	gopath = abs(gopath)
	if err := os.MkdirAll(gopath, 0o755); err != nil {
		return "", fmt.Errorf("prepare module gopath: %w", err)
	}

	requestKey, err := moduleExportRequestKey(moduleDir, goenv)
	if err != nil {
		return "", fmt.Errorf("derive module export request key: %w", err)
	}
	exportRoot := filepath.Join(gopath, "cache", "module-exports", requestKey)
	exportRoot = abs(exportRoot)
	if err := os.MkdirAll(exportRoot, 0o755); err != nil {
		return "", fmt.Errorf("prepare module gocache: %w", err)
	}
	if err := seedWovenStdlibCache(goenv, exportRoot); err != nil {
		return "", fmt.Errorf("seed module gocache from woven stdlib cache: %w", err)
	}
	return exportRoot, nil
}

func modulePackageCommandEnv(goenv *env, exportRoot string) ([]string, error) {
	env := append([]string{}, os.Environ()...)
	env = setEnv(env, "GO111MODULE", "on")
	env = setEnv(env, "GOWORK", "off")
	env = setEnv(env, orchestrionJobserverURLEnvVar, "")
	env = setEnv(env, orchestrionSkipPinEnvVar, "")
	if goenv.goroot != "" {
		env = setEnv(env, "GOROOT", abs(goenv.goroot))
	}

	goBin := filepath.Join(abs(goenv.sdk), "bin")
	env = setEnv(env, "PATH", goBin+string(os.PathListSeparator)+getEnv(env, "PATH"))

	gopath := getEnv(env, "GOPATH")
	if gopath == "" {
		gopath = filepath.Join(os.TempDir(), "datadog-orchestrion-go-cache")
	}
	gopath = abs(gopath)
	if err := os.MkdirAll(gopath, 0o755); err != nil {
		return nil, fmt.Errorf("prepare module gopath: %w", err)
	}
	env = setEnv(env, "GOPATH", gopath)

	gomodcache := getEnv(env, "GOMODCACHE")
	if gomodcache == "" {
		gomodcache = filepath.Join(gopath, "pkg", "mod")
	}
	gomodcache = abs(gomodcache)
	if err := os.MkdirAll(gomodcache, 0o755); err != nil {
		return nil, fmt.Errorf("prepare module gomodcache: %w", err)
	}
	env = setEnv(env, "GOMODCACHE", gomodcache)
	env = setEnv(env, "GOCACHE", abs(exportRoot))
	env = setEnv(env, orchestrionStdlibCacheEnvVar, goenv.stdlibCache)

	if getEnv(env, "GOPROXY") == "" {
		env = setEnv(env, "GOPROXY", "https://proxy.golang.org,direct")
	}
	if getEnv(env, "GOSUMDB") == "" {
		env = setEnv(env, "GOSUMDB", "sum.golang.org")
	}
	if getEnv(env, "GOFLAGS") == "" {
		env = setEnv(env, "GOFLAGS", "-mod=mod")
	}
	if getEnv(env, "HOME") == "" {
		homePath := filepath.Join(os.TempDir(), "datadog-orchestrion-home")
		if err := os.MkdirAll(homePath, 0o755); err != nil {
			return nil, fmt.Errorf("prepare module home: %w", err)
		}
		env = setEnv(env, "HOME", homePath)
	}
	return env, nil
}

func loadModulePackageMetadata(goenv *env, moduleDir, exportRoot, pkg string) (*modulePackageMetadata, error) {
	args := goenv.goCmd("list", "-json", pkg)
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = "."
	if moduleDir != "" {
		cmd.Dir = abs(moduleDir)
	}
	env, err := modulePackageCommandEnv(goenv, exportRoot)
	if err != nil {
		return nil, err
	}
	cmd.Env = env
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("go list package metadata for %s: %w\n%s", pkg, err, string(output))
	}
	var meta modulePackageMetadata
	if err := json.Unmarshal(output, &meta); err != nil {
		return nil, fmt.Errorf("parse package metadata for %s: %w", pkg, err)
	}
	if meta.Dir == "" || meta.ImportPath == "" || len(meta.GoFiles) == 0 {
		return nil, fmt.Errorf("incomplete package metadata for %s", pkg)
	}
	return &meta, nil
}

func loadModulePackageMetadataCached(goenv *env, moduleDir, exportRoot string, cache map[string]*modulePackageMetadata, pkg string) (*modulePackageMetadata, error) {
	if meta := cache[pkg]; meta != nil {
		return meta, nil
	}
	meta, err := loadModulePackageMetadata(goenv, moduleDir, exportRoot, pkg)
	if err != nil {
		return nil, err
	}
	cache[pkg] = meta
	return meta, nil
}

func packageNeedsSyntheticSourceCompile(goenv *env, moduleDir, exportRoot, pkg string, rootSet map[string]bool, decisions map[string]bool, metaCache map[string]*modulePackageMetadata, visiting map[string]bool) (bool, error) {
	if rootSet[pkg] {
		decisions[pkg] = true
		return true, nil
	}
	if decision, ok := decisions[pkg]; ok {
		return decision, nil
	}
	if visiting[pkg] {
		return false, nil
	}
	meta, err := loadModulePackageMetadataCached(goenv, moduleDir, exportRoot, metaCache, pkg)
	if err != nil {
		return false, err
	}
	if len(meta.CgoFiles) > 0 {
		decisions[pkg] = false
		return false, nil
	}
	visiting[pkg] = true
	defer delete(visiting, pkg)
	for _, imp := range meta.Imports {
		imp = strings.TrimSpace(imp)
		if imp == "" || !strings.Contains(imp, ".") {
			switch imp {
			case "flag", "log", "log/slog", "net/http", "os", "os/exec", "testing":
				decisions[pkg] = true
				return true, nil
			}
			continue
		}
		depNeedsCompile, err := packageNeedsSyntheticSourceCompile(goenv, moduleDir, exportRoot, imp, rootSet, decisions, metaCache, visiting)
		if err != nil {
			return false, err
		}
		if depNeedsCompile {
			decisions[pkg] = true
			return true, nil
		}
	}
	decisions[pkg] = false
	return false, nil
}

func compileSyntheticTestmainSourcePackage(goenv *env, pack, workDir, moduleDir, exportRoot string, rootSet map[string]bool, sourceDecisions map[string]bool, metaCache map[string]*modulePackageMetadata, compiled map[string]compiledModuleArchive, pkg string) (string, string, error) {
	if archive, ok := compiled[pkg]; ok {
		return archive.compilePath, archive.linkPath, nil
	}
	meta, err := loadModulePackageMetadataCached(goenv, moduleDir, exportRoot, metaCache, pkg)
	if err != nil {
		return "", "", err
	}
	resolveModuleDir := moduleDir
	linkClosure := make(map[string]string)
	directDepPkgs := make([]string, 0, len(meta.Imports))
	seenDeps := make(map[string]bool, len(meta.Imports))
	imports := make(map[string]*archive, len(meta.Imports))
	for _, imp := range meta.Imports {
		imp = strings.TrimSpace(imp)
		if imp == "" || imp == "C" {
			continue
		}
		if strings.Contains(imp, ".") {
			if !seenDeps[imp] {
				seenDeps[imp] = true
				sourceCompileDep, err := packageNeedsSyntheticSourceCompile(goenv, moduleDir, exportRoot, imp, rootSet, sourceDecisions, metaCache, map[string]bool{})
				if err != nil {
					return "", "", fmt.Errorf("inspect source-compile dependency %s for %s: %w", imp, pkg, err)
				}
				if sourceCompileDep {
					compilePath, linkPath, err := compileSyntheticTestmainSourcePackage(goenv, pack, workDir, moduleDir, exportRoot, rootSet, sourceDecisions, metaCache, compiled, imp)
					if err != nil {
						return "", "", fmt.Errorf("compile source dependency %s for %s: %w", imp, pkg, err)
					}
					imports[imp] = &archive{
						importPath:  imp,
						packagePath: imp,
						file:        compilePath,
					}
					linkClosure[imp] = linkPath
					if depArchive, ok := compiled[imp]; ok {
						for depPkg, depPath := range depArchive.linkClosure {
							linkClosure[depPkg] = depPath
						}
					}
				} else {
					directDepPkgs = append(directDepPkgs, imp)
				}
			}
			continue
		}
		imports[imp] = nil
	}

	depExports, err := resolveModuleExportsForPackagesWithRoot(goenv, directDepPkgs, "", resolveModuleDir, exportRoot)
	if err != nil {
		return "", "", fmt.Errorf("resolve direct exports for %s: %w", pkg, err)
	}
	for depPkg, depPath := range depExports {
		if strings.TrimSpace(depPath) != "" {
			linkClosure[depPkg] = depPath
		}
	}
	for _, imp := range directDepPkgs {
		exportPath := strings.TrimSpace(depExports[imp])
		if exportPath == "" {
			return "", "", fmt.Errorf("missing direct export for %s dependency %s", pkg, imp)
		}
		imports[imp] = &archive{
			importPath:  imp,
			packagePath: imp,
			file:        exportPath,
		}
	}

	packageWorkDir := filepath.Join(workDir, "synthetic_testmain_source_"+sanitizePathForIdentifier(meta.ImportPath))
	if err := os.MkdirAll(packageWorkDir, 0o755); err != nil {
		return "", "", fmt.Errorf("prepare synthetic package work dir for %s: %w", pkg, err)
	}
	importcfgPath, err := buildImportcfgFileForCompile(imports, goenv.installSuffix, packageWorkDir)
	if err != nil {
		return "", "", fmt.Errorf("build importcfg for %s: %w", pkg, err)
	}
	if err := rewriteImportcfgFromCurrentStdlibEntries(importcfgPath, goenv); err != nil {
		return "", "", fmt.Errorf("rewrite stdlib importcfg for %s: %w", pkg, err)
	}

	srcPaths := make([]string, 0, len(meta.GoFiles))
	for _, name := range meta.GoFiles {
		srcPaths = append(srcPaths, filepath.Join(meta.Dir, name))
	}
	for _, name := range meta.HFiles {
		srcPaths = append(srcPaths, filepath.Join(meta.Dir, name))
	}
	for _, name := range meta.SFiles {
		srcPaths = append(srcPaths, filepath.Join(meta.Dir, name))
	}
	for _, name := range meta.SysoFiles {
		srcPaths = append(srcPaths, filepath.Join(meta.Dir, name))
	}
	filteredSrcs, err := filterAndSplitFiles(srcPaths)
	if err != nil {
		return "", "", fmt.Errorf("parse Go files for %s: %w", pkg, err)
	}
	embedSrcPaths := make([]string, 0, len(meta.EmbedFiles))
	for _, embedFile := range meta.EmbedFiles {
		embedSrcPaths = append(embedSrcPaths, filepath.Join(meta.Dir, filepath.FromSlash(embedFile)))
	}
	embedcfgPath, err := buildEmbedcfgFile(filteredSrcs.goSrcs, embedSrcPaths, []string{meta.Dir}, packageWorkDir)
	if err != nil {
		return "", "", fmt.Errorf("build embedcfg for %s: %w", pkg, err)
	}

	archiveDir := filepath.Join(exportRoot, "manual")
	if err := os.MkdirAll(archiveDir, 0o755); err != nil {
		return "", "", fmt.Errorf("prepare synthetic archive dir for %s: %w", pkg, err)
	}
	stem := fmt.Sprintf("%x", sha256.Sum256([]byte(meta.ImportPath)))[:16]
	outLinkobjPath := filepath.Join(archiveDir, stem+".a")
	outInterfacePath := filepath.Join(archiveDir, stem+".iface.a")
	trimPath, err := createTrimPath()
	if err != nil {
		return "", "", fmt.Errorf("create trimpath for %s: %w", pkg, err)
	}
	gcFlags := []string{"-trimpath=" + trimPath}
	goSrcs := make([]string, len(filteredSrcs.goSrcs))
	for i, src := range filteredSrcs.goSrcs {
		goSrcs[i] = src.filename
	}
	asmHdrPath := ""
	if len(filteredSrcs.sSrcs) > 0 {
		asmHdrPath = filepath.Join(packageWorkDir, "go_asm.h")
	}
	var symabisPath string
	if len(filteredSrcs.sSrcs) > 0 {
		symabisPath, err = buildSymabisFile(goenv, meta.ImportPath, filteredSrcs.sSrcs, filteredSrcs.hSrcs, asmHdrPath)
		if err != nil {
			return "", "", fmt.Errorf("build symabis for %s: %w", pkg, err)
		}
	}
	if err := compileGo(goenv, goSrcs, nil, meta.ImportPath, meta.ImportPath, importcfgPath, embedcfgPath, asmHdrPath, symabisPath, gcFlags, "", outLinkobjPath, outInterfacePath, "", ""); err != nil {
		return "", "", fmt.Errorf("compile synthetic helper %s: %w", pkg, err)
	}
	objFiles := make([]string, 0, len(filteredSrcs.sSrcs)+len(filteredSrcs.sysoSrcs))
	if len(filteredSrcs.sSrcs) > 0 {
		includeSet := map[string]struct{}{
			filepath.Join(os.Getenv("GOROOT"), "pkg", "include"): {},
			packageWorkDir: {},
		}
		for _, hdr := range filteredSrcs.hSrcs {
			includeSet[filepath.Dir(hdr.filename)] = struct{}{}
		}
		includes := make([]string, 0, len(includeSet))
		for inc := range includeSet {
			includes = append(includes, inc)
		}
		sort.Strings(includes)
		asmFlags := make([]string, 0, len(includes)*2)
		for _, inc := range includes {
			asmFlags = append(asmFlags, "-I", inc)
		}
		for i, sSrc := range filteredSrcs.sSrcs {
			obj := filepath.Join(packageWorkDir, fmt.Sprintf("s%d.o", i))
			if err := asmFile(goenv, sSrc.filename, meta.ImportPath, asmFlags, obj); err != nil {
				return "", "", fmt.Errorf("assemble synthetic helper %s: %w", pkg, err)
			}
			objFiles = append(objFiles, obj)
		}
	}
	for _, src := range filteredSrcs.sysoSrcs {
		objFiles = append(objFiles, src.filename)
	}
	if len(objFiles) > 0 {
		if err := appendToArchive(goenv, pack, outLinkobjPath, objFiles); err != nil {
			return "", "", fmt.Errorf("append synthetic helper objects for %s: %w", pkg, err)
		}
	}

	compileExports := map[string]string{meta.ImportPath: outInterfacePath}
	if err := sanitizeModuleExportArchives(compileExports); err != nil {
		return "", "", fmt.Errorf("sanitize synthetic helper compile archive %s: %w", pkg, err)
	}
	result := compiledModuleArchive{
		compilePath: compileExports[meta.ImportPath],
		linkPath:    outLinkobjPath,
		linkClosure: linkClosure,
	}
	compiled[pkg] = result
	return result.compilePath, result.linkPath, nil
}

func shouldSkipOrchestrionForImportPath(importPath string) bool {
	return strings.HasPrefix(importPath, "github.com/bazelbuild/rules_go/go/tools/")
}

func checkImportsAndBuildCfg(goenv *env, importPath string, srcs archiveSrcs, deps []archive, packageListPath string, recompileInternalDeps []string, compilingWithCgo bool, coverMode string, workDir string, _ string) (string, error) {
	// Check that the filtered sources don't import anything outside of
	// the standard library and the direct dependencies.
	imports, err := checkImports(srcs.goSrcs, deps, packageListPath, importPath, recompileInternalDeps)
	if err != nil {
		return "", err
	}
	if compilingWithCgo {
		// cgo generated code imports some extra packages.
		imports["runtime/cgo"] = nil
		imports["syscall"] = nil
		imports["unsafe"] = nil
	}
	if coverMode != "" {
		if coverMode == "atomic" {
			imports["sync/atomic"] = nil
		}
		const coverdataPath = "github.com/bazelbuild/rules_go/go/tools/coverdata"
		var coverdata *archive
		for i := range deps {
			if deps[i].importPath == coverdataPath {
				coverdata = &deps[i]
				break
			}
		}
		if coverdata == nil {
			return "", errors.New("coverage requested but coverdata dependency not provided")
		}
		imports[coverdataPath] = coverdata
		imports["runtime/coverage"] = nil
	}

	// Build an importcfg file for the compiler.
	importcfgPath, err := buildImportcfgFileForCompile(imports, goenv.installSuffix, workDir)
	if err != nil {
		return "", err
	}
	if shouldSkipOrchestrionForImportPath(importPath) {
		if err := rewriteImportcfgFromCurrentStdlibEntries(importcfgPath, goenv); err != nil {
			return "", fmt.Errorf("compilepkg: rewrite importcfg from helper package stdlib entries: %w", err)
		}
	} else {
		if err := rewriteImportcfgForDefaultCacheStdlibExports(importcfgPath, goenv); err != nil {
			return "", fmt.Errorf("compilepkg: rewrite importcfg from cache stdlib exports: %w", err)
		}
	}
	return importcfgPath, nil
}

func compileGo(goenv *env, srcs []string, embedLookupDirs []string, orchImportPath, packagePath, importcfgPath, embedcfgPath, asmHdrPath, symabisPath string, gcFlags []string, pgoprofile, outLinkobjPath, outInterfacePath, coverageCfg, orchestrion string) error {
	sdkPath := abs(goenv.sdk)
	syntheticTestmain := isSyntheticTestmainCompile(packagePath, srcs)
	if shouldSkipOrchestrionForImportPath(orchImportPath) {
		orchestrion = ""
	}
	if syntheticTestmain && orchestrion != "" {
		orchestrion = ""
	}
	if orchestrion != "" {
		orchestrion = abs(orchestrion)
		goenv.sdk = sdkPath
	}
	args := goenv.goToolWithOrchestion(orchestrion, "compile")
	args = append(args, "-p", packagePath, "-importcfg", importcfgPath, "-pack")
	// Add a buildid when using orchestrion - it needs this for its NBT caching
	if orchestrion != "" {
		buildID := fmt.Sprintf("%x", sha256.Sum256([]byte(packagePath+outLinkobjPath)))[:16]
		args = append(args, "-buildid", buildID)
	}
	if embedcfgPath != "" {
		args = append(args, "-embedcfg", embedcfgPath)
	}
	if asmHdrPath != "" {
		args = append(args, "-asmhdr", asmHdrPath)
	}
	if symabisPath != "" {
		args = append(args, "-symabis", symabisPath)
	}
	if pgoprofile != "" {
		args = append(args, "-pgoprofile", pgoprofile)
	}
	if coverageCfg != "" {
		args = append(args, "-coveragecfg", coverageCfg)
	}
	args = append(args, gcFlags...)
	args = append(args, "-o", outInterfacePath)
	args = append(args, "-linkobj", outLinkobjPath)
	args = append(args, "--")
	args = append(args, srcs...)
	absArgs(args, []string{"-I", "-o", "-importcfg"})

	// Orchestrion requires a go.mod file - create a temporary one if needed
	// Also look for orchestrion.yml in source directories
	if orchestrion != "" {
		srcDirs := make([]string, 0, len(srcs))
		seen := make(map[string]bool)

		addSrcDir := func(dir string) {
			if dir == "" {
				return
			}
			// Get absolute path to handle symlinks properly
			if absDir, err := filepath.Abs(dir); err == nil {
				// Also resolve symlinks to find the real source directory
				if realDir, err := filepath.EvalSymlinks(absDir); err == nil {
					dir = realDir
				} else {
					dir = absDir
				}
			}
			if !seen[dir] {
				seen[dir] = true
				srcDirs = append(srcDirs, dir)
			}
		}
		for _, lookupDir := range embedLookupDirs {
			addSrcDir(lookupDir)
		}
		for _, src := range srcs {
			addSrcDir(filepath.Dir(src))
		}
		restoreOrchWorkDir, err := enterOrchestrionWorkDir(srcDirs, goenv.verbose)
		if err != nil {
			return fmt.Errorf("compilepkg: %w", err)
		}
		defer restoreOrchWorkDir()
		orchImportPath = resolveOrchestrionImportPath(orchImportPath, goenv.verbose)
		if syntheticTestmain && !strings.HasSuffix(orchImportPath, ".test") {
			orchImportPath += ".test"
		}
		cleanupGoMod, err := ensureGoModExists(srcDirs, sdkPath, goenv.verbose)
		if err != nil {
			return fmt.Errorf("compilepkg: %w", err)
		}
		defer cleanupGoMod()
	}

	// Start orchestrion jobserver if needed. Use the normalized GOROOT captured
	// during flag parsing; do not recompute it after any orchestrion chdir.
	goRootPath := goenv.goroot
	if goRootPath == "" {
		goRootPath = os.Getenv("GOROOT")
	}
	var jobserver *orchestrionJobserver
	if !syntheticTestmain {
		var err error
		jobserver, err = startOrchestrionJobserver(orchestrion, sdkPath, goRootPath, goenv.verbose)
		if err != nil {
			return fmt.Errorf("compilepkg: failed to start orchestrion jobserver: %w", err)
		}
		defer jobserver.cleanup()
	}

	// TOOLEXEC_IMPORTPATH should match the compiler import path, not Bazel's
	// internal importmap/package path.
	return goenv.runCommandWithJobserver(args, jobserver, orchImportPath)
}

func appendToArchive(goenv *env, pack, outPath string, objFiles []string) error {
	// Use abs to work around long path issues on Windows.
	args := []string{pack, "r", abs(outPath)}
	args = append(args, objFiles...)
	return goenv.runCommand(args)
}

func createTrimPath() (string, error) {
	trimPath, err := os.Getwd()
	if err != nil {
		return "", err
	}
	// Create a trim path to make paths relative to the working directory.
	// First, attempt to trim the working directory, and if this fails, replace
	// the parent of the working directory with "..".
	trimPath = fmt.Sprintf("%s;%s=>..", trimPath, filepath.Dir(trimPath))
	return trimPath, nil
}

func sanitizePathForIdentifier(path string) string {
	return strings.Map(func(r rune) rune {
		if 'A' <= r && r <= 'Z' ||
			'a' <= r && r <= 'z' ||
			'0' <= r && r <= '9' ||
			r == '_' {
			return r
		}
		return '_'
	}, path)
}

func isSyntheticTestmainCompile(packagePath string, srcs []string) bool {
	if packagePath != "main" || len(srcs) != 1 {
		return false
	}
	return filepath.Base(srcs[0]) == "testmain.go"
}
