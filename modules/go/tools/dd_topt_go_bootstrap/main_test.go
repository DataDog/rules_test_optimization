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

func TestManagedModuleBlockIncludesRulesGoExtension(t *testing.T) {
	cfg := config{
		orchestrionVersion: "v1.5.0",
		rulesGoRemote:      "https://github.com/example/repo.git",
		rulesGoCommit:      "deadbeef",
	}
	got := managedModuleBlock(cfg)
	if !strings.Contains(got, `git_override(`) {
		t.Fatalf("expected rules_go override in managed block:\n%s", got)
	}
	if !strings.Contains(got, `strip_prefix = "third_party/rules_go_orchestrion"`) {
		t.Fatalf("expected vendored rules_go strip_prefix in managed block:\n%s", got)
	}
	if !strings.Contains(got, `use_extension("@rules_go//go:extensions.bzl", "orchestrion")`) {
		t.Fatalf("expected rules_go orchestrion extension in managed block:\n%s", got)
	}
	if !strings.Contains(got, `orchestrion.from_source(version = "v1.5.0")`) {
		t.Fatalf("expected orchestrion version in managed block:\n%s", got)
	}
	if !strings.Contains(got, `use_repo(orchestrion, "rules_go_orchestrion_tool")`) {
		t.Fatalf("expected rules_go orchestrion repo wiring in managed block:\n%s", got)
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

func TestInferDatadogRepoOverride(t *testing.T) {
	input := `module(name = "example")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "cafebabe",
    strip_prefix = "modules/go",
)
`
	remote, commit := inferDatadogRepoOverride(input)
	if remote != "https://github.com/DataDog/rules_test_optimization.git" {
		t.Fatalf("unexpected remote: %q", remote)
	}
	if commit != "cafebabe" {
		t.Fatalf("unexpected commit: %q", commit)
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

func TestEnsureCIVisibilityOrchestrionImport(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "orchestrion.tool.go")
	original := `package tools

import (
	_ "github.com/DataDog/orchestrion" // integration
	_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2" // integration
)
`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatalf("write orchestrion.tool.go: %v", err)
	}

	cfg := config{goModuleDir: dir}
	if err := ensureCIVisibilityOrchestrionImport(cfg); err != nil {
		t.Fatalf("ensureCIVisibilityOrchestrionImport error: %v", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`) {
		t.Fatalf("expected v2 orchestrion import in orchestrion.tool.go:\n%s", text)
	}
	if strings.Count(text, `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`) != 1 {
		t.Fatalf("expected v2 orchestrion import to be added once:\n%s", text)
	}
}

func TestEnsureCIVisibilityOrchestrionImportNoopWhenPresent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "orchestrion.tool.go")
	original := `package tools

import (
	_ "github.com/DataDog/orchestrion" // integration
	_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration
	_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2" // integration
)
`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatalf("write orchestrion.tool.go: %v", err)
	}

	cfg := config{goModuleDir: dir}
	if err := ensureCIVisibilityOrchestrionImport(cfg); err != nil {
		t.Fatalf("ensureCIVisibilityOrchestrionImport error: %v", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(content)
	if strings.Count(text, `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`) != 1 {
		t.Fatalf("expected v2 orchestrion import to remain single:\n%s", text)
	}
}

func TestEnsureCIVisibilityOrchestrionImportHandlesBlankLinesAroundV2Import(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "orchestrion.tool.go")
	original := `package tools

import (
	_ "github.com/DataDog/orchestrion" // integration

	_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration

	_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2" // integration
)
`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatalf("write orchestrion.tool.go: %v", err)
	}

	cfg := config{goModuleDir: dir}
	if err := ensureCIVisibilityOrchestrionImport(cfg); err != nil {
		t.Fatalf("ensureCIVisibilityOrchestrionImport error: %v", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`) {
		t.Fatalf("expected v2 orchestrion import in orchestrion.tool.go:\n%s", text)
	}
}

func TestEnsureCIVisibilityOrchestrionImportRemovesLegacyV1Import(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "orchestrion.tool.go")
	original := `package tools

import (
	_ "github.com/DataDog/orchestrion" // integration
	_ "gopkg.in/DataDog/dd-trace-go.v1/civisibility" // integration
	_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2" // integration
)
`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatalf("write orchestrion.tool.go: %v", err)
	}

	cfg := config{goModuleDir: dir}
	if err := ensureCIVisibilityOrchestrionImport(cfg); err != nil {
		t.Fatalf("ensureCIVisibilityOrchestrionImport error: %v", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(content)
	if strings.Contains(text, `_ "gopkg.in/DataDog/dd-trace-go.v1/civisibility" // integration`) {
		t.Fatalf("expected legacy v1 import to be removed:\n%s", text)
	}
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`) {
		t.Fatalf("expected v2 orchestrion import after legacy cleanup:\n%s", text)
	}
}
