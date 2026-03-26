package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCacheEntryReadyRequiresManifestAndReady(t *testing.T) {
	root := t.TempDir()
	paths := orchestrionCachePaths(root, "validation", "abc123")
	if cacheEntryReady(paths) {
		t.Fatal("cache entry should not be ready without files")
	}
	if err := os.MkdirAll(paths.entryDir, 0o755); err != nil {
		t.Fatalf("mkdir entry dir: %v", err)
	}
	if err := os.WriteFile(paths.manifestPath, []byte("{}\n"), 0o644); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	if cacheEntryReady(paths) {
		t.Fatal("cache entry should not be ready without ready sentinel")
	}
	if err := os.WriteFile(paths.readyPath, []byte("ready\n"), 0o644); err != nil {
		t.Fatalf("write ready: %v", err)
	}
	if !cacheEntryReady(paths) {
		t.Fatal("cache entry should be ready once manifest and ready exist")
	}
}

func TestAcquireCacheLockReplacesStaleLock(t *testing.T) {
	lockDir := filepath.Join(t.TempDir(), "cache.lock")
	if err := os.MkdirAll(lockDir, 0o755); err != nil {
		t.Fatalf("mkdir stale lock: %v", err)
	}
	staleTime := time.Now().Add(-2 * time.Minute)
	if err := os.Chtimes(lockDir, staleTime, staleTime); err != nil {
		t.Fatalf("chtimes stale lock: %v", err)
	}

	release, err := acquireCacheLockWithTimings(lockDir, 20*time.Millisecond, time.Minute, 5*time.Millisecond)
	if err != nil {
		t.Fatalf("acquireCacheLockWithTimings error: %v", err)
	}
	if _, err := os.Stat(lockDir); err != nil {
		t.Fatalf("expected lock dir to exist after acquisition: %v", err)
	}
	release()
	if _, err := os.Stat(lockDir); !os.IsNotExist(err) {
		t.Fatalf("expected release to remove lock dir, stat err=%v", err)
	}
}

func TestWriteFileAtomically(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "manifest.json")
	if err := writeFileAtomically(path, []byte("payload\n"), 0o644); err != nil {
		t.Fatalf("writeFileAtomically error: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read atomic file: %v", err)
	}
	if string(data) != "payload\n" {
		t.Fatalf("writeFileAtomically wrote %q", string(data))
	}
}

func TestStdlibSnapshotCacheKeyIgnoresOutputBasePaths(t *testing.T) {
	t.Setenv("CC", "")
	t.Setenv("CGO_CFLAGS", "")
	t.Setenv("CGO_CXXFLAGS", "")
	t.Setenv("CGO_CPPFLAGS", "")
	t.Setenv("CGO_LDFLAGS", "")

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

	pathsA, _, err := stdlibSnapshotCachePaths(
		&env{
			sdk:           makeSDK(filepath.Join(t.TempDir(), "execroot-a")),
			goroot:        filepath.Join(t.TempDir(), "out-a", "stdlib_"),
			stdlibCache:   filepath.Join(t.TempDir(), "out-a", "cache"),
			installSuffix: "linux_amd64_dynlink",
		},
		[]string{"runtime/cgo", "std", "cmd/internal/cov"},
		[]string{"-shared", "-dynlink"},
		false,
		false,
		true,
		true,
	)
	if err != nil {
		t.Fatalf("stdlibSnapshotCachePaths A error: %v", err)
	}

	pathsB, _, err := stdlibSnapshotCachePaths(
		&env{
			sdk:           makeSDK(filepath.Join(t.TempDir(), "execroot-b")),
			goroot:        filepath.Join(t.TempDir(), "out-b", "stdlib_"),
			stdlibCache:   filepath.Join(t.TempDir(), "out-b", "cache"),
			installSuffix: "linux_amd64_dynlink",
		},
		[]string{"cmd/internal/cov", "std", "runtime/cgo"},
		[]string{"-shared", "-dynlink"},
		false,
		false,
		true,
		true,
	)
	if err != nil {
		t.Fatalf("stdlibSnapshotCachePaths B error: %v", err)
	}

	if pathsA.entryDir != pathsB.entryDir {
		t.Fatalf("stdlib snapshot cache path changed across equivalent output bases: %q != %q", pathsA.entryDir, pathsB.entryDir)
	}
}

