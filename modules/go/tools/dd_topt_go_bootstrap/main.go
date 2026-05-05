package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	defaultRulesGoVersion        = "0.60.0"
	defaultRulesGoRemote         = "https://github.com/DataDog/rules_test_optimization.git"
	defaultRulesGoCommit         = ""
	defaultRulesGoVariant        = "base"
	defaultDatadogFetch          = "git"
	defaultRulesGoFetch          = "git"
	defaultRulesGoRepoName       = "io_bazel_rules_go"
	defaultOrchestrionVersion    = "v1.9.0"
	defaultDDTraceGoVersion      = "v2.9.0-dev.0.20260416093245-194346a71c51"
	defaultSyncRepoName          = "test_optimization_data"
	defaultDoctorTargetName      = "dd_test_optimization_doctor"
	defaultUploaderTargetName    = "dd_upload_payloads"
	defaultBazelrcPath           = ".bazelrc"
	defaultBazelrcConfig         = "test-optimization"
	managedBlockStart            = "# BEGIN Datadog Go Orchestrion bootstrap"
	managedBlockEnd              = "# END Datadog Go Orchestrion bootstrap"
	bazelrcBlockStart            = "# BEGIN Datadog Test Optimization Bazelrc"
	bazelrcBlockEnd              = "# END Datadog Test Optimization Bazelrc"
	guidedBlockStart             = "# BEGIN Datadog Go Guided Setup"
	guidedBlockEnd               = "# END Datadog Go Guided Setup"
	doctorBlockStart             = "# BEGIN Datadog Go Doctor"
	doctorBlockEnd               = "# END Datadog Go Doctor"
	uploaderBlockStart           = "# BEGIN Datadog Go Uploader"
	uploaderBlockEnd             = "# END Datadog Go Uploader"
	pinExportsBlockStart         = "# BEGIN Datadog Go Pin Files"
	pinExportsBlockEnd           = "# END Datadog Go Pin Files"
	wrapperBlockStart            = "# BEGIN Datadog Go Wrapper"
	wrapperBlockEnd              = "# END Datadog Go Wrapper"
	defaultStarterOrchestrionYML = `---
# yaml-language-server: $schema=https://datadoghq.dev/orchestrion/schema.json
meta:
  name: datadog/go-bootstrap
  description: Datadog starter configuration for Orchestrion.

aspects: []
`
	sharedOrchestrionCacheDirName = "datadog-orchestrion-go-cache"
	toolsBuildDir                 = "tools/build"
	wrapperFileName               = "dd_go_test.bzl"
)

var orchestrionPinFiles = []string{
	"go.mod",
	"go.sum",
	"orchestrion.tool.go",
	"orchestrion.yml",
}

var ddTraceGoModules = []string{
	"github.com/DataDog/dd-trace-go/v2",
	"github.com/DataDog/dd-trace-go/contrib/net/http/v2",
	"github.com/DataDog/dd-trace-go/contrib/log/slog/v2",
}

var ddTraceGoValidationPackages = []string{
	"github.com/DataDog/dd-trace-go/v2/orchestrion",
	"github.com/DataDog/dd-trace-go/contrib/net/http/v2",
	"github.com/DataDog/dd-trace-go/contrib/log/slog/v2",
}

var ddTraceGoWarmPackages = []string{
	"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer",
	"github.com/DataDog/dd-trace-go/v2/profiler",
	"github.com/DataDog/dd-trace-go/v2/instrumentation/env",
	"github.com/DataDog/dd-trace-go/contrib/net/http/v2",
	"github.com/DataDog/dd-trace-go/contrib/log/slog/v2",
}

// bazelrcRepoEnvKeys mirrors the public sync metadata environment contract.
// The generated .bazelrc passes these values to repository/module resolution,
// never to test sandboxes.
var bazelrcRepoEnvKeys = []string{
	"DD_API_KEY",
	"FETCH_SALT",
	"DD_SITE",
	"DD_TEST_OPTIMIZATION_AGENTLESS_URL",
	"DD_SERVICE",
	"DD_ENV",
	"DD_GIT_REPOSITORY_URL",
	"DD_GIT_BRANCH",
	"DD_GIT_TAG",
	"DD_GIT_COMMIT_SHA",
	"DD_GIT_HEAD_COMMIT",
	"DD_GIT_COMMIT_MESSAGE",
	"DD_GIT_HEAD_MESSAGE",
	"DD_GIT_COMMIT_AUTHOR_NAME",
	"DD_GIT_COMMIT_AUTHOR_EMAIL",
	"DD_GIT_COMMIT_AUTHOR_DATE",
	"DD_GIT_COMMIT_COMMITTER_NAME",
	"DD_GIT_COMMIT_COMMITTER_EMAIL",
	"DD_GIT_COMMIT_COMMITTER_DATE",
	"DD_GIT_HEAD_AUTHOR_NAME",
	"DD_GIT_HEAD_AUTHOR_EMAIL",
	"DD_GIT_HEAD_AUTHOR_DATE",
	"DD_GIT_HEAD_COMMITTER_NAME",
	"DD_GIT_HEAD_COMMITTER_EMAIL",
	"DD_GIT_HEAD_COMMITTER_DATE",
	"DD_GIT_PR_BASE_BRANCH",
	"DD_GIT_PR_BASE_BRANCH_SHA",
	"DD_GIT_PR_BASE_BRANCH_HEAD_SHA",
	"DD_PR_NUMBER",
}

type config struct {
	workspaceDir          string
	moduleFile            string
	goModuleDir           string
	force                 bool
	guided                bool
	printWorkspaceSnippet bool
	printBazelrcSnippet   bool
	writeBazelrc          bool
	bazelrcPath           string
	bazelrcConfig         string
	service               string
	runtimeVersion        string
	goModulePath          string
	syncRepoName          string
	doctorTargetName      string
	uploaderTargetName    string
	orchestrionVersion    string
	ddTraceGoVersion      string
	ddTraceGoVersions     map[string]string
	ddTraceGoVersionSet   bool
	rulesGoRemote         string
	rulesGoCommit         string
	datadogFetch          string
	rulesGoFetch          string
	rulesGoRepoName       string
	rtoCommit             string
	rtoArchiveURL         string
	rtoArchiveSHA256      string
	rtoArchivePrefix      string
	rtoArchiveType        string
	// rulesGoRemoteSet records whether the operator explicitly selected the
	// rules_go fork remote instead of accepting the inferred/default remote.
	rulesGoRemoteSet bool
	// rulesGoCommitSet records whether the operator explicitly selected the
	// rules_go fork commit instead of accepting an inferred commit.
	rulesGoCommitSet  bool
	rulesGoVariant    string
	rulesGoVariantSet bool
}

func main() {
	cfg := parseFlags()
	if err := run(cfg); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func parseFlags() config {
	workspaceDefault := os.Getenv("BUILD_WORKSPACE_DIRECTORY")
	if workspaceDefault == "" {
		cwd, _ := os.Getwd()
		workspaceDefault = cwd
	}

	cfg := config{}
	flag.StringVar(&cfg.workspaceDir, "workspace", workspaceDefault, "Workspace root to update")
	flag.StringVar(&cfg.goModuleDir, "go-module-dir", "", "Go module directory to pin for Orchestrion (defaults to workspace root)")
	flag.BoolVar(&cfg.force, "force", false, "Allow overwriting Datadog-managed bootstrap files")
	flag.BoolVar(&cfg.guided, "guided", false, "Generate Datadog-managed single-service Go onboarding files")
	flag.BoolVar(&cfg.printWorkspaceSnippet, "print-workspace-snippet", false, "Print WORKSPACE-mode repository wiring and exit without modifying files")
	flag.BoolVar(&cfg.printBazelrcSnippet, "print-bazelrc-snippet", false, "Print recommended .bazelrc configuration and exit without modifying files")
	flag.BoolVar(&cfg.writeBazelrc, "write-bazelrc", false, "Insert or replace the Datadog-managed .bazelrc configuration block")
	flag.StringVar(&cfg.bazelrcPath, "bazelrc-path", defaultBazelrcPath, "Path to the .bazelrc file to update when --write-bazelrc is set")
	flag.StringVar(&cfg.bazelrcConfig, "bazelrc-config", defaultBazelrcConfig, "Bazel config name used by the generated .bazelrc block")
	flag.StringVar(&cfg.service, "service", "", "Datadog service name for guided single-service Go setup")
	flag.StringVar(&cfg.runtimeVersion, "runtime-version", "", "Go runtime version for guided single-service Go setup")
	flag.StringVar(&cfg.syncRepoName, "sync-repo-name", defaultSyncRepoName, "Repository name generated by guided single-service Go setup")
	flag.StringVar(&cfg.doctorTargetName, "doctor-target-name", defaultDoctorTargetName, "Root doctor target name generated by guided single-service Go setup")
	flag.StringVar(&cfg.uploaderTargetName, "uploader-target-name", defaultUploaderTargetName, "Root uploader target name generated by guided single-service Go setup")
	flag.StringVar(&cfg.orchestrionVersion, "orchestrion-version", defaultOrchestrionVersion, "Orchestrion version to configure")
	flag.StringVar(&cfg.ddTraceGoVersion, "dd-trace-go-version", defaultDDTraceGoVersion, "dd-trace-go version to pin for Orchestrion-backed instrumentation")
	flag.StringVar(&cfg.rulesGoRemote, "rules-go-remote", defaultRulesGoRemote, "rules_go fork remote used for Orchestrion support")
	flag.StringVar(&cfg.rulesGoCommit, "rules-go-commit", defaultRulesGoCommit, "rules_go fork commit used for Orchestrion support; inferred from Datadog git_override wiring when omitted")
	flag.StringVar(&cfg.rulesGoVariant, "rules-go-variant", defaultRulesGoVariant, "rules_go Orchestrion variant to use: base or complete")
	flag.StringVar(&cfg.datadogFetch, "datadog-fetch", defaultDatadogFetch, "WORKSPACE snippet fetch mode for Datadog companion repositories: git or archive")
	flag.StringVar(&cfg.rulesGoFetch, "rules-go-fetch", defaultRulesGoFetch, "WORKSPACE snippet fetch mode for rules_go: git or archive")
	flag.StringVar(&cfg.rulesGoRepoName, "rules-go-repo-name", defaultRulesGoRepoName, "WORKSPACE snippet repository name for the rules_go fork")
	flag.StringVar(&cfg.rtoCommit, "rto-commit", "", "WORKSPACE snippet commit for Datadog repositories; falls back to --rules-go-commit when omitted")
	flag.StringVar(&cfg.rtoArchiveURL, "rto-archive-url", "", "WORKSPACE snippet archive URL for archive fetch mode")
	flag.StringVar(&cfg.rtoArchiveSHA256, "rto-archive-sha256", "", "WORKSPACE snippet archive SHA256 for archive fetch mode")
	flag.StringVar(&cfg.rtoArchivePrefix, "rto-archive-prefix", "", "WORKSPACE snippet archive root prefix for archive fetch mode")
	flag.StringVar(&cfg.rtoArchiveType, "rto-archive-type", "tar.gz", "WORKSPACE snippet archive type for archive fetch mode")
	flag.Parse()
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "dd-trace-go-version" {
			cfg.ddTraceGoVersionSet = true
		}
		if f.Name == "rules-go-remote" {
			cfg.rulesGoRemoteSet = true
		}
		if f.Name == "rules-go-commit" {
			cfg.rulesGoCommitSet = true
		}
		if f.Name == "rules-go-variant" {
			cfg.rulesGoVariantSet = true
		}
	})
	return cfg
}

