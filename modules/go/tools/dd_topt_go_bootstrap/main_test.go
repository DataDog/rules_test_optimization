package main

import (
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// captureStdout runs fn while collecting stdout into buf.
func captureStdout(buf *strings.Builder, fn func() error) error {
	original := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		return err
	}
	os.Stdout = writer
	runErr := fn()
	closeErr := writer.Close()
	os.Stdout = original
	_, copyErr := io.Copy(buf, reader)
	reader.Close()
	if runErr != nil {
		return runErr
	}
	if closeErr != nil {
		return closeErr
	}
	return copyErr
}

func TestInsertAfterModuleDecl(t *testing.T) {
	input := "module(name = \"example\")\n"
	got, err := insertAfterModuleDecl(input, "bazel_dep(name = \"rules_go\", version = \"0.60.0\")\n")
	if err != nil {
		t.Fatalf("insertAfterModuleDecl error: %v", err)
	}
	if !strings.Contains(got, "bazel_dep(name = \"rules_go\", version = \"0.60.0\")") {
		t.Fatalf("expected rules_go bazel_dep in output:\n%s", got)
	}
}

func TestReplaceManagedSectionAppendsWhenMissing(t *testing.T) {
	input := "module(name = \"example\")\n"
	got, err := replaceManagedSection(input, managedBlockStart, managedBlockEnd, managedBlockStart+"\nfoo\n"+managedBlockEnd+"\n")
	if err != nil {
		t.Fatalf("replaceManagedSection error: %v", err)
	}
	if !strings.Contains(got, managedBlockStart) || !strings.Contains(got, "foo") {
		t.Fatalf("expected managed block in output:\n%s", got)
	}
}

func TestManagedModuleBlockIncludesRulesGoExtension(t *testing.T) {
	cfg := config{
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersion:   "v2.5.0",
		rulesGoRemote:      "https://github.com/example/repo.git",
		rulesGoCommit:      "deadbeef",
	}
	got := managedModuleBlock(cfg)
	if !strings.Contains(got, `git_override(`) {
		t.Fatalf("expected rules_go override in managed block:\n%s", got)
	}
	if !strings.Contains(got, `strip_prefix = "third_party/rules_go_orchestrion_base"`) {
		t.Fatalf("expected vendored rules_go strip_prefix in managed block:\n%s", got)
	}
	if !strings.Contains(got, `use_extension("@rules_go//go:extensions.bzl", "orchestrion")`) {
		t.Fatalf("expected rules_go orchestrion extension in managed block:\n%s", got)
	}
	if !strings.Contains(got, `orchestrion.from_source(`) {
		t.Fatalf("expected orchestrion extension call in managed block:\n%s", got)
	}
	if !strings.Contains(got, `version = "v1.9.0"`) {
		t.Fatalf("expected orchestrion version in managed block:\n%s", got)
	}
	if !strings.Contains(got, `dd_trace_go_version = "v2.5.0"`) {
		t.Fatalf("expected dd-trace-go version in managed block:\n%s", got)
	}
	if !strings.Contains(got, `use_repo(orchestrion, "rules_go_orchestrion_tool")`) {
		t.Fatalf("expected rules_go orchestrion repo wiring in managed block:\n%s", got)
	}
}

func TestManagedModuleBlockCanSelectCompleteRulesGoVariant(t *testing.T) {
	cfg := config{
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersion:   "v2.5.0",
		rulesGoRemote:      "https://github.com/example/repo.git",
		rulesGoCommit:      "deadbeef",
		rulesGoVariant:     "complete",
	}
	got := managedModuleBlock(cfg)
	if !strings.Contains(got, `strip_prefix = "third_party/rules_go_orchestrion_complete"`) {
		t.Fatalf("expected complete rules_go variant in managed block:\n%s", got)
	}
}

func TestValidateRulesGoVariantRejectsUnknownVariant(t *testing.T) {
	if err := validateRulesGoVariant("custom"); err == nil {
		t.Fatal("expected unknown rules_go variant to fail")
	}
}

func TestWorkspaceSnippetSupportsMixedFetchModes(t *testing.T) {
	cfg := config{
		rulesGoRemote:      "https://github.com/example/repo.git",
		rtoCommit:          "published-sha",
		datadogFetch:       "git",
		rulesGoFetch:       "archive",
		rulesGoRepoName:    "io_bazel_rules_go",
		rulesGoVariant:     "complete",
		rtoArchiveURL:      "https://example.test/archive.tar.gz",
		rtoArchiveSHA256:   strings.Repeat("0", 64),
		rtoArchivePrefix:   "rules_test_optimization-published-sha",
		rtoArchiveType:     "tar.gz",
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersion:   "v2.9.0-dev.0.20260416093245-194346a71c51",
	}
	got, err := workspaceSnippet(cfg)
	if err != nil {
		t.Fatalf("workspaceSnippet error: %v", err)
	}
	for _, want := range []string{
		`git_repository(`,
		`name = "datadog-rules-test-optimization"`,
		`load("@datadog-rules-test-optimization//tools/go:workspace_repositories.bzl", "datadog_go_test_optimization_workspace_repositories")`,
		`datadog_fetch = "git"`,
		`rto_commit = "published-sha"`,
		`rules_go_fetch = "archive"`,
		`rules_go_variant = "complete"`,
		`go_orchestrion_tool_repo(`,
		`dd_trace_go_version = "v2.9.0-dev.0.20260416093245-194346a71c51"`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("workspace snippet missing %q:\n%s", want, got)
		}
	}
}

func TestWorkspaceSnippetFallsBackToRulesGoCommit(t *testing.T) {
	cfg := config{
		rulesGoRemote:      "https://github.com/example/repo.git",
		rulesGoCommit:      "legacy-published-sha",
		datadogFetch:       "git",
		rulesGoFetch:       "git",
		rulesGoRepoName:    "io_bazel_rules_go",
		rulesGoVariant:     "base",
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersion:   "v2.9.0-dev.0.20260416093245-194346a71c51",
	}
	got, err := workspaceSnippet(cfg)
	if err != nil {
		t.Fatalf("workspaceSnippet error: %v", err)
	}
	if !strings.Contains(got, `rto_commit = "legacy-published-sha"`) {
		t.Fatalf("workspace snippet did not fall back to rulesGoCommit:\n%s", got)
	}
}

