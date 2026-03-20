package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

func TestConfiguredDDTraceGoVersionsDefaults(t *testing.T) {
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, "")
	got, err := configuredDDTraceGoVersions()
	if err != nil {
		t.Fatalf("configuredDDTraceGoVersions error: %v", err)
	}
	for _, modulePath := range ddTraceGoModules {
		if got[modulePath] != defaultDDTraceGoVersion {
			t.Fatalf("configuredDDTraceGoVersions[%q]=%q, want %q", modulePath, got[modulePath], defaultDDTraceGoVersion)
		}
	}
}

func TestConfiguredDDTraceGoVersionsFromLegacyTextFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "dd_trace_go_versions.txt")
	if err := os.WriteFile(path, []byte("v2.5.0\n"), 0o644); err != nil {
		t.Fatalf("write version file: %v", err)
	}
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, path)
	got, err := configuredDDTraceGoVersions()
	if err != nil {
		t.Fatalf("configuredDDTraceGoVersions error: %v", err)
	}
	for _, modulePath := range ddTraceGoModules {
		if got[modulePath] != "v2.5.0" {
			t.Fatalf("configuredDDTraceGoVersions[%q]=%q, want %q", modulePath, got[modulePath], "v2.5.0")
		}
	}
}

func TestConfiguredDDTraceGoVersionsFromJSONFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "dd_trace_go_versions.json")
	content := `{"modules":{"github.com/DataDog/dd-trace-go/v2":"v2.7.0-rc.4","github.com/DataDog/dd-trace-go/contrib/net/http/v2":"v2.8.0-dev.0.20260316165907-0cdd3b7576b7","github.com/DataDog/dd-trace-go/contrib/log/slog/v2":"v2.8.0-dev.0.20260316165907-0cdd3b7576b7"}}`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write version file: %v", err)
	}
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, path)
	got, err := configuredDDTraceGoVersions()
	if err != nil {
		t.Fatalf("configuredDDTraceGoVersions error: %v", err)
	}
	if got["github.com/DataDog/dd-trace-go/v2"] != "v2.7.0-rc.4" {
		t.Fatalf("configuredDDTraceGoVersions root=%q", got["github.com/DataDog/dd-trace-go/v2"])
	}
	if got["github.com/DataDog/dd-trace-go/contrib/net/http/v2"] != "v2.8.0-dev.0.20260316165907-0cdd3b7576b7" {
		t.Fatalf("configuredDDTraceGoVersions net/http=%q", got["github.com/DataDog/dd-trace-go/contrib/net/http/v2"])
	}
}

func TestSyntheticOrchestrionGoModUsesConfiguredVersions(t *testing.T) {
	versions := map[string]string{
		"github.com/DataDog/dd-trace-go/v2":                  "v2.7.0-rc.4",
		"github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.8.0-dev.0.20260316165907-0cdd3b7576b7",
		"github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.8.0-dev.0.20260316165907-0cdd3b7576b7",
	}
	got := syntheticOrchestrionGoMod(versions)
	for modulePath, version := range versions {
		want := modulePath + " " + version
		if !strings.Contains(got, want) {
			t.Fatalf("syntheticOrchestrionGoMod missing configured version %q:\n%s", want, got)
		}
	}
}

func TestResolveModuleVersionFromModule(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	dir := t.TempDir()
	goPath := filepath.Join(dir, "go")
	script := "#!/bin/sh\ncat <<'EOF'\n{\"Version\":\"v2.5.0\"}\nEOF\n"
	if err := os.WriteFile(goPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake go tool: %v", err)
	}

	got, err := resolveModuleVersionFromModule(goPath, dir, os.Environ(), ddTraceGoModules[0])
	if err != nil {
		t.Fatalf("resolveModuleVersionFromModule error: %v", err)
	}
	if got != "v2.5.0" {
		t.Fatalf("resolveModuleVersionFromModule=%q, want %q", got, "v2.5.0")
	}
}

