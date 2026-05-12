// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/DataDog/rules_test_optimization/modules/go/tools/onboardingpins"
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

func TestWorkspaceModeSnippetIncludesSyncAndCompleteVariant(t *testing.T) {
	cfg := config{
		workspaceMode:        true,
		rulesGoRemote:        "https://github.com/example/repo.git",
		rtoCommit:            "published-sha",
		datadogFetch:         "git",
		rulesGoFetch:         "git",
		rulesGoRepoName:      "io_bazel_rules_go",
		rulesGoVariant:       "complete",
		orchestrionVersion:   "v1.9.0",
		ddTraceGoVersion:     "v2.9.0-dev.0.20260416093245-194346a71c51",
		syncRepoName:         "test_optimization_data_worker",
		service:              "worker",
		runtimeVersion:       "1.25.9",
		doctorTargetName:     defaultDoctorTargetName,
		uploaderTargetName:   defaultUploaderTargetName,
		plainWrapperName:     defaultPlainWrapperName,
		optimizedWrapperName: defaultOptimizedWrapperName,
	}
	got, err := workspaceSnippet(cfg)
	if err != nil {
		t.Fatalf("workspaceSnippet error: %v", err)
	}
	for _, want := range []string{
		`rules_go_variant = "complete"`,
		`rules_go_repo_name = "io_bazel_rules_go"`,
		`load("@datadog-rules-test-optimization//tools/core:test_optimization_sync.bzl", "test_optimization_sync")`,
		`name = "test_optimization_data_worker"`,
		`service = "worker"`,
		`runtime_name = "go"`,
		`runtime_version = "1.25.9"`,
		`require_git_metadata = True`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("workspace mode snippet missing %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "dd-source") {
		t.Fatalf("workspace mode snippet must stay generic:\n%s", got)
	}
}

func TestRunWorkspaceModeWritesSelectedFilesWithoutModuleBazel(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		workspaceDir:          dir,
		goModuleDir:           dir,
		workspaceMode:         true,
		writeRootTargets:      true,
		writeOrchestrionFiles: true,
		writeWrapperTemplate:  true,
		writeBazelrc:          true,
		bazelrcPath:           ".bazelrc",
		bazelrcConfig:         "test-optimization-worker",
		syncRepoName:          "test_optimization_data_worker",
		doctorTargetName:      "dd_test_optimization_doctor",
		uploaderTargetName:    "dd_upload_payloads",
		expectedTargets:       []string{"//worker:go_default_test"},
		wrapperPackage:        "rules/go",
		wrapperFile:           "dd_topt_go_test.bzl",
		plainWrapperName:      "dd_go_test",
		optimizedWrapperName:  "dd_topt_go_test",
		rulesGoRepoName:       "io_bazel_rules_go",
		datadogFetch:          defaultDatadogFetch,
		rulesGoFetch:          defaultRulesGoFetch,
		rulesGoVariant:        defaultRulesGoVariant,
		ddTraceGoVersion:      defaultDDTraceGoVersion,
		orchestrionVersion:    defaultOrchestrionVersion,
		rulesGoRemote:         defaultRulesGoRemote,
		goModSync:             defaultGoModSync,
	}
	if err := run(cfg); err != nil {
		t.Fatalf("run workspace mode error: %v", err)
	}
	for _, path := range []string{
		"BUILD.bazel",
		".bazelrc",
		"orchestrion.tool.go",
		"orchestrion.yml",
		"rules/go/BUILD.bazel",
		"rules/go/dd_topt_go_test.bzl",
	} {
		if _, err := os.Stat(filepath.Join(dir, path)); err != nil {
			t.Fatalf("expected %s: %v", path, err)
		}
	}
	rootBuild, err := os.ReadFile(filepath.Join(dir, "BUILD.bazel"))
	if err != nil {
		t.Fatalf("read root BUILD.bazel: %v", err)
	}
	if !strings.Contains(string(rootBuild), `expected_targets = [`) || !strings.Contains(string(rootBuild), `"//worker:go_default_test"`) {
		t.Fatalf("expected doctor expected_targets in root BUILD.bazel:\n%s", rootBuild)
	}
	wrapper, err := os.ReadFile(filepath.Join(dir, "rules/go/dd_topt_go_test.bzl"))
	if err != nil {
		t.Fatalf("read wrapper: %v", err)
	}
	wrapperText := string(wrapper)
	for _, want := range []string{
		`load("@io_bazel_rules_go//go:def.bzl", _raw_go_test = "go_test")`,
		`def dd_go_test(name, **kwargs):`,
		`def dd_topt_go_test(name, **kwargs):`,
		`load("@test_optimization_data_worker//:export.bzl", "topt_data")`,
		`orchestrion_pin_files = _ORCHESTRION_PIN_FILES`,
	} {
		if !strings.Contains(wrapperText, want) {
			t.Fatalf("workspace wrapper missing %q:\n%s", want, wrapperText)
		}
	}
	for _, forbidden := range []string{"dd-source", "--test_env=DD_GIT_"} {
		if strings.Contains(wrapperText, forbidden) {
			t.Fatalf("workspace wrapper contains forbidden %q:\n%s", forbidden, wrapperText)
		}
	}
}