func TestWorkspaceSnippetDoesNotRequireModuleFiles(t *testing.T) {
	cfg := config{
		rulesGoRemote:      "https://github.com/example/repo.git",
		rtoCommit:          "published-sha",
		datadogFetch:       "git",
		rulesGoFetch:       "git",
		rulesGoRepoName:    "io_bazel_rules_go",
		rulesGoVariant:     "base",
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersion:   "v2.9.0-dev.0.20260416093245-194346a71c51",
	}
	if _, err := workspaceSnippet(cfg); err != nil {
		t.Fatalf("workspaceSnippet should not inspect MODULE.bazel or go.mod: %v", err)
	}
}

func TestBazelrcSnippetUsesRepoEnvOnlyForSyncMetadata(t *testing.T) {
	got, err := bazelrcSnippet(config{bazelrcConfig: "test-optimization"})
	if err != nil {
		t.Fatalf("bazelrcSnippet error: %v", err)
	}
	for _, want := range []string{
		bazelrcBlockStart,
		`common:test-optimization --repo_env=DD_API_KEY`,
		`common:test-optimization --repo_env=FETCH_SALT`,
		`common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL`,
		`common:test-optimization --repo_env=DD_GIT_REPOSITORY_URL`,
		`common:test-optimization --repo_env=DD_PR_NUMBER`,
		`test:test-optimization --remote_download_outputs=all`,
		bazelrcBlockEnd,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("bazelrc snippet missing %q:\n%s", want, got)
		}
	}
	for _, key := range bazelrcRepoEnvKeys {
		want := "common:test-optimization --repo_env=" + key
		if !strings.Contains(got, want) {
			t.Fatalf("bazelrc snippet missing %q:\n%s", want, got)
		}
	}
	for _, forbidden := range []string{
		`--test_env=DD_GIT_`,
		`--test_env=DD_TEST_OPTIMIZATION_AGENT_URL`,
		`--test_env=DD_TEST_OPTIMIZATION_AGENTLESS_URL`,
	} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("bazelrc snippet contains forbidden test env %q:\n%s", forbidden, got)
		}
	}
}

func TestRunPrintBazelrcSnippetDoesNotRequireModuleFiles(t *testing.T) {
	dir := t.TempDir()
	var buf strings.Builder
	if err := captureStdout(&buf, func() error {
		return run(config{
			workspaceDir:        dir,
			printBazelrcSnippet: true,
			bazelrcConfig:       "test-optimization",
			datadogFetch:        defaultDatadogFetch,
			rulesGoFetch:        defaultRulesGoFetch,
			rulesGoVariant:      defaultRulesGoVariant,
			ddTraceGoVersion:    defaultDDTraceGoVersion,
			orchestrionVersion:  defaultOrchestrionVersion,
			rulesGoRepoName:     defaultRulesGoRepoName,
			rulesGoRemote:       defaultRulesGoRemote,
			syncRepoName:        defaultSyncRepoName,
			doctorTargetName:    defaultDoctorTargetName,
			uploaderTargetName:  defaultUploaderTargetName,
		})
	}); err != nil {
		t.Fatalf("run --print-bazelrc-snippet error: %v", err)
	}
	if got := buf.String(); !strings.Contains(got, `test:test-optimization --remote_download_outputs=all`) {
		t.Fatalf("expected bazelrc snippet on stdout:\n%s", got)
	}
}

func TestWriteBazelrcBlockPreservesUserContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".bazelrc")
	if err := os.WriteFile(path, []byte("common --announce_rc\n"), 0o644); err != nil {
		t.Fatalf("write .bazelrc: %v", err)
	}
	cfg := config{
		workspaceDir:  dir,
		bazelrcPath:   ".bazelrc",
		bazelrcConfig: "test-optimization",
	}
	if err := writeBazelrcBlock(cfg); err != nil {
		t.Fatalf("writeBazelrcBlock error: %v", err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read .bazelrc: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, "common --announce_rc") || !strings.Contains(text, bazelrcBlockStart) {
		t.Fatalf("expected user content and managed block in .bazelrc:\n%s", text)
	}
}

func TestWriteBazelrcBlockIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		workspaceDir:  dir,
		bazelrcPath:   ".bazelrc",
		bazelrcConfig: "test-optimization",
	}
	if err := writeBazelrcBlock(cfg); err != nil {
		t.Fatalf("first writeBazelrcBlock error: %v", err)
	}
	first, err := os.ReadFile(filepath.Join(dir, ".bazelrc"))
	if err != nil {
		t.Fatalf("read first .bazelrc: %v", err)
	}
	if err := writeBazelrcBlock(cfg); err != nil {
		t.Fatalf("second writeBazelrcBlock error: %v", err)
	}
	second, err := os.ReadFile(filepath.Join(dir, ".bazelrc"))
	if err != nil {
		t.Fatalf("read second .bazelrc: %v", err)
	}
	if string(first) != string(second) {
		t.Fatalf("expected idempotent .bazelrc write:\nfirst:\n%s\nsecond:\n%s", first, second)
	}
}

func TestWriteBazelrcBlockReplacesManagedContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".bazelrc")
	input := `common --announce_rc
# BEGIN Datadog Test Optimization Bazelrc
test:old --test_env=DD_GIT_BRANCH=main
# END Datadog Test Optimization Bazelrc
`
	if err := os.WriteFile(path, []byte(input), 0o644); err != nil {
		t.Fatalf("write .bazelrc: %v", err)
	}
	cfg := config{
		workspaceDir:  dir,
		bazelrcPath:   ".bazelrc",
		bazelrcConfig: "test-optimization",
	}
	if err := writeBazelrcBlock(cfg); err != nil {
		t.Fatalf("writeBazelrcBlock error: %v", err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read .bazelrc: %v", err)
	}
	text := string(content)
	if strings.Contains(text, "--test_env=DD_GIT_BRANCH") || strings.Count(text, bazelrcBlockStart) != 1 {
		t.Fatalf("expected old managed block to be replaced:\n%s", text)
	}
}

