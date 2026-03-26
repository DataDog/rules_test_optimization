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
	"encoding/json"
	"flag"
	"fmt"
	"go/build"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const syntheticOrchestrionToolGo = `//go:build tools

package tools

import (
	_ "github.com/DataDog/orchestrion"
	_ "github.com/DataDog/dd-trace-go/v2/orchestrion"
	_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2"
	_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2"
)
`

const syntheticStdlibModulePath = "module github.com/DataDog/dd-trace-go/v2/bazel_orchestrion_stdlib"
const orchestrionStdlibCacheManifestName = ".orchestrion_stdlib_cache_manifest"

const (
	// stdlibSnapshotCacheABIVersion invalidates host-side woven stdlib snapshots
	// when their on-disk layout or cache key inputs change.
	stdlibSnapshotCacheABIVersion = "v1"

	// stdlibSnapshotPackageTreeDirName stores the compiled stdlib archive tree
	// rooted at GOROOT/pkg/<installsuffix>.
	stdlibSnapshotPackageTreeDirName = "pkg"

	// stdlibSnapshotPersistedExportsDirName stores the current action's
	// persisted stdlib export manifest and archive copies.
	stdlibSnapshotPersistedExportsDirName = "persisted_exports"

	// stdlibSnapshotGoCacheDirName stores the woven stdlib export cache tree
	// consumed by later compile/link actions and synthetic helper seeding.
	stdlibSnapshotGoCacheDirName = "gocache"
)

// stdlibSnapshotManifest records the host-stable woven stdlib snapshot layout.
// The manifest is intentionally small: it only names the directories restored
// into a fresh action output tree and preserves the exact cache key inputs.
type stdlibSnapshotManifest struct {
	Key                 string   `json:"key"`
	KeyParts            []string `json:"key_parts,omitempty"`
	StdlibSnapshotCache string   `json:"stdlib_snapshot_cache"`
	PackageTreeDir      string   `json:"package_tree_dir"`
	PersistedExportsDir string   `json:"persisted_exports_dir"`
	GoCacheDir          string   `json:"go_cache_dir"`
}

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
	if *orchestrion == "" {
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
			tidyArgs := []string{"mod", "tidy"}
			tidySpan := beginProbe("stdlib.synthetic_module_tidy")
			if err := goenv.runCommand(goenv.goCmd(tidyArgs[0], tidyArgs[1:]...)); err != nil {
				tidySpan.End(err)
				return fmt.Errorf("stdlib: synthetic orchestrion tidy failed: %w", err)
			}
			tidySpan.End(nil)
			if goenv.verbose {
				fmt.Fprintf(os.Stderr, "stdlib: synthetic orchestrion tidy completed using dd-trace-go/v2/orchestrion tools-tagged integration imports\n")
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
		snapshotPaths, snapshotKeyParts, err := stdlibSnapshotCachePaths(goenv, packages, gcflags, *race, *msan, *shared, *dynlink)
		if err != nil {
			return fmt.Errorf("stdlib: derive snapshot cache key: %w", err)
		}
		restoreSpan := beginProbe("stdlib.restore_snapshot", newProbeField("entry_dir", snapshotPaths.entryDir))
		restored, restoreErr := restoreStdlibSnapshot(snapshotPaths, goenv, goenv.verbose)
		restoreSpan.End(restoreErr)
		if restoreErr != nil {
			return fmt.Errorf("stdlib: restore woven stdlib snapshot: %w", restoreErr)
		}
		if restored {
			emitProbeLine("stdlib.restore_snapshot_hit", 0, newProbeField("entry_dir", snapshotPaths.entryDir))
			if goenv.verbose {
				fmt.Fprintf(os.Stderr, "stdlib: restored woven stdlib snapshot from %s\n", snapshotPaths.entryDir)
			}
			return nil
		}
		emitProbeLine("stdlib.restore_snapshot_miss", 0, newProbeField("entry_dir", snapshotPaths.entryDir))
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
		snapshotPersistSpan := beginProbe("stdlib.persist_snapshot", newProbeField("entry_dir", snapshotPaths.entryDir))
		snapshotErr := persistStdlibSnapshot(snapshotPaths, snapshotKeyParts, goenv, goenv.verbose)
		snapshotPersistSpan.End(snapshotErr)
		if snapshotErr != nil {
			emitProbeLine(
				"stdlib.persist_snapshot_failed",
				0,
				newProbeField("entry_dir", snapshotPaths.entryDir),
				newProbeField("status", probeStatus(snapshotErr)),
			)
			if goenv.verbose {
				fmt.Fprintf(os.Stderr, "stdlib: failed to persist woven stdlib snapshot at %s: %v\n", snapshotPaths.entryDir, snapshotErr)
			}
		}
		return nil
	}
	if err := goenv.runCommand(installArgs); err != nil {
		return err
	}
	return nil
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
	// just copied into the persistent export root. Copying those same files back
	// onto pkgRoot only rewrites the exact same paths and adds I/O without
	// changing the current action outputs.
	if err := syncPersistedOrchestrionExportsToCache(goenv, persistedExports, verbose); err != nil {
		return fmt.Errorf("sync persisted stdlib archives into cache exports: %w", err)
	}
	return nil
}