func TestWorkspaceModeDoesNotRunGoModSyncByDefault(t *testing.T) {
	dir := t.TempDir()
	if err := run(config{
		workspaceDir:          dir,
		workspaceMode:         true,
		writeOrchestrionFiles: true,
		datadogFetch:          defaultDatadogFetch,
		rulesGoFetch:          defaultRulesGoFetch,
		rulesGoVariant:        defaultRulesGoVariant,
		ddTraceGoVersion:      defaultDDTraceGoVersion,
		orchestrionVersion:    defaultOrchestrionVersion,
		rulesGoRepoName:       defaultRulesGoRepoName,
		rulesGoRemote:         defaultRulesGoRemote,
		syncRepoName:          defaultSyncRepoName,
		doctorTargetName:      defaultDoctorTargetName,
		uploaderTargetName:    defaultUploaderTargetName,
		wrapperPackage:        defaultWrapperPackage,
		wrapperFile:           defaultWorkspaceWrapperFile,
		plainWrapperName:      defaultPlainWrapperName,
		optimizedWrapperName:  defaultOptimizedWrapperName,
		goModSync:             defaultGoModSync,
	}); err != nil {
		t.Fatalf("workspace mode should write Orchestrion files without go.mod by default: %v", err)
	}
}

func TestEnsureWorkspaceWrapperTemplateIsIdempotent(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		workspaceDir:         dir,
		syncRepoName:         "test_optimization_data",
		wrapperPackage:       "tools/test",
		wrapperFile:          "go_test_wrappers.bzl",
		plainWrapperName:     "plain_go_test",
		optimizedWrapperName: "optimized_go_test",
		rulesGoRepoName:      "io_bazel_rules_go",
	}
	if err := ensureWorkspaceWrapperTemplate(cfg); err != nil {
		t.Fatalf("first ensureWorkspaceWrapperTemplate error: %v", err)
	}
	path := filepath.Join(dir, "tools", "test", "go_test_wrappers.bzl")
	first, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read first wrapper: %v", err)
	}
	if err := ensureWorkspaceWrapperTemplate(cfg); err != nil {
		t.Fatalf("second ensureWorkspaceWrapperTemplate error: %v", err)
	}
	second, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read second wrapper: %v", err)
	}
	if string(first) != string(second) {
		t.Fatalf("expected idempotent wrapper template:\nfirst:\n%s\nsecond:\n%s", first, second)
	}
}

func TestEnsureWorkspaceWrapperTemplateRejectsPathTraversal(t *testing.T) {
	dir := t.TempDir()
	err := ensureWorkspaceWrapperTemplate(config{
		workspaceDir:         dir,
		syncRepoName:         "test_optimization_data",
		wrapperPackage:       "../outside",
		wrapperFile:          "dd_topt_go_test.bzl",
		plainWrapperName:     "dd_go_test",
		optimizedWrapperName: "dd_topt_go_test",
		rulesGoRepoName:      "io_bazel_rules_go",
	})
	if err == nil || !strings.Contains(err.Error(), "--wrapper-package must stay inside the workspace") {
		t.Fatalf("ensureWorkspaceWrapperTemplate error=%v, want path traversal rejection", err)
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

func TestRunPrintPublishedPinsDoesNotRequireModuleFiles(t *testing.T) {
	dir, commit := publishedPinsTestRepo(t)
	var buf strings.Builder
	if err := captureStdout(&buf, func() error {
		return run(config{
			workspaceDir:                dir,
			printPublishedPins:          true,
			rtoCommit:                   commit,
			datadogFetch:                defaultDatadogFetch,
			rulesGoFetch:                defaultRulesGoFetch,
			rulesGoVariant:              "complete",
			publishedPinsArchiveFetcher: staticArchiveFetcher("archive bytes"),
		})
	}); err != nil {
		t.Fatalf("run --print-published-pins error: %v", err)
	}
	got := buf.String()
	for _, want := range []string{
		`RTO_COMMIT="` + commit + `"`,
		`RTO_ARCHIVE_URL="https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/` + commit + `"`,
		`RULES_GO_VARIANT="complete"`,
		`DD_TRACE_GO_VERSION="` + onboardingpins.DefaultDDTraceGoVersion + `"`,
		`ORCHESTRION_VERSION="` + onboardingpins.DefaultOrchestrionVersion + `"`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("published pins missing %q:\n%s", want, got)
		}
	}
}

func TestRunPrintOnboardingSummaryUsesCurrentCommit(t *testing.T) {
	dir, commit := publishedPinsTestRepo(t)
	staleCommit := strings.Repeat("b", 40)
	var buf strings.Builder
	if err := captureStdout(&buf, func() error {
		return run(config{
			workspaceDir:                dir,
			printOnboardingSummary:      true,
			rtoCommit:                   commit,
			datadogFetch:                defaultDatadogFetch,
			rulesGoFetch:                defaultRulesGoFetch,
			rulesGoVariant:              "base",
			publishedPinsArchiveFetcher: staticArchiveFetcher("archive bytes"),
		})
	}); err != nil {
		t.Fatalf("run --print-onboarding-summary error: %v", err)
	}
	got := buf.String()
	if !strings.Contains(got, commit) {
		t.Fatalf("summary missing current commit:\n%s", got)
	}
	if strings.Contains(got, staleCommit) {
		t.Fatalf("summary contains stale commit %s:\n%s", staleCommit, got)
	}
}

func TestWriteOnboardingSummaryPreservesUnmanagedFile(t *testing.T) {
	dir, commit := publishedPinsTestRepo(t)
	path := filepath.Join(dir, "TEST_OPTIMIZATION_GUIDE.md")
	if err := os.WriteFile(path, []byte("# Existing guide\n"), 0o644); err != nil {
		t.Fatalf("write unmanaged guide: %v", err)
	}
	err := run(config{
		workspaceDir:                dir,
		writeOnboardingSummary:      "TEST_OPTIMIZATION_GUIDE.md",
		rtoCommit:                   commit,
		datadogFetch:                defaultDatadogFetch,
		rulesGoFetch:                defaultRulesGoFetch,
		rulesGoVariant:              "complete",
		publishedPinsArchiveFetcher: staticArchiveFetcher("archive bytes"),
	})
	if err == nil || !strings.Contains(err.Error(), "is not Datadog-managed") {
		t.Fatalf("run --write-onboarding-summary error=%v, want unmanaged file rejection", err)
	}
}

func TestWriteOnboardingSummaryIsIdempotent(t *testing.T) {
	dir, commit := publishedPinsTestRepo(t)
	cfg := config{
		workspaceDir:                dir,
		writeOnboardingSummary:      "TEST_OPTIMIZATION_GUIDE.md",
		rtoCommit:                   commit,
		datadogFetch:                defaultDatadogFetch,
		rulesGoFetch:                defaultRulesGoFetch,
		rulesGoVariant:              "complete",
		publishedPinsArchiveFetcher: staticArchiveFetcher("archive bytes"),
	}
	if err := run(cfg); err != nil {
		t.Fatalf("first run --write-onboarding-summary error: %v", err)
	}
	path := filepath.Join(dir, "TEST_OPTIMIZATION_GUIDE.md")
	first, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read first guide: %v", err)
	}
	if err := run(cfg); err != nil {
		t.Fatalf("second run --write-onboarding-summary error: %v", err)
	}
	second, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read second guide: %v", err)
	}
	if string(first) != string(second) {
		t.Fatalf("summary write should be idempotent:\nfirst:\n%s\nsecond:\n%s", first, second)
	}
	if !strings.Contains(string(second), commit) {
		t.Fatalf("summary missing current commit:\n%s", second)
	}
}