func TestHydrateManagedRulesGoVariantPreservesCompleteVariant(t *testing.T) {
	content := `module(name = "example")

# BEGIN Datadog Go Orchestrion bootstrap
git_override(
    module_name = "rules_go",
    remote = "https://github.com/example/repo.git",
    commit = "deadbeef",
    strip_prefix = "third_party/rules_go_orchestrion_complete",
)
# END Datadog Go Orchestrion bootstrap
`
	cfg := config{rulesGoVariant: defaultRulesGoVariant}
	if err := hydrateManagedRulesGoVariant(&cfg, content); err != nil {
		t.Fatalf("hydrateManagedRulesGoVariant error: %v", err)
	}
	if cfg.rulesGoVariant != "complete" {
		t.Fatalf("rulesGoVariant=%q, want complete", cfg.rulesGoVariant)
	}
}

func TestManagedModuleBlockIncludesPerModuleVersions(t *testing.T) {
	cfg := config{
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersions: map[string]string{
			"github.com/DataDog/dd-trace-go/v2":                  "v2.7.0-rc.4",
			"github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.8.0-dev.0.20260316165907-0cdd3b7576b7",
			"github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.8.0-dev.0.20260316165907-0cdd3b7576b7",
		},
		rulesGoRemote: "https://github.com/example/repo.git",
		rulesGoCommit: "deadbeef",
	}
	got := managedModuleBlock(cfg)
	if !strings.Contains(got, `dd_trace_go_versions = {`) {
		t.Fatalf("expected per-module dd-trace-go versions in managed block:\n%s", got)
	}
	if !strings.Contains(got, `"github.com/DataDog/dd-trace-go/v2": "v2.7.0-rc.4"`) {
		t.Fatalf("expected root tracer version in managed block:\n%s", got)
	}
	if strings.Contains(got, `dd_trace_go_version =`) {
		t.Fatalf("expected shared dd_trace_go_version to be omitted in per-module mode:\n%s", got)
	}
}

func TestReplaceManagedBlockRejectsConflictingOverride(t *testing.T) {
	input := `module(name = "example")
git_override(
    module_name = "rules_go",
    remote = "https://example.com/custom.git",
    commit = "deadbeef",
)
`
	cfg := config{
		rulesGoRemote: defaultRulesGoRemote,
		rulesGoCommit: "deadbeef",
	}
	if rulesGoOverrideCompatible(input, cfg) {
		t.Fatal("expected incompatible rules_go override to be rejected")
	}
}

func TestInferDatadogRepoOverride(t *testing.T) {
	input := `module(name = "example")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "cafebabe",
    strip_prefix = "modules/go",
)
`
	remote, commit := inferDatadogRepoOverride(input)
	if remote != "https://github.com/DataDog/rules_test_optimization.git" {
		t.Fatalf("unexpected remote: %q", remote)
	}
	if commit != "cafebabe" {
		t.Fatalf("unexpected commit: %q", commit)
	}
}

