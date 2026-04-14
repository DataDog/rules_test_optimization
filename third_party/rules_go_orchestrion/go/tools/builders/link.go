// Copyright 2017 The Bazel Authors. All rights reserved.
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

// link combines the results of a compile step using "go tool link". It is invoked by the
// Go rules as an action.
package main

import (
	"bufio"
	"bytes"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
)

// parseXdef parses a linker -X flag into package, variable, and value fields.
// When the package matches the main package path, the linker expects "main".
func parseXdef(xdef string, mainPackagePath string) (pkg, name, value string, err error) {
	eq := strings.IndexByte(xdef, '=')
	if eq < 0 {
		return "", "", "", fmt.Errorf("-X flag does not contain '=': %s", xdef)
	}
	dot := strings.LastIndexByte(xdef[:eq], '.')
	if dot < 0 {
		return "", "", "", fmt.Errorf("-X flag does not contain '.': %s", xdef)
	}
	pkg, name, value = xdef[:dot], xdef[dot+1:eq], xdef[eq+1:]
	if pkg == mainPackagePath {
		pkg = "main"
	}
	return pkg, name, value, nil
}

// buildInfoInputs stores the raw buildinfo inputs emitted by link.bzl before
// the builder resolves package import paths to their final module versions.
type buildInfoInputs struct {
	Path       string
	ImportDeps []string
}

// readBuildInfoInputs parses the generated buildinfo input file produced by
// link.bzl into the main-package path and raw dependency import paths.
func readBuildInfoInputs(filename string) (buildInfoInputs, error) {
	if filename == "" {
		return buildInfoInputs{}, nil
	}
	data, err := os.ReadFile(filename)
	if err != nil {
		return buildInfoInputs{}, fmt.Errorf("reading buildinfo file %s: %w", filename, err)
	}
	inputs := buildInfoInputs{}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		switch parts[0] {
		case "path":
			if len(parts) >= 2 {
				inputs.Path = strings.TrimSpace(parts[1])
			}
		case "dep":
			if len(parts) >= 2 {
				inputs.ImportDeps = append(inputs.ImportDeps, strings.TrimSpace(parts[1]))
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return buildInfoInputs{}, fmt.Errorf("scanning buildinfo file %s: %w", filename, err)
	}
	return inputs, nil
}

// readVersionMap parses the generated module-version map emitted by link.bzl.
func readVersionMap(filename string) (map[string]string, error) {
	if filename == "" {
		return nil, nil
	}
	data, err := os.ReadFile(filename)
	if err != nil {
		return nil, fmt.Errorf("reading version map file %s: %w", filename, err)
	}
	versionMap := map[string]string{}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) < 2 {
			continue
		}
		versionMap[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scanning version map file %s: %w", filename, err)
	}
	return versionMap, nil
}

// findBestModuleMatch returns the longest module path that matches an import
// path exactly or as a path-segment prefix.
func findBestModuleMatch(importPath string, versionMap map[string]string) (string, string, bool) {
	bestModule := ""
	bestVersion := ""
	for module, version := range versionMap {
		if importPath != module && !strings.HasPrefix(importPath, module+"/") {
			continue
		}
		if len(module) > len(bestModule) {
			bestModule = module
			bestVersion = version
		}
	}
	if bestModule == "" {
		return "", "", false
	}
	return bestModule, bestVersion, true
}

// resolveBuildInfoDeps maps raw dependency import paths to the entries that
// runtime/debug.ReadBuildInfo should expose at runtime.
func resolveBuildInfoDeps(importDeps []string, versionMap map[string]string) []*Module {
	if len(importDeps) == 0 {
		return nil
	}
	seen := map[string]bool{}
	deps := make([]*Module, 0, len(importDeps))
	for _, importDep := range importDeps {
		if importDep == "" {
			continue
		}
		path := importDep
		version := "(devel)"
		if module, moduleVersion, ok := findBestModuleMatch(importDep, versionMap); ok {
			path = module
			version = moduleVersion
		}
		if seen[path] {
			continue
		}
		seen[path] = true
		deps = append(deps, &Module{Path: path, Version: version})
	}
	return deps
}

