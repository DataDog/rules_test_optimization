// Copyright 2024 The Bazel Authors. All rights reserved.
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
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	// orchestrionJobserverURLEnvVar is the environment variable used by orchestrion
	// to locate the jobserver.
	orchestrionJobserverURLEnvVar = "ORCHESTRION_JOBSERVER_URL"

	// toolexecImportPathEnvVar is the environment variable used by orchestrion
	// to know the import path of the package being compiled.
	toolexecImportPathEnvVar = "TOOLEXEC_IMPORTPATH"

	// orchestrionSkipPinEnvVar is set to skip orchestrion's auto-pinning behavior
	// which tries to modify go.mod files (not needed in Bazel builds).
	orchestrionSkipPinEnvVar = "DD_ORCHESTRION_IS_GOMOD_VERSION"

	// jobserverStartTimeout is the maximum time to wait for the jobserver to start.
	jobserverStartTimeout = 10 * time.Second

	// jobserverPollInterval is the interval to poll for the URL file.
	jobserverPollInterval = 50 * time.Millisecond

	// orchestrionSharedCacheDirName is a stable cache root shared by bootstrap
	// and sandboxed Orchestrion subprocesses, so woven dependency resolution can
	// reuse downloaded modules across steps.
	orchestrionSharedCacheDirName = "datadog-orchestrion-go-cache"

	orchestrionLogLevelEnvVar = "ORCHESTRION_LOG_LEVEL"

	orchestrionStdlibCacheEnvVar = "RULES_GO_ORCHESTRION_STDLIB_CACHE"
)

var orchestrionWovenPackagePatterns = []string{
	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer",
	"github.com/DataDog/dd-trace-go/v2/profiler",
	"github.com/DataDog/dd-trace-go/v2/instrumentation/env",
}

// ensureGoModuleCacheEnv provisions a writable Go cache/module cache for
// orchestrion subprocesses. Some Bazel sandboxes do not provide GOPATH or
// GOMODCACHE, but orchestrion shells out to `go list` while loading injector
// configuration from orchestrion.tool.go.
func ensureGoModuleCacheEnv(env []string, verbose bool) ([]string, error) {
	goBuildCache := strings.TrimSpace(getEnv(env, orchestrionStdlibCacheEnvVar))
	explicitBuildCache := goBuildCache != ""
	if goBuildCache == "" {
		goBuildCache = getEnv(env, "GOCACHE")
		explicitBuildCache = goBuildCache != ""
	}
	cacheRoot := strings.TrimSpace(getEnv(env, "GOPATH"))
	if cacheRoot == "" {
		// Keep the compiled object cache in Bazel's declared output tree when it
		// is provided, but anchor GOPATH/GOMODCACHE in a stable user cache root so
		// local reruns are not coupled to a fresh TMPDIR or output_base.
		cacheRoot = filepath.Join(orchestrionDefaultCacheRoot(env), "gopath")
	}
	if goBuildCache == "" {
		goBuildCache = filepath.Join(cacheRoot, "cache")
	}
	if !explicitBuildCache {
		if goroot := strings.TrimSpace(getEnv(env, "GOROOT")); goroot != "" {
			sum := sha256.Sum256([]byte(stableCacheKeyPath(goroot)))
			goBuildCache = filepath.Join(cacheRoot, "cache", hex.EncodeToString(sum[:8]))
		}
	}

	goModCache := strings.TrimSpace(getEnv(env, "GOMODCACHE"))
	if goModCache == "" {
		goModCache = filepath.Join(cacheRoot, "pkg", "mod")
	}

	for _, dir := range []string{goModCache, goBuildCache} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("creating orchestrion go cache dir %s: %w", dir, err)
		}
	}

	env = setEnv(env, "GOPATH", cacheRoot)
	env = setEnv(env, "GOMODCACHE", goModCache)
	env = setEnv(env, "GOCACHE", goBuildCache)
	env = setEnv(env, "GOPROXY", "https://proxy.golang.org,direct")
	env = setEnv(env, "GOSUMDB", "sum.golang.org")

	if verbose {
		fmt.Fprintf(os.Stderr, "orchestrion: using GOPATH=%s GOMODCACHE=%s GOCACHE=%s GOPROXY=%s\n", cacheRoot, goModCache, goBuildCache, getEnv(env, "GOPROXY"))
	}

	return env, nil
}

func stableCacheKeyPath(path string) string {
	path = abs(path)
	path = filepath.ToSlash(path)
	for _, marker := range []string{
		"/execroot/_main/",
		"/execroot/__main__/",
		"/bazel-out/",
		"/external/",
	} {
		if idx := strings.Index(path, marker); idx >= 0 {
			return path[idx+1:]
		}
	}
	return path
}

