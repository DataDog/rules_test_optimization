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

func TestShouldRemoveStdlibCache(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name            string
		orchestrionPath string
		cacheOut        string
		want            bool
	}{
		{
			name: "plain internal cache",
			want: true,
		},
		{
			name:     "plain declared cache output",
			cacheOut: "bazel-out/bin/external/rules_go/stdlib_/gocache",
			want:     false,
		},
		{
			name:            "orchestrion internal cache",
			orchestrionPath: "external/rules_go_orchestrion_tool/orchestrion",
			want:            false,
		},
		{
			name:            "orchestrion declared cache output",
			orchestrionPath: "external/rules_go_orchestrion_tool/orchestrion",
			cacheOut:        "bazel-out/bin/external/rules_go/stdlib_/gocache",
			want:            false,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := shouldRemoveStdlibCache(tt.orchestrionPath, tt.cacheOut); got != tt.want {
				t.Fatalf("shouldRemoveStdlibCache(%q, %q) = %v, want %v", tt.orchestrionPath, tt.cacheOut, got, tt.want)
			}
		})
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
