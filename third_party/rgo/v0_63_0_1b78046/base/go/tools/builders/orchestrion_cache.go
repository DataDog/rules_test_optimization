package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	validationCacheABIVersion = "v2"
	// Bump the synthetic module cache ABI whenever the bootstrap preparation
	// logic changes. The prepared cache snapshot only keys off the copied module
	// files plus selected toolchain metadata, so code-only changes would
	// otherwise keep restoring stale synthetic go.mod state.
	syntheticModuleCacheABIVersion = "v5"
	helperDecisionCacheABIVersion  = "v8"
	helperExportCacheABIVersion    = "v7"
	helperArchiveCacheABIVersion   = "v12"
	// Bump the helper source-set version whenever the synthetic testmain source
	// compile closure changes. The helper decision and archive caches both key
	// off this value, so closure changes must force a rebuild instead of reusing
	// bundles prepared for the older package selection.
	helperSourceSetVersion = "v7"

	orchestrionPersistentCacheDirName = "rules-go-orchestrion"

	cacheManifestFileName = "manifest.json"
	cacheReadyFileName    = "ready"
	cacheLockOwnerPrefix  = "owner-"
	cacheLockClaimPrefix  = "claim-"

	cacheLockPollInterval = 200 * time.Millisecond
	// Cold shared-cache preparation can take several minutes. Keep contention
	// bounded without abandoning a healthy owner during that work.
	cacheLockTimeout    = 20 * time.Minute
	cacheLockStaleAfter = 10 * time.Minute
)

type cachePaths struct {
	entryDir     string
	manifestPath string
	readyPath    string
	lockDir      string
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
	deadline := time.Now().Add(timeout)
	for {
		release, err := tryAcquireCacheLock(lockDir, staleAfter)
		if err == nil {
			return release, nil
		}
		if !os.IsExist(err) {
			return nil, fmt.Errorf("acquire cache lock %s: %w", lockDir, err)
		}
		if !time.Now().Before(deadline) {
			return nil, fmt.Errorf("timeout acquiring cache lock %s", lockDir)
		}

		snapshot, stale, err := inspectCacheLock(lockDir, staleAfter)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, fmt.Errorf("inspect cache lock %s: %w", lockDir, err)
		}
		if stale {
			removed, err := removeStaleCacheLock(lockDir, snapshot, staleAfter)
			if err != nil && !os.IsNotExist(err) {
				return nil, fmt.Errorf("remove stale cache lock %s: %w", lockDir, err)
			}
			if removed {
				continue
			}
		}

		wait := time.Until(deadline)
		if wait > pollInterval {
			wait = pollInterval
		}
		if wait > 0 {
			time.Sleep(wait)
		}
	}
}

func tryAcquireCacheLock(lockDir string, staleAfter time.Duration) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(lockDir), 0o755); err != nil {
		return nil, err
	}
	if err := os.Mkdir(lockDir, 0o755); err != nil {
		return nil, err
	}
	token, err := cacheLockToken()
	if err != nil {
		_ = os.Remove(lockDir)
		return nil, err
	}
	ownerPath := filepath.Join(lockDir, cacheLockOwnerPrefix+token)
	if err := os.WriteFile(ownerPath, []byte(token+"\n"), 0o600); err != nil {
		_ = os.Remove(lockDir)
		return nil, err
	}
	stopHeartbeat := make(chan struct{})
	heartbeatDone := make(chan struct{})
	go maintainCacheLockHeartbeat(lockDir, ownerPath, staleAfter, stopHeartbeat, heartbeatDone)
	released := false
	return func() {
		if released {
			return
		}
		released = true
		close(stopHeartbeat)
		<-heartbeatDone
		if err := os.Remove(ownerPath); err != nil {
			return
		}
		_ = os.Remove(lockDir)
	}, nil
}

