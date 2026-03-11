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

var linkDebugPatterns = []string{
	"github.com/DataDog/dd-trace-go/v2",
}

func link(args []string) error {
	// Parse arguments.
	args, _, err := expandParamsFiles(args)
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

	// Build an importcfg file.
	importcfgName, err := buildImportcfgFileForLink(archives, *packageList, goenv.installSuffix, filepath.Dir(*outFile))
	if err != nil {
		return err
	}
	if !goenv.shouldPreserveWorkDir {
		defer os.Remove(importcfgName)
	}
	debugImportcfgState("before-link", importcfgName)

	orchImportPath := *packagePath
	sdkPath := abs(goenv.sdk)
	if *orchestrion != "" {
		*orchestrion = abs(*orchestrion)
		goenv.sdk = sdkPath
	}

	// generate any additional link options we need
	goargs := goenv.goToolWithOrchestion(*orchestrion, "link")
	goargs = append(goargs, "-importcfg", importcfgName)

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
	// add in the unprocess pass through options
	goargs = append(goargs, toolArgs...)
	goargs = append(goargs, *main)

	clearGoRoot, err := onVersion(23)
	if err != nil {
		return err
	}
	if clearGoRoot {
		// Explicitly set GOROOT to a dummy value when running linker.
		// This ensures that the GOROOT written into the binary
		// is constant and thus builds are reproducible.
		oldroot := os.Getenv("GOROOT")
		os.Setenv("GOROOT", "GOROOT")
		defer os.Setenv("GOROOT", oldroot)
	}

	if *orchestrion != "" {
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
		restoreOrchWorkDir, err := enterOrchestrionWorkDir(srcDirs, goenv.verbose)
		if err != nil {
			return fmt.Errorf("link: %w", err)
		}
		defer restoreOrchWorkDir()
		cleanupGoMod, err := ensureGoModExists(srcDirs, goenv.verbose)
		if err != nil {
			return fmt.Errorf("link: %w", err)
		}
		defer cleanupGoMod()
		if orchImportPath == "main" || orchImportPath == "testmain" {
			orchImportPath = ""
		}
		orchImportPath = resolveOrchestrionImportPath(orchImportPath, goenv.verbose)
		if goenv.verbose || os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
			cwd, _ := os.Getwd()
			fmt.Fprintf(os.Stderr, "link: orchestrion cwd=%s packagePath=%s resolved_importpath=%s main=%s out=%s\n", cwd, *packagePath, orchImportPath, *main, *outFile)
		}
		goRootPath := goenv.goroot
		if goRootPath == "" {
			goRootPath = os.Getenv("GOROOT")
		}
		jobserver, err := startOrchestrionJobserver(*orchestrion, sdkPath, goRootPath, goenv.verbose)
		if err != nil {
			return fmt.Errorf("link: failed to start orchestrion jobserver: %w", err)
		}
		defer jobserver.cleanup()
		if err := goenv.runCommandWithJobserver(goargs, jobserver, orchImportPath); err != nil {
			debugImportcfgState("after-link-error", importcfgName)
			return err
		}
		debugImportcfgState("after-link-success", importcfgName)
	} else if err := goenv.runCommand(goargs); err != nil {
		debugImportcfgState("after-link-error", importcfgName)
		return err
	}
	debugImportcfgState("after-link-success", importcfgName)

	if *buildmode == "c-archive" {
		if err := stripArMetadata(*outFile); err != nil {
			return fmt.Errorf("error stripping archive metadata: %v", err)
		}
	}

	return nil
}

func debugImportcfgState(stage, path string) {
	if os.Getenv("ORCHESTRION_DEBUG_TRACE") == "" {
		return
	}

	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "orchestrion link debug: %s importcfg=%s read error: %v\n", stage, path, err)
		return
	}

	lines := strings.Split(string(data), "\n")
	packagefileCount := 0
	interesting := make([]string, 0, len(lines))
	malformed := make([]string, 0, 8)
	for _, line := range lines {
		if strings.HasPrefix(line, "packagefile ") {
			packagefileCount++
			rest := strings.TrimPrefix(line, "packagefile ")
			parts := strings.SplitN(rest, "=", 2)
			if len(parts) != 2 || strings.TrimSpace(parts[1]) == "" {
				malformed = append(malformed, line)
			}
		}
		for _, pattern := range linkDebugPatterns {
			if strings.Contains(line, pattern) {
				interesting = append(interesting, line)
				break
			}
		}
	}

	fmt.Fprintf(os.Stderr, "orchestrion link debug: %s importcfg=%s bytes=%d packagefiles=%d interesting=%d malformed=%d\n",
		stage, path, len(data), packagefileCount, len(interesting), len(malformed))
	for _, line := range interesting {
		fmt.Fprintf(os.Stderr, "orchestrion link debug: %s %s\n", stage, line)
	}
	for _, line := range malformed {
		fmt.Fprintf(os.Stderr, "orchestrion link debug: %s malformed %s\n", stage, line)
	}
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