func ensureWovenPackagesAvailable(env []string, goSdkPath string, verbose bool) (err error) {
	span := beginProbe("orchestrion.ensure_woven_packages_available")
	defer func() {
		span.End(err)
	}()
	goExe := ""
	if goSdkPath != "" {
		goExe = filepath.Join(abs(goSdkPath), "bin", "go")
		if runtime.GOOS == "windows" {
			goExe += ".exe"
		}
	}
	if goExe == "" {
		goExe = filepath.Join(getEnv(env, "GOROOT"), "bin", "go")
		if runtime.GOOS == "windows" {
			goExe += ".exe"
		}
	}

	if _, err := os.Stat(goExe); err != nil {
		if verbose {
			fmt.Fprintf(os.Stderr, "orchestrion: skipping woven dependency warmup; go binary unavailable at %s: %v\n", goExe, err)
		}
		return nil
	}

	probeIncludesRequestedPackages := func(out []byte) bool {
		text := string(out)
		for _, pkg := range orchestrionWovenPackagePatterns {
			if !strings.Contains(text, pkg) {
				return false
			}
		}
		return true
	}

	runProbe := func(label string, args ...string) error {
		probe := beginProbe(
			"orchestrion.ensure_woven_packages_available."+strings.ReplaceAll(label, " ", "_"),
			newProbeField("argv0", filepath.Base(goExe)),
			newProbeField("arg_count", strconv.Itoa(len(args))),
		)
		cmd := exec.Command(goExe, args...)
		cmd.Env = env
		cmd.Dir = mustGetwd()
		out, err := cmd.CombinedOutput()
		if verbose {
			fmt.Fprintf(os.Stderr, "orchestrion: %s command=%q\n", label, append([]string{goExe}, args...))
			if len(out) > 0 {
				fmt.Fprintf(os.Stderr, "orchestrion: %s output:\n%s\n", label, string(out))
			}
		}
		if err != nil {
			if probeIncludesRequestedPackages(out) {
				if verbose {
					fmt.Fprintf(os.Stderr, "orchestrion: %s returned non-zero but included all requested woven packages; continuing\n", label)
				}
				probe.End(nil, newProbeField("result", "non_zero_but_complete"))
				return nil
			}
			probe.End(err)
			return fmt.Errorf("%s failed: %w", label, err)
		}
		probe.End(nil)
		return nil
	}

	if err := runProbe("probe woven deps", append([]string{"list", "-mod=mod"}, orchestrionWovenPackagePatterns...)...); err == nil {
		return nil
	} else if verbose {
		fmt.Fprintf(os.Stderr, "orchestrion: initial woven dependency probe failed: %v\n", err)
	}

	if err := runProbe("download dd-trace-go", "mod", "download", "github.com/DataDog/dd-trace-go/v2"); err != nil && verbose {
		fmt.Fprintf(os.Stderr, "orchestrion: dd-trace-go module download failed: %v\n", err)
	}
	if err := runProbe("re-probe woven deps", append([]string{"list", "-mod=mod"}, orchestrionWovenPackagePatterns...)...); err != nil {
		return err
	}
	return nil
}

func ensureGoRootCompatibility(goRootPath, goSdkPath string, verbose bool) error {
	if goRootPath == "" || goSdkPath == "" {
		return nil
	}

	srcPath := filepath.Join(goRootPath, "src")
	if _, err := os.Stat(srcPath); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("stat GOROOT src %s: %w", srcPath, err)
	}

	sdkSrcPath := filepath.Join(goSdkPath, "src")
	if _, err := os.Stat(sdkSrcPath); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("stat SDK src %s: %w", sdkSrcPath, err)
	}

	linkTarget, err := computeCompatibilitySymlinkTarget(goRootPath, sdkSrcPath)
	if err != nil {
		return fmt.Errorf("compute GOROOT src symlink from %s to %s: %w", goRootPath, sdkSrcPath, err)
	}
	if err := os.Symlink(linkTarget, srcPath); err != nil && !os.IsExist(err) {
		return fmt.Errorf("create GOROOT src symlink %s -> %s: %w", srcPath, linkTarget, err)
	}
	if verbose {
		fmt.Fprintf(os.Stderr, "orchestrion: created GOROOT src compatibility symlink %s -> %s\n", srcPath, linkTarget)
	}
	return nil
}

func computeCompatibilitySymlinkTarget(baseDir, dstPath string) (string, error) {
	relTarget, err := filepath.Rel(baseDir, dstPath)
	if err == nil {
		return relTarget, nil
	}
	absTarget, absErr := filepath.Abs(dstPath)
	if absErr != nil {
		return "", fmt.Errorf("absolutize compatibility target %s after relative failure: %w", dstPath, absErr)
	}
	return absTarget, nil
}

// orchestrionJobserver manages the lifecycle of an orchestrion jobserver process.
type orchestrionJobserver struct {
	url     string
	urlFile string
	cmd     *exec.Cmd
}

