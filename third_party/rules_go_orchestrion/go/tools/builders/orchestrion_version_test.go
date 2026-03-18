package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestConfiguredDDTraceGoVersionDefaults(t *testing.T) {
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, "")
	got, err := configuredDDTraceGoVersion()
	if err != nil {
		t.Fatalf("configuredDDTraceGoVersion error: %v", err)
	}
	if got != defaultDDTraceGoVersion {
		t.Fatalf("configuredDDTraceGoVersion=%q, want %q", got, defaultDDTraceGoVersion)
	}
}

func TestConfiguredDDTraceGoVersionFromFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "dd_trace_go_version.txt")
	if err := os.WriteFile(path, []byte("v2.5.0\n"), 0o644); err != nil {
		t.Fatalf("write version file: %v", err)
	}
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, path)
	got, err := configuredDDTraceGoVersion()
	if err != nil {
		t.Fatalf("configuredDDTraceGoVersion error: %v", err)
	}
	if got != "v2.5.0" {
		t.Fatalf("configuredDDTraceGoVersion=%q, want %q", got, "v2.5.0")
	}
}

func TestSyntheticOrchestrionGoModUsesConfiguredVersion(t *testing.T) {
	got := syntheticOrchestrionGoMod("v2.5.0")
	for _, modulePath := range ddTraceGoModules {
		want := modulePath + " v2.5.0"
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