func TestStdlibSnapshotCacheKeyNormalizesBuildEnvOutputBasePaths(t *testing.T) {
	t.Setenv("CGO_ENABLED", "1")
	t.Setenv("GOOS", "darwin")
	t.Setenv("GOARCH", "arm64")
	t.Setenv("CXX", "")
	t.Setenv("AR", "")
	t.Setenv("CC", "/private/tmp/output-base-a/execroot/_main/external/rules_cc++cc_configure_extension+local_config_cc/cc_wrapper.sh")
	t.Setenv("CGO_CFLAGS", "-fdebug-prefix-map=/private/tmp/output-base-a/execroot/_main=. -fdebug-prefix-map=/private/tmp/output-base-a/execroot/_main/bazel-out/darwin_arm64-fastbuild/bin/external/rules_go+/stdlib_=. -pthread")
	t.Setenv("CGO_CXXFLAGS", "")
	t.Setenv("CGO_CPPFLAGS", "")
	t.Setenv("CGO_LDFLAGS", "-fuse-ld=/private/tmp/output-base-a/execroot/_main/external/custom/bin/ld -L/private/tmp/output-base-a/execroot/_main/bazel-out/darwin_arm64-fastbuild/bin/external/custom/lib -lm")

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

	pathsA, _, err := stdlibSnapshotCachePaths(
		&env{
			sdk:           makeSDK(filepath.Join(t.TempDir(), "execroot-a")),
			goroot:        filepath.Join(t.TempDir(), "out-a", "stdlib_"),
			stdlibCache:   filepath.Join(t.TempDir(), "out-a", "cache"),
			installSuffix: "darwin_arm64",
		},
		[]string{"runtime/cgo", "std", "cmd/internal/cov", "cmd/internal/bio"},
		[]string{"-shared"},
		false,
		false,
		true,
		false,
	)
	if err != nil {
		t.Fatalf("stdlibSnapshotCachePaths A error: %v", err)
	}

	t.Setenv("CC", "/private/tmp/output-base-b/execroot/_main/external/rules_cc++cc_configure_extension+local_config_cc/cc_wrapper.sh")
	t.Setenv("CGO_CFLAGS", "-fdebug-prefix-map=/private/tmp/output-base-b/execroot/_main=. -fdebug-prefix-map=/private/tmp/output-base-b/execroot/_main/bazel-out/darwin_arm64-fastbuild/bin/external/rules_go+/stdlib_=. -pthread")
	t.Setenv("CGO_LDFLAGS", "-fuse-ld=/private/tmp/output-base-b/execroot/_main/external/custom/bin/ld -L/private/tmp/output-base-b/execroot/_main/bazel-out/darwin_arm64-fastbuild/bin/external/custom/lib -lm")

	pathsB, _, err := stdlibSnapshotCachePaths(
		&env{
			sdk:           makeSDK(filepath.Join(t.TempDir(), "execroot-b")),
			goroot:        filepath.Join(t.TempDir(), "out-b", "stdlib_"),
			stdlibCache:   filepath.Join(t.TempDir(), "out-b", "cache"),
			installSuffix: "darwin_arm64",
		},
		[]string{"cmd/internal/bio", "runtime/cgo", "std", "cmd/internal/cov"},
		[]string{"-shared"},
		false,
		false,
		true,
		false,
	)
	if err != nil {
		t.Fatalf("stdlibSnapshotCachePaths B error: %v", err)
	}

	if pathsA.entryDir != pathsB.entryDir {
		t.Fatalf("stdlib snapshot cache path changed across equivalent build envs: %q != %q", pathsA.entryDir, pathsB.entryDir)
	}
}