func TestPatchModuleFileInfersRulesGoCommitFromDatadogOverride(t *testing.T) {
	dir := t.TempDir()
	moduleFile := filepath.Join(dir, "MODULE.bazel")
	input := `module(name = "example")

bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
git_override(
    module_name = "datadog-rules-test-optimization-go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "published-main-sha",
    strip_prefix = "modules/go",
)
`
	if err := os.WriteFile(moduleFile, []byte(input), 0o644); err != nil {
		t.Fatalf("write MODULE.bazel: %v", err)
	}

	cfg := config{
		moduleFile:          moduleFile,
		orchestrionVersion:  "v1.9.0",
		ddTraceGoVersion:    "v2.9.0-dev.0.20260416093245-194346a71c51",
		rulesGoRemote:       defaultRulesGoRemote,
		rulesGoVariant:      defaultRulesGoVariant,
		rulesGoCommitSet:    false,
		ddTraceGoVersionSet: true,
	}
	if err := patchModuleFile(cfg); err != nil {
		t.Fatalf("patchModuleFile error: %v", err)
	}

	content, err := os.ReadFile(moduleFile)
	if err != nil {
		t.Fatalf("read MODULE.bazel: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, `commit = "published-main-sha"`) {
		t.Fatalf("expected inferred rules_go commit in managed block:\n%s", text)
	}
	if !strings.Contains(text, `strip_prefix = "third_party/rules_go_orchestrion_base"`) {
		t.Fatalf("expected base variant strip_prefix in managed block:\n%s", text)
	}
}

func TestPatchModuleFilePreservesManagedRulesGoCommitOnRerun(t *testing.T) {
	dir := t.TempDir()
	moduleFile := filepath.Join(dir, "MODULE.bazel")
	input := `module(name = "example")

# BEGIN Datadog Go Orchestrion bootstrap
git_override(
    module_name = "rules_go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "already-published-sha",
    strip_prefix = "third_party/rules_go_orchestrion_complete",
)

orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = "v1.9.0",
    dd_trace_go_version = "v2.9.0-dev.0.20260416093245-194346a71c51",
)
use_repo(orchestrion, "rules_go_orchestrion_tool")
# END Datadog Go Orchestrion bootstrap
`
	if err := os.WriteFile(moduleFile, []byte(input), 0o644); err != nil {
		t.Fatalf("write MODULE.bazel: %v", err)
	}

	cfg := config{
		moduleFile:          moduleFile,
		orchestrionVersion:  "v1.9.0",
		ddTraceGoVersion:    "v2.9.0-dev.0.20260416093245-194346a71c51",
		rulesGoRemote:       defaultRulesGoRemote,
		rulesGoVariant:      "complete",
		ddTraceGoVersionSet: true,
	}
	if err := patchModuleFile(cfg); err != nil {
		t.Fatalf("patchModuleFile error: %v", err)
	}

	content, err := os.ReadFile(moduleFile)
	if err != nil {
		t.Fatalf("read MODULE.bazel: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, `commit = "already-published-sha"`) {
		t.Fatalf("expected existing managed rules_go commit to be preserved:\n%s", text)
	}
	if !strings.Contains(text, `strip_prefix = "third_party/rules_go_orchestrion_complete"`) {
		t.Fatalf("expected existing complete variant to be preserved:\n%s", text)
	}
}

func TestPatchModuleFileRequiresRulesGoCommitWhenNoPublishedSourceExists(t *testing.T) {
	dir := t.TempDir()
	moduleFile := filepath.Join(dir, "MODULE.bazel")
	if err := os.WriteFile(moduleFile, []byte("module(name = \"example\")\n"), 0o644); err != nil {
		t.Fatalf("write MODULE.bazel: %v", err)
	}

	cfg := config{
		moduleFile:          moduleFile,
		orchestrionVersion:  "v1.9.0",
		ddTraceGoVersion:    "v2.9.0-dev.0.20260416093245-194346a71c51",
		rulesGoRemote:       defaultRulesGoRemote,
		rulesGoVariant:      defaultRulesGoVariant,
		ddTraceGoVersionSet: true,
	}
	err := patchModuleFile(cfg)
	if err == nil {
		t.Fatal("expected patchModuleFile to require a rules_go commit")
	}
	if !strings.Contains(err.Error(), "rules_go fork commit is required") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestReadGoModulePath(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "go.mod")
	if err := os.WriteFile(path, []byte("// comment\nmodule example.com/service // production module\n\ngo 1.24\n"), 0o644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}

	got, err := readGoModulePath(path)
	if err != nil {
		t.Fatalf("readGoModulePath error: %v", err)
	}
	if got != "example.com/service" {
		t.Fatalf("readGoModulePath=%q, want example.com/service", got)
	}
}

func TestManagedGuidedModuleBlockIncludesModulePath(t *testing.T) {
	cfg := config{
		syncRepoName:   "test_optimization_data",
		service:        "go-service",
		runtimeVersion: "1.25.0",
		goModulePath:   "github.com/DataDog/example-service",
	}

	got := managedGuidedModuleBlock(cfg)
	if !strings.Contains(got, `module_path = "github.com/DataDog/example-service"`) {
		t.Fatalf("expected guided block to include explicit module_path:\n%s", got)
	}
}

func TestWriteStarterOrchestrionYML(t *testing.T) {
	dir := t.TempDir()
	cfg := config{goModuleDir: dir}
	if err := writeStarterOrchestrionYML(cfg); err != nil {
		t.Fatalf("writeStarterOrchestrionYML error: %v", err)
	}
	path := filepath.Join(dir, "orchestrion.yml")
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read orchestrion.yml: %v", err)
	}
	if !strings.Contains(string(content), "aspects: []") {
		t.Fatalf("unexpected orchestrion.yml content:\n%s", string(content))
	}
}

func TestWriteOrchestrionToolFileWritesManagedImports(t *testing.T) {
	dir := t.TempDir()
	cfg := config{goModuleDir: dir}
	if err := writeOrchestrionToolFile(cfg); err != nil {
		t.Fatalf("writeOrchestrionToolFile error: %v", err)
	}

	content, err := os.ReadFile(filepath.Join(dir, "orchestrion.tool.go"))
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(content)
	requiredImports := []string{
		`_ "github.com/DataDog/orchestrion" // integration`,
		`_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration`,
		`_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration`,
		`_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`,
	}
	for _, importLine := range requiredImports {
		if !strings.Contains(text, importLine) {
			t.Fatalf("managed orchestrion.tool.go missing %q:\n%s", importLine, text)
		}
	}
	if strings.Contains(text, `github.com/DataDog/dd-trace-go/orchestrion/all/v2`) {
		t.Fatalf("managed orchestrion.tool.go should not contain orchestrion/all/v2:\n%s", text)
	}
}

func TestBootstrapSyncCommandsPinConfiguredOrchestrionVersion(t *testing.T) {
	cfg := config{
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersion:   "v2.9.0-dev.0.20260416093245-194346a71c51",
	}

	got := bootstrapSyncCommands(cfg)
	if len(got) < 2 {
		t.Fatalf("bootstrapSyncCommands returned too few commands: %#v", got)
	}
	if strings.Join(got[0], " ") != "mod edit -require=github.com/DataDog/orchestrion@v1.9.0" {
		t.Fatalf("first bootstrap sync command=%q, want orchestrion version pin", strings.Join(got[0], " "))
	}
	if strings.Join(got[len(got)-1], " ") != "mod tidy" {
		t.Fatalf("last bootstrap sync command=%q, want mod tidy", strings.Join(got[len(got)-1], " "))
	}
}

func TestEnsureCIVisibilityOrchestrionImport(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "orchestrion.tool.go")
	original := `package tools

import (
	_ "github.com/DataDog/orchestrion" // integration
	_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2" // integration
)
`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatalf("write orchestrion.tool.go: %v", err)
	}

	cfg := config{goModuleDir: dir}
	if err := ensureCIVisibilityOrchestrionImport(cfg); err != nil {
		t.Fatalf("ensureCIVisibilityOrchestrionImport error: %v", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`) {
		t.Fatalf("expected v2 orchestrion import in orchestrion.tool.go:\n%s", text)
	}
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration`) {
		t.Fatalf("expected net/http integration import in orchestrion.tool.go:\n%s", text)
	}
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration`) {
		t.Fatalf("expected slog integration import in orchestrion.tool.go:\n%s", text)
	}
	if strings.Count(text, `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`) != 1 {
		t.Fatalf("expected v2 orchestrion import to be added once:\n%s", text)
	}
}

func TestEnsureCIVisibilityOrchestrionImportNoopWhenPresent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "orchestrion.tool.go")
	original := `package tools

import (
	_ "github.com/DataDog/orchestrion" // integration
	_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration
	_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
	_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration
	_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2" // integration
)
`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatalf("write orchestrion.tool.go: %v", err)
	}

	cfg := config{goModuleDir: dir}
	if err := ensureCIVisibilityOrchestrionImport(cfg); err != nil {
		t.Fatalf("ensureCIVisibilityOrchestrionImport error: %v", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(content)
	if strings.Count(text, `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`) != 1 {
		t.Fatalf("expected v2 orchestrion import to remain single:\n%s", text)
	}
	if strings.Count(text, `_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration`) != 1 {
		t.Fatalf("expected net/http integration import to remain single:\n%s", text)
	}
	if strings.Count(text, `_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration`) != 1 {
		t.Fatalf("expected slog integration import to remain single:\n%s", text)
	}
}

func TestEnsureCIVisibilityOrchestrionImportHandlesBlankLinesAroundV2Import(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "orchestrion.tool.go")
	original := `package tools

import (
	_ "github.com/DataDog/orchestrion" // integration

	_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration
	_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration
	_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration

	_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2" // integration
)
`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatalf("write orchestrion.tool.go: %v", err)
	}

	cfg := config{goModuleDir: dir}
	if err := ensureCIVisibilityOrchestrionImport(cfg); err != nil {
		t.Fatalf("ensureCIVisibilityOrchestrionImport error: %v", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`) {
		t.Fatalf("expected v2 orchestrion import in orchestrion.tool.go:\n%s", text)
	}
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration`) {
		t.Fatalf("expected net/http integration import in orchestrion.tool.go:\n%s", text)
	}
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration`) {
		t.Fatalf("expected slog integration import in orchestrion.tool.go:\n%s", text)
	}
}

