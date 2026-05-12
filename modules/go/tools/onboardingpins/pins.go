// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package onboardingpins

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	// DefaultRemote is the public GitHub repository that publishes the rules.
	DefaultRemote = "https://github.com/DataDog/rules_test_optimization.git"
	// DefaultArchiveType is the archive type used by GitHub codeload tarballs.
	DefaultArchiveType = "tar.gz"
	// DefaultDDTraceGoVersion is the Go tracer version that supports the Bazel JSON payload contract.
	DefaultDDTraceGoVersion = "v2.9.0-dev.0.20260416093245-194346a71c51"
	// DefaultOrchestrionVersion is the Orchestrion version validated by the Go onboarding fixtures.
	DefaultOrchestrionVersion = "v1.9.0"
	// DefaultMainRef is the remote ref that published pins must be reachable from.
	DefaultMainRef = "origin/main"
)

// ArchiveFetcher returns the bytes for one archive URL.
type ArchiveFetcher func(ctx context.Context, url string) (io.ReadCloser, error)

// GitRunner runs one git command in a workspace and returns stdout.
type GitRunner func(ctx context.Context, workspaceDir string, args ...string) (string, error)

// Options describes the inputs needed to produce published onboarding pins.
type Options struct {
	// WorkspaceDir is the repository checkout used for git reachability checks and variant validation.
	WorkspaceDir string
	// Commit is the published rules_test_optimization commit to pin.
	Commit string
	// Remote is the repository remote used by git_repository snippets.
	Remote string
	// Variant is the rules_go Orchestrion variant, either "base" or "complete".
	Variant string
	// ArchiveType is the archive type used by http_archive.
	ArchiveType string
	// DDTraceGoVersion is the tracer version printed in the operator summary.
	DDTraceGoVersion string
	// OrchestrionVersion is the Orchestrion version printed in the operator summary.
	OrchestrionVersion string
	// MainRef is the remote ref that must contain Commit when VerifyMainReachable is true.
	MainRef string
	// VerifyMainReachable requires Commit to be an ancestor of MainRef.
	VerifyMainReachable bool
	// ValidateVariantDir requires the selected variant directory to exist in WorkspaceDir.
	ValidateVariantDir bool
	// FetchArchive overrides archive downloads for tests.
	FetchArchive ArchiveFetcher
	// RunGit overrides git execution for tests.
	RunGit GitRunner
}

// Pins is the complete published tuple consumers need for Go/Orchestrion onboarding.
type Pins struct {
	// RTOCommit is the full published commit SHA.
	RTOCommit string
	// RTORemote is the Git remote used by Datadog repositories.
	RTORemote string
	// RTOArchiveURL is the GitHub codeload URL for RTOCommit.
	RTOArchiveURL string
	// RTOArchiveSHA256 is the SHA256 of the published codeload archive.
	RTOArchiveSHA256 string
	// RTOArchivePrefix is the archive root directory expected by http_archive.
	RTOArchivePrefix string
	// RTOArchiveType is the archive type expected by http_archive.
	RTOArchiveType string
	// Variant is the selected rules_go Orchestrion variant.
	Variant string
	// RulesGoStripPrefix is the archive subdirectory for the selected variant.
	RulesGoStripPrefix string
	// DDTraceGoVersion is the tracer version used by generated onboarding snippets.
	DDTraceGoVersion string
	// OrchestrionVersion is the Orchestrion version used by generated onboarding snippets.
	OrchestrionVersion string
}

