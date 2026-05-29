package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRewriteImportcfgForDefaultCacheStdlibExportsIgnoresPlainCache(t *testing.T) {
	importcfgPath := filepath.Join(t.TempDir(), "importcfg")
	original := strings.Join([]string{
		"packagefile fmt=/bazel-out/stdlib/pkg/fmt.a",
		"packagefile os=/bazel-out/stdlib/pkg/os.a",
		"",
	}, "\n")
	if err := os.WriteFile(importcfgPath, []byte(original), 0o644); err != nil {
		t.Fatalf("write importcfg: %v", err)
	}

	goroot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(goroot, "src"), 0o755); err != nil {
		t.Fatalf("mkdir goroot src: %v", err)
	}
	goenv := &env{
		sdk:         t.TempDir(),
		goroot:      goroot,
		stdlibCache: t.TempDir(),
	}
	if err := rewriteImportcfgForDefaultCacheStdlibExports(importcfgPath, goenv); err != nil {
		t.Fatalf("rewrite importcfg: %v", err)
	}
	data, err := os.ReadFile(importcfgPath)
	if err != nil {
		t.Fatalf("read importcfg: %v", err)
	}
	if string(data) != original {
		t.Fatalf("importcfg changed for plain stdlib cache:\n%s", string(data))
	}
}

func TestRewriteImportcfgFromCurrentStdlibEntriesIgnoresPlainCache(t *testing.T) {
	importcfgPath := filepath.Join(t.TempDir(), "importcfg")
	original := strings.Join([]string{
		"packagefile fmt=/bazel-out/stdlib/pkg/fmt.a",
		"packagefile runtime=/bazel-out/stdlib/pkg/runtime.a",
		"",
	}, "\n")
	if err := os.WriteFile(importcfgPath, []byte(original), 0o644); err != nil {
		t.Fatalf("write importcfg: %v", err)
	}

	goroot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(goroot, "src"), 0o755); err != nil {
		t.Fatalf("mkdir goroot src: %v", err)
	}
	goenv := &env{
		sdk:         t.TempDir(),
		goroot:      goroot,
		stdlibCache: t.TempDir(),
	}
	if err := rewriteImportcfgFromCurrentStdlibEntries(importcfgPath, goenv); err != nil {
		t.Fatalf("rewrite importcfg: %v", err)
	}
	data, err := os.ReadFile(importcfgPath)
	if err != nil {
		t.Fatalf("read importcfg: %v", err)
	}
	if string(data) != original {
		t.Fatalf("importcfg changed for plain stdlib cache:\n%s", string(data))
	}
}

func TestRewriteImportcfgFromCurrentStdlibEntriesUsesPersistedMissingExports(t *testing.T) {
	tempDir := t.TempDir()
	importcfgPath := filepath.Join(tempDir, "importcfg")
	original := strings.Join([]string{
		"packagefile net/http=/bazel-out/stdlib/pkg/net/http.a",
		"packagefile net/url=/bazel-out/stdlib/pkg/net/url.a",
		"packagefile os=/bazel-out/stdlib/pkg/os.a",
		"",
	}, "\n")
	if err := os.WriteFile(importcfgPath, []byte(original), 0o644); err != nil {
		t.Fatalf("write importcfg: %v", err)
	}

	goroot := filepath.Join(tempDir, "goroot")
	installSuffix := "darwin_arm64"
	persistedRoot := filepath.Join(goroot, "pkg", orchestrionStdlibExportDirName, installSuffix)
	for _, pkg := range []string{"net/http", "net/url"} {
		archivePath := filepath.Join(persistedRoot, filepath.FromSlash(pkg)+".a")
		if err := os.MkdirAll(filepath.Dir(archivePath), 0o755); err != nil {
			t.Fatalf("mkdir persisted archive: %v", err)
		}
		if err := os.WriteFile(archivePath, []byte(pkg), 0o644); err != nil {
			t.Fatalf("write persisted archive: %v", err)
		}
	}
	if err := os.WriteFile(filepath.Join(persistedRoot, orchestrionStdlibExportManifestName), []byte("net/http=net/http.a\nnet/url=net/url.a\n"), 0o644); err != nil {
		t.Fatalf("write persisted manifest: %v", err)
	}

	cacheDir := filepath.Join(tempDir, "cache")
	cacheOSArchive := filepath.Join(cacheDir, "os-cache.a")
	if err := os.MkdirAll(filepath.Dir(cacheOSArchive), 0o755); err != nil {
		t.Fatalf("mkdir cache archive: %v", err)
	}
	if err := os.WriteFile(cacheOSArchive, []byte("os"), 0o644); err != nil {
		t.Fatalf("write cache archive: %v", err)
	}
	if err := os.WriteFile(filepath.Join(cacheDir, orchestrionStdlibCacheManifestName), []byte("os=os-cache.a\n"), 0o644); err != nil {
		t.Fatalf("write cache manifest: %v", err)
	}

	goenv := &env{
		goroot:        goroot,
		installSuffix: installSuffix,
		stdlibCache:   cacheDir,
	}
	if err := rewriteImportcfgFromCurrentStdlibEntries(importcfgPath, goenv); err != nil {
		t.Fatalf("rewrite importcfg: %v", err)
	}
	data, err := os.ReadFile(importcfgPath)
	if err != nil {
		t.Fatalf("read importcfg: %v", err)
	}
	got := string(data)
	for _, want := range []string{
		"packagefile net/http=" + filepath.Join(persistedRoot, "net/http.a"),
		"packagefile net/url=" + filepath.Join(persistedRoot, "net/url.a"),
		"packagefile os=" + cacheOSArchive,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("rewritten importcfg missing %q:\n%s", want, got)
		}
	}
}