func run(cfg config) error {
	if cfg.workspaceDir == "" {
		return errors.New("workspace directory is required")
	}
	if err := validateRulesGoVariant(cfg.rulesGoVariant); err != nil {
		return err
	}
	if err := validateFetchMode(cfg.datadogFetch, "datadog-fetch"); err != nil {
		return err
	}
	if err := validateFetchMode(cfg.rulesGoFetch, "rules-go-fetch"); err != nil {
		return err
	}
	if cfg.printBazelrcSnippet {
		snippet, err := bazelrcSnippet(cfg)
		if err != nil {
			return err
		}
		fmt.Print(snippet)
		return nil
	}
	if cfg.printWorkspaceSnippet {
		snippet, err := workspaceSnippet(cfg)
		if err != nil {
			return err
		}
		fmt.Print(snippet)
		return nil
	}
	workspaceDir, err := filepath.Abs(cfg.workspaceDir)
	if err != nil {
		return fmt.Errorf("resolve workspace: %w", err)
	}
	cfg.workspaceDir = workspaceDir
	if cfg.goModuleDir == "" {
		cfg.goModuleDir = workspaceDir
	} else if !filepath.IsAbs(cfg.goModuleDir) {
		cfg.goModuleDir = filepath.Join(workspaceDir, cfg.goModuleDir)
	}
	cfg.moduleFile = filepath.Join(workspaceDir, "MODULE.bazel")

	if cfg.guided {
		if strings.TrimSpace(cfg.service) == "" {
			return errors.New("--guided requires --service")
		}
		if strings.TrimSpace(cfg.runtimeVersion) == "" {
			return errors.New("--guided requires --runtime-version")
		}
		if strings.TrimSpace(cfg.syncRepoName) == "" {
			return errors.New("--guided requires a non-empty --sync-repo-name")
		}
		if strings.TrimSpace(cfg.doctorTargetName) == "" {
			return errors.New("--guided requires a non-empty --doctor-target-name")
		}
		if strings.TrimSpace(cfg.uploaderTargetName) == "" {
			return errors.New("--guided requires a non-empty --uploader-target-name")
		}
	}
	if cfg.writeBazelrc {
		if err := writeBazelrcBlock(cfg); err != nil {
			return err
		}
		if !cfg.guided {
			return nil
		}
	}

	if err := ensureFileExists(cfg.moduleFile, "MODULE.bazel"); err != nil {
		return err
	}
	if err := ensureFileExists(filepath.Join(cfg.goModuleDir, "go.mod"), "go.mod"); err != nil {
		return err
	}
	goModulePath, err := readGoModulePath(filepath.Join(cfg.goModuleDir, "go.mod"))
	if err != nil {
		return err
	}
	cfg.goModulePath = goModulePath

	moduleContent, err := os.ReadFile(cfg.moduleFile)
	if err != nil {
		return fmt.Errorf("read MODULE.bazel: %w", err)
	}

	originalDDTraceGoVersionQuery := cfg.ddTraceGoVersion
	if err := ensureBootstrapCanManageTracerConfig(string(moduleContent)); err != nil {
		return err
	}
	if !cfg.ddTraceGoVersionSet {
		if err := hydrateManagedTracerConfig(&cfg, string(moduleContent)); err != nil {
			return err
		}
	}
	if !cfg.rulesGoVariantSet {
		if err := hydrateManagedRulesGoVariant(&cfg, string(moduleContent)); err != nil {
			return err
		}
	}

	if cfg.ddTraceGoVersionSet {
		if err := normalizeDDTraceGoVersion(&cfg); err != nil {
			return err
		}
	} else if !cfg.hasTracerConfig() {
		cfg.ddTraceGoVersion = defaultDDTraceGoVersion
		cfg.ddTraceGoVersions = nil
	}

	if err := patchModuleFile(cfg); err != nil {
		return err
	}
	if cfg.guided {
		if err := ensureGuidedWorkspaceFiles(cfg); err != nil {
			return err
		}
	}
	if err := writeOrchestrionToolFile(cfg); err != nil {
		return err
	}
	if err := ensureCIVisibilityOrchestrionImport(cfg); err != nil {
		return err
	}
	if err := syncDDTraceGoVersion(cfg); err != nil {
		return err
	}
	if err := warmOrchestrionModuleCache(cfg); err != nil {
		return err
	}
	if err := verifyResolvedBootstrapModuleVersions(cfg); err != nil {
		return fmt.Errorf("%w\nbootstrap may have already updated these files: MODULE.bazel, go.mod, go.sum, orchestrion.tool.go%s", err, maybeChangedStarterYML(cfg.goModuleDir))
	}
	if err := writeStarterOrchestrionYML(cfg); err != nil {
		return err
	}

	fmt.Printf("Updated %s and pinned Orchestrion in %s\n", cfg.moduleFile, cfg.goModuleDir)
	switch {
	case cfg.ddTraceGoVersionSet && cfg.usesPerModuleTracerConfig():
		fmt.Printf("Resolved dd-trace-go query %q to per-module versions and persisted the exact resolved versions.\n", originalDDTraceGoVersionQuery)
	case cfg.ddTraceGoVersionSet && originalDDTraceGoVersionQuery != cfg.ddTraceGoVersion:
		fmt.Printf("Normalized dd-trace-go query %q to canonical version %q and persisted the canonical version.\n", originalDDTraceGoVersionQuery, cfg.ddTraceGoVersion)
	}
	return nil
}

func ensureFileExists(path, label string) error {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("%s not found at %s", label, path)
		}
		return fmt.Errorf("stat %s: %w", path, err)
	}
	if info.IsDir() {
		return fmt.Errorf("%s path is a directory: %s", label, path)
	}
	return nil
}

// readGoModulePath returns the module path declared by a go.mod file.
func readGoModulePath(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read go.mod: %w", err)
	}
	for _, line := range strings.Split(string(content), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "//") {
			continue
		}
		if strings.HasPrefix(trimmed, "module ") || strings.HasPrefix(trimmed, "module\t") {
			modulePath := strings.TrimSpace(strings.TrimPrefix(trimmed, "module"))
			fields := strings.Fields(modulePath)
			if len(fields) > 0 {
				modulePath = fields[0]
			}
			modulePath = strings.Trim(modulePath, `"`)
			if modulePath == "" {
				return "", fmt.Errorf("go.mod at %s has an empty module path", path)
			}
			return modulePath, nil
		}
	}
	return "", fmt.Errorf("go.mod at %s does not declare a module path", path)
}

