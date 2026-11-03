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
	"os/exec"
	"path/filepath"
	"regexp"
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

func shellPwdPath(t *testing.T, dir string, elems ...string) string {
	t.Helper()
	cmd := exec.Command("bash", "-c", "pwd -P")
	cmd.Dir = dir
	output, err := cmd.Output()
	if err != nil {
		t.Fatalf("resolve bash pwd for %s: %v", dir, err)
	}
	parts := append([]string{strings.TrimSpace(string(output))}, elems...)
	return strings.Join(parts, "/")
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

func TestReplaceManagedSectionPreservesSurroundingTextOnRerun(t *testing.T) {
	for _, suffix := range []string{"", "\n", "\n\n# Other settings\n"} {
		block := "# BEGIN\nowned = True\n# END\n"
		input := "# Existing header\n" + block + suffix
		first, err := replaceManagedSection(input, "# BEGIN", "# END", block)
		if err != nil || first != input {
			t.Fatalf("managed newline replacement changed surrounding text: %v\n%q -> %q", err, input, first)
		}
	}
}

func TestTopLevelCallSpansIgnoreQuotedAndCommentedDelimiters(t *testing.T) {
	for _, value := range []string{`"https://mirror.example/file)#asset"`, "\"\"\"first )\nsecond (\nend\"\"\"", `'escaped \' ) # text'`} {
		input := "# λ before a call(\n" + "archive_override(\n    urls = [" + value + "], # ) ( \"\n)\n" + "bazel_dep(name = \"keep\", version = \"1\")\n"
		blocks := topLevelCallBlocks(input)
		if len(blocks) != 2 || blocks[0].function != "archive_override" || blocks[1].function != "bazel_dep" {
			t.Fatalf("incorrect call spans for %q: %#v", value, blocks)
		}
		if input[blocks[0].start:blocks[0].end] != "archive_override(\n    urls = ["+value+"], # ) ( \"\n)\n" {
			t.Fatalf("scanner did not preserve original byte offsets for %q", value)
		}
	}
}

func TestManagedModuleBlockConfiguresInstrumentedSDK(t *testing.T) {
	got, err := managedModuleBlock(config{runtimeVersion: "1.25.0"})
	if err != nil {
		t.Fatalf("managedModuleBlock error: %v", err)
	}
	want := managedBlockStart + `
topt_go_ddtest = use_extension(
    "@datadog-rules-test-optimization-go//:topt_go_ddtest_extension.bzl",
    "topt_go_ddtest",
)
topt_go_ddtest.sdk(go_version = "1.25.0")
` + managedBlockEnd + "\n"
	if got != want {
		t.Fatalf("managedModuleBlock=\n%s\nwant\n%s", got, want)
	}
}

func TestManagedModuleBlockWithoutRuntimeVersionReadsGoMod(t *testing.T) {
	dir := t.TempDir()
	for goModuleDir, want := range map[string]string{
		dir:                                      `topt_go_ddtest.sdk(go_mod = "//:go.mod")`,
		filepath.Join(dir, "services", "worker"): `topt_go_ddtest.sdk(go_mod = "//services/worker:go.mod")`,
	} {
		if err := os.MkdirAll(goModuleDir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", goModuleDir, err)
		}
		if err := os.WriteFile(filepath.Join(goModuleDir, "BUILD"), nil, 0o644); err != nil {
			t.Fatalf("write BUILD: %v", err)
		}
		got, err := managedModuleBlock(config{workspaceDir: dir, goModuleDir: goModuleDir})
		if err != nil {
			t.Fatalf("managedModuleBlock(%s) error: %v", goModuleDir, err)
		}
		if !strings.Contains(got, want) {
			t.Fatalf("managedModuleBlock(%s) missing %q:\n%s", goModuleDir, want, got)
		}
	}
	if _, err := managedModuleBlock(config{workspaceDir: dir, goModuleDir: filepath.Dir(dir)}); err == nil || !strings.Contains(err.Error(), "must be inside workspace") {
		t.Fatalf("managedModuleBlock error=%v, want outside-workspace rejection", err)
	}
}

func TestManagedModuleBlockWithoutRuntimeVersionNeedsGoModPackage(t *testing.T) {
	dir := t.TempDir()
	_, err := managedModuleBlock(config{workspaceDir: dir, goModuleDir: dir})
	if err == nil || !strings.Contains(err.Error(), "needs a BUILD file next to go.mod") {
		t.Fatalf("managedModuleBlock error=%v, want missing BUILD file", err)
	}
	if _, err := managedModuleBlock(config{workspaceDir: dir, goModuleDir: dir, runtimeVersion: "1.25.0"}); err != nil {
		t.Fatalf("managedModuleBlock with --runtime-version error: %v", err)
	}
}

func TestWorkspaceSnippetWiresUpstreamRulesGoAndDdtest(t *testing.T) {
	cfg := config{
		rtoCommit:       "published-sha",
		datadogFetch:    "git",
		rulesGoRepoName: "io_bazel_rules_go",
		runtimeVersion:  "1.25.0",
	}
	got, err := workspaceSnippet(cfg)
	if err != nil {
		t.Fatalf("workspaceSnippet error: %v", err)
	}
	ordered := []string{
		`# http_archive(
#     name = "io_bazel_rules_go",`,
		`git_repository(
    name = "datadog-rules-test-optimization",
    commit = "published-sha",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
)`,
		`datadog_go_test_optimization_workspace_repositories(
    rto_commit = "published-sha",
    rto_remote = "https://github.com/DataDog/rules_test_optimization.git",
    datadog_fetch = "git",
    rules_go_repo_name = "io_bazel_rules_go",
)`,
		`load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")`,
		"\ngo_rules_dependencies()\n",
		`go_register_toolchains(version = "1.25.0")`,
		`load("@datadog-rules-test-optimization-go//:topt_go_ddtest_repository.bzl", "topt_go_ddtest_workspace_repositories")`,
		`topt_go_ddtest_workspace_repositories(go_version = "1.25.0")`,
		`dd_topt_go_workspace_sync_repositories(`,
	}
	last := -1
	for _, want := range ordered {
		index := strings.Index(got, want)
		if index < 0 {
			t.Fatalf("workspace snippet missing %q:\n%s", want, got)
		}
		if index < last {
			t.Fatalf("workspace snippet has %q out of order:\n%s", want, got)
		}
		last = index
	}
	for _, removed := range []string{"orchestrion", "rules_go_fetch", "rules_go_upstream", "rules_go_variant", "dd_trace_go", "go_sdk_root"} {
		if strings.Contains(got, removed) {
			t.Fatalf("workspace snippet still contains %q:\n%s", removed, got)
		}
	}
}

func TestWorkspaceSnippetArchiveMode(t *testing.T) {
	cfg := config{
		datadogFetch:     "archive",
		rulesGoRepoName:  "io_bazel_rules_go",
		rtoArchiveURL:    "https://example.test/archive.tar.gz",
		rtoArchiveSHA256: strings.Repeat("0", 64),
		rtoArchivePrefix: "rules_test_optimization-published-sha",
		rtoArchiveType:   "tar.gz",
	}
	got, err := workspaceSnippet(cfg)
	if err != nil {
		t.Fatalf("workspaceSnippet error: %v", err)
	}
	for _, want := range []string{
		`http_archive(
    name = "datadog-rules-test-optimization",
    urls = ["https://example.test/archive.tar.gz"],`,
		`datadog_fetch = "archive"`,
		`rto_archive_url = "https://example.test/archive.tar.gz"`,
		`rto_archive_prefix = "rules_test_optimization-published-sha"`,
		`rto_archive_type = "tar.gz"`,
		`topt_go_ddtest_workspace_repositories(go_version = "<go-version>")`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("workspace snippet missing %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "git_repository(\n") {
		t.Fatalf("archive workspace snippet declares a git_repository:\n%s", got)
	}
	cfg.rtoArchiveSHA256 = ""
	if _, err := workspaceSnippet(cfg); err == nil || !strings.Contains(err.Error(), "--rto-archive-sha256") {
		t.Fatalf("workspaceSnippet error=%v, want missing archive flag", err)
	}
}

func TestWorkspaceSnippetRequiresRTOCommitForGit(t *testing.T) {
	_, err := workspaceSnippet(config{datadogFetch: "git", rulesGoRepoName: "io_bazel_rules_go"})
	if err == nil || !strings.Contains(err.Error(), "--rto-commit is required when --datadog-fetch is git") {
		t.Fatalf("workspaceSnippet error=%v, want missing --rto-commit", err)
	}
}

func TestWorkspaceSnippetDoesNotRequireModuleFiles(t *testing.T) {
	cfg := config{
		rtoCommit:       "published-sha",
		datadogFetch:    "git",
		rulesGoRepoName: "io_bazel_rules_go",
	}
	if _, err := workspaceSnippet(cfg); err != nil {
		t.Fatalf("workspaceSnippet should not inspect MODULE.bazel or go.mod: %v", err)
	}
}

func TestWorkspaceModeSnippetIncludesSync(t *testing.T) {
	cfg := config{
		workspaceMode:        true,
		rtoCommit:            "published-sha",
		datadogFetch:         "git",
		rulesGoRepoName:      "io_bazel_rules_go",
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
		`rules_go_repo_name = "io_bazel_rules_go"`,
		`load("@datadog-rules-test-optimization-go//:topt_go_workspace.bzl", "dd_topt_go_workspace_sync_repositories")`,
		`dd_topt_go_workspace_sync_repositories(`,
		`name = "test_optimization_data_worker"`,
		`service = "worker"`,
		`runtime_version = "1.25.9"`,
		`go_register_toolchains(version = "1.25.9")`,
		`topt_go_ddtest_workspace_repositories(go_version = "1.25.9")`,
		`require_git_metadata = True`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("workspace mode snippet missing %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "consumer-internal-name") {
		t.Fatalf("workspace mode snippet must stay generic:\n%s", got)
	}
}

func TestRunWorkspaceModeWritesSelectedFilesWithoutModuleBazel(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		workspaceDir:         dir,
		goModuleDir:          dir,
		workspaceMode:        true,
		writeRootTargets:     true,
		writeWrapperTemplate: true,
		writeBazelrc:         true,
		bazelrcPath:          ".bazelrc",
		bazelrcConfig:        "test-optimization-worker",
		syncRepoName:         "test_optimization_data_worker",
		doctorTargetName:     "dd_test_optimization_doctor",
		uploaderTargetName:   "dd_upload_payloads",
		expectedTargets:      []string{"//worker:go_default_test"},
		wrapperPackage:       "rules/go",
		wrapperFile:          "dd_topt_go_test.bzl",
		plainWrapperName:     "dd_go_test",
		optimizedWrapperName: "dd_topt_go_test",
		rulesGoRepoName:      "io_bazel_rules_go",
		datadogFetch:         defaultDatadogFetch,
	}
	if err := run(cfg); err != nil {
		t.Fatalf("run workspace mode error: %v", err)
	}
	for _, path := range []string{
		"BUILD.bazel",
		".bazelrc",
		"rules/go/BUILD.bazel",
		"rules/go/dd_topt_go_test.bzl",
	} {
		if _, err := os.Stat(filepath.Join(dir, path)); err != nil {
			t.Fatalf("expected %s: %v", path, err)
		}
	}
	for _, path := range []string{"orchestrion.tool.go", "orchestrion.yml"} {
		if _, err := os.Stat(filepath.Join(dir, path)); !os.IsNotExist(err) {
			t.Fatalf("workspace mode wrote %s: %v", path, err)
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
		`def dd_go_test(name, **kwargs):`,
		`dd_topt_go_test = dd_go_test`,
		`load("@test_optimization_data_worker//:export.bzl", "topt_data")`,
		`topt_data = topt_data,`,
	} {
		if !strings.Contains(wrapperText, want) {
			t.Fatalf("workspace wrapper missing %q:\n%s", want, wrapperText)
		}
	}
	for _, forbidden := range []string{
		"consumer-internal-name",
		"orchestrion",
		"--test_env=DD_GIT_",
		`load("@io_bazel_rules_go//go:def.bzl", _raw_go_test = "go_test")`,
		`def dd_topt_go_test(name, **kwargs):`,
	} {
		if strings.Contains(wrapperText, forbidden) {
			t.Fatalf("workspace wrapper contains forbidden %q:\n%s", forbidden, wrapperText)
		}
	}
	if got := strings.Count(wrapperText, "_raw_dd_topt_go_test,"); got != 1 {
		t.Fatalf("workspace wrapper should have one Test Optimization call path, got %d:\n%s", got, wrapperText)
	}
}

func TestWorkspaceModeRequiresAnAction(t *testing.T) {
	err := run(config{
		workspaceDir:  t.TempDir(),
		workspaceMode: true,
		datadogFetch:  defaultDatadogFetch,
		syncRepoName:  defaultSyncRepoName,
	})
	if err == nil || !strings.Contains(err.Error(), "--workspace-mode requires at least one action") {
		t.Fatalf("run error=%v, want missing workspace-mode action", err)
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
	for _, want := range []string{
		`def plain_go_test(name, **kwargs):`,
		`optimized_go_test = plain_go_test`,
	} {
		if !strings.Contains(string(first), want) {
			t.Fatalf("workspace wrapper missing %q:\n%s", want, first)
		}
	}
	if strings.Contains(string(first), "orchestrion") {
		t.Fatalf("workspace wrapper still passes Orchestrion attributes:\n%s", first)
	}
	if strings.Contains(string(first), `_raw_go_test`) {
		t.Fatalf("workspace wrapper must not bypass config-gated dispatch:\n%s", first)
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
		`common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1`,
		`test:test-optimization --remote_download_minimal`,
		`test:test-optimization --remote_download_regex=.*test[.]outputs.*`,
		`test:test-optimization --zip_undeclared_test_outputs`,
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
			rulesGoRepoName:     defaultRulesGoRepoName,
			syncRepoName:        defaultSyncRepoName,
			doctorTargetName:    defaultDoctorTargetName,
			uploaderTargetName:  defaultUploaderTargetName,
		})
	}); err != nil {
		t.Fatalf("run --print-bazelrc-snippet error: %v", err)
	}
	if got := buf.String(); !strings.Contains(got, `test:test-optimization --remote_download_minimal`) {
		t.Fatalf("expected bazelrc snippet on stdout:\n%s", got)
	}
}

func TestRunPrintBazelrcSnippetUsesSelectiveRemoteDownloads(t *testing.T) {
	dir := t.TempDir()
	var buf strings.Builder
	if err := captureStdout(&buf, func() error {
		return run(config{
			workspaceDir:        dir,
			printBazelrcSnippet: true,
			bazelrcConfig:       "test-optimization",
			datadogFetch:        defaultDatadogFetch,
			rulesGoRepoName:     defaultRulesGoRepoName,
			syncRepoName:        defaultSyncRepoName,
			doctorTargetName:    defaultDoctorTargetName,
			uploaderTargetName:  defaultUploaderTargetName,
		})
	}); err != nil {
		t.Fatalf("run --print-bazelrc-snippet error: %v", err)
	}
	got := buf.String()
	for _, want := range []string{
		`test:test-optimization --remote_download_minimal`,
		`test:test-optimization --remote_download_regex=.*test[.]outputs.*`,
		`test:test-optimization --zip_undeclared_test_outputs`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("expected bazelrc snippet to contain %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, `--remote_download_outputs=all`) {
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
			publishedPinsArchiveFetcher: staticArchiveFetcher("archive bytes"),
		})
	}); err != nil {
		t.Fatalf("run --print-published-pins error: %v", err)
	}
	got := buf.String()
	for _, want := range []string{
		`RTO_COMMIT="` + commit + `"`,
		`RTO_ARCHIVE_URL="https://codeload.github.com/DataDog/rules_test_optimization/tar.gz/` + commit + `"`,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("published pins missing %q:\n%s", want, got)
		}
	}
	for _, removed := range []string{"RULES_GO_", "ORCHESTRION", "DD_TRACE_GO"} {
		if strings.Contains(got, removed) {
			t.Fatalf("published pins still print %q:\n%s", removed, got)
		}
	}
}

