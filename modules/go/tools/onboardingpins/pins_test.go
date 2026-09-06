// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package onboardingpins

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveRejectsEmptyCommit(t *testing.T) {
	_, err := Resolve(context.Background(), Options{
		WorkspaceDir: variantWorkspace(t),
		FetchArchive: archiveFromString("archive"),
	})
	if err == nil || !strings.Contains(err.Error(), "--commit is required") {
		t.Fatalf("Resolve error=%v, want empty commit rejection", err)
	}
}

func TestResolveRejectsCommitNotReachableFromMain(t *testing.T) {
	dir := variantWorkspace(t)
	runGit(t, dir, "init", ".")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test User")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("main\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	runGit(t, dir, "add", "README.md")
	runGit(t, dir, "commit", "-m", "main")
	mainCommit := strings.TrimSpace(runGit(t, dir, "rev-parse", "HEAD"))
	runGit(t, dir, "update-ref", "refs/remotes/origin/main", mainCommit)
	runGit(t, dir, "switch", "--create", "feature")
	if err := os.WriteFile(filepath.Join(dir, "feature.txt"), []byte("feature\n"), 0o644); err != nil {
		t.Fatalf("write feature: %v", err)
	}
	runGit(t, dir, "add", "feature.txt")
	runGit(t, dir, "commit", "-m", "feature")
	featureCommit := strings.TrimSpace(runGit(t, dir, "rev-parse", "HEAD"))

	_, err := Resolve(context.Background(), Options{
		WorkspaceDir:        dir,
		Commit:              featureCommit,
		VerifyMainReachable: true,
		FetchArchive:        archiveFromString("archive"),
		DDTraceGoVersion:    DefaultDDTraceGoVersion,
		OrchestrionVersion:  DefaultOrchestrionVersion,
	})
	if err == nil || !strings.Contains(err.Error(), "is not reachable from origin/main") {
		t.Fatalf("Resolve error=%v, want reachability rejection", err)
	}
}

func TestArchiveSHA256HashesArchiveBytes(t *testing.T) {
	body := "published archive bytes"
	got, err := ArchiveSHA256(context.Background(), "https://example.test/archive.tar.gz", archiveFromString(body))
	if err != nil {
		t.Fatalf("ArchiveSHA256 error: %v", err)
	}
	sum := sha256.Sum256([]byte(body))
	want := hex.EncodeToString(sum[:])
	if got != want {
		t.Fatalf("ArchiveSHA256=%s, want %s", got, want)
	}
}

func TestResolveRejectsNonTarArchiveType(t *testing.T) {
	_, err := Resolve(context.Background(), Options{
		Commit:       strings.Repeat("a", 40),
		ArchiveType:  "zip",
		FetchArchive: archiveFromString("archive"),
	})
	if err == nil || !strings.Contains(err.Error(), `--archive-type must be "tar.gz"`) {
		t.Fatalf("Resolve error=%v, want archive type rejection", err)
	}
}

func TestResolveReturnsPublishedTuple(t *testing.T) {
	dir := variantWorkspace(t)
	runGit(t, dir, "init", ".")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test User")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("main\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	runGit(t, dir, "add", "README.md")
	runGit(t, dir, "commit", "-m", "main")
	commit := strings.TrimSpace(runGit(t, dir, "rev-parse", "HEAD"))
	runGit(t, dir, "update-ref", "refs/remotes/origin/main", commit)

	pins, err := Resolve(context.Background(), Options{
		WorkspaceDir:        dir,
		Commit:              commit,
		Variant:             "base",
		VerifyMainReachable: true,
		FetchArchive:        archiveFromString("archive"),
	})
	if err != nil {
		t.Fatalf("Resolve error: %v", err)
	}
	if pins.RTOCommit != commit {
		t.Fatalf("RTOCommit=%s, want %s", pins.RTOCommit, commit)
	}
	if pins.RTOArchiveURL != "https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/"+commit {
		t.Fatalf("unexpected archive URL: %s", pins.RTOArchiveURL)
	}
	if pins.RTOArchivePrefix != "rules_test_optimization-"+commit {
		t.Fatalf("unexpected archive prefix: %s", pins.RTOArchivePrefix)
	}
	if pins.RulesGoStripPrefix != "third_party/rgo/v0_60_0/base" {
		t.Fatalf("unexpected strip prefix: %s", pins.RulesGoStripPrefix)
	}
}

