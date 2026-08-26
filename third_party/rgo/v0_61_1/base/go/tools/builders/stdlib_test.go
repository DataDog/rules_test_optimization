package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
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

	cleanup, err := ensureSyntheticOrchestrionToolGo(false, orchestrionModeGeneral)
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

	cleanup, err = ensureSyntheticOrchestrionToolGo(false, orchestrionModeTestOptimization)
	if err != nil {
		t.Fatalf("ensureSyntheticOrchestrionToolGo test_optimization error: %v", err)
	}
	defer cleanup()
	content, err = os.ReadFile("orchestrion.tool.go")
	if err != nil {
		t.Fatalf("read test_optimization orchestrion.tool.go: %v", err)
	}
	text = string(content)
	for _, needle := range []string{
		`_ "github.com/DataDog/orchestrion"`,
		`_ "github.com/DataDog/dd-trace-go/v2/orchestrion"`,
	} {
		if !strings.Contains(text, needle) {
			t.Fatalf("test_optimization orchestrion.tool.go missing %q:\n%s", needle, text)
		}
	}
	for _, excluded := range []string{
		`github.com/DataDog/dd-trace-go/contrib/log/slog/v2`,
		`github.com/DataDog/dd-trace-go/contrib/net/http/v2`,
	} {
		if strings.Contains(text, excluded) {
			t.Fatalf("test_optimization orchestrion.tool.go should exclude %q:\n%s", excluded, text)
		}
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

func TestPrepareStdlibCachesWithoutDeclaredOutput(t *testing.T) {
	output := filepath.Join(t.TempDir(), "stdlib")
	scratch, declared, cleanup, err := prepareStdlibCaches(output, "")
	if err != nil {
		t.Fatalf("prepareStdlibCaches error: %v", err)
	}
	if want := filepath.Join(abs(output), ".gocache"); scratch != want {
		t.Fatalf("scratch cache = %q, want %q", scratch, want)
	}
	if declared != "" {
		t.Fatalf("declared cache = %q, want empty", declared)
	}
	if info, err := os.Stat(scratch); err != nil || !info.IsDir() {
		t.Fatalf("scratch cache was not created: %v", err)
	}
	cleanup()
	if _, err := os.Stat(scratch); !os.IsNotExist(err) {
		t.Fatalf("scratch cache still exists after cleanup: %v", err)
	}
}

func TestPrepareStdlibCachesSeparatesDeclaredOutput(t *testing.T) {
	root := t.TempDir()
	output := filepath.Join(root, "stdlib")
	cacheOut := filepath.Join(root, "declared")
	scratch, declared, cleanup, err := prepareStdlibCaches(output, cacheOut)
	if err != nil {
		t.Fatalf("prepareStdlibCaches error: %v", err)
	}
	if sameFilePath(scratch, declared) {
		t.Fatalf("scratch cache %q aliases declared cache %q", scratch, declared)
	}
	for name, path := range map[string]string{"scratch": scratch, "declared": declared} {
		if info, err := os.Stat(path); err != nil || !info.IsDir() {
			t.Fatalf("%s cache was not created: %v", name, err)
		}
	}
	cleanup()
	if _, err := os.Stat(scratch); !os.IsNotExist(err) {
		t.Fatalf("scratch cache still exists after cleanup: %v", err)
	}
	if info, err := os.Stat(declared); err != nil || !info.IsDir() {
		t.Fatalf("declared cache should remain after scratch cleanup: %v", err)
	}
}

func TestPrepareStdlibCachesNormalizesRelativeInputs(t *testing.T) {
	root := t.TempDir()
	previousWD, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatalf("chdir: %v", err)
	}
	defer func() { _ = os.Chdir(previousWD) }()
	normalizedRoot, err := os.Getwd()
	if err != nil {
		t.Fatalf("get normalized workdir: %v", err)
	}

	scratch, declared, cleanup, err := prepareStdlibCaches("stdlib", "declared")
	if err != nil {
		t.Fatalf("prepareStdlibCaches error: %v", err)
	}
	defer cleanup()
	if !filepath.IsAbs(scratch) || !filepath.IsAbs(declared) {
		t.Fatalf("cache paths are not absolute: scratch=%q declared=%q", scratch, declared)
	}
	if scratch != filepath.Join(normalizedRoot, "stdlib", ".gocache") {
		t.Fatalf("scratch cache = %q", scratch)
	}
	if declared != filepath.Join(normalizedRoot, "declared") {
		t.Fatalf("declared cache = %q", declared)
	}
}

func TestPrepareStdlibCachesRejectsAliasedOutput(t *testing.T) {
	output := filepath.Join(t.TempDir(), "stdlib")
	alias := filepath.Join(output, ".gocache")
	if _, _, _, err := prepareStdlibCaches(output, alias); err == nil || !strings.Contains(err.Error(), "aliases declared cache") {
		t.Fatalf("prepareStdlibCaches alias error = %v", err)
	}
	if _, err := os.Stat(alias); !os.IsNotExist(err) {
		t.Fatalf("aliased scratch cache still exists after failure: %v", err)
	}
}

