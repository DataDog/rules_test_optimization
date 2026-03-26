package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	validationCacheABIVersion      = "v1"
	syntheticModuleCacheABIVersion = "v1"
	helperDecisionCacheABIVersion  = "v1"
	helperExportCacheABIVersion    = "v2"
	helperArchiveCacheABIVersion   = "v2"
	helperSourceSetVersion         = "v1"
	orchestrionVersionIdentity     = "v1.5.0"

	orchestrionPersistentCacheDirName = "rules-go-orchestrion"

	cacheManifestFileName = "manifest.json"
	cacheReadyFileName    = "ready"

	cacheLockPollInterval = 200 * time.Millisecond
	cacheLockTimeout      = 60 * time.Second
	cacheLockStaleAfter   = 10 * time.Minute
)

type cachePaths struct {
	entryDir     string
	manifestPath string
	readyPath    string
	lockDir      string
}

func orchestrionPersistentCacheRoot(env []string) (string, error) {
	root := filepath.Join(orchestrionDefaultCacheRoot(env), "cache", orchestrionPersistentCacheDirName)
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", fmt.Errorf("prepare orchestrion persistent cache root %s: %w", root, err)
	}
	return root, nil
}

// orchestrionDefaultCacheRoot returns a stable writable cache root that is not
// tied to Bazel's ephemeral output bases. This keeps Orchestrion's module cache
// reusable across local reruns while avoiding accidental dependence on whatever
// GOPATH the user happens to have configured for unrelated work.
func orchestrionDefaultCacheRoot(env []string) string {
	if cacheRoot := strings.TrimSpace(getEnv(env, "GOPATH")); cacheRoot != "" {
		return abs(cacheRoot)
	}
	if cacheDir := strings.TrimSpace(getEnv(env, "XDG_CACHE_HOME")); cacheDir != "" {
		return filepath.Join(abs(cacheDir), orchestrionSharedCacheDirName)
	}
	if cacheDir, err := os.UserCacheDir(); err == nil && strings.TrimSpace(cacheDir) != "" {
		return filepath.Join(abs(cacheDir), orchestrionSharedCacheDirName)
	}
	if home := strings.TrimSpace(getEnv(env, "HOME")); home != "" {
		return filepath.Join(abs(home), ".cache", orchestrionSharedCacheDirName)
	}
	if homeDir, err := os.UserHomeDir(); err == nil && strings.TrimSpace(homeDir) != "" {
		return filepath.Join(abs(homeDir), ".cache", orchestrionSharedCacheDirName)
	}
	return filepath.Join(os.TempDir(), orchestrionSharedCacheDirName)
}

func orchestrionCachePaths(root, namespace, key string) cachePaths {
	entryDir := filepath.Join(abs(root), namespace, key)
	return cachePaths{
		entryDir:     entryDir,
		manifestPath: filepath.Join(entryDir, cacheManifestFileName),
		readyPath:    filepath.Join(entryDir, cacheReadyFileName),
		lockDir:      entryDir + ".lock",
	}
}

func cacheEntryReady(paths cachePaths) bool {
	if _, err := os.Stat(paths.manifestPath); err != nil {
		return false
	}
	if _, err := os.Stat(paths.readyPath); err != nil {
		return false
	}
	return true
}

func acquireCacheLock(lockDir string, timeout, staleAfter time.Duration) (func(), error) {
	return acquireCacheLockWithTimings(lockDir, timeout, staleAfter, cacheLockPollInterval)
}

func acquireCacheLockWithTimings(lockDir string, timeout, staleAfter, pollInterval time.Duration) (func(), error) {
	retryAfterStaleRemoval := true
	for {
		release, err := tryAcquireCacheLock(lockDir)
		if err == nil {
			return release, nil
		}
		if !os.IsExist(err) {
			return nil, fmt.Errorf("acquire cache lock %s: %w", lockDir, err)
		}

		deadline := time.Now().Add(timeout)
		for time.Now().Before(deadline) {
			time.Sleep(pollInterval)
			release, err = tryAcquireCacheLock(lockDir)
			if err == nil {
				return release, nil
			}
			if !os.IsExist(err) {
				return nil, fmt.Errorf("acquire cache lock %s: %w", lockDir, err)
			}
		}

		stale, err := cacheLockIsStale(lockDir, staleAfter)
		if err != nil {
			return nil, fmt.Errorf("inspect cache lock %s: %w", lockDir, err)
		}
		if stale && retryAfterStaleRemoval {
			retryAfterStaleRemoval = false
			if err := os.RemoveAll(lockDir); err != nil && !os.IsNotExist(err) {
				return nil, fmt.Errorf("remove stale cache lock %s: %w", lockDir, err)
			}
			continue
		}
		return nil, fmt.Errorf("timeout acquiring cache lock %s", lockDir)
	}
}