func TestResolveUsesDefaultRulesGoUpstream(t *testing.T) {
	commit := strings.Repeat("a", 40)
	pins, err := Resolve(context.Background(), Options{
		WorkspaceDir:       variantWorkspace(t),
		Commit:             commit,
		Variant:            "base",
		DDTraceGoVersion:   DefaultDDTraceGoVersion,
		OrchestrionVersion: DefaultOrchestrionVersion,
		FetchArchive:       archiveFromString("archive"),
		ValidateVariantDir: true,
	})
	if err != nil {
		t.Fatalf("Resolve error: %v", err)
	}
	if pins.RulesGoUpstream != DefaultRulesGoUpstream {
		t.Fatalf("RulesGoUpstream=%q, want %q", pins.RulesGoUpstream, DefaultRulesGoUpstream)
	}
	if pins.RulesGoStripPrefix != "third_party/rgo/v0_60_0/base" {
		t.Fatalf("RulesGoStripPrefix=%q", pins.RulesGoStripPrefix)
	}
}

func TestResolveNormalizesDefaultRulesGoVariant(t *testing.T) {
	commit := strings.Repeat("a", 40)
	pins, err := Resolve(context.Background(), Options{
		WorkspaceDir:       variantWorkspace(t),
		Commit:             commit,
		Variant:            "default",
		DDTraceGoVersion:   DefaultDDTraceGoVersion,
		OrchestrionVersion: DefaultOrchestrionVersion,
		FetchArchive:       archiveFromString("archive"),
		ValidateVariantDir: true,
	})
	if err != nil {
		t.Fatalf("Resolve error: %v", err)
	}
	if pins.Variant != "base" {
		t.Fatalf("Variant=%q, want base", pins.Variant)
	}
	if pins.RulesGoStripPrefix != "third_party/rgo/v0_60_0/base" {
		t.Fatalf("RulesGoStripPrefix=%q", pins.RulesGoStripPrefix)
	}
}

func TestResolveRejectsUnknownRulesGoUpstream(t *testing.T) {
	_, err := Resolve(context.Background(), Options{
		Commit:           strings.Repeat("a", 40),
		Variant:          "base",
		RulesGoUpstream:  "v9_99_0",
		FetchArchive:     archiveFromString("archive"),
		DDTraceGoVersion: DefaultDDTraceGoVersion,
	})
	if err == nil || !strings.Contains(err.Error(), "rules_go_upstream") {
		t.Fatalf("Resolve error=%v, want rules_go_upstream rejection", err)
	}
}

func TestRulesGoStripPrefixDefaultsToGeneratedBase(t *testing.T) {
	prefix, err := RulesGoStripPrefix("default", "default")
	if err != nil {
		t.Fatalf("RulesGoStripPrefix error: %v", err)
	}
	if prefix != "third_party/rgo/v0_60_0/base" {
		t.Fatalf("RulesGoStripPrefix=%q", prefix)
	}
}

func TestRulesGoSelectionForStripPrefixFindsBaseVariant(t *testing.T) {
	upstream, variant, err := RulesGoSelectionForStripPrefix("third_party/rgo/v0_60_0/base")
	if err != nil {
		t.Fatalf("RulesGoSelectionForStripPrefix error: %v", err)
	}
	if upstream != "v0_60_0" || variant != "base" {
		t.Fatalf("selection=%s/%s, want v0_60_0/base", upstream, variant)
	}
}

func TestRulesGoSelectionForStripPrefixAcceptsLegacyV060BaseAlias(t *testing.T) {
	upstream, variant, err := RulesGoSelectionForStripPrefix("third_party/rules_go_orchestrion_base")
	if err != nil {
		t.Fatalf("RulesGoSelectionForStripPrefix error: %v", err)
	}
	if upstream != "v0_60_0" || variant != "base" {
		t.Fatalf("selection=%s/%s, want v0_60_0/base", upstream, variant)
	}
}