func cacheLockToken() (string, error) {
	var data [16]byte
	if _, err := rand.Read(data[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(data[:]), nil
}

func maintainCacheLockHeartbeat(lockDir, ownerPath string, staleAfter time.Duration, stop <-chan struct{}, done chan<- struct{}) {
	defer close(done)
	interval := staleAfter / 4
	if interval < time.Millisecond {
		interval = time.Millisecond
	}
	if interval > time.Minute {
		interval = time.Minute
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case now := <-ticker.C:
			if err := os.Chtimes(ownerPath, now, now); err != nil {
				return
			}
			if err := os.Chtimes(lockDir, now, now); err != nil {
				return
			}
		}
	}
}

type cacheLockSnapshot struct {
	dirModTime   time.Time
	ownerName    string
	ownerModTime time.Time
}

func inspectCacheLock(lockDir string, staleAfter time.Duration) (cacheLockSnapshot, bool, error) {
	dirInfo, err := os.Stat(lockDir)
	if err != nil {
		return cacheLockSnapshot{}, false, err
	}
	snapshot := cacheLockSnapshot{dirModTime: dirInfo.ModTime()}
	entries, err := os.ReadDir(lockDir)
	if err != nil {
		return cacheLockSnapshot{}, false, err
	}
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), cacheLockOwnerPrefix) {
			continue
		}
		if snapshot.ownerName != "" {
			return cacheLockSnapshot{}, false, fmt.Errorf("multiple cache lock owners under %s", lockDir)
		}
		info, err := entry.Info()
		if err != nil {
			return cacheLockSnapshot{}, false, err
		}
		snapshot.ownerName = entry.Name()
		snapshot.ownerModTime = info.ModTime()
	}
	heartbeat := snapshot.dirModTime
	if snapshot.ownerModTime.After(heartbeat) {
		heartbeat = snapshot.ownerModTime
	}
	return snapshot, time.Since(heartbeat) >= staleAfter, nil
}

func sameCacheLockSnapshot(left, right cacheLockSnapshot) bool {
	return left.ownerName == right.ownerName &&
		left.dirModTime.Equal(right.dirModTime) &&
		left.ownerModTime.Equal(right.ownerModTime)
}

// removeStaleCacheLock claims the observed owner marker before retiring its
// lock. Renaming that exact marker makes a concurrent heartbeat visible and
// keeps a replacement owner out of scope.
func removeStaleCacheLock(lockDir string, expected cacheLockSnapshot, staleAfter time.Duration) (bool, error) {
	current, stale, err := inspectCacheLock(lockDir, staleAfter)
	if err != nil {
		return false, err
	}
	if !stale || !sameCacheLockSnapshot(current, expected) {
		return false, nil
	}

	token, err := cacheLockToken()
	if err != nil {
		return false, err
	}
	claimedOwnerPath := ""
	ownerPath := ""
	if current.ownerName != "" {
		ownerPath = filepath.Join(lockDir, current.ownerName)
		claimedOwnerPath = filepath.Join(lockDir, cacheLockClaimPrefix+token)
		if err := os.Rename(ownerPath, claimedOwnerPath); err != nil {
			return false, err
		}
		claimedInfo, err := os.Stat(claimedOwnerPath)
		if err != nil {
			_ = os.Rename(claimedOwnerPath, ownerPath)
			return false, err
		}
		if !claimedInfo.ModTime().Equal(current.ownerModTime) || time.Since(claimedInfo.ModTime()) < staleAfter {
			if err := os.Rename(claimedOwnerPath, ownerPath); err != nil {
				return false, fmt.Errorf("restore renewed cache lock owner: %w", err)
			}
			return false, nil
		}
	}

	staleDir := lockDir + ".stale-" + token
	if err := os.Rename(lockDir, staleDir); err != nil {
		if claimedOwnerPath != "" {
			_ = os.Rename(claimedOwnerPath, ownerPath)
		}
		return false, err
	}
	if err := os.RemoveAll(staleDir); err != nil {
		return false, err
	}
	return true, nil
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

// hardlinkOrCopyFile refreshes dst from src. The helper keeps the old name
// because multiple cache-seeding paths share it, but it intentionally uses a
// plain copy so later cache warmup steps can rewrite destination files without
// inheriting read-only permissions or link relationships from Go's cache.
func hardlinkOrCopyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	_ = os.Remove(dst)
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

func fullDigestFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return fmt.Sprintf("%x", sum[:]), nil
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

func ddTraceVersionsDigest(versions map[string]string, orchestrionMode string) string {
	keys := ddTraceGoModulesForMode(orchestrionMode)
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