func TestValidationScriptUsesConfiguredFlowAndUploadOptIn(t *testing.T) {
	got, err := validationScript(config{
		printValidationScript:  true,
		bazelCommand:           "bzl",
		bazelConfig:            "test-optimization-worker-pilot",
		syncRepoName:           "test_optimization_data_worker",
		validationDoctorTarget: "//:dd_test_optimization_doctor",
		validationUploadTarget: "//:dd_upload_payloads",
		controlTargets:         []string{"//worker/control:go_default_test"},
		expectedTargets:        []string{"//worker:go_default_test", "//worker:topt_flaky_test"},
		extraSyncFlags:         []string{"--enable_workspace"},
		extraTestFlags:         []string{"--noexperimental_use_validation_aspect"},
		extraRunFlags:          []string{"--remote_cache="},
		largeMonorepo:          true,
		minFreeDiskGB:          35,
		shutdownBazelOnExit:    true,
		defaultJobs:            1,
		datadogFetch:           defaultDatadogFetch,
		rulesGoFetch:           defaultRulesGoFetch,
		rulesGoVariant:         defaultRulesGoVariant,
		ddTraceGoVersion:       defaultDDTraceGoVersion,
		orchestrionVersion:     defaultOrchestrionVersion,
		rulesGoRepoName:        defaultRulesGoRepoName,
		rulesGoRemote:          defaultRulesGoRemote,
		doctorTargetName:       defaultDoctorTargetName,
		uploaderTargetName:     defaultUploaderTargetName,
		wrapperPackage:         defaultWrapperPackage,
		wrapperFile:            defaultWorkspaceWrapperFile,
		plainWrapperName:       defaultPlainWrapperName,
		optimizedWrapperName:   defaultOptimizedWrapperName,
	})
	if err != nil {
		t.Fatalf("validationScript error: %v", err)
	}
	for _, want := range []string{
		`BAZEL='bzl'`,
		`BAZEL_CONFIG='test-optimization-worker-pilot'`,
		`SYNC_REPO='test_optimization_data_worker'`,
		`DOCTOR_TARGET='//:dd_test_optimization_doctor'`,
		`UPLOAD_TARGET='//:dd_upload_payloads'`,
		`MIN_FREE_DISK_GB=35`,
		`LARGE_MONOREPO=1`,
		`SHUTDOWN_BAZEL_ON_EXIT=1`,
		`'--config=test-optimization-worker-pilot'`,
		`'--jobs=1'`,
		`'--enable_workspace'`,
		`'--noexperimental_use_validation_aspect'`,
		`'--remote_cache='`,
		`'//worker/control:go_default_test'`,
		`'//worker:go_default_test'`,
		`'//worker:topt_flaky_test'`,
		`sync -> controls -> instrumented tests -> doctor -> optional upload`,
		`upload skipped; rerun with --upload`,
		`${BAZEL}" shutdown`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("validation script missing %q:\n%s", want, got)
		}
	}
	for _, forbidden := range []string{
		`--test_env=DD_GIT_`,
		`DD_API_KEY=`,
		`rm -rf`,
	} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("validation script contains forbidden %q:\n%s", forbidden, got)
		}
	}
}