func patchModuleFile(cfg config) error {
	content, err := os.ReadFile(cfg.moduleFile)
	if err != nil {
		return fmt.Errorf("read MODULE.bazel: %w", err)
	}
	text := string(content)

	if cfg.guided {
		if err := validateGuidedPrerequisites(text); err != nil {
			return err
		}
	}

	if !strings.Contains(text, `bazel_dep(name = "rules_go"`) && !strings.Contains(text, `bazel_dep(name="rules_go"`) {
		snippet := fmt.Sprintf(`bazel_dep(name = "rules_go", version = "%s")%s`, defaultRulesGoVersion, "\n")
		text, err = insertAfterModuleDecl(text, snippet)
		if err != nil {
			return err
		}
	}

	if !cfg.rulesGoCommitSet {
		if remote, commit := inferManagedRulesGoOverride(text); remote != "" && commit != "" {
			if !cfg.rulesGoRemoteSet {
				cfg.rulesGoRemote = remote
			}
			cfg.rulesGoCommit = commit
		}
	}

	if !cfg.rulesGoRemoteSet && !cfg.rulesGoCommitSet && cfg.rulesGoCommit == "" {
		if remote, commit := inferDatadogRepoOverride(text); remote != "" && commit != "" {
			cfg.rulesGoRemote = remote
			cfg.rulesGoCommit = commit
		}
	}

	if strings.TrimSpace(cfg.rulesGoCommit) == "" {
		return errors.New("rules_go fork commit is required; add a git_override for datadog-rules-test-optimization-go/datadog-rules-test-optimization or pass --rules-go-commit explicitly")
	}

	if !strings.Contains(text, managedBlockStart) && strings.Contains(text, `module_name = "rules_go"`) && !rulesGoOverrideCompatible(text, cfg) {
		return errors.New("MODULE.bazel already contains an incompatible rules_go git_override; update it manually before running the Datadog bootstrap")
	}

	managedBlock := managedModuleBlock(cfg)

	text, err = replaceManagedSection(text, managedBlockStart, managedBlockEnd, managedBlock)
	if err != nil {
		return err
	}

	if cfg.guided {
		addGuidedBlock, err := shouldAddGuidedBlock(text, cfg)
		if err != nil {
			return err
		}
		if addGuidedBlock {
			text, err = replaceManagedSection(text, guidedBlockStart, guidedBlockEnd, managedGuidedModuleBlock(cfg))
			if err != nil {
				return err
			}
		}
	}

	if err := os.WriteFile(cfg.moduleFile, []byte(text), 0o644); err != nil {
		return fmt.Errorf("write MODULE.bazel: %w", err)
	}
	return nil
}

func managedModuleBlock(cfg config) string {
	return fmt.Sprintf(`%s
git_override(
    module_name = "rules_go",
    remote = "%s",
    commit = "%s",
    strip_prefix = "%s",
)

orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = "%s",
%s
)
use_repo(orchestrion, "rules_go_orchestrion_tool")
%s
`, managedBlockStart, cfg.rulesGoRemote, cfg.rulesGoCommit, rulesGoStripPrefix(cfg), cfg.orchestrionVersion, managedTracerConfigBlock(cfg), managedBlockEnd)
}

func validateRulesGoVariant(variant string) error {
	// Keep the public bootstrap contract explicit: normal consumers use the
	// generic base variant, while large monorepos can opt into complete.
	if variant == "base" || variant == "complete" {
		return nil
	}
	return fmt.Errorf("--rules-go-variant must be \"base\" or \"complete\", got %q", variant)
}

func validateFetchMode(value, flagName string) error {
	if value == "git" || value == "archive" {
		return nil
	}
	return fmt.Errorf("--%s must be \"git\" or \"archive\", got %q", flagName, value)
}

// validateBazelrcConfig validates the config suffix used in generated Bazel
// flags.
func validateBazelrcConfig(configName string) error {
	// Bazel config suffixes cannot be empty because every generated command is
	// documented as --config=<name>.
	if strings.TrimSpace(configName) == "" {
		return errors.New("--bazelrc-config must be non-empty")
	}
	if strings.ContainsAny(configName, " \t\r\n") {
		return fmt.Errorf("--bazelrc-config must not contain whitespace, got %q", configName)
	}
	return nil
}

// bazelrcSnippet renders the managed .bazelrc block for Go onboarding.
func bazelrcSnippet(cfg config) (string, error) {
	if err := validateBazelrcConfig(cfg.bazelrcConfig); err != nil {
		return "", err
	}

	var buf strings.Builder
	buf.WriteString(bazelrcBlockStart)
	buf.WriteString("\n")
	for _, key := range bazelrcRepoEnvKeys {
		fmt.Fprintf(&buf, "common:%s --repo_env=%s\n", cfg.bazelrcConfig, key)
	}
	fmt.Fprintf(&buf, "test:%s --remote_download_outputs=all\n", cfg.bazelrcConfig)
	buf.WriteString(bazelrcBlockEnd)
	buf.WriteString("\n")
	return buf.String(), nil
}