func syncPersistedOrchestrionExportsToCache(goenv *env, exports map[string]string, verbose bool) (err error) {
	span := beginProbe("stdlib.sync_persisted_exports_to_cache", newProbeField("export_count", strconv.Itoa(len(exports))))
	defer func() {
		span.End(err)
	}()
	if goenv == nil || len(exports) == 0 {
		return nil
	}
	packages := make([]string, 0, len(exports))
	for pkg := range exports {
		packages = append(packages, pkg)
	}
	sort.Strings(packages)

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

		cacheExports, err := resolveCacheStdlibExportsAt(goenv, packages, cachePath)
		if err != nil {
			return err
		}
		var manifest strings.Builder
		for _, pkg := range packages {
			src := exports[pkg]
			dst, ok := cacheExports[pkg]
			if !ok || dst == "" {
				continue
			}
			// The stdlib install step already populated the Bazel-declared cache
			// root when cachePath matches goenv.stdlibCache. In that case we only
			// need to verify the resolved archive still exists and record it in the
			// manifest instead of rewriting the same cache entry again.
			skipCopy := filepath.Clean(cachePath) == filepath.Clean(goenv.stdlibCache)
			if skipCopy {
				if _, err := os.Stat(dst); err == nil {
					goto recordManifest
				}
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
		recordManifest:
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

func copyArchiveFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}

// stdlibSnapshotCachePaths returns the host-stable cache entry for a woven
// stdlib build. The key intentionally avoids Bazel output-base paths so a
// fresh output base can restore a matching snapshot instead of rebuilding.
func stdlibSnapshotCachePaths(goenv *env, packages, gcflags []string, race, msan, shared, dynlink bool) (cachePaths, []string, error) {
	configuredVersions, err := configuredDDTraceGoVersions()
	if err != nil {
		return cachePaths{}, nil, err
	}
	sdkIdentity, err := goSDKCacheIdentity(goenv.sdk)
	if err != nil {
		return cachePaths{}, nil, err
	}
	cacheRoot, err := orchestrionPersistentCacheRoot(os.Environ())
	if err != nil {
		return cachePaths{}, nil, err
	}
	keyParts := []string{
		"stdlib_snapshot_cache=" + stdlibSnapshotCacheABIVersion,
		"orchestrion=" + orchestrionVersionIdentity,
		"configured_versions=" + ddTraceVersionsDigest(configuredVersions),
		"sdk=" + sdkIdentity,
		"target=" + goTargetIdentity(os.Environ()),
		"installsuffix=" + goenv.installSuffix,
		"packages=" + strings.Join(normalizeStdlibSnapshotValues(packages), ","),
		"gcflags=" + strings.Join(gcflags, "\x1f"),
		"race=" + strconv.FormatBool(race),
		"msan=" + strconv.FormatBool(msan),
		"shared=" + strconv.FormatBool(shared),
		"dynlink=" + strconv.FormatBool(dynlink),
		"build_env=" + stdlibBuildEnvIdentity(os.Environ()),
	}
	return orchestrionCachePaths(cacheRoot, "woven-stdlib", stableDigestParts(keyParts...)), keyParts, nil
}

// normalizeStdlibSnapshotValues deduplicates and sorts cache-key lists so
// equivalent requests resolve to the same host snapshot entry.
func normalizeStdlibSnapshotValues(values []string) []string {
	seen := make(map[string]bool, len(values))
	normalized := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		normalized = append(normalized, value)
	}
	sort.Strings(normalized)
	return normalized
}

// stdlibBuildEnvIdentity captures the environment settings that materially
// affect a stdlib build so host snapshots do not cross incompatible toolchain
// or cgo configurations.
func stdlibBuildEnvIdentity(env []string) string {
	keys := []string{
		"CGO_ENABLED",
		"CC",
		"CXX",
		"AR",
		"CGO_CFLAGS",
		"CGO_CXXFLAGS",
		"CGO_CPPFLAGS",
		"CGO_LDFLAGS",
		"GOAMD64",
		"GOARM",
		"GO386",
		"GOMIPS",
		"GOMIPS64",
		"GOPPC64",
		"GORISCV64",
		"GOEXPERIMENT",
	}
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, key+"="+normalizeStdlibBuildEnvValue(key, getEnv(env, key)))
	}
	return stableDigestParts(parts...)
}

