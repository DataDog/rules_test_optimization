package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadSyntheticTestmainPackagefileManifestIncludesStdlibPackages(t *testing.T) {
	dir := t.TempDir()
	sidecarPath := filepath.Join(dir, syntheticTestmainPackagefileManifestName)
	content := strings.Join([]string{
		"importmap example.com/__orchestrion/gotesting=github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting",
		"packagefile testing=/tmp/testing.a",
		"packagefile github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting=/tmp/gotesting.a",
		"",
	}, "\n")
	if err := os.WriteFile(sidecarPath, []byte(content), 0o644); err != nil {
		t.Fatalf("write sidecar manifest: %v", err)
	}

	directives, packages, err := parseSyntheticTestmainPackagefileManifest(sidecarPath)
	if err != nil {
		t.Fatalf("parseSyntheticTestmainPackagefileManifest error: %v", err)
	}
	if len(directives) != 2 {
		t.Fatalf("parseSyntheticTestmainPackagefileManifest returned %d directives, want 2", len(directives))
	}
	if !packages["testing"] {
		t.Fatal("parseSyntheticTestmainPackagefileManifest did not retain stdlib package testing")
	}
	if !packages["github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting"] {
		t.Fatal("parseSyntheticTestmainPackagefileManifest did not retain gotesting package")
	}
}

func TestRewriteImportcfgFromCurrentStdlibEntriesSkipsSyntheticManifestPackages(t *testing.T) {
	dir := t.TempDir()
	cacheRoot := filepath.Join(dir, "cache")
	if err := os.MkdirAll(cacheRoot, 0o755); err != nil {
		t.Fatalf("mkdir cache root: %v", err)
	}
	testingArchive := filepath.Join(cacheRoot, "testing.a")
	fmtArchive := filepath.Join(cacheRoot, "fmt.a")
	for _, path := range []string{testingArchive, fmtArchive} {
		if err := os.WriteFile(path, []byte("archive"), 0o644); err != nil {
			t.Fatalf("write fake archive %s: %v", path, err)
		}
	}
	manifestPath := filepath.Join(cacheRoot, orchestrionStdlibCacheManifestName)
	manifest := strings.Join([]string{
		"testing=testing.a",
		"fmt=fmt.a",
		"",
	}, "\n")
	if err := os.WriteFile(manifestPath, []byte(manifest), 0o644); err != nil {
		t.Fatalf("write stdlib cache manifest: %v", err)
	}

	importcfgPath := filepath.Join(dir, "importcfg")
	originalTesting := filepath.Join(dir, "original-testing.a")
	originalFmt := filepath.Join(dir, "original-fmt.a")
	for _, path := range []string{originalTesting, originalFmt} {
		if err := os.WriteFile(path, []byte("orig"), 0o644); err != nil {
			t.Fatalf("write original archive %s: %v", path, err)
		}
	}
	importcfg := strings.Join([]string{
		"packagefile testing=" + originalTesting,
		"packagefile fmt=" + originalFmt,
		"packagefile github.com/example/dep=" + filepath.Join(dir, "dep.a"),
		"",
	}, "\n")
	if err := os.WriteFile(importcfgPath, []byte(importcfg), 0o644); err != nil {
		t.Fatalf("write importcfg: %v", err)
	}

	goenv := &env{stdlibCache: cacheRoot}
	if err := rewriteImportcfgFromCurrentStdlibEntries(importcfgPath, goenv, map[string]bool{"testing": true}); err != nil {
		t.Fatalf("rewriteImportcfgFromCurrentStdlibEntries error: %v", err)
	}

	data, err := os.ReadFile(importcfgPath)
	if err != nil {
		t.Fatalf("read rewritten importcfg: %v", err)
	}
	rewritten := string(data)
	if !strings.Contains(rewritten, "packagefile testing="+originalTesting) {
		t.Fatalf("testing packagefile was rewritten unexpectedly:\n%s", rewritten)
	}
	if !strings.Contains(rewritten, "packagefile fmt="+fmtArchive) {
		t.Fatalf("fmt packagefile was not rewritten to cached stdlib archive:\n%s", rewritten)
	}
}