func TestValidationScriptTargetsFollowGuidedTargetNames(t *testing.T) {
	cfg := config{
		doctorTargetName:       "custom_doctor",
		uploaderTargetName:     "custom_upload",
		validationDoctorTarget: "//:" + defaultDoctorTargetName,
		validationUploadTarget: "//:" + defaultUploaderTargetName,
	}
	normalizeValidationScriptTargets(&cfg)
	if cfg.validationDoctorTarget != "//:custom_doctor" {
		t.Fatalf("validationDoctorTarget=%q, want //:custom_doctor", cfg.validationDoctorTarget)
	}
	if cfg.validationUploadTarget != "//:custom_upload" {
		t.Fatalf("validationUploadTarget=%q, want //:custom_upload", cfg.validationUploadTarget)
	}

	cfg.validationDoctorTarget = "//:explicit_doctor"
	cfg.validationUploadTarget = "//:explicit_upload"
	cfg.validationDoctorSet = true
	cfg.validationUploadSet = true
	normalizeValidationScriptTargets(&cfg)
	if cfg.validationDoctorTarget != "//:explicit_doctor" || cfg.validationUploadTarget != "//:explicit_upload" {
		t.Fatalf("explicit validation labels were not preserved: doctor=%q upload=%q", cfg.validationDoctorTarget, cfg.validationUploadTarget)
	}
}

func TestRunPrintValidationScriptDoesNotRequireModuleFiles(t *testing.T) {
	dir := t.TempDir()
	var buf strings.Builder
	if err := captureStdout(&buf, func() error {
		return run(config{
			workspaceDir:           dir,
			printValidationScript:  true,
			bazelCommand:           "bazel",
			bazelConfig:            "test-optimization",
			validationDoctorTarget: "//:dd_test_optimization_doctor",
			validationUploadTarget: "//:dd_upload_payloads",
			expectedTargets:        []string{"//pkg:go_default_test"},
			datadogFetch:           defaultDatadogFetch,
			rulesGoFetch:           defaultRulesGoFetch,
			rulesGoVariant:         defaultRulesGoVariant,
			ddTraceGoVersion:       defaultDDTraceGoVersion,
			orchestrionVersion:     defaultOrchestrionVersion,
			rulesGoRepoName:        defaultRulesGoRepoName,
			rulesGoRemote:          defaultRulesGoRemote,
			syncRepoName:           defaultSyncRepoName,
			doctorTargetName:       defaultDoctorTargetName,
			uploaderTargetName:     defaultUploaderTargetName,
			wrapperPackage:         defaultWrapperPackage,
			wrapperFile:            defaultWorkspaceWrapperFile,
			plainWrapperName:       defaultPlainWrapperName,
			optimizedWrapperName:   defaultOptimizedWrapperName,
		})
	}); err != nil {
		t.Fatalf("run --print-validation-script error: %v", err)
	}
	if got := buf.String(); !strings.Contains(got, `run_step "doctor ${DOCTOR_TARGET}"`) {
		t.Fatalf("expected validation script on stdout:\n%s", got)
	}
}

func TestValidationScriptRunsWithNoControlTargets(t *testing.T) {
	dir := t.TempDir()
	fakeBazel := filepath.Join(dir, "bazel")
	logPath := filepath.Join(dir, "bazel.log")
	if err := os.WriteFile(fakeBazel, []byte("#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$BAZEL_LOG\"\n"), 0o755); err != nil {
		t.Fatalf("write fake bazel: %v", err)
	}

	script, err := validationScript(config{
		printValidationScript:  true,
		bazelCommand:           fakeBazel,
		bazelConfig:            "test-optimization",
		syncRepoName:           defaultSyncRepoName,
		validationDoctorTarget: "//:dd_test_optimization_doctor",
		validationUploadTarget: "//:dd_upload_payloads",
		expectedTargets:        []string{"//pkg:go_default_test"},
		minFreeDiskGB:          defaultMinFreeDiskGB,
	})
	if err != nil {
		t.Fatalf("validationScript error: %v", err)
	}
	scriptPath := filepath.Join(dir, "validate.sh")
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write validation script: %v", err)
	}
	cmd := exec.Command("bash", scriptPath, "--no-upload")
	cmd.Env = append(os.Environ(), "BAZEL_LOG="+logPath)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("validation script failed: %v\n%s", err, output)
	}
	logBytes, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read fake bazel log: %v", err)
	}
	logText := string(logBytes)
	for _, want := range []string{
		"sync --config=test-optimization --repo_env=FETCH_SALT=",
		"test --config=test-optimization //pkg:go_default_test",
		"run --config=test-optimization //:dd_test_optimization_doctor",
	} {
		if !strings.Contains(logText, want) {
			t.Fatalf("fake bazel log missing %q:\n%s\nscript output:\n%s", want, logText, output)
		}
	}
	if strings.Contains(logText, "dd_upload_payloads") {
		t.Fatalf("validation script uploaded without --upload:\n%s", logText)
	}
}