// writeBazelrcBlock inserts or replaces the managed .bazelrc block.
func writeBazelrcBlock(cfg config) error {
	if strings.TrimSpace(cfg.bazelrcPath) == "" {
		return errors.New("--bazelrc-path must be non-empty")
	}
	snippet, err := bazelrcSnippet(cfg)
	if err != nil {
		return err
	}
	path := cfg.bazelrcPath
	if !filepath.IsAbs(path) {
		path = filepath.Join(cfg.workspaceDir, path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create %s: %w", filepath.Dir(path), err)
	}
	content, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read %s: %w", path, err)
	}
	text := snippet
	if len(content) > 0 {
		text, err = replaceManagedSection(string(content), bazelrcBlockStart, bazelrcBlockEnd, strings.TrimRight(snippet, "\n"))
		if err != nil {
			return err
		}
		text = strings.TrimRight(text, "\n") + "\n"
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

func workspaceSnippet(cfg config) (string, error) {
	if cfg.rulesGoRepoName == "" {
		return "", errors.New("--rules-go-repo-name must be non-empty")
	}
	rtoCommit := cfg.rtoCommit
	if strings.TrimSpace(rtoCommit) == "" {
		rtoCommit = cfg.rulesGoCommit
	}
	if (cfg.datadogFetch == "git" || cfg.rulesGoFetch == "git") && strings.TrimSpace(rtoCommit) == "" {
		return "", errors.New("--rto-commit is required when --datadog-fetch or --rules-go-fetch is git")
	}
	if cfg.datadogFetch == "archive" || cfg.rulesGoFetch == "archive" {
		missing := []string{}
		if cfg.rtoArchiveURL == "" {
			missing = append(missing, "--rto-archive-url")
		}
		if cfg.rtoArchiveSHA256 == "" {
			missing = append(missing, "--rto-archive-sha256")
		}
		if cfg.rtoArchivePrefix == "" {
			missing = append(missing, "--rto-archive-prefix")
		}
		if cfg.rtoArchiveType == "" {
			missing = append(missing, "--rto-archive-type")
		}
		if len(missing) > 0 {
			return "", fmt.Errorf("archive WORKSPACE snippet mode requires %s", strings.Join(missing, ", "))
		}
	}

	var buf strings.Builder
	buf.WriteString(`# Datadog Test Optimization Go/Orchestrion WORKSPACE wiring.
load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

`)
	if cfg.datadogFetch == "git" {
		buf.WriteString(fmt.Sprintf(`git_repository(
    name = "datadog-rules-test-optimization",
    commit = "%s",
    remote = "%s",
)

`, rtoCommit, cfg.rulesGoRemote))
	} else {
		buf.WriteString(fmt.Sprintf(`http_archive(
    name = "datadog-rules-test-optimization",
    urls = ["%s"],
    sha256 = "%s",
    type = "%s",
    strip_prefix = "%s",
)

`, cfg.rtoArchiveURL, cfg.rtoArchiveSHA256, cfg.rtoArchiveType, cfg.rtoArchivePrefix))
	}

	buf.WriteString(fmt.Sprintf(`load("@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl", "datadog_go_test_optimization_workspace_repositories")

datadog_go_test_optimization_workspace_repositories(
    rto_commit = "%s",
    rto_remote = "%s",
    datadog_fetch = "%s",
    rules_go_fetch = "%s",
    rules_go_repo_name = "%s",
    rules_go_variant = "%s",
`, rtoCommit, cfg.rulesGoRemote, cfg.datadogFetch, cfg.rulesGoFetch, cfg.rulesGoRepoName, cfg.rulesGoVariant))
	if cfg.datadogFetch == "archive" || cfg.rulesGoFetch == "archive" {
		buf.WriteString(fmt.Sprintf(`    rto_archive_url = "%s",
    rto_archive_sha256 = "%s",
    rto_archive_prefix = "%s",
    rto_archive_type = "%s",
`, cfg.rtoArchiveURL, cfg.rtoArchiveSHA256, cfg.rtoArchivePrefix, cfg.rtoArchiveType))
	}
	buf.WriteString(")\n\n")

	buf.WriteString(fmt.Sprintf(`load("@%s//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")
load("@%s//go:orchestrion_workspace.bzl", "go_orchestrion_tool_repo")

go_rules_dependencies()
go_register_toolchains(version = "<go-version>")
go_orchestrion_tool_repo(
    version = "%s",
%s
)
`, cfg.rulesGoRepoName, cfg.rulesGoRepoName, cfg.orchestrionVersion, workspaceSnippetTracerConfig(cfg)))
	return buf.String(), nil
}

func workspaceSnippetTracerConfig(cfg config) string {
	if cfg.usesPerModuleTracerConfig() {
		var buf strings.Builder
		buf.WriteString("    dd_trace_go_versions = {\n")
		for _, modulePath := range ddTraceGoModules {
			buf.WriteString(fmt.Sprintf("        %q: %q,\n", modulePath, cfg.ddTraceGoVersions[modulePath]))
		}
		buf.WriteString("    },")
		return buf.String()
	}
	return fmt.Sprintf("    dd_trace_go_version = %q,", cfg.ddTraceGoVersion)
}

func rulesGoStripPrefix(cfg config) string {
	variant := cfg.rulesGoVariant
	if variant == "" {
		variant = defaultRulesGoVariant
	}
	return "third_party/rules_go_orchestrion_" + variant
}

func managedTracerConfigBlock(cfg config) string {
	if cfg.usesPerModuleTracerConfig() {
		var buf strings.Builder
		buf.WriteString("    dd_trace_go_versions = {\n")
		for _, modulePath := range ddTraceGoModules {
			buf.WriteString(fmt.Sprintf("        %q: %q,\n", modulePath, cfg.ddTraceGoVersions[modulePath]))
		}
		buf.WriteString("    },")
		return buf.String()
	}
	return fmt.Sprintf("    dd_trace_go_version = %q,", cfg.ddTraceGoVersion)
}

func managedGuidedModuleBlock(cfg config) string {
	modulePathLine := ""
	if cfg.goModulePath != "" {
		modulePathLine = fmt.Sprintf("    module_path = %q,\n", cfg.goModulePath)
	}
	return fmt.Sprintf(`%s
datadog_go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

datadog_go_topt.test_optimization_go(
    name = "%s",
    service = "%s",
    runtime_version = "%s",
%s)

use_repo(datadog_go_topt, "%s")
%s
`, guidedBlockStart, cfg.syncRepoName, cfg.service, cfg.runtimeVersion, modulePathLine, cfg.syncRepoName, guidedBlockEnd)
}

func insertAfterModuleDecl(content, snippet string) (string, error) {
	start := strings.Index(content, "module(")
	if start < 0 {
		return "", errors.New("MODULE.bazel does not contain a module(...) declaration")
	}
	depth := 0
	for idx, r := range content[start:] {
		switch r {
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				insertAt := start + idx + 1
				return content[:insertAt] + "\n\n" + snippet + content[insertAt:], nil
			}
		}
	}
	return "", errors.New("failed to locate the end of module(...) in MODULE.bazel")
}

func replaceManagedSection(content, startMarker, endMarker, block string) (string, error) {
	start := strings.Index(content, startMarker)
	end := strings.Index(content, endMarker)
	switch {
	case start >= 0 && end >= 0 && end > start:
		end += len(endMarker)
		return content[:start] + block + content[end:], nil
	case start >= 0 || end >= 0:
		return "", fmt.Errorf("existing Datadog managed block is malformed: %s / %s", startMarker, endMarker)
	}

	var buf bytes.Buffer
	buf.WriteString(content)
	if !strings.HasSuffix(content, "\n") {
		buf.WriteString("\n")
	}
	buf.WriteString("\n")
	buf.WriteString(block)
	return buf.String(), nil
}

// removeManagedSectionIfPresent removes a managed block without creating it
// when it is absent.
func removeManagedSectionIfPresent(content, startMarker, endMarker string) (string, error) {
	start := strings.Index(content, startMarker)
	end := strings.Index(content, endMarker)
	switch {
	case start >= 0 && end >= 0 && end > start:
		end += len(endMarker)
		return content[:start] + content[end:], nil
	case start >= 0 || end >= 0:
		return "", fmt.Errorf("existing Datadog managed block is malformed: %s / %s", startMarker, endMarker)
	default:
		return content, nil
	}
}

func inferDatadogRepoOverride(content string) (string, string) {
	overridePattern := regexp.MustCompile(`(?s)git_override\(\s*module_name\s*=\s*"([^"]+)"(.*?)\n\)`)
	remotePattern := regexp.MustCompile(`remote\s*=\s*"([^"]+)"`)
	commitPattern := regexp.MustCompile(`commit\s*=\s*"([^"]+)"`)

	for _, match := range overridePattern.FindAllStringSubmatch(content, -1) {
		moduleName := match[1]
		if moduleName != "datadog-rules-test-optimization" && moduleName != "datadog-rules-test-optimization-go" {
			continue
		}
		body := match[2]
		remoteMatch := remotePattern.FindStringSubmatch(body)
		commitMatch := commitPattern.FindStringSubmatch(body)
		if len(remoteMatch) < 2 || len(commitMatch) < 2 {
			continue
		}
		return remoteMatch[1], commitMatch[1]
	}
	return "", ""
}

func inferManagedRulesGoOverride(content string) (string, string) {
	// Rerunning bootstrap should preserve the published fork commit already
	// written in the managed rules_go override. This avoids depending on an
	// embedded commit that may not survive squash-merge publication.
	start := strings.Index(content, managedBlockStart)
	end := strings.Index(content, managedBlockEnd)
	if start < 0 || end < 0 || end <= start {
		return "", ""
	}
	return inferRulesGoOverride(content[start:end])
}

func inferRulesGoOverride(content string) (string, string) {
	// Return the remote and commit from an existing rules_go override when the
	// workspace already owns that wiring.
	overridePattern := regexp.MustCompile(`(?s)git_override\(\s*module_name\s*=\s*"rules_go"(.*?)\n\)`)
	remotePattern := regexp.MustCompile(`remote\s*=\s*"([^"]+)"`)
	commitPattern := regexp.MustCompile(`commit\s*=\s*"([^"]+)"`)

	match := overridePattern.FindStringSubmatch(content)
	if len(match) < 2 {
		return "", ""
	}
	body := match[1]
	remoteMatch := remotePattern.FindStringSubmatch(body)
	commitMatch := commitPattern.FindStringSubmatch(body)
	if len(remoteMatch) < 2 || len(commitMatch) < 2 {
		return "", ""
	}
	return remoteMatch[1], commitMatch[1]
}

type goExtensionCall struct {
	name           string
	service        string
	runtimeVersion string
	hasServices    bool
}

func validateGuidedPrerequisites(content string) error {
	if !hasModuleReference(content, "datadog-rules-test-optimization") {
		return errors.New("guided bootstrap requires the Datadog core module wiring in MODULE.bazel; add the datadog-rules-test-optimization dependency/override first")
	}
	if !hasModuleReference(content, "datadog-rules-test-optimization-go") {
		return errors.New("guided bootstrap requires the Datadog Go companion wiring in MODULE.bazel; add the datadog-rules-test-optimization-go dependency/override first")
	}
	return nil
}

func hasModuleReference(content, moduleName string) bool {
	patterns := []string{
		fmt.Sprintf(`bazel_dep(name = "%s"`, moduleName),
		fmt.Sprintf(`bazel_dep(name="%s"`, moduleName),
		fmt.Sprintf(`module_name = "%s"`, moduleName),
		fmt.Sprintf(`module_name="%s"`, moduleName),
	}
	for _, pattern := range patterns {
		if strings.Contains(content, pattern) {
			return true
		}
	}
	return false
}

func shouldAddGuidedBlock(content string, cfg config) (bool, error) {
	hasManagedGuidedBlock := strings.Contains(content, guidedBlockStart) || strings.Contains(content, guidedBlockEnd)
	scanContent := content
	if stripped, ok := stripManagedSectionIfPresent(content, guidedBlockStart, guidedBlockEnd); ok {
		scanContent = stripped
	}

	if strings.Contains(scanContent, `"test_optimization_sync_extension"`) {
		return false, errors.New("guided bootstrap only supports fresh single-service Go workspaces; found existing test_optimization_sync_extension setup")
	}
	if strings.Contains(scanContent, `"test_optimization_multi_sync_extension"`) {
		return false, errors.New("guided bootstrap only supports fresh single-service Go workspaces; found existing test_optimization_multi_sync_extension setup")
	}

	if !strings.Contains(scanContent, `"test_optimization_go_extension"`) && !strings.Contains(scanContent, `.test_optimization_go(`) {
		return true, nil
	}

	calls := extractGoExtensionCalls(scanContent)
	if len(calls) == 0 {
		return false, errors.New("guided bootstrap found existing test_optimization_go_extension wiring but could not validate it; use the manual Go setup path instead")
	}
	if len(calls) > 1 {
		return false, errors.New("guided bootstrap only supports fresh single-service Go workspaces; found multiple test_optimization_go(...) tags")
	}

	call := calls[0]
	if call.hasServices {
		return false, errors.New("guided bootstrap only supports fresh single-service Go workspaces; found services = [...] in test_optimization_go(...)")
	}
	if call.name != cfg.syncRepoName || call.service != cfg.service || call.runtimeVersion != cfg.runtimeVersion {
		return false, fmt.Errorf("guided bootstrap found conflicting test_optimization_go(...) wiring (name=%q service=%q runtime_version=%q); use the manual Go setup path instead", call.name, call.service, call.runtimeVersion)
	}
	if !moduleUsesRepo(scanContent, cfg.syncRepoName) {
		return false, fmt.Errorf("guided bootstrap found matching test_optimization_go(...) wiring but missing use_repo(..., %q); use the manual Go setup path instead", cfg.syncRepoName)
	}
	if hasManagedGuidedBlock {
		return false, errors.New("guided bootstrap found duplicate single-service Go sync wiring outside the Datadog-managed block; use the manual Go setup path instead")
	}
	return false, nil
}

func stripManagedSectionIfPresent(content, startMarker, endMarker string) (string, bool) {
	start := strings.Index(content, startMarker)
	end := strings.Index(content, endMarker)
	if start < 0 || end < 0 || end <= start {
		return content, false
	}
	end += len(endMarker)
	return content[:start] + content[end:], true
}

func extractGoExtensionCalls(content string) []goExtensionCall {
	callPattern := regexp.MustCompile(`(?s)[A-Za-z_][A-Za-z0-9_]*\.test_optimization_go\((.*?)\n\)`)
	namePattern := regexp.MustCompile(`(?m)^\s*name\s*=\s*"([^"]+)"`)
	servicePattern := regexp.MustCompile(`(?m)^\s*service\s*=\s*"([^"]+)"`)
	runtimeVersionPattern := regexp.MustCompile(`(?m)^\s*runtime_version\s*=\s*"([^"]+)"`)
	servicesPattern := regexp.MustCompile(`(?m)^\s*services\s*=`)

	matches := callPattern.FindAllStringSubmatch(content, -1)
	calls := make([]goExtensionCall, 0, len(matches))
	for _, match := range matches {
		body := match[1]
		call := goExtensionCall{
			hasServices: servicesPattern.MatchString(body),
		}
		if nameMatch := namePattern.FindStringSubmatch(body); len(nameMatch) == 2 {
			call.name = nameMatch[1]
		}
		if serviceMatch := servicePattern.FindStringSubmatch(body); len(serviceMatch) == 2 {
			call.service = serviceMatch[1]
		}
		if runtimeVersionMatch := runtimeVersionPattern.FindStringSubmatch(body); len(runtimeVersionMatch) == 2 {
			call.runtimeVersion = runtimeVersionMatch[1]
		}
		calls = append(calls, call)
	}
	return calls
}

func moduleUsesRepo(content, repoName string) bool {
	pattern := regexp.MustCompile(`(?s)use_repo\((.*?)\)`)
	for _, match := range pattern.FindAllStringSubmatch(content, -1) {
		if strings.Contains(match[1], fmt.Sprintf("%q", repoName)) {
			return true
		}
	}
	return false
}

func rulesGoOverrideCompatible(content string, cfg config) bool {
	overridePattern := regexp.MustCompile(`(?s)git_override\(\s*module_name\s*=\s*"rules_go"(.*?)\n\)`)
	remotePattern := regexp.MustCompile(`remote\s*=\s*"([^"]+)"`)
	commitPattern := regexp.MustCompile(`commit\s*=\s*"([^"]+)"`)
	stripPrefixPattern := regexp.MustCompile(`strip_prefix\s*=\s*"([^"]+)"`)

	match := overridePattern.FindStringSubmatch(content)
	if len(match) < 2 {
		return false
	}
	body := match[1]
	remoteMatch := remotePattern.FindStringSubmatch(body)
	commitMatch := commitPattern.FindStringSubmatch(body)
	stripPrefixMatch := stripPrefixPattern.FindStringSubmatch(body)
	if len(remoteMatch) < 2 || len(commitMatch) < 2 || len(stripPrefixMatch) < 2 {
		return false
	}
	return remoteMatch[1] == cfg.rulesGoRemote && commitMatch[1] == cfg.rulesGoCommit && stripPrefixMatch[1] == rulesGoStripPrefix(cfg)
}

func ensureGuidedWorkspaceFiles(cfg config) error {
	if err := ensureGuidedRootBuild(cfg); err != nil {
		return err
	}
	if err := ensureGuidedGoModuleBuild(cfg); err != nil {
		return err
	}
	if err := ensureGuidedWrapper(cfg); err != nil {
		return err
	}
	return nil
}

func ensureGuidedRootBuild(cfg config) error {
	buildPath, err := selectPackageFile(cfg.workspaceDir)
	if err != nil {
		return err
	}
	content, err := os.ReadFile(buildPath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read %s: %w", buildPath, err)
	}
	text := string(content)

	if !strings.Contains(text, doctorBlockStart) && hasNamedTarget(text, cfg.doctorTargetName) {
		if !cfg.force {
			return fmt.Errorf("%s already contains an unmanaged target named %q; rerun with --force or use the manual Go setup path", filepath.Base(buildPath), cfg.doctorTargetName)
		}
		text, err = removeNamedTarget(text, cfg.doctorTargetName)
		if err != nil {
			return err
		}
	}
	if !strings.Contains(text, uploaderBlockStart) && hasNamedTarget(text, cfg.uploaderTargetName) {
		if !cfg.force {
			return fmt.Errorf("%s already contains an unmanaged target named %q; rerun with --force or use the manual Go setup path", filepath.Base(buildPath), cfg.uploaderTargetName)
		}
		text, err = removeNamedTarget(text, cfg.uploaderTargetName)
		if err != nil {
			return err
		}
	}

	text, err = ensureLoadStatement(text, `load("@datadog-rules-test-optimization//tools/core:test_optimization_doctor.bzl", "dd_test_optimization_doctor")`)
	if err != nil {
		return err
	}
	text, err = ensureLoadStatement(text, `load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")`)
	if err != nil {
		return err
	}

	doctorBlock := fmt.Sprintf(`%s
dd_test_optimization_doctor(
    name = "%s",
    data = ["@%s//:test_optimization_context"],
)
%s
`, doctorBlockStart, cfg.doctorTargetName, cfg.syncRepoName, doctorBlockEnd)
	text, err = replaceManagedSection(text, doctorBlockStart, doctorBlockEnd, doctorBlock)
	if err != nil {
		return err
	}

	uploaderBlock := fmt.Sprintf(`%s
dd_payload_uploader(
    name = "%s",
    data = ["@%s//:test_optimization_context"],
)
%s
`, uploaderBlockStart, cfg.uploaderTargetName, cfg.syncRepoName, uploaderBlockEnd)
	text, err = replaceManagedSection(text, uploaderBlockStart, uploaderBlockEnd, uploaderBlock)
	if err != nil {
		return err
	}

	if sameCleanPath(goModuleDirOrWorkspace(cfg), cfg.workspaceDir) {
		pinBlock := renderPinExportsBlock()
		text, err = replaceManagedSection(text, pinExportsBlockStart, pinExportsBlockEnd, pinBlock)
		if err != nil {
			return err
		}
	} else {
		text, err = removeManagedSectionIfPresent(text, pinExportsBlockStart, pinExportsBlockEnd)
		if err != nil {
			return err
		}
	}

	if err := os.WriteFile(buildPath, []byte(text), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", buildPath, err)
	}
	return nil
}

// ensureGuidedGoModuleBuild ensures the configured Go module package exports
// Orchestrion pin files.
func ensureGuidedGoModuleBuild(cfg config) error {
	if _, err := goModuleBazelPackage(cfg); err != nil {
		return err
	}
	moduleDir := goModuleDirOrWorkspace(cfg)
	buildPath, err := selectPackageFile(moduleDir)
	if err != nil {
		return err
	}
	content, err := os.ReadFile(buildPath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read %s: %w", buildPath, err)
	}
	text := string(content)

	pinBlock := renderPinExportsBlock()
	text, err = replaceManagedSection(text, pinExportsBlockStart, pinExportsBlockEnd, pinBlock)
	if err != nil {
		return err
	}

	if err := os.WriteFile(buildPath, []byte(text), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", buildPath, err)
	}
	return nil
}

func renderPinExportsBlock() string {
	var buf bytes.Buffer
	buf.WriteString(pinExportsBlockStart)
	buf.WriteString("\nexports_files([\n")
	for _, file := range orchestrionPinFiles {
		fmt.Fprintf(&buf, "    %q,\n", file)
	}
	buf.WriteString("])\n")
	buf.WriteString(pinExportsBlockEnd)
	buf.WriteString("\n")
	return buf.String()
}

func ensureGuidedWrapper(cfg config) error {
	pinLabels, err := orchestrionPinFileLabels(cfg)
	if err != nil {
		return err
	}

	wrapperDir := filepath.Join(cfg.workspaceDir, toolsBuildDir)
	if err := os.MkdirAll(wrapperDir, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", wrapperDir, err)
	}
	packagePath, err := selectPackageFile(wrapperDir)
	if err != nil {
		return err
	}
	if _, err := os.Stat(packagePath); os.IsNotExist(err) {
		if err := os.WriteFile(packagePath, []byte("# Package marker for workspace-local test wrapper macros.\n"), 0o644); err != nil {
			return fmt.Errorf("write %s: %w", packagePath, err)
		}
	} else if err != nil {
		return fmt.Errorf("stat %s: %w", packagePath, err)
	}

	wrapperPath := filepath.Join(wrapperDir, wrapperFileName)
	existing, err := os.ReadFile(wrapperPath)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read %s: %w", wrapperPath, err)
	}
	if len(existing) > 0 && (!strings.Contains(string(existing), wrapperBlockStart) || !strings.Contains(string(existing), wrapperBlockEnd)) && !cfg.force {
		return fmt.Errorf("%s already exists and is not Datadog-managed; rerun with --force or use the manual Go setup path", wrapperPath)
	}

	wrapperContent := fmt.Sprintf(`"""Datadog-managed workspace-local wrapper for Go test optimization."""

%s
load("@datadog-rules-test-optimization-go//:topt_go_test.bzl", "dd_topt_go_test")
load("@%s//:export.bzl", "topt_data")

_ORCHESTRION_PIN_FILES = [
%s
]

def dd_go_test(name, **kwargs):
    dd_topt_go_test(
        name = name,
        topt_data = topt_data,
        orchestrion_pin_files = _ORCHESTRION_PIN_FILES,
        **kwargs
    )
%s
`, wrapperBlockStart, cfg.syncRepoName, renderPinLabelLines(pinLabels), wrapperBlockEnd)
	if err := os.WriteFile(wrapperPath, []byte(wrapperContent), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", wrapperPath, err)
	}
	return nil
}

