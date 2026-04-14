package main

import (
	"os/exec"
	"strings"
	"testing"

	"github.com/bazelbuild/rules_go/go/tools/bazel"
)

const (
	noBuildInfoMarkerForSrcsOnly = "NO_BUILD_INFO"
	// Srcs-only binaries do not carry an importpath provider, so BuildInfo
	// falls back to the Bazel package path for the main package.
	srcsOnlyFallbackPath = "tests/core/buildinfo"
)

func TestSrcsOnlyBinaryBuildInfo(t *testing.T) {
	bin, ok := bazel.FindBinary("tests/core/buildinfo", "srcs_only_bin")
	if !ok {
		t.Fatal("could not find srcs_only_bin")
	}

	out, err := exec.Command(bin).CombinedOutput()
	if err != nil {
		t.Fatalf("failed to run srcs_only_bin: %v\noutput: %s", err, out)
	}

	output := string(out)
	if strings.Contains(output, noBuildInfoMarkerForSrcsOnly) {
		t.Fatalf("srcs-only binary did not expose build info:\n%s", output)
	}
	if !strings.Contains(output, "Path="+srcsOnlyFallbackPath) {
		t.Fatalf("srcs-only binary path mismatch:\n%s", output)
	}
	if !strings.Contains(output, "GoVersion=go") {
		t.Fatalf("srcs-only binary missing Go version:\n%s", output)
	}
}
