// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package main

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/DataDog/rules_test_optimization/modules/go/tools/onboardingpins"
)

func TestPrintGoOnboardingPinsIncludesRulesGoUpstream(t *testing.T) {
	var stdout bytes.Buffer
	cfg := cliConfig{
		commit:             strings.Repeat("a", 40),
		variant:            "base",
		upstream:           "v0_60_0",
		remote:             onboardingpins.DefaultRemote,
		workspace:          testWorkspaceWithRulesGoFork(t),
		archiveType:        onboardingpins.DefaultArchiveType,
		ddTraceGoVersion:   onboardingpins.DefaultDDTraceGoVersion,
		orchestrionVersion: onboardingpins.DefaultOrchestrionVersion,
		fetchArchive:       archiveFromStringForCLI("archive"),
	}
	if err := runWithOutput(context.Background(), cfg, &stdout); err != nil {
		t.Fatalf("runWithOutput error: %v", err)
	}
	if !strings.Contains(stdout.String(), `RULES_GO_UPSTREAM="v0_60_0"`) {
		t.Fatalf("pin output missing upstream:\n%s", stdout.String())
	}
}

func TestPrintGoOnboardingPinsRejectsCompleteVariant(t *testing.T) {
	var stdout bytes.Buffer
	cfg := cliConfig{
		commit:             strings.Repeat("a", 40),
		variant:            "complete",
		upstream:           "v0_60_0",
		remote:             onboardingpins.DefaultRemote,
		workspace:          testWorkspaceWithRulesGoFork(t),
		archiveType:        onboardingpins.DefaultArchiveType,
		ddTraceGoVersion:   onboardingpins.DefaultDDTraceGoVersion,
		orchestrionVersion: onboardingpins.DefaultOrchestrionVersion,
		fetchArchive:       archiveFromStringForCLI("archive"),
	}
	err := runWithOutput(context.Background(), cfg, &stdout)
	if err == nil {
		t.Fatalf("runWithOutput succeeded for removed complete variant")
	}
	if !strings.Contains(err.Error(), `rules_go_variant "complete" is no longer supported`) {
		t.Fatalf("unexpected complete variant error: %v", err)
	}
	if stdout.Len() != 0 {
		t.Fatalf("unexpected stdout for rejected variant:\n%s", stdout.String())
	}
}

func testWorkspaceWithRulesGoFork(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "third_party", "rgo", "v0_60_0", "base"), 0o755); err != nil {
		t.Fatalf("create variant dir: %v", err)
	}
	return dir
}

func archiveFromStringForCLI(body string) onboardingpins.ArchiveFetcher {
	return func(context.Context, string) (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewBufferString(body)), nil
	}
}