func TestRunPrintPublishedPinsRequiresRTOCommit(t *testing.T) {
	err := run(config{
		workspaceDir:       t.TempDir(),
		printPublishedPins: true,
		datadogFetch:       defaultDatadogFetch,
	})
	if err == nil || !strings.Contains(err.Error(), "published pins require --rto-commit") {
		t.Fatalf("run --print-published-pins error=%v, want missing --rto-commit", err)
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
		rulesGoRepoName:        defaultRulesGoRepoName,
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
		`WORKSPACE_DIR="$(pwd -P)"`,
		`BEP_TMP_ROOT=""`,
		`BEP_JSON_DIR=""`,
		`ARTIFACT_STAGING_DIR=""`,
		`REPORT_DIR="${DD_TEST_OPTIMIZATION_REPORT_DIR:-}"`,
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
		`--build_event_json_file=${bep_json_path}`,
		`--bep-json=${bep_json_path}`,
		`--freshness-source=bep`,
		`--freshness-mode=required`,
		`--artifact-source=bep`,
		`--artifact-staging-dir=${ARTIFACT_STAGING_DIR}`,
		`doctor-report.json`,
		`uploader-report.json`,
		`--report-json`,
		`mktemp -d "${tmp_parent%/}/dd-go-topt.XXXXXX"`,
		`sync -> controls -> instrumented tests -> doctor -> validated uploader`,
		`validate ordinary no-config bootstrap`,
		`validate explicit disabled precedence`,
		`query "@${SYNC_REPO}//:test_optimization_files"`,
		`--repo_env=DD_TEST_OPTIMIZATION_ENABLED=0`,
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
		`RULES_GO_ORCHESTRION_PACKAGE`,
		`cquery`,
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
			rulesGoRepoName:        defaultRulesGoRepoName,
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
	cmd.Dir = dir
	tmpParent := filepath.Join(dir, "tmp")
	cmd.Env = append(os.Environ(), "BAZEL_LOG="+logPath, "DD_TEST_OPTIMIZATION_TMPDIR="+tmpParent)
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
		"query @test_optimization_data//:test_optimization_files",
		"query --config=test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=0 @test_optimization_data//:test_optimization_files",
		"sync --config=test-optimization --repo_env=FETCH_SALT=",
		"test --config=test-optimization --build_event_json_file=",
		"//pkg:go_default_test",
		"run --config=test-optimization //:dd_test_optimization_doctor -- --bep-json=",
		"--report-json=",
		"--freshness-source=bep --freshness-mode=required --artifact-source=bep --artifact-staging-dir=",
		"run --config=test-optimization //:dd_upload_payloads -- --bep-json=",
		"--dry-run --validate-enrichment",
	} {
		if !strings.Contains(logText, want) {
			t.Fatalf("fake bazel log missing %q:\n%s\nscript output:\n%s", want, logText, output)
		}
	}
	if strings.Contains(logText, "cquery") {
		t.Fatalf("validation script still checks the Orchestrion alias:\n%s", logText)
	}
	if strings.Contains(logText, filepath.Join(dir, ".topt", "bep")) {
		t.Fatalf("validation script reused the workspace .topt BEP directory:\n%s", logText)
	}
	if strings.Contains(logText, "run --config=test-optimization //:dd_upload_payloads") && !strings.Contains(logText, "--dry-run --validate-enrichment") {
		t.Fatalf("validation script ran uploader without dry-run in --no-upload mode:\n%s", logText)
	}
}