func TestEnsureCIVisibilityOrchestrionImportRemovesLegacyV1Import(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "orchestrion.tool.go")
	original := `package tools

import (
	_ "github.com/DataDog/orchestrion" // integration
	_ "gopkg.in/DataDog/dd-trace-go.v1/civisibility" // integration
	_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2" // integration
)
`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatalf("write orchestrion.tool.go: %v", err)
	}

	cfg := config{goModuleDir: dir}
	if err := ensureCIVisibilityOrchestrionImport(cfg); err != nil {
		t.Fatalf("ensureCIVisibilityOrchestrionImport error: %v", err)
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read orchestrion.tool.go: %v", err)
	}
	text := string(content)
	if strings.Contains(text, `_ "gopkg.in/DataDog/dd-trace-go.v1/civisibility" // integration`) {
		t.Fatalf("expected legacy v1 import to be removed:\n%s", text)
	}
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`) {
		t.Fatalf("expected v2 orchestrion import after legacy cleanup:\n%s", text)
	}
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2" // integration`) {
		t.Fatalf("expected net/http integration import after legacy cleanup:\n%s", text)
	}
	if !strings.Contains(text, `_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2" // integration`) {
		t.Fatalf("expected slog integration import after legacy cleanup:\n%s", text)
	}
}

func TestResolveDDTraceGoVersionQueryAcceptsCanonicalTag(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	goPath := writeFakeGoTool(t, `#!/bin/sh
case "$*" in
  *"list -m -json github.com/DataDog/dd-trace-go/v2@v2.6.0"*)
    printf '{"Version":"v2.6.0"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/net/http/v2@v2.6.0"*)
    printf '{"Version":"v2.6.0"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/log/slog/v2@v2.6.0"*)
    printf '{"Version":"v2.6.0"}\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/v2/orchestrion"*)
    printf 'github.com/DataDog/dd-trace-go/v2/orchestrion\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/net/http/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/net/http/v2\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/log/slog/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/log/slog/v2\n'
    ;;
  *)
    echo "unexpected args: $*" >&2
    exit 1
    ;;
esac
`)

	got, err := resolveDDTraceGoVersionQuery("v2.6.0", goPath, []string{"PATH=" + os.Getenv("PATH")})
	if err != nil {
		t.Fatalf("resolveDDTraceGoVersionQuery error: %v", err)
	}
	for _, modulePath := range ddTraceGoModules {
		if got[modulePath] != "v2.6.0" {
			t.Fatalf("resolveDDTraceGoVersionQuery[%q]=%q, want %q", modulePath, got[modulePath], "v2.6.0")
		}
	}
}

func TestResolveDDTraceGoVersionQueryNormalizesCommitSHA(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	goPath := writeFakeGoTool(t, `#!/bin/sh
case "$*" in
  *"list -m -json github.com/DataDog/dd-trace-go/v2@abc123def456"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/net/http/v2@abc123def456"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/log/slog/v2@abc123def456"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/v2/orchestrion"*)
    printf 'github.com/DataDog/dd-trace-go/v2/orchestrion\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/net/http/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/net/http/v2\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/log/slog/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/log/slog/v2\n'
    ;;
  *)
    echo "unexpected args: $*" >&2
    exit 1
    ;;
esac
`)

	got, err := resolveDDTraceGoVersionQuery("abc123def456", goPath, []string{"PATH=" + os.Getenv("PATH")})
	if err != nil {
		t.Fatalf("resolveDDTraceGoVersionQuery error: %v", err)
	}
	for _, modulePath := range ddTraceGoModules {
		if got[modulePath] != "v2.7.0-rc.4" {
			t.Fatalf("resolveDDTraceGoVersionQuery[%q]=%q, want %q", modulePath, got[modulePath], "v2.7.0-rc.4")
		}
	}
}

