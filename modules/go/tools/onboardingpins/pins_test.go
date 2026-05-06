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
		Variant:             "complete",
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
	if pins.RulesGoStripPrefix != "third_party/rules_go_orchestrion_complete" {
		t.Fatalf("unexpected strip prefix: %s", pins.RulesGoStripPrefix)
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
		Variant:            "complete",
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
		Variant:      "complete",
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
		Variant:            "complete",
		RulesGoStripPrefix: "third_party/rules_go_orchestrion_complete",
		DDTraceGoVersion:   DefaultDDTraceGoVersion,
		OrchestrionVersion: DefaultOrchestrionVersion,
	})
	if !strings.Contains(got, commit) {
		t.Fatalf("summary missing current commit:\n%s", got)
	}
	if strings.Contains(got, staleCommit) {
		t.Fatalf("summary contains stale commit %s:\n%s", staleCommit, got)
	}
}

func variantWorkspace(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, variant := range []string{"base", "complete"} {
		if err := os.MkdirAll(filepath.Join(dir, "third_party", "rules_go_orchestrion_"+variant), 0o755); err != nil {
			t.Fatalf("create variant dir: %v", err)
		}
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

func TestFormatShellIncludesCompleteTuple(t *testing.T) {
	pins := Pins{
		RTOCommit:          strings.Repeat("a", 40),
		RTORemote:          DefaultRemote,
		RTOArchiveURL:      "https://example.test/archive.tar.gz",
		RTOArchiveSHA256:   strings.Repeat("1", 64),
		RTOArchivePrefix:   "rules_test_optimization-" + strings.Repeat("a", 40),
		RTOArchiveType:     DefaultArchiveType,
		Variant:            "base",
		RulesGoStripPrefix: "third_party/rules_go_orchestrion_base",
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
		Variant:            "complete",
		RulesGoStripPrefix: "third_party/rules_go_orchestrion_complete",
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
	// RULES_GO_VARIANT="complete"
	// RULES_GO_STRIP_PREFIX="third_party/rules_go_orchestrion_complete"
	// DD_TRACE_GO_VERSION="v2.9.0-dev.0.20260416093245-194346a71c51"
	// ORCHESTRION_VERSION="v1.9.0"
}