func TestValidationScriptPassesBepFilesBeforeUpload(t *testing.T) {
	dir := t.TempDir()
	fakeBazel := filepath.Join(dir, "bazel")
	logPath := filepath.Join(dir, "bazel.log")
	fakeBazelScript := `#!/usr/bin/env bash
set -euo pipefail
	printf '%s\n' "$*" >> "$BAZEL_LOG"
	if [[ "${1:-}" == "test" ]]; then
	  bep_path=""
	  target=""
	  for arg in "$@"; do
	    case "$arg" in
	      --build_event_json_file=*)
	        bep_path="${arg#--build_event_json_file=}"
	        ;;
	      //*)
	        target="$arg"
	        ;;
	    esac
	  done
	  if [[ -z "$bep_path" ]]; then
	    echo "missing --build_event_json_file" >&2
	    exit 42
	  fi
	  mkdir -p "$(dirname "$bep_path")"
	  printf '{"id":{"testResult":{"label":"%s","run":1,"shard":1,"attempt":1}},"testResult":{"status":"PASSED","testActionOutput":[{"name":"test.outputs","uri":"file:///execroot/main/bazel-out/testlogs/%s/test.outputs"}]}}\n' "$target" "${target//[^A-Za-z0-9_.-]/_}" > "$bep_path"
	fi
	`
	if err := os.WriteFile(fakeBazel, []byte(fakeBazelScript), 0o755); err != nil {
		t.Fatalf("write fake bazel: %v", err)
	}

	script, err := validationScript(config{
		printValidationScript:  true,
		bazelCommand:           fakeBazel,
		bazelConfig:            "test-optimization",
		syncRepoName:           defaultSyncRepoName,
		validationDoctorTarget: "//:dd_test_optimization_doctor",
		validationUploadTarget: "//:dd_upload_payloads",
		controlTargets:         []string{"//control:go_default_test"},
		expectedTargets:        []string{"//pkg:one_test", "//pkg:two_test"},
		minFreeDiskGB:          defaultMinFreeDiskGB,
	})
	if err != nil {
		t.Fatalf("validationScript error: %v", err)
	}
	scriptPath := filepath.Join(dir, "validate.sh")
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write validation script: %v", err)
	}

	cmd := exec.Command("bash", scriptPath, "--upload")
	cmd.Dir = dir
	tmpParent := filepath.Join(dir, "tmp")
	cmd.Env = append(os.Environ(), "BAZEL_LOG="+logPath, "DD_TEST_OPTIMIZATION_TMPDIR="+tmpParent, "DD_TEST_OPTIMIZATION_KEEP_TMP=1")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("validation script failed: %v\n%s", err, output)
	}

	logBytes, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read fake bazel log: %v", err)
	}
	logText := string(logBytes)
	bepByTarget := map[string]string{}
	for _, match := range regexp.MustCompile(`test --config=test-optimization --build_event_json_file=([^ ]+) (//[^ \n]+)`).FindAllStringSubmatch(logText, -1) {
		bepByTarget[match[2]] = match[1]
	}
	controlBEPPath := bepByTarget["//control:go_default_test"]
	oneBEPPath := bepByTarget["//pkg:one_test"]
	twoBEPPath := bepByTarget["//pkg:two_test"]
	if controlBEPPath == "" || oneBEPPath == "" || twoBEPPath == "" {
		t.Fatalf("could not extract all BEP paths from fake bazel log:\n%s", logText)
	}
	for _, bepPath := range []string{controlBEPPath, oneBEPPath, twoBEPPath} {
		if !strings.HasPrefix(bepPath, tmpParent) {
			t.Fatalf("BEP path %q does not use configured temporary parent %q", bepPath, tmpParent)
		}
	}
	for _, want := range []string{
		"test --config=test-optimization --build_event_json_file=" + controlBEPPath + " //control:go_default_test",
		"test --config=test-optimization --build_event_json_file=" + oneBEPPath + " //pkg:one_test",
		"test --config=test-optimization --build_event_json_file=" + twoBEPPath + " //pkg:two_test",
		"run --config=test-optimization //:dd_test_optimization_doctor -- --bep-json=" + controlBEPPath + " --bep-json=" + oneBEPPath + " --bep-json=" + twoBEPPath + " --freshness-source=bep --freshness-mode=required --artifact-source=bep --artifact-staging-dir=",
		"run --config=test-optimization //:dd_upload_payloads -- --bep-json=" + controlBEPPath + " --bep-json=" + oneBEPPath + " --bep-json=" + twoBEPPath + " --freshness-source=bep --freshness-mode=required --artifact-source=bep --artifact-staging-dir=",
		"uploader-report.json --validate-enrichment",
	} {
		if !strings.Contains(logText, want) {
			t.Fatalf("fake bazel log missing %q:\n%s\nscript output:\n%s", want, logText, output)
		}
	}
	doctorIdx := strings.Index(logText, "run --config=test-optimization //:dd_test_optimization_doctor")
	uploadIdx := strings.Index(logText, "run --config=test-optimization //:dd_upload_payloads")
	if doctorIdx < 0 || uploadIdx < 0 || uploadIdx < doctorIdx {
		t.Fatalf("upload did not run after doctor:\n%s", logText)
	}

	for _, entry := range []struct {
		path  string
		label string
	}{
		{controlBEPPath, "//control:go_default_test"},
		{oneBEPPath, "//pkg:one_test"},
		{twoBEPPath, "//pkg:two_test"},
	} {
		bepBytes, err := os.ReadFile(entry.path)
		if err != nil {
			t.Fatalf("read BEP file %s: %v", entry.path, err)
		}
		if !strings.Contains(string(bepBytes), `"label":"`+entry.label+`"`) {
			t.Fatalf("BEP file %s missing label %s:\n%s", entry.path, entry.label, bepBytes)
		}
	}
}