func TestModuleExportRequestKeyIncludesStdlibCacheState(t *testing.T) {
	moduleDir := t.TempDir()
	for _, name := range []string{"go.mod", "orchestrion.tool.go", "orchestrion.yml"} {
		if err := os.WriteFile(filepath.Join(moduleDir, name), []byte(name+"\n"), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	cacheDir := filepath.Join(t.TempDir(), "gocache")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatalf("mkdir cache: %v", err)
	}
	testingArchiveV1 := filepath.Join(cacheDir, "aa", "testing-v1-d")
	if err := os.MkdirAll(filepath.Dir(testingArchiveV1), 0o755); err != nil {
		t.Fatalf("mkdir testing archive dir: %v", err)
	}
	if err := os.WriteFile(testingArchiveV1, []byte("testing-v1"), 0o644); err != nil {
		t.Fatalf("write testing archive v1: %v", err)
	}
	manifestPath := filepath.Join(cacheDir, orchestrionStdlibCacheManifestName)
	manifestV1 := "testing=aa/testing-v1-d\nruntime=aa/testing-v1-d\nfmt=aa/testing-v1-d\nflag=aa/testing-v1-d\nlog=aa/testing-v1-d\n"
	if err := os.WriteFile(manifestPath, []byte(manifestV1), 0o644); err != nil {
		t.Fatalf("write manifest v1: %v", err)
	}

	goenv := &env{stdlibCache: cacheDir, orchestrionMode: orchestrionModeGeneral}
	keyV1, _, err := moduleExportRequestKey(moduleDir, goenv, []string{"github.com/DataDog/dd-trace-go/v2"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey v1 error: %v", err)
	}

	testingArchiveV2 := filepath.Join(cacheDir, "bb", "testing-v2-d")
	if err := os.MkdirAll(filepath.Dir(testingArchiveV2), 0o755); err != nil {
		t.Fatalf("mkdir testing archive dir v2: %v", err)
	}
	if err := os.WriteFile(testingArchiveV2, []byte("testing-v2"), 0o644); err != nil {
		t.Fatalf("write testing archive v2: %v", err)
	}
	manifestV2 := "testing=bb/testing-v2-d\nruntime=bb/testing-v2-d\nfmt=bb/testing-v2-d\nflag=bb/testing-v2-d\nlog=bb/testing-v2-d\n"
	if err := os.WriteFile(manifestPath, []byte(manifestV2), 0o644); err != nil {
		t.Fatalf("write manifest v2: %v", err)
	}

	keyV2, _, err := moduleExportRequestKey(moduleDir, goenv, []string{"github.com/DataDog/dd-trace-go/v2"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey v2 error: %v", err)
	}
	if keyV1 == keyV2 {
		t.Fatalf("moduleExportRequestKey did not change when stdlib cache changed: %q", keyV1)
	}
}

func TestModuleExportRequestKeyIncludesLogSlogStdlibCacheState(t *testing.T) {
	moduleDir := t.TempDir()
	for _, name := range []string{"go.mod", "orchestrion.tool.go", "orchestrion.yml"} {
		if err := os.WriteFile(filepath.Join(moduleDir, name), []byte(name+"\n"), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	cacheDir := filepath.Join(t.TempDir(), "gocache")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatalf("mkdir cache: %v", err)
	}
	writeArchive := func(relPath, content string) {
		path := filepath.Join(cacheDir, relPath)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("mkdir archive dir for %s: %v", relPath, err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatalf("write archive %s: %v", relPath, err)
		}
	}

	writeArchive("aa/testing-d", "testing")
	writeArchive("aa/runtime-d", "runtime")
	writeArchive("aa/fmt-d", "fmt")
	writeArchive("aa/flag-d", "flag")
	writeArchive("aa/log-d", "log")
	writeArchive("aa/log-slog-v1-d", "log-slog-v1")
	manifestPath := filepath.Join(cacheDir, orchestrionStdlibCacheManifestName)
	manifestV1 := strings.Join([]string{
		"testing=aa/testing-d",
		"runtime=aa/runtime-d",
		"fmt=aa/fmt-d",
		"flag=aa/flag-d",
		"log=aa/log-d",
		"log/slog=aa/log-slog-v1-d",
		"",
	}, "\n")
	if err := os.WriteFile(manifestPath, []byte(manifestV1), 0o644); err != nil {
		t.Fatalf("write manifest v1: %v", err)
	}

	goenv := &env{stdlibCache: cacheDir}
	keyV1, _, err := moduleExportRequestKey(moduleDir, goenv, []string{"github.com/DataDog/dd-trace-go/v2"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey v1 error: %v", err)
	}

	writeArchive("bb/log-slog-v2-d", "log-slog-v2")
	manifestV2 := strings.Join([]string{
		"testing=aa/testing-d",
		"runtime=aa/runtime-d",
		"fmt=aa/fmt-d",
		"flag=aa/flag-d",
		"log=aa/log-d",
		"log/slog=bb/log-slog-v2-d",
		"",
	}, "\n")
	if err := os.WriteFile(manifestPath, []byte(manifestV2), 0o644); err != nil {
		t.Fatalf("write manifest v2: %v", err)
	}

	keyV2, _, err := moduleExportRequestKey(moduleDir, goenv, []string{"github.com/DataDog/dd-trace-go/v2"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey v2 error: %v", err)
	}
	if keyV1 == keyV2 {
		t.Fatalf("moduleExportRequestKey ignored log/slog stdlib cache change: %q", keyV1)
	}

	testOptEnv := &env{stdlibCache: cacheDir, orchestrionMode: orchestrionModeTestOptimization}
	keyTestOptV2, _, err := moduleExportRequestKey(moduleDir, testOptEnv, []string{"github.com/DataDog/dd-trace-go/v2"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey test_optimization v2 error: %v", err)
	}
	if err := os.WriteFile(manifestPath, []byte(manifestV1), 0o644); err != nil {
		t.Fatalf("restore manifest v1: %v", err)
	}
	keyTestOptV1, _, err := moduleExportRequestKey(moduleDir, testOptEnv, []string{"github.com/DataDog/dd-trace-go/v2"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey test_optimization v1 error: %v", err)
	}
	if keyTestOptV1 == keyTestOptV2 {
		t.Fatalf("test_optimization key ignored log/slog stdlib cache change: %q", keyTestOptV1)
	}
}

func TestModuleExportRequestKeyIgnoresSyntheticTempDir(t *testing.T) {
	t.Setenv(rulesGoOrchestrionToolVersionFileEnvVar, writeOrchestrionToolVersionFile(t, "v1.6.0"))
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, writeDDTraceGoVersionsFile(t, `{"modules":{"github.com/DataDog/dd-trace-go/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/net/http/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/log/slog/v2":"v2.7.3"}}`))
	moduleDirs := []string{
		filepath.Join(t.TempDir(), "one"),
		filepath.Join(t.TempDir(), "two"),
	}
	for _, moduleDir := range moduleDirs {
		if err := os.MkdirAll(moduleDir, 0o755); err != nil {
			t.Fatalf("mkdir module dir: %v", err)
		}
		for name, content := range map[string]string{
			"go.mod":              syntheticOrchestrionGoMod("v1.6.0", defaultDDTraceGoVersions(), orchestrionModeGeneral),
			"orchestrion.tool.go": syntheticOrchestrionToolGo,
			"orchestrion.yml":     "injectors: []\n",
		} {
			if err := os.WriteFile(filepath.Join(moduleDir, name), []byte(content), 0o644); err != nil {
				t.Fatalf("write %s: %v", name, err)
			}
		}
	}
	goenv := &env{}
	key1, _, err := moduleExportRequestKey(moduleDirs[0], goenv, []string{"github.com/DataDog/dd-trace-go/v2"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey dir1 error: %v", err)
	}
	key2, _, err := moduleExportRequestKey(moduleDirs[1], goenv, []string{"github.com/DataDog/dd-trace-go/v2"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey dir2 error: %v", err)
	}
	if key1 != key2 {
		t.Fatalf("synthetic module export key mismatch: %q != %q", key1, key2)
	}
}

func TestModuleExportRequestKeyIgnoresSyntheticGoModGoSumDrift(t *testing.T) {
	t.Setenv(rulesGoOrchestrionToolVersionFileEnvVar, writeOrchestrionToolVersionFile(t, "v1.6.0"))
	t.Setenv(rulesGoOrchestrionVersionFileEnvVar, writeDDTraceGoVersionsFile(t, `{"modules":{"github.com/DataDog/dd-trace-go/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/net/http/v2":"v2.7.3","github.com/DataDog/dd-trace-go/contrib/log/slog/v2":"v2.7.3"}}`))
	moduleDirs := []string{
		filepath.Join(t.TempDir(), "one"),
		filepath.Join(t.TempDir(), "two"),
	}
	for idx, moduleDir := range moduleDirs {
		if err := os.MkdirAll(moduleDir, 0o755); err != nil {
			t.Fatalf("mkdir module dir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(moduleDir, "go.mod"), []byte(syntheticOrchestrionGoMod("v1.6.0", defaultDDTraceGoVersions(), orchestrionModeGeneral)+"\n// temp drift\n"), 0o644); err != nil {
			t.Fatalf("write go.mod: %v", err)
		}
		if err := os.WriteFile(filepath.Join(moduleDir, "orchestrion.tool.go"), []byte(syntheticOrchestrionToolGo), 0o644); err != nil {
			t.Fatalf("write orchestrion.tool.go: %v", err)
		}
		if idx == 0 {
			if err := os.WriteFile(filepath.Join(moduleDir, "go.sum"), []byte("transient-sum\n"), 0o644); err != nil {
				t.Fatalf("write go.sum: %v", err)
			}
		}
	}
	goenv := &env{}
	key1, _, err := moduleExportRequestKey(moduleDirs[0], goenv, []string{"github.com/DataDog/dd-trace-go/v2"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey dir1 error: %v", err)
	}
	key2, _, err := moduleExportRequestKey(moduleDirs[1], goenv, []string{"github.com/DataDog/dd-trace-go/v2"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey dir2 error: %v", err)
	}
	if key1 != key2 {
		t.Fatalf("synthetic module export key changed with transient go.mod/go.sum drift: %q != %q", key1, key2)
	}
}

func TestModuleExportRequestKeyIncludesNormalizedPackageSet(t *testing.T) {
	moduleDir := t.TempDir()
	for name, content := range map[string]string{
		"go.mod":              "module example.com/test\n",
		"orchestrion.tool.go": syntheticOrchestrionToolGo,
		"orchestrion.yml":     "injectors: []\n",
	} {
		if err := os.WriteFile(filepath.Join(moduleDir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	goenv := &env{}
	keyA, _, err := moduleExportRequestKey(moduleDir, goenv, []string{"b/pkg", "a/pkg", "b/pkg"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey keyA error: %v", err)
	}
	keyB, _, err := moduleExportRequestKey(moduleDir, goenv, []string{"a/pkg", "b/pkg"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey keyB error: %v", err)
	}
	keyC, _, err := moduleExportRequestKey(moduleDir, goenv, []string{"a/pkg"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey keyC error: %v", err)
	}
	if keyA != keyB {
		t.Fatalf("normalized package set mismatch: %q != %q", keyA, keyB)
	}
	if keyA == keyC {
		t.Fatalf("moduleExportRequestKey ignored package set: %q", keyA)
	}
}

func TestModuleExportRequestKeyIncludesMode(t *testing.T) {
	moduleDir := t.TempDir()
	for name, content := range map[string]string{
		"go.mod":              "module example.com/test\n",
		"orchestrion.tool.go": syntheticOrchestrionToolGo,
		"orchestrion.yml":     "injectors: []\n",
	} {
		if err := os.WriteFile(filepath.Join(moduleDir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	keyGeneral, partsGeneral, err := moduleExportRequestKey(moduleDir, &env{orchestrionMode: orchestrionModeGeneral}, []string{"a/pkg"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey general error: %v", err)
	}
	keyTestOpt, partsTestOpt, err := moduleExportRequestKey(moduleDir, &env{orchestrionMode: orchestrionModeTestOptimization}, []string{"a/pkg"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey test_optimization error: %v", err)
	}
	if keyGeneral == keyTestOpt {
		t.Fatalf("module export request key should differ by mode: %q", keyGeneral)
	}
	if !containsString(partsGeneral, "orchestrion_mode=general") || !containsString(partsTestOpt, "orchestrion_mode=test_optimization") {
		t.Fatalf("module export request key parts missing mode: general=%v test_optimization=%v", partsGeneral, partsTestOpt)
	}
}

func TestModuleExportRequestKeyIgnoresSdkExecrootPath(t *testing.T) {
	moduleDir := t.TempDir()
	for name, content := range map[string]string{
		"go.mod":              "module example.com/test\n",
		"orchestrion.tool.go": syntheticOrchestrionToolGo,
		"orchestrion.yml":     "injectors: []\n",
	} {
		if err := os.WriteFile(filepath.Join(moduleDir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

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

	keyA, _, err := moduleExportRequestKey(moduleDir, &env{sdk: makeSDK(filepath.Join(t.TempDir(), "execroot-a"))}, []string{"a/pkg", "b/pkg"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey sdk A error: %v", err)
	}
	keyB, _, err := moduleExportRequestKey(moduleDir, &env{sdk: makeSDK(filepath.Join(t.TempDir(), "execroot-b"))}, []string{"a/pkg", "b/pkg"})
	if err != nil {
		t.Fatalf("moduleExportRequestKey sdk B error: %v", err)
	}
	if keyA != keyB {
		t.Fatalf("moduleExportRequestKey changed across equivalent sdk paths: %q != %q", keyA, keyB)
	}
}

func TestModuleExportCacheManifestRoundTrip(t *testing.T) {
	root := t.TempDir()
	paths := orchestrionCachePaths(root, "module-exports", "abc123")
	if err := os.MkdirAll(paths.entryDir, 0o755); err != nil {
		t.Fatalf("mkdir entry dir: %v", err)
	}
	archivePath := filepath.Join(paths.entryDir, "aa", "pkg.a.nolinkdeps")
	if err := os.MkdirAll(filepath.Dir(archivePath), 0o755); err != nil {
		t.Fatalf("mkdir archive dir: %v", err)
	}
	if err := os.WriteFile(archivePath, []byte("archive"), 0o644); err != nil {
		t.Fatalf("write archive: %v", err)
	}
	exports := map[string]string{"example.com/pkg": archivePath}
	if err := writeModuleExportCache(paths, []string{"packages=example.com/pkg"}, []string{"example.com/pkg"}, exports); err != nil {
		t.Fatalf("writeModuleExportCache error: %v", err)
	}
	got, err := loadModuleExportCache(paths)
	if err != nil {
		t.Fatalf("loadModuleExportCache error: %v", err)
	}
	if got["example.com/pkg"] != archivePath {
		t.Fatalf("loadModuleExportCache got %q, want %q", got["example.com/pkg"], archivePath)
	}
}

func TestModuleExportCacheManifestRejectsMissingArchive(t *testing.T) {
	root := t.TempDir()
	paths := orchestrionCachePaths(root, "module-exports", "abc123")
	if err := os.MkdirAll(paths.entryDir, 0o755); err != nil {
		t.Fatalf("mkdir entry dir: %v", err)
	}
	manifest := moduleExportCacheManifest{
		Key:         "abc123",
		ExportCache: helperExportCacheABIVersion,
		Packages:    []string{"example.com/pkg"},
		Exports:     map[string]string{"example.com/pkg": "missing/pkg.a.nolinkdeps"},
	}
	if err := writeJSONAtomically(paths.manifestPath, manifest); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	if err := writeReadySentinel(paths.readyPath); err != nil {
		t.Fatalf("write ready: %v", err)
	}
	if _, err := loadModuleExportCache(paths); err == nil {
		t.Fatal("loadModuleExportCache unexpectedly succeeded with missing archive")
	}
}

func TestSeedWovenStdlibCacheNoopWhenAlreadyReady(t *testing.T) {
	sourceRoot := filepath.Join(t.TempDir(), "source")
	destRoot := filepath.Join(t.TempDir(), "dest")
	for _, root := range []string{sourceRoot, destRoot} {
		if err := os.MkdirAll(root, 0o755); err != nil {
			t.Fatalf("mkdir root: %v", err)
		}
	}
	sourceArchive := filepath.Join(sourceRoot, "aa", "testing.a")
	if err := os.MkdirAll(filepath.Dir(sourceArchive), 0o755); err != nil {
		t.Fatalf("mkdir source archive dir: %v", err)
	}
	if err := os.WriteFile(sourceArchive, []byte("source"), 0o644); err != nil {
		t.Fatalf("write source archive: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sourceRoot, orchestrionStdlibCacheManifestName), []byte("testing=aa/testing.a\n"), 0o644); err != nil {
		t.Fatalf("write source manifest: %v", err)
	}
	destArchive := filepath.Join(destRoot, "bb", "testing.a")
	if err := os.MkdirAll(filepath.Dir(destArchive), 0o755); err != nil {
		t.Fatalf("mkdir dest archive dir: %v", err)
	}
	if err := os.WriteFile(destArchive, []byte("dest"), 0o644); err != nil {
		t.Fatalf("write dest archive: %v", err)
	}
	manifestPath := filepath.Join(destRoot, orchestrionStdlibCacheManifestName)
	if err := os.WriteFile(manifestPath, []byte("testing=bb/testing.a\n"), 0o644); err != nil {
		t.Fatalf("write dest manifest: %v", err)
	}
	before, err := os.ReadFile(destArchive)
	if err != nil {
		t.Fatalf("read dest archive before seed: %v", err)
	}
	if err := seedWovenStdlibCache(&env{stdlibCache: sourceRoot}, destRoot); err != nil {
		t.Fatalf("seedWovenStdlibCache error: %v", err)
	}
	after, err := os.ReadFile(destArchive)
	if err != nil {
		t.Fatalf("read dest archive after seed: %v", err)
	}
	if string(before) != string(after) {
		t.Fatalf("seedWovenStdlibCache rewrote ready archive: before=%q after=%q", string(before), string(after))
	}
}

func TestStdlibSeedPackagesForModeUsesRequestedFallbackInTestOptimization(t *testing.T) {
	sourceExports := map[string]string{
		"encoding/json": "/cache/encoding-json.a",
		"log/slog":      "/cache/log-slog.a",
		"testing":       "/cache/testing.a",
	}

	general := stdlibSeedPackagesForMode(sourceExports, orchestrionModeGeneral, []string{"testing", "missing"})
	if got, want := strings.Join(general, ","), "testing"; got != want {
		t.Fatalf("general seed packages = %q, want %q", got, want)
	}

	testOptimization := stdlibSeedPackagesForMode(sourceExports, orchestrionModeTestOptimization, []string{"testing"})
	if got, want := strings.Join(testOptimization, ","), "testing"; got != want {
		t.Fatalf("test_optimization seed packages = %q, want %q", got, want)
	}
}

func TestRewriteImportcfgForSyntheticTestmainStdlibTestOptimizationSkipsUnneededStdlib(t *testing.T) {
	tempDir := t.TempDir()
	importcfgPath := filepath.Join(tempDir, "importcfg")
	originalEncodingJSON := "/bazel-out/stdlib/pkg/encoding/json.a"
	original := strings.Join([]string{
		"packagefile encoding/json=" + originalEncodingJSON,
		"packagefile testing=/bazel-out/stdlib/pkg/testing.a",
		"",
	}, "\n")
	if err := os.WriteFile(importcfgPath, []byte(original), 0o644); err != nil {
		t.Fatalf("write importcfg: %v", err)
	}

	cacheDir := filepath.Join(tempDir, "cache")
	cacheEncodingJSON := filepath.Join(cacheDir, "encoding-json-cache.a")
	cacheTesting := filepath.Join(cacheDir, "testing-cache.a")
	for _, path := range []string{cacheEncodingJSON, cacheTesting} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("mkdir cache archive: %v", err)
		}
		if err := os.WriteFile(path, []byte(filepath.Base(path)), 0o644); err != nil {
			t.Fatalf("write cache archive: %v", err)
		}
	}
	manifest := strings.Join([]string{
		"encoding/json=" + filepath.Base(cacheEncodingJSON),
		"testing=" + filepath.Base(cacheTesting),
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(cacheDir, orchestrionStdlibCacheManifestName), []byte(manifest), 0o644); err != nil {
		t.Fatalf("write cache manifest: %v", err)
	}

	goenv := &env{
		orchestrionMode: orchestrionModeTestOptimization,
		stdlibCache:     cacheDir,
	}
	if err := rewriteImportcfgForSyntheticTestmainStdlib(importcfgPath, goenv); err != nil {
		t.Fatalf("rewrite importcfg: %v", err)
	}
	data, err := os.ReadFile(importcfgPath)
	if err != nil {
		t.Fatalf("read importcfg: %v", err)
	}
	got := string(data)
	if !strings.Contains(got, "packagefile encoding/json="+originalEncodingJSON) {
		t.Fatalf("test_optimization rewrote unneeded encoding/json packagefile:\n%s", got)
	}
	if !strings.Contains(got, "packagefile testing="+cacheTesting) {
		t.Fatalf("test_optimization did not rewrite testing packagefile:\n%s", got)
	}
}

func TestRewriteImportcfgForSyntheticTestmainStdlibTestOptimizationUsesPersistedExportsWithoutCache(t *testing.T) {
	tempDir := t.TempDir()
	importcfgPath := filepath.Join(tempDir, "importcfg")
	originalRuntime := "/bazel-out/stdlib/pkg/runtime.a"
	original := strings.Join([]string{
		"packagefile runtime=" + originalRuntime,
		"packagefile testing=/bazel-out/stdlib/pkg/testing.a",
		"",
	}, "\n")
	if err := os.WriteFile(importcfgPath, []byte(original), 0o644); err != nil {
		t.Fatalf("write importcfg: %v", err)
	}

	goroot := filepath.Join(tempDir, "goroot")
	installSuffix := "darwin_arm64"
	persistedRoot := filepath.Join(goroot, "pkg", orchestrionStdlibExportDirName, installSuffix)
	persistedTesting := filepath.Join(persistedRoot, "testing.a")
	if err := os.MkdirAll(filepath.Dir(persistedTesting), 0o755); err != nil {
		t.Fatalf("mkdir persisted testing archive: %v", err)
	}
	if err := os.WriteFile(persistedTesting, []byte("testing"), 0o644); err != nil {
		t.Fatalf("write persisted testing archive: %v", err)
	}
	if err := os.WriteFile(filepath.Join(persistedRoot, orchestrionStdlibExportManifestName), []byte("testing=testing.a\n"), 0o644); err != nil {
		t.Fatalf("write persisted manifest: %v", err)
	}

	goenv := &env{
		goroot:          goroot,
		installSuffix:   installSuffix,
		orchestrionMode: orchestrionModeTestOptimization,
	}
	if err := rewriteImportcfgForSyntheticTestmainStdlib(importcfgPath, goenv); err != nil {
		t.Fatalf("rewrite importcfg: %v", err)
	}
	data, err := os.ReadFile(importcfgPath)
	if err != nil {
		t.Fatalf("read importcfg: %v", err)
	}
	got := string(data)
	if !strings.Contains(got, "packagefile runtime="+originalRuntime) {
		t.Fatalf("test_optimization rewrote unneeded runtime packagefile:\n%s", got)
	}
	if !strings.Contains(got, "packagefile testing="+persistedTesting) {
		t.Fatalf("test_optimization did not rewrite testing from persisted exports without stdlib cache:\n%s", got)
	}
}
