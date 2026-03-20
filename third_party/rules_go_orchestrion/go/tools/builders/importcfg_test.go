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

func TestModuleExportRequestKeyIgnoresSyntheticTempDir(t *testing.T) {
	moduleDirs := []string{
		filepath.Join(t.TempDir(), "one"),
		filepath.Join(t.TempDir(), "two"),
	}
	for _, moduleDir := range moduleDirs {
		if err := os.MkdirAll(moduleDir, 0o755); err != nil {
			t.Fatalf("mkdir module dir: %v", err)
		}
		for name, content := range map[string]string{
			"go.mod":              syntheticOrchestrionGoMod(defaultDDTraceGoVersions()),
			"orchestrion.tool.go": syntheticOrchestrionToolGo,
			"orchestrion.yml":     "injectors: []\n",
		} {
			if err := os.WriteFile(filepath.Join(moduleDir, name), []byte(content), 0o644); err != nil {
				t.Fatalf("write %s: %v", name, err)
			}
		}
	}
	goenv := &env{}
	key1, err := moduleExportRequestKey(moduleDirs[0], goenv)
	if err != nil {
		t.Fatalf("moduleExportRequestKey dir1 error: %v", err)
	}
	key2, err := moduleExportRequestKey(moduleDirs[1], goenv)
	if err != nil {
		t.Fatalf("moduleExportRequestKey dir2 error: %v", err)
	}
	if key1 != key2 {
		t.Fatalf("synthetic module export key mismatch: %q != %q", key1, key2)
	}
}

func TestSeedWovenStdlibCacheNoopWhenAlreadyReady(t *testing.T) {
	sourceRoot := filepath.Join(t.TempDir(), "source")
	destRoot := filepath.Join(t.TempDir(), "dest")
	for _, root := range []string{sourceRoot, destRoot} {
		if err := os.MkdirAll(root, 0o755); err != nil {
			t.Fatalf("mkdir root: %v", err)
		}
	}
	sourceArchive := filepath.Join(sourceRoot, "aa", "testing.a")
	if err := os.MkdirAll(filepath.Dir(sourceArchive), 0o755); err != nil {
		t.Fatalf("mkdir source archive dir: %v", err)
	}
	if err := os.WriteFile(sourceArchive, []byte("source"), 0o644); err != nil {
		t.Fatalf("write source archive: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sourceRoot, orchestrionStdlibCacheManifestName), []byte("testing=aa/testing.a\n"), 0o644); err != nil {
		t.Fatalf("write source manifest: %v", err)
	}
	destArchive := filepath.Join(destRoot, "bb", "testing.a")
	if err := os.MkdirAll(filepath.Dir(destArchive), 0o755); err != nil {
		t.Fatalf("mkdir dest archive dir: %v", err)
	}
	if err := os.WriteFile(destArchive, []byte("dest"), 0o644); err != nil {
		t.Fatalf("write dest archive: %v", err)
	}
	manifestPath := filepath.Join(destRoot, orchestrionStdlibCacheManifestName)
	if err := os.WriteFile(manifestPath, []byte("testing=bb/testing.a\n"), 0o644); err != nil {
		t.Fatalf("write dest manifest: %v", err)
	}
	before, err := os.ReadFile(destArchive)
	if err != nil {
		t.Fatalf("read dest archive before seed: %v", err)
	}
	if err := seedWovenStdlibCache(&env{stdlibCache: sourceRoot}, destRoot); err != nil {
		t.Fatalf("seedWovenStdlibCache error: %v", err)
	}
	after, err := os.ReadFile(destArchive)
	if err != nil {
		t.Fatalf("read dest archive after seed: %v", err)
	}
	if string(before) != string(after) {
		t.Fatalf("seedWovenStdlibCache rewrote ready archive: before=%q after=%q", string(before), string(after))
	}
}
