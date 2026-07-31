package main

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// resetProbeState clears the cached probe environment so tests can control it.
func resetProbeState(t *testing.T) {
	t.Helper()
	orchestrionProbeEnabledOnce = sync.Once{}
	orchestrionProbeEnabledFlag = false
	orchestrionProbeFilePathOnce = sync.Once{}
	orchestrionProbeFilePath = ""
}

func TestEmitProbeLineMirrorsToFile(t *testing.T) {
	t.Setenv(orchestrionProbeEnvVar, "1")
	probeFile := filepath.Join(t.TempDir(), "builder-probes.log")
	t.Setenv(orchestrionProbeFileEnvVar, probeFile)
	resetProbeState(t)

	emitProbeLine("probe.test", 25*time.Millisecond, newProbeField("kind", "unit"))

	data, err := os.ReadFile(probeFile)
	if err != nil {
		t.Fatalf("read probe file: %v", err)
	}
	line := string(data)
	if !strings.Contains(line, `phase="probe.test"`) {
		t.Fatalf("probe file missing phase: %q", line)
	}
	if !strings.Contains(line, `kind="unit"`) {
		t.Fatalf("probe file missing custom field: %q", line)
	}
	if !strings.Contains(line, `pid="`) {
		t.Fatalf("probe file missing pid: %q", line)
	}
}

func TestEmitProbeLineSkipsFileWhenDisabled(t *testing.T) {
	t.Setenv(orchestrionProbeEnvVar, "")
	probeFile := filepath.Join(t.TempDir(), "builder-probes.log")
	t.Setenv(orchestrionProbeFileEnvVar, probeFile)
	resetProbeState(t)

	emitProbeLine("probe.test", 25*time.Millisecond)

	if _, err := os.Stat(probeFile); !os.IsNotExist(err) {
		t.Fatalf("expected no probe file, got err=%v", err)
	}
}

func TestEmitProbeLineUsesDefaultProbeFilePath(t *testing.T) {
	t.Setenv(orchestrionProbeEnvVar, "1")
	t.Setenv(orchestrionProbeFileEnvVar, "")
	t.Setenv("GOPATH", "")
	cacheRoot := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheRoot)
	resetProbeState(t)

	emitProbeLine("probe.default", 10*time.Millisecond)

	probeFile := filepath.Join(
		cacheRoot,
		orchestrionProbeSharedCacheDirName,
		"probes",
		orchestrionProbeDefaultFileName,
	)
	data, err := os.ReadFile(probeFile)
	if err != nil {
		t.Fatalf("read default probe file: %v", err)
	}
	if !strings.Contains(string(data), `phase="probe.default"`) {
		t.Fatalf("default probe file missing phase: %q", string(data))
	}
}

func TestProbeFilePathAllowsAbsoluteTempPath(t *testing.T) {
	t.Setenv(orchestrionProbeEnvVar, "1")
	probeFile := filepath.Join(t.TempDir(), "nested", "builder-probes.log")
	t.Setenv(orchestrionProbeFileEnvVar, probeFile)
	resetProbeState(t)

	emitProbeLine("probe.temp", 5*time.Millisecond)

	if _, err := os.Stat(probeFile); err != nil {
		t.Fatalf("stat allowed probe file: %v", err)
	}
}

func TestProbeFilePathRejectsTraversalOutsideProbeDir(t *testing.T) {
	t.Setenv(orchestrionProbeEnvVar, "1")
	t.Setenv(orchestrionProbeFileEnvVar, "../escape.log")
	t.Setenv("GOPATH", "")
	cacheRoot := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheRoot)
	resetProbeState(t)

	emitProbeLine("probe.default", 10*time.Millisecond)

	defaultProbeFile := filepath.Join(
		cacheRoot,
		orchestrionProbeSharedCacheDirName,
		"probes",
		orchestrionProbeDefaultFileName,
	)
	if _, err := os.Stat(defaultProbeFile); err != nil {
		t.Fatalf("stat default fallback probe file: %v", err)
	}
	escapedProbeFile := filepath.Join(cacheRoot, "escape.log")
	if _, err := os.Stat(escapedProbeFile); !os.IsNotExist(err) {
		t.Fatalf("expected traversal target to stay unused, got err=%v", err)
	}
}

func TestProbeFilePathRejectsAbsolutePathOutsideAllowedRoots(t *testing.T) {
	t.Setenv(orchestrionProbeEnvVar, "1")
	t.Setenv("GOPATH", "")
	cacheRoot := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheRoot)
	forbiddenProbeFile := filepath.Join(string(os.PathSeparator), "Users", "forbidden", "builder-probes.log")
	t.Setenv(orchestrionProbeFileEnvVar, forbiddenProbeFile)
	resetProbeState(t)

	emitProbeLine("probe.default", 10*time.Millisecond)

	defaultProbeFile := filepath.Join(
		cacheRoot,
		orchestrionProbeSharedCacheDirName,
		"probes",
		orchestrionProbeDefaultFileName,
	)
	if _, err := os.Stat(defaultProbeFile); err != nil {
		t.Fatalf("stat default fallback probe file: %v", err)
	}
	if _, err := os.Stat(forbiddenProbeFile); !os.IsNotExist(err) {
		t.Fatalf("expected forbidden probe file to stay unused, got err=%v", err)
	}
}