func TestPersistAndRestoreStdlibSnapshotRoundTrip(t *testing.T) {
	sourceRoot := t.TempDir()
	sourceGoRoot := filepath.Join(sourceRoot, "goroot")
	sourceCache := filepath.Join(sourceRoot, "gocache")
	sourcePkg := filepath.Join(sourceGoRoot, "pkg", "linux_amd64", "fmt.a")
	sourcePersisted := filepath.Join(sourceGoRoot, "pkg", orchestrionStdlibExportDirName, "linux_amd64", "fmt.a")
	sourceCacheArchive := filepath.Join(sourceCache, "aa", "fmt-export")

	for _, path := range []string{sourcePkg, sourcePersisted, sourceCacheArchive} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", path, err)
		}
	}
	if err := os.WriteFile(sourcePkg, []byte("pkg"), 0o644); err != nil {
		t.Fatalf("write source pkg: %v", err)
	}
	if err := os.WriteFile(sourcePersisted, []byte("persisted"), 0o644); err != nil {
		t.Fatalf("write source persisted: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sourceGoRoot, "pkg", orchestrionStdlibExportDirName, "linux_amd64", orchestrionStdlibExportManifestName), []byte("fmt=fmt.a\n"), 0o644); err != nil {
		t.Fatalf("write source persisted manifest: %v", err)
	}
	if err := os.WriteFile(sourceCacheArchive, []byte("cache"), 0o644); err != nil {
		t.Fatalf("write source cache archive: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sourceCache, orchestrionStdlibCacheManifestName), []byte("fmt=aa/fmt-export\n"), 0o644); err != nil {
		t.Fatalf("write source cache manifest: %v", err)
	}

	sdk := filepath.Join(t.TempDir(), "sdk")
	if err := os.MkdirAll(filepath.Join(sdk, "src", "internal", "buildcfg"), 0o755); err != nil {
		t.Fatalf("mkdir sdk: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sdk, "VERSION"), []byte("go1.24.0\n"), 0o644); err != nil {
		t.Fatalf("write VERSION: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sdk, "src", "internal", "buildcfg", "zbootstrap.go"), []byte("package buildcfg\n"), 0o644); err != nil {
		t.Fatalf("write zbootstrap.go: %v", err)
	}

	goenv := &env{
		sdk:           sdk,
		goroot:        sourceGoRoot,
		stdlibCache:   sourceCache,
		installSuffix: "linux_amd64",
	}
	paths, keyParts, err := stdlibSnapshotCachePaths(goenv, []string{"std", "runtime/cgo"}, []string{"-shared"}, false, false, true, false)
	if err != nil {
		t.Fatalf("stdlibSnapshotCachePaths error: %v", err)
	}
	if err := persistStdlibSnapshot(paths, keyParts, goenv, false); err != nil {
		t.Fatalf("persistStdlibSnapshot error: %v", err)
	}

	destRoot := t.TempDir()
	destGoRoot := filepath.Join(destRoot, "goroot")
	destCache := filepath.Join(destRoot, "gocache")
	destEnv := &env{
		sdk:           sdk,
		goroot:        destGoRoot,
		stdlibCache:   destCache,
		installSuffix: "linux_amd64",
	}
	restored, err := restoreStdlibSnapshot(paths, destEnv, false)
	if err != nil {
		t.Fatalf("restoreStdlibSnapshot error: %v", err)
	}
	if !restored {
		t.Fatal("restoreStdlibSnapshot reported cache miss after persist")
	}

	checkFile := func(path, want string) {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		if string(data) != want {
			t.Fatalf("file %s = %q, want %q", path, string(data), want)
		}
	}

	checkFile(filepath.Join(destGoRoot, "pkg", "linux_amd64", "fmt.a"), "pkg")
	checkFile(filepath.Join(destGoRoot, "pkg", orchestrionStdlibExportDirName, "linux_amd64", "fmt.a"), "persisted")
	checkFile(filepath.Join(destGoRoot, "pkg", orchestrionStdlibExportDirName, "linux_amd64", orchestrionStdlibExportManifestName), "fmt=fmt.a\n")
	checkFile(filepath.Join(destCache, "aa", "fmt-export"), "cache")
	checkFile(filepath.Join(destCache, orchestrionStdlibCacheManifestName), "fmt=aa/fmt-export\n")
}
