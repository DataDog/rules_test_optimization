package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInsertAfterModuleDecl(t *testing.T) {
	input := "module(name = \"example\")\n"
	got, err := insertAfterModuleDecl(input, "bazel_dep(name = \"rules_go\", version = \"0.59.0\")\n")
	if err != nil {
		t.Fatalf("insertAfterModuleDecl error: %v", err)
	}
	if !strings.Contains(got, "bazel_dep(name = \"rules_go\", version = \"0.59.0\")") {
		t.Fatalf("expected rules_go bazel_dep in output:\n%s", got)
	}
}

func TestReplaceManagedBlockAppendsWhenMissing(t *testing.T) {
	input := "module(name = \"example\")\n"
	got, err := replaceManagedBlock(input, managedBlockStart+"\nfoo\n"+managedBlockEnd+"\n")
	if err != nil {
		t.Fatalf("replaceManagedBlock error: %v", err)
	}
	if !strings.Contains(got, managedBlockStart) || !strings.Contains(got, "foo") {
		t.Fatalf("expected managed block in output:\n%s", got)
	}
}

func TestReplaceManagedBlockRejectsConflictingOverride(t *testing.T) {
	input := `module(name = "example")
git_override(
    module_name = "rules_go",
    remote = "https://example.com/custom.git",
    commit = "deadbeef",
)
`
	if _, err := replaceManagedBlock(input, managedBlockStart+"\nfoo\n"+managedBlockEnd+"\n"); err == nil {
		t.Fatal("expected conflicting rules_go override to fail")
	}
}

func TestWriteStarterOrchestrionYML(t *testing.T) {
	dir := t.TempDir()
	cfg := config{goModuleDir: dir}
	if err := writeStarterOrchestrionYML(cfg); err != nil {
		t.Fatalf("writeStarterOrchestrionYML error: %v", err)
	}
	path := filepath.Join(dir, "orchestrion.yml")
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read orchestrion.yml: %v", err)
	}
	if !strings.Contains(string(content), "aspects: []") {
		t.Fatalf("unexpected orchestrion.yml content:\n%s", string(content))
	}
}