// normalizeStdlibBuildEnvValue removes output-base-specific path churn from
// environment values that materially affect stdlib builds while preserving the
// actual toolchain identity. This lets equivalent fresh Bazel output bases hit
// the same host-side woven stdlib snapshot cache entry.
func normalizeStdlibBuildEnvValue(key, value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	switch key {
	case "CC", "CXX", "AR":
		return normalizeStdlibBuildEnvToken(value)
	case "CGO_CFLAGS", "CGO_CXXFLAGS", "CGO_CPPFLAGS", "CGO_LDFLAGS":
		parts, err := splitQuoted(value)
		if err != nil {
			return value
		}
		for i, part := range parts {
			parts[i] = normalizeStdlibBuildEnvToken(part)
		}
		return strings.Join(parts, " ")
	default:
		return value
	}
}

// normalizeStdlibBuildEnvToken keeps compiler and cgo flag tokens stable
// across equivalent output bases by normalizing embedded execroot and
// bazel-out paths while leaving non-Bazel host tool paths unchanged.
func normalizeStdlibBuildEnvToken(token string) string {
	token = strings.TrimSpace(token)
	if token == "" {
		return ""
	}
	switch {
	case strings.HasPrefix(token, "-fdebug-prefix-map="), strings.HasPrefix(token, "-ffile-prefix-map="):
		prefixEnd := strings.Index(token, "=") + 1
		mapping := token[prefixEnd:]
		oldPath, newPath, ok := strings.Cut(mapping, "=")
		if !ok {
			return token[:prefixEnd] + stableCacheKeyPath(oldPath)
		}
		return token[:prefixEnd] + stableCacheKeyPath(oldPath) + "=" + newPath
	case strings.HasPrefix(token, "-fuse-ld="):
		prefixEnd := strings.Index(token, "=") + 1
		return token[:prefixEnd] + stableCacheKeyPath(token[prefixEnd:])
	case strings.HasPrefix(token, "-I"), strings.HasPrefix(token, "-L"), strings.HasPrefix(token, "-F"):
		if len(token) > 2 {
			return token[:2] + stableCacheKeyPath(token[2:])
		}
		return token
	case filepath.IsAbs(token):
		return stableCacheKeyPath(token)
	default:
		return token
	}
}