func TestValidationScriptUploadsAfterPartialFailures(t *testing.T) {
	dir := t.TempDir()
	fakeBazel := filepath.Join(dir, "bazel")
	logPath := filepath.Join(dir, "bazel.log")
	fakeBazelScript := `#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BAZEL_LOG"
if [[ "${1:-}" == "test" ]]; then exit 7; fi
if [[ "${1:-}" == "run" && "$*" == *"//:dd_test_optimization_doctor"* ]]; then exit 8; fi
if [[ "${1:-}" == "run" && "$*" == *"//:dd_upload_payloads"*"--dry-run"* ]]; then exit 9; fi
if [[ "${1:-}" == "run" && "$*" == *"//:dd_upload_payloads"* ]]; then exit 10; fi
exit 0
`
	if err := os.WriteFile(fakeBazel, []byte(fakeBazelScript), 0o755); err != nil {
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

	cmd := exec.Command("bash", scriptPath, "--upload")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "BAZEL_LOG="+logPath)
	output, err := cmd.CombinedOutput()
	exitErr, ok := err.(*exec.ExitError)
	if !ok || exitErr.ExitCode() != 7 {
		t.Fatalf("validation script error=%v, want test exit 7\n%s", err, output)
	}

	logBytes, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read fake bazel log: %v", err)
	}
	logText := string(logBytes)
	if got := strings.Count(logText, "run --config=test-optimization //:dd_upload_payloads"); got != 1 {
		t.Fatalf("uploader command count=%d, want one validated real upload:\n%s", got, logText)
	}
	if strings.Contains(logText, "--dry-run") ||
		!strings.Contains(logText, "uploader-report.json --validate-enrichment") {
		t.Fatalf("validation script did not run one validated real upload:\n%s", logText)
	}
}