func TestResolveModuleVersionFromModuleRejectsLocalReplace(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	dir := t.TempDir()
	goPath := filepath.Join(dir, "go")
	script := "#!/bin/sh\ncat <<'EOF'\n{\"Version\":\"v2.5.0\",\"Replace\":{\"Path\":\"../dd-trace-go\"}}\nEOF\n"
	if err := os.WriteFile(goPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake go tool: %v", err)
	}

	_, err := resolveModuleVersionFromModule(goPath, dir, os.Environ(), ddTraceGoModules[0])
	if err == nil {
		t.Fatal("expected local replace to fail")
	}
	if !strings.Contains(err.Error(), "local replace targets are not supported") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestResolveModuleVersionFromModuleForcesGoWorkOff(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	dir := t.TempDir()
	goPath := filepath.Join(dir, "go")
	script := "#!/bin/sh\nif [ \"$GOWORK\" != \"off\" ]; then echo \"GOWORK=$GOWORK\" >&2; exit 1; fi\ncat <<'EOF'\n{\"Version\":\"v2.5.0\"}\nEOF\n"
	if err := os.WriteFile(goPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake go tool: %v", err)
	}

	got, err := resolveModuleVersionFromModule(goPath, dir, []string{"GOWORK=/tmp/custom"}, ddTraceGoModules[0])
	if err != nil {
		t.Fatalf("resolveModuleVersionFromModule error: %v", err)
	}
	if got != "v2.5.0" {
		t.Fatalf("resolveModuleVersionFromModule=%q, want %q", got, "v2.5.0")
	}
}

func TestResolveModuleVersionsFromModuleParsesStream(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	dir := t.TempDir()
	goPath := filepath.Join(dir, "go")
	script := "#!/bin/sh\ncat <<'EOF'\n{\"Path\":\"github.com/DataDog/dd-trace-go/v2\",\"Version\":\"v2.5.0\"}\n{\"Path\":\"github.com/DataDog/dd-trace-go/contrib/net/http/v2\",\"Version\":\"v2.5.1\"}\nEOF\n"
	if err := os.WriteFile(goPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake go tool: %v", err)
	}

	got, err := resolveModuleVersionsFromModule(goPath, dir, os.Environ(), []string{
		"github.com/DataDog/dd-trace-go/v2",
		"github.com/DataDog/dd-trace-go/contrib/net/http/v2",
	})
	if err != nil {
		t.Fatalf("resolveModuleVersionsFromModule error: %v", err)
	}
	if got["github.com/DataDog/dd-trace-go/v2"] != "v2.5.0" {
		t.Fatalf("root version=%q", got["github.com/DataDog/dd-trace-go/v2"])
	}
	if got["github.com/DataDog/dd-trace-go/contrib/net/http/v2"] != "v2.5.1" {
		t.Fatalf("net/http version=%q", got["github.com/DataDog/dd-trace-go/contrib/net/http/v2"])
	}
}

func TestValidateResolvedDDTraceGoVersionUsesCache(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	moduleDir := t.TempDir()
	for name, content := range map[string]string{
		"go.mod":              "module example.com/test\n\ngo 1.21\n",
		"orchestrion.tool.go": "package tools\n",
		"orchestrion.yml":     "injectors: []\n",
	} {
		if err := os.WriteFile(filepath.Join(moduleDir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	versionFile := filepath.Join(t.TempDir(), "dd_trace_go_versions.txt")
	if err := os.WriteFile(versionFile, []byte("v2.5.0\n"), 0o644); err != nil {
		t.Fatalf("write version file: %v", err)
	}
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, versionFile)
	counterPath := filepath.Join(t.TempDir(), "go-counter")
	goPath := filepath.Join(t.TempDir(), "go")
	script := "#!/bin/sh\ncounter_file=\"$GO_COUNTER_FILE\"\ncount=0\nif [ -f \"$counter_file\" ]; then count=$(cat \"$counter_file\"); fi\ncount=$((count + 1))\nprintf '%s' \"$count\" > \"$counter_file\"\ncat <<'EOF'\n{\"Path\":\"github.com/DataDog/dd-trace-go/v2\",\"Version\":\"v2.5.0\"}\n{\"Path\":\"github.com/DataDog/dd-trace-go/contrib/net/http/v2\",\"Version\":\"v2.5.0\"}\n{\"Path\":\"github.com/DataDog/dd-trace-go/contrib/log/slog/v2\",\"Version\":\"v2.5.0\"}\nEOF\n"
	if err := os.WriteFile(goPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake go tool: %v", err)
	}
	env := []string{
		"GOPATH=" + filepath.Join(t.TempDir(), "gopath"),
		"GO_COUNTER_FILE=" + counterPath,
	}
	if err := validateResolvedDDTraceGoVersion(goPath, moduleDir, env, false); err != nil {
		t.Fatalf("first validateResolvedDDTraceGoVersion error: %v", err)
	}
	if err := validateResolvedDDTraceGoVersion(goPath, moduleDir, env, false); err != nil {
		t.Fatalf("second validateResolvedDDTraceGoVersion error: %v", err)
	}
	if got := readCounterFile(t, counterPath); got != 1 {
		t.Fatalf("go list invocation count=%d, want 1", got)
	}
}

func TestValidateResolvedDDTraceGoVersionInvalidatesWhenGoModChanges(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	moduleDir := t.TempDir()
	goModPath := filepath.Join(moduleDir, "go.mod")
	if err := os.WriteFile(goModPath, []byte("module example.com/test\n\ngo 1.21\n"), 0o644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}
	if err := os.WriteFile(filepath.Join(moduleDir, "orchestrion.tool.go"), []byte("package tools\n"), 0o644); err != nil {
		t.Fatalf("write orchestrion.tool.go: %v", err)
	}
	versionFile := filepath.Join(t.TempDir(), "dd_trace_go_versions.txt")
	if err := os.WriteFile(versionFile, []byte("v2.5.0\n"), 0o644); err != nil {
		t.Fatalf("write version file: %v", err)
	}
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, versionFile)
	counterPath := filepath.Join(t.TempDir(), "go-counter")
	goPath := filepath.Join(t.TempDir(), "go")
	script := "#!/bin/sh\ncounter_file=\"$GO_COUNTER_FILE\"\ncount=0\nif [ -f \"$counter_file\" ]; then count=$(cat \"$counter_file\"); fi\ncount=$((count + 1))\nprintf '%s' \"$count\" > \"$counter_file\"\ncat <<'EOF'\n{\"Path\":\"github.com/DataDog/dd-trace-go/v2\",\"Version\":\"v2.5.0\"}\n{\"Path\":\"github.com/DataDog/dd-trace-go/contrib/net/http/v2\",\"Version\":\"v2.5.0\"}\n{\"Path\":\"github.com/DataDog/dd-trace-go/contrib/log/slog/v2\",\"Version\":\"v2.5.0\"}\nEOF\n"
	if err := os.WriteFile(goPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake go tool: %v", err)
	}
	env := []string{
		"GOPATH=" + filepath.Join(t.TempDir(), "gopath"),
		"GO_COUNTER_FILE=" + counterPath,
	}
	if err := validateResolvedDDTraceGoVersion(goPath, moduleDir, env, false); err != nil {
		t.Fatalf("first validateResolvedDDTraceGoVersion error: %v", err)
	}
	if err := os.WriteFile(goModPath, []byte("module example.com/changed\n\ngo 1.21\n"), 0o644); err != nil {
		t.Fatalf("rewrite go.mod: %v", err)
	}
	if err := validateResolvedDDTraceGoVersion(goPath, moduleDir, env, false); err != nil {
		t.Fatalf("second validateResolvedDDTraceGoVersion error: %v", err)
	}
	if got := readCounterFile(t, counterPath); got != 2 {
		t.Fatalf("go list invocation count=%d, want 2", got)
	}
}

func readCounterFile(t *testing.T, path string) int {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read counter file: %v", err)
	}
	value, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatalf("parse counter file %q: %v", string(data), err)
	}
	return value
}