// restoreStdlibSnapshot copies a host-stable woven stdlib snapshot into the
// current action output tree and cache root. A cache miss is silent and falls
// back to the normal stdlib build path.
func restoreStdlibSnapshot(paths cachePaths, goenv *env, verbose bool) (bool, error) {
	if !cacheEntryReady(paths) {
		return false, nil
	}
	manifest, err := loadStdlibSnapshotManifest(paths)
	if err != nil {
		emitProbeLine(
			"stdlib.restore_snapshot_reload_failed",
			0,
			newProbeField("entry_dir", paths.entryDir),
			newProbeField("status", probeStatus(err)),
		)
		return false, nil
	}
	emitProbeLine(
		"stdlib.restore_snapshot_hit",
		0,
		newProbeField("entry_dir", paths.entryDir),
		newProbeField("status", "ok"),
	)
	pkgRoot := filepath.Join(abs(goenv.goroot), "pkg", goenv.installSuffix)
	if err := restoreStdlibSnapshotTree(filepath.Join(paths.entryDir, manifest.PackageTreeDir), pkgRoot); err != nil {
		return false, fmt.Errorf("restore stdlib package tree: %w", err)
	}
	persistedRoot := orchestrionStdlibExportRoot(goenv)
	if persistedRoot != "" {
		if err := restoreStdlibSnapshotTree(filepath.Join(paths.entryDir, manifest.PersistedExportsDir), persistedRoot); err != nil {
			return false, fmt.Errorf("restore persisted stdlib exports: %w", err)
		}
	}
	if goenv.stdlibCache != "" {
		if err := restoreStdlibSnapshotTree(filepath.Join(paths.entryDir, manifest.GoCacheDir), goenv.stdlibCache); err != nil {
			return false, fmt.Errorf("restore stdlib gocache: %w", err)
		}
	}
	if verbose {
		fmt.Fprintf(os.Stderr, "stdlib: restored woven stdlib snapshot into GOROOT=%s GOCACHE=%s\n", goenv.goroot, goenv.stdlibCache)
	}
	return true, nil
}

// persistStdlibSnapshot best-effort stores the woven stdlib outputs in a
// host-stable cache entry so future fresh output bases can restore them.
func persistStdlibSnapshot(paths cachePaths, keyParts []string, goenv *env, verbose bool) error {
	releaseLock, err := acquireCacheLock(paths.lockDir, cacheLockTimeout, cacheLockStaleAfter)
	if err != nil {
		return err
	}
	defer releaseLock()

	if cacheEntryReady(paths) {
		return nil
	}

	tempEntryDir, err := os.MkdirTemp(filepath.Dir(paths.entryDir), filepath.Base(paths.entryDir)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create stdlib snapshot temp dir: %w", err)
	}
	success := false
	defer func() {
		if !success {
			_ = os.RemoveAll(tempEntryDir)
		}
	}()

	pkgRoot := filepath.Join(abs(goenv.goroot), "pkg", goenv.installSuffix)
	if err := copyStdlibSnapshotTree(pkgRoot, filepath.Join(tempEntryDir, stdlibSnapshotPackageTreeDirName)); err != nil {
		return fmt.Errorf("copy stdlib package tree: %w", err)
	}
	persistedRoot := orchestrionStdlibExportRoot(goenv)
	if persistedRoot != "" {
		if err := copyStdlibSnapshotTree(persistedRoot, filepath.Join(tempEntryDir, stdlibSnapshotPersistedExportsDirName)); err != nil {
			return fmt.Errorf("copy persisted stdlib exports: %w", err)
		}
	}
	if goenv.stdlibCache != "" {
		if err := copyStdlibSnapshotTree(goenv.stdlibCache, filepath.Join(tempEntryDir, stdlibSnapshotGoCacheDirName)); err != nil {
			return fmt.Errorf("copy stdlib gocache: %w", err)
		}
	}

	manifest := stdlibSnapshotManifest{
		Key:                 filepath.Base(paths.entryDir),
		KeyParts:            append([]string{}, keyParts...),
		StdlibSnapshotCache: stdlibSnapshotCacheABIVersion,
		PackageTreeDir:      stdlibSnapshotPackageTreeDirName,
		PersistedExportsDir: stdlibSnapshotPersistedExportsDirName,
		GoCacheDir:          stdlibSnapshotGoCacheDirName,
	}
	if err := writeJSONAtomically(filepath.Join(tempEntryDir, cacheManifestFileName), manifest); err != nil {
		return fmt.Errorf("write stdlib snapshot manifest: %w", err)
	}
	if err := writeReadySentinel(filepath.Join(tempEntryDir, cacheReadyFileName)); err != nil {
		return fmt.Errorf("write stdlib snapshot ready file: %w", err)
	}
	if err := promoteCacheTempDir(tempEntryDir, paths.entryDir); err != nil {
		return fmt.Errorf("promote stdlib snapshot cache: %w", err)
	}
	success = true
	if verbose {
		fmt.Fprintf(os.Stderr, "stdlib: persisted woven stdlib snapshot at %s\n", paths.entryDir)
	}
	return nil
}

