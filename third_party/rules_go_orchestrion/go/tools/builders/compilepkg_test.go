package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestSyntheticTestmainHelperDecisionManifestRoundTrip(t *testing.T) {
	paths := orchestrionCachePaths(t.TempDir(), "synthetic-testmain-helper-decisions", "abc123")
	if err := os.MkdirAll(paths.entryDir, 0o755); err != nil {
		t.Fatalf("mkdir entry dir: %v", err)
	}
	state := syntheticTestmainHelperDecisionState{
		metaCache: map[string]*modulePackageMetadata{
			"example.com/root": {
				Dir:        "/tmp/root",
				ImportPath: "example.com/root",
				GoFiles:    []string{"root.go"},
				Imports:    []string{"example.com/dep", "net/http"},
			},
			"example.com/dep": {
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
		"example.com/root": {
			ImportPath: "example.com/root",
			Imports:    []string{"example.com/external", "example.com/dep"},
		},
		"example.com/dep": {
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

	keyPartsA, err := syntheticTestmainHelperDecisionCacheKeyParts(&env{sdk: makeSDK(filepath.Join(t.TempDir(), "execroot-a"))}, "")
	if err != nil {
		t.Fatalf("syntheticTestmainHelperDecisionCacheKeyParts sdk A error: %v", err)
	}
	keyPartsB, err := syntheticTestmainHelperDecisionCacheKeyParts(&env{sdk: makeSDK(filepath.Join(t.TempDir(), "execroot-b"))}, "")
	if err != nil {
		t.Fatalf("syntheticTestmainHelperDecisionCacheKeyParts sdk B error: %v", err)
	}
	if !reflect.DeepEqual(keyPartsA, keyPartsB) {
		t.Fatalf("helper decision cache key changed across equivalent sdk paths: %v != %v", keyPartsA, keyPartsB)
	}
}

// TestSeedSyntheticTestmainModuleFilesPrefersSourceModule verifies that the
// synthetic testmain helper bootstrap reuses the real consumer module files
// when they are available, instead of rebuilding a minimal temporary graph.
func TestSeedSyntheticTestmainModuleFilesPrefersSourceModule(t *testing.T) {
	sourceDir := t.TempDir()
	syntheticDir := t.TempDir()
	files := map[string]string{
		"go.mod":              "module example.com/source\n",
		"go.sum":              "example.com/module v1.0.0 h1:abc\n",
		"orchestrion.tool.go": "package tools\n",
		"orchestrion.yml":     "version: 1\n",
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(sourceDir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	usedSourceModule, err := seedSyntheticTestmainModuleFiles(sourceDir, syntheticDir, defaultDDTraceGoVersions())
	if err != nil {
		t.Fatalf("seedSyntheticTestmainModuleFiles error: %v", err)
	}
	if !usedSourceModule {
		t.Fatal("seedSyntheticTestmainModuleFiles did not reuse the source module")
	}

	for name, want := range files {
		got, err := os.ReadFile(filepath.Join(syntheticDir, name))
		if err != nil {
			t.Fatalf("read seeded %s: %v", name, err)
		}
		if string(got) != want {
			t.Fatalf("seeded %s = %q, want %q", name, string(got), want)
		}
	}
}

// TestSeedSyntheticTestmainModuleFilesFallsBack verifies that the synthetic
// helper bootstrap still produces a minimal module when no consumer module
// metadata is available.
func TestSeedSyntheticTestmainModuleFilesFallsBack(t *testing.T) {
	syntheticDir := t.TempDir()

	usedSourceModule, err := seedSyntheticTestmainModuleFiles("", syntheticDir, defaultDDTraceGoVersions())
	if err != nil {
		t.Fatalf("seedSyntheticTestmainModuleFiles error: %v", err)
	}
	if usedSourceModule {
		t.Fatal("seedSyntheticTestmainModuleFiles unexpectedly reported a source module")
	}

	goMod, err := os.ReadFile(filepath.Join(syntheticDir, "go.mod"))
	if err != nil {
		t.Fatalf("read fallback go.mod: %v", err)
	}
	want := syntheticOrchestrionGoMod(defaultDDTraceGoVersions())
	if string(goMod) != want {
		t.Fatalf("fallback go.mod = %q, want %q", string(goMod), want)
	}
}

// TestModulePackageCommandEnvUsesExportLocalModuleCache verifies that
// synthetic metadata and export commands isolate their module cache from the
// shared orchestrion cache entry, so a bad extraction in one run cannot poison
// later helper rebuilds.
func TestModulePackageCommandEnvUsesExportLocalModuleCache(t *testing.T) {
	sdkRoot := filepath.Join(t.TempDir(), "sdk")
	exportRoot := filepath.Join(t.TempDir(), "exports")
	if err := os.MkdirAll(filepath.Join(sdkRoot, "bin"), 0o755); err != nil {
		t.Fatalf("mkdir fake sdk bin: %v", err)
	}
	if err := os.MkdirAll(exportRoot, 0o755); err != nil {
		t.Fatalf("mkdir export root: %v", err)
	}

	envv, err := modulePackageCommandEnv(&env{sdk: sdkRoot}, exportRoot)
	if err != nil {
		t.Fatalf("modulePackageCommandEnv error: %v", err)
	}

	wantGoPath := filepath.Join(filepath.Dir(exportRoot), ".exports_gopath")
	if got := getEnv(envv, "GOPATH"); got != wantGoPath {
		t.Fatalf("GOPATH = %q, want %q", got, wantGoPath)
	}
	wantGoModCache := filepath.Join(wantGoPath, "pkg", "mod")
	if got := getEnv(envv, "GOMODCACHE"); got != wantGoModCache {
		t.Fatalf("GOMODCACHE = %q, want %q", got, wantGoModCache)
	}
	if got := getEnv(envv, "GOCACHE"); got != exportRoot {
		t.Fatalf("GOCACHE = %q, want %q", got, exportRoot)
	}
	if got := getEnv(envv, "GIT_CONFIG_GLOBAL"); got != os.DevNull {
		t.Fatalf("GIT_CONFIG_GLOBAL = %q, want %q", got, os.DevNull)
	}
	if got := getEnv(envv, "GIT_CONFIG_NOSYSTEM"); got != "1" {
		t.Fatalf("GIT_CONFIG_NOSYSTEM = %q, want 1", got)
	}
	if got := getEnv(envv, "GIT_TERMINAL_PROMPT"); got != "0" {
		t.Fatalf("GIT_TERMINAL_PROMPT = %q, want 0", got)
	}
}

// TestSyntheticTestmainHelperModuleCacheRootIsStable verifies that synthetic
// helper bootstrap subprocesses have a dedicated stable GOPATH root derived
// from the helper cache key instead of reusing the shared orchestrion cache.
func TestSyntheticTestmainHelperModuleCacheRootIsStable(t *testing.T) {
	cacheRoot, err := orchestrionPersistentCacheRoot(os.Environ())
	if err != nil {
		t.Fatalf("orchestrionPersistentCacheRoot error: %v", err)
	}
	got, err := syntheticTestmainHelperModuleCacheRoot([]string{"configured_versions=abc", "sdk=def"})
	if err != nil {
		t.Fatalf("syntheticTestmainHelperModuleCacheRoot error: %v", err)
	}
	want := filepath.Join(cacheRoot, "synthetic-testmain-helper-module-cache", stableDigestParts("configured_versions=abc", "sdk=def"))
	if got != want {
		t.Fatalf("syntheticTestmainHelperModuleCacheRoot = %q, want %q", got, want)
	}
}

// TestWithSyntheticTestmainModuleCacheEnvRestoresEnvironment verifies that the
// synthetic helper wrapper points subprocess cache env vars at the helper
// cache root during execution and restores the caller's environment after.
func TestWithSyntheticTestmainModuleCacheEnvRestoresEnvironment(t *testing.T) {
	t.Setenv("GOPATH", filepath.Join(t.TempDir(), "original-gopath"))
	t.Setenv("GOMODCACHE", filepath.Join(t.TempDir(), "original-modcache"))
	t.Setenv("GOCACHE", filepath.Join(t.TempDir(), "original-gocache"))

	cacheRoot := filepath.Join(t.TempDir(), "synthetic-helper-cache")
	if err := withSyntheticTestmainModuleCacheEnv(cacheRoot, func() error {
		if got := os.Getenv("GOPATH"); got != cacheRoot {
			t.Fatalf("GOPATH inside wrapper = %q, want %q", got, cacheRoot)
		}
		if got := os.Getenv("GOMODCACHE"); got != filepath.Join(cacheRoot, "pkg", "mod") {
			t.Fatalf("GOMODCACHE inside wrapper = %q", got)
		}
		if got := os.Getenv("GOCACHE"); got != filepath.Join(cacheRoot, "gocache") {
			t.Fatalf("GOCACHE inside wrapper = %q", got)
		}
		return nil
	}); err != nil {
		t.Fatalf("withSyntheticTestmainModuleCacheEnv error: %v", err)
	}

	if got := os.Getenv("GOPATH"); !strings.HasSuffix(got, "original-gopath") {
		t.Fatalf("GOPATH after wrapper = %q", got)
	}
	if got := os.Getenv("GOMODCACHE"); !strings.HasSuffix(got, "original-modcache") {
		t.Fatalf("GOMODCACHE after wrapper = %q", got)
	}
	if got := os.Getenv("GOCACHE"); !strings.HasSuffix(got, "original-gocache") {
		t.Fatalf("GOCACHE after wrapper = %q", got)
	}
}

// TestPrepareModuleExportRootUsesWrappedSyntheticCache verifies that the
// synthetic helper wrapper also moves the shared export-root parent under the
// helper-specific GOPATH root, so older shared cache entries are bypassed.
func TestPrepareModuleExportRootUsesWrappedSyntheticCache(t *testing.T) {
	sdkRoot := filepath.Join(t.TempDir(), "sdk")
	if err := os.MkdirAll(filepath.Join(sdkRoot, "bin"), 0o755); err != nil {
		t.Fatalf("mkdir fake sdk bin: %v", err)
	}
	cacheRoot := filepath.Join(t.TempDir(), "synthetic-helper-cache")
	var exportRoot string
	if err := withSyntheticTestmainModuleCacheEnv(cacheRoot, func() error {
		var err error
		exportRoot, err = prepareModuleExportRoot(&env{sdk: sdkRoot}, t.TempDir(), []string{"example.com/root"})
		return err
	}); err != nil {
		t.Fatalf("prepareModuleExportRoot under wrapped cache error: %v", err)
	}
	wantPrefix := filepath.Join(cacheRoot, "cache", "module-exports") + string(os.PathSeparator)
	if !strings.HasPrefix(exportRoot, wantPrefix) {
		t.Fatalf("exportRoot = %q, want prefix %q", exportRoot, wantPrefix)
	}
}

// TestLoadModulePackageMetadataBatchSkipsBrokenTransitiveDeps proves the
// helper metadata loader only asks `go list` for the requested roots. The
// direct package metadata must still load even when a transitive dependency is
// intentionally unresolved.
func TestLoadModulePackageMetadataBatchSkipsBrokenTransitiveDeps(t *testing.T) {
	goExe, err := exec.LookPath("go")
	if err != nil {
		t.Skipf("go binary not on PATH: %v", err)
	}

	root := t.TempDir()
	depDir := filepath.Join(root, "dep")
	mainDir := filepath.Join(root, "main")
	for _, dir := range []string{depDir, mainDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
	}
	if err := os.WriteFile(filepath.Join(depDir, "go.mod"), []byte("module example.com/dep\n\ngo 1.20\n"), 0o644); err != nil {
		t.Fatalf("write dep go.mod: %v", err)
	}
	if err := os.WriteFile(filepath.Join(depDir, "dep.go"), []byte("package dep\n\nimport _ \"example.com/missing\"\n"), 0o644); err != nil {
		t.Fatalf("write dep.go: %v", err)
	}
	replacePath, err := filepath.Rel(mainDir, depDir)
	if err != nil {
		t.Fatalf("rel dep dir: %v", err)
	}
	mainGoMod := strings.Join([]string{
		"module example.com/main",
		"",
		"go 1.20",
		"",
		"require example.com/dep v0.0.0",
		"",
		"replace example.com/dep => " + filepath.ToSlash(replacePath),
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(mainDir, "go.mod"), []byte(mainGoMod), 0o644); err != nil {
		t.Fatalf("write main go.mod: %v", err)
	}

	exportRoot := filepath.Join(root, "exports")
	if err := os.MkdirAll(exportRoot, 0o755); err != nil {
		t.Fatalf("mkdir export root: %v", err)
	}
	metaCache, err := loadModulePackageMetadataBatch(
		&env{sdk: filepath.Dir(filepath.Dir(goExe))},
		mainDir,
		exportRoot,
		[]string{"example.com/dep"},
	)
	if err != nil {
		t.Fatalf("loadModulePackageMetadataBatch error: %v", err)
	}
	meta := metaCache["example.com/dep"]
	if meta == nil {
		t.Fatal("missing metadata for example.com/dep")
	}
	gotDir, err := filepath.EvalSymlinks(meta.Dir)
	if err != nil {
		t.Fatalf("EvalSymlinks(metadata Dir): %v", err)
	}
	wantDir, err := filepath.EvalSymlinks(depDir)
	if err != nil {
		t.Fatalf("EvalSymlinks(depDir): %v", err)
	}
	if gotDir != wantDir {
		t.Fatalf("metadata Dir = %q (resolved %q), want %q (resolved %q)", meta.Dir, gotDir, depDir, wantDir)
	}
	if !reflect.DeepEqual(meta.Imports, []string{"example.com/missing"}) {
		t.Fatalf("metadata Imports = %v, want [example.com/missing]", meta.Imports)
	}
}

func TestIsSyntheticTestmainSourceCompileCandidate(t *testing.T) {
	if !isSyntheticTestmainSourceCompileCandidate("github.com/DataDog/dd-trace-go/v2/internal/orchestrion") {
		t.Fatal("dd-trace-go internal package should be source-compile eligible")
	}
	if !isSyntheticTestmainSourceCompileCandidate("github.com/DataDog/dd-trace-go/contrib/net/http/v2/internal/orchestrion") {
		t.Fatal("contrib helper package should be source-compile eligible")
	}
	if isSyntheticTestmainSourceCompileCandidate("github.com/DataDog/datadog-agent/pkg/obfuscate") {
		t.Fatal("external split module must stay on the export path")
	}
}

// TestPackageNeedsSyntheticSourceCompileIncludesExternalStdlibUsers verifies
// that the recursive helper closure now source-compiles non-cgo dependencies
// outside the root Datadog helper families when they import woven stdlib
// packages such as log/slog.
func TestPackageNeedsSyntheticSourceCompileIncludesExternalStdlibUsers(t *testing.T) {
	metaCache := map[string]*modulePackageMetadata{
		"example.com/helper/external": {
			Dir:        "/tmp/external",
			ImportPath: "example.com/helper/external",
			GoFiles:    []string{"external.go"},
			Imports:    []string{"log/slog"},
		},
	}

	got, err := packageNeedsSyntheticSourceCompile(
		nil,
		"",
		"",
		"example.com/helper/external",
		map[string]bool{},
		map[string]bool{},
		metaCache,
		map[string]bool{},
	)
	if err != nil {
		t.Fatalf("packageNeedsSyntheticSourceCompile error: %v", err)
	}
	if !got {
		t.Fatal("external package importing log/slog should be source-compiled")
	}
}

// TestPackageNeedsSyntheticSourceCompilePropagatesAcrossExternalDeps verifies
// that packages above a non-root external stdlib user also join the recursive
// source-compiled closure so their compiled fingerprints stay aligned.
func TestPackageNeedsSyntheticSourceCompilePropagatesAcrossExternalDeps(t *testing.T) {
	metaCache := map[string]*modulePackageMetadata{
		"example.com/helper/parent": {
			Dir:        "/tmp/parent",
			ImportPath: "example.com/helper/parent",
			GoFiles:    []string{"parent.go"},
			Imports:    []string{"example.com/helper/external"},
		},
		"example.com/helper/external": {
			Dir:        "/tmp/external",
			ImportPath: "example.com/helper/external",
			GoFiles:    []string{"external.go"},
			Imports:    []string{"log/slog"},
		},
	}
	decisions := map[string]bool{}

	got, err := packageNeedsSyntheticSourceCompile(
		nil,
		"",
		"",
		"example.com/helper/parent",
		map[string]bool{},
		decisions,
		metaCache,
		map[string]bool{},
	)
	if err != nil {
		t.Fatalf("packageNeedsSyntheticSourceCompile error: %v", err)
	}
	if !got {
		t.Fatal("parent of external log/slog user should be source-compiled")
	}
	if !decisions["example.com/helper/external"] {
		t.Fatalf("expected external dependency decision to be true, got %v", decisions["example.com/helper/external"])
	}
}
