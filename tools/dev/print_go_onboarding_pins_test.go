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
	"strings"
	"testing"

	"github.com/DataDog/rules_test_optimization/modules/go/tools/onboardingpins"
)

func TestPrintGoOnboardingPinsPrintsPublishedTuple(t *testing.T) {
	var stdout bytes.Buffer
	commit := strings.Repeat("a", 40)
	cfg := cliConfig{
		commit:       commit,
		remote:       onboardingpins.DefaultRemote,
		workspace:    t.TempDir(),
		archiveType:  onboardingpins.DefaultArchiveType,
		printSummary: true,
		fetchArchive: archiveFromStringForCLI("archive"),
	}
	if err := runWithOutput(context.Background(), cfg, &stdout); err != nil {
		t.Fatalf("runWithOutput error: %v", err)
	}
	got := stdout.String()
	for _, want := range []string{
		`RTO_COMMIT="` + commit + `"`,
		`RTO_ARCHIVE_PREFIX="rules_test_optimization-` + commit + `"`,
		"# Datadog Go Test Optimization Onboarding Pins",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("pin output missing %q:\n%s", want, got)
		}
	}
	for _, removed := range []string{"RULES_GO_", "ORCHESTRION", "DD_TRACE_GO"} {
		if strings.Contains(got, removed) {
			t.Fatalf("pin output still prints %q:\n%s", removed, got)
		}
	}
}

func TestPrintGoOnboardingPinsRejectsShortCommit(t *testing.T) {
	var stdout bytes.Buffer
	cfg := cliConfig{
		commit:       "abc123",
		remote:       onboardingpins.DefaultRemote,
		workspace:    t.TempDir(),
		archiveType:  onboardingpins.DefaultArchiveType,
		fetchArchive: archiveFromStringForCLI("archive"),
	}
	err := runWithOutput(context.Background(), cfg, &stdout)
	if err == nil || !strings.Contains(err.Error(), "--commit must be a full 40-character lowercase SHA") {
		t.Fatalf("runWithOutput error=%v, want short commit rejection", err)
	}
	if stdout.Len() != 0 {
		t.Fatalf("unexpected stdout for rejected commit:\n%s", stdout.String())
	}
}

func archiveFromStringForCLI(body string) onboardingpins.ArchiveFetcher {
	return func(context.Context, string) (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewBufferString(body)), nil
	}
}