func TestNewBufferedCommandPreservesWritableGoCache(t *testing.T) {
	scratch := filepath.Join(t.TempDir(), "scratch")
	declared := filepath.Join(t.TempDir(), "declared")
	if err := os.MkdirAll(declared, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOCACHE", scratch)

	cmd := (&env{stdlibCache: declared}).newBufferedCommand([]string{"go", "version"}, &bytes.Buffer{})
	if got := getEnv(cmd.Env, "GOCACHE"); got != scratch {
		t.Fatalf("GOCACHE = %q, want writable cache %q", got, scratch)
	}
	if got := getEnv(cmd.Env, orchestrionStdlibCacheEnvVar); got != declared {
		t.Fatalf("%s = %q, want %q", orchestrionStdlibCacheEnvVar, got, declared)
	}

	for _, invalid := range []string{"", filepath.Join(t.TempDir(), "missing")} {
		cmd = (&env{stdlibCache: invalid}).newBufferedCommand([]string{"go", "version"}, &bytes.Buffer{})
		if got := getEnv(cmd.Env, "GOCACHE"); got != scratch {
			t.Fatalf("invalid declared cache %q replaced GOCACHE with %q", invalid, got)
		}
		if got := getEnv(cmd.Env, orchestrionStdlibCacheEnvVar); got != "" {
			t.Fatalf("invalid declared cache %q set %s=%q", invalid, orchestrionStdlibCacheEnvVar, got)
		}
	}
}

func TestPublishPersistedOrchestrionExportsIsDeterministic(t *testing.T) {
	archives := map[string][]byte{
		"fmt": []byte("woven fmt archive"),
		"log": []byte("woven log archive"),
	}
	cachePaths := map[string]string{
		"fmt": filepath.Join("11", "fmt-d"),
		"log": filepath.Join("aa", "log-d"),
	}

	inventories := make([]map[string]string, 0, 2)
	for run := 0; run < 2; run++ {
		scratch := filepath.Join(t.TempDir(), "scratch")
		declared := filepath.Join(t.TempDir(), "declared")
		persisted := filepath.Join(t.TempDir(), "persisted")
		if err := os.MkdirAll(scratch, 0o755); err != nil {
			t.Fatal(err)
		}
		exports := make(map[string]string, len(archives))
		resolved := make(map[string]string, len(cachePaths))
		for pkg, data := range archives {
			src := filepath.Join(persisted, pkg+".a")
			writeTestFile(t, src, data)
			exports[pkg] = src
			resolved[pkg] = filepath.Join(scratch, cachePaths[pkg])
			writeTestFile(t, resolved[pkg], []byte(fmt.Sprintf("unwoven run %d", run)))
		}
		writeTestFile(t, filepath.Join(scratch, "11", "fmt-a"), []byte(fmt.Sprintf("timestamp %d", run)))
		writeTestFile(t, filepath.Join(scratch, "trim.txt"), []byte(fmt.Sprintf("trim %d", run)))
		writeTestFile(t, filepath.Join(scratch, "unrelated", "entry-d"), []byte(fmt.Sprintf("unrelated %d", run)))

		if err := publishPersistedOrchestrionExportsToCache(exports, resolved, scratch, declared, false); err != nil {
			t.Fatalf("publish run %d: %v", run, err)
		}
		inventory := testTreeInventory(t, declared)
		inventories = append(inventories, inventory)
		if len(inventory) != len(archives)+1 {
			t.Fatalf("declared inventory has unexpected entries: %v", inventory)
		}
		for pkg, data := range archives {
			path := filepath.ToSlash(cachePaths[pkg])
			if got := inventory[path]; got != testDigest(data) {
				t.Fatalf("published %s digest = %q, want %q", path, got, testDigest(data))
			}
		}
		manifest, err := os.ReadFile(filepath.Join(declared, orchestrionStdlibCacheManifestName))
		if err != nil {
			t.Fatal(err)
		}
		wantManifest := "fmt=11/fmt-d\nlog=aa/log-d\n"
		if string(manifest) != wantManifest {
			t.Fatalf("manifest = %q, want %q", string(manifest), wantManifest)
		}
	}
	if !reflect.DeepEqual(inventories[0], inventories[1]) {
		t.Fatalf("declared cache inventories differ:\nrun 1: %v\nrun 2: %v", inventories[0], inventories[1])
	}
}

func TestProjectStdlibCacheArchiveRejectsInvalidPaths(t *testing.T) {
	root := t.TempDir()
	scratch := filepath.Join(root, "scratch")
	declared := filepath.Join(root, "declared")
	tests := []struct {
		name    string
		archive string
		want    string
	}{
		{name: "outside scratch", archive: filepath.Join(root, "outside", "entry-d"), want: "escapes scratch root"},
		{name: "action index", archive: filepath.Join(scratch, "aa", "entry-a"), want: "not a Go cache data entry"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, _, err := projectStdlibCacheArchive(scratch, declared, tt.archive); err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("projectStdlibCacheArchive error = %v, want %q", err, tt.want)
			}
		})
	}
}