// ensureGoModExists creates a minimal go.mod file in the current directory if one
// doesn't exist. This is required by orchestrion to function properly.
// If srcDirs contains directories with orchestrion.yml, it copies them to the
// current directory so orchestrion can find its configuration.
// Returns a cleanup function that removes the temporary files we created.
func ensureGoModExists(srcDirs []string, goSdkPath string, verbose bool) (cleanup func(), err error) {
	span := beginProbe("orchestrion.ensure_go_mod_exists", newProbeField("src_dir_count", strconv.Itoa(len(srcDirs))))
	defer func() {
		span.End(err)
	}()
	const goModFile = "go.mod"
	const goSumFile = "go.sum"
	const orchestrionYML = "orchestrion.yml"
	const orchestrionToolGo = "orchestrion.tool.go"

	var filesToCleanup []string
	var copiedGoMod bool
	configuredVersions, err := configuredDDTraceGoVersions()
	if err != nil {
		return nil, err
	}

	if verbose {
		cwd, _ := os.Getwd()
		fmt.Fprintf(os.Stderr, "orchestrion: ensureGoModExists cwd=%s srcDirs=%v\n", cwd, srcDirs)
	}

	// Prefer copying pinned module metadata from the source directory. Orchestrion
	// needs the real module requirements from `orchestrion pin`; a synthetic
	// minimal go.mod is only a fallback when the package has no module files.
	if _, err := os.Stat(goModFile); os.IsNotExist(err) {
		for _, dir := range srcDirs {
			goModSrc := filepath.Join(dir, goModFile)
			if _, err := os.Stat(goModSrc); err == nil {
				if verbose {
					fmt.Fprintf(os.Stderr, "orchestrion: Found %s\n", goModSrc)
				}
				if err := copyOrchFile(goModSrc, goModFile); err != nil {
					return nil, fmt.Errorf("copying go.mod: %w", err)
				}
				filesToCleanup = append(filesToCleanup, goModFile)
				copiedGoMod = true
				if verbose {
					fmt.Fprintf(os.Stderr, "orchestrion: Copied go.mod to cwd\n")
				}

				goSumSrc := filepath.Join(dir, goSumFile)
				if _, err := os.Stat(goSumSrc); err == nil {
					if verbose {
						fmt.Fprintf(os.Stderr, "orchestrion: Found %s\n", goSumSrc)
					}
					if err := copyOrchFile(goSumSrc, goSumFile); err != nil {
						return nil, fmt.Errorf("copying go.sum: %w", err)
					}
					filesToCleanup = append(filesToCleanup, goSumFile)
					if verbose {
						fmt.Fprintf(os.Stderr, "orchestrion: Copied go.sum to cwd\n")
					}
				}
				break
			}
		}

		if !copiedGoMod {
			content := []byte(syntheticOrchestrionGoMod(configuredVersions))
			if err := os.WriteFile(goModFile, content, 0644); err != nil {
				return nil, fmt.Errorf("creating temporary go.mod: %w", err)
			}
			filesToCleanup = append(filesToCleanup, goModFile)
			if verbose {
				fmt.Fprintf(os.Stderr, "orchestrion: Created temporary go.mod\n")
			}
		}
	}

	if _, err := os.Stat(goModFile); err == nil {
		goExe := resolveGoExecutable(goSdkPath)
		if err := validateResolvedDDTraceGoVersion(goExe, ".", os.Environ(), verbose); err != nil {
			return nil, err
		}
	} else if err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("stat go.mod: %w", err)
	}

	// Look for orchestrion.yml in source directories and copy it to cwd
	// Also look for orchestrion.tool.go which may contain additional config imports
	var copiedToolGo bool
	for _, dir := range srcDirs {
		ymlSrc := filepath.Join(dir, orchestrionYML)
		if _, err := os.Stat(ymlSrc); err == nil {
			if verbose {
				fmt.Fprintf(os.Stderr, "orchestrion: Found %s\n", ymlSrc)
			}
			// Copy orchestrion.yml to current directory
			if _, err := os.Stat(orchestrionYML); os.IsNotExist(err) {
				if err := copyOrchFile(ymlSrc, orchestrionYML); err != nil {
					return nil, fmt.Errorf("copying orchestrion.yml: %w", err)
				}
				filesToCleanup = append(filesToCleanup, orchestrionYML)
				if verbose {
					fmt.Fprintf(os.Stderr, "orchestrion: Copied orchestrion.yml to cwd\n")
				}
			}
		}

		toolGoSrc := filepath.Join(dir, orchestrionToolGo)
		if _, err := os.Stat(toolGoSrc); err == nil {
			if verbose {
				fmt.Fprintf(os.Stderr, "orchestrion: Found %s\n", toolGoSrc)
			}
			// Copy orchestrion.tool.go to current directory
			if _, err := os.Stat(orchestrionToolGo); os.IsNotExist(err) {
				if err := copyOrchFile(toolGoSrc, orchestrionToolGo); err != nil {
					return nil, fmt.Errorf("copying orchestrion.tool.go: %w", err)
				}
				filesToCleanup = append(filesToCleanup, orchestrionToolGo)
				copiedToolGo = true
				if verbose {
					fmt.Fprintf(os.Stderr, "orchestrion: Copied orchestrion.tool.go to cwd\n")
				}
			}
		}
	}

	if _, err := os.Stat(orchestrionToolGo); os.IsNotExist(err) {
		if err := os.WriteFile(orchestrionToolGo, []byte(syntheticOrchestrionToolGo), 0o644); err != nil {
			return nil, fmt.Errorf("creating temporary orchestrion.tool.go: %w", err)
		}
		filesToCleanup = append(filesToCleanup, orchestrionToolGo)
		if verbose {
			if copiedToolGo {
				fmt.Fprintf(os.Stderr, "orchestrion: Recreated missing orchestrion.tool.go with synthetic fallback\n")
			} else {
				fmt.Fprintf(os.Stderr, "orchestrion: Created temporary orchestrion.tool.go\n")
			}
		}
	} else if err != nil {
		return nil, fmt.Errorf("stat orchestrion.tool.go: %w", err)
	}

	if verbose {
		logOrchestrionTempModuleState()
	}

	shouldPrepareSynthetic := false
	for _, path := range filesToCleanup {
		base := filepath.Base(path)
		if base == goModFile || base == goSumFile || base == orchestrionToolGo {
			shouldPrepareSynthetic = true
			break
		}
	}
	if shouldPrepareSynthetic && !copiedGoMod {
		cacheHit, err := restorePreparedSyntheticModule(goSdkPath, configuredVersions, verbose)
		if err != nil {
			return nil, err
		}
		if !cacheHit {
			if err := prepareSyntheticOrchestrionModule(goSdkPath, verbose); err != nil {
				return nil, err
			}
			if err := snapshotPreparedSyntheticModule(goSdkPath, configuredVersions); err != nil {
				return nil, err
			}
		}
	} else if shouldPrepareSynthetic {
		if err := prepareSyntheticOrchestrionModule(goSdkPath, verbose); err != nil {
			return nil, err
		}
	}

	return func() {
		for _, f := range filesToCleanup {
			os.Remove(f)
		}
	}, nil
}

