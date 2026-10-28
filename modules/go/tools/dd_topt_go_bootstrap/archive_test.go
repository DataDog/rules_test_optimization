// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func archiveTestOverride(module, prefix string) string {
	return fmt.Sprintf(`archive_override(
    module_name = %q,
    urls = ["https://mirror.example/source.tar.gz", "https://github.com/DataDog/rules_test_optimization/releases/download/v1.3.0/source.tar.gz"],
    sha256 = %q,
    strip_prefix = %q,
)
`, module, strings.Repeat("a", 64), prefix)
}

func TestArchiveBootstrapSourcesAndIdempotence(t *testing.T) {
	for _, module := range []string{"datadog-rules-test-optimization", "datadog-rules-test-optimization-go", "rules_go"} {
		t.Run(module, func(t *testing.T) {
			prefix := "rules_test_optimization-1.3.0"
			if module == "datadog-rules-test-optimization-go" {
				prefix += "/modules/go"
			} else if module == "rules_go" {
				prefix += "/third_party/rgo/v0_60_0/base"
			}
			input := "module(name = \"consumer\")\n" + archiveTestOverride(module, prefix)
			file := filepath.Join(t.TempDir(), "MODULE.bazel")
			if err := os.WriteFile(file, []byte(input), 0o644); err != nil {
				t.Fatal(err)
			}
			cfg := config{moduleFile: file, rulesGoVariant: "base", orchestrionVersion: defaultOrchestrionVersion, ddTraceGoVersion: defaultDDTraceGoVersion}
			if err := patchModuleFile(cfg); err != nil {
				t.Fatal(err)
			}
			first, _ := os.ReadFile(file)
			if strings.Contains(string(first), "git_override(") || strings.Count(string(first), `module_name = "rules_go"`) != 1 {
				t.Fatalf("expected exactly one archive fork override, no Git:\n%s", first)
			}
			for _, wanted := range []string{"https://mirror.example/source.tar.gz", strings.Repeat("a", 64), "rules_test_optimization-1.3.0/third_party/rgo/v0_60_0/base"} {
				if !strings.Contains(string(first), wanted) {
					t.Fatalf("missing %q:\n%s", wanted, first)
				}
			}
			if err := patchModuleFile(cfg); err != nil {
				t.Fatal(err)
			}
			second, _ := os.ReadFile(file)
			if string(first) != string(second) {
				t.Fatalf("bootstrap is not idempotent:\n%s\nthen:\n%s", first, second)
			}
		})
	}
}

