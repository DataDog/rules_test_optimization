package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCacheEntryReadyRequiresManifestAndReady(t *testing.T) {
	root := t.TempDir()
	paths := orchestrionCachePaths(root, "validation", "abc123")
	if cacheEntryReady(paths) {
		t.Fatal("cache entry should not be ready without files")
	}
	if err := os.MkdirAll(paths.entryDir, 0o755); err != nil {
		t.Fatalf("mkdir entry dir: %v", err)
	}
	if err := os.WriteFile(paths.manifestPath, []byte("{}\n"), 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	if cacheEntryReady(paths) {
		t.Fatal("cache entry should not be ready without ready sentinel")
	}
	if err := os.WriteFile(paths.readyPath, []byte("ready\n"), 0o644); err != nil {
		t.Fatalf("write ready: %v", err)
	}
	if !cacheEntryReady(paths) {
		t.Fatal("cache entry should be ready once manifest and ready exist")
	}
}

func TestDDTraceVersionsDigestUsesEffectiveModeModules(t *testing.T) {
	baseVersions := map[string]string{
		"github.com/DataDog/dd-trace-go/v2":                  "v2.7.0",
		"github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.8.0",
		"github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.8.0",
	}
	contribChanged := map[string]string{
		"github.com/DataDog/dd-trace-go/v2":                  "v2.7.0",
		"github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.9.0",
		"github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.9.0",
	}
	rootChanged := map[string]string{
		"github.com/DataDog/dd-trace-go/v2":                  "v2.7.1",
		"github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.8.0",
		"github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.8.0",
	}

	if ddTraceVersionsDigest(baseVersions, orchestrionModeGeneral) == ddTraceVersionsDigest(contribChanged, orchestrionModeGeneral) {
		t.Fatal("general mode digest should include contrib module versions")
	}
	if ddTraceVersionsDigest(baseVersions, orchestrionModeTestOptimization) != ddTraceVersionsDigest(contribChanged, orchestrionModeTestOptimization) {
		t.Fatal("test_optimization digest should ignore unused contrib module versions")
	}
	if ddTraceVersionsDigest(baseVersions, orchestrionModeGeneral) == ddTraceVersionsDigest(rootChanged, orchestrionModeGeneral) {
		t.Fatal("general mode digest should include the root tracer module version")
	}
	if ddTraceVersionsDigest(baseVersions, orchestrionModeTestOptimization) == ddTraceVersionsDigest(rootChanged, orchestrionModeTestOptimization) {
		t.Fatal("test_optimization digest should include the root tracer module version")
	}
}

func TestAcquireCacheLockReplacesStaleLock(t *testing.T) {
	lockDir := filepath.Join(t.TempDir(), "cache.lock")
	if err := os.MkdirAll(lockDir, 0o755); err != nil {
		t.Fatalf("mkdir stale lock: %v", err)
	}
	staleTime := time.Now().Add(-2 * time.Minute)
	if err := os.Chtimes(lockDir, staleTime, staleTime); err != nil {
		t.Fatalf("chtimes stale lock: %v", err)
	}

	release, err := acquireCacheLockWithTimings(lockDir, 20*time.Millisecond, time.Minute, 5*time.Millisecond)
	if err != nil {
		t.Fatalf("acquireCacheLockWithTimings error: %v", err)
	}
	if _, err := os.Stat(lockDir); err != nil {
		t.Fatalf("expected lock dir to exist after acquisition: %v", err)
	}
	release()
	if _, err := os.Stat(lockDir); !os.IsNotExist(err) {
		t.Fatalf("expected release to remove lock dir, stat err=%v", err)
	}
}

func TestAcquireCacheLockWaitsForActiveOwnerWithinTimeout(t *testing.T) {
	lockDir := filepath.Join(t.TempDir(), "cache.lock")
	releaseOwner, err := tryAcquireCacheLock(lockDir, 20*time.Millisecond)
	if err != nil {
		t.Fatalf("acquire owner lock: %v", err)
	}
	go func() {
		time.Sleep(50 * time.Millisecond)
		releaseOwner()
	}()

	releaseWaiter, err := acquireCacheLockWithTimings(lockDir, 2*time.Second, 20*time.Millisecond, 2*time.Millisecond)
	if err != nil {
		t.Fatalf("wait for active owner: %v", err)
	}
	releaseWaiter()
}

func TestAcquireCacheLockTimesOutWithoutStealingActiveOwner(t *testing.T) {
	lockDir := filepath.Join(t.TempDir(), "cache.lock")
	releaseOwner, err := tryAcquireCacheLock(lockDir, 20*time.Millisecond)
	if err != nil {
		t.Fatalf("acquire owner lock: %v", err)
	}
	defer releaseOwner()

	started := time.Now()
	_, err = acquireCacheLockWithTimings(lockDir, 100*time.Millisecond, 20*time.Millisecond, 2*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "timeout acquiring cache lock") {
		t.Fatalf("wait for active owner error = %v, want timeout", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("wait for active owner took %s, want a bounded wait", elapsed)
	}
	if _, err := os.Stat(lockDir); err != nil {
		t.Fatalf("waiter removed the active owner's lock: %v", err)
	}
}

func TestRemoveStaleCacheLockPreservesRenewedOwner(t *testing.T) {
	lockDir := filepath.Join(t.TempDir(), "cache.lock")
	releaseOwner, err := tryAcquireCacheLock(lockDir, time.Hour)
	if err != nil {
		t.Fatalf("acquire owner lock: %v", err)
	}
	defer releaseOwner()

	staleAfter := time.Minute
	staleTime := time.Now().Add(-2 * staleAfter)
	entries, err := os.ReadDir(lockDir)
	if err != nil {
		t.Fatal(err)
	}
	ownerPath := filepath.Join(lockDir, entries[0].Name())
	if err := os.Chtimes(ownerPath, staleTime, staleTime); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(lockDir, staleTime, staleTime); err != nil {
		t.Fatal(err)
	}
	snapshot, stale, err := inspectCacheLock(lockDir, staleAfter)
	if err != nil || !stale {
		t.Fatalf("inspect stale lock: stale=%v err=%v", stale, err)
	}

	now := time.Now()
	if err := os.Chtimes(ownerPath, now, now); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(lockDir, now, now); err != nil {
		t.Fatal(err)
	}
	removed, err := removeStaleCacheLock(lockDir, snapshot, staleAfter)
	if err != nil {
		t.Fatal(err)
	}
	if removed {
		t.Fatal("removed a lock renewed after inspection")
	}
	if _, err := os.Stat(ownerPath); err != nil {
		t.Fatalf("renewed owner marker was removed: %v", err)
	}
}

func TestRemoveStaleCacheLockPreservesReplacementOwner(t *testing.T) {
	lockDir := filepath.Join(t.TempDir(), "cache.lock")
	releaseOld, err := tryAcquireCacheLock(lockDir, time.Hour)
	if err != nil {
		t.Fatalf("acquire old lock: %v", err)
	}
	staleAfter := time.Minute
	staleTime := time.Now().Add(-2 * staleAfter)
	entries, err := os.ReadDir(lockDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(filepath.Join(lockDir, entries[0].Name()), staleTime, staleTime); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(lockDir, staleTime, staleTime); err != nil {
		t.Fatal(err)
	}
	snapshot, stale, err := inspectCacheLock(lockDir, staleAfter)
	if err != nil || !stale {
		t.Fatalf("inspect stale lock: stale=%v err=%v", stale, err)
	}
	releaseOld()

	releaseReplacement, err := tryAcquireCacheLock(lockDir, time.Hour)
	if err != nil {
		t.Fatalf("acquire replacement lock: %v", err)
	}
	defer releaseReplacement()
	removed, err := removeStaleCacheLock(lockDir, snapshot, staleAfter)
	if err != nil {
		t.Fatal(err)
	}
	if removed {
		t.Fatal("removed a replacement lock")
	}
	if _, err := os.Stat(lockDir); err != nil {
		t.Fatalf("replacement lock was removed: %v", err)
	}
}

func TestOldCacheLockReleaseDoesNotRemoveReplacementOwner(t *testing.T) {
	root := t.TempDir()
	lockDir := filepath.Join(root, "cache.lock")
	releaseOld, err := tryAcquireCacheLock(lockDir, time.Minute)
	if err != nil {
		t.Fatalf("acquire old lock: %v", err)
	}
	abandonedDir := filepath.Join(root, "abandoned.lock")
	if err := os.Rename(lockDir, abandonedDir); err != nil {
		t.Fatalf("rename old lock: %v", err)
	}
	releaseReplacement, err := tryAcquireCacheLock(lockDir, time.Minute)
	if err != nil {
		t.Fatalf("acquire replacement lock: %v", err)
	}
	releaseOld()
	if _, err := os.Stat(lockDir); err != nil {
		t.Fatalf("old release removed replacement lock: %v", err)
	}
	releaseReplacement()
}

func TestWriteFileAtomically(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "manifest.json")
	if err := writeFileAtomically(path, []byte("payload\n"), 0o644); err != nil {
		t.Fatalf("writeFileAtomically error: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read atomic file: %v", err)
	}
	if string(data) != "payload\n" {
		t.Fatalf("writeFileAtomically wrote %q", string(data))
	}
}