func prepareSyntheticOrchestrionModule(goSdkPath string, verbose bool) (err error) {
	span := beginProbe("orchestrion.prepare_synthetic_module")
	defer func() {
		span.End(err)
	}()
	goExe := resolveGoExecutable(goSdkPath)
	if goExe == "" {
		if verbose {
			fmt.Fprintf(os.Stderr, "orchestrion: skipping synthetic module preparation; go binary unavailable\n")
		}
		return nil
	}

	run := func(label string, args ...string) error {
		probe := beginProbe(
			"orchestrion.prepare_synthetic_module."+strings.ReplaceAll(label, " ", "_"),
			newProbeField("argv0", filepath.Base(goExe)),
			newProbeField("arg_count", strconv.Itoa(len(args))),
		)
		cmd := exec.Command(goExe, args...)
		env := append([]string{}, os.Environ()...)
		normalizedEnv, envErr := ensureGoModuleCacheEnv(env, verbose)
		if envErr != nil {
			return fmt.Errorf("prepare synthetic module cache env: %w", envErr)
		}
		env = normalizedEnv
		var replaced bool
		for i, entry := range env {
			if strings.HasPrefix(entry, "GO111MODULE=") {
				env[i] = "GO111MODULE=on"
				replaced = true
				break
			}
		}
		if !replaced {
			env = append(env, "GO111MODULE=on")
		}
		var foundProxy bool
		var foundSumDB bool
		for i, entry := range env {
			switch {
			case strings.HasPrefix(entry, "GOPROXY="):
				foundProxy = true
				if strings.TrimPrefix(entry, "GOPROXY=") == "" {
					env[i] = "GOPROXY=https://proxy.golang.org,direct"
				}
			case strings.HasPrefix(entry, "GOSUMDB="):
				foundSumDB = true
				if strings.TrimPrefix(entry, "GOSUMDB=") == "" {
					env[i] = "GOSUMDB=sum.golang.org"
				}
			}
		}
		if !foundProxy {
			env = append(env, "GOPROXY=https://proxy.golang.org,direct")
		}
		if !foundSumDB {
			env = append(env, "GOSUMDB=sum.golang.org")
		}
		cmd.Env = env
		cmd.Dir = mustGetwd()
		out, err := cmd.CombinedOutput()
		if verbose {
			fmt.Fprintf(os.Stderr, "orchestrion: %s command=%q\n", label, append([]string{goExe}, args...))
			if len(out) > 0 {
				fmt.Fprintf(os.Stderr, "orchestrion: %s output:\n%s\n", label, string(out))
			}
		}
		if err != nil {
			probe.End(err)
			return fmt.Errorf("%s failed: %w", label, err)
		}
		probe.End(nil)
		return nil
	}

	if err := run("download synthetic deps", "mod", "download",
		"github.com/DataDog/orchestrion",
		"github.com/DataDog/dd-trace-go/v2",
		"github.com/DataDog/dd-trace-go/contrib/net/http/v2",
		"github.com/DataDog/dd-trace-go/contrib/log/slog/v2",
	); err != nil {
		return err
	}
	if err := run("load orchestrion tool imports", "list", "-mod=mod", "-tags=tools", "github.com/DataDog/dd-trace-go/v2/orchestrion"); err != nil {
		return err
	}
	if err := run("tidy synthetic module", "mod", "tidy"); err != nil {
		return err
	}
	return nil
}

type preparedSyntheticModuleManifest struct {
	Key                  string `json:"key"`
	HasGoSum             bool   `json:"has_go_sum"`
	SyntheticModuleCache string `json:"synthetic_module_cache"`
}

func restorePreparedSyntheticModule(goSdkPath string, configuredVersions map[string]string, verbose bool) (bool, error) {
	cacheDir, paths, err := preparedSyntheticModuleCachePaths(goSdkPath, configuredVersions)
	if err != nil {
		return false, err
	}
	if !cacheEntryReady(paths) {
		return false, nil
	}
	if verbose {
		fmt.Fprintf(os.Stderr, "orchestrion: synthetic module cache hit key=%s\n", filepath.Base(cacheDir))
	}
	if _, err := copyFileIfExists(filepath.Join(cacheDir, "go.mod"), "go.mod"); err != nil {
		return false, fmt.Errorf("restore prepared synthetic go.mod: %w", err)
	}
	if _, err := copyFileIfExists(filepath.Join(cacheDir, "orchestrion.tool.go"), "orchestrion.tool.go"); err != nil {
		return false, fmt.Errorf("restore prepared synthetic orchestrion.tool.go: %w", err)
	}
	hasGoSum, err := copyFileIfExists(filepath.Join(cacheDir, "go.sum"), "go.sum")
	if err != nil {
		return false, fmt.Errorf("restore prepared synthetic go.sum: %w", err)
	}
	if !hasGoSum {
		_ = os.Remove("go.sum")
	}
	return true, nil
}