func TestRulesGoSelectionForStripPrefixRejectsLegacyCompleteAlias(t *testing.T) {
	_, _, err := RulesGoSelectionForStripPrefix("third_party/rules_go_orchestrion_complete")
	if err == nil || !strings.Contains(err.Error(), removedCompleteVariantError) {
		t.Fatalf("RulesGoSelectionForStripPrefix error=%v, want complete variant rejection", err)
	}
}

func TestResolveRejectsCompleteVariant(t *testing.T) {
	_, err := Resolve(context.Background(), Options{
		WorkspaceDir: variantWorkspace(t),
		Commit:       strings.Repeat("a", 40),
		Variant:      "complete",
		FetchArchive: archiveFromString("archive"),
	})
	if err == nil || !strings.Contains(err.Error(), `rules_go_variant "complete" is no longer supported. Use "base".`) {
		t.Fatalf("Resolve error=%v, want complete variant rejection", err)
	}
}

func TestResolveValidatesVariantDirWhenRequested(t *testing.T) {
	dir := t.TempDir()
	runGit(t, dir, "init", ".")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test User")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("main\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	runGit(t, dir, "add", "README.md")
	runGit(t, dir, "commit", "-m", "main")
	commit := strings.TrimSpace(runGit(t, dir, "rev-parse", "HEAD"))

	_, err := Resolve(context.Background(), Options{
		WorkspaceDir:       dir,
		Commit:             commit,
		Variant:            "base",
		ValidateVariantDir: true,
		FetchArchive:       archiveFromString("archive"),
	})
	if err == nil || !strings.Contains(err.Error(), "does not exist") {
		t.Fatalf("Resolve error=%v, want missing variant dir rejection", err)
	}
}

func TestResolveCanSkipVariantDirForConsumerBootstrap(t *testing.T) {
	dir := t.TempDir()
	runGit(t, dir, "init", ".")
	runGit(t, dir, "config", "user.email", "test@example.com")
	runGit(t, dir, "config", "user.name", "Test User")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("main\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	runGit(t, dir, "add", "README.md")
	runGit(t, dir, "commit", "-m", "main")
	commit := strings.TrimSpace(runGit(t, dir, "rev-parse", "HEAD"))

	if _, err := Resolve(context.Background(), Options{
		WorkspaceDir: dir,
		Commit:       commit,
		Variant:      "base",
		FetchArchive: archiveFromString("archive"),
	}); err != nil {
		t.Fatalf("Resolve should not require local variant dirs when ValidateVariantDir is false: %v", err)
	}
}

func TestSummaryContainsCurrentCommitOnly(t *testing.T) {
	commit := strings.Repeat("a", 40)
	staleCommit := strings.Repeat("b", 40)
	got := FormatMarkdownSummary(Pins{
		RTOCommit:          commit,
		RTORemote:          DefaultRemote,
		RTOArchiveURL:      "https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/" + commit,
		RTOArchiveSHA256:   strings.Repeat("1", 64),
		RTOArchivePrefix:   "rules_test_optimization-" + commit,
		RTOArchiveType:     DefaultArchiveType,
		Variant:            "base",
		RulesGoStripPrefix: "third_party/rgo/v0_60_0/base",
		DDTraceGoVersion:   DefaultDDTraceGoVersion,
		OrchestrionVersion: DefaultOrchestrionVersion,
	})
	if !strings.Contains(got, commit) {
		t.Fatalf("summary missing current commit:\n%s", got)
	}
	if strings.Contains(got, staleCommit) {
		t.Fatalf("summary contains stale commit %s:\n%s", staleCommit, got)
	}
	for _, want := range []string{
		"one uploader pass with enrichment validation",
		"DD_TEST_OPTIMIZATION_REPORT_DIR",
		"selected uploader report",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("summary missing %q:\n%s", want, got)
		}
	}
}

func variantWorkspace(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "third_party", "rgo", "v0_60_0", "base"), 0o755); err != nil {
		t.Fatalf("create variant dir: %v", err)
	}
	return dir
}

