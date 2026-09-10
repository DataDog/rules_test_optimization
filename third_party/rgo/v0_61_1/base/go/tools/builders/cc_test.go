package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestNormalizeCgoRandomSeedIgnoresEphemeralRoots(t *testing.T) {
	firstCCRoot := filepath.Join("tmp", "source", "first", "workspace")
	secondCCRoot := filepath.Join("tmp", "source", "second", "workspace")
	firstExecRoot := filepath.Join("tmp", "sandbox", "1", "execroot", "workspace")
	secondExecRoot := filepath.Join("tmp", "sandbox", "2", "execroot", "workspace")
	firstWorkRoot := filepath.Join("tmp", "go-build111")
	secondWorkRoot := filepath.Join("tmp", "go-build222")

	first := []string{
		"clang",
		"-I" + filepath.Join(firstExecRoot, "external", "sysroot", "include"),
		"-frandom-seed=volatile-first",
		"-o", filepath.Join(firstWorkRoot, "b001", "_x001.o"),
		"-c", filepath.Join(firstWorkRoot, "b001", "_cgo_export.c"),
	}
	second := []string{
		"clang",
		"-I" + filepath.Join(secondExecRoot, "external", "sysroot", "include"),
		"-frandom-seed=volatile-second",
		"-o", filepath.Join(secondWorkRoot, "b001", "_x001.o"),
		"-c", filepath.Join(secondWorkRoot, "b001", "_cgo_export.c"),
	}

	// Orchestrion runs `go install` from the resolved module directory, while
	// Bazel's C compiler remains rooted in the action execroot. The wrapper must
	// normalize both independent roots even though GO_CC_ROOT only names the
	// former.
	normalizeCgoRandomSeed(first, firstCCRoot)
	normalizeCgoRandomSeed(second, secondCCRoot)
	if got, want := randomSeedArg(first), randomSeedArg(second); got == "" || got != want {
		t.Fatalf("normalized seeds differ:\nfirst:  %s\nsecond: %s", got, want)
	}

	second = append(second, "-DPROFILE=changed")
	normalizeCgoRandomSeed(second, secondCCRoot)
	if randomSeedArg(first) == randomSeedArg(second) {
		t.Fatal("meaningful compiler arguments must affect the normalized seed")
	}
}

func TestNormalizeBazelExecRoots(t *testing.T) {
	tests := map[string]string{
		"/tmp/sandbox/1/execroot/workspace/external/cc":                       "$EXECROOT/external/cc",
		"-I/tmp/sandbox/1/execroot/workspace/include":                         "-I$EXECROOT/include",
		"--sysroot=/tmp/one/execroot/ws/sysroot":                              "--sysroot=$EXECROOT/sysroot",
		"-ffile-prefix-map=/tmp/one/execroot/ws/src=/tmp/two/execroot/ws/src": "-ffile-prefix-map=$EXECROOT/src=$EXECROOT/src",
		`C:\tmp\one\execroot\ws\external\cc.exe`:                              `$EXECROOT\external\cc.exe`,
		`-IC:\tmp\one\execroot\ws\include`:                                    `-I$EXECROOT\include`,
		`C:/tmp/one/execroot/ws/external/cc.exe`:                              `$EXECROOT/external/cc.exe`,
		`-IC:/tmp/one/execroot/ws/include`:                                    `-I$EXECROOT/include`,
	}
	for input, want := range tests {
		if got := normalizeBazelExecRoots(input); got != want {
			t.Errorf("normalizeBazelExecRoots(%q) = %q, want %q", input, got, want)
		}
	}
}

func randomSeedArg(args []string) string {
	for _, arg := range args {
		if strings.HasPrefix(arg, "-frandom-seed=") {
			return arg
		}
	}
	return ""
}
