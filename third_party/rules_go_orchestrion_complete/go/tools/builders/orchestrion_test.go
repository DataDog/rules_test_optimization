package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
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
		"go.mod":              syntheticOrchestrionGoMod("v1.6.0", defaultDDTraceGoVersions(), orchestrionModeGeneral),
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
	if err := snapshotPreparedSyntheticModule(filepath.Join("/tmp", "sdk"), configuredVersions, orchestrionModeGeneral); err != nil {
		t.Fatalf("snapshotPreparedSyntheticModule error: %v", err)
	}
	for _, name := range []string{"go.mod", "go.sum", "orchestrion.tool.go"} {
		if err := os.Remove(name); err != nil {
			t.Fatalf("remove %s: %v", name, err)
		}
	}
	if err := os.WriteFile("go.mod", []byte(syntheticOrchestrionGoMod("v1.6.0", defaultDDTraceGoVersions(), orchestrionModeGeneral)), 0o644); err != nil {
		t.Fatalf("rewrite go.mod: %v", err)
	}
	if err := os.WriteFile("orchestrion.tool.go", []byte(syntheticOrchestrionToolGo), 0o644); err != nil {
		t.Fatalf("rewrite orchestrion.tool.go: %v", err)
	}
	hit, err := restorePreparedSyntheticModule(filepath.Join("/tmp", "sdk"), configuredVersions, orchestrionModeGeneral, false)
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

func TestEnsureGoModExistsUsesSyntheticToolInTestOptimizationMode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based fake Go SDK is Unix-only")
	}
	sourceDir := t.TempDir()
	workDir := t.TempDir()
	for name, content := range map[string]string{
		"go.mod":              "module example.com/app\n\ngo 1.21\n\nrequire (\n\tal.essio.dev/pkg/shellescape v1.6.0\n\tgithub.com/DataDog/dd-trace-go/v2 v2.7.3\n)\n",
		"go.sum":              "github.com/DataDog/dd-trace-go/v2 v2.7.3 h1:test\n",
		"orchestrion.tool.go": "package tools\n\nimport _ \"github.com/DataDog/dd-trace-go/contrib/net/http/v2\"\n",
	} {
		if err := os.WriteFile(filepath.Join(sourceDir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write source %s: %v", name, err)
		}
	}
	sdkDir := writeFakeGoSDK(t)
	t.Setenv("GOPATH", filepath.Join(t.TempDir(), "gopath"))
	t.Setenv(rulesGoOrchestrionToolVersionFileEnvVar, writeOrchestrionToolVersionFile(t, "v1.6.0"))
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, writeDDTraceGoVersionsFile(t, `{"modules":{"github.com/DataDog/dd-trace-go/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/net/http/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/log/slog/v2":"v2.7.3"}}`))

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

	cleanup, err := ensureGoModExists([]string{sourceDir}, sdkDir, false, orchestrionModeTestOptimization)
	if err != nil {
		t.Fatalf("ensureGoModExists error: %v", err)
	}
	defer cleanup()

	goModData, err := os.ReadFile("go.mod")
	if err != nil {
		t.Fatalf("read go.mod: %v", err)
	}
	goModText := string(goModData)
	if !strings.Contains(goModText, "module bazel_orchestrion_temp") {
		t.Fatalf("test_optimization did not use the reduced synthetic go.mod:\n%s", goModText)
	}
	if strings.Contains(goModText, "al.essio.dev/pkg/shellescape") {
		t.Fatalf("test_optimization copied consumer-only module requirements:\n%s", goModText)
	}

	data, err := os.ReadFile("orchestrion.tool.go")
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(data)
	if !strings.Contains(text, "github.com/DataDog/dd-trace-go/v2/orchestrion") {
		t.Fatalf("test_optimization tool pin missing CI Visibility orchestrion import:\n%s", text)
	}
	if strings.Contains(text, "github.com/DataDog/dd-trace-go/contrib/net/http/v2") {
		t.Fatalf("test_optimization copied generic user tool pin:\n%s", text)
	}
}

