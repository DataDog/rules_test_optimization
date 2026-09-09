package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestNormalizeCgoRandomSeedIgnoresEphemeralRoots(t *testing.T) {
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

	normalizeCgoRandomSeed(first, firstExecRoot)
	normalizeCgoRandomSeed(second, secondExecRoot)
	if got, want := randomSeedArg(first), randomSeedArg(second); got == "" || got != want {
		t.Fatalf("normalized seeds differ:\nfirst:  %s\nsecond: %s", got, want)
	}

	second = append(second, "-DPROFILE=changed")
	normalizeCgoRandomSeed(second, secondExecRoot)
	if randomSeedArg(first) == randomSeedArg(second) {
		t.Fatal("meaningful compiler arguments must affect the normalized seed")
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
