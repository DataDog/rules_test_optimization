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
	"io/ioutil"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
)

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

var orchestrionLinkClosurePackagesTestOptimization = []string{
	"github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting",
	"github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting/coverage",
	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer",
}

var orchestrionLinkStdlibRoots = []string{
	"flag",
	"log",
	"log/slog",
	"net/http",
	"os",
	"os/exec",
}

var orchestrionLinkStdlibRootsTestOptimization = []string{
	"flag",
	"log",
	"log/slog",
	"net/http",
	"os",
	"os/exec",
}

func orchestrionLinkClosurePackagesForMode(mode string) []string {
	if effectiveOrchestrionMode(mode) == orchestrionModeTestOptimization {
		return orchestrionLinkClosurePackagesTestOptimization
	}
	return orchestrionLinkClosurePackages
}

func orchestrionLinkStdlibRootsForMode(mode string) []string {
	if effectiveOrchestrionMode(mode) == orchestrionModeTestOptimization {
		return orchestrionLinkStdlibRootsTestOptimization
	}
	return orchestrionLinkStdlibRoots
}

func collectOrchestrionLinkClosurePackages(archives []archive, orchestrionMode string) []string {
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
	for _, pkg := range orchestrionLinkClosurePackagesForMode(orchestrionMode) {
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
	orchestrionSrcDirs := multiFlag{}
	archives := archiveMultiFlag{}
	flags := flag.NewFlagSet("link", flag.ExitOnError)
	goenv := envFlags(flags)
	main := flags.String("main", "", "Path to the main archive.")
	packagePath := flags.String("p", "", "Package path of the main archive.")
	outFile := flags.String("o", "", "Path to output file.")
	orchestrion := flags.String("orchestrion", "", "Path to orchestrion binary")
	orchestrionModeFlag := flags.String("orchestrion_mode", orchestrionModeGeneral, "Orchestrion integration mode")
	flags.Var(&orchestrionSrcDirs, "orchsrc", "source directory that may contain Orchestrion pin files")
	flags.Var(&archives, "arc", "Label, package path, and file name of a dependency, separated by '='")
	packageList := flags.String("package_list", "", "The file containing the list of standard library packages")
	buildmode := flags.String("buildmode", "", "Build mode used.")
	flags.Var(&xdefs, "X", "A string variable to replace in the linked binary (repeated).")
	flags.Var(&stamps, "stamp", "The name of a file with stamping values.")
	if err := flags.Parse(builderArgs); err != nil {
		return err
	}
	if err := goenv.checkFlagsAndSetGoroot(); err != nil {
		return err
	}
	orchestrionMode, err := validateOrchestrionMode(*orchestrionModeFlag)
	if err != nil {
		return err
	}
	goenv.orchestrionMode = orchestrionMode
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
		stampbuf, err := ioutil.ReadFile(stampfile)
		if err != nil {
			return fmt.Errorf("Failed reading stamp file %s: %v", stampfile, err)
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

	parseXdef := func(xdef string) (pkg, name, value string, err error) {
		eq := strings.IndexByte(xdef, '=')
		if eq < 0 {
			return "", "", "", fmt.Errorf("-X flag does not contain '=': %s", xdef)
		}
		dot := strings.LastIndexByte(xdef[:eq], '.')
		if dot < 0 {
			return "", "", "", fmt.Errorf("-X flag does not contain '.': %s", xdef)
		}
		pkg, name, value = xdef[:dot], xdef[dot+1:eq], xdef[eq+1:]
		if pkg == *packagePath {
			pkg = "main"
		}
		return pkg, name, value, nil
	}
	for _, xdef := range xdefs {
		pkg, name, value, err := parseXdef(xdef)
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
		for _, dir := range orchestrionSrcDirs {
			addSrcDir(dir)
		}
		workDirSpan := beginProbe("link.enter_orchestrion_workdir")
		restoreOrchWorkDir, err := enterOrchestrionWorkDir(srcDirs, goenv.verbose, orchestrionMode)
		workDirSpan.End(err)
		if err != nil {
			return fmt.Errorf("link: %w", err)
		}
		defer restoreOrchWorkDir()
		if linkOrchestrion != "" {
			goModSpan := beginProbe("link.ensure_go_mod_exists")
			cleanupGoMod, err := ensureGoModExists(srcDirs, goenv.sdk, goenv.verbose, orchestrionMode)
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
		importcfgName, err := buildImportcfgFileForLink(archives, *packageList, goenv.installSuffix, filepath.Dir(*outFile))
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
				err := appendMissingModulePackagefiles(importcfgName, goenv, orchestrionLinkClosurePackagesForMode(orchestrionMode), linkOrchestrion, ".")
				modulePkgSpan.End(err)
				if err != nil {
					return fmt.Errorf("link: append module packagefiles for synthetic test binary: %w", err)
				}
			}
		}
		if goenv.stdlibCache != "" {
			rewriteSpan := beginProbe("link.rewrite_importcfg_from_current_stdlib_entries")
			err := rewriteImportcfgForSyntheticTestmainStdlib(importcfgName, goenv)
			rewriteSpan.End(err)
			if err != nil {
				return fmt.Errorf("link: rewrite importcfg from current stdlib entries: %w", err)
			}
		} else {
			closurePackages := collectOrchestrionLinkClosurePackages(archives, orchestrionMode)
			rewriteSpan := beginProbe(
				"link.rewrite_importcfg_for_cache_stdlib_closures",
				newProbeField("orchestrion_mode", orchestrionMode),
				newProbeField("closure_count", strconv.Itoa(len(closurePackages))),
			)
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
			jobserver, err = startOrchestrionJobserver(linkOrchestrion, sdkPath, goRootPath, goenv.verbose, orchestrionMode)
			jobserverSpan.End(err)
			if err != nil {
				return fmt.Errorf("link: failed to start orchestrion jobserver: %w", err)
			}
			defer jobserver.cleanup()
		}
		runSpan := beginProbe(
			"link.run_command",
			newProbeField("import_path", orchImportPath),
			newProbeField("orchestrion_mode", orchestrionMode),
		)
		if err := goenv.runCommandWithJobserver(goargs, jobserver, orchImportPath, linkOrchestrion != ""); err != nil {
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
			for _, dir := range orchestrionSrcDirs {
				addSrcDir(dir)
			}
			restoreOrchWorkDir, err = enterOrchestrionWorkDir(srcDirs, goenv.verbose, orchestrionMode)
			if err != nil {
				return fmt.Errorf("link: %w", err)
			}
			defer restoreOrchWorkDir()
			if linkOrchestrion != "" {
				cleanupGoMod, err = ensureGoModExists(srcDirs, goenv.sdk, goenv.verbose, orchestrionMode)
				if err != nil {
					return fmt.Errorf("link: %w", err)
				}
				defer cleanupGoMod()
			}
		}
		importcfgName, err := buildImportcfgFileForLink(archives, *packageList, goenv.installSuffix, filepath.Dir(*outFile))
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
				if err := appendMissingModulePackagefiles(importcfgName, goenv, orchestrionLinkClosurePackagesForMode(orchestrionMode), linkOrchestrion, "."); err != nil {
					return fmt.Errorf("link: append module packagefiles for synthetic test binary: %w", err)
				}
			}
			if goenv.stdlibCache != "" {
				if err := rewriteImportcfgForSyntheticTestmainStdlib(importcfgName, goenv); err != nil {
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
			return fmt.Errorf("error stripping archive metadata: %v", err)
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