func snapshotPreparedSyntheticModule(goSdkPath string, configuredVersions map[string]string) error {
	cacheDir, paths, err := preparedSyntheticModuleCachePaths(goSdkPath, configuredVersions)
	if err != nil {
		return err
	}
	releaseLock, err := acquireCacheLock(paths.lockDir, cacheLockTimeout, cacheLockStaleAfter)
	if err != nil {
		return err
	}
	defer releaseLock()
	if cacheEntryReady(paths) {
		return nil
	}
	tempDir, err := os.MkdirTemp(filepath.Dir(paths.entryDir), filepath.Base(paths.entryDir)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create prepared synthetic module temp dir: %w", err)
	}
	success := false
	defer func() {
		if !success {
			_ = os.RemoveAll(tempDir)
		}
	}()
	if _, err := copyFileIfExists("go.mod", filepath.Join(tempDir, "go.mod")); err != nil {
		return fmt.Errorf("snapshot prepared synthetic go.mod: %w", err)
	}
	hasGoSum, err := copyFileIfExists("go.sum", filepath.Join(tempDir, "go.sum"))
	if err != nil {
		return fmt.Errorf("snapshot prepared synthetic go.sum: %w", err)
	}
	if _, err := copyFileIfExists("orchestrion.tool.go", filepath.Join(tempDir, "orchestrion.tool.go")); err != nil {
		return fmt.Errorf("snapshot prepared synthetic orchestrion.tool.go: %w", err)
	}
	manifest := preparedSyntheticModuleManifest{
		Key:                  filepath.Base(cacheDir),
		HasGoSum:             hasGoSum,
		SyntheticModuleCache: syntheticModuleCacheABIVersion,
	}
	if err := writeJSONAtomically(filepath.Join(tempDir, cacheManifestFileName), manifest); err != nil {
		return fmt.Errorf("write prepared synthetic module manifest: %w", err)
	}
	if err := writeReadySentinel(filepath.Join(tempDir, cacheReadyFileName)); err != nil {
		return fmt.Errorf("write prepared synthetic module ready file: %w", err)
	}
	if err := promoteCacheTempDir(tempDir, cacheDir); err != nil {
		return fmt.Errorf("promote prepared synthetic module cache: %w", err)
	}
	success = true
	return nil
}

func preparedSyntheticModuleCachePaths(goSdkPath string, configuredVersions map[string]string) (string, cachePaths, error) {
	key, err := preparedSyntheticModuleCacheKey(goSdkPath, configuredVersions)
	if err != nil {
		return "", cachePaths{}, err
	}
	cacheRoot, err := orchestrionPersistentCacheRoot(os.Environ())
	if err != nil {
		return "", cachePaths{}, err
	}
	paths := orchestrionCachePaths(cacheRoot, "synthetic-module", key)
	return paths.entryDir, paths, nil
}

func preparedSyntheticModuleCacheKey(goSdkPath string, configuredVersions map[string]string) (string, error) {
	goModDigest, err := digestFileOrMissing("go.mod")
	if err != nil {
		return "", err
	}
	toolDigest, err := digestFileOrMissing("orchestrion.tool.go")
	if err != nil {
		return "", err
	}
	return stableDigestParts(
		"go_mod="+goModDigest,
		"tool_go="+toolDigest,
		"configured_versions="+ddTraceVersionsDigest(configuredVersions),
		"go_sdk="+abs(goSdkPath),
		"orchestrion="+orchestrionVersionIdentity,
		"target="+goTargetIdentity(os.Environ()),
		"synthetic_module_cache="+syntheticModuleCacheABIVersion,
	), nil
}

func logOrchestrionTempModuleState() {
	cwd, _ := os.Getwd()
	fmt.Fprintf(os.Stderr, "orchestrion: temp module cwd=%s\n", cwd)
	for _, name := range []string{"go.mod", "go.sum", "orchestrion.tool.go", "orchestrion.yml"} {
		if info, err := os.Stat(name); err == nil {
			fmt.Fprintf(os.Stderr, "orchestrion: temp file %s size=%d\n", name, info.Size())
		} else if os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "orchestrion: temp file %s missing\n", name)
		} else {
			fmt.Fprintf(os.Stderr, "orchestrion: temp file %s stat error: %v\n", name, err)
		}
	}
	if data, err := os.ReadFile("go.mod"); err == nil {
		fmt.Fprintf(os.Stderr, "orchestrion: temp go.mod has dd-trace-go/v2=%t dd-trace-go.v1=%t orchestrion/all/v2=%t\n",
			strings.Contains(string(data), "github.com/DataDog/dd-trace-go/v2"),
			strings.Contains(string(data), "gopkg.in/DataDog/dd-trace-go.v1"),
			strings.Contains(string(data), "github.com/DataDog/dd-trace-go/orchestrion/all/v2"))
	}
	if data, err := os.ReadFile("orchestrion.tool.go"); err == nil {
		fmt.Fprintf(os.Stderr, "orchestrion: temp orchestrion.tool.go contents begin\n%s\norchestrion: temp orchestrion.tool.go contents end\n", string(data))
	}
	if data, err := os.ReadFile("orchestrion.yml"); err == nil {
		fmt.Fprintf(os.Stderr, "orchestrion: temp orchestrion.yml contents begin\n%s\norchestrion: temp orchestrion.yml contents end\n", string(data))
	}
}