// renderPinLabelLines renders Starlark list entries for Orchestrion pin-file
// labels.
func renderPinLabelLines(labels []string) string {
	var buf bytes.Buffer
	for _, label := range labels {
		fmt.Fprintf(&buf, "    %q,\n", label)
	}
	return buf.String()
}

// orchestrionPinFileLabels returns Bazel labels for pin files in the
// configured Go module package.
func orchestrionPinFileLabels(cfg config) ([]string, error) {
	pkg, err := goModuleBazelPackage(cfg)
	if err != nil {
		return nil, err
	}
	labels := make([]string, 0, len(orchestrionPinFiles))
	for _, file := range orchestrionPinFiles {
		if pkg == "//" {
			labels = append(labels, "//:"+file)
		} else {
			labels = append(labels, pkg+":"+file)
		}
	}
	return labels, nil
}

// goModuleBazelPackage returns the Bazel package label for the configured Go
// module directory.
func goModuleBazelPackage(cfg config) (string, error) {
	moduleDir := goModuleDirOrWorkspace(cfg)
	rel, err := filepath.Rel(cfg.workspaceDir, moduleDir)
	if err != nil {
		return "", fmt.Errorf("resolve Go module package: %w", err)
	}
	rel = filepath.Clean(rel)
	if rel == "." {
		return "//", nil
	}
	if filepath.IsAbs(rel) || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("go module directory %s must be inside workspace %s", moduleDir, cfg.workspaceDir)
	}
	return "//" + filepath.ToSlash(rel), nil
}