// parseModulePath reads the module path from a go.mod file.
func parseModulePath(goModPath string) (string, error) {
	data, err := os.ReadFile(goModPath)
	if err != nil {
		return "", fmt.Errorf("reading go.mod %s: %w", goModPath, err)
	}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "module ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "module ")), nil
		}
	}
	if err := scanner.Err(); err != nil {
		return "", fmt.Errorf("scanning go.mod %s: %w", goModPath, err)
	}
	return "", nil
}

// findGoMod walks upward from startDir until it finds a go.mod file.
func findGoMod(startDir string) (string, error) {
	dir := startDir
	for {
		candidate := filepath.Join(dir, "go.mod")
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return "", fmt.Errorf("stat %s: %w", candidate, err)
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", nil
		}
		dir = parent
	}
}

// deriveMainPackagePath prefers the repository module path plus Bazel package
// when that information is available, then falls back to inferring the module
// prefix from dependency import paths before using the raw package path.
func deriveMainPackagePath(rawPath, bazelTarget string, importDeps []string) string {
	path := rawPath
	label := bazelTarget
	if idx := strings.Index(label, "//"); idx >= 0 {
		label = label[idx+2:]
	}
	if label == "" {
		return path
	}
	pkg := label
	name := ""
	if colon := strings.IndexByte(label, ':'); colon >= 0 {
		pkg = label[:colon]
		name = label[colon+1:]
	}
	if name != "" && strings.HasSuffix(path, "/"+name) {
		path = strings.TrimSuffix(path, "/"+name)
	}
	if goModPath, err := findGoMod("."); err == nil && goModPath != "" {
		if modulePath, err := parseModulePath(goModPath); err == nil && modulePath != "" {
			if pkg == "" {
				return modulePath
			}
			return modulePath + "/" + pkg
		}
	}
	if path != "" {
		pattern := "/" + path + "/"
		for _, importDep := range importDeps {
			if idx := strings.Index(importDep, pattern); idx >= 0 {
				return importDep[:idx+1] + path
			}
		}
	}
	if pkg != "" {
		return pkg
	}
	return path
}

func getArchFeature(goarch string) (key, value string) {
	switch goarch {
	case "amd64":
		return "GOAMD64", os.Getenv("GOAMD64")
	case "arm":
		return "GOARM", os.Getenv("GOARM")
	case "386":
		return "GO386", os.Getenv("GO386")
	case "mips", "mipsle":
		return "GOMIPS", os.Getenv("GOMIPS")
	case "mips64", "mips64le":
		return "GOMIPS64", os.Getenv("GOMIPS64")
	case "ppc64", "ppc64le":
		return "GOPPC64", os.Getenv("GOPPC64")
	case "riscv64":
		return "GORISCV64", os.Getenv("GORISCV64")
	case "wasm":
		return "GOWASM", os.Getenv("GOWASM")
	default:
		return "", ""
	}
}

var orchestrionLinkClosurePackages = []string{
	"github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting",
	"github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting/coverage",
	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer",
	"github.com/DataDog/dd-trace-go/v2/internal",
	"github.com/DataDog/dd-trace-go/v2/profiler",
	"github.com/DataDog/dd-trace-go/contrib/net/http/v2",
	"github.com/DataDog/dd-trace-go/contrib/net/http/v2/internal/orchestrion",
	"github.com/DataDog/dd-trace-go/contrib/log/slog/v2",
}

var orchestrionLinkStdlibRoots = []string{
	"flag",
	"log",
	"log/slog",
	"net/http",
	"os",
	"os/exec",
}

func collectOrchestrionLinkClosurePackages(archives []archive) []string {
	seen := map[string]bool{
		"testing":                   true,
		"testing/internal/testdeps": true,
	}
	packages := []string{"testing", "testing/internal/testdeps"}
	add := func(pkg string) {
		pkg = strings.TrimSpace(pkg)
		pkg = strings.TrimPrefix(pkg, "+initfirst/")
		if pkg == "" || seen[pkg] {
			return
		}
		if strings.HasPrefix(pkg, "github.com/bazelbuild/rules_go/") {
			return
		}
		if !strings.Contains(pkg, ".") {
			return
		}
		seen[pkg] = true
		packages = append(packages, pkg)
	}
	for _, archive := range archives {
		add(archive.packagePath)
	}
	for _, pkg := range orchestrionLinkClosurePackages {
		add(pkg)
	}
	return packages
}

