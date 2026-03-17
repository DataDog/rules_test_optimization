package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInsertAfterModuleDecl(t *testing.T) {
	input := "module(name = \"example\")\n"
	got, err := insertAfterModuleDecl(input, "bazel_dep(name = \"rules_go\", version = \"0.59.0\")\n")
	if err != nil {
		t.Fatalf("insertAfterModuleDecl error: %v", err)
	}
	if !strings.Contains(got, "bazel_dep(name = \"rules_go\", version = \"0.59.0\")") {
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
		orchestrionVersion: "v1.5.0",
		rulesGoRemote:      "https://github.com/example/repo.git",
		rulesGoCommit:      "deadbeef",
	}
	got := managedModuleBlock(cfg)
	if !strings.Contains(got, `git_override(`) {
		t.Fatalf("expected rules_go override in managed block:\n%s", got)
	}
	if !strings.Contains(got, `strip_prefix = "third_party/rules_go_orchestrion"`) {
		t.Fatalf("expected vendored rules_go strip_prefix in managed block:\n%s", got)
	}
	if !strings.Contains(got, `use_extension("@rules_go//go:extensions.bzl", "orchestrion")`) {
		t.Fatalf("expected rules_go orchestrion extension in managed block:\n%s", got)
	}
	if !strings.Contains(got, `orchestrion.from_source(version = "v1.5.0")`) {
		t.Fatalf("expected orchestrion version in managed block:\n%s", got)
	}
	if !strings.Contains(got, `use_repo(orchestrion, "rules_go_orchestrion_tool")`) {
		t.Fatalf("expected rules_go orchestrion repo wiring in managed block:\n%s", got)
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
		rulesGoCommit: defaultRulesGoCommit,
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
}

func TestEnsureCIVisibilityOrchestrionImportHandlesBlankLinesAroundV2Import(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "orchestrion.tool.go")
	original := `package tools

import (
	_ "github.com/DataDog/orchestrion" // integration

	_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration

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
		runtimeVersion: "1.24.0",
	}
	input := `module(name = "example")
go_topt = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_extension.bzl",
    "test_optimization_go_extension",
)

go_topt.test_optimization_go(
    name = "test_optimization_data",
    service = "go-service",
    runtime_version = "1.24.0",
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
		runtimeVersion: "1.24.0",
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
		runtimeVersion: "1.24.0",
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
		runtimeVersion: "1.24.0",
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
    runtime_version = "1.24.0",
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
	if !strings.Contains(text, uploaderBlockStart) || !strings.Contains(text, `name = "dd_upload_payloads"`) {
		t.Fatalf("expected managed uploader block in BUILD.bazel:\n%s", text)
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
