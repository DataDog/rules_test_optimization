package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestModuleExportRequestKeyIncludesStdlibCacheState(t *testing.T) {
	moduleDir := t.TempDir()
	for _, name := range []string{"go.mod", "orchestrion.tool.go", "orchestrion.yml"} {
		if err := os.WriteFile(filepath.Join(moduleDir, name), []byte(name+"\n"), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	cacheDir := filepath.Join(t.TempDir(), "gocache")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatalf("mkdir cache: %v", err)
	}
	testingArchiveV1 := filepath.Join(cacheDir, "aa", "testing-v1-d")
	if err := os.MkdirAll(filepath.Dir(testingArchiveV1), 0o755); err != nil {
		t.Fatalf("mkdir testing archive dir: %v", err)
	}
	if err := os.WriteFile(testingArchiveV1, []byte("testing-v1"), 0o644); err != nil {
		t.Fatalf("write testing archive v1: %v", err)
	}
	manifestPath := filepath.Join(cacheDir, orchestrionStdlibCacheManifestName)
	manifestV1 := "testing=aa/testing-v1-d\nruntime=aa/testing-v1-d\nfmt=aa/testing-v1-d\nflag=aa/testing-v1-d\nlog=aa/testing-v1-d\n"
	if err := os.WriteFile(manifestPath, []byte(manifestV1), 0o644); err != nil {
		t.Fatalf("write manifest v1: %v", err)
	}

	goenv := &env{stdlibCache: cacheDir}
	keyV1, err := moduleExportRequestKey(moduleDir, goenv)
	if err != nil {
		t.Fatalf("moduleExportRequestKey v1 error: %v", err)
	}

	testingArchiveV2 := filepath.Join(cacheDir, "bb", "testing-v2-d")
	if err := os.MkdirAll(filepath.Dir(testingArchiveV2), 0o755); err != nil {
		t.Fatalf("mkdir testing archive dir v2: %v", err)
	}
	if err := os.WriteFile(testingArchiveV2, []byte("testing-v2"), 0o644); err != nil {
		t.Fatalf("write testing archive v2: %v", err)
	}
	manifestV2 := "testing=bb/testing-v2-d\nruntime=bb/testing-v2-d\nfmt=bb/testing-v2-d\nflag=bb/testing-v2-d\nlog=bb/testing-v2-d\n"
	if err := os.WriteFile(manifestPath, []byte(manifestV2), 0o644); err != nil {
		t.Fatalf("write manifest v2: %v", err)
	}

	keyV2, err := moduleExportRequestKey(moduleDir, goenv)
	if err != nil {
		t.Fatalf("moduleExportRequestKey v2 error: %v", err)
	}
	if keyV1 == keyV2 {
		t.Fatalf("moduleExportRequestKey did not change when stdlib cache changed: %q", keyV1)
	}
}