func isSyntheticTestmainLink(mainArchive, packagePath string) bool {
	mainBase := filepath.Base(mainArchive)
	return strings.HasSuffix(mainBase, "~testmain.a") && (packagePath == "testmain" || packagePath == "")
}

func readSyntheticTestmainPackagefileManifest(mainArchive string) ([]string, error) {
	sidecarPath := syntheticTestmainPackagefileManifestSidecarPath(mainArchive)
	data, err := os.ReadFile(sidecarPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, fmt.Errorf("read synthetic packagefile manifest sidecar %s: %w", sidecarPath, err)
	}
	directives := strings.Split(strings.TrimSpace(string(data)), "\n")
	filtered := make([]string, 0, len(directives))
	for _, line := range directives {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "packagefile ") {
			filtered = append(filtered, line)
		}
	}
	return filtered, nil
}

func appendSyntheticTestmainPackagefileManifest(importcfgPath, mainArchive string) (bool, error) {
	filtered, err := readSyntheticTestmainPackagefileManifest(mainArchive)
	if err != nil {
		return false, err
	}
	if len(filtered) == 0 {
		return false, nil
	}
	if err := appendOrReplaceImportcfgDirectives(importcfgPath, filtered, "synthetic-testmain-manifest"); err != nil {
		return false, err
	}
	return true, nil
}