// goModuleDirOrWorkspace returns cfg.goModuleDir, defaulting to the workspace
// root.
func goModuleDirOrWorkspace(cfg config) string {
	if cfg.goModuleDir != "" {
		return cfg.goModuleDir
	}
	return cfg.workspaceDir
}

// sameCleanPath returns whether two local paths are equal after filepath
// cleanup.
func sameCleanPath(left, right string) bool {
	return filepath.Clean(left) == filepath.Clean(right)
}

func selectPackageFile(dir string) (string, error) {
	buildBazel := filepath.Join(dir, "BUILD.bazel")
	if _, err := os.Stat(buildBazel); err == nil {
		return buildBazel, nil
	} else if err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("stat %s: %w", buildBazel, err)
	}

	build := filepath.Join(dir, "BUILD")
	if _, err := os.Stat(build); err == nil {
		return build, nil
	} else if err != nil && !os.IsNotExist(err) {
		return "", fmt.Errorf("stat %s: %w", build, err)
	}
	return buildBazel, nil
}

func ensureLoadStatement(content, loadStatement string) (string, error) {
	if strings.Contains(content, loadStatement) {
		return content, nil
	}

	lines := splitLinesPreserveNewline(content)
	insertAt := 0
	inLoad := false
	loadDepth := 0

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		switch {
		case inLoad:
			insertAt += len(line)
			loadDepth += strings.Count(line, "(")
			loadDepth -= strings.Count(line, ")")
			if loadDepth <= 0 {
				inLoad = false
			}
		case trimmed == "" || strings.HasPrefix(trimmed, "#"):
			insertAt += len(line)
		case strings.HasPrefix(trimmed, "load("):
			inLoad = true
			loadDepth = strings.Count(line, "(") - strings.Count(line, ")")
			insertAt += len(line)
			if loadDepth <= 0 {
				inLoad = false
			}
		default:
			goto insert
		}
	}

insert:
	var buf bytes.Buffer
	buf.WriteString(content[:insertAt])
	buf.WriteString(loadStatement)
	buf.WriteString("\n")
	buf.WriteString(content[insertAt:])
	return buf.String(), nil
}

func splitLinesPreserveNewline(content string) []string {
	if content == "" {
		return nil
	}
	lines := strings.SplitAfter(content, "\n")
	if !strings.HasSuffix(content, "\n") {
		return lines
	}
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		return lines[:len(lines)-1]
	}
	return lines
}

type callBlock struct {
	assign   string
	function string
	text     string
	start    int
	end      int
}

func topLevelCallBlocks(content string) []callBlock {
	lines := splitLinesPreserveNewline(content)
	startPattern := regexp.MustCompile(`^\s*(?:([A-Za-z_][A-Za-z0-9_]*)\s*=\s*)?([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)\(`)
	offset := 0
	blocks := []callBlock{}

	for i := 0; i < len(lines); i++ {
		line := lines[i]
		match := startPattern.FindStringSubmatch(line)
		if match == nil {
			offset += len(line)
			continue
		}
		start := offset
		depth := strings.Count(line, "(") - strings.Count(line, ")")
		offset += len(line)
		j := i
		for depth > 0 && j+1 < len(lines) {
			j++
			line = lines[j]
			depth += strings.Count(line, "(")
			depth -= strings.Count(line, ")")
			offset += len(line)
		}
		blocks = append(blocks, callBlock{
			assign:   match[1],
			function: match[1],
			text:     content[start:offset],
			start:    start,
			end:      offset,
		})
		if match[2] != "" {
			blocks[len(blocks)-1].function = match[2]
		}
		if match[1] == "" {
			blocks[len(blocks)-1].assign = ""
		}
		i = j
	}
	return blocks
}

type tracerConfig struct {
	shared    string
	perModule map[string]string
}

func (c tracerConfig) isSet() bool {
	return strings.TrimSpace(c.shared) != "" || len(c.perModule) > 0
}

func (cfg config) hasTracerConfig() bool {
	return strings.TrimSpace(cfg.ddTraceGoVersion) != "" || len(cfg.ddTraceGoVersions) > 0
}

func (cfg config) usesPerModuleTracerConfig() bool {
	return len(cfg.ddTraceGoVersions) > 0
}

func (cfg config) effectiveDDTraceGoVersions() map[string]string {
	if cfg.usesPerModuleTracerConfig() {
		return copyDDTraceGoVersions(cfg.ddTraceGoVersions)
	}
	versions := make(map[string]string, len(ddTraceGoModules))
	for _, modulePath := range ddTraceGoModules {
		versions[modulePath] = cfg.ddTraceGoVersion
	}
	return versions
}

func copyDDTraceGoVersions(src map[string]string) map[string]string {
	if len(src) == 0 {
		return nil
	}
	dst := make(map[string]string, len(src))
	for key, value := range src {
		dst[key] = value
	}
	return dst
}

func sharedDDTraceGoVersion(versions map[string]string) (string, bool) {
	if len(versions) == 0 {
		return "", false
	}
	shared := strings.TrimSpace(versions[ddTraceGoModules[0]])
	if shared == "" {
		return "", false
	}
	for _, modulePath := range ddTraceGoModules[1:] {
		if strings.TrimSpace(versions[modulePath]) != shared {
			return "", false
		}
	}
	return shared, true
}

func managedTracerConfig(content string) (tracerConfig, error) {
	start := strings.Index(content, managedBlockStart)
	end := strings.Index(content, managedBlockEnd)
	if start < 0 || end < 0 || end <= start {
		return tracerConfig{}, nil
	}
	return parseTracerConfigFromContent(content[start:end])
}

func ensureBootstrapCanManageTracerConfig(content string) error {
	stripped, _ := stripManagedSectionIfPresent(content, managedBlockStart, managedBlockEnd)
	configs, err := parseTracerConfigsFromContent(stripped)
	if err != nil {
		return err
	}
	if len(configs) == 0 {
		return nil
	}
	return errors.New("manual tracer configuration is already active outside the Datadog-managed block; remove or migrate that orchestrion.from_source(...) tracer config before rerunning bootstrap")
}

func hydrateManagedTracerConfig(cfg *config, content string) error {
	managed, err := managedTracerConfig(content)
	if err != nil {
		return err
	}
	if !managed.isSet() {
		return nil
	}
	cfg.ddTraceGoVersion = managed.shared
	cfg.ddTraceGoVersions = copyDDTraceGoVersions(managed.perModule)
	return nil
}

func hydrateManagedRulesGoVariant(cfg *config, content string) error {
	// Rerunning the bootstrap should preserve the variant the managed block
	// already selected. Without this, complete-variant workspaces silently
	// downgrade to the base variant unless every rerun repeats the flag.
	start := strings.Index(content, managedBlockStart)
	end := strings.Index(content, managedBlockEnd)
	if start < 0 || end < 0 || end <= start {
		return nil
	}
	stripPrefixPattern := regexp.MustCompile(`strip_prefix\s*=\s*"third_party/rules_go_orchestrion_([^"]+)"`)
	match := stripPrefixPattern.FindStringSubmatch(content[start:end])
	if len(match) != 2 {
		return nil
	}
	if err := validateRulesGoVariant(match[1]); err != nil {
		return err
	}
	cfg.rulesGoVariant = match[1]
	return nil
}

func parseTracerConfigsFromContent(content string) ([]tracerConfig, error) {
	aliases := map[string]struct{}{}
	for _, block := range topLevelCallBlocks(content) {
		if block.function != "use_extension" || block.assign == "" {
			continue
		}
		if strings.Contains(block.text, `"@rules_go//go:extensions.bzl"`) && strings.Contains(block.text, `"orchestrion"`) {
			aliases[block.assign] = struct{}{}
		}
	}
	configs := []tracerConfig{}
	for _, block := range topLevelCallBlocks(content) {
		parts := strings.Split(block.function, ".")
		if len(parts) != 2 || parts[1] != "from_source" {
			continue
		}
		if _, ok := aliases[parts[0]]; !ok {
			continue
		}
		cfg, err := parseTracerConfigFromCall(block.text)
		if err != nil {
			return nil, err
		}
		if cfg.isSet() {
			configs = append(configs, cfg)
		}
	}
	return configs, nil
}

