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

// Demonstrates reading test optimization files using TEST_OPTIMIZATION_MANIFEST_FILE
func TestMain(m *testing.M) {
	// Get the manifest file path and derive the working directory
	manifestRloc := os.Getenv("TEST_OPTIMIZATION_MANIFEST_FILE")
	if manifestRloc == "" {
		fmt.Println("TEST_OPTIMIZATION_MANIFEST_FILE not set")
		os.Exit(m.Run())
	}

	// Resolve the manifest path and get the .testoptimization directory
	manifestPath := resolveRlocation(manifestRloc)
	toptDir := filepath.Dir(manifestPath)
	fmt.Println("Test optimization directory:", toptDir)
	fmt.Println()

	// Read the test optimization files from the directory
	files := []string{"settings.json", "known_tests.json", "test_management.json"}
	for _, filename := range files {
		path := filepath.Join(toptDir, filename)
		fmt.Println("--------------------------------")
		fmt.Println(filename)
		content, err := os.ReadFile(path)
		if err != nil {
			fmt.Printf("read %s: %v\n", filename, err)
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

func TestGreeting(t *testing.T) {
	if getGreeting() != "Hello, World!" {
		t.Fatal("unexpected greeting")
	}
}

func TestMainOutput(t *testing.T) {
	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	main()
	w.Close()
	os.Stdout = old
	var buf bytes.Buffer
	io.Copy(&buf, r)
	if buf.String() != "Hello, World!\n" {
		t.Fatal("unexpected output")
	}
}
