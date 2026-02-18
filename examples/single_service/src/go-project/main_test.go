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

// Demonstrates reading test optimization files using DD_TEST_OPTIMIZATION_MANIFEST_FILE.
func TestMain(m *testing.M) {
	// Get the manifest file path and derive the working directory
	manifestRloc := os.Getenv("DD_TEST_OPTIMIZATION_MANIFEST_FILE")
	if manifestRloc == "" {
		fmt.Println("DD_TEST_OPTIMIZATION_MANIFEST_FILE not set")
		os.Exit(m.Run())
	}

	// Resolve the manifest path and get the .testoptimization directory
	manifestPath := resolveRlocation(manifestRloc)
	toptDir := filepath.Dir(manifestPath)
	fmt.Println("Test optimization directory:", toptDir)
	fmt.Println()

	// Read synced HTTP metadata from cache/http under the manifest directory.
	files := []string{
		filepath.Join("cache", "http", "settings.json"),
		filepath.Join("cache", "http", "known_tests.json"),
		filepath.Join("cache", "http", "test_management.json"),
	}
	for _, relPath := range files {
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
func resolveRlocation(p string) string {
	if _, err := os.Stat(p); err == nil {
		return p
	}
	if d := os.Getenv("RUNFILES_DIR"); d != "" {
		cand := filepath.Join(d, p)
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
	}
	if mf := os.Getenv("RUNFILES_MANIFEST_FILE"); mf != "" {
		if f, err := os.Open(mf); err == nil {
			defer f.Close()
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				line := sc.Text()
				i := strings.IndexByte(line, ' ')
				if i > 0 && line[:i] == p {
					return line[i+1:]
				}
			}
		}
	}
	if s := os.Getenv("TEST_SRCDIR"); s != "" {
		cand := filepath.Join(s, p)
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
	}
	return p
}

func TestMainOutput(t *testing.T) {
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
		t.Errorf("Expected %q, got %q", "Hello, World!\n", output)
	}
}

func TestGreeting(t *testing.T) {
	if getGreeting() != "Hello, World!" {
		t.Errorf("greeting mismatch")
	}
}