// Resolve computes a published pin tuple from a checkout and commit.
func Resolve(ctx context.Context, opts Options) (Pins, error) {
	opts = opts.withDefaults()
	if strings.TrimSpace(opts.Commit) == "" {
		return Pins{}, errors.New("--commit is required and must be a published full SHA")
	}
	if err := validateVariant(opts.Variant); err != nil {
		return Pins{}, err
	}
	if opts.ArchiveType != DefaultArchiveType {
		return Pins{}, fmt.Errorf("--archive-type must be %q for published GitHub codeload pins, got %q", DefaultArchiveType, opts.ArchiveType)
	}
	if opts.ValidateVariantDir {
		if err := validateVariantDir(opts.WorkspaceDir, opts.Variant); err != nil {
			return Pins{}, err
		}
	}
	commit := strings.TrimSpace(opts.Commit)
	if opts.VerifyMainReachable {
		var err error
		commit, err = resolveCommit(ctx, opts)
		if err != nil {
			return Pins{}, err
		}
		if err := verifyCommitReachable(ctx, opts, commit); err != nil {
			return Pins{}, err
		}
	} else if err := validateFullCommit(commit); err != nil {
		return Pins{}, err
	}
	archiveURL, err := CodeloadURL(opts.Remote, commit)
	if err != nil {
		return Pins{}, err
	}
	archiveSHA, err := ArchiveSHA256(ctx, archiveURL, opts.FetchArchive)
	if err != nil {
		return Pins{}, err
	}
	return Pins{
		RTOCommit:          commit,
		RTORemote:          opts.Remote,
		RTOArchiveURL:      archiveURL,
		RTOArchiveSHA256:   archiveSHA,
		RTOArchivePrefix:   ArchivePrefix(opts.Remote, commit),
		RTOArchiveType:     opts.ArchiveType,
		Variant:            opts.Variant,
		RulesGoStripPrefix: "third_party/rules_go_orchestrion_" + opts.Variant,
		DDTraceGoVersion:   opts.DDTraceGoVersion,
		OrchestrionVersion: opts.OrchestrionVersion,
	}, nil
}

// FormatShell renders the published tuple as shell-style assignments.
func FormatShell(pins Pins) string {
	var buf strings.Builder
	fmt.Fprintf(&buf, "RTO_COMMIT=%q\n", pins.RTOCommit)
	fmt.Fprintf(&buf, "RTO_REMOTE=%q\n", pins.RTORemote)
	fmt.Fprintf(&buf, "RTO_ARCHIVE_URL=%q\n", pins.RTOArchiveURL)
	fmt.Fprintf(&buf, "RTO_ARCHIVE_SHA256=%q\n", pins.RTOArchiveSHA256)
	fmt.Fprintf(&buf, "RTO_ARCHIVE_PREFIX=%q\n", pins.RTOArchivePrefix)
	fmt.Fprintf(&buf, "RTO_ARCHIVE_TYPE=%q\n", pins.RTOArchiveType)
	fmt.Fprintf(&buf, "RULES_GO_VARIANT=%q\n", pins.Variant)
	fmt.Fprintf(&buf, "RULES_GO_STRIP_PREFIX=%q\n", pins.RulesGoStripPrefix)
	fmt.Fprintf(&buf, "DD_TRACE_GO_VERSION=%q\n", pins.DDTraceGoVersion)
	fmt.Fprintf(&buf, "ORCHESTRION_VERSION=%q\n", pins.OrchestrionVersion)
	return buf.String()
}