func TestResolveDDTraceGoVersionQuerySupportsDivergentModules(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	goPath := writeFakeGoTool(t, `#!/bin/sh
case "$*" in
  *"list -m -json github.com/DataDog/dd-trace-go/v2@main"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/net/http/v2@main"*)
    printf '{"Version":"v2.6.0"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/log/slog/v2@main"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/v2/orchestrion"*)
    printf 'github.com/DataDog/dd-trace-go/v2/orchestrion\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/net/http/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/net/http/v2\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/log/slog/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/log/slog/v2\n'
    ;;
  *)
    echo "unexpected args: $*" >&2
    exit 1
    ;;
esac
`)

	got, err := resolveDDTraceGoVersionQuery("main", goPath, []string{"PATH=" + os.Getenv("PATH")})
	if err != nil {
		t.Fatalf("resolveDDTraceGoVersionQuery error: %v", err)
	}
	if got["github.com/DataDog/dd-trace-go/v2"] != "v2.7.0-rc.4" {
		t.Fatalf("unexpected root tracer version: %#v", got)
	}
	if got["github.com/DataDog/dd-trace-go/contrib/net/http/v2"] != "v2.6.0" {
		t.Fatalf("unexpected net/http tracer version: %#v", got)
	}
}

func TestResolveDDTraceGoVersionQueryRejectsPackageValidationFailure(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	goPath := writeFakeGoTool(t, `#!/bin/sh
case "$*" in
  *"list -m -json github.com/DataDog/dd-trace-go/v2@deadbeef"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/net/http/v2@deadbeef"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/log/slog/v2@deadbeef"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/v2/orchestrion"*)
    printf 'github.com/DataDog/dd-trace-go/v2/orchestrion\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/net/http/v2"*)
    echo 'missing package' >&2
    exit 1
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/log/slog/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/log/slog/v2\n'
    ;;
  *)
    echo "unexpected args: $*" >&2
    exit 1
    ;;
esac
`)

	_, err := resolveDDTraceGoVersionQuery("deadbeef", goPath, []string{"PATH=" + os.Getenv("PATH")})
	if err == nil {
		t.Fatal("expected package validation failure")
	}
	if !strings.Contains(err.Error(), `package validation failed`) {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSyntheticDDTraceGoVersionCheckModUsesConfiguredVersions(t *testing.T) {
	versions := map[string]string{
		"github.com/DataDog/dd-trace-go/v2":                  "v2.7.0-rc.4",
		"github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.6.0",
		"github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.7.0-rc.4",
	}
	got := syntheticDDTraceGoVersionCheckMod(versions)
	for modulePath, version := range versions {
		want := modulePath + " " + version
		if !strings.Contains(got, want) {
			t.Fatalf("syntheticDDTraceGoVersionCheckMod missing %q:\n%s", want, got)
		}
	}
}

func TestNormalizedGoEnvForcesGoWorkOff(t *testing.T) {
	got := normalizedGoEnv([]string{"GO111MODULE=off", "GOWORK=/tmp/example", "PATH=" + os.Getenv("PATH")})
	if envValue(got, "GO111MODULE") != "on" {
		t.Fatalf("GO111MODULE=%q, want %q", envValue(got, "GO111MODULE"), "on")
	}
	if envValue(got, "GOWORK") != "off" {
		t.Fatalf("GOWORK=%q, want %q", envValue(got, "GOWORK"), "off")
	}
}

func TestNormalizeDDTraceGoVersionMutatesConfigBeforePersistence(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	goPath := writeFakeGoTool(t, `#!/bin/sh
case "$*" in
  *"list -m -json github.com/DataDog/dd-trace-go/v2@feature-branch"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/net/http/v2@feature-branch"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/log/slog/v2@feature-branch"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/v2/orchestrion"*)
    printf 'github.com/DataDog/dd-trace-go/v2/orchestrion\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/net/http/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/net/http/v2\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/log/slog/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/log/slog/v2\n'
    ;;
  *)
    echo "unexpected args: $*" >&2
    exit 1
    ;;
esac
`)
	t.Setenv("PATH", filepath.Dir(goPath))

	cfg := config{ddTraceGoVersion: "feature-branch"}
	if err := normalizeDDTraceGoVersion(&cfg); err != nil {
		t.Fatalf("normalizeDDTraceGoVersion error: %v", err)
	}
	if cfg.ddTraceGoVersion != "v2.7.0-rc.4" {
		t.Fatalf("cfg.ddTraceGoVersion=%q, want %q", cfg.ddTraceGoVersion, "v2.7.0-rc.4")
	}
	if !strings.Contains(managedModuleBlock(cfg), `dd_trace_go_version = "v2.7.0-rc.4"`) {
		t.Fatalf("expected managed module block to use canonical version:\n%s", managedModuleBlock(cfg))
	}
}

func TestNormalizeDDTraceGoVersionUsesPerModuleConfigWhenVersionsDiverge(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	goPath := writeFakeGoTool(t, `#!/bin/sh
case "$*" in
  *"list -m -json github.com/DataDog/dd-trace-go/v2@feature-branch"*)
    printf '{"Version":"v2.7.0-rc.4"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/net/http/v2@feature-branch"*)
    printf '{"Version":"v2.8.0-dev.0.20260316165907-0cdd3b7576b7"}\n'
    ;;
  *"list -m -json github.com/DataDog/dd-trace-go/contrib/log/slog/v2@feature-branch"*)
    printf '{"Version":"v2.8.0-dev.0.20260316165907-0cdd3b7576b7"}\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/v2/orchestrion"*)
    printf 'github.com/DataDog/dd-trace-go/v2/orchestrion\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/net/http/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/net/http/v2\n'
    ;;
  *"list -mod=mod github.com/DataDog/dd-trace-go/contrib/log/slog/v2"*)
    printf 'github.com/DataDog/dd-trace-go/contrib/log/slog/v2\n'
    ;;
  *)
    echo "unexpected args: $*" >&2
    exit 1
    ;;
esac
`)
	t.Setenv("PATH", filepath.Dir(goPath))

	cfg := config{ddTraceGoVersion: "feature-branch"}
	if err := normalizeDDTraceGoVersion(&cfg); err != nil {
		t.Fatalf("normalizeDDTraceGoVersion error: %v", err)
	}
	if cfg.ddTraceGoVersion != "" {
		t.Fatalf("cfg.ddTraceGoVersion=%q, want empty shared version", cfg.ddTraceGoVersion)
	}
	if cfg.ddTraceGoVersions["github.com/DataDog/dd-trace-go/v2"] != "v2.7.0-rc.4" {
		t.Fatalf("unexpected per-module root version: %#v", cfg.ddTraceGoVersions)
	}
	if !strings.Contains(managedModuleBlock(cfg), `dd_trace_go_versions = {`) {
		t.Fatalf("expected managed module block to use per-module config:\n%s", managedModuleBlock(cfg))
	}
}

func TestEnsureBootstrapCanManageTracerConfigRejectsManualTracerConfig(t *testing.T) {
	content := `module(name = "example")
orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = "v1.9.0",
    dd_trace_go_versions = {
        "github.com/DataDog/dd-trace-go/v2": "v2.7.0-rc.4",
        "github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.8.0-dev.0.20260316165907-0cdd3b7576b7",
        "github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.8.0-dev.0.20260316165907-0cdd3b7576b7",
    },
)
`
	if err := ensureBootstrapCanManageTracerConfig(content); err == nil {
		t.Fatal("expected external manual tracer config to fail")
	}
}

func TestHydrateManagedTracerConfigPreservesPerModuleConfig(t *testing.T) {
	content := `module(name = "example")
# BEGIN Datadog Go Orchestrion bootstrap
git_override(
    module_name = "rules_go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "deadbeef",
    strip_prefix = "third_party/rules_go_orchestrion_base",
)

orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = "v1.9.0",
    dd_trace_go_versions = {
        "github.com/DataDog/dd-trace-go/v2": "v2.7.0-rc.4",
        "github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.8.0-dev.0.20260316165907-0cdd3b7576b7",
        "github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.8.0-dev.0.20260316165907-0cdd3b7576b7",
    },
)
use_repo(orchestrion, "rules_go_orchestrion_tool")
# END Datadog Go Orchestrion bootstrap
`
	var cfg config
	if err := hydrateManagedTracerConfig(&cfg, content); err != nil {
		t.Fatalf("hydrateManagedTracerConfig error: %v", err)
	}
	if cfg.ddTraceGoVersion != "" {
		t.Fatalf("expected shared tracer version to be empty, got %q", cfg.ddTraceGoVersion)
	}
	if cfg.ddTraceGoVersions["github.com/DataDog/dd-trace-go/v2"] != "v2.7.0-rc.4" {
		t.Fatalf("unexpected managed per-module versions: %#v", cfg.ddTraceGoVersions)
	}
}

func writeFakeGoTool(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "go")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake go tool: %v", err)
	}
	return path
}

