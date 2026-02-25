package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var testOptimizationFiles = []string{
	filepath.Join("cache", "http", "settings.json"),
	filepath.Join("cache", "http", "known_tests.json"),
	filepath.Join("cache", "http", "test_management.json"),
}

// Demonstrates reading test optimization files using DD_TEST_OPTIMIZATION_MANIFEST_FILE.
func TestMain(m *testing.M) {
	// Get the manifest file path and derive the working directory
	manifestRloc := os.Getenv("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
	if manifestRloc == "" {
		fmt.Println("DD_TEST_OPTIMIZATION_MANIFEST_FILE not set")
		os.Exit(m.Run())
	}

	// Resolve the manifest path and get the .testoptimization directory
	manifestPath, ok := resolveRlocation(manifestRloc)
	if !ok {
		fmt.Println("unable to resolve DD_TEST_OPTIMIZATION_MANIFEST_FILE runfile path")
		os.Exit(m.Run())
	}
	toptDir := filepath.Dir(manifestPath)
	fmt.Println("Test optimization directory:", toptDir)
	fmt.Println()

	// Read synced HTTP metadata from cache/http under the manifest directory.
	for _, relPath := range testOptimizationFiles {
		path := filepath.Join(toptDir, relPath)
		fmt.Println("--------------------------------")
		fmt.Println(relPath)
		content, err := os.ReadFile(path)
		if err != nil {
			fmt.Printf("read %s: %v\n", relPath, err)
			continue
		}
		fmt.Println(string(content))
		fmt.Println("--------------------------------")
		fmt.Println()
	}
	os.Exit(m.Run())
}

// resolveRlocation resolves a runfile rlocation path to an absolute path.
// Duplicated intentionally: each example is a standalone workspace.
func resolveRlocation(p string) (string, bool) {
	if _, err := os.Stat(p); err == nil {
		return p, true
	}
	if d := os.Getenv("RUNFILES_DIR"); d != "" {
		cand := filepath.Join(d, p)
		if _, err := os.Stat(cand); err == nil {
			return cand, true
		}
	}
	if mf := os.Getenv("RUNFILES_MANIFEST_FILE"); mf != "" {
		if f, err := os.Open(mf); err == nil {
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				line := sc.Text()
				i := strings.IndexByte(line, ' ')
				if i > 0 && line[:i] == p {
					_ = f.Close()
					return line[i+1:], true
				}
			}
			_ = f.Close()
		}
	}
	if s := os.Getenv("TEST_SRCDIR"); s != "" {
		cand := filepath.Join(s, p)
		if _, err := os.Stat(cand); err == nil {
			return cand, true
		}
	}
	return p, false
}

func TestManifestMetadataFilesPresent(t *testing.T) {
	manifestRloc := os.Getenv("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
	if manifestRloc == "" {
		t.Skip("DD_TEST_OPTIMIZATION_MANIFEST_FILE not set in this environment")
	}
	manifestPath, ok := resolveRlocation(manifestRloc)
	if !ok {
		t.Fatalf("failed to resolve runfile path: %s", manifestRloc)
	}
	manifestDir := filepath.Dir(manifestPath)
	for _, relPath := range testOptimizationFiles {
		path := filepath.Join(manifestDir, relPath)
		content, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", relPath, err)
		}
		if len(content) == 0 {
			t.Fatalf("expected non-empty metadata file: %s", relPath)
		}
	}
}

func TestMainOutput(t *testing.T) {
	// This test intentionally swaps os.Stdout and must not run in parallel.
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		os.Stdout = old
		_ = r.Close()
		_ = w.Close()
	})
	os.Stdout = w
	main()
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	os.Stdout = old
	var buf bytes.Buffer
	if _, err := io.Copy(&buf, r); err != nil {
		t.Fatal(err)
	}
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	output := buf.String()
	if output != "Hello, World!\n" {
		t.Fatalf("expected %q, got %q", "Hello, World!\n", output)
	}
}

func TestGreeting(t *testing.T) {
	got := getGreeting()
	if got != "Hello, World!" {
		t.Fatalf("expected %q, got %q", "Hello, World!", got)
	}
}