func link(args []string) (err error) {
	span := beginProbe("link.action")
	defer func() {
		span.End(err)
	}()
	// Parse arguments.
	args, _, err = expandParamsFiles(args)
	if err != nil {
		return err
	}
	builderArgs, toolArgs := splitArgs(args)
	stamps := multiFlag{}
	xdefs := multiFlag{}
	archives := archiveMultiFlag{}
	flags := flag.NewFlagSet("link", flag.ExitOnError)
	goenv := envFlags(flags)
	main := flags.String("main", "", "Path to the main archive.")
	packagePath := flags.String("p", "", "Package path of the main archive.")
	outFile := flags.String("o", "", "Path to output file.")
	orchestrion := flags.String("orchestrion", "", "Path to orchestrion binary")
	flags.Var(&archives, "arc", "Label, package path, and file name of a dependency, separated by '='")
	packageList := flags.String("package_list", "", "The file containing the list of standard library packages")
	buildmode := flags.String("buildmode", "", "Build mode used.")
	flags.Var(&xdefs, "X", "A string variable to replace in the linked binary (repeated).")
	flags.Var(&stamps, "stamp", "The name of a file with stamping values.")
	buildinfoFile := flags.String("buildinfo", "", "Path to buildinfo dependency file for Go 1.18+ buildInfo.")
	versionMapFile := flags.String("versionmap", "", "Path to version map file with real dependency versions from package_info.")
	bazelTarget := flags.String("bazeltarget", "", "Bazel target label for buildInfo metadata.")
	if err := flags.Parse(builderArgs); err != nil {
		return err
	}
	if err := goenv.checkFlagsAndSetGoroot(); err != nil {
		return err
	}
	// On Windows, take the absolute path of the output file and main file.
	// This is needed on Windows because the relative path is frequently too long.
	// os.Open on Windows converts absolute paths to some other path format with
	// longer length limits. Absolute paths do not work on macOS for .dylib
	// outputs because they get baked in as the "install path".
	if runtime.GOOS != "darwin" && runtime.GOOS != "ios" {
		*outFile = abs(*outFile)
	}
	*main = abs(*main)

	// If we were given any stamp value files, read and parse them
	stampMap := map[string]string{}
	for _, stampfile := range stamps {
		stampbuf, err := os.ReadFile(stampfile)
		if err != nil {
			return fmt.Errorf("reading stamp file %s: %w", stampfile, err)
		}
		scanner := bufio.NewScanner(bytes.NewReader(stampbuf))
		for scanner.Scan() {
			line := strings.SplitN(scanner.Text(), " ", 2)
			switch len(line) {
			case 0:
				// Nothing to do here
			case 1:
				// Map to the empty string
				stampMap[line[0]] = ""
			case 2:
				// Key and value
				stampMap[line[0]] = line[1]
			}
		}
	}

	orchImportPath := *packagePath
	syntheticTestBinaryLink := isSyntheticTestmainLink(*main, *packagePath)
	sdkPath := abs(goenv.sdk)
	linkOrchestrion := *orchestrion
	if syntheticTestBinaryLink {
		linkOrchestrion = ""
	}
	if *orchestrion != "" {
		*orchestrion = abs(*orchestrion)
		if linkOrchestrion != "" {
			linkOrchestrion = abs(linkOrchestrion)
		}
		goenv.sdk = sdkPath
	}

	// generate any additional link options we need
	goargs := goenv.goToolWithOrchestion(linkOrchestrion, "link")

	for _, xdef := range xdefs {
		pkg, name, value, err := parseXdef(xdef, *packagePath)
		if err != nil {
			return err
		}
		var missingKey bool
		value = regexp.MustCompile(`\{.+?\}`).ReplaceAllStringFunc(value, func(key string) string {
			if value, ok := stampMap[key[1:len(key)-1]]; ok {
				return value
			}
			missingKey = true
			return key
		})
		if !missingKey {
			goargs = append(goargs, "-X", fmt.Sprintf("%s.%s=%s", pkg, name, value))
		}
	}

	if *buildmode != "" {
		goargs = append(goargs, "-buildmode", *buildmode)
	}
	goargs = append(goargs, "-o", *outFile)

	buildInfoInputs, err := readBuildInfoInputs(*buildinfoFile)
	if err != nil {
		return err
	}
	versionMap, err := readVersionMap(*versionMapFile)
	if err != nil {
		return err
	}
	goarchFeatureKey, goarchFeatureValue := getArchFeature(os.Getenv("GOARCH"))
	path := *packagePath
	if buildInfoInputs.Path != "" {
		path = deriveMainPackagePath(buildInfoInputs.Path, *bazelTarget, buildInfoInputs.ImportDeps)
	}
	cfg := linkConfig{
		path:               path,
		buildMode:          "exe",
		compiler:           "gc",
		cgoEnabled:         os.Getenv("CGO_ENABLED") == "1",
		goarch:             os.Getenv("GOARCH"),
		goos:               os.Getenv("GOOS"),
		buildinfoFile:      *buildinfoFile,
		deps:               resolveBuildInfoDeps(buildInfoInputs.ImportDeps, versionMap),
		goarchFeatureKey:   goarchFeatureKey,
		goarchFeatureValue: goarchFeatureValue,
		cgoCflags:          os.Getenv("CGO_CFLAGS"),
		cgoCxxflags:        os.Getenv("CGO_CXXFLAGS"),
		cgoLdflags:         os.Getenv("CGO_LDFLAGS"),
		bazelTarget:        *bazelTarget,
	}
	if *buildmode != "" {
		cfg.buildMode = *buildmode
	}

	// substitute `builder cc` for the linker with a symlink to builder called `builder-cc`.
	// unfortunately we can't just set an environment variable to `builder cc` because
	// in `go tool link` the `linkerFlagSupported` [1][2] call sites used to determine
	// if a linker supports various flags all appear to use the first arg after splitting
	// so the `cc` would be left off of `builder cc`
	//
	//    [1]: https://cs.opensource.google/go/go/+/ad7f736d8f51ea03166b698256385c869968ae3e:src/cmd/link/internal/ld/lib.go;l=1739
	//    [2]: https://cs.opensource.google/go/go/+/master:src/cmd/link/internal/ld/lib.go;drc=c6531fae589cf3f9475f3567a5beffb4336fe1d6;l=1429?q=linkerFlagSupported&ss=go%2Fgo
	linkerCleanup, err := absCCLinker(toolArgs)
	if err != nil {
		return err
	}
	defer linkerCleanup()
	// Add the unprocessed pass-through options first. Positional inputs like the
	// main archive must come last so orchestrion's link proxy can still parse
	// later flags such as -importcfg.
	goargs = append(goargs, toolArgs...)

	clearGoRoot, err := onVersion(23)
	if err != nil {
		return err
	}

	syntheticTestBinaryLink = isSyntheticTestmainLink(*main, *packagePath)

	if linkOrchestrion != "" {
		srcDirs := make([]string, 0, len(archives))
		seen := make(map[string]bool)
		addSrcDir := func(dir string) {
			if dir == "" {
				return
			}
			if absDir, err := filepath.Abs(dir); err == nil {
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
		for _, archive := range archives {
			addSrcDir(filepath.Dir(archive.file))
		}
		workDirSpan := beginProbe("link.enter_orchestrion_workdir")
		restoreOrchWorkDir, err := enterOrchestrionWorkDir(srcDirs, goenv.verbose)
		workDirSpan.End(err)
		if err != nil {
			return fmt.Errorf("link: %w", err)
		}
		defer restoreOrchWorkDir()
		if linkOrchestrion != "" {
			goModSpan := beginProbe("link.ensure_go_mod_exists")
			cleanupGoMod, err := ensureGoModExists(srcDirs, goenv.sdk, goenv.verbose)
			goModSpan.End(err)
			if err != nil {
				return fmt.Errorf("link: %w", err)
			}
			defer cleanupGoMod()
		}
		if orchImportPath == "main" {
			orchImportPath = ""
		}
		orchImportPath = resolveOrchestrionImportPath(orchImportPath, goenv.verbose)
		if strings.HasSuffix(*main, "~testmain.a") && !strings.HasSuffix(orchImportPath, ".test") {
			orchImportPath += ".test"
		}
		importcfgSpan := beginProbe("link.build_importcfg")
		importcfgName, err := buildImportcfgFileForLink(archives, *packageList, goenv.installSuffix, filepath.Dir(*outFile), cfg)
		importcfgSpan.End(err)
		if err != nil {
			return err
		}
		if !goenv.shouldPreserveWorkDir {
			defer os.Remove(importcfgName)
		}
		if syntheticTestBinaryLink {
			synthManifestSpan := beginProbe("link.append_synthetic_testmain_manifest")
			_, err := appendSyntheticTestmainPackagefileManifest(importcfgName, *main)
			synthManifestSpan.End(err)
			if err != nil {
				return fmt.Errorf("link: apply synthetic testmain packagefile manifest: %w", err)
			}
			if linkOrchestrion != "" {
				// The synthetic compile manifest only guarantees the helper packages that
				// were explicitly rooted during testmain compile. Final link still needs
				// the broader Datadog closure (for example tracer/profiler). Append the
				// closure only when link itself is orchestrion-enabled; plain synthetic
				// links must reuse the compile-time manifest only.
				modulePkgSpan := beginProbe("link.append_missing_module_packagefiles")
				err := appendMissingModulePackagefiles(importcfgName, goenv, orchestrionLinkClosurePackages, linkOrchestrion, ".")
				modulePkgSpan.End(err)
				if err != nil {
					return fmt.Errorf("link: append module packagefiles for synthetic test binary: %w", err)
				}
			}
		}
		if goenv.stdlibCache != "" {
			rewriteSpan := beginProbe("link.rewrite_importcfg_from_current_stdlib_entries")
			err := rewriteImportcfgFromCurrentStdlibEntries(importcfgName, goenv)
			rewriteSpan.End(err)
			if err != nil {
				return fmt.Errorf("link: rewrite importcfg from current stdlib entries: %w", err)
			}
		} else {
			closurePackages := collectOrchestrionLinkClosurePackages(archives)
			rewriteSpan := beginProbe("link.rewrite_importcfg_for_cache_stdlib_closures", newProbeField("closure_count", strconv.Itoa(len(closurePackages))))
			err := rewriteImportcfgForCacheStdlibClosures(importcfgName, goenv, closurePackages)
			rewriteSpan.End(err)
			if err != nil {
				return fmt.Errorf("link: rewrite importcfg from cache stdlib closures: %w", err)
			}
		}
		goargs = append(goargs, "-importcfg", importcfgName)
		goargs = append(goargs, *main)
		var jobserver *orchestrionJobserver
		if !syntheticTestBinaryLink {
			goRootPath := goenv.goroot
			if goRootPath == "" {
				goRootPath = os.Getenv("GOROOT")
			}
			jobserverSpan := beginProbe("link.start_jobserver")
			jobserver, err = startOrchestrionJobserver(linkOrchestrion, sdkPath, goRootPath, goenv.verbose)
			jobserverSpan.End(err)
			if err != nil {
				return fmt.Errorf("link: failed to start orchestrion jobserver: %w", err)
			}
			defer jobserver.cleanup()
		}
		runSpan := beginProbe("link.run_command", newProbeField("import_path", orchImportPath))
		if err := goenv.runCommandWithJobserver(goargs, jobserver, orchImportPath); err != nil {
			runSpan.End(err)
			return err
		}
		runSpan.End(nil)
	} else {
		var restoreOrchWorkDir func()
		var cleanupGoMod func()
		if syntheticTestBinaryLink {
			srcDirs := make([]string, 0, len(archives))
			seen := make(map[string]bool)
			addSrcDir := func(dir string) {
				if dir == "" {
					return
				}
				if absDir, err := filepath.Abs(dir); err == nil {
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
			for _, archive := range archives {
				addSrcDir(filepath.Dir(archive.packagePath))
			}
			restoreOrchWorkDir, err = enterOrchestrionWorkDir(srcDirs, goenv.verbose)
			if err != nil {
				return fmt.Errorf("link: %w", err)
			}
			defer restoreOrchWorkDir()
			if linkOrchestrion != "" {
				cleanupGoMod, err = ensureGoModExists(srcDirs, goenv.sdk, goenv.verbose)
				if err != nil {
					return fmt.Errorf("link: %w", err)
				}
				defer cleanupGoMod()
			}
		}
		importcfgName, err := buildImportcfgFileForLink(archives, *packageList, goenv.installSuffix, filepath.Dir(*outFile), cfg)
		if err != nil {
			return err
		}
		if !goenv.shouldPreserveWorkDir {
			defer os.Remove(importcfgName)
		}
		if syntheticTestBinaryLink {
			_, err := appendSyntheticTestmainPackagefileManifest(importcfgName, *main)
			if err != nil {
				return fmt.Errorf("link: apply synthetic testmain packagefile manifest: %w", err)
			}
			if linkOrchestrion != "" {
				if err := appendMissingModulePackagefiles(importcfgName, goenv, orchestrionLinkClosurePackages, linkOrchestrion, "."); err != nil {
					return fmt.Errorf("link: append module packagefiles for synthetic test binary: %w", err)
				}
			}
			if goenv.stdlibCache != "" {
				if err := rewriteImportcfgFromCurrentStdlibEntries(importcfgName, goenv); err != nil {
					return fmt.Errorf("link: rewrite importcfg from current stdlib entries: %w", err)
				}
			}
		}
		goargs = append(goargs, "-importcfg", importcfgName)
		goargs = append(goargs, *main)
		if clearGoRoot {
			// Explicitly set GOROOT to a dummy value only after generating the
			// importcfg file so stdlib entries retain their real archive paths.
			oldroot := os.Getenv("GOROOT")
			os.Setenv("GOROOT", "GOROOT")
			defer os.Setenv("GOROOT", oldroot)
		}
		if err := goenv.runCommand(goargs); err != nil {
			return err
		}
	}

	if *buildmode == "c-archive" {
		if err := stripArMetadata(*outFile); err != nil {
			return fmt.Errorf("error stripping archive metadata: %w", err)
		}
	}

	return nil
}

var versionExp = regexp.MustCompile(`.*go1\.(\d+).*$`)

func onVersion(version int) (bool, error) {
	v := runtime.Version()
	m := versionExp.FindStringSubmatch(v)
	if len(m) != 2 {
		return false, fmt.Errorf("failed to match against Go version %q", v)
	}
	mvStr := m[1]
	mv, err := strconv.Atoi(mvStr)
	if err != nil {
		return false, fmt.Errorf("convert minor version %q to int: %w", mvStr, err)
	}

	return mv >= version, nil
}