func TestPublishPersistedOrchestrionExportsFailureLeavesNoManifest(t *testing.T) {
	root := t.TempDir()
	scratch := filepath.Join(root, "scratch")
	declared := filepath.Join(root, "declared")
	manifest := filepath.Join(declared, orchestrionStdlibCacheManifestName)
	writeTestFile(t, manifest, []byte("stale=stale-d\n"))

	err := publishPersistedOrchestrionExportsToCache(
		map[string]string{},
		map[string]string{"fmt": filepath.Join(scratch, "aa", "fmt-d")},
		scratch,
		declared,
		false,
	)
	if err == nil || !strings.Contains(err.Error(), "missing persisted stdlib archive for cache package fmt") {
		t.Fatalf("publish error = %v", err)
	}
	if _, err := os.Stat(manifest); !os.IsNotExist(err) {
		t.Fatalf("manifest exists after failed publication: %v", err)
	}
}

func TestMergeGoDebugSettingPreservesExistingFlags(t *testing.T) {
	tests := []struct {
		name     string
		existing string
		setting  string
		want     string
	}{
		{
			name:    "empty",
			setting: "installgoroot=all",
			want:    "installgoroot=all",
		},
		{
			name:     "preserve windows symlink flag",
			existing: "winsymlink=0",
			setting:  "installgoroot=all",
			want:     "winsymlink=0,installgoroot=all",
		},
		{
			name:     "replace existing key",
			existing: "winsymlink=0,installgoroot=0",
			setting:  "installgoroot=all",
			want:     "winsymlink=0,installgoroot=all",
		},
	}
	for _, tt := range tests {
		if got := mergeGoDebugSetting(tt.existing, tt.setting); got != tt.want {
			t.Fatalf("%s: mergeGoDebugSetting(%q, %q) = %q, want %q", tt.name, tt.existing, tt.setting, got, tt.want)
		}
	}
}

func TestPersistOrchestrionStdlibExportsUsesGoToolInstallDir(t *testing.T) {
	t.Setenv("GOOS", "windows")
	t.Setenv("GOARCH", "amd64")

	tempDir := t.TempDir()
	goroot := filepath.Join(tempDir, "goroot")
	installSuffix := "windows_amd64"
	goToolPkgRoot := filepath.Join(goroot, "pkg", "windows_amd64_windows_amd64")
	for _, pkg := range []string{"testing", "net/http"} {
		archivePath := filepath.Join(goToolPkgRoot, filepath.FromSlash(pkg)+".a")
		if err := os.MkdirAll(filepath.Dir(archivePath), 0o755); err != nil {
			t.Fatalf("mkdir archive: %v", err)
		}
		if err := os.WriteFile(archivePath, []byte(pkg), 0o644); err != nil {
			t.Fatalf("write archive: %v", err)
		}
	}

	goenv := &env{
		goroot:        goroot,
		installSuffix: installSuffix,
	}
	if err := persistOrchestrionStdlibExports(goenv, nil, false); err != nil {
		t.Fatalf("persistOrchestrionStdlibExports error: %v", err)
	}

	persistedRoot := filepath.Join(goroot, "pkg", orchestrionStdlibExportDirName, installSuffix)
	for _, pkg := range []string{"testing", "net/http"} {
		persistedPath := filepath.Join(persistedRoot, filepath.FromSlash(pkg)+".a")
		data, err := os.ReadFile(persistedPath)
		if err != nil {
			t.Fatalf("read persisted archive %s: %v", pkg, err)
		}
		if string(data) != pkg {
			t.Fatalf("persisted archive %s = %q, want %q", pkg, string(data), pkg)
		}
	}

	manifest, err := os.ReadFile(filepath.Join(persistedRoot, orchestrionStdlibExportManifestName))
	if err != nil {
		t.Fatalf("read persisted manifest: %v", err)
	}
	for _, want := range []string{"testing=testing.a", "net/http=net/http.a"} {
		if !strings.Contains(string(manifest), want) {
			t.Fatalf("manifest missing %q:\n%s", want, string(manifest))
		}
	}
}

func writeTestFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func testTreeInventory(t *testing.T, root string) map[string]string {
	t.Helper()
	inventory := make(map[string]string)
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == root || entry.IsDir() {
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("unexpected symlink %s", path)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		inventory[filepath.ToSlash(rel)] = testDigest(data)
		return nil
	})
	if err != nil {
		t.Fatalf("inventory %s: %v", root, err)
	}
	return inventory
}

func testDigest(data []byte) string {
	sum := sha256.Sum256(data)
	return fmt.Sprintf("%x", sum[:])
}