func TestValidateGuidedPrerequisites(t *testing.T) {
	input := `module(name = "example")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.0.0")
`
	if err := validateGuidedPrerequisites(input); err != nil {
		t.Fatalf("validateGuidedPrerequisites error: %v", err)
	}
}

func TestValidateGuidedPrerequisitesRequiresCoreAndGo(t *testing.T) {
	input := `module(name = "example")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.0.0")
`
	if err := validateGuidedPrerequisites(input); err == nil {
		t.Fatal("expected missing Go companion prerequisite to fail")
	}
}

func TestShouldAddGuidedBlockExactSingleServiceMatch(t *testing.T) {
	cfg := config{
		syncRepoName:   "test_optimization_data",
		service:        "go-service",
		runtimeVersion: "1.25.0",
	}
	input := `module(name = "example")
go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

go_topt.test_optimization_go(
    name = "test_optimization_data",
    service = "go-service",
    runtime_version = "1.25.0",
)

use_repo(go_topt, "test_optimization_data")
`
	add, err := shouldAddGuidedBlock(input, cfg)
	if err != nil {
		t.Fatalf("shouldAddGuidedBlock error: %v", err)
	}
	if add {
		t.Fatal("expected exact single-service setup to be tolerated without adding a managed block")
	}
}

func TestShouldAddGuidedBlockRejectsCoreSyncSetup(t *testing.T) {
	cfg := config{
		syncRepoName:   "test_optimization_data",
		service:        "go-service",
		runtimeVersion: "1.25.0",
	}
	input := `module(name = "example")
test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)
`
	if _, err := shouldAddGuidedBlock(input, cfg); err == nil {
		t.Fatal("expected core sync setup to be rejected")
	}
}

func TestShouldAddGuidedBlockUpdatesManagedBlockWhenPresent(t *testing.T) {
	cfg := config{
		syncRepoName:   "test_optimization_data",
		service:        "go-service",
		runtimeVersion: "1.25.0",
	}
	input := `module(name = "example")
# BEGIN Datadog Go Guided Setup
datadog_go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)
datadog_go_topt.test_optimization_go(
    name = "test_optimization_data",
    service = "go-service",
    runtime_version = "1.23.0",
)
use_repo(datadog_go_topt, "test_optimization_data")
# END Datadog Go Guided Setup
`
	add, err := shouldAddGuidedBlock(input, cfg)
	if err != nil {
		t.Fatalf("shouldAddGuidedBlock error: %v", err)
	}
	if !add {
		t.Fatal("expected managed guided block to be updated")
	}
}

func TestShouldAddGuidedBlockRejectsConflictingSetupOutsideManagedBlock(t *testing.T) {
	cfg := config{
		syncRepoName:   "test_optimization_data",
		service:        "go-service",
		runtimeVersion: "1.25.0",
	}
	input := `module(name = "example")
# BEGIN Datadog Go Guided Setup
datadog_go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)
datadog_go_topt.test_optimization_go(
    name = "test_optimization_data",
    service = "go-service",
    runtime_version = "1.25.0",
)
use_repo(datadog_go_topt, "test_optimization_data")
# END Datadog Go Guided Setup

test_optimization_sync = use_extension(
    "@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl",
    "test_optimization_sync_extension",
)
`
	if _, err := shouldAddGuidedBlock(input, cfg); err == nil {
		t.Fatal("expected conflicting unmanaged sync setup to be rejected")
	}
}

