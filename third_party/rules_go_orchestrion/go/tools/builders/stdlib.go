// Copyright 2018 The Bazel Authors. All rights reserved.
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

package main

import (
	"flag"
	"fmt"
	"go/build"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const syntheticOrchestrionToolGo = `package tools

import (
	_ "github.com/DataDog/orchestrion"
	_ "github.com/DataDog/dd-trace-go/v2/orchestrion"
)
`

const syntheticStdlibModulePath = "module github.com/DataDog/dd-trace-go/v2/bazel_orchestrion_stdlib"

// stdlib builds the standard library in the appropriate mode into a new goroot.
func stdlib(args []string) error {
	// process the args
	flags := flag.NewFlagSet("stdlib", flag.ExitOnError)
	goenv := envFlags(flags)
	out := flags.String("out", "", "Path to output go root")
	orchestrion := flags.String("orchestrion", "", "Path to orchestrion binary for toolexec instrumentation")
	var orchestrionSrcDirs multiFlag
	flags.Var(&orchestrionSrcDirs, "orchsrc", "source directories that may contain orchestrion pin files")
	race := flags.Bool("race", false, "Build in race mode")
	msan := flags.Bool("msan", false, "Build in msan mode")
	shared := flags.Bool("shared", false, "Build in shared mode")
	dynlink := flags.Bool("dynlink", false, "Build in dynlink mode")
	pgoprofile := flags.String("pgoprofile", "", "Build with pgo using the given pprof file")
	var packages multiFlag
	flags.Var(&packages, "package", "Packages to build")
	var gcflags quoteMultiFlag
	flags.Var(&gcflags, "gcflags", "Go compiler flags")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if err := goenv.checkFlagsAndSetGoroot(); err != nil {
		return err
	}
	if *orchestrion != "" {
		*orchestrion = abs(*orchestrion)
		goenv.verbose = true
	}
	goroot := os.Getenv("GOROOT")
	if goroot == "" {
		return fmt.Errorf("GOROOT not set")
	}
	output := abs(*out)

	// Fail fast if cgo is required but a toolchain is not configured.
	if os.Getenv("CGO_ENABLED") == "1" && filepath.Base(os.Getenv("CC")) == "vc_installation_error.bat" {
		return fmt.Errorf(`cgo is required, but a C toolchain has not been configured.
You may need to use the flags --cpu=x64_windows --compiler=mingw-gcc.`)
	}

	// Link in the bare minimum needed to the new GOROOT
	if err := replicate(goroot, output, replicatePaths("src", "pkg/tool", "pkg/include")); err != nil {
		return err
	}

	output, err := processPath(output)
	if err != nil {
		return err
	}

	// Now switch to the newly created GOROOT
	os.Setenv("GOROOT", output)
	goenv.goroot = output

	// Create a temporary cache directory. "go build" requires this starting
	// in Go 1.12.
	cachePath := filepath.Join(output, ".gocache")
	os.Setenv("GOCACHE", cachePath)
	defer os.RemoveAll(cachePath)

	// Disable modules for the plain stdlib build command. When Orchestrion is
	// enabled we flip this back on later after preparing a synthetic module that
	// can resolve the dd-trace-go integrations used for stdlib weaving.
	os.Setenv("GO111MODULE", "off")

	// Make sure we have an absolute path to the C compiler.
	os.Setenv("CC", quotePathIfNeeded(abs(os.Getenv("CC"))))

	// Ensure paths are absolute.
	absPaths := []string{}
	for _, path := range filepath.SplitList(os.Getenv("PATH")) {
		absPaths = append(absPaths, abs(path))
	}
	if goenv.sdk != "" {
		sdkBin := abs(filepath.Join(goenv.sdk, "bin"))
		foundSDKBin := false
		for _, p := range absPaths {
			if p == sdkBin {
				foundSDKBin = true
				break
			}
		}
		if !foundSDKBin {
			absPaths = append([]string{sdkBin}, absPaths...)
		}
	}
	os.Setenv("PATH", strings.Join(absPaths, string(os.PathListSeparator)))

	sandboxPath := abs(".")

	// Strip path prefix from source files in debug information.
	os.Setenv("CGO_CFLAGS", os.Getenv("CGO_CFLAGS")+" "+strings.Join(defaultCFlags(output), " "))
	os.Setenv("CGO_LDFLAGS", os.Getenv("CGO_LDFLAGS")+" "+strings.Join(defaultLdFlags(), " "))

	// Allow flags in CGO_LDFLAGS that wouldn't pass the security check.
	// Workaround for golang.org/issue/42565.
	var b strings.Builder
	sep := ""
	cgoLdflags, _ := splitQuoted(os.Getenv("CGO_LDFLAGS"))
	for _, f := range cgoLdflags {
		b.WriteString(sep)
		sep = "|"
		b.WriteString(regexp.QuoteMeta(f))
		// If the flag if -framework, the flag value needs to be in the same
		// condition.
		if f == "-framework" {
			sep = " "
		}
	}
	os.Setenv("CGO_LDFLAGS_ALLOW", b.String())
	os.Setenv("GODEBUG", "installgoroot=all")

	// Build the commands needed to build the std library in the right mode
	// NOTE: the go command stamps compiled .a files with build ids, which are
	// cryptographic sums derived from the inputs. This prevents us from
	// creating reproducible builds because the build ids are hashed from
	// CGO_CFLAGS, which frequently contains absolute paths. As a workaround,
	// we strip the build ids, since they won't be used after this.
	toolexec := quotePathIfNeeded(abs(os.Args[0])) + " filterbuildid"
	if *orchestrion != "" {
		if len(orchestrionSrcDirs) == 0 {
			discovered, err := discoverOrchestrionSourceDirs(".")
			if err != nil && goenv.verbose {
				fmt.Fprintf(os.Stderr, "stdlib: failed to discover orchestrion source dirs: %v\n", err)
			}
			if len(discovered) > 0 {
				orchestrionSrcDirs = multiFlag(discovered)
				if goenv.verbose || os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
					fmt.Fprintf(os.Stderr, "stdlib: discovered orchestrion source dirs=%v\n", discovered)
				}
			}
		}
		restoreOrchWorkDir, err := enterOrchestrionWorkDir(orchestrionSrcDirs, goenv.verbose)
		if err != nil {
			return fmt.Errorf("stdlib: %w", err)
		}
		defer restoreOrchWorkDir()
		cleanupGoMod, err := ensureGoModExists(orchestrionSrcDirs, goenv.verbose)
		if err != nil {
			return fmt.Errorf("stdlib: %w", err)
		}
		defer cleanupGoMod()
		cleanupGoModModulePath, err := ensureImportableStdlibModulePath(goenv.verbose)
		if err != nil {
			return fmt.Errorf("stdlib: %w", err)
		}
		defer cleanupGoModModulePath()
		cleanupSyntheticToolGo, err := ensureSyntheticOrchestrionToolGo(goenv.verbose)
		if err != nil {
			return fmt.Errorf("stdlib: %w", err)
		}
		defer cleanupSyntheticToolGo()
		if cwd, err := os.Getwd(); err == nil {
			goModPath := filepath.Join(cwd, "go.mod")
			_ = os.Setenv("GOMOD", goModPath)
			if goenv.verbose || os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
				fmt.Fprintf(os.Stderr, "stdlib: exporting GOMOD=%s\n", goModPath)
			}
		}
		prevGo111Module, hadGo111Module := os.LookupEnv("GO111MODULE")
		_ = os.Setenv("GO111MODULE", "on")
		defer func() {
			if hadGo111Module {
				_ = os.Setenv("GO111MODULE", prevGo111Module)
			} else {
				_ = os.Unsetenv("GO111MODULE")
			}
		}()
		if len(orchestrionSrcDirs) == 0 {
			envWithCache, err := ensureGoModuleCacheEnv(os.Environ(), goenv.verbose)
			if err != nil {
				return fmt.Errorf("stdlib: ensure go module cache env: %w", err)
			}
			for _, entry := range envWithCache {
				parts := strings.SplitN(entry, "=", 2)
				if len(parts) == 2 {
					_ = os.Setenv(parts[0], parts[1])
				}
			}
			syntheticDownloads := [][]string{
				{"mod", "download", "github.com/DataDog/orchestrion"},
				{"mod", "download", "github.com/DataDog/dd-trace-go/v2"},
			}
			for _, dl := range syntheticDownloads {
				if err := goenv.runCommand(goenv.goCmd(dl[0], dl[1:]...)); err != nil && goenv.verbose {
					fmt.Fprintf(os.Stderr, "stdlib: synthetic orchestrion download failed %q: %v\n", strings.Join(dl, " "), err)
				}
			}
			tidyArgs := []string{"mod", "tidy"}
			if err := goenv.runCommand(goenv.goCmd(tidyArgs[0], tidyArgs[1:]...)); err != nil {
				return fmt.Errorf("stdlib: synthetic orchestrion tidy failed: %w", err)
			}
			if goenv.verbose || os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
				fmt.Fprintf(os.Stderr, "stdlib: synthetic orchestrion tidy completed using dd-trace-go/v2/orchestrion tools-tagged integration imports\n")
			}
			if goenv.verbose || os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
				fmt.Fprintf(os.Stderr, "stdlib: skipping synthetic orchestrion pin; using synthesized module/tool files instead\n")
			}
		}
		if goenv.verbose || os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
			diagnosticArgs := [][]string{
				{"list", "-mod=mod", "-tags=tools", "-f", "{{.ImportPath}} GoFiles={{.GoFiles}} IgnoredGoFiles={{.IgnoredGoFiles}}", "github.com/DataDog/dd-trace-go/v2/orchestrion"},
			}
			for _, diag := range diagnosticArgs {
				if err := goenv.runCommand(goenv.goCmd(diag[0], diag[1:]...)); err != nil && goenv.verbose {
					fmt.Fprintf(os.Stderr, "stdlib: diagnostic command failed %q: %v\n", strings.Join(diag, " "), err)
				}
			}
		}
		goFlags := strings.TrimSpace(os.Getenv("GOFLAGS"))
		if !strings.Contains(goFlags, "-tags=tools") && !strings.Contains(goFlags, "-tags tools") {
			if goFlags == "" {
				goFlags = "-tags=tools"
			} else {
				goFlags += " -tags=tools"
			}
			_ = os.Setenv("GOFLAGS", goFlags)
			if goenv.verbose || os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
				fmt.Fprintf(os.Stderr, "stdlib: forcing GOFLAGS=%s\n", goFlags)
			}
		}
		if goenv.verbose || os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
			cwd, _ := os.Getwd()
			fmt.Fprintf(os.Stderr, "stdlib: orchestrion enabled cwd=%s sdk=%s goroot=%s orchsrc=%v\n", cwd, goenv.sdk, output, []string(orchestrionSrcDirs))
		}
		stdlibWorkDir := ""
		if cwd, err := os.Getwd(); err == nil {
			stdlibWorkDir = cwd
			_ = os.Setenv("RULES_GO_ORCHESTRION_WORKDIR", cwd)
			if goenv.verbose || os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
				fmt.Fprintf(os.Stderr, "stdlib: exporting RULES_GO_ORCHESTRION_WORKDIR=%s\n", cwd)
			}
		}
		toolexec = quotePathIfNeeded(abs(os.Args[0])) + " orchestrionfilterbuildid " + quotePathIfNeeded(*orchestrion)
		if stdlibWorkDir != "" {
			toolexec += " " + quotePathIfNeeded("--workdir="+stdlibWorkDir)
		}
	}
	installArgs := goenv.goCmd("install", "-toolexec", toolexec)
	if len(build.Default.BuildTags) > 0 {
		installArgs = append(installArgs, "-tags", strings.Join(build.Default.BuildTags, ","))
	}

	ldflags := []string{"-trimpath", sandboxPath}
	asmflags := []string{"-trimpath", output}
	if *race {
		installArgs = append(installArgs, "-race")
	}
	if *msan {
		installArgs = append(installArgs, "-msan")
	}
	if *pgoprofile != "" {
		gcflags = append(gcflags, "-pgoprofile="+abs(*pgoprofile))
	}
	if *shared {
		gcflags = append(gcflags, "-shared")
		ldflags = append(ldflags, "-shared")
		asmflags = append(asmflags, "-shared")
	}
	if *dynlink {
		gcflags = append(gcflags, "-dynlink")
		ldflags = append(ldflags, "-dynlink")
		asmflags = append(asmflags, "-dynlink")
	}

	// Since Go 1.10, an all= prefix indicates the flags should apply to the package
	// and its dependencies, rather than just the package itself. This was the
	// default behavior before Go 1.10.
	allSlug := ""
	for _, t := range build.Default.ReleaseTags {
		if t == "go1.10" {
			allSlug = "all="
			break
		}
	}
	installArgs = append(installArgs, "-gcflags="+allSlug+strings.Join(gcflags, " "))
	installArgs = append(installArgs, "-ldflags="+allSlug+strings.Join(ldflags, " "))
	installArgs = append(installArgs, "-asmflags="+allSlug+strings.Join(asmflags, " "))

	if err := absCCCompiler(cgoEnvVars, cgoAbsEnvFlags); err != nil {
		return fmt.Errorf("error modifying cgo environment to absolute path: %v", err)
	}

	installArgs = append(installArgs, packages...)
	if *orchestrion != "" {
		sdkPath := abs(goenv.sdk)
		jobserver, err := startOrchestrionJobserver(*orchestrion, sdkPath, output, goenv.verbose)
		if err != nil {
			return fmt.Errorf("stdlib: failed to start orchestrion jobserver: %w", err)
		}
		defer jobserver.cleanup()
		if err := goenv.runCommandWithJobserver(installArgs, jobserver, ""); err != nil {
			return err
		}
		return nil
	}
	if err := goenv.runCommand(installArgs); err != nil {
		return err
	}
	return nil
}