// enterOrchestrionWorkDir switches the current process directory to the first
// source directory that already contains Orchestrion pin/module metadata. This
// keeps `go list` / `go env GOMOD` aligned with the real Go module root instead
// of Bazel's execroot when Orchestrion shells out during toolexec compilation.
func enterOrchestrionWorkDir(srcDirs []string, verbose bool) (func(), error) {
	for _, dir := range srcDirs {
		moduleDir := findContainingOrchestrionDir(dir)
		if moduleDir == "" {
			continue
		}
		cwd, err := os.Getwd()
		if err != nil {
			return nil, fmt.Errorf("determine cwd before orchestrion chdir: %w", err)
		}
		if cwd == moduleDir {
			return func() {}, nil
		}
		var cleanupPaths []string
		for _, name := range []string{"bazel-out", "external"} {
			srcPath := filepath.Join(cwd, name)
			if _, err := os.Stat(srcPath); err != nil {
				continue
			}
			dstPath := filepath.Join(moduleDir, name)
			if _, err := os.Lstat(dstPath); err == nil {
				continue
			} else if !os.IsNotExist(err) {
				return nil, fmt.Errorf("stat orchestrion compatibility path %s: %w", dstPath, err)
			}
			linkTarget, err := computeCompatibilitySymlinkTarget(moduleDir, srcPath)
			if err != nil {
				return nil, fmt.Errorf("compute orchestrion compatibility path for %s: %w", name, err)
			}
			if err := os.Symlink(linkTarget, dstPath); err != nil {
				return nil, fmt.Errorf("create orchestrion compatibility symlink %s -> %s: %w", dstPath, linkTarget, err)
			}
			cleanupPaths = append(cleanupPaths, dstPath)
			if verbose {
				fmt.Fprintf(os.Stderr, "orchestrion: created compatibility symlink %s -> %s\n", dstPath, linkTarget)
			}
		}
		if verbose {
			fmt.Fprintf(os.Stderr, "orchestrion: chdir %s -> %s\n", cwd, moduleDir)
		}
		if err := os.Chdir(moduleDir); err != nil {
			for _, cleanupPath := range cleanupPaths {
				_ = os.Remove(cleanupPath)
			}
			return nil, fmt.Errorf("chdir to orchestrion work dir %s: %w", moduleDir, err)
		}
		return func() {
			_ = os.Chdir(cwd)
			for _, cleanupPath := range cleanupPaths {
				_ = os.Remove(cleanupPath)
			}
		}, nil
	}
	return func() {}, nil
}

func findContainingOrchestrionDir(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	resolved := path
	if absPath, err := filepath.Abs(path); err == nil {
		if realPath, err := filepath.EvalSymlinks(absPath); err == nil {
			resolved = realPath
		} else {
			resolved = absPath
		}
	}
	info, err := os.Stat(resolved)
	if err == nil && !info.IsDir() {
		resolved = filepath.Dir(resolved)
	}
	for {
		for _, marker := range []string{"go.mod", "orchestrion.tool.go", "orchestrion.yml"} {
			if _, err := os.Stat(filepath.Join(resolved, marker)); err == nil {
				return resolved
			}
		}
		parent := filepath.Dir(resolved)
		if parent == resolved {
			return ""
		}
		resolved = parent
	}
}

func resolveOrchestrionImportPath(fallback string, verbose bool) string {
	cwd, err := os.Getwd()
	if err != nil {
		return fallback
	}

	moduleDir := cwd
	for {
		if _, err := os.Stat(filepath.Join(moduleDir, "go.mod")); err == nil {
			break
		}
		parent := filepath.Dir(moduleDir)
		if parent == moduleDir {
			return fallback
		}
		moduleDir = parent
	}

	modulePath, err := readGoModulePath(filepath.Join(moduleDir, "go.mod"))
	if err != nil || modulePath == "" {
		return fallback
	}

	rel, err := filepath.Rel(moduleDir, cwd)
	if err != nil {
		return fallback
	}

	importPath := modulePath
	if rel != "." {
		importPath = modulePath + "/" + filepath.ToSlash(rel)
	}

	if verbose {
		fmt.Fprintf(os.Stderr, "orchestrion: resolved import path %s -> %s (moduleDir=%s cwd=%s)\n", fallback, importPath, moduleDir, cwd)
	}

	return importPath
}

func readGoModulePath(goModPath string) (string, error) {
	f, err := os.Open(goModPath)
	if err != nil {
		return "", err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "//") {
			continue
		}
		if strings.HasPrefix(line, "module ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "module ")), nil
		}
	}

	if err := scanner.Err(); err != nil {
		return "", err
	}
	return "", nil
}

// copyOrchFile copies a file from src to dst. This is a simple wrapper
// that reads the entire file and writes it to the destination.
// Note: There's also a copyFile in cgo2.go with different implementation.
func copyOrchFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0644)
}

