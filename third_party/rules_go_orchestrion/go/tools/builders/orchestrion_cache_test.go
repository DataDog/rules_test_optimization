package main

import (
	"os"
	"path/filepath"
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
