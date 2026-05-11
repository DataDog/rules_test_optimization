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
	"strconv"
	"strings"
)

const syntheticStdlibModulePath = "module github.com/DataDog/dd-trace-go/v2/bazel_orchestrion_stdlib"
const orchestrionStdlibCacheManifestName = ".orchestrion_stdlib_cache_manifest"

// stdlib builds the standard library in the appropriate mode into a new goroot.
func stdlib(args []string) (err error) {
	span := beginProbe("stdlib.action")
	defer func() {
		span.End(err)
	}()
	// process the args
	flags := flag.NewFlagSet("stdlib", flag.ExitOnError)
	goenv := envFlags(flags)
	out := flags.String("out", "", "Path to output go root")
	cacheOut := flags.String("cacheout", "", "Path to output Go build cache directory")
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
	replicateSpan := beginProbe("stdlib.replicate_goroot")
	if err := replicate(goroot, output, replicatePaths("src", "pkg/tool", "pkg/include")); err != nil {
		replicateSpan.End(err)
		return err
	}
	replicateSpan.End(nil)

	output, err = processPath(output)
	if err != nil {
		return err
	}

	// Now switch to the newly created GOROOT
	os.Setenv("GOROOT", output)
	goenv.goroot = output

	// Create a temporary cache directory. "go build" requires this starting
	// in Go 1.12.
	cachePath := filepath.Join(output, ".gocache")
	if *cacheOut != "" {
		cachePath = abs(*cacheOut)
		goenv.stdlibCache = cachePath
	}
	os.Setenv("GOCACHE", cachePath)
	if err := os.MkdirAll(cachePath, 0o755); err != nil {
		return fmt.Errorf("prepare stdlib gocache at %s: %w", cachePath, err)
	}
	if shouldRemoveStdlibCache(*orchestrion, *cacheOut) {
		defer os.RemoveAll(cachePath)
	}

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
				if goenv.verbose {
					fmt.Fprintf(os.Stderr, "stdlib: discovered orchestrion source dirs=%v\n", discovered)
				}
			}
		}
		workDirSpan := beginProbe("stdlib.enter_orchestrion_workdir")
		restoreOrchWorkDir, err := enterOrchestrionWorkDir(orchestrionSrcDirs, goenv.verbose)
		workDirSpan.End(err)
		if err != nil {
			return fmt.Errorf("stdlib: %w", err)
		}
		defer restoreOrchWorkDir()
		goModSpan := beginProbe("stdlib.ensure_go_mod_exists")
		cleanupGoMod, err := ensureGoModExists(orchestrionSrcDirs, goenv.sdk, goenv.verbose)
		goModSpan.End(err)
		if err != nil {
			return fmt.Errorf("stdlib: %w", err)
		}
		defer cleanupGoMod()
		modulePathSpan := beginProbe("stdlib.ensure_importable_stdlib_module_path")
		cleanupGoModModulePath, err := ensureImportableStdlibModulePath(goenv.verbose)
		modulePathSpan.End(err)
		if err != nil {
			return fmt.Errorf("stdlib: %w", err)
		}
		defer cleanupGoModModulePath()
		toolGoSpan := beginProbe("stdlib.ensure_synthetic_orchestrion_tool_go")
		cleanupSyntheticToolGo, err := ensureSyntheticOrchestrionToolGo(goenv.verbose)
		toolGoSpan.End(err)
		if err != nil {
			return fmt.Errorf("stdlib: %w", err)
		}
		defer cleanupSyntheticToolGo()
		if cwd, err := os.Getwd(); err == nil {
			goModPath := filepath.Join(cwd, "go.mod")
			_ = os.Setenv("GOMOD", goModPath)
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
				{"mod", "download", "github.com/DataDog/dd-trace-go/contrib/net/http/v2"},
				{"mod", "download", "github.com/DataDog/dd-trace-go/contrib/log/slog/v2"},
			}
			for _, dl := range syntheticDownloads {
				downloadSpan := beginProbe("stdlib.synthetic_download", newProbeField("command", strings.Join(dl, " ")))
				if err := goenv.runCommand(goenv.goCmd(dl[0], dl[1:]...)); err != nil && goenv.verbose {
					downloadSpan.End(err)
					fmt.Fprintf(os.Stderr, "stdlib: synthetic orchestrion download failed %q: %v\n", strings.Join(dl, " "), err)
				} else {
					downloadSpan.End(nil)
				}
			}
			// Do not run `go mod tidy` for the stdlib synthetic action-time module.
			// Like the other synthetic Orchestrion module flows, stdlib only needs
			// the runtime build graph staged in the offline proxy. `tidy` expands
			// into unrelated helper/test dependencies that are outside that
			// contract and has proven to fail on Windows consumer builds even when
			// the actual stdlib weaving path is otherwise valid.
			if goenv.verbose {
				fmt.Fprintf(os.Stderr, "stdlib: skipping synthetic orchestrion tidy; using synthesized module/tool files and offline proxy downloads instead\n")
			}
			if goenv.verbose {
				fmt.Fprintf(os.Stderr, "stdlib: skipping synthetic orchestrion pin; using synthesized module/tool files instead\n")
			}
		}
		stdlibWorkDir := ""
		if cwd, err := os.Getwd(); err == nil {
			stdlibWorkDir = cwd
			_ = os.Setenv("RULES_GO_ORCHESTRION_WORKDIR", cwd)
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
		jobserverSpan := beginProbe("stdlib.start_jobserver")
		jobserver, err := startOrchestrionJobserver(*orchestrion, sdkPath, output, goenv.verbose)
		jobserverSpan.End(err)
		if err != nil {
			return fmt.Errorf("stdlib: failed to start orchestrion jobserver: %w", err)
		}
		defer jobserver.cleanup()
		runSpan := beginProbe("stdlib.run_install")
		if err := goenv.runCommandWithJobserver(installArgs, jobserver, ""); err != nil {
			runSpan.End(err)
			return err
		}
		runSpan.End(nil)
		persistSpan := beginProbe("stdlib.persist_orchestrion_stdlib_exports")
		if err := persistOrchestrionStdlibExports(goenv, append([]string{"testing", "testing/internal/testdeps"}, orchestrionLinkStdlibRoots...), goenv.verbose); err != nil {
			persistSpan.End(err)
			return fmt.Errorf("stdlib: persist orchestrion stdlib exports: %w", err)
		}
		persistSpan.End(nil)
		// Keep this path tied to the archives produced by the current stdlib
		// install. A previous host-side stdlib snapshot reuse experiment made the
		// build look correct while silently breaking runtime weaving: tests still
		// passed, but CI Visibility never started and no payload files were
		// emitted. Any future stdlib reuse optimization must be validated with a
		// real consumer run that checks tracer startup logs and payload-file
		// output, not just build success.
		return nil
	}
	if err := goenv.runCommand(installArgs); err != nil {
		return err
	}
	return nil
}