func TestValidationScriptUsesBepArtifactSourceForZippedOutputs(t *testing.T) {
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
		extraTestFlags:         []string{"--zip_undeclared_test_outputs"},
		minFreeDiskGB:          defaultMinFreeDiskGB,
	})
	if err != nil {
		t.Fatalf("validationScript error: %v", err)
	}
	scriptPath := filepath.Join(dir, "validate.sh")
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write validation script: %v", err)
	}

	cmd := exec.Command("bash", scriptPath, "--upload")
	cmd.Dir = dir
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
		"test --config=test-optimization --zip_undeclared_test_outputs --build_event_json_file=",
		"run --config=test-optimization //:dd_test_optimization_doctor -- --bep-json=",
		"--freshness-source=bep --freshness-mode=required --artifact-source=bep",
		"run --config=test-optimization //:dd_upload_payloads -- --bep-json=",
		"uploader-report.json --validate-enrichment",
	} {
		if !strings.Contains(logText, want) {
			t.Fatalf("fake bazel log missing %q:\n%s\nscript output:\n%s", want, logText, output)
		}
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
		rulesGoRepoName:    defaultRulesGoRepoName,
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
	for _, want := range []string{
		`common:test-optimization --repo_env=DD_TEST_OPTIMIZATION_ENABLED=1`,
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("migrated managed block missing %q:\n%s", want, text)
		}
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

// orchestrionManagedBlock is a MODULE.bazel block that the Orchestrion
// bootstrap wrote, with its fork override.
func orchestrionManagedBlock(override string) string {
	return legacyManagedBlockStart + "\n" + override + `
test_optimization_go_sdk = use_extension("@rules_go//go:extensions.bzl", "go_sdk")
test_optimization_go_sdk.download(
    name = "test_optimization_go_sdk",
    version = "1.25.0",
)
use_repo(test_optimization_go_sdk, "test_optimization_go_sdk")

orchestrion = use_extension("@rules_go//go:extensions.bzl", "orchestrion")
orchestrion.from_source(
    version = "v1.12.0",
    dd_trace_go_version = "v2.9.1",
    go_sdk_root = "@test_optimization_go_sdk//:ROOT",
    go_sdk_version = "1.25.0",
)
use_repo(orchestrion, "rules_go_orchestrion_tool")
` + legacyManagedBlockEnd + "\n"
}

const orchestrionGitOverride = `git_override(
    module_name = "rules_go",
    remote = "https://github.com/DataDog/rules_test_optimization.git",
    commit = "already-published-sha",
    strip_prefix = "third_party/rgo/v0_60_0/base",
)
`

// writeModuleFile writes MODULE.bazel, go.mod and an empty root BUILD.bazel
// into a new workspace.
func writeModuleFile(t *testing.T, content string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	moduleFile := filepath.Join(dir, "MODULE.bazel")
	if err := os.WriteFile(moduleFile, []byte(content), 0o644); err != nil {
		t.Fatalf("write MODULE.bazel: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/service\n\ngo 1.25.0\n"), 0o644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "BUILD.bazel"), nil, 0o644); err != nil {
		t.Fatalf("write BUILD.bazel: %v", err)
	}
	return dir, moduleFile
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(content)
}

