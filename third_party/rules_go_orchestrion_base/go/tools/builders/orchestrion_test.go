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
		"go.mod":              syntheticOrchestrionGoMod("v1.6.0", defaultDDTraceGoVersions()),
		"go.sum":              "github.com/DataDog/orchestrion v1.6.0 h1:test\n",
		"orchestrion.tool.go": syntheticOrchestrionToolGo,
	} {
		if err := os.WriteFile(name, []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	gopath := filepath.Join(t.TempDir(), "gopath")
	t.Setenv("GOPATH", gopath)
	t.Setenv(rulesGoOrchestrionToolVersionFileEnvVar, writeOrchestrionToolVersionFile(t, "v1.6.0"))
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, writeDDTraceGoVersionsFile(t, `{"modules":{"github.com/DataDog/dd-trace-go/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/net/http/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/log/slog/v2":"v2.7.3"}}`))

	configuredVersions := defaultDDTraceGoVersions()
	if err := snapshotPreparedSyntheticModule(filepath.Join("/tmp", "sdk"), configuredVersions); err != nil {
		t.Fatalf("snapshotPreparedSyntheticModule error: %v", err)
	}
	for _, name := range []string{"go.mod", "go.sum", "orchestrion.tool.go"} {
		if err := os.Remove(name); err != nil {
			t.Fatalf("remove %s: %v", name, err)
		}
	}
	if err := os.WriteFile("go.mod", []byte(syntheticOrchestrionGoMod("v1.6.0", defaultDDTraceGoVersions())), 0o644); err != nil {
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
