package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnsureSyntheticOrchestrionToolGoCreatesExpectedContents(t *testing.T) {
	workDir := t.TempDir()
	previousWD, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(workDir); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	defer func() {
		_ = os.Chdir(previousWD)
	}()

	cleanup, err := ensureSyntheticOrchestrionToolGo(false)
	if err != nil {
		t.Fatalf("ensureSyntheticOrchestrionToolGo error: %v", err)
	}
	defer cleanup()

	content, err := os.ReadFile("orchestrion.tool.go")
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(content)
	for _, needle := range []string{
		"//go:build tools",
		`_ "github.com/DataDog/orchestrion"`,
		`_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2"`,
		`_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2"`,
		`_ "github.com/DataDog/dd-trace-go/v2/orchestrion"`,
	} {
		if !strings.Contains(text, needle) {
			t.Fatalf("orchestrion.tool.go missing %q:\n%s", needle, text)
		}
	}

	cleanup()
	if _, err := os.Stat("orchestrion.tool.go"); !os.IsNotExist(err) {
		t.Fatalf("orchestrion.tool.go still exists after cleanup: %v", err)
	}
}

func TestEnsureImportableStdlibModulePathRewritesAndRestores(t *testing.T) {
	workDir := t.TempDir()
	previousWD, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(workDir); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	defer func() {
		_ = os.Chdir(previousWD)
	}()

	original := "module std\n\ngo 1.21\n"
	if err := os.WriteFile(filepath.Join(workDir, "go.mod"), []byte(original), 0o644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}

	cleanup, err := ensureImportableStdlibModulePath(false)
	if err != nil {
		t.Fatalf("ensureImportableStdlibModulePath error: %v", err)
	}
	rewritten, err := os.ReadFile("go.mod")
	if err != nil {
		t.Fatalf("read rewritten go.mod: %v", err)
	}
	if !strings.HasPrefix(string(rewritten), syntheticStdlibModulePath+"\n") {
		t.Fatalf("go.mod was not rewritten to %q:\n%s", syntheticStdlibModulePath, string(rewritten))
	}

	cleanup()
	restored, err := os.ReadFile("go.mod")
	if err != nil {
		t.Fatalf("read restored go.mod: %v", err)
	}
	if string(restored) != original {
		t.Fatalf("go.mod was not restored:\n%s", string(restored))
	}
}