// startOrchestrionJobserver starts an orchestrion jobserver and returns the server
// instance. The caller must call cleanup() when done to terminate the server.
// If orchestrionPath is empty or ORCHESTRION_JOBSERVER_URL is already set,
// this returns nil (no server needed).
// goSdkPath is the path to the Go SDK, used to set PATH for the server.
// goRootPath is the GOROOT tree that should be exposed to `go list` / asm
// resolution inside the jobserver. Under Bazel this is often the cloned stdlib
// tree, not the SDK root.
func startOrchestrionJobserver(orchestrionPath, goSdkPath, goRootPath string, verbose bool) (_ *orchestrionJobserver, err error) {
	span := beginProbe(
		"orchestrion.start_jobserver",
		newProbeField("orchestrion", strconv.FormatBool(orchestrionPath != "")),
	)
	defer func() {
		span.End(err)
	}()
	if orchestrionPath == "" {
		return nil, nil
	}

	// If ORCHESTRION_JOBSERVER_URL is already set, we don't need to start a server
	if os.Getenv(orchestrionJobserverURLEnvVar) != "" {
		return nil, nil
	}

	// Create a temporary file for the URL
	tmpDir := os.TempDir()
	urlFile := filepath.Join(tmpDir, fmt.Sprintf("orchestrion-jobserver-%d.url", os.Getpid()))

	// Start the orchestrion server process
	cmd := exec.Command(orchestrionPath, "server",
		"-url-file="+urlFile,
		"-inactivity-timeout=30m",
	)
	cmd.Stdout = os.Stderr // Redirect to stderr for debugging
	cmd.Stderr = os.Stderr

	// Set up environment with proper PATH and GOROOT for the server process
	// The server needs access to the go binary to load its configuration
	cmd.Env = os.Environ()
	cacheSpan := beginProbe("orchestrion.start_jobserver.ensure_cache_env")
	cmd.Env, err = ensureGoModuleCacheEnv(cmd.Env, verbose)
	cacheSpan.End(err)
	if err != nil {
		return nil, err
	}
	if goSdkPath != "" {
		absGoSdkPath := goSdkPath
		if !filepath.IsAbs(goSdkPath) {
			if abs, err := filepath.Abs(goSdkPath); err == nil {
				absGoSdkPath = abs
			}
		}
		goBinPath := filepath.Join(absGoSdkPath, "bin")
		cmd.Env = prependToPath(cmd.Env, goBinPath)
		if goRootPath != "" {
			if !filepath.IsAbs(goRootPath) {
				if abs, err := filepath.Abs(goRootPath); err == nil {
					goRootPath = abs
				}
			}
			cmd.Env = setEnv(cmd.Env, "GOROOT", goRootPath)
		} else {
			cmd.Env = setEnv(cmd.Env, "GOROOT", absGoSdkPath)
		}
		// Prevent go from trying to download different toolchains
		cmd.Env = setEnv(cmd.Env, "GOTOOLCHAIN", "local")
		// Disable external package driver
		cmd.Env = setEnv(cmd.Env, "GOPACKAGESDRIVER", "off")

	}
	goRootSpan := beginProbe("orchestrion.start_jobserver.ensure_goroot_compatibility")
	err = ensureGoRootCompatibility(getEnv(cmd.Env, "GOROOT"), goSdkPath, verbose)
	goRootSpan.End(err)
	if err != nil {
		return nil, err
	}
	warmSpan := beginProbe("orchestrion.start_jobserver.warm_woven_packages")
	err = ensureWovenPackagesAvailable(cmd.Env, goSdkPath, verbose)
	warmSpan.End(err)
	if err != nil {
		return nil, fmt.Errorf("warm woven dependencies before jobserver: %w", err)
	}

	startSpan := beginProbe("orchestrion.start_jobserver.spawn")
	err = cmd.Start()
	startSpan.End(err)
	if err != nil {
		return nil, fmt.Errorf("failed to start orchestrion jobserver: %w", err)
	}

	// Wait for the URL file to be created and populated
	waitSpan := beginProbe("orchestrion.start_jobserver.wait_for_url")
	url, err := waitForURLFile(urlFile, jobserverStartTimeout)
	waitSpan.End(err)
	if err != nil {
		// Kill the process if we failed to get the URL
		_ = cmd.Process.Kill()
		_ = os.Remove(urlFile)
		return nil, fmt.Errorf("failed to get orchestrion jobserver URL: %w", err)
	}

	return &orchestrionJobserver{
		url:     url,
		urlFile: urlFile,
		cmd:     cmd,
	}, nil
}

// URL returns the jobserver URL.
func (j *orchestrionJobserver) URL() string {
	if j == nil {
		return ""
	}
	return j.url
}

// cleanup terminates the jobserver and removes the URL file.
func (j *orchestrionJobserver) cleanup() {
	if j == nil {
		return
	}
	if j.cmd != nil && j.cmd.Process != nil {
		_ = j.cmd.Process.Kill()
		_ = j.cmd.Wait() // Reap the process
	}
	if j.urlFile != "" {
		_ = os.Remove(j.urlFile)
	}
}

// waitForURLFile waits for the URL file to be created and contain a valid URL.
func waitForURLFile(path string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil && len(data) > 0 {
			url := strings.TrimSpace(string(data))
			if url != "" {
				return url, nil
			}
		}
		time.Sleep(jobserverPollInterval)
	}

	return "", fmt.Errorf("timeout waiting for orchestrion jobserver URL file: %s", path)
}