func parseTracerConfigFromContent(content string) (tracerConfig, error) {
	configs, err := parseTracerConfigsFromContent(content)
	if err != nil {
		return tracerConfig{}, err
	}
	if len(configs) == 0 {
		return tracerConfig{}, nil
	}
	if len(configs) > 1 {
		return tracerConfig{}, errors.New("multiple active orchestrion.from_source(...) tracer configs found")
	}
	return configs[0], nil
}

func parseTracerConfigFromCall(call string) (tracerConfig, error) {
	sharedMatch := regexp.MustCompile(`(?m)^\s*dd_trace_go_version\s*=\s*"([^"]+)"`).FindStringSubmatch(call)
	perModuleMatch := regexp.MustCompile(`(?s)dd_trace_go_versions\s*=\s*\{(.*?)\}`).FindStringSubmatch(call)
	if len(sharedMatch) > 1 && len(perModuleMatch) > 1 {
		return tracerConfig{}, errors.New("dd_trace_go_version and dd_trace_go_versions cannot both be set in the same orchestrion.from_source(...) call")
	}
	if len(sharedMatch) > 1 {
		return tracerConfig{shared: sharedMatch[1]}, nil
	}
	if len(perModuleMatch) > 1 {
		perModule := map[string]string{}
		entryPattern := regexp.MustCompile(`"([^"]+)"\s*:\s*"([^"]+)"`)
		for _, match := range entryPattern.FindAllStringSubmatch(perModuleMatch[1], -1) {
			perModule[match[1]] = match[2]
		}
		return tracerConfig{perModule: perModule}, nil
	}
	return tracerConfig{}, nil
}

func hasNamedTarget(content, targetName string) bool {
	for _, block := range topLevelCallBlocks(content) {
		if block.function == "load" {
			continue
		}
		if extractBlockName(block.text) == targetName {
			return true
		}
	}
	return false
}

func removeNamedTarget(content, targetName string) (string, error) {
	blocks := topLevelCallBlocks(content)
	var removed bool
	var out strings.Builder
	last := 0
	for _, block := range blocks {
		if block.function == "load" {
			continue
		}
		if extractBlockName(block.text) != targetName {
			continue
		}
		out.WriteString(content[last:block.start])
		last = block.end
		removed = true
	}
	if !removed {
		return content, nil
	}
	out.WriteString(content[last:])
	return out.String(), nil
}

func extractBlockName(block string) string {
	pattern := regexp.MustCompile(`(?m)^\s*name\s*=\s*"([^"]+)"`)
	match := pattern.FindStringSubmatch(block)
	if len(match) != 2 {
		return ""
	}
	return match[1]
}

// writeOrchestrionToolFile writes the managed tools-tagged Orchestrion entrypoint
// that the bootstrap flow keeps aligned with the Bazel-side Orchestrion wiring.
// The helper writes this file directly instead of depending on `orchestrion pin`
// so bootstrap stays deterministic even when upstream pin behavior changes.
func writeOrchestrionToolFile(cfg config) error {
	path := filepath.Join(cfg.goModuleDir, "orchestrion.tool.go")
	if err := os.WriteFile(path, []byte(managedOrchestrionToolFileSource()), 0o644); err != nil {
		return fmt.Errorf("write orchestrion.tool.go: %w", err)
	}
	return nil
}

// managedOrchestrionToolFileSource returns the canonical bootstrap-owned
// Orchestrion tools file. The import set matches the Orchestrion module-proxy
// seed so bootstrap and Bazel action-time module resolution stay aligned.
func managedOrchestrionToolFileSource() string {
	return `//go:build tools

package tools

import (
	_ "github.com/DataDog/orchestrion" // integration
	_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration
	_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
	_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration
)
`
}

func syncDDTraceGoVersion(cfg config) error {
	for _, args := range bootstrapSyncCommands(cfg) {
		cmd := exec.Command("go", args...)
		cmd.Dir = cfg.goModuleDir
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		cmd.Env = orchestrionBootstrapEnv()
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("run `go %s` in %s: %w", strings.Join(args, " "), cfg.goModuleDir, err)
		}
	}
	return nil
}

// bootstrapSyncCommands returns the exact go command sequence bootstrap uses to
// pin the workspace module graph. The Orchestrion module itself is pinned here
// so the generated tools file cannot drift to a newer upstream release during
// `go mod tidy`.
func bootstrapSyncCommands(cfg config) [][]string {
	commands := make([][]string, 0, len(ddTraceGoModules)+3)
	versions := cfg.effectiveDDTraceGoVersions()
	commands = append(commands, []string{"mod", "edit", "-require=github.com/DataDog/orchestrion@" + cfg.orchestrionVersion})
	for _, modulePath := range ddTraceGoModules {
		commands = append(commands, []string{"mod", "edit", "-require=" + modulePath + "@" + versions[modulePath]})
	}
	commands = append(commands,
		[]string{"get", "github.com/DataDog/dd-trace-go/v2/orchestrion@" + versions["github.com/DataDog/dd-trace-go/v2"]},
		[]string{"mod", "tidy"},
	)
	return commands
}

func normalizeDDTraceGoVersion(cfg *config) error {
	resolvedVersions, err := resolveDDTraceGoVersionQuery(cfg.ddTraceGoVersion, "go", orchestrionBootstrapEnv())
	if err != nil {
		return err
	}
	if shared, ok := sharedDDTraceGoVersion(resolvedVersions); ok {
		cfg.ddTraceGoVersion = shared
		cfg.ddTraceGoVersions = nil
		return nil
	}
	cfg.ddTraceGoVersion = ""
	cfg.ddTraceGoVersions = copyDDTraceGoVersions(resolvedVersions)
	return nil
}

func ensureCIVisibilityOrchestrionImport(cfg config) error {
	path := filepath.Join(cfg.goModuleDir, "orchestrion.tool.go")
	content, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read orchestrion.tool.go: %w", err)
	}
	text := string(content)

	const (
		legacyCIVisibilityImport     = `_ "gopkg.in/DataDog/dd-trace-go.v1/civisibility" // integration`
		legacyCIVisibilityImportBare = `_ "gopkg.in/DataDog/dd-trace-go.v1/civisibility"`
		v2OrchestrionImport          = `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`
		v2OrchestrionImportBare      = `_ "github.com/DataDog/dd-trace-go/v2/orchestrion"`
		v2NetHTTPImport              = `_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration`
		v2NetHTTPImportBare          = `_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2"`
		v2SlogImport                 = `_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration`
		v2SlogImportBare             = `_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2"`
		v2AllImport                  = `_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2" // integration`
		v2AllImportBare              = `_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2"`
		v2GotestingImport            = `_ "github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting" // integration`
		v2GotestingImportBare        = `_ "github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting"`
	)

	updated := strings.ReplaceAll(text, legacyCIVisibilityImport+"\n", "")
	updated = strings.ReplaceAll(updated, legacyCIVisibilityImport, "")
	updated = strings.ReplaceAll(updated, legacyCIVisibilityImportBare+"\n", "")
	updated = strings.ReplaceAll(updated, legacyCIVisibilityImportBare, "")
	updated = strings.ReplaceAll(updated, v2OrchestrionImport+"\n", "")
	updated = strings.ReplaceAll(updated, v2OrchestrionImport, "")
	updated = strings.ReplaceAll(updated, v2OrchestrionImportBare+"\n", "")
	updated = strings.ReplaceAll(updated, v2OrchestrionImportBare, "")
	updated = strings.ReplaceAll(updated, v2NetHTTPImport+"\n", "")
	updated = strings.ReplaceAll(updated, v2NetHTTPImport, "")
	updated = strings.ReplaceAll(updated, v2NetHTTPImportBare+"\n", "")
	updated = strings.ReplaceAll(updated, v2NetHTTPImportBare, "")
	updated = strings.ReplaceAll(updated, v2SlogImport+"\n", "")
	updated = strings.ReplaceAll(updated, v2SlogImport, "")
	updated = strings.ReplaceAll(updated, v2SlogImportBare+"\n", "")
	updated = strings.ReplaceAll(updated, v2SlogImportBare, "")
	updated = strings.ReplaceAll(updated, v2AllImport+"\n", "")
	updated = strings.ReplaceAll(updated, v2AllImport, "")
	updated = strings.ReplaceAll(updated, v2AllImportBare+"\n", "")
	updated = strings.ReplaceAll(updated, v2AllImportBare, "")
	updated = strings.ReplaceAll(updated, v2GotestingImport+"\n", "")
	updated = strings.ReplaceAll(updated, v2GotestingImport, "")
	updated = strings.ReplaceAll(updated, v2GotestingImportBare+"\n", "")
	updated = strings.ReplaceAll(updated, v2GotestingImportBare, "")
	updated = strings.ReplaceAll(updated, "\n\n\n", "\n\n")

	requiredImports := []string{
		v2OrchestrionImport,
		v2NetHTTPImport,
		v2SlogImport,
	}

	baseOrchestrionPattern := `(?m)^(\s*_\s*"github\.com/DataDog/orchestrion"(?:\s*//.*)?\s*)$`
	if re := regexp.MustCompile(baseOrchestrionPattern); re.MatchString(updated) {
		updated = re.ReplaceAllString(updated, `${1}`+"\n\t"+strings.Join(requiredImports, "\n\t"))
	} else if strings.Contains(updated, ")\n") {
		updated = strings.Replace(updated, ")\n", "\t"+strings.Join(requiredImports, "\n\t")+"\n)\n", 1)
	} else {
		return fmt.Errorf("patch orchestrion.tool.go: could not locate import block")
	}

	if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
		return fmt.Errorf("write orchestrion.tool.go: %w", err)
	}
	return nil
}