// FormatMarkdownSummary renders a commit-specific onboarding summary for repository guides.
func FormatMarkdownSummary(pins Pins) string {
	var buf strings.Builder
	buf.WriteString("# Datadog Go Test Optimization Onboarding Pins\n\n")
	buf.WriteString("Use this published tuple when wiring a WORKSPACE or Bzlmod repository to the Go/Orchestrion integration.\n\n")
	buf.WriteString("## Published Rules Tuple\n\n")
	fmt.Fprintf(&buf, "- `RTO_COMMIT`: `%s`\n", pins.RTOCommit)
	fmt.Fprintf(&buf, "- `RTO_REMOTE`: `%s`\n", pins.RTORemote)
	fmt.Fprintf(&buf, "- `RTO_ARCHIVE_URL`: `%s`\n", pins.RTOArchiveURL)
	fmt.Fprintf(&buf, "- `RTO_ARCHIVE_SHA256`: `%s`\n", pins.RTOArchiveSHA256)
	fmt.Fprintf(&buf, "- `RTO_ARCHIVE_PREFIX`: `%s`\n", pins.RTOArchivePrefix)
	fmt.Fprintf(&buf, "- `RTO_ARCHIVE_TYPE`: `%s`\n", pins.RTOArchiveType)
	fmt.Fprintf(&buf, "- `rules_go_variant`: `%s`\n", pins.Variant)
	fmt.Fprintf(&buf, "- `rules_go_strip_prefix`: `%s`\n", pins.RulesGoStripPrefix)
	fmt.Fprintf(&buf, "- `dd_trace_go_version`: `%s`\n", pins.DDTraceGoVersion)
	fmt.Fprintf(&buf, "- `orchestrion_version`: `%s`\n", pins.OrchestrionVersion)
	buf.WriteString("\n")
	buf.WriteString("## Recommended Flow\n\n")
	buf.WriteString("1. Wire the published repositories using the tuple above.\n")
	buf.WriteString("2. Run tests with the Test Optimization Bazel config so JSON payloads are downloaded locally.\n")
	buf.WriteString("3. Run the doctor target before uploading payloads.\n")
	buf.WriteString("4. Run the uploader with credentials available only to `bazel run`.\n")
	return buf.String()
}

// ArchivePrefix returns the root directory GitHub places in codeload archives.
func ArchivePrefix(remote, commit string) string {
	repo := "rules_test_optimization"
	if _, parsedRepo, ok := parseGitHubRemote(remote); ok && parsedRepo != "" {
		repo = parsedRepo
	}
	return repo + "-" + commit
}

// CodeloadURL returns the GitHub codeload tarball URL for a remote and commit.
func CodeloadURL(remote, commit string) (string, error) {
	owner, repo, ok := parseGitHubRemote(remote)
	if !ok {
		return "", fmt.Errorf("remote %q is not a supported GitHub remote", remote)
	}
	return fmt.Sprintf("https://codeload.github.com/%s/%s/tar.gz/%s", owner, repo, commit), nil
}

// ArchiveSHA256 streams an archive and returns its SHA256 without writing it to disk.
func ArchiveSHA256(ctx context.Context, archiveURL string, fetch ArchiveFetcher) (string, error) {
	if fetch == nil {
		fetch = defaultArchiveFetcher
	}
	reader, err := fetch(ctx, archiveURL)
	if err != nil {
		return "", err
	}
	defer reader.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, reader); err != nil {
		return "", fmt.Errorf("hash archive %s: %w", archiveURL, err)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// withDefaults fills unset options with the public Go onboarding defaults.
func (opts Options) withDefaults() Options {
	if opts.WorkspaceDir == "" {
		opts.WorkspaceDir = "."
	}
	if opts.Remote == "" {
		opts.Remote = DefaultRemote
	}
	if opts.Variant == "" {
		opts.Variant = "base"
	}
	if opts.ArchiveType == "" {
		opts.ArchiveType = DefaultArchiveType
	}
	if opts.DDTraceGoVersion == "" {
		opts.DDTraceGoVersion = DefaultDDTraceGoVersion
	}
	if opts.OrchestrionVersion == "" {
		opts.OrchestrionVersion = DefaultOrchestrionVersion
	}
	if opts.MainRef == "" {
		opts.MainRef = DefaultMainRef
	}
	if opts.RunGit == nil {
		opts.RunGit = defaultGitRunner
	}
	return opts
}

// validateVariant rejects variant names that are not part of the public contract.
func validateVariant(variant string) error {
	if variant == "base" || variant == "complete" {
		return nil
	}
	return fmt.Errorf("--variant must be \"base\" or \"complete\", got %q", variant)
}

// validateVariantDir confirms the selected vendored fork variant exists locally.
func validateVariantDir(workspaceDir, variant string) error {
	path := filepath.Join(workspaceDir, "third_party", "rules_go_orchestrion_"+variant)
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("rules_go variant %q does not exist at %s", variant, path)
		}
		return fmt.Errorf("stat rules_go variant %s: %w", path, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("rules_go variant path is not a directory: %s", path)
	}
	return nil
}

