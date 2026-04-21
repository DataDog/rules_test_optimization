package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestSyntheticTestmainHelperDecisionManifestRoundTrip(t *testing.T) {
	paths := orchestrionCachePaths(t.TempDir(), "synthetic-testmain-helper-decisions", "abc123")
	if err := os.MkdirAll(paths.entryDir, 0o755); err != nil {
		t.Fatalf("mkdir entry dir: %v", err)
	}
	state := syntheticTestmainHelperDecisionState{
		metaCache: map[string]*modulePackageMetadata{
			"example.com/root": &modulePackageMetadata{
				Dir:        "/tmp/root",
				ImportPath: "example.com/root",
				GoFiles:    []string{"root.go"},
				Imports:    []string{"example.com/dep", "net/http"},
			},
			"example.com/dep": &modulePackageMetadata{
				Dir:        "/tmp/dep",
				ImportPath: "example.com/dep",
				GoFiles:    []string{"dep.go"},
				Imports:    []string{"log"},
			},
		},
		sourceDecisions:  map[string]bool{"example.com/root": true, "example.com/dep": false},
		sourcePackages:   []string{"example.com/root"},
		externalPackages: []string{"example.com/external"},
	}
	if err := writeSyntheticTestmainHelperDecisionManifest(paths.entryDir, state, []string{"configured_versions=abc"}); err != nil {
		t.Fatalf("writeSyntheticTestmainHelperDecisionManifest error: %v", err)
	}
	got, err := loadSyntheticTestmainHelperDecisionManifest(paths)
	if err != nil {
		t.Fatalf("loadSyntheticTestmainHelperDecisionManifest error: %v", err)
	}
	if !reflect.DeepEqual(got.sourceDecisions, state.sourceDecisions) {
		t.Fatalf("sourceDecisions mismatch: got=%v want=%v", got.sourceDecisions, state.sourceDecisions)
	}
	if !reflect.DeepEqual(got.sourcePackages, state.sourcePackages) {
		t.Fatalf("sourcePackages mismatch: got=%v want=%v", got.sourcePackages, state.sourcePackages)
	}
	if !reflect.DeepEqual(got.externalPackages, state.externalPackages) {
		t.Fatalf("externalPackages mismatch: got=%v want=%v", got.externalPackages, state.externalPackages)
	}
	if got.metaCache["example.com/root"] == nil || got.metaCache["example.com/root"].Dir != "/tmp/root" {
		t.Fatalf("metaCache missing expected root package: %#v", got.metaCache["example.com/root"])
	}
}

func TestCollectSyntheticTestmainExternalPackagesIsStable(t *testing.T) {
	rootSet := map[string]bool{"example.com/root": true}
	sourceDecisions := map[string]bool{
		"example.com/root": true,
		"example.com/dep":  true,
	}
	metaCache := map[string]*modulePackageMetadata{
		"example.com/root": &modulePackageMetadata{
			ImportPath: "example.com/root",
			Imports:    []string{"example.com/external", "example.com/dep"},
		},
		"example.com/dep": &modulePackageMetadata{
			ImportPath: "example.com/dep",
			Imports:    []string{"example.com/external", "example.com/other"},
		},
	}
	got := collectSyntheticTestmainExternalPackages(rootSet, sourceDecisions, metaCache)
	want := []string{"example.com/external", "example.com/other"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("collectSyntheticTestmainExternalPackages got=%v want=%v", got, want)
	}
}

func TestSyntheticTestmainHelperDecisionCacheKeyIgnoresSdkExecrootPath(t *testing.T) {
	t.Setenv(rulesGoOrchestrionToolVersionFileEnvVar, writeOrchestrionToolVersionFile(t, "v1.6.0"))
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, writeDDTraceGoVersionsFile(t, `{"modules":{"github.com/DataDog/dd-trace-go/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/net/http/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/log/slog/v2":"v2.7.3"}}`))
	makeSDK := func(root string) string {
		sdk := filepath.Join(root, "external", "rules_go++go_sdk+go_default_sdk")
		if err := os.MkdirAll(filepath.Join(sdk, "src", "internal", "buildcfg"), 0o755); err != nil {
			t.Fatalf("mkdir sdk tree: %v", err)
		}
		if err := os.WriteFile(filepath.Join(sdk, "VERSION"), []byte("go1.24.0\n"), 0o644); err != nil {
			t.Fatalf("write VERSION: %v", err)
		}
		if err := os.WriteFile(filepath.Join(sdk, "src", "internal", "buildcfg", "zbootstrap.go"), []byte("package buildcfg\n"), 0o644); err != nil {
			t.Fatalf("write zbootstrap.go: %v", err)
		}
		return sdk
	}

	keyPartsA, err := syntheticTestmainHelperDecisionCacheKeyParts(&env{sdk: makeSDK(filepath.Join(t.TempDir(), "execroot-a"))})
	if err != nil {
		t.Fatalf("syntheticTestmainHelperDecisionCacheKeyParts sdk A error: %v", err)
	}
	keyPartsB, err := syntheticTestmainHelperDecisionCacheKeyParts(&env{sdk: makeSDK(filepath.Join(t.TempDir(), "execroot-b"))})
	if err != nil {
		t.Fatalf("syntheticTestmainHelperDecisionCacheKeyParts sdk B error: %v", err)
	}
	if !reflect.DeepEqual(keyPartsA, keyPartsB) {
		t.Fatalf("helper decision cache key changed across equivalent sdk paths: %v != %v", keyPartsA, keyPartsB)
	}
}