func TestPatchModuleFileAddsRulesGoAndDdtestBlock(t *testing.T) {
	dir, moduleFile := writeModuleFile(t, "module(name = \"example\")\n")
	cfg := config{workspaceDir: dir, goModuleDir: dir, moduleFile: moduleFile}
	if err := patchModuleFile(cfg); err != nil {
		t.Fatalf("patchModuleFile error: %v", err)
	}
	first := readFile(t, moduleFile)
	for _, want := range []string{
		`bazel_dep(name = "rules_go", version = "0.60.0")`,
		managedBlockStart,
		`topt_go_ddtest.sdk(go_mod = "//:go.mod")`,
		managedBlockEnd,
	} {
		if !strings.Contains(first, want) {
			t.Fatalf("MODULE.bazel missing %q:\n%s", want, first)
		}
	}
	if err := patchModuleFile(cfg); err != nil {
		t.Fatalf("second patchModuleFile error: %v", err)
	}
	if second := readFile(t, moduleFile); second != first {
		t.Fatalf("patchModuleFile is not idempotent:\n%s\nthen:\n%s", first, second)
	}
}

func TestPatchModuleFileReplacesOrchestrionBlock(t *testing.T) {
	archiveOverride := `archive_override(
    module_name = "rules_go",
    urls = ["https://mirror.example/source.tar.gz"],
    sha256 = "` + strings.Repeat("a", 64) + `",
    strip_prefix = "rules_test_optimization-1.3.0/third_party/rgo/v0_60_0/base",
)
`
	for name, override := range map[string]string{"git": orchestrionGitOverride, "archive": archiveOverride} {
		t.Run(name, func(t *testing.T) {
			const header = "module(name = \"example\")\n\nbazel_dep(name = \"rules_go\", version = \"0.60.0\")\n\n"
			const footer = "\nbazel_dep(name = \"keep_me\", version = \"1.0.0\")\n"
			dir, moduleFile := writeModuleFile(t, header+orchestrionManagedBlock(override)+footer)
			cfg := config{workspaceDir: dir, goModuleDir: dir, moduleFile: moduleFile, runtimeVersion: "1.25.0"}
			if err := patchModuleFile(cfg); err != nil {
				t.Fatalf("patchModuleFile error: %v", err)
			}
			block, err := managedModuleBlock(cfg)
			if err != nil {
				t.Fatalf("managedModuleBlock error: %v", err)
			}
			got := readFile(t, moduleFile)
			if got != header+block+footer {
				t.Fatalf("the ddtest block did not replace the Orchestrion block in place:\n%s", got)
			}
			if err := patchModuleFile(cfg); err != nil {
				t.Fatalf("second patchModuleFile error: %v", err)
			}
			if again := readFile(t, moduleFile); again != got {
				t.Fatalf("migration is not idempotent:\n%s\nthen:\n%s", got, again)
			}
		})
	}
}