func tryAcquireCacheLock(lockDir string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(lockDir), 0o755); err != nil {
		return nil, err
	}
	if err := os.Mkdir(lockDir, 0o755); err != nil {
		return nil, err
	}
	return func() {
		_ = os.RemoveAll(lockDir)
	}, nil
}

func cacheLockIsStale(lockDir string, staleAfter time.Duration) (bool, error) {
	info, err := os.Stat(lockDir)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	return time.Since(info.ModTime()) >= staleAfter, nil
}

func writeFileAtomically(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tempFile, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tempName := tempFile.Name()
	success := false
	defer func() {
		if !success {
			_ = os.Remove(tempName)
		}
	}()
	if _, err := tempFile.Write(data); err != nil {
		_ = tempFile.Close()
		return err
	}
	if err := tempFile.Chmod(mode); err != nil {
		_ = tempFile.Close()
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempName, path); err != nil {
		return err
	}
	success = true
	return nil
}

func writeJSONAtomically(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return writeFileAtomically(path, data, 0o644)
}

func writeReadySentinel(path string) error {
	return writeFileAtomically(path, []byte("ready\n"), 0o644)
}

func promoteCacheTempDir(tempDir, finalDir string) error {
	if err := os.RemoveAll(finalDir); err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(finalDir), 0o755); err != nil {
		return err
	}
	return os.Rename(tempDir, finalDir)
}

func copyFileIfExists(src, dst string) (bool, error) {
	data, err := os.ReadFile(src)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	return true, writeFileAtomically(dst, data, 0o644)
}

// hardlinkOrCopyFile refreshes dst from src while preferring a hardlink on
// filesystems that support it. The cache directories in this fork treat these
// archives as immutable content-addressed blobs, so linking is safe and avoids
// an extra byte-for-byte copy on the common same-volume path.
func hardlinkOrCopyFile(src, dst string) error {
	if filepath.Clean(src) == filepath.Clean(dst) {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	_ = os.Remove(dst)
	if err := os.Link(src, dst); err == nil {
		return nil
	}
	return copyArchiveFile(src, dst)
}

func digestFileOrMissing(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "missing", nil
		}
		return "", err
	}
	return shortDigest(data), nil
}

// goSDKCacheIdentity returns a stable cache identity for the selected Go SDK
// without depending on Bazel's output-base-specific execroot path. The identity
// is derived from SDK file contents that remain stable across equivalent
// checkouts of the same toolchain.
func goSDKCacheIdentity(sdkPath string) (string, error) {
	if strings.TrimSpace(sdkPath) == "" {
		return "default", nil
	}
	sdkPath = abs(sdkPath)
	versionDigest, err := digestFileOrMissing(filepath.Join(sdkPath, "VERSION"))
	if err != nil {
		return "", err
	}
	buildcfgDigest, err := digestFileOrMissing(filepath.Join(sdkPath, "src", "internal", "buildcfg", "zbootstrap.go"))
	if err != nil {
		return "", err
	}
	return stableDigestParts(
		"version="+versionDigest,
		"buildcfg="+buildcfgDigest,
	), nil
}

func shortDigest(data []byte) string {
	sum := sha256.Sum256(data)
	return fmt.Sprintf("%x", sum[:8])
}

func stableDigestParts(parts ...string) string {
	return shortDigest([]byte(strings.Join(parts, "\n")))
}

func ddTraceVersionsDigest(versions map[string]string) string {
	keys := append([]string{}, ddTraceGoModules...)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, key+"="+strings.TrimSpace(versions[key]))
	}
	return stableDigestParts(parts...)
}

func goTargetIdentity(env []string) string {
	goos := strings.TrimSpace(getEnv(env, "GOOS"))
	if goos == "" {
		goos = runtime.GOOS
	}
	goarch := strings.TrimSpace(getEnv(env, "GOARCH"))
	if goarch == "" {
		goarch = runtime.GOARCH
	}
	return goos + "/" + goarch
}
