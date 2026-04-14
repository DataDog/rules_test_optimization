package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseXdef(t *testing.T) {
	pkg, name, value, err := parseXdef("example.com/module.Version=v1.2.3", "example.com/module")
	if err != nil {
		t.Fatalf("parseXdef returned error: %v", err)
	}
	if pkg != "main" || name != "Version" || value != "v1.2.3" {
		t.Fatalf("unexpected parseXdef result: pkg=%q name=%q value=%q", pkg, name, value)
	}
}

func TestReadBuildInfoInputs(t *testing.T) {
	dir := t.TempDir()
	filename := filepath.Join(dir, "buildinfo.txt")
	if err := os.WriteFile(filename, []byte("path\texample.com/main\ndep\texample.com/internal/pkg\ndep\texample.com/mod/subpkg\n"), 0o644); err != nil {
		t.Fatalf("write buildinfo file: %v", err)
	}
	inputs, err := readBuildInfoInputs(filename)
	if err != nil {
		t.Fatalf("readBuildInfoInputs returned error: %v", err)
	}
	if inputs.Path != "example.com/main" {
		t.Fatalf("unexpected path: %q", inputs.Path)
	}
	if len(inputs.ImportDeps) != 2 || inputs.ImportDeps[0] != "example.com/internal/pkg" || inputs.ImportDeps[1] != "example.com/mod/subpkg" {
		t.Fatalf("unexpected import deps: %#v", inputs.ImportDeps)
	}
}

func TestFindBestModuleMatch(t *testing.T) {
	versionMap := map[string]string{
		"example.com/mod":     "v1.2.3",
		"example.com/mod/sub": "v1.2.4",
	}
	module, version, ok := findBestModuleMatch("example.com/mod/sub/pkg", versionMap)
	if !ok {
		t.Fatal("expected a module match")
	}
	if module != "example.com/mod/sub" || version != "v1.2.4" {
		t.Fatalf("unexpected match: module=%q version=%q", module, version)
	}
}

func TestResolveBuildInfoDeps(t *testing.T) {
	deps := resolveBuildInfoDeps(
		[]string{
			"example.com/internal/pkg",
			"golang.org/x/sys/unix",
			"golang.org/x/sys/windows",
		},
		map[string]string{"golang.org/x/sys": "v0.30.0"},
	)
	if len(deps) != 2 {
		t.Fatalf("unexpected deps length: %d (%#v)", len(deps), deps)
	}
	if deps[0].Path != "example.com/internal/pkg" || deps[0].Version != "(devel)" {
		t.Fatalf("unexpected internal dep: %#v", deps[0])
	}
	if deps[1].Path != "golang.org/x/sys" || deps[1].Version != "v0.30.0" {
		t.Fatalf("unexpected external dep: %#v", deps[1])
	}
}

func TestBuildImportcfgFileForLinkIncludesModinfo(t *testing.T) {
	t.Setenv("GOROOT", "/goroot")
	cfg := linkConfig{
		path:          "example.com/main",
		buildMode:     "exe",
		compiler:      "gc",
		cgoEnabled:    false,
		goos:          "linux",
		goarch:        "amd64",
		buildinfoFile: "present",
		deps: []*Module{
			{Path: "example.com/mod", Version: "v1.2.3"},
		},
		bazelTarget: "//:main",
	}
	stdPackageListPath := filepath.Join(t.TempDir(), "stdlib.txt")
	if err := os.WriteFile(stdPackageListPath, []byte("fmt\n"), 0o644); err != nil {
		t.Fatalf("write package list: %v", err)
	}
	importcfgName, err := buildImportcfgFileForLink(nil, stdPackageListPath, "linux_amd64", t.TempDir(), cfg)
	if err != nil {
		t.Fatalf("buildImportcfgFileForLink returned error: %v", err)
	}
	data, err := os.ReadFile(importcfgName)
	if err != nil {
		t.Fatalf("read importcfg: %v", err)
	}
	text := string(data)
	if !strings.Contains(text, "modinfo ") {
		t.Fatalf("expected modinfo directive in importcfg, got %q", text)
	}
	if !strings.Contains(text, "example.com/mod") {
		t.Fatalf("expected dependency module in modinfo, got %q", text)
	}
}