func archiveFromString(body string) ArchiveFetcher {
	return func(context.Context, string) (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewBufferString(body)), nil
	}
}

func runGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, output)
	}
	return strings.TrimSpace(string(output))
}

func TestCodeloadURLSupportsCommonGitHubRemotes(t *testing.T) {
	for _, remote := range []string{
		"https://github.com/DataDog/rules_test_optimization.git",
		"git@github.com:DataDog/rules_test_optimization.git",
		"ssh://git@github.com/DataDog/rules_test_optimization.git",
	} {
		got, err := CodeloadURL(remote, "abc123")
		if err != nil {
			t.Fatalf("CodeloadURL(%q) error: %v", remote, err)
		}
		want := "https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/abc123"
		if got != want {
			t.Fatalf("CodeloadURL(%q)=%q, want %q", remote, got, want)
		}
	}
}

func TestCodeloadURLRejectsNonGitHubRemote(t *testing.T) {
	_, err := CodeloadURL("https://example.test/repo.git", "abc123")
	if err == nil || !strings.Contains(err.Error(), "not a supported GitHub remote") {
		t.Fatalf("CodeloadURL error=%v, want unsupported remote rejection", err)
	}
}

func TestFormatShellIncludesBaseTuple(t *testing.T) {
	pins := Pins{
		RTOCommit:          strings.Repeat("a", 40),
		RTORemote:          DefaultRemote,
		RTOArchiveURL:      "https://example.test/archive.tar.gz",
		RTOArchiveSHA256:   strings.Repeat("1", 64),
		RTOArchivePrefix:   "rules_test_optimization-" + strings.Repeat("a", 40),
		RTOArchiveType:     DefaultArchiveType,
		Variant:            "base",
		RulesGoStripPrefix: "third_party/rgo/v0_60_0/base",
		DDTraceGoVersion:   DefaultDDTraceGoVersion,
		OrchestrionVersion: DefaultOrchestrionVersion,
	}
	got := FormatShell(pins)
	for _, want := range []string{
		"RTO_COMMIT=",
		"RTO_REMOTE=",
		"RTO_ARCHIVE_URL=",
		"RTO_ARCHIVE_SHA256=",
		"RTO_ARCHIVE_PREFIX=",
		"RULES_GO_UPSTREAM=",
		"RULES_GO_VARIANT=",
		"DD_TRACE_GO_VERSION=",
		"ORCHESTRION_VERSION=",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("FormatShell missing %q:\n%s", want, got)
		}
	}
}

func ExampleFormatShell() {
	fmt.Print(FormatShell(Pins{
		RTOCommit:          strings.Repeat("a", 40),
		RTORemote:          DefaultRemote,
		RTOArchiveURL:      "https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/" + strings.Repeat("a", 40),
		RTOArchiveSHA256:   strings.Repeat("1", 64),
		RTOArchivePrefix:   "rules_test_optimization-" + strings.Repeat("a", 40),
		RTOArchiveType:     DefaultArchiveType,
		RulesGoUpstream:    DefaultRulesGoUpstream,
		Variant:            "base",
		RulesGoStripPrefix: "third_party/rgo/v0_60_0/base",
		DDTraceGoVersion:   DefaultDDTraceGoVersion,
		OrchestrionVersion: DefaultOrchestrionVersion,
	}))
	// Output:
	// RTO_COMMIT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	// RTO_REMOTE="https://github.com/DataDog/rules_test_optimization.git"
	// RTO_ARCHIVE_URL="https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	// RTO_ARCHIVE_SHA256="1111111111111111111111111111111111111111111111111111111111111111"
	// RTO_ARCHIVE_PREFIX="rules_test_optimization-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	// RTO_ARCHIVE_TYPE="tar.gz"
	// RULES_GO_UPSTREAM="v0_60_0"
	// RULES_GO_VARIANT="base"
	// RULES_GO_STRIP_PREFIX="third_party/rgo/v0_60_0/base"
	// DD_TRACE_GO_VERSION="v2.9.1"
	// ORCHESTRION_VERSION="v1.12.0"
}
