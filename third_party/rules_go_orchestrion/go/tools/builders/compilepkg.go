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
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strconv"
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
) (err error) {
	span := beginProbe(
		"compilepkg.compile_archive",
		newProbeField("package_path", packagePath),
		newProbeField("import_path", orchImportPath),
		newProbeField("orchestrion", strconv.FormatBool(orchestrion != "")),
	)
	defer func() {
		span.End(err)
	}()
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
		synthSpan := beginProbe("compilepkg.augment_synthetic_testmain_roots", newProbeField("package_path", packagePath))
		srcs, deps, syntheticTestmainPackagefiles, err = augmentSyntheticTestmainRoots(goenv, pack, workDir, srcs, deps, embedLookupDirs, orchestrion)
		synthSpan.End(err)
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

	importcfgSpan := beginProbe("compilepkg.check_imports_and_build_cfg", newProbeField("package_path", packagePath))
	importcfgPath, err := checkImportsAndBuildCfg(goenv, orchImportPath, srcs, deps, packageListPath, recompileInternalDeps, compilingWithCgo, coverMode, workDir, orchestrion)
	importcfgSpan.End(err)
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
	compileSpan := beginProbe("compilepkg.compile_go", newProbeField("package_path", packagePath))
	if err := compileGo(goenv, goSrcs, embedLookupDirs, orchImportPath, packagePath, importcfgPath, embedcfgPath, asmHdrPath, symabisPath, gcFlags, pgoprofile, outLinkObj, outInterfacePath, coverageCfg, orchestrion); err != nil {
		compileSpan.End(err)
		return err
	}
	compileSpan.End(nil)
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

func augmentSyntheticTestmainRoots(goenv *env, pack, workDir string, srcs archiveSrcs, deps []archive, embedLookupDirs []string, orchestrion string) (_ archiveSrcs, _ []archive, _ string, err error) {
	span := beginProbe("compilepkg.augment_synthetic_testmain_roots")
	defer func() {
		span.End(err)
	}()
	existingArchives := existingArchivesByPackagePath(deps)
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
		if isSyntheticTestmainSourceCompileCandidate(pkg) {
			continue
		}
		exportPackages = append(exportPackages, pkg)
	}

	forcedExportRoot := ""
	if sourceCompiledExports, exportRoot, err := compileSyntheticTestmainSourcePackages(goenv, pack, workDir, moduleDir, packages, existingArchives); err != nil {
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
		if existing, ok := existingArchives[root.packagePath]; ok {
			compilePath = existing.file
			linkPath = linkArchiveForExistingDependency(existing.file)
		}
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
		if existing, ok := existingArchives[pkg]; ok {
			exportPath = linkArchiveForExistingDependency(existing.file)
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

// existingArchivesByPackagePath indexes the archives Bazel already passed to
// the synthetic testmain compile. These archives belong to the consumer's
// normal dependency graph, so synthetic packagefile manifests must prefer them
// over module-built helper archives to keep compile and link fingerprints
// aligned.
func existingArchivesByPackagePath(deps []archive) map[string]archive {
	archives := make(map[string]archive, len(deps))
	for _, dep := range deps {
		packagePath := strings.TrimSpace(dep.packagePath)
		file := strings.TrimSpace(dep.file)
		if packagePath == "" || file == "" {
			continue
		}
		if _, ok := archives[packagePath]; ok {
			continue
		}
		dep.file = file
		archives[packagePath] = dep
	}
	return archives
}

// linkArchiveForExistingDependency converts a compile-time export archive into
// the matching full archive when rules_go emitted the conventional .x/.a pair.
// Link manifests need the full archive and must not capture the absolute
// sandbox path from the compile action, because the manifest is consumed by a
// later link action in a different sandbox.
func linkArchiveForExistingDependency(file string) string {
	file = strings.TrimSpace(file)
	if file == "" {
		return ""
	}
	file = execrootRelativePath(file)
	if strings.HasSuffix(file, ".x") {
		file = strings.TrimSuffix(file, ".x") + ".a"
	}
	return file
}

// execrootRelativePath strips the current action's execroot prefix from Bazel
// input paths before those paths are written to reusable artifacts. Absolute
// paths outside the execroot are left intact because they refer to cache files
// outside Bazel's action sandbox.
func execrootRelativePath(file string) string {
	if !filepath.IsAbs(file) {
		return file
	}
	cwd, err := os.Getwd()
	if err != nil {
		return file
	}
	rel, err := filepath.Rel(cwd, file)
	if err != nil || rel == "." || rel == "" {
		return file
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return file
	}
	return rel
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

type helperArchiveManifest struct {
	Key                   string                              `json:"key"`
	KeyParts              []string                            `json:"key_parts,omitempty"`
	ExportRoot            string                              `json:"export_root"`
	HelperArchiveCache    string                              `json:"helper_archive_cache"`
	SourcePackages        []string                            `json:"source_packages,omitempty"`
	ExternalPackages      []string                            `json:"external_packages,omitempty"`
	DependencyClosureHash string                              `json:"dependency_closure_hash,omitempty"`
	Packages              map[string]helperArchiveManifestPkg `json:"packages"`
}

type helperArchiveManifestPkg struct {
	CompilePath string            `json:"compile_path"`
	LinkPath    string            `json:"link_path"`
	LinkClosure map[string]string `json:"link_closure"`
}

const helperManifestExecrootPathPrefix = "execroot:"

// helperDecisionManifest stores the reusable synthetic testmain dependency
// classification so helper bundle rebuilds can skip rediscovering the same
// source-compile closure on later cold misses.
type helperDecisionManifest struct {
	Key                   string                           `json:"key"`
	KeyParts              []string                         `json:"key_parts,omitempty"`
	HelperDecisionCache   string                           `json:"helper_decision_cache"`
	SourceDecisions       map[string]bool                  `json:"source_decisions"`
	SourcePackages        []string                         `json:"source_packages"`
	ExternalPackages      []string                         `json:"external_packages"`
	DependencyClosureHash string                           `json:"dependency_closure_hash,omitempty"`
	Metadata              map[string]modulePackageMetadata `json:"metadata"`
}

// syntheticTestmainHelperDecisionState is the in-memory view of the persisted
// helper decision manifest used while rebuilding helper bundles.
type syntheticTestmainHelperDecisionState struct {
	metaCache        map[string]*modulePackageMetadata
	sourceDecisions  map[string]bool
	sourcePackages   []string
	externalPackages []string
}

func compileSyntheticTestmainSourcePackages(goenv *env, pack, workDir, moduleDir string, packages []string, existingArchives map[string]archive) (_ map[string]compiledModuleArchive, _ string, err error) {
	span := beginProbe(
		"compilepkg.compile_synthetic_testmain_source_packages",
		newProbeField("package_count", strconv.Itoa(len(packages))),
	)
	defer func() {
		span.End(err)
	}()
	selected := make([]string, 0, len(packages))
	for _, pkg := range packages {
		if isSyntheticTestmainSourceCompileCandidate(pkg) {
			selected = append(selected, pkg)
		}
	}
	if len(selected) == 0 {
		return nil, "", nil
	}

	resolveModuleDir, err := prepareSyntheticTestmainModuleDir(workDir, moduleDir)
	if err != nil {
		return nil, "", err
	}
	decisionCachePaths, decisionKeyParts, err := syntheticTestmainHelperDecisionCachePaths(goenv)
	if err != nil {
		return nil, "", err
	}
	sourceCompiledSet := syntheticSourceCompiledSet(selected, existingArchives)
	decisionModuleCacheRoot, err := syntheticTestmainHelperModuleCacheRoot(decisionKeyParts)
	if err != nil {
		return nil, "", err
	}
	var decisionState syntheticTestmainHelperDecisionState
	if err := withSyntheticTestmainModuleCacheEnv(decisionModuleCacheRoot, func() error {
		var loadErr error
		decisionState, loadErr = loadOrBuildSyntheticTestmainHelperDecisionState(goenv, resolveModuleDir, decisionCachePaths, decisionKeyParts, selected)
		return loadErr
	}); err != nil {
		return nil, "", err
	}
	decisionState = decisionState.withExistingArchiveOverrides(sourceCompiledSet, existingArchives)

	existingKeyParts, err := syntheticExistingArchiveKeyParts(syntheticRelevantExistingArchives(selected, decisionState, existingArchives))
	if err != nil {
		return nil, "", err
	}
	cachePaths, helperKeyParts, err := syntheticTestmainHelperCachePaths(goenv, existingKeyParts)
	if err != nil {
		return nil, "", err
	}
	if cacheEntryReady(cachePaths) {
		emitProbeLine(
			"compilepkg.synthetic_testmain_helper_cache_hit",
			0,
			newProbeField("entry_dir", cachePaths.entryDir),
			newProbeField("status", "ok"),
		)
		return loadSyntheticTestmainHelperCache(cachePaths)
	}
	emitProbeLine(
		"compilepkg.synthetic_testmain_helper_cache_miss",
		0,
		newProbeField("entry_dir", cachePaths.entryDir),
		newProbeField("status", "ok"),
	)

	releaseLock, err := acquireCacheLock(cachePaths.lockDir, cacheLockTimeout, cacheLockStaleAfter)
	if err != nil {
		return nil, "", err
	}
	defer releaseLock()

	if cacheEntryReady(cachePaths) {
		return loadSyntheticTestmainHelperCache(cachePaths)
	}
	helperModuleCacheRoot, err := syntheticTestmainHelperModuleCacheRoot(helperKeyParts)
	if err != nil {
		return nil, "", err
	}

	tempEntryDir, err := os.MkdirTemp(filepath.Dir(cachePaths.entryDir), filepath.Base(cachePaths.entryDir)+".tmp-*")
	if err != nil {
		return nil, "", fmt.Errorf("create synthetic helper cache temp dir: %w", err)
	}
	success := false
	defer func() {
		if !success {
			_ = os.RemoveAll(tempEntryDir)
		}
	}()

	exportRoot := filepath.Join(tempEntryDir, "exports")
	if err := prepareModuleExportRootAt(goenv, exportRoot); err != nil {
		return nil, "", err
	}

	compiled := make(map[string]compiledModuleArchive, len(selected))
	if err := withSyntheticTestmainModuleCacheEnv(helperModuleCacheRoot, func() error {
		externalExports, err := resolveSyntheticTestmainExternalExports(goenv, resolveModuleDir, decisionState.externalPackages)
		if err != nil {
			return err
		}
		preferExistingArchiveExports(externalExports, existingArchives)
		for _, pkg := range selected {
			if !sourceCompiledSet[pkg] {
				continue
			}
			if _, _, err := compileSyntheticTestmainSourcePackage(goenv, pack, workDir, resolveModuleDir, exportRoot, sourceCompiledSet, decisionState.sourceDecisions, decisionState.metaCache, compiled, externalExports, pkg); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return nil, "", err
	}
	if err := writeSyntheticTestmainHelperManifest(tempEntryDir, compiled, decisionState, helperKeyParts); err != nil {
		return nil, "", err
	}
	if err := writeReadySentinel(filepath.Join(tempEntryDir, cacheReadyFileName)); err != nil {
		return nil, "", fmt.Errorf("write synthetic helper cache ready file: %w", err)
	}
	if err := promoteCacheTempDir(tempEntryDir, cachePaths.entryDir); err != nil {
		return nil, "", fmt.Errorf("promote synthetic helper cache: %w", err)
	}
	success = true
	return loadSyntheticTestmainHelperCache(cachePaths)
}

func prepareSyntheticTestmainModuleDir(workDir, sourceModuleDir string) (string, error) {
	versions, err := configuredDDTraceGoVersionsRequired()
	if err != nil {
		return "", err
	}
	orchestrionVersion, err := configuredOrchestrionToolVersion()
	if err != nil {
		return "", err
	}
	moduleDir := filepath.Join(workDir, "synthetic_testmain_module")
	if err := os.MkdirAll(moduleDir, 0o755); err != nil {
		return "", fmt.Errorf("prepare synthetic testmain module dir: %w", err)
	}
	if _, err := seedSyntheticTestmainModuleFiles(sourceModuleDir, moduleDir, orchestrionVersion, versions); err != nil {
		return "", err
	}
	return moduleDir, nil
}

// seedSyntheticTestmainModuleFiles prepares the module files used by synthetic
// helper subprocesses. When the consumer module exposes all Orchestrion pin
// files, the helper reuses them so `go list` and helper compiles see the same
// dependency graph as the target. Otherwise it falls back to a minimal module
// generated from the repository-rule version pins.
func seedSyntheticTestmainModuleFiles(sourceModuleDir, syntheticDir, orchestrionVersion string, versions map[string]string) (bool, error) {
	pinFiles := []string{"go.mod", "go.sum", "orchestrion.tool.go", "orchestrion.yml"}
	if strings.TrimSpace(sourceModuleDir) != "" {
		allCopied := true
		for _, name := range pinFiles {
			copied, err := copyFileIfExists(filepath.Join(sourceModuleDir, name), filepath.Join(syntheticDir, name))
			if err != nil {
				return false, fmt.Errorf("copy synthetic testmain module file %s: %w", name, err)
			}
			if !copied {
				allCopied = false
				break
			}
		}
		if allCopied {
			return true, nil
		}
	}

	goModPath := filepath.Join(syntheticDir, "go.mod")
	if err := os.WriteFile(goModPath, []byte(syntheticOrchestrionGoMod(orchestrionVersion, versions)), 0o644); err != nil {
		return false, fmt.Errorf("write synthetic testmain go.mod: %w", err)
	}
	return false, nil
}

// prepareModuleExportRoot returns the shared module-export cache root for a
// specific module and request package set.
func prepareModuleExportRoot(goenv *env, moduleDir string, packages []string) (string, error) {
	env := append([]string{}, os.Environ()...)
	gopath := getEnv(env, "GOPATH")
	if gopath == "" {
		gopath = filepath.Join(os.TempDir(), "datadog-orchestrion-go-cache")
	}
	gopath = abs(gopath)
	if err := os.MkdirAll(gopath, 0o755); err != nil {
		return "", fmt.Errorf("prepare module gopath: %w", err)
	}

	requestKey, _, err := moduleExportRequestKey(moduleDir, goenv, packages)
	if err != nil {
		return "", fmt.Errorf("derive module export request key: %w", err)
	}
	exportRoot := filepath.Join(gopath, "cache", "module-exports", requestKey)
	exportRoot = abs(exportRoot)
	if err := prepareModuleExportRootAt(goenv, exportRoot); err != nil {
		return "", err
	}
	return exportRoot, nil
}

// orchestrionPersistentCacheRoot returns the stable cache root shared by
// Orchestrion helper subprocesses for a single action environment.
func orchestrionPersistentCacheRoot(env []string) (string, error) {
	return orchestrionActionCacheRoot(env)
}

// syntheticTestmainHelperModuleCacheRoot returns the GOPATH root dedicated to a
// synthetic helper cache key. Isolating module and build caches per helper key
// prevents stale module downloads or compiled exports from one helper graph
// from affecting a later graph with different inputs.
func syntheticTestmainHelperModuleCacheRoot(keyParts []string) (string, error) {
	cacheRoot, err := orchestrionPersistentCacheRoot(os.Environ())
	if err != nil {
		return "", err
	}
	return filepath.Join(cacheRoot, "synthetic-testmain-helper-module-cache", stableDigestParts(keyParts...)), nil
}

// withSyntheticTestmainModuleCacheEnv points Go module subprocesses at a
// helper-specific cache root for the duration of fn, then restores the caller's
// environment exactly.
func withSyntheticTestmainModuleCacheEnv(cacheRoot string, fn func() error) error {
	names := []string{"GOPATH", "GOMODCACHE", "GOCACHE"}
	previous := make(map[string]string, len(names))
	present := make(map[string]bool, len(names))
	for _, name := range names {
		value, ok := os.LookupEnv(name)
		previous[name] = value
		present[name] = ok
	}
	restore := func() {
		for _, name := range names {
			if present[name] {
				_ = os.Setenv(name, previous[name])
				continue
			}
			_ = os.Unsetenv(name)
		}
	}
	defer restore()

	if err := os.MkdirAll(filepath.Join(cacheRoot, "pkg", "mod"), 0o755); err != nil {
		return fmt.Errorf("prepare synthetic helper module cache: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(cacheRoot, "gocache"), 0o755); err != nil {
		return fmt.Errorf("prepare synthetic helper build cache: %w", err)
	}
	if err := os.Setenv("GOPATH", cacheRoot); err != nil {
		return err
	}
	if err := os.Setenv("GOMODCACHE", filepath.Join(cacheRoot, "pkg", "mod")); err != nil {
		return err
	}
	if err := os.Setenv("GOCACHE", filepath.Join(cacheRoot, "gocache")); err != nil {
		return err
	}
	return fn()
}

func prepareModuleExportRootAt(goenv *env, exportRoot string) error {
	if err := os.MkdirAll(exportRoot, 0o755); err != nil {
		return fmt.Errorf("prepare module gocache: %w", err)
	}
	if err := seedWovenStdlibCache(goenv, exportRoot); err != nil {
		return fmt.Errorf("seed module gocache from woven stdlib cache: %w", err)
	}
	return nil
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
	env, err := normalizeGoActionCacheEnv(env)
	if err != nil {
		return nil, fmt.Errorf("prepare module action cache env: %w", err)
	}
	env = setEnv(env, "GOCACHE", abs(exportRoot))
	env = setEnv(env, orchestrionStdlibCacheEnvVar, goenv.stdlibCache)
	env, err = normalizeGoModuleResolutionEnv(env)
	if err != nil {
		return nil, fmt.Errorf("prepare module resolution env: %w", err)
	}
	moduleCacheRoot := filepath.Join(filepath.Dir(abs(exportRoot)), ".exports_gopath")
	env = setEnv(env, "GOPATH", moduleCacheRoot)
	env = setEnv(env, "GOMODCACHE", filepath.Join(moduleCacheRoot, "pkg", "mod"))
	env = setEnv(env, "GIT_CONFIG_GLOBAL", os.DevNull)
	env = setEnv(env, "GIT_CONFIG_NOSYSTEM", "1")
	env = setEnv(env, "GIT_TERMINAL_PROMPT", "0")
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
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err = cmd.Run()
	if err != nil {
		return nil, fmt.Errorf("go list package metadata for %s: %w\n%s", pkg, err, strings.TrimSpace(stderr.String()))
	}
	var meta modulePackageMetadata
	if err := json.Unmarshal(stdout.Bytes(), &meta); err != nil {
		return nil, fmt.Errorf("parse package metadata for %s: %w", pkg, err)
	}
	if meta.Dir == "" || meta.ImportPath == "" || len(meta.GoFiles) == 0 {
		return nil, fmt.Errorf("incomplete package metadata for %s", pkg)
	}
	return &meta, nil
}

func loadModulePackageMetadataBatch(goenv *env, moduleDir, exportRoot string, packages []string) (map[string]*modulePackageMetadata, error) {
	if len(packages) == 0 {
		return map[string]*modulePackageMetadata{}, nil
	}
	args := goenv.goCmd("list", append([]string{"-e", "-json"}, packages...)...)
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
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err = cmd.Run()
	if err != nil {
		return nil, fmt.Errorf("go list batch package metadata for %v: %w\n%s", packages, err, strings.TrimSpace(stderr.String()))
	}
	decoder := json.NewDecoder(bytes.NewReader(stdout.Bytes()))
	cache := make(map[string]*modulePackageMetadata)
	for {
		var meta modulePackageMetadata
		if err := decoder.Decode(&meta); err != nil {
			if err == io.EOF {
				break
			}
			return nil, fmt.Errorf("parse batch package metadata: %w", err)
		}
		if meta.Dir == "" || meta.ImportPath == "" || len(meta.GoFiles) == 0 {
			continue
		}
		copyMeta := meta
		cache[meta.ImportPath] = &copyMeta
	}
	return cache, nil
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

func syntheticTestmainHelperCachePaths(goenv *env, extraKeyParts []string) (cachePaths, []string, error) {
	keyParts, err := syntheticTestmainHelperCacheKeyParts(goenv)
	if err != nil {
		return cachePaths{}, nil, err
	}
	keyParts = append(keyParts, extraKeyParts...)
	cacheRoot, err := orchestrionActionCacheRoot(os.Environ())
	if err != nil {
		return cachePaths{}, nil, err
	}
	return orchestrionCachePaths(cacheRoot, "synthetic-testmain-helpers", stableDigestParts(keyParts...)), keyParts, nil
}

// syntheticTestmainHelperCacheKeyParts returns the exact inputs that define the
// compiled helper bundle cache identity.
func syntheticTestmainHelperCacheKeyParts(goenv *env) ([]string, error) {
	configuredVersions, err := configuredDDTraceGoVersionsRequired()
	if err != nil {
		return nil, err
	}
	sdkIdentity, err := goSDKCacheIdentity(goenv.sdk)
	if err != nil {
		return nil, err
	}
	stdlibKey, err := currentWovenStdlibCacheKey(goenv)
	if err != nil {
		return nil, err
	}
	return []string{
		"configured_versions=" + ddTraceVersionsDigest(configuredVersions),
		"sdk=" + sdkIdentity,
		"target=" + goTargetIdentity(os.Environ()),
		"installsuffix=" + goenv.installSuffix,
		"stdlib=" + stdlibKey,
		"orchestrion=" + orchestrionToolVersionIdentity(),
		"source_set=" + helperSourceSetVersion,
		"helper_archive_cache=" + helperArchiveCacheABIVersion,
	}, nil
}

// syntheticExistingArchiveKeyParts returns target-specific cache inputs for
// packages that are already present in Bazel's dependency graph and also
// participate in the synthetic helper bundle. Synthetic helpers compile
// against those Bazel-provided export archives, so the helper cache key must
// include those exact files instead of the module-built helper archives.
func syntheticExistingArchiveKeyParts(existingArchives map[string]archive) ([]string, error) {
	if len(existingArchives) == 0 {
		return nil, nil
	}
	packages := make([]string, 0, len(existingArchives))
	for pkg := range existingArchives {
		packages = append(packages, pkg)
	}
	sort.Strings(packages)
	keyParts := make([]string, 0, len(packages))
	for _, pkg := range packages {
		archivePath := existingArchiveCompileExport(existingArchives[pkg].file)
		if strings.TrimSpace(archivePath) == "" {
			continue
		}
		digest, err := digestFileOrMissing(archivePath)
		if err != nil {
			return nil, fmt.Errorf("digest existing synthetic helper archive %s: %w", archivePath, err)
		}
		keyParts = append(keyParts, fmt.Sprintf("existing_archive=%s=%s=%s", pkg, execrootRelativePath(archivePath), digest))
	}
	return keyParts, nil
}

// syntheticTestmainHelperDecisionCachePaths returns the reusable decision graph
// cache used to avoid recomputing helper package classification on bundle
// rebuilds.
func syntheticTestmainHelperDecisionCachePaths(goenv *env) (cachePaths, []string, error) {
	keyParts, err := syntheticTestmainHelperDecisionCacheKeyParts(goenv)
	if err != nil {
		return cachePaths{}, nil, err
	}
	cacheRoot, err := orchestrionActionCacheRoot(os.Environ())
	if err != nil {
		return cachePaths{}, nil, err
	}
	return orchestrionCachePaths(cacheRoot, "synthetic-testmain-helper-decisions", stableDigestParts(keyParts...)), keyParts, nil
}

// syntheticTestmainHelperDecisionCacheKeyParts returns the exact inputs that
// define the helper package decision graph.
func syntheticTestmainHelperDecisionCacheKeyParts(goenv *env) ([]string, error) {
	configuredVersions, err := configuredDDTraceGoVersionsRequired()
	if err != nil {
		return nil, err
	}
	sdkIdentity, err := goSDKCacheIdentity(goenv.sdk)
	if err != nil {
		return nil, err
	}
	return []string{
		"configured_versions=" + ddTraceVersionsDigest(configuredVersions),
		"sdk=" + sdkIdentity,
		"target=" + goTargetIdentity(os.Environ()),
		"orchestrion=" + orchestrionToolVersionIdentity(),
		"source_set=" + helperSourceSetVersion,
		"helper_decision_cache=" + helperDecisionCacheABIVersion,
	}, nil
}

func writeSyntheticTestmainHelperManifest(entryDir string, compiled map[string]compiledModuleArchive, decisionState syntheticTestmainHelperDecisionState, keyParts []string) error {
	manifest := helperArchiveManifest{
		Key:                   filepath.Base(entryDir),
		KeyParts:              append([]string{}, keyParts...),
		ExportRoot:            "exports",
		HelperArchiveCache:    helperArchiveCacheABIVersion,
		SourcePackages:        append([]string{}, decisionState.sourcePackages...),
		ExternalPackages:      append([]string{}, decisionState.externalPackages...),
		DependencyClosureHash: helperDecisionClosureHash(decisionState.metaCache),
		Packages:              make(map[string]helperArchiveManifestPkg, len(compiled)),
	}
	for pkg, archive := range compiled {
		linkClosure := make(map[string]string, len(archive.linkClosure))
		for depPkg, depPath := range archive.linkClosure {
			relPath := syntheticHelperManifestPath(entryDir, depPath)
			linkClosure[depPkg] = relPath
		}
		compileRel := syntheticHelperManifestPath(entryDir, archive.compilePath)
		linkRel := syntheticHelperManifestPath(entryDir, archive.linkPath)
		manifest.Packages[pkg] = helperArchiveManifestPkg{
			CompilePath: compileRel,
			LinkPath:    linkRel,
			LinkClosure: linkClosure,
		}
	}
	return writeJSONAtomically(filepath.Join(entryDir, cacheManifestFileName), manifest)
}

// syntheticHelperManifestPath encodes a helper cache path so cache-owned files
// stay relative to the cache entry while Bazel execroot-relative paths keep
// pointing at the later action's execroot. Synthetic helper link closures may
// reference both kinds of files when a target already provides an archive that
// the helper graph also imports.
func syntheticHelperManifestPath(entryDir, path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	if filepath.IsAbs(path) {
		rel, err := filepath.Rel(entryDir, path)
		if err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
			return rel
		}
		return helperManifestExecrootPathPrefix + path
	}
	return helperManifestExecrootPathPrefix + path
}

// resolveSyntheticHelperManifestPath decodes paths written by
// syntheticHelperManifestPath. Unprefixed paths are cache-entry relative for
// compatibility with the helper archive manifest format; prefixed paths are
// already relative to the consuming Bazel action's execroot or intentionally
// absolute outside the helper cache.
func resolveSyntheticHelperManifestPath(entryDir, path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	if strings.HasPrefix(path, helperManifestExecrootPathPrefix) {
		return strings.TrimPrefix(path, helperManifestExecrootPathPrefix)
	}
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(entryDir, path)
}

// loadOrBuildSyntheticTestmainHelperDecisionState loads a reusable helper
// decision graph if it is already cached; otherwise it rebuilds the graph once
// and persists it for later helper bundle rebuilds.
func loadOrBuildSyntheticTestmainHelperDecisionState(goenv *env, moduleDir string, paths cachePaths, keyParts []string, selected []string) (_ syntheticTestmainHelperDecisionState, err error) {
	if cacheEntryReady(paths) {
		state, loadErr := loadSyntheticTestmainHelperDecisionManifest(paths)
		if loadErr == nil {
			emitProbeLine(
				"compilepkg.synthetic_testmain_helper_decision_cache_hit",
				0,
				newProbeField("entry_dir", paths.entryDir),
				newProbeField("status", "ok"),
			)
			return state, nil
		}
		emitProbeLine(
			"compilepkg.synthetic_testmain_helper_decision_cache_reload_failed",
			0,
			newProbeField("entry_dir", paths.entryDir),
			newProbeField("status", probeStatus(loadErr)),
		)
	}
	emitProbeLine(
		"compilepkg.synthetic_testmain_helper_decision_cache_miss",
		0,
		newProbeField("entry_dir", paths.entryDir),
		newProbeField("status", "ok"),
	)

	releaseLock, err := acquireCacheLock(paths.lockDir, cacheLockTimeout, cacheLockStaleAfter)
	if err != nil {
		return syntheticTestmainHelperDecisionState{}, err
	}
	defer releaseLock()

	if cacheEntryReady(paths) {
		state, loadErr := loadSyntheticTestmainHelperDecisionManifest(paths)
		if loadErr == nil {
			return state, nil
		}
		emitProbeLine(
			"compilepkg.synthetic_testmain_helper_decision_cache_reload_failed",
			0,
			newProbeField("entry_dir", paths.entryDir),
			newProbeField("status", probeStatus(loadErr)),
		)
	}

	state, err := buildSyntheticTestmainHelperDecisionState(goenv, moduleDir, selected)
	if err != nil {
		return syntheticTestmainHelperDecisionState{}, err
	}
	if writeErr := persistSyntheticTestmainHelperDecisionManifest(paths, keyParts, state); writeErr != nil {
		emitProbeLine(
			"compilepkg.synthetic_testmain_helper_decision_cache_write_failed",
			0,
			newProbeField("entry_dir", paths.entryDir),
			newProbeField("status", probeStatus(writeErr)),
		)
	}
	return state, nil
}

// buildSyntheticTestmainHelperDecisionState resolves the helper metadata batch
// and the recursive source-compile decision graph without compiling archives.
func buildSyntheticTestmainHelperDecisionState(goenv *env, moduleDir string, selected []string) (_ syntheticTestmainHelperDecisionState, err error) {
	exportRoot, err := prepareModuleExportRoot(goenv, moduleDir, selected)
	if err != nil {
		return syntheticTestmainHelperDecisionState{}, err
	}
	metaCache, err := loadModulePackageMetadataBatch(goenv, moduleDir, exportRoot, selected)
	if err != nil {
		return syntheticTestmainHelperDecisionState{}, err
	}
	sourceDecisions := make(map[string]bool)
	rootSet := make(map[string]bool, len(selected))
	for _, pkg := range selected {
		rootSet[pkg] = true
	}
	for _, pkg := range selected {
		if _, err := packageNeedsSyntheticSourceCompile(goenv, moduleDir, exportRoot, pkg, rootSet, sourceDecisions, metaCache, map[string]bool{}); err != nil {
			return syntheticTestmainHelperDecisionState{}, err
		}
	}
	return syntheticTestmainHelperDecisionState{
		metaCache:        metaCache,
		sourceDecisions:  sourceDecisions,
		sourcePackages:   sortedTrueDecisionPackages(sourceDecisions),
		externalPackages: collectSyntheticTestmainExternalPackages(rootSet, sourceDecisions, metaCache),
	}, nil
}

// persistSyntheticTestmainHelperDecisionManifest best-effort stores the
// computed helper dependency graph so later bundle rebuilds can reuse it.
func persistSyntheticTestmainHelperDecisionManifest(paths cachePaths, keyParts []string, state syntheticTestmainHelperDecisionState) error {
	tempEntryDir, err := os.MkdirTemp(filepath.Dir(paths.entryDir), filepath.Base(paths.entryDir)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create synthetic helper decision temp dir: %w", err)
	}
	success := false
	defer func() {
		if !success {
			_ = os.RemoveAll(tempEntryDir)
		}
	}()
	if err := writeSyntheticTestmainHelperDecisionManifest(tempEntryDir, state, keyParts); err != nil {
		return err
	}
	if err := writeReadySentinel(filepath.Join(tempEntryDir, cacheReadyFileName)); err != nil {
		return fmt.Errorf("write synthetic helper decision ready file: %w", err)
	}
	if err := promoteCacheTempDir(tempEntryDir, paths.entryDir); err != nil {
		return fmt.Errorf("promote synthetic helper decision cache: %w", err)
	}
	success = true
	return nil
}

// writeSyntheticTestmainHelperDecisionManifest stores the metadata snapshot and
// recursive source-compile decisions for the current synthetic helper graph.
func writeSyntheticTestmainHelperDecisionManifest(entryDir string, state syntheticTestmainHelperDecisionState, keyParts []string) error {
	manifest := helperDecisionManifest{
		Key:                   filepath.Base(entryDir),
		KeyParts:              append([]string{}, keyParts...),
		HelperDecisionCache:   helperDecisionCacheABIVersion,
		SourceDecisions:       copyBoolMap(state.sourceDecisions),
		SourcePackages:        append([]string{}, state.sourcePackages...),
		ExternalPackages:      append([]string{}, state.externalPackages...),
		DependencyClosureHash: helperDecisionClosureHash(state.metaCache),
		Metadata:              metadataSnapshotForManifest(state.metaCache),
	}
	return writeJSONAtomically(filepath.Join(entryDir, cacheManifestFileName), manifest)
}

// loadSyntheticTestmainHelperDecisionManifest loads the persisted helper
// metadata snapshot and validates that the referenced snapshot is complete.
func loadSyntheticTestmainHelperDecisionManifest(paths cachePaths) (syntheticTestmainHelperDecisionState, error) {
	data, err := os.ReadFile(paths.manifestPath)
	if err != nil {
		return syntheticTestmainHelperDecisionState{}, fmt.Errorf("read synthetic helper decision manifest %s: %w", paths.manifestPath, err)
	}
	var manifest helperDecisionManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return syntheticTestmainHelperDecisionState{}, fmt.Errorf("parse synthetic helper decision manifest %s: %w", paths.manifestPath, err)
	}
	metaCache := make(map[string]*modulePackageMetadata, len(manifest.Metadata))
	for pkg, meta := range manifest.Metadata {
		copyMeta := meta
		metaCache[pkg] = &copyMeta
	}
	if len(metaCache) == 0 {
		return syntheticTestmainHelperDecisionState{}, fmt.Errorf("synthetic helper decision manifest %s has no metadata", paths.manifestPath)
	}
	for _, pkg := range manifest.SourcePackages {
		if metaCache[pkg] == nil {
			return syntheticTestmainHelperDecisionState{}, fmt.Errorf("synthetic helper decision manifest %s missing metadata for %s", paths.manifestPath, pkg)
		}
	}
	return syntheticTestmainHelperDecisionState{
		metaCache:        metaCache,
		sourceDecisions:  copyBoolMap(manifest.SourceDecisions),
		sourcePackages:   append([]string{}, manifest.SourcePackages...),
		externalPackages: append([]string{}, manifest.ExternalPackages...),
	}, nil
}

// metadataSnapshotForManifest converts the pointer-based metadata cache into a
// stable JSON payload that can be written to disk.
func metadataSnapshotForManifest(metaCache map[string]*modulePackageMetadata) map[string]modulePackageMetadata {
	snapshot := make(map[string]modulePackageMetadata, len(metaCache))
	for pkg, meta := range metaCache {
		if meta == nil {
			continue
		}
		snapshot[pkg] = *meta
	}
	return snapshot
}

// helperDecisionClosureHash summarizes the helper metadata graph in a stable
// way so manifests can record which dependency closure they describe.
func helperDecisionClosureHash(metaCache map[string]*modulePackageMetadata) string {
	lines := make([]string, 0, len(metaCache))
	for pkg, meta := range metaCache {
		if meta == nil {
			continue
		}
		imports := append([]string{}, meta.Imports...)
		sort.Strings(imports)
		lines = append(lines, pkg+"|"+strings.Join(imports, ","))
	}
	sort.Strings(lines)
	return stableDigestParts(lines...)
}

// sortedTrueDecisionPackages returns the source-compiled package set in a
// stable order so manifests remain deterministic across identical runs.
func sortedTrueDecisionPackages(decisions map[string]bool) []string {
	packages := make([]string, 0, len(decisions))
	for pkg, decision := range decisions {
		if decision {
			packages = append(packages, pkg)
		}
	}
	sort.Strings(packages)
	return packages
}

// copyBoolMap returns a detached copy of a boolean decision map so cache
// callers cannot accidentally mutate shared state.
func copyBoolMap(source map[string]bool) map[string]bool {
	if len(source) == 0 {
		return map[string]bool{}
	}
	copyMap := make(map[string]bool, len(source))
	for key, value := range source {
		copyMap[key] = value
	}
	return copyMap
}

func loadSyntheticTestmainHelperCache(paths cachePaths) (map[string]compiledModuleArchive, string, error) {
	data, err := os.ReadFile(paths.manifestPath)
	if err != nil {
		return nil, "", fmt.Errorf("read synthetic helper cache manifest %s: %w", paths.manifestPath, err)
	}
	var manifest helperArchiveManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, "", fmt.Errorf("parse synthetic helper cache manifest %s: %w", paths.manifestPath, err)
	}
	compiled := make(map[string]compiledModuleArchive, len(manifest.Packages))
	for pkg, archive := range manifest.Packages {
		linkClosure := make(map[string]string, len(archive.LinkClosure))
		for depPkg, depPath := range archive.LinkClosure {
			linkClosure[depPkg] = resolveSyntheticHelperManifestPath(paths.entryDir, depPath)
		}
		compiled[pkg] = compiledModuleArchive{
			compilePath: resolveSyntheticHelperManifestPath(paths.entryDir, archive.CompilePath),
			linkPath:    resolveSyntheticHelperManifestPath(paths.entryDir, archive.LinkPath),
			linkClosure: linkClosure,
		}
	}
	return compiled, filepath.Join(paths.entryDir, manifest.ExportRoot), nil
}

// syntheticSourceCompiledSet returns the helper packages that must still be
// compiled from source for this target. Packages already supplied by Bazel are
// treated as external archives so synthetic helpers compile against the same Go
// fingerprints that the final link action will see.
func syntheticSourceCompiledSet(selected []string, existingArchives map[string]archive) map[string]bool {
	rootSet := make(map[string]bool, len(selected))
	for _, pkg := range selected {
		if _, ok := existingArchives[pkg]; ok {
			continue
		}
		rootSet[pkg] = true
	}
	return rootSet
}

// withExistingArchiveOverrides adjusts a reusable helper decision graph for the
// current Bazel target by forcing already-present packages onto the external
// archive path.
func (state syntheticTestmainHelperDecisionState) withExistingArchiveOverrides(rootSet map[string]bool, existingArchives map[string]archive) syntheticTestmainHelperDecisionState {
	sourceDecisions := copyBoolMap(state.sourceDecisions)
	existingArchiveSet := make(map[string]bool, len(existingArchives))
	for pkg := range existingArchives {
		existingArchiveSet[pkg] = true
		sourceDecisions[pkg] = false
	}
	for pkg := range rootSet {
		if !existingArchiveSet[pkg] {
			sourceDecisions[pkg] = true
		}
	}
	propagateExistingArchiveSourceDecisions(sourceDecisions, rootSet, existingArchiveSet, state.metaCache)
	return syntheticTestmainHelperDecisionState{
		metaCache:        state.metaCache,
		sourceDecisions:  sourceDecisions,
		sourcePackages:   sortedTrueDecisionPackages(sourceDecisions),
		externalPackages: collectSyntheticTestmainExternalPackages(rootSet, sourceDecisions, state.metaCache),
	}
}

// propagateExistingArchiveSourceDecisions marks helper packages for source
// compilation when they depend on a package that must be supplied by Bazel or by
// another source-compiled helper package. Without this propagation, a module
// cache export can be linked next to a Bazel archive with a different Go
// fingerprint for the same dependency.
func propagateExistingArchiveSourceDecisions(sourceDecisions map[string]bool, rootSet map[string]bool, existingArchiveSet map[string]bool, metaCache map[string]*modulePackageMetadata) {
	changed := true
	for changed {
		changed = false
		for pkg, meta := range metaCache {
			if meta == nil || existingArchiveSet[pkg] || len(meta.CgoFiles) > 0 {
				continue
			}
			needsSource := rootSet[pkg] || sourceDecisions[pkg]
			if !needsSource {
				for _, imp := range meta.Imports {
					imp = strings.TrimSpace(imp)
					if imp == "" || imp == "C" || !strings.Contains(imp, ".") {
						continue
					}
					if existingArchiveSet[imp] || sourceDecisions[imp] {
						needsSource = true
						break
					}
				}
			}
			if needsSource && !sourceDecisions[pkg] {
				sourceDecisions[pkg] = true
				changed = true
			}
		}
	}
	for pkg := range existingArchiveSet {
		sourceDecisions[pkg] = false
	}
}

// syntheticRelevantExistingArchives returns the subset of Bazel-provided
// archives that can affect the synthetic helper bundle. This keeps helper cache
// keys precise without hashing every transitive package in a large consumer
// target.
func syntheticRelevantExistingArchives(selected []string, decisionState syntheticTestmainHelperDecisionState, existingArchives map[string]archive) map[string]archive {
	relevant := make(map[string]archive)
	addIfPresent := func(pkg string) {
		pkg = strings.TrimSpace(pkg)
		if pkg == "" {
			return
		}
		if archive, ok := existingArchives[pkg]; ok {
			relevant[pkg] = archive
		}
	}
	for _, pkg := range selected {
		addIfPresent(pkg)
	}
	for _, pkg := range decisionState.externalPackages {
		addIfPresent(pkg)
	}
	return relevant
}

// preferExistingArchiveExports replaces module-built helper dependency exports
// with Bazel-provided compile exports when the final link is already going to
// contain that package. The compile path intentionally stays as the .x export
// file Bazel provided to this action; only the later packagefile manifest
// converts that path to the full .a archive for the link action.
func preferExistingArchiveExports(exports map[string]string, existingArchives map[string]archive) {
	for pkg := range exports {
		existing, ok := existingArchives[pkg]
		if !ok {
			continue
		}
		archivePath := existingArchiveCompileExport(existing.file)
		if strings.TrimSpace(archivePath) == "" {
			continue
		}
		exports[pkg] = archivePath
	}
}

// existingArchiveCompileExport returns the Bazel-provided export archive path
// used while compiling synthetic helper sources. It strips only the current
// execroot prefix so helper caches do not capture sandbox-local absolute paths.
func existingArchiveCompileExport(file string) string {
	file = strings.TrimSpace(file)
	if file == "" {
		return ""
	}
	return execrootRelativePath(file)
}

// collectSyntheticTestmainExternalPackages returns the external helper
// dependencies that still need archive resolution after source compilation.
func collectSyntheticTestmainExternalPackages(rootSet map[string]bool, sourceDecisions map[string]bool, metaCache map[string]*modulePackageMetadata) []string {
	externalDeps := make([]string, 0)
	seen := make(map[string]bool)
	for pkg, meta := range metaCache {
		if !rootSet[pkg] && !sourceDecisions[pkg] {
			continue
		}
		for _, imp := range meta.Imports {
			imp = strings.TrimSpace(imp)
			if imp == "" || imp == "C" || !strings.Contains(imp, ".") {
				continue
			}
			if sourceDecisions[imp] {
				continue
			}
			if seen[imp] {
				continue
			}
			seen[imp] = true
			externalDeps = append(externalDeps, imp)
		}
	}
	sort.Strings(externalDeps)
	return externalDeps
}

// resolveSyntheticTestmainExternalExports resolves external helper dependency
// archives through the shared request-keyed module export cache.
func resolveSyntheticTestmainExternalExports(goenv *env, moduleDir string, externalPackages []string) (map[string]string, error) {
	return resolveModuleExportsForPackages(goenv, externalPackages, "", moduleDir)
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

func compileSyntheticTestmainSourcePackage(goenv *env, pack, workDir, moduleDir, exportRoot string, rootSet map[string]bool, sourceDecisions map[string]bool, metaCache map[string]*modulePackageMetadata, compiled map[string]compiledModuleArchive, externalExports map[string]string, pkg string) (_ string, _ string, err error) {
	span := beginProbe("compilepkg.compile_synthetic_testmain_source_package", newProbeField("package", pkg))
	defer func() {
		span.End(err)
	}()
	if archive, ok := compiled[pkg]; ok {
		return archive.compilePath, archive.linkPath, nil
	}
	meta, err := loadModulePackageMetadataCached(goenv, moduleDir, exportRoot, metaCache, pkg)
	if err != nil {
		return "", "", err
	}
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
					compilePath, linkPath, err := compileSyntheticTestmainSourcePackage(goenv, pack, workDir, moduleDir, exportRoot, rootSet, sourceDecisions, metaCache, compiled, externalExports, imp)
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

	for _, imp := range directDepPkgs {
		exportPath := strings.TrimSpace(externalExports[imp])
		if exportPath == "" {
			return "", "", fmt.Errorf("missing direct export for %s dependency %s", pkg, imp)
		}
		linkClosure[imp] = exportPath
		imports[imp] = &archive{
			importPath:  imp,
			packagePath: imp,
			file:        exportPath,
		}
	}
	for depPkg, depPath := range externalExports {
		depPkg = strings.TrimSpace(depPkg)
		depPath = strings.TrimSpace(depPath)
		if depPkg == "" || depPath == "" {
			continue
		}
		if _, ok := linkClosure[depPkg]; !ok {
			linkClosure[depPkg] = depPath
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
	if strings.HasPrefix(importPath, "github.com/bazelbuild/rules_go/go/tools/") {
		return true
	}
	// Do not weave the tracer runtime itself. Final test links may replace these
	// packages with helper archives; compiling consumers against woven Bazel
	// archives can otherwise leave import and link fingerprints out of sync.
	return strings.HasPrefix(importPath, "github.com/DataDog/dd-trace-go/") ||
		strings.HasPrefix(importPath, "gopkg.in/DataDog/dd-trace-go.v1/")
}

// isSyntheticTestmainSourceCompileCandidate reports whether a helper package
// should be compiled from source in the synthetic testmain helper graph. The
// explicit set covers public helper entry points, while the prefix rules keep
// internal helper packages aligned without adding every new helper dependency
// to a fixed list.
func isSyntheticTestmainSourceCompileCandidate(importPath string) bool {
	importPath = strings.TrimSpace(importPath)
	if syntheticTestmainSourceCompiledPackages[importPath] {
		return true
	}
	if strings.HasPrefix(importPath, "github.com/DataDog/dd-trace-go/v2/internal/") {
		return true
	}
	if strings.HasPrefix(importPath, "github.com/DataDog/dd-trace-go/contrib/") &&
		strings.Contains(importPath, "/internal/orchestrion") {
		return true
	}
	return false
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

func compileGo(goenv *env, srcs []string, embedLookupDirs []string, orchImportPath, packagePath, importcfgPath, embedcfgPath, asmHdrPath, symabisPath string, gcFlags []string, pgoprofile, outLinkobjPath, outInterfacePath, coverageCfg, orchestrion string) (err error) {
	span := beginProbe(
		"compilepkg.compile_go_action",
		newProbeField("package_path", packagePath),
		newProbeField("import_path", orchImportPath),
	)
	defer func() {
		span.End(err)
	}()
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
		workDirSpan := beginProbe("compilepkg.compile_go_action.enter_orchestrion_workdir", newProbeField("package_path", packagePath))
		restoreOrchWorkDir, err := enterOrchestrionWorkDir(srcDirs, goenv.verbose)
		workDirSpan.End(err)
		if err != nil {
			return fmt.Errorf("compilepkg: %w", err)
		}
		defer restoreOrchWorkDir()
		orchImportPath = resolveOrchestrionImportPath(orchImportPath, goenv.verbose)
		if syntheticTestmain && !strings.HasSuffix(orchImportPath, ".test") {
			orchImportPath += ".test"
		}
		goModSpan := beginProbe("compilepkg.compile_go_action.ensure_go_mod_exists", newProbeField("package_path", packagePath))
		cleanupGoMod, err := ensureGoModExists(srcDirs, sdkPath, goenv.verbose)
		goModSpan.End(err)
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
		jobserverSpan := beginProbe("compilepkg.compile_go_action.start_jobserver", newProbeField("package_path", packagePath))
		jobserver, err = startOrchestrionJobserver(orchestrion, sdkPath, goRootPath, goenv.verbose)
		jobserverSpan.End(err)
		if err != nil {
			return fmt.Errorf("compilepkg: failed to start orchestrion jobserver: %w", err)
		}
		defer jobserver.cleanup()
	}

	// TOOLEXEC_IMPORTPATH should match the compiler import path, not Bazel's
	// internal importmap/package path.
	runSpan := beginProbe("compilepkg.compile_go_action.run_command", newProbeField("package_path", packagePath))
	err = goenv.runCommandWithJobserver(args, jobserver, orchImportPath)
	runSpan.End(err)
	return err
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
