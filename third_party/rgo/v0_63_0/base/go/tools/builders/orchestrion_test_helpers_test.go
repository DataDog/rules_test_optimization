package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeDDTraceGoVersionsFile(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "dd_trace_go_versions.json")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write dd-trace-go versions file: %v", err)
	}
	return path
}

func writeOrchestrionToolVersionFile(t *testing.T, version string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "orchestrion_version.txt")
	if err := os.WriteFile(path, []byte(version+"\n"), 0o644); err != nil {
		t.Fatalf("write orchestrion tool version file: %v", err)
	}
	return path
}