// shouldRemoveStdlibCache reports whether the builder owns the cache directory
// as scratch space. A non-empty -cacheout value is a Bazel-declared TreeArtifact
// output, so it must remain present even for plain non-Orchestrion stdlib
// actions.
func shouldRemoveStdlibCache(orchestrionPath, cacheOut string) bool {
	return strings.TrimSpace(orchestrionPath) == "" && strings.TrimSpace(cacheOut) == ""
}

func persistOrchestrionStdlibExports(goenv *env, packages []string, verbose bool) (err error) {
	span := beginProbe("stdlib.persist_exports", newProbeField("package_count", strconv.Itoa(len(packages))))
	defer func() {
		span.End(err)
	}()
	root := orchestrionStdlibExportRoot(goenv)
	if root == "" {
		return nil
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	pkgRoot := filepath.Join(abs(goenv.goroot), "pkg", goenv.installSuffix)
	exports := make(map[string]string)
	if err := filepath.Walk(pkgRoot, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			if filepath.Clean(path) == filepath.Clean(root) {
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Ext(path) != ".a" {
			return nil
		}
		rel, err := filepath.Rel(pkgRoot, path)
		if err != nil {
			return err
		}
		pkg := filepath.ToSlash(strings.TrimSuffix(rel, ".a"))
		exports[pkg] = path
		return nil
	}); err != nil {
		return err
	}
	if len(exports) == 0 {
		if verbose {
			fmt.Fprintf(os.Stderr, "stdlib: no stdlib archives found under %s for persistence\n", pkgRoot)
		}
		return nil
	}
	keys := make([]string, 0, len(exports))
	for pkg := range exports {
		keys = append(keys, pkg)
	}
	sort.Strings(keys)
	persistedExports := make(map[string]string, len(exports))
	var manifest strings.Builder
	for _, pkg := range keys {
		src := exports[pkg]
		relDst := filepath.FromSlash(pkg) + ".a"
		dst := filepath.Join(root, relDst)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		if err := copyArchiveFile(src, dst); err != nil {
			return fmt.Errorf("copy %s -> %s: %w", src, dst, err)
		}
		persistedExports[pkg] = dst
		manifest.WriteString(pkg)
		manifest.WriteString("=")
		manifest.WriteString(relDst)
		manifest.WriteString("\n")
		if verbose {
			fmt.Fprintf(os.Stderr, "stdlib: persisted orchestrion export %s -> %s (manifest=%s)\n", pkg, dst, relDst)
		}
	}
	manifestPath := orchestrionStdlibExportManifestPath(goenv)
	if manifestPath == "" {
		return nil
	}
	if err := os.WriteFile(manifestPath, []byte(manifest.String()), 0o644); err != nil {
		return err
	}
	if verbose {
		fmt.Fprintf(os.Stderr, "stdlib: wrote orchestrion export manifest %s\n", manifestPath)
	}
	// pkgRoot is already the source of truth for the woven stdlib archives we
	// just copied into the persistent export root. Sync only the cache-local
	// closure that later compile/link paths actually request from the stdlib
	// cache, rather than rewriting every persisted archive back into cache paths.
	if err := syncPersistedOrchestrionExportsToCache(goenv, persistedExports, packages, verbose); err != nil {
		return fmt.Errorf("sync persisted stdlib archives into cache exports: %w", err)
	}
	return nil
}

func syncPersistedOrchestrionExportsToCache(goenv *env, exports map[string]string, roots []string, verbose bool) (err error) {
	span := beginProbe("stdlib.sync_persisted_exports_to_cache", newProbeField("export_count", strconv.Itoa(len(exports))))
	defer func() {
		span.End(err)
	}()
	if goenv == nil || len(exports) == 0 {
		return nil
	}

	// We have two cache families to keep consistent:
	// 1. the Bazel-declared stdlib cache consumed by later compile/link actions
	// 2. the shared Datadog/Orchestrion cache used by internal `go list -export`
	//    dependency resolution when woven deps are injected.
	//
	// If only one is populated, compile and link can observe different archive
	// fingerprints for stdlib packages like log/fmt/flag. Populate both from the
	// same woven persisted exports.
	candidateCaches := []string{}
	seenCaches := map[string]struct{}{}
	addCache := func(path string) {
		path = strings.TrimSpace(path)
		if path == "" {
			return
		}
		path = abs(path)
		if _, ok := seenCaches[path]; ok {
			return
		}
		seenCaches[path] = struct{}{}
		candidateCaches = append(candidateCaches, path)
	}

	addCache(goenv.stdlibCache)
	if envCache := strings.TrimSpace(os.Getenv("GOCACHE")); envCache != "" {
		addCache(envCache)
	}
	if len(candidateCaches) == 0 {
		addCache(filepath.Join(abs(goenv.goroot), ".gocache"))
	}

	prevCachePath, hadPrevCachePath := os.LookupEnv("GOCACHE")
	defer func() {
		if hadPrevCachePath {
			_ = os.Setenv("GOCACHE", prevCachePath)
		} else {
			_ = os.Unsetenv("GOCACHE")
		}
	}()

	for _, cachePath := range candidateCaches {
		if err := os.MkdirAll(cachePath, 0o755); err != nil {
			return fmt.Errorf("prepare stdlib cache exports at %s: %w", cachePath, err)
		}
		if err := os.Setenv("GOCACHE", cachePath); err != nil {
			return fmt.Errorf("set stdlib cache exports path %s: %w", cachePath, err)
		}
		if verbose {
			fmt.Fprintf(os.Stderr, "stdlib: resolving cache-family exports against GOCACHE=%s\n", cachePath)
		}

		cacheExports, err := resolveCacheStdlibExportsAt(goenv, roots, cachePath)
		if err != nil {
			return err
		}
		packages := make([]string, 0, len(cacheExports))
		for pkg := range cacheExports {
			packages = append(packages, pkg)
		}
		sort.Strings(packages)
		var manifest strings.Builder
		for _, pkg := range packages {
			src := exports[pkg]
			dst, ok := cacheExports[pkg]
			if !ok || dst == "" {
				continue
			}
			if strings.TrimSpace(src) == "" {
				return fmt.Errorf("missing persisted stdlib archive for cache package %s", pkg)
			}
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return err
			}
			if err := copyArchiveFile(src, dst); err != nil {
				return fmt.Errorf("copy persisted stdlib archive %s -> cache %s: %w", src, dst, err)
			}
			if verbose {
				fmt.Fprintf(os.Stderr, "stdlib: synced persisted orchestrion export %s -> cache %s\n", src, dst)
			}
			relDst := dst
			if rel, err := filepath.Rel(cachePath, dst); err == nil {
				relDst = rel
			}
			manifest.WriteString(pkg)
			manifest.WriteString("=")
			manifest.WriteString(relDst)
			manifest.WriteString("\n")
		}
		if manifest.Len() > 0 {
			manifestPath := filepath.Join(cachePath, orchestrionStdlibCacheManifestName)
			if err := os.WriteFile(manifestPath, []byte(manifest.String()), 0o644); err != nil {
				return fmt.Errorf("write stdlib cache manifest at %s: %w", manifestPath, err)
			}
			if verbose {
				fmt.Fprintf(os.Stderr, "stdlib: wrote stdlib cache manifest %s\n", manifestPath)
			}
		}
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
