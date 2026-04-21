package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const (
	// rulesGoOrchestrionModuleProxyRootEnvVar points at the declared offline Go
	// module proxy root staged by the Orchestrion tool repository.
	rulesGoOrchestrionModuleProxyRootEnvVar = "RULES_GO_ORCHESTRION_MODULE_PROXY_ROOT"
)

var legacyModuleProxyFallbackWarningOnce sync.Once

// moduleProxyFileURL converts a filesystem path into the file:// URL syntax
// accepted by GOPROXY.
func moduleProxyFileURL(path string) (string, error) {
	cleanedPath := strings.TrimSpace(path)
	if cleanedPath == "" {
		return "", fmt.Errorf("module proxy path is empty")
	}
	if isWindowsAbsolutePath(cleanedPath) {
		return "file:///" + strings.ReplaceAll(cleanedPath, "\\", "/"), nil
	}
	absolutePath, err := filepath.Abs(cleanedPath)
	if err != nil {
		return "", fmt.Errorf("absolutize module proxy path %s: %w", cleanedPath, err)
	}
	slashPath := filepath.ToSlash(absolutePath)
	if !strings.HasPrefix(slashPath, "/") {
		slashPath = "/" + slashPath
	}
	return "file://" + slashPath, nil
}

// normalizeGoModuleResolutionEnv applies the Go module-resolution defaults used
// by Orchestrion subprocesses. When the offline proxy is present, it becomes
// the sole module source for action-time module operations.
func normalizeGoModuleResolutionEnv(env []string) ([]string, error) {
	moduleProxyRoot := strings.TrimSpace(getEnv(env, rulesGoOrchestrionModuleProxyRootEnvVar))
	if moduleProxyRoot != "" {
		proxyURL, err := moduleProxyFileURL(moduleProxyRoot)
		if err != nil {
			return nil, err
		}
		env = setEnv(env, "GOPROXY", proxyURL)
		env = setEnv(env, "GOSUMDB", "off")
		env = setEnv(env, "GOPRIVATE", "")
		env = setEnv(env, "GONOPROXY", "")
		env = setEnv(env, "GONOSUMDB", "")
		return env, nil
	}

	maybeWarnLegacyModuleProxyFallback(env)

	if strings.TrimSpace(getEnv(env, "GOPROXY")) == "" {
		env = setEnv(env, "GOPROXY", "https://proxy.golang.org,direct")
	}
	if strings.TrimSpace(getEnv(env, "GOSUMDB")) == "" {
		env = setEnv(env, "GOSUMDB", "sum.golang.org")
	}
	return env, nil
}

// normalizeGoActionCacheEnv ensures Orchestrion subprocesses have writable Go
// caches without defaulting into persistent user-cache locations.
func normalizeGoActionCacheEnv(env []string) ([]string, error) {
	goPath := strings.TrimSpace(getEnv(env, "GOPATH"))
	if goPath == "" {
		goPath = filepath.Join(os.TempDir(), orchestrionSharedCacheDirName, "gopath")
	}

	goModCache := strings.TrimSpace(getEnv(env, "GOMODCACHE"))
	if goModCache == "" {
		goModCache = filepath.Join(goPath, "pkg", "mod")
	}

	goBuildCache := strings.TrimSpace(getEnv(env, "GOCACHE"))
	if goBuildCache == "" {
		goBuildCache = filepath.Join(goPath, "cache")
	}

	for _, dir := range []string{goPath, goModCache, goBuildCache} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("prepare orchestrion go cache dir %s: %w", dir, err)
		}
	}

	env = setEnv(env, "GOPATH", goPath)
	env = setEnv(env, "GOMODCACHE", goModCache)
	env = setEnv(env, "GOCACHE", goBuildCache)
	return env, nil
}

// orchestrionActionCacheRoot returns the action-local cache root used by the
// builder-owned Orchestrion caches.
func orchestrionActionCacheRoot(env []string) (string, error) {
	if goPath := strings.TrimSpace(getEnv(env, "GOPATH")); goPath != "" {
		return filepath.Join(filepath.Clean(goPath), "cache", orchestrionPersistentCacheDirName), nil
	}
	return filepath.Join(os.TempDir(), orchestrionSharedCacheDirName, "cache", orchestrionPersistentCacheDirName), nil
}

// isWindowsAbsolutePath reports whether a path uses a Windows drive-prefix
// absolute form so tests can validate URL formatting on any host platform.
func isWindowsAbsolutePath(path string) bool {
	if len(path) < 3 {
		return false
	}
	drive := path[0]
	if !((drive >= 'a' && drive <= 'z') || (drive >= 'A' && drive <= 'Z')) {
		return false
	}
	if path[1] != ':' {
		return false
	}
	return path[2] == '\\' || path[2] == '/'
}

// maybeWarnLegacyModuleProxyFallback emits a single actionable warning when an
// Orchestrion action falls back to the legacy online module-resolution path.
func maybeWarnLegacyModuleProxyFallback(env []string) {
	if strings.TrimSpace(getEnv(env, rulesGoOrchestrionVersionFileEnvVar)) == "" {
		return
	}
	legacyModuleProxyFallbackWarningOnce.Do(func() {
		fmt.Fprintf(os.Stderr, "orchestrion: offline module proxy artifacts are missing; falling back to the legacy online module-resolution path. Rerun 'bazel sync --only=rules_go_orchestrion_tool --repo_env=FETCH_SALT=$(date +%%s)' to regenerate the tool repo.\n")
	})
}