func TestEnsureGoModExistsMasksExistingConsumerModuleInTestOptimizationMode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based fake Go SDK is Unix-only")
	}
	workDir := t.TempDir()
	consumerGoMod := "module example.com/app\n\ngo 1.21\n\nrequire (\n\tal.essio.dev/pkg/shellescape v1.6.0\n\tgithub.com/DataDog/dd-trace-go/v2 v2.7.3\n)\n"
	consumerGoSum := "al.essio.dev/pkg/shellescape v1.6.0 h1:test\n"
	consumerToolGo := "package tools\n\nimport _ \"github.com/DataDog/dd-trace-go/contrib/net/http/v2\"\n"
	for name, content := range map[string]string{
		"go.mod":              consumerGoMod,
		"go.sum":              consumerGoSum,
		"orchestrion.tool.go": consumerToolGo,
	} {
		if err := os.WriteFile(filepath.Join(workDir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write source %s: %v", name, err)
		}
	}
	sdkDir := writeFakeGoSDK(t)
	t.Setenv("GOPATH", filepath.Join(t.TempDir(), "gopath"))
	t.Setenv(rulesGoOrchestrionToolVersionFileEnvVar, writeOrchestrionToolVersionFile(t, "v1.6.0"))
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, writeDDTraceGoVersionsFile(t, `{"modules":{"github.com/DataDog/dd-trace-go/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/net/http/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/log/slog/v2":"v2.7.3"}}`))

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

	cleanup, err := ensureGoModExists([]string{workDir}, sdkDir, false, orchestrionModeTestOptimization)
	if err != nil {
		t.Fatalf("ensureGoModExists error: %v", err)
	}

	goModData, err := os.ReadFile("go.mod")
	if err != nil {
		t.Fatalf("read go.mod: %v", err)
	}
	goModText := string(goModData)
	if !strings.Contains(goModText, "module bazel_orchestrion_temp") {
		t.Fatalf("test_optimization did not replace the active go.mod with the reduced synthetic module:\n%s", goModText)
	}
	if strings.Contains(goModText, "al.essio.dev/pkg/shellescape") {
		t.Fatalf("test_optimization leaked consumer-only module requirements:\n%s", goModText)
	}

	toolData, err := os.ReadFile("orchestrion.tool.go")
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	toolText := string(toolData)
	if !strings.Contains(toolText, "github.com/DataDog/dd-trace-go/v2/orchestrion") {
		t.Fatalf("test_optimization tool pin missing CI Visibility orchestrion import:\n%s", toolText)
	}
	if strings.Contains(toolText, "github.com/DataDog/dd-trace-go/contrib/net/http/v2") {
		t.Fatalf("test_optimization leaked generic user tool pin:\n%s", toolText)
	}

	cleanup()
	for name, want := range map[string]string{
		"go.mod":              consumerGoMod,
		"go.sum":              consumerGoSum,
		"orchestrion.tool.go": consumerToolGo,
	} {
		got, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read restored %s: %v", name, err)
		}
		if string(got) != want {
			t.Fatalf("restored %s = %q, want %q", name, string(got), want)
		}
	}
}

func writeFakeGoSDK(t *testing.T) string {
	t.Helper()
	sdkDir := t.TempDir()
	binDir := filepath.Join(sdkDir, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("mkdir fake sdk bin: %v", err)
	}
	goPath := filepath.Join(binDir, "go")
	script := `#!/bin/sh
if [ "$1" = "list" ]; then
  cat <<'EOF'
{"Path":"github.com/DataDog/dd-trace-go/v2","Version":"v2.7.3"}
{"Path":"github.com/DataDog/dd-trace-go/contrib/net/http/v2","Version":"v2.7.3"}
{"Path":"github.com/DataDog/dd-trace-go/contrib/log/slog/v2","Version":"v2.7.3"}
EOF
  exit 0
fi
if [ "$1" = "mod" ] && [ "$2" = "download" ]; then
  exit 0
fi
exit 0
`
	if err := os.WriteFile(goPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake go: %v", err)
	}
	return sdkDir
}