// loadStdlibSnapshotManifest validates the on-disk snapshot metadata before a
// restore path trusts it.
func loadStdlibSnapshotManifest(paths cachePaths) (stdlibSnapshotManifest, error) {
	data, err := os.ReadFile(paths.manifestPath)
	if err != nil {
		return stdlibSnapshotManifest{}, fmt.Errorf("read stdlib snapshot manifest %s: %w", paths.manifestPath, err)
	}
	var manifest stdlibSnapshotManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return stdlibSnapshotManifest{}, fmt.Errorf("parse stdlib snapshot manifest %s: %w", paths.manifestPath, err)
	}
	required := map[string]string{
		"package tree":      manifest.PackageTreeDir,
		"persisted exports": manifest.PersistedExportsDir,
		"go cache":          manifest.GoCacheDir,
	}
	for label, relPath := range required {
		if strings.TrimSpace(relPath) == "" {
			return stdlibSnapshotManifest{}, fmt.Errorf("stdlib snapshot manifest %s missing %s path", paths.manifestPath, label)
		}
		info, err := os.Stat(filepath.Join(paths.entryDir, relPath))
		if err != nil {
			return stdlibSnapshotManifest{}, fmt.Errorf("stat stdlib snapshot %s at %s: %w", label, filepath.Join(paths.entryDir, relPath), err)
		}
		if !info.IsDir() {
			return stdlibSnapshotManifest{}, fmt.Errorf("stdlib snapshot %s at %s is not a directory", label, filepath.Join(paths.entryDir, relPath))
		}
	}
	return manifest, nil
}

// restoreStdlibSnapshotTree replaces dstRoot with a copied snapshot tree so
// the current action owns regular writable files rather than linked cache
// entries from the host cache.
func restoreStdlibSnapshotTree(srcRoot, dstRoot string) error {
	if err := os.RemoveAll(dstRoot); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dstRoot), 0o755); err != nil {
		return err
	}
	return syncDirectoryTree(srcRoot, dstRoot)
}

// copyStdlibSnapshotTree materializes a snapshot source tree under temp cache
// storage. Missing optional roots are ignored so cache writes stay best-effort.
func copyStdlibSnapshotTree(srcRoot, dstRoot string) error {
	info, err := os.Stat(srcRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return os.MkdirAll(dstRoot, 0o755)
		}
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("%s is not a directory", srcRoot)
	}
	if err := os.RemoveAll(dstRoot); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(dstRoot, 0o755); err != nil {
		return err
	}
	return syncDirectoryTree(srcRoot, dstRoot)
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