func TestWriteValidationScriptFileIsExecutableAndPreservesUnmanagedFiles(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		workspaceDir:           dir,
		validationScriptPath:   "tools/test_optimization/validate_go_pilot.sh",
		bazelCommand:           "bazel",
		bazelConfig:            "test-optimization",
		syncRepoName:           "test_optimization_data",
		validationDoctorTarget: "//:dd_test_optimization_doctor",
		validationUploadTarget: "//:dd_upload_payloads",
		expectedTargets:        []string{"//pkg:go_default_test"},
		minFreeDiskGB:          defaultMinFreeDiskGB,
	}
	if err := writeValidationScriptFile(cfg); err != nil {
		t.Fatalf("writeValidationScriptFile error: %v", err)
	}
	path := filepath.Join(dir, "tools", "test_optimization", "validate_go_pilot.sh")
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat validation script: %v", err)
	}
	if info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("validation script is not executable: mode=%s", info.Mode())
	}
	first, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read validation script: %v", err)
	}
	if err := writeValidationScriptFile(cfg); err != nil {
		t.Fatalf("second writeValidationScriptFile error: %v", err)
	}
	second, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read second validation script: %v", err)
	}
	if string(first) != string(second) {
		t.Fatalf("expected idempotent validation script write")
	}

	unmanagedPath := filepath.Join(dir, "tools", "test_optimization", "custom.sh")
	if err := os.WriteFile(unmanagedPath, []byte("#!/usr/bin/env bash\n"), 0o755); err != nil {
		t.Fatalf("write unmanaged script: %v", err)
	}
	cfg.validationScriptPath = "tools/test_optimization/custom.sh"
	if err := writeValidationScriptFile(cfg); err == nil || !strings.Contains(err.Error(), "is not Datadog-managed") {
		t.Fatalf("writeValidationScriptFile error=%v, want unmanaged-file protection", err)
	}
}