// executeCommandWithJobserver runs a command with the orchestrion jobserver URL set
// in the environment if a jobserver is provided. If importPath is non-empty,
// TOOLEXEC_IMPORTPATH is also set (required by orchestrion toolexec).
// If goSdkPath is non-empty, the Go SDK's bin directory is prepended to PATH.
// If goRootPath is non-empty, it is used as GOROOT for the command.
func executeCommandWithJobserver(cmd *exec.Cmd, jobserver *orchestrionJobserver, importPath, goSdkPath, goRootPath string, verbose bool) (err error) {
	span := beginProbe(
		"orchestrion.execute_command_with_jobserver",
		newProbeField("argv0", filepath.Base(cmd.Path)),
		newProbeField("import_path", importPath),
		newProbeField("jobserver", strconv.FormatBool(jobserver != nil && jobserver.URL() != "")),
	)
	defer func() {
		span.End(err)
	}()
	if goSdkPath != "" {
		// Set PATH in the current process so that child processes inherit it
		// This is needed because exec.Command looks up the path using the current process's PATH
		goBinPath := filepath.Join(goSdkPath, "bin")
		currentPath := os.Getenv("PATH")
		newPath := goBinPath + string(os.PathListSeparator) + currentPath
		os.Setenv("PATH", newPath)
		cmd.Env = prependToPath(cmd.Env, goBinPath)
		if goRootPath != "" {
			os.Setenv("GOROOT", goRootPath)
			cmd.Env = setEnv(cmd.Env, "GOROOT", goRootPath)
		} else {
			os.Setenv("GOROOT", goSdkPath)
			cmd.Env = setEnv(cmd.Env, "GOROOT", goSdkPath)
		}
	}

	// Let cmd inherit the modified environment from the current process
	// Don't set cmd.Env explicitly so it uses the process environment
	if cmd.Env == nil {
		cmd.Env = os.Environ()
	}
	cacheSpan := beginProbe("orchestrion.execute_command_with_jobserver.ensure_cache_env")
	cmd.Env, err = ensureGoModuleCacheEnv(cmd.Env, verbose)
	cacheSpan.End(err)
	if err != nil {
		return err
	}
	goRootSpan := beginProbe("orchestrion.execute_command_with_jobserver.ensure_goroot_compatibility")
	err = ensureGoRootCompatibility(getEnv(cmd.Env, "GOROOT"), goSdkPath, verbose)
	goRootSpan.End(err)
	if err != nil {
		return err
	}

	if jobserver != nil && jobserver.URL() != "" {
		cmd.Env = appendEnvIfNotExists(cmd.Env, orchestrionJobserverURLEnvVar, jobserver.URL())
		cmd.Env = appendEnvIfNotExists(cmd.Env, orchestrionSkipPinEnvVar, "true")
		// Disable external package driver to ensure go command is used directly
		cmd.Env = setEnv(cmd.Env, "GOPACKAGESDRIVER", "off")
		// Prevent go from trying to download different toolchains
		cmd.Env = setEnv(cmd.Env, "GOTOOLCHAIN", "local")
		// Force module-aware resolution for Orchestrion's woven dependency lookups.
		// Our explicit `go list -mod=mod` probes succeed in the same sandbox; this
		// keeps the actual toolexec execution on the same resolution mode.
		goFlags := strings.TrimSpace(getEnv(cmd.Env, "GOFLAGS"))
		if !strings.Contains(goFlags, "-mod=") {
			if goFlags == "" {
				goFlags = "-mod=mod"
			} else {
				goFlags = "-mod=mod " + goFlags
			}
			cmd.Env = setEnv(cmd.Env, "GOFLAGS", goFlags)
		}
		// Also ensure GOROOT is set correctly in cmd.Env
		if goRootPath != "" {
			cmd.Env = setEnv(cmd.Env, "GOROOT", goRootPath)
		} else if goSdkPath != "" {
			cmd.Env = setEnv(cmd.Env, "GOROOT", goSdkPath)
		}
	} else {
		cmd.Env = unsetEnv(cmd.Env, orchestrionJobserverURLEnvVar)
		cmd.Env = unsetEnv(cmd.Env, orchestrionSkipPinEnvVar)
	}
	if importPath != "" {
		cmd.Env = setEnv(cmd.Env, toolexecImportPathEnvVar, importPath)
	}
	logLevel := strings.TrimSpace(getEnv(cmd.Env, orchestrionLogLevelEnvVar))
	if logLevel != "" && filepath.Base(cmd.Path) == "orchestrion_bin" {
		hasLogLevel := false
		for _, arg := range cmd.Args[1:] {
			if strings.HasPrefix(arg, "--log-level=") {
				hasLogLevel = true
				break
			}
		}
		if !hasLogLevel {
			cmd.Args = append([]string{cmd.Args[0], "--log-level=" + logLevel}, cmd.Args[1:]...)
		}
	}
	if err := ensureWovenPackagesAvailable(cmd.Env, goSdkPath, verbose); err != nil {
		return fmt.Errorf("ensure woven dependencies available: %w", err)
	}
	runSpan := beginProbe("orchestrion.execute_command_with_jobserver.run")
	err = runAndLogCommand(cmd, verbose)
	runSpan.End(err)
	return err
}

func mustGetwd() string {
	cwd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return cwd
}

// setEnv sets an environment variable, replacing any existing value.
func setEnv(env []string, key, value string) []string {
	if env == nil {
		env = os.Environ()
	}
	prefix := key + "="
	for i, e := range env {
		if strings.HasPrefix(e, prefix) {
			env[i] = prefix + value
			return env
		}
	}
	return append(env, prefix+value)
}

// getEnv returns the value of an environment variable from env, or an empty
// string if the key is not present.
func getEnv(env []string, key string) string {
	if env == nil {
		return ""
	}
	prefix := key + "="
	for _, e := range env {
		if strings.HasPrefix(e, prefix) {
			return strings.TrimPrefix(e, prefix)
		}
	}
	return ""
}

func unsetEnv(env []string, key string) []string {
	if env == nil {
		return nil
	}
	prefix := key + "="
	filtered := env[:0]
	for _, e := range env {
		if strings.HasPrefix(e, prefix) {
			continue
		}
		filtered = append(filtered, e)
	}
	return filtered
}

// prependToPath prepends a directory to the PATH environment variable.
func prependToPath(env []string, dir string) []string {
	if env == nil {
		env = os.Environ()
	}
	for i, e := range env {
		if strings.HasPrefix(e, "PATH=") {
			env[i] = "PATH=" + dir + string(os.PathListSeparator) + e[5:]
			return env
		}
	}
	return append(env, "PATH="+dir)
}

// appendEnvIfNotExists appends key=value to env if key is not already set.
func appendEnvIfNotExists(env []string, key, value string) []string {
	if env == nil {
		env = os.Environ()
	}
	prefix := key + "="
	for _, e := range env {
		if strings.HasPrefix(e, prefix) {
			return env // Already set
		}
	}
	return append(env, prefix+value)
}