func TestPatchModuleFileDropsOrchestrionBlockBesideDdtestBlock(t *testing.T) {
	dir, moduleFile := writeModuleFile(t, "module(name = \"example\")\n")
	cfg := config{workspaceDir: dir, goModuleDir: dir, moduleFile: moduleFile, runtimeVersion: "1.25.0"}
	block, err := managedModuleBlock(cfg)
	if err != nil {
		t.Fatalf("managedModuleBlock error: %v", err)
	}
	if err := os.WriteFile(moduleFile, []byte("module(name = \"example\")\n\n"+block+"\n"+orchestrionManagedBlock(orchestrionGitOverride)), 0o644); err != nil {
		t.Fatalf("write MODULE.bazel: %v", err)
	}
	if err := patchModuleFile(cfg); err != nil {
		t.Fatalf("patchModuleFile error: %v", err)
	}
	got := readFile(t, moduleFile)
	if strings.Contains(got, legacyManagedBlockStart) || strings.Contains(got, "orchestrion") || strings.Count(got, managedBlockStart) != 1 {
		t.Fatalf("expected only the ddtest block:\n%s", got)
	}
}

func TestPatchModuleFileKeepsOtherRulesGoOverrides(t *testing.T) {
	const override = `git_override(
    module_name = "rules_go",
    remote = "https://example.com/custom.git",
    commit = "deadbeef",
)
`
	dir, moduleFile := writeModuleFile(t, "module(name = \"example\")\n"+override)
	if err := patchModuleFile(config{workspaceDir: dir, goModuleDir: dir, moduleFile: moduleFile}); err != nil {
		t.Fatalf("patchModuleFile error: %v", err)
	}
	if got := readFile(t, moduleFile); !strings.Contains(got, override) || !strings.Contains(got, managedBlockStart) {
		t.Fatalf("expected the consumer's rules_go override and the ddtest block:\n%s", got)
	}
}

func TestPatchModuleFileRejectsRulesGoForkOutsideBlockWithoutWriting(t *testing.T) {
	for name, override := range map[string]string{
		"git":             orchestrionGitOverride,
		"legacy path":     strings.Replace(orchestrionGitOverride, "third_party/rgo/v0_60_0/base", "third_party/rules_go_orchestrion_base", 1),
		"computed prefix": strings.Replace(orchestrionGitOverride, `"third_party/rgo/v0_60_0/base"`, `"release/" + "third_party/rgo/v0_63_0/base"`, 1),
		"archive": `archive_override(
    module_name = "rules_go",
    urls = ["https://mirror.example/source.tar.gz"],
    strip_prefix = "release/third_party/rgo/v0_60_0/base",
)
`,
		"local path": `local_path_override(
    module_name = "rules_go",
    path = "/src/rules_test_optimization/third_party/rgo/v0_60_0/base",
)
`,
		"windows path": `local_path_override(
    module_name = "rules_go",
    path = "C:\\src\\rules_test_optimization\\third_party\\rgo\\v0_60_0\\base",
)
`,
	} {
		t.Run(name, func(t *testing.T) {
			input := "module(name = \"example\")\n" + override
			dir, moduleFile := writeModuleFile(t, input)
			err := patchModuleFile(config{workspaceDir: dir, goModuleDir: dir, moduleFile: moduleFile, runtimeVersion: "1.25.0"})
			if err == nil || !strings.Contains(err.Error(), "removed Datadog rules_go fork") {
				t.Fatalf("patchModuleFile error=%v, want fork override rejection", err)
			}
			if got := readFile(t, moduleFile); got != input {
				t.Fatalf("rejected MODULE.bazel changed:\n%s", got)
			}
		})
	}
}