func TestEnsureLoadStatementInsertsBeforePackageCall(t *testing.T) {
	input := `# workspace root

package(default_visibility = ["//visibility:public"])

exports_files(["foo"])
`
	got, err := ensureLoadStatement(input, `load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")`)
	if err != nil {
		t.Fatalf("ensureLoadStatement error: %v", err)
	}
	loadIdx := strings.Index(got, `load("@datadog-rules-test-optimization//tools/core:test_optimization_uploader.bzl", "dd_payload_uploader")`)
	packageIdx := strings.Index(got, `package(default_visibility = ["//visibility:public"])`)
	if loadIdx < 0 || packageIdx < 0 || loadIdx > packageIdx {
		t.Fatalf("expected load before package() call:\n%s", got)
	}
}

func TestEnsureGuidedRootBuildCreatesBuildBazel(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		workspaceDir:       dir,
		syncRepoName:       "test_optimization_data",
		doctorTargetName:   "dd_test_optimization_doctor",
		uploaderTargetName: "dd_upload_payloads",
	}
	if err := ensureGuidedRootBuild(cfg); err != nil {
		t.Fatalf("ensureGuidedRootBuild error: %v", err)
	}
	path := filepath.Join(dir, "BUILD.bazel")
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read BUILD.bazel: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, doctorBlockStart) || !strings.Contains(text, `name = "dd_test_optimization_doctor"`) {
		t.Fatalf("expected managed doctor block in BUILD.bazel:\n%s", text)
	}
	if !strings.Contains(text, uploaderBlockStart) || !strings.Contains(text, `name = "dd_upload_payloads"`) {
		t.Fatalf("expected managed uploader block in BUILD.bazel:\n%s", text)
	}
	if !strings.Contains(text, pinExportsBlockStart) || !strings.Contains(text, `"orchestrion.tool.go"`) || !strings.Contains(text, `"orchestrion.yml"`) {
		t.Fatalf("expected managed pin-file exports in BUILD.bazel:\n%s", text)
	}
}

func TestEnsureGuidedWrapperCreatesFiles(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		workspaceDir: dir,
		syncRepoName: "test_optimization_data",
	}
	if err := ensureGuidedWrapper(cfg); err != nil {
		t.Fatalf("ensureGuidedWrapper error: %v", err)
	}
	buildPath := filepath.Join(dir, "tools", "build", "BUILD.bazel")
	if _, err := os.Stat(buildPath); err != nil {
		t.Fatalf("expected tools/build/BUILD.bazel: %v", err)
	}
	wrapperPath := filepath.Join(dir, "tools", "build", "dd_go_test.bzl")
	content, err := os.ReadFile(wrapperPath)
	if err != nil {
		t.Fatalf("read dd_go_test.bzl: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, wrapperBlockStart) || !strings.Contains(text, `load("@test_optimization_data//:export.bzl", "topt_data")`) {
		t.Fatalf("expected managed wrapper content:\n%s", text)
	}
	if !strings.Contains(text, `orchestrion_pin_files = _ORCHESTRION_PIN_FILES`) || !strings.Contains(text, `"//:orchestrion.tool.go"`) {
		t.Fatalf("expected wrapper to pass root Orchestrion pin files:\n%s", text)
	}
}

func TestEnsureGuidedWorkspaceFilesUsesGoModulePackagePinLabels(t *testing.T) {
	dir := t.TempDir()
	goModuleDir := filepath.Join(dir, "services", "worker")
	if err := os.MkdirAll(goModuleDir, 0o755); err != nil {
		t.Fatalf("mkdir go module dir: %v", err)
	}
	cfg := config{
		workspaceDir:       dir,
		goModuleDir:        goModuleDir,
		syncRepoName:       "test_optimization_data",
		doctorTargetName:   "dd_test_optimization_doctor",
		uploaderTargetName: "dd_upload_payloads",
	}
	if err := ensureGuidedWorkspaceFiles(cfg); err != nil {
		t.Fatalf("ensureGuidedWorkspaceFiles error: %v", err)
	}

	rootBuild, err := os.ReadFile(filepath.Join(dir, "BUILD.bazel"))
	if err != nil {
		t.Fatalf("read root BUILD.bazel: %v", err)
	}
	if strings.Contains(string(rootBuild), pinExportsBlockStart) {
		t.Fatalf("root BUILD.bazel should not export non-root Go module pin files:\n%s", string(rootBuild))
	}

	moduleBuild, err := os.ReadFile(filepath.Join(goModuleDir, "BUILD.bazel"))
	if err != nil {
		t.Fatalf("read module BUILD.bazel: %v", err)
	}
	if !strings.Contains(string(moduleBuild), pinExportsBlockStart) || !strings.Contains(string(moduleBuild), `"orchestrion.tool.go"`) {
		t.Fatalf("expected module BUILD.bazel to export Orchestrion pin files:\n%s", string(moduleBuild))
	}

	wrapperPath := filepath.Join(dir, "tools", "build", "dd_go_test.bzl")
	wrapperContent, err := os.ReadFile(wrapperPath)
	if err != nil {
		t.Fatalf("read dd_go_test.bzl: %v", err)
	}
	wrapper := string(wrapperContent)
	if !strings.Contains(wrapper, `"//services/worker:orchestrion.tool.go"`) || strings.Contains(wrapper, `"//:orchestrion.tool.go"`) {
		t.Fatalf("expected wrapper to reference Go module package pin labels:\n%s", wrapper)
	}
}

func TestEnsureGuidedWrapperRejectsUnmanagedFileWithoutForce(t *testing.T) {
	dir := t.TempDir()
	wrapperDir := filepath.Join(dir, "tools", "build")
	if err := os.MkdirAll(wrapperDir, 0o755); err != nil {
		t.Fatalf("mkdir tools/build: %v", err)
	}
	wrapperPath := filepath.Join(wrapperDir, "dd_go_test.bzl")
	if err := os.WriteFile(wrapperPath, []byte("custom"), 0o644); err != nil {
		t.Fatalf("write dd_go_test.bzl: %v", err)
	}
	cfg := config{
		workspaceDir: dir,
		syncRepoName: "test_optimization_data",
	}
	if err := ensureGuidedWrapper(cfg); err == nil {
		t.Fatal("expected unmanaged wrapper file to fail without force")
	}
}