func warmOrchestrionModuleCache(cfg config) error {
	commands := make([][]string, 0, len(ddTraceGoModules)+len(ddTraceGoWarmPackages))
	versions := cfg.effectiveDDTraceGoVersions()
	for _, modulePath := range ddTraceGoModules {
		commands = append(commands, []string{"mod", "download", modulePath + "@" + versions[modulePath]})
	}
	for _, packagePath := range ddTraceGoWarmPackages {
		commands = append(commands, []string{"list", "-mod=mod", packagePath})
	}

	for _, args := range commands {
		cmd := exec.Command("go", args...)
		cmd.Dir = cfg.goModuleDir
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		cmd.Env = orchestrionBootstrapEnv()
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("run `go %s` in %s: %w", strings.Join(args, " "), cfg.goModuleDir, err)
		}
	}

	return nil
}

type goListModule struct {
	Version string `json:"Version"`
	Replace *struct {
		Version string `json:"Version"`
		Path    string `json:"Path"`
	} `json:"Replace"`
}

func verifyResolvedBootstrapModuleVersions(cfg config) error {
	orchestrionVersion, err := resolvedModuleVersion(cfg.goModuleDir, orchestrionBootstrapEnv(), "github.com/DataDog/orchestrion")
	if err != nil {
		return err
	}
	if orchestrionVersion != cfg.orchestrionVersion {
		return fmt.Errorf("resolved orchestrion version mismatch in %s: configured %s, resolved %s", cfg.goModuleDir, cfg.orchestrionVersion, orchestrionVersion)
	}

	expected := cfg.effectiveDDTraceGoVersions()
	for _, modulePath := range ddTraceGoModules {
		resolved, err := resolvedModuleVersion(cfg.goModuleDir, orchestrionBootstrapEnv(), modulePath)
		if err != nil {
			return err
		}
		if resolved != expected[modulePath] {
			return fmt.Errorf("resolved dd-trace-go version mismatch in %s for %s: configured %s, resolved %s", cfg.goModuleDir, modulePath, expected[modulePath], resolved)
		}
	}
	return nil
}

func resolveDDTraceGoVersionQuery(query, goExe string, env []string) (map[string]string, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, errors.New("dd-trace-go version query cannot be empty")
	}

	neutralModuleDir, err := os.MkdirTemp("", "dd-trace-go-version-check-")
	if err != nil {
		return nil, fmt.Errorf("create temporary module for dd-trace-go version resolution: %w", err)
	}
	defer os.RemoveAll(neutralModuleDir)

	if err := os.WriteFile(filepath.Join(neutralModuleDir, "go.mod"), []byte("module ddtraceversioncheck\n\ngo 1.21\n"), 0o644); err != nil {
		return nil, fmt.Errorf("write temporary go.mod for dd-trace-go version resolution: %w", err)
	}

	resolvedVersions := make(map[string]string, len(ddTraceGoModules))
	for _, modulePath := range ddTraceGoModules {
		resolvedVersion, err := resolveModuleVersionFromQuery(goExe, neutralModuleDir, env, modulePath, query)
		if err != nil {
			return nil, err
		}
		resolvedVersions[modulePath] = resolvedVersion
	}

	if err := os.WriteFile(filepath.Join(neutralModuleDir, "go.mod"), []byte(syntheticDDTraceGoVersionCheckMod(resolvedVersions)), 0o644); err != nil {
		return nil, fmt.Errorf("write temporary go.mod for dd-trace-go package validation: %w", err)
	}
	for _, packagePath := range ddTraceGoValidationPackages {
		if err := verifyPackageAvailable(goExe, neutralModuleDir, env, packagePath); err != nil {
			return nil, fmt.Errorf("dd-trace-go query %q package validation failed for %s: %w", query, packagePath, err)
		}
	}

	return resolvedVersions, nil
}

func resolveModuleVersionFromQuery(goExe, moduleDir string, env []string, modulePath, query string) (string, error) {
	cmd := exec.Command(goExe, "list", "-m", "-json", modulePath+"@"+query)
	cmd.Dir = moduleDir
	cmd.Env = normalizedGoEnv(env)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("resolve dd-trace-go query %q for %s: %w: %s", query, modulePath, err, strings.TrimSpace(string(output)))
	}
	var module goListModule
	if err := json.Unmarshal(output, &module); err != nil {
		return "", fmt.Errorf("parse resolved dd-trace-go query %q for %s: %w", query, modulePath, err)
	}
	if strings.TrimSpace(module.Version) == "" {
		return "", fmt.Errorf("resolve dd-trace-go query %q for %s: empty resolved version", query, modulePath)
	}
	return strings.TrimSpace(module.Version), nil
}

func resolvedModuleVersion(moduleDir string, env []string, modulePath string) (string, error) {
	cmd := exec.Command("go", "list", "-mod=mod", "-m", "-json", modulePath)
	cmd.Dir = moduleDir
	cmd.Env = normalizedGoEnv(env)
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("resolve %s version in %s: %w", modulePath, moduleDir, err)
	}
	var module goListModule
	if err := json.Unmarshal(output, &module); err != nil {
		return "", fmt.Errorf("parse %s version in %s: %w", modulePath, moduleDir, err)
	}
	if module.Replace != nil {
		if strings.TrimSpace(module.Replace.Version) == "" {
			return "", fmt.Errorf("resolve %s version in %s: local replace targets are not supported for bootstrap verification", modulePath, moduleDir)
		}
		return module.Replace.Version, nil
	}
	if strings.TrimSpace(module.Version) == "" {
		return "", fmt.Errorf("resolve %s version in %s: empty module version", modulePath, moduleDir)
	}
	return module.Version, nil
}

func verifyPackageAvailable(goExe, moduleDir string, env []string, packagePath string) error {
	cmd := exec.Command(goExe, "list", "-mod=mod", packagePath)
	cmd.Dir = moduleDir
	cmd.Env = normalizedGoEnv(env)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("resolve %s in %s: %w: %s", packagePath, moduleDir, err, strings.TrimSpace(string(output)))
	}
	return nil
}

func syntheticDDTraceGoVersionCheckMod(versions map[string]string) string {
	var buf strings.Builder
	buf.WriteString("module ddtraceversioncheck\n\n")
	buf.WriteString("go 1.21\n\n")
	buf.WriteString("require (\n")
	for _, modulePath := range ddTraceGoModules {
		buf.WriteString("\t")
		buf.WriteString(modulePath)
		buf.WriteString(" ")
		buf.WriteString(versions[modulePath])
		buf.WriteString("\n")
	}
	buf.WriteString(")\n")
	return buf.String()
}

func normalizedGoEnv(env []string) []string {
	normalized := append([]string{}, env...)
	normalized = setEnvValue(normalized, "GO111MODULE", "on")
	normalized = setEnvValue(normalized, "GOWORK", "off")
	if strings.TrimSpace(envValue(normalized, "GOPROXY")) == "" {
		normalized = setEnvValue(normalized, "GOPROXY", "https://proxy.golang.org,direct")
	}
	if strings.TrimSpace(envValue(normalized, "GOSUMDB")) == "" {
		normalized = setEnvValue(normalized, "GOSUMDB", "sum.golang.org")
	}
	return normalized
}

func setEnvValue(env []string, key, value string) []string {
	prefix := key + "="
	replaced := false
	for idx, entry := range env {
		if strings.HasPrefix(entry, prefix) {
			env[idx] = prefix + value
			replaced = true
		}
	}
	if !replaced {
		env = append(env, prefix+value)
	}
	return env
}

func envValue(env []string, key string) string {
	prefix := key + "="
	for _, entry := range env {
		if strings.HasPrefix(entry, prefix) {
			return strings.TrimPrefix(entry, prefix)
		}
	}
	return ""
}

func orchestrionBootstrapEnv() []string {
	env := append([]string{}, os.Environ()...)
	cacheRoot := filepath.Join(os.TempDir(), sharedOrchestrionCacheDirName)
	goModCache := filepath.Join(cacheRoot, "pkg", "mod")
	goBuildCache := filepath.Join(cacheRoot, "cache")

	env = append(env,
		"GO111MODULE=on",
		"GOWORK=off",
		"GOPATH="+cacheRoot,
		"GOMODCACHE="+goModCache,
		"GOCACHE="+goBuildCache,
		"GOPROXY=https://proxy.golang.org,direct",
		"GOSUMDB=sum.golang.org",
	)
	return normalizedGoEnv(env)
}

func writeStarterOrchestrionYML(cfg config) error {
	path := filepath.Join(cfg.goModuleDir, "orchestrion.yml")
	if _, err := os.Stat(path); err == nil && !cfg.force {
		return nil
	} else if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("stat orchestrion.yml: %w", err)
	}
	if err := os.WriteFile(path, []byte(defaultStarterOrchestrionYML), 0o644); err != nil {
		return fmt.Errorf("write orchestrion.yml: %w", err)
	}
	return nil
}

func maybeChangedStarterYML(goModuleDir string) string {
	if _, err := os.Stat(filepath.Join(goModuleDir, "orchestrion.yml")); err == nil {
		return ", orchestrion.yml"
	}
	return ""
}