func TestPatchModuleFileIgnoresCommentedForkOverride(t *testing.T) {
	commented := "# " + strings.ReplaceAll(strings.TrimSuffix(orchestrionGitOverride, "\n"), "\n", "\n# ") + "\n"
	dir, moduleFile := writeModuleFile(t, "module(name = \"example\")\n"+commented)
	if err := patchModuleFile(config{workspaceDir: dir, goModuleDir: dir, moduleFile: moduleFile, runtimeVersion: "1.25.0"}); err != nil {
		t.Fatalf("patchModuleFile error: %v", err)
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
	if strings.Contains(got, `enabled_by_env`) {
		t.Fatalf("expected guided block to rely on the config-gated extension default:\n%s", got)
	}
}

func TestValidateGuidedPrerequisites(t *testing.T) {
	input := `module(name = "example")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.2.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.2.0")
`
	if err := validateGuidedPrerequisites(input); err != nil {
		t.Fatalf("validateGuidedPrerequisites error: %v", err)
	}
}

func TestValidateGuidedPrerequisitesRequiresCoreAndGo(t *testing.T) {
	input := `module(name = "example")
bazel_dep(name = "datadog-rules-test-optimization", version = "1.2.0")
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
	if strings.Contains(text, "exports_files") || strings.Contains(text, "orchestrion") {
		t.Fatalf("expected no Orchestrion pin-file exports in BUILD.bazel:\n%s", text)
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
	if !strings.Contains(text, `topt_data = topt_data,`) || strings.Contains(text, "orchestrion") {
		t.Fatalf("expected wrapper to pass only topt_data to dd_topt_go_test:\n%s", text)
	}
}

func TestEnsureGuidedWorkspaceFilesLeavesGoModulePackageAlone(t *testing.T) {
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
	if _, err := os.Stat(filepath.Join(goModuleDir, "BUILD.bazel")); !os.IsNotExist(err) {
		t.Fatalf("guided setup wrote the Go module package BUILD.bazel: %v", err)
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

func TestRunGuidedWritesDdtestSetup(t *testing.T) {
	const goMod = "module example.com/service\n\ngo 1.25.0\n"
	dir, moduleFile := writeModuleFile(t, `module(name = "example")

bazel_dep(name = "datadog-rules-test-optimization", version = "1.4.0")
bazel_dep(name = "datadog-rules-test-optimization-go", version = "1.4.0")
`)
	cfg := config{
		workspaceDir:       dir,
		guided:             true,
		service:            "example-service",
		runtimeVersion:     "1.25.0",
		datadogFetch:       defaultDatadogFetch,
		syncRepoName:       defaultSyncRepoName,
		doctorTargetName:   defaultDoctorTargetName,
		uploaderTargetName: defaultUploaderTargetName,
	}
	if err := captureStdout(&strings.Builder{}, func() error { return run(cfg) }); err != nil {
		t.Fatalf("run --guided error: %v", err)
	}
	module := readFile(t, moduleFile)
	for _, want := range []string{
		`bazel_dep(name = "rules_go", version = "0.60.0")`,
		`topt_go_ddtest.sdk(go_version = "1.25.0")`,
		guidedBlockStart,
		`service = "example-service"`,
		`module_path = "example.com/service"`,
	} {
		if !strings.Contains(module, want) {
			t.Fatalf("MODULE.bazel missing %q:\n%s", want, module)
		}
	}
	if strings.Contains(module, "orchestrion") || strings.Contains(module, "_override(") {
		t.Fatalf("MODULE.bazel still has Orchestrion wiring:\n%s", module)
	}
	if wrapper := readFile(t, filepath.Join(dir, "tools", "build", "dd_go_test.bzl")); strings.Contains(wrapper, "orchestrion") {
		t.Fatalf("guided wrapper still passes Orchestrion attributes:\n%s", wrapper)
	}
	for _, path := range []string{"orchestrion.tool.go", "orchestrion.yml"} {
		if _, err := os.Stat(filepath.Join(dir, path)); !os.IsNotExist(err) {
			t.Fatalf("guided bootstrap wrote %s: %v", path, err)
		}
	}
	if got := readFile(t, filepath.Join(dir, "go.mod")); got != goMod {
		t.Fatalf("guided bootstrap changed go.mod:\n%s", got)
	}
}

func publishedPinsTestRepo(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
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
