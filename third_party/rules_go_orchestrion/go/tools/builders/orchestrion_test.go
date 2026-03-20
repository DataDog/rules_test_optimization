package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPreparedSyntheticModuleSnapshotAndRestore(t *testing.T) {
	workDir := t.TempDir()
	previousWD, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(workDir); err != nil {
		t.Fatalf("chdir workdir: %v", err)
	}
	defer func() {
		_ = os.Chdir(previousWD)
	}()

	for name, content := range map[string]string{
		"go.mod":              syntheticOrchestrionGoMod(defaultDDTraceGoVersions()),
		"go.sum":              "github.com/DataDog/orchestrion v1.5.0 h1:test\n",
		"orchestrion.tool.go": syntheticOrchestrionToolGo,
	} {
		if err := os.WriteFile(name, []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	gopath := filepath.Join(t.TempDir(), "gopath")
	t.Setenv("GOPATH", gopath)

	configuredVersions := defaultDDTraceGoVersions()
	if err := snapshotPreparedSyntheticModule(filepath.Join("/tmp", "sdk"), configuredVersions); err != nil {
		t.Fatalf("snapshotPreparedSyntheticModule error: %v", err)
	}
	for _, name := range []string{"go.mod", "go.sum", "orchestrion.tool.go"} {
		if err := os.Remove(name); err != nil {
			t.Fatalf("remove %s: %v", name, err)
		}
	}
	if err := os.WriteFile("go.mod", []byte(syntheticOrchestrionGoMod(defaultDDTraceGoVersions())), 0o644); err != nil {
		t.Fatalf("rewrite go.mod: %v", err)
	}
	if err := os.WriteFile("orchestrion.tool.go", []byte(syntheticOrchestrionToolGo), 0o644); err != nil {
		t.Fatalf("rewrite orchestrion.tool.go: %v", err)
	}
	hit, err := restorePreparedSyntheticModule(filepath.Join("/tmp", "sdk"), configuredVersions, false)
	if err != nil {
		t.Fatalf("restorePreparedSyntheticModule error: %v", err)
	}
	if !hit {
		t.Fatal("restorePreparedSyntheticModule should hit cache after snapshot")
	}
	for _, name := range []string{"go.mod", "go.sum", "orchestrion.tool.go"} {
		if _, err := os.Stat(name); err != nil {
			t.Fatalf("expected restored file %s: %v", name, err)
		}
	}
}