// resolveCommit resolves any Git revision accepted by git to a full commit SHA.
func resolveCommit(ctx context.Context, opts Options) (string, error) {
	out, err := opts.RunGit(ctx, opts.WorkspaceDir, "rev-parse", "--verify", opts.Commit+"^{commit}")
	if err != nil {
		return "", fmt.Errorf("resolve commit %q: %w", opts.Commit, err)
	}
	commit := strings.TrimSpace(out)
	if !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(commit) {
		return "", fmt.Errorf("resolved commit for %q is not a full SHA: %q", opts.Commit, commit)
	}
	return commit, nil
}

// validateFullCommit requires a commit value that can be embedded in published snippets.
func validateFullCommit(commit string) error {
	if regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(commit) {
		return nil
	}
	return fmt.Errorf("--commit must be a full 40-character lowercase SHA, got %q", commit)
}

// verifyCommitReachable ensures the selected commit is already published on main.
func verifyCommitReachable(ctx context.Context, opts Options, commit string) error {
	if _, err := opts.RunGit(ctx, opts.WorkspaceDir, "rev-parse", "--verify", opts.MainRef+"^{commit}"); err != nil {
		return fmt.Errorf("verify %s exists before publishing pins: %w", opts.MainRef, err)
	}
	if _, err := opts.RunGit(ctx, opts.WorkspaceDir, "merge-base", "--is-ancestor", commit, opts.MainRef); err != nil {
		return fmt.Errorf("commit %s is not reachable from %s; publish or pull main before generating consumer pins", commit, opts.MainRef)
	}
	return nil
}

// defaultGitRunner executes Git commands in the selected workspace.
func defaultGitRunner(ctx context.Context, workspaceDir string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = workspaceDir
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %s failed: %w\n%s", strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return string(output), nil
}

// defaultArchiveFetcher downloads an archive, using GitHub auth when available.
func defaultArchiveFetcher(ctx context.Context, archiveURL string) (io.ReadCloser, error) {
	requestCtx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, archiveURL, nil)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("create archive request: %w", err)
	}
	if token := githubToken(requestCtx); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("download archive %s: %w", archiveURL, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		resp.Body.Close()
		cancel()
		return nil, fmt.Errorf("download archive %s: HTTP %s", archiveURL, resp.Status)
	}
	return cancelOnCloseReadCloser{ReadCloser: resp.Body, cancel: cancel}, nil
}

// githubToken returns an optional GitHub token for private codeload archives.
func githubToken(ctx context.Context) string {
	for _, key := range []string{"GITHUB_TOKEN", "GH_TOKEN"} {
		if token := strings.TrimSpace(os.Getenv(key)); token != "" {
			return token
		}
	}
	cmd := exec.CommandContext(ctx, "gh", "auth", "token")
	output, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

// cancelOnCloseReadCloser keeps the HTTP request context alive until callers
// finish reading the archive stream.
type cancelOnCloseReadCloser struct {
	io.ReadCloser
	cancel context.CancelFunc
}

// Close closes the wrapped stream and releases the request context.
func (c cancelOnCloseReadCloser) Close() error {
	err := c.ReadCloser.Close()
	c.cancel()
	return err
}

// parseGitHubRemote extracts owner and repo names from common GitHub remote forms.
func parseGitHubRemote(remote string) (owner, repo string, ok bool) {
	remote = strings.TrimSuffix(strings.TrimSpace(remote), ".git")
	patterns := []*regexp.Regexp{
		regexp.MustCompile(`^https://github\.com/([^/]+)/([^/]+)$`),
		regexp.MustCompile(`^git@github\.com:([^/]+)/([^/]+)$`),
		regexp.MustCompile(`^ssh://git@github\.com/([^/]+)/([^/]+)$`),
	}
	for _, pattern := range patterns {
		match := pattern.FindStringSubmatch(remote)
		if len(match) == 3 {
			return match[1], match[2], true
		}
	}
	return "", "", false
}