func ensureSyntheticOrchestrionToolGo(verbose bool) (func(), error) {
	const toolFile = "orchestrion.tool.go"
	if _, err := os.Stat(toolFile); err == nil {
		if verbose {
			if data, readErr := os.ReadFile(toolFile); readErr == nil {
				fmt.Fprintf(os.Stderr, "stdlib: existing synthetic %s contents begin\n%s\nstdlib: existing synthetic %s contents end\n", toolFile, string(data), toolFile)
			}
		}
		return func() {}, nil
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("stat %s: %w", toolFile, err)
	}
	if err := os.WriteFile(toolFile, []byte(syntheticOrchestrionToolGo), 0o644); err != nil {
		return nil, fmt.Errorf("write %s: %w", toolFile, err)
	}
	if verbose {
		fmt.Fprintf(os.Stderr, "stdlib: created synthetic %s\n", toolFile)
		fmt.Fprintf(os.Stderr, "stdlib: synthetic %s contents begin\n%s\nstdlib: synthetic %s contents end\n", toolFile, syntheticOrchestrionToolGo, toolFile)
	}
	return func() {
		_ = os.Remove(toolFile)
	}, nil
}

func ensureImportableStdlibModulePath(verbose bool) (func(), error) {
	const goModFile = "go.mod"

	data, err := os.ReadFile(goModFile)
	if err != nil {
		if os.IsNotExist(err) {
			return func() {}, nil
		}
		return nil, fmt.Errorf("read %s: %w", goModFile, err)
	}

	contents := string(data)
	if !strings.HasPrefix(contents, "module std\n") {
		return func() {}, nil
	}

	rewritten := strings.Replace(contents, "module std\n", syntheticStdlibModulePath+"\n", 1)
	if err := os.WriteFile(goModFile, []byte(rewritten), 0o644); err != nil {
		return nil, fmt.Errorf("rewrite %s module path: %w", goModFile, err)
	}
	if verbose {
		fmt.Fprintf(os.Stderr, "stdlib: rewrote %s module path to %s\n", goModFile, syntheticStdlibModulePath)
	}

	return func() {
		_ = os.WriteFile(goModFile, data, 0o644)
	}, nil
}

func discoverOrchestrionSourceDirs(root string) ([]string, error) {
	var dirs []string
	seen := map[string]bool{}
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			base := filepath.Base(path)
			if base == "bazel-out" || base == "external" || strings.HasPrefix(base, ".") && path != "." {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Name() != "orchestrion.tool.go" {
			return nil
		}
		dir := filepath.Dir(path)
		if seen[dir] {
			return nil
		}
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err != nil {
			return nil
		}
		absDir, err := filepath.Abs(dir)
		if err != nil {
			return nil
		}
		seen[absDir] = true
		dirs = append(dirs, absDir)
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(dirs)
	return dirs, nil
}