func TestArchiveBootstrapRejectsInvalidInputsWithoutWriting(t *testing.T) {
	valid := archiveTestOverride("datadog-rules-test-optimization", "release")
	for name, input := range map[string]string{
		"missing checksum":   strings.Replace(valid, strings.Repeat("a", 64), "", 1),
		"malformed checksum": strings.Replace(valid, strings.Repeat("a", 64), "not-a-sha", 1),
		"computed URLs":      strings.Replace(valid, `"https://mirror.example/source.tar.gz"`, "MIRROR_URL", 1),
		"conditional URLs":   strings.Replace(valid, "],\n", "] if USE_MIRROR else [\"https://fallback.example/source.tar.gz\"],\n", 1),
		"concatenated URLs":  strings.Replace(valid, "],\n", "] + [\"https://fallback.example/source.tar.gz\"],\n", 1),
		"computed prefix":    strings.Replace(valid, `strip_prefix = "release"`, `strip_prefix = PREFIX`, 1),
		"parent traversal":   strings.Replace(valid, `strip_prefix = "release"`, `strip_prefix = "../release"`, 1),
		"fork patches":       strings.Replace(archiveTestOverride("rules_go", "release/third_party/rgo/v0_60_0/base"), "archive_override(", "archive_override(\n patches = [\"//:custom.patch\"],", 1),
	} {
		t.Run(name, func(t *testing.T) {
			file := filepath.Join(t.TempDir(), "MODULE.bazel")
			if err := os.WriteFile(file, []byte(input), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := patchModuleFile(config{moduleFile: file, rulesGoVariant: "base"}); err == nil {
				t.Fatal("expected actionable validation error")
			}
			after, _ := os.ReadFile(file)
			if string(after) != input {
				t.Fatal("invalid input changed MODULE.bazel")
			}
		})
	}
}

func TestArchiveInferenceRejectsComputedURLLists(t *testing.T) {
	const module = "datadog-rules-test-optimization"
	valid := archiveTestOverride(module, "release")
	if archive, err := findModuleArchive(valid, module); err != nil || archive == nil || len(archive.urls) != 2 {
		t.Fatalf("expected literal URL-list inference to succeed: archive=%+v err=%v", archive, err)
	}
	for _, suffix := range []string{` if USE_MIRROR else ["https://fallback.example/source.tar.gz"]`, ` + ["https://fallback.example/source.tar.gz"]`} {
		t.Run(suffix, func(t *testing.T) {
			input := strings.Replace(valid, "],\n", "]"+suffix+",\n", 1)
			if archive, err := findModuleArchive(input, module); err == nil || archive != nil {
				t.Fatalf("computed URL list was accepted: archive=%+v err=%v", archive, err)
			}
		})
	}
}

func TestArchiveBootstrapPreservesDeclarationsAroundCommentedOverrides(t *testing.T) {
	for _, comment := range []string{"# example: foo(", "# example: foo)", "# Unicode: héllo( and an unmatched quote \""} {
		t.Run(comment, func(t *testing.T) {
			prefix := "# Existing header: é\nmodule(name = \"consumer\")\n"
			suffix := "\nbazel_dep(name = \"keep_me\", version = \"1.0.0\")\n"
			override := strings.Replace(archiveTestOverride("rules_go", "release/third_party/rgo/v0_60_0/base"), "archive_override(\n", "archive_override(\n    "+comment+"\n", 1)
			input := prefix + override + suffix
			file := filepath.Join(t.TempDir(), "MODULE.bazel")
			if err := os.WriteFile(file, []byte(input), 0o644); err != nil {
				t.Fatal(err)
			}
			cfg := config{moduleFile: file}
			if err := patchModuleFile(cfg); err != nil {
				t.Fatal(err)
			}
			first, _ := os.ReadFile(file)
			if !strings.HasPrefix(string(first), prefix) || !strings.Contains(string(first), suffix) || strings.Count(string(first), "archive_override(") != 1 {
				t.Fatalf("moving an override changed surrounding declarations:\n%s", first)
			}
			if err := patchModuleFile(cfg); err != nil {
				t.Fatal(err)
			}
			second, _ := os.ReadFile(file)
			if string(first) != string(second) {
				t.Fatal("commented override is not idempotent")
			}
		})
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

func TestArchiveBootstrapExplicitFlagsAndGitEscapeHatch(t *testing.T) {
	cfg := config{rulesGoFetch: "archive", rtoArchiveURL: "file:///tmp/source.tar.gz", rtoArchiveSHA256: strings.Repeat("b", 64), rtoArchivePrefix: "release"}
	if err := configureModuleArchive(&cfg, ""); err != nil || cfg.rulesGoArchive == nil {
		t.Fatalf("explicit archive flags: %v", err)
	}
	for _, cfg := range []config{{rulesGoCommitSet: true}, {rulesGoRemoteSet: true}, {rulesGoFetch: "git", rulesGoFetchSet: true}} {
		if err := configureModuleArchive(&cfg, archiveTestOverride("datadog-rules-test-optimization", "release")); err != nil || cfg.rulesGoArchive != nil {
			t.Fatalf("explicit Git flags should disable archive inference: %v", err)
		}
	}
}

func TestArchiveBootstrapPreservesSupportedUpstreams(t *testing.T) {
	for _, upstream := range []string{"v0_60_0", "v0_61_1", "v0_62_0", "v0_63_0"} {
		t.Run(upstream, func(t *testing.T) {
			input := managedBlockStart + "\n" + archiveTestOverride("rules_go", "release/third_party/rgo/"+upstream+"/base") + managedBlockEnd
			cfg := config{}
			if err := hydrateManagedRulesGoVariant(&cfg, input); err != nil || cfg.rulesGoUpstream != upstream {
				t.Fatalf("hydrate archive selection: cfg=%+v err=%v", cfg, err)
			}
			if err := configureModuleArchive(&cfg, input); err != nil {
				t.Fatal(err)
			}
			block, err := managedModuleBlockWithError(cfg)
			if err != nil || !strings.Contains(block, "release/third_party/rgo/"+upstream+"/base") {
				t.Fatalf("preserve archive fork: %v\n%s", err, block)
			}
		})
	}
}

func TestArchiveBootstrapCommentsAndLiteralFormatting(t *testing.T) {
	input := "# " + strings.ReplaceAll(archiveTestOverride("rules_go", "wrong"), "\n", "\n# ") + "\n" + strings.ReplaceAll(archiveTestOverride("datadog-rules-test-optimization", "release"), `"`, `'`)
	cfg := config{}
	if err := configureModuleArchive(&cfg, input); err != nil || cfg.rulesGoArchive == nil || cfg.rulesGoArchive.prefix != "release" {
		t.Fatalf("comments/single quotes: %v %+v", err, cfg.rulesGoArchive)
	}
}

func TestArchiveBootstrapSingleQuotedManualForkAndURLParameters(t *testing.T) {
	input := "module(name = \"consumer\")\n" + strings.ReplaceAll(archiveTestOverride("rules_go", "release/third_party/rgo/v0_60_0/base"), `"`, `'`)
	input = strings.ReplaceAll(input, "source.tar.gz", "source.tar.gz?version=1")
	file := filepath.Join(t.TempDir(), "MODULE.bazel")
	if err := os.WriteFile(file, []byte(input), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := patchModuleFile(config{moduleFile: file}); err != nil {
		t.Fatal(err)
	}
	result, _ := os.ReadFile(file)
	if strings.Count(string(result), "archive_override(") != 1 || !strings.Contains(string(result), "?version=1") {
		t.Fatalf("manual fork should move into managed block, preserving URL parameters:\n%s", result)
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

func TestArchiveBootstrapDoesNotReplaceAnExistingGitFork(t *testing.T) {
	input := archiveTestOverride("datadog-rules-test-optimization", "release") + managedBlockStart + `
git_override(
    module_name = "rules_go",
    remote = "https://example.com/owned-fork.git",
    commit = "existing-published-commit",
    strip_prefix = "third_party/rgo/v0_60_0/base",
)
` + managedBlockEnd
	cfg := config{}
	if err := configureModuleArchive(&cfg, input); err != nil || cfg.rulesGoArchive != nil || cfg.rulesGoCommit != "existing-published-commit" {
		t.Fatalf("existing Git fork must win over a core archive: %+v, %v", cfg, err)
	}
}