func TestValidationScriptRejectsUnsafeValues(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		workspaceDir:           dir,
		printValidationScript:  true,
		bazelCommand:           "bazel --bad",
		bazelConfig:            "test-optimization",
		syncRepoName:           "test_optimization_data",
		validationDoctorTarget: "//:dd_test_optimization_doctor",
		validationUploadTarget: "//:dd_upload_payloads",
		expectedTargets:        []string{"//pkg:go_default_test"},
		minFreeDiskGB:          defaultMinFreeDiskGB,
	}
	if _, err := validationScript(cfg); err == nil || !strings.Contains(err.Error(), "--bazel-command must not contain arguments") {
		t.Fatalf("validationScript error=%v, want bazel command rejection", err)
	}
	cfg.bazelCommand = "bazel"
	cfg.extraTestFlags = []string{"--test_env=DD_GIT_BRANCH=main"}
	if _, err := validationScript(cfg); err == nil || !strings.Contains(err.Error(), "must not pass DD_GIT_*") {
		t.Fatalf("validationScript error=%v, want DD_GIT test env rejection", err)
	}
	cfg.extraTestFlags = []string{"--test_env==DD_GIT_BRANCH"}
	if _, err := validationScript(cfg); err == nil || !strings.Contains(err.Error(), "must not pass DD_GIT_*") {
		t.Fatalf("validationScript error=%v, want DD_GIT test env unset rejection", err)
	}
	cfg.extraTestFlags = nil
	cfg.validationScriptPath = "../outside.sh"
	if err := writeValidationScriptFile(cfg); err == nil || !strings.Contains(err.Error(), "--validation-script-path must stay inside workspace") {
		t.Fatalf("writeValidationScriptFile error=%v, want path traversal rejection", err)
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

func TestRunGuidedWriteBazelrcValidatesBeforeWriting(t *testing.T) {
	dir := t.TempDir()
	err := run(config{
		workspaceDir:       dir,
		guided:             true,
		writeBazelrc:       true,
		bazelrcPath:        ".bazelrc",
		bazelrcConfig:      "test-optimization",
		datadogFetch:       defaultDatadogFetch,
		rulesGoFetch:       defaultRulesGoFetch,
		rulesGoVariant:     defaultRulesGoVariant,
		ddTraceGoVersion:   defaultDDTraceGoVersion,
		orchestrionVersion: defaultOrchestrionVersion,
		rulesGoRepoName:    defaultRulesGoRepoName,
		rulesGoRemote:      defaultRulesGoRemote,
		syncRepoName:       defaultSyncRepoName,
		doctorTargetName:   defaultDoctorTargetName,
		uploaderTargetName: defaultUploaderTargetName,
		runtimeVersion:     "1.25.0",
	})
	if err == nil || !strings.Contains(err.Error(), "--guided requires --service") {
		t.Fatalf("run error=%v, want missing service validation", err)
	}
	if _, statErr := os.Stat(filepath.Join(dir, ".bazelrc")); !os.IsNotExist(statErr) {
		t.Fatalf(".bazelrc was written before guided validation, statErr=%v", statErr)
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

func TestWriteBazelrcBlockRejectsPathTraversal(t *testing.T) {
	dir := t.TempDir()
	err := writeBazelrcBlock(config{
		workspaceDir:  dir,
		bazelrcPath:   "../outside.bazelrc",
		bazelrcConfig: "test-optimization",
	})
	if err == nil || !strings.Contains(err.Error(), "--bazelrc-path must stay inside workspace") {
		t.Fatalf("writeBazelrcBlock error=%v, want workspace-bound path validation", err)
	}
	if _, statErr := os.Stat(filepath.Join(filepath.Dir(dir), "outside.bazelrc")); !os.IsNotExist(statErr) {
		t.Fatalf("outside .bazelrc was written, statErr=%v", statErr)
	}
}

func TestWriteBazelrcBlockAllowsAbsolutePathInsideWorkspace(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tools", "test-optimization.bazelrc")
	if err := writeBazelrcBlock(config{
		workspaceDir:  dir,
		bazelrcPath:   path,
		bazelrcConfig: "test-optimization",
	}); err != nil {
		t.Fatalf("writeBazelrcBlock error: %v", err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read managed bazelrc: %v", err)
	}
	if !strings.Contains(string(content), bazelrcBlockStart) {
		t.Fatalf("expected managed block in absolute workspace path:\n%s", content)
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

func TestBootstrapSyncCommandsTargetedModeAvoidsGoModTidy(t *testing.T) {
	cfg := config{
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersion:   "v2.9.0-dev.0.20260416093245-194346a71c51",
		goModSync:          "targeted",
	}

	got := bootstrapSyncCommands(cfg)
	if len(got) < 3 {
		t.Fatalf("bootstrapSyncCommands returned too few commands: %#v", got)
	}
	if strings.Join(got[0], " ") != "mod edit -require=github.com/DataDog/orchestrion@v1.9.0" {
		t.Fatalf("first bootstrap sync command=%q, want orchestrion version pin", strings.Join(got[0], " "))
	}
	joined := strings.Join(flattenCommands(got), "\n")
	if strings.Contains(joined, "mod tidy") {
		t.Fatalf("targeted bootstrap sync must not run go mod tidy:\n%s", joined)
	}
	if !strings.Contains(joined, "list -mod=mod -tags=tools github.com/DataDog/orchestrion") {
		t.Fatalf("targeted bootstrap sync must resolve the Orchestrion tool graph:\n%s", joined)
	}
	if !strings.Contains(joined, "list -mod=readonly -tags=tools github.com/DataDog/orchestrion") {
		t.Fatalf("targeted bootstrap sync must verify readonly module completeness:\n%s", joined)
	}
}

func TestBootstrapSyncCommandsDefaultsToTargetedMode(t *testing.T) {
	cfg := config{
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersion:   "v2.9.0-dev.0.20260416093245-194346a71c51",
	}

	joined := strings.Join(flattenCommands(bootstrapSyncCommands(cfg)), "\n")
	if strings.Contains(joined, "mod tidy") {
		t.Fatalf("default bootstrap sync must not run go mod tidy:\n%s", joined)
	}
	if !strings.Contains(joined, "list -mod=readonly -tags=tools") {
		t.Fatalf("default bootstrap sync must use targeted readonly verification:\n%s", joined)
	}
}

func TestBootstrapSyncCommandsTidyModeKeepsExplicitGoModTidy(t *testing.T) {
	cfg := config{
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersion:   "v2.9.0-dev.0.20260416093245-194346a71c51",
		goModSync:          "tidy",
	}

	joined := strings.Join(flattenCommands(bootstrapSyncCommands(cfg)), "\n")
	if !strings.Contains(joined, "mod tidy") {
		t.Fatalf("tidy bootstrap sync must keep explicit go mod tidy:\n%s", joined)
	}
}

func TestBootstrapSyncCommandsOffModeSkipsGoCommands(t *testing.T) {
	cfg := config{
		orchestrionVersion: "v1.9.0",
		ddTraceGoVersion:   "v2.9.0-dev.0.20260416093245-194346a71c51",
		goModSync:          "off",
	}

	if got := bootstrapSyncCommands(cfg); len(got) != 0 {
		t.Fatalf("off bootstrap sync returned commands: %#v", got)
	}
}

func TestValidateGoModSyncModeRejectsUnknownValue(t *testing.T) {
	if err := validateGoModSyncMode("broad"); err == nil {
		t.Fatal("expected unknown go module sync mode to fail")
	}
}

func TestValidateGoBinaryRejectsShellStyleCommand(t *testing.T) {
	for _, value := range []string{
		"go test",
		" go",
		"go ",
		"go\t",
		"bash",
	} {
		if err := validateGoBinary(value); err == nil {
			t.Fatalf("expected --go-binary=%q to fail validation", value)
		}
	}
}

func TestValidateGoBinaryAcceptsGoExecutableName(t *testing.T) {
	for _, value := range []string{"go", filepath.Join("custom", "bin", "go"), filepath.Join("custom", "bin", "go.exe")} {
		if err := validateGoBinary(value); err != nil {
			t.Fatalf("expected --go-binary=%q to pass validation: %v", value, err)
		}
	}
}

func TestSyncDDTraceGoVersionHonorsCustomGoBinary(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	dir := t.TempDir()
	logPath := filepath.Join(dir, "go-args.log")
	goPath := writeFakeGoTool(t, `#!/bin/sh
printf '%s\n' "$*" >> "`+logPath+`"
exit 0
`)
	cfg := config{
		goBinary:            goPath,
		goModuleDir:         dir,
		goModSync:           "targeted",
		orchestrionVersion:  "v1.9.0",
		ddTraceGoVersion:    "v2.9.0-dev.0.20260416093245-194346a71c51",
		ddTraceGoVersions:   nil,
		ddTraceGoVersionSet: true,
	}

	if err := syncDDTraceGoVersion(cfg); err != nil {
		t.Fatalf("syncDDTraceGoVersion error: %v", err)
	}

	content, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read fake go log: %v", err)
	}
	text := string(content)
	if !strings.Contains(text, "list -mod=readonly -tags=tools") {
		t.Fatalf("custom go binary did not receive readonly verification command:\n%s", text)
	}
}

func TestSyncDDTraceGoVersionReadonlyFailureMentionsTargetedSync(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell-script based helper test is Unix-only")
	}
	dir := t.TempDir()
	goPath := writeFakeGoTool(t, `#!/bin/sh
case "$*" in
  *"list -mod=readonly -tags=tools"*)
    echo "readonly module graph is incomplete" >&2
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
`)
	cfg := config{
		goBinary:            goPath,
		goModuleDir:         dir,
		goModSync:           "targeted",
		orchestrionVersion:  "v1.9.0",
		ddTraceGoVersion:    "v2.9.0-dev.0.20260416093245-194346a71c51",
		ddTraceGoVersionSet: true,
	}

	err := syncDDTraceGoVersion(cfg)
	if err == nil {
		t.Fatal("expected readonly verification failure")
	}
	text := err.Error()
	if !strings.Contains(text, "--go-mod-sync=targeted") {
		t.Fatalf("expected targeted sync hint in error, got:\n%s", text)
	}
	if !strings.Contains(text, "go_repository") {
		t.Fatalf("expected go_repository refresh hint in error, got:\n%s", text)
	}
}

func flattenCommands(commands [][]string) []string {
	flattened := make([]string, 0, len(commands))
	for _, command := range commands {
		flattened = append(flattened, strings.Join(command, " "))
	}
	return flattened
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

func TestParseGoRepositoryDeclarations(t *testing.T) {
	content := `
go_repository(
    name = "com_github_datadog_orchestrion",
    importpath = "github.com/DataDog/orchestrion",
    version = "v1.9.0",
)

go_repository(
    name = 'com_github_datadog_dd_trace_go_v2',
    importpath = 'github.com/DataDog/dd-trace-go/v2',
    version = 'v2.9.0-dev.0.20260416093245-194346a71c51',
)
`
	got := parseGoRepositoryDeclarations(content)
	if got["github.com/DataDog/orchestrion"].version != "v1.9.0" {
		t.Fatalf("unexpected orchestrion declaration: %#v", got)
	}
	if got["github.com/DataDog/dd-trace-go/v2"].name != "com_github_datadog_dd_trace_go_v2" {
		t.Fatalf("unexpected dd-trace-go declaration: %#v", got)
	}
}

func TestParseGoRepositoryDeclarationsIgnoresCommentedBlocks(t *testing.T) {
	content := `
# go_repository(
#     name = "com_github_datadog_orchestrion",
#     importpath = "github.com/DataDog/orchestrion",
#     version = "v9.9.9",
# )

go_repository(
    name = "com_github_datadog_orchestrion",
    importpath = "github.com/DataDog/orchestrion",  # active declaration
    version = "v1.9.0",
)
`
	got := parseGoRepositoryDeclarations(content)
	if got["github.com/DataDog/orchestrion"].version != "v1.9.0" {
		t.Fatalf("commented declaration should be ignored: %#v", got)
	}
}

func TestCheckGoRepositoriesAcceptsMatchingVersions(t *testing.T) {
	dir := t.TempDir()
	writeRepositoriesFile(t, filepath.Join(dir, "repositories.bzl"), map[string]string{
		"github.com/DataDog/orchestrion":                     "v1.9.0",
		"github.com/DataDog/dd-trace-go/v2":                  "v2.9.0-dev.0.20260416093245-194346a71c51",
		"github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.9.0-dev.0.20260416093245-194346a71c51",
		"github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.9.0-dev.0.20260416093245-194346a71c51",
	})
	cfg := goRepositoryDiagnosticsTestConfig(dir)
	if err := checkGoRepositories(cfg, false); err != nil {
		t.Fatalf("checkGoRepositories error: %v", err)
	}
}

func TestCheckGoRepositoriesRejectsStaleVersionWithActionableMessage(t *testing.T) {
	dir := t.TempDir()
	writeRepositoriesFile(t, filepath.Join(dir, "repositories.bzl"), map[string]string{
		"github.com/DataDog/orchestrion":                     "v1.8.0",
		"github.com/DataDog/dd-trace-go/v2":                  "v2.9.0-dev.0.20260416093245-194346a71c51",
		"github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.9.0-dev.0.20260416093245-194346a71c51",
		"github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.9.0-dev.0.20260416093245-194346a71c51",
	})
	cfg := goRepositoryDiagnosticsTestConfig(dir)
	err := checkGoRepositories(cfg, false)
	if err == nil {
		t.Fatal("expected stale go_repository declaration to fail")
	}
	text := err.Error()
	for _, want := range []string{
		"github.com/DataDog/orchestrion",
		"v1.8.0",
		"v1.9.0",
		"--go-repositories-refresh-command",
		"go_repository(",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("diagnostics missing %q:\n%s", want, text)
		}
	}
}

func TestCheckGoRepositoriesRejectsMissingModule(t *testing.T) {
	dir := t.TempDir()
	writeRepositoriesFile(t, filepath.Join(dir, "repositories.bzl"), map[string]string{
		"github.com/DataDog/orchestrion": "v1.9.0",
	})
	cfg := goRepositoryDiagnosticsTestConfig(dir)
	err := checkGoRepositories(cfg, false)
	if err == nil {
		t.Fatal("expected missing go_repository declarations to fail")
	}
	if !strings.Contains(err.Error(), "github.com/DataDog/dd-trace-go/v2 is missing") {
		t.Fatalf("expected missing module diagnostic, got:\n%s", err)
	}
}

func TestCheckGoRepositoriesRefreshHookRepairsStaleFile(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell refresh command test is Unix-only")
	}
	dir := t.TempDir()
	repositoriesPath := filepath.Join(dir, "repositories.bzl")
	writeRepositoriesFile(t, repositoriesPath, map[string]string{
		"github.com/DataDog/orchestrion":                     "v1.8.0",
		"github.com/DataDog/dd-trace-go/v2":                  "v2.8.0",
		"github.com/DataDog/dd-trace-go/contrib/net/http/v2": "v2.8.0",
		"github.com/DataDog/dd-trace-go/contrib/log/slog/v2": "v2.8.0",
	})
	refreshPath := filepath.Join(dir, "refresh.sh")
	if err := os.WriteFile(refreshPath, []byte(`#!/bin/sh
cat > repositories.bzl <<'EOF'
go_repository(name = "com_github_datadog_orchestrion", importpath = "github.com/DataDog/orchestrion", version = "v1.9.0")
go_repository(name = "com_github_datadog_dd_trace_go_v2", importpath = "github.com/DataDog/dd-trace-go/v2", version = "v2.9.0-dev.0.20260416093245-194346a71c51")
go_repository(name = "com_github_datadog_dd_trace_go_contrib_net_http_v2", importpath = "github.com/DataDog/dd-trace-go/contrib/net/http/v2", version = "v2.9.0-dev.0.20260416093245-194346a71c51")
go_repository(name = "com_github_datadog_dd_trace_go_contrib_log_slog_v2", importpath = "github.com/DataDog/dd-trace-go/contrib/log/slog/v2", version = "v2.9.0-dev.0.20260416093245-194346a71c51")
EOF
`), 0o755); err != nil {
		t.Fatalf("write refresh hook: %v", err)
	}
	cfg := goRepositoryDiagnosticsTestConfig(dir)
	cfg.goRepositoriesRefreshCommand = "./refresh.sh"
	if err := checkGoRepositories(cfg, true); err != nil {
		t.Fatalf("refresh hook should repair stale repositories: %v", err)
	}
}

func TestCheckGoRepositoriesDoesNotRunRefreshWithoutTargetedSync(t *testing.T) {
	dir := t.TempDir()
	writeRepositoriesFile(t, filepath.Join(dir, "repositories.bzl"), map[string]string{
		"github.com/DataDog/orchestrion": "v1.8.0",
	})
	cfg := goRepositoryDiagnosticsTestConfig(dir)
	cfg.goRepositoriesRefreshCommand = "echo should-not-run > marker"
	err := checkGoRepositories(cfg, false)
	if err == nil {
		t.Fatal("expected stale repositories without targeted sync to fail")
	}
	if !strings.Contains(err.Error(), "only runs after a successful --go-mod-sync=targeted") {
		t.Fatalf("expected targeted sync guard, got:\n%s", err)
	}
	if _, statErr := os.Stat(filepath.Join(dir, "marker")); !os.IsNotExist(statErr) {
		t.Fatalf("refresh command should not have run, stat err=%v", statErr)
	}
}

func TestGoRepositoryNameUsesGazelleStyleReversedDomain(t *testing.T) {
	got := goRepositoryName("github.com/DataDog/dd-trace-go/contrib/net/http/v2")
	want := "com_github_datadog_dd_trace_go_contrib_net_http_v2"
	if got != want {
		t.Fatalf("goRepositoryName=%q, want %q", got, want)
	}
}

func goRepositoryDiagnosticsTestConfig(dir string) config {
	return config{
		workspaceDir:        dir,
		goRepositoriesFile:  "repositories.bzl",
		checkGoRepositories: true,
		orchestrionVersion:  "v1.9.0",
		ddTraceGoVersion:    "v2.9.0-dev.0.20260416093245-194346a71c51",
		ddTraceGoVersions:   nil,
		ddTraceGoVersionSet: true,
	}
}

func writeRepositoriesFile(t *testing.T, path string, versions map[string]string) {
	t.Helper()
	var buf strings.Builder
	for _, modulePath := range requiredGoRepositoryImportpaths() {
		version, ok := versions[modulePath]
		if !ok {
			continue
		}
		fmt.Fprintf(&buf, "go_repository(\n    name = %q,\n    importpath = %q,\n    version = %q,\n)\n\n", goRepositoryName(modulePath), modulePath, version)
	}
	if err := os.WriteFile(path, []byte(buf.String()), 0o644); err != nil {
		t.Fatalf("write repositories file: %v", err)
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

func publishedPinsTestRepo(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	for _, variant := range []string{"base", "complete"} {
		if err := os.MkdirAll(filepath.Join(dir, "third_party", "rules_go_orchestrion_"+variant), 0o755); err != nil {
			t.Fatalf("create variant dir: %v", err)
		}
	}
	runGitCommand(t, dir, "init", ".")
	runGitCommand(t, dir, "config", "user.email", "test@example.com")
	runGitCommand(t, dir, "config", "user.name", "Test User")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("main\n"), 0o644); err != nil {
		t.Fatalf("write README: %v", err)
	}
	runGitCommand(t, dir, "add", ".")
	runGitCommand(t, dir, "commit", "-m", "main")
	commit := strings.TrimSpace(runGitCommand(t, dir, "rev-parse", "HEAD"))
	runGitCommand(t, dir, "update-ref", "refs/remotes/origin/main", commit)
	return dir, commit
}

func runGitCommand(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s failed: %v\n%s", strings.Join(args, " "), err, output)
	}
	return strings.TrimSpace(string(output))
}

func staticArchiveFetcher(body string) onboardingpins.ArchiveFetcher {
	return func(context.Context, string) (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewBufferString(body)), nil
	}
}
