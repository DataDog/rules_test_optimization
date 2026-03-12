package main

import (
	"bytes"
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
	defaultRulesGoVersion        = "0.59.0"
	defaultRulesGoRemote         = "https://github.com/DataDog/rules_test_optimization.git"
	defaultRulesGoCommit         = "16712cc851915317659b932471dcb68af48dd5bb"
	defaultRulesGoStripPrefix    = "third_party/rules_go_orchestrion"
	defaultOrchestrionVersion    = "v1.5.0"
	managedBlockStart            = "# BEGIN Datadog Go Orchestrion bootstrap"
	managedBlockEnd              = "# END Datadog Go Orchestrion bootstrap"
	defaultStarterOrchestrionYML = `---
# yaml-language-server: $schema=https://datadoghq.dev/orchestrion/schema.json
meta:
  name: datadog/go-bootstrap
  description: Datadog starter configuration for Orchestrion.

aspects: []
`
	sharedOrchestrionCacheDirName = "datadog-orchestrion-go-cache"
)

type config struct {
	workspaceDir       string
	moduleFile         string
	goModuleDir        string
	force              bool
	orchestrionVersion string
	rulesGoRemote      string
	rulesGoCommit      string
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
	flag.StringVar(&cfg.orchestrionVersion, "orchestrion-version", defaultOrchestrionVersion, "Orchestrion version to configure")
	flag.StringVar(&cfg.rulesGoRemote, "rules-go-remote", defaultRulesGoRemote, "rules_go fork remote used for Orchestrion support")
	flag.StringVar(&cfg.rulesGoCommit, "rules-go-commit", defaultRulesGoCommit, "rules_go fork commit used for Orchestrion support")
	flag.Parse()
	return cfg
}

func run(cfg config) error {
	if cfg.workspaceDir == "" {
		return errors.New("workspace directory is required")
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

	if err := ensureFileExists(cfg.moduleFile, "MODULE.bazel"); err != nil {
		return err
	}
	if err := ensureFileExists(filepath.Join(cfg.goModuleDir, "go.mod"), "go.mod"); err != nil {
		return err
	}

	if err := patchModuleFile(cfg); err != nil {
		return err
	}
	if err := runOrchestrionPin(cfg); err != nil {
		return err
	}
	if err := ensureCIVisibilityOrchestrionImport(cfg); err != nil {
		return err
	}
	if err := warmOrchestrionModuleCache(cfg); err != nil {
		return err
	}
	if err := writeStarterOrchestrionYML(cfg); err != nil {
		return err
	}

	fmt.Printf("Updated %s and pinned Orchestrion in %s\n", cfg.moduleFile, cfg.goModuleDir)
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

func patchModuleFile(cfg config) error {
	content, err := os.ReadFile(cfg.moduleFile)
	if err != nil {
		return fmt.Errorf("read MODULE.bazel: %w", err)
	}
	text := string(content)

	if !strings.Contains(text, `bazel_dep(name = "rules_go"`) && !strings.Contains(text, `bazel_dep(name="rules_go"`) {
		snippet := fmt.Sprintf(`bazel_dep(name = "rules_go", version = "%s")%s`, defaultRulesGoVersion, "\n")
		text, err = insertAfterModuleDecl(text, snippet)
		if err != nil {
			return err
		}
	}

	if cfg.rulesGoRemote == defaultRulesGoRemote && cfg.rulesGoCommit == defaultRulesGoCommit {
		if remote, commit := inferDatadogRepoOverride(text); remote != "" && commit != "" {
			cfg.rulesGoRemote = remote
			cfg.rulesGoCommit = commit
		}
	}

	managedBlock := managedModuleBlock(cfg)

	text, err = replaceManagedBlock(text, managedBlock)
	if err != nil {
		return err
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
orchestrion.from_source(version = "%s")
use_repo(orchestrion, "rules_go_orchestrion_tool")
%s
`, managedBlockStart, cfg.rulesGoRemote, cfg.rulesGoCommit, defaultRulesGoStripPrefix, cfg.orchestrionVersion, managedBlockEnd)
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

func replaceManagedBlock(content, block string) (string, error) {
	start := strings.Index(content, managedBlockStart)
	end := strings.Index(content, managedBlockEnd)
	switch {
	case start >= 0 && end >= 0 && end > start:
		end += len(managedBlockEnd)
		return content[:start] + block + content[end:], nil
	case start >= 0 || end >= 0:
		return "", errors.New("existing Datadog bootstrap block in MODULE.bazel is malformed")
	}

	rulesGoOverride := regexp.MustCompile(`(?s)git_override\(\s*module_name\s*=\s*"rules_go".*?\n\)`)
	if rulesGoOverride.MatchString(content) {
		return "", errors.New("MODULE.bazel already contains a rules_go git_override; update it manually before running the Datadog bootstrap")
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

func runOrchestrionPin(cfg config) error {
	cmd := exec.Command("go", "run", "github.com/DataDog/orchestrion@"+cfg.orchestrionVersion, "pin")
	cmd.Dir = cfg.goModuleDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = orchestrionBootstrapEnv()
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("run orchestrion pin in %s: %w", cfg.goModuleDir, err)
	}
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
		legacyCIVisibilityImport = `_ "gopkg.in/DataDog/dd-trace-go.v1/civisibility" // integration`
		legacyCIVisibilityImportBare = `_ "gopkg.in/DataDog/dd-trace-go.v1/civisibility"`
		v2OrchestrionImport      = `_ "github.com/DataDog/dd-trace-go/v2/orchestrion" // integration`
		v2AllImport              = `_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2" // integration`
		v2AllImportBare          = `_ "github.com/DataDog/dd-trace-go/orchestrion/all/v2"`
		v2GotestingImport        = `_ "github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting" // integration`
		v2GotestingImportBare    = `_ "github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting"`
	)

	updated := strings.ReplaceAll(text, legacyCIVisibilityImport+"\n", "")
	updated = strings.ReplaceAll(updated, legacyCIVisibilityImport, "")
	updated = strings.ReplaceAll(updated, legacyCIVisibilityImportBare+"\n", "")
	updated = strings.ReplaceAll(updated, legacyCIVisibilityImportBare, "")
	updated = strings.ReplaceAll(updated, v2AllImport+"\n", "")
	updated = strings.ReplaceAll(updated, v2AllImport, "")
	updated = strings.ReplaceAll(updated, v2AllImportBare+"\n", "")
	updated = strings.ReplaceAll(updated, v2AllImportBare, "")
	updated = strings.ReplaceAll(updated, v2GotestingImport+"\n", "")
	updated = strings.ReplaceAll(updated, v2GotestingImport, "")
	updated = strings.ReplaceAll(updated, v2GotestingImportBare+"\n", "")
	updated = strings.ReplaceAll(updated, v2GotestingImportBare, "")
	updated = strings.ReplaceAll(updated, "\n\n\n", "\n\n")

	if strings.Contains(updated, v2OrchestrionImport) {
		if updated == text {
			return nil
		}
		if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
			return fmt.Errorf("write orchestrion.tool.go: %w", err)
		}
		return nil
	}

	baseOrchestrionPattern := `(?m)^(\s*_\s*"github\.com/DataDog/orchestrion"(?:\s*//.*)?\s*)$`
	if re := regexp.MustCompile(baseOrchestrionPattern); re.MatchString(updated) {
		updated = re.ReplaceAllString(updated, `${1}`+"\n\t"+v2OrchestrionImport)
	} else if strings.Contains(updated, ")\n") {
		updated = strings.Replace(updated, ")\n", "\t"+v2OrchestrionImport+"\n)\n", 1)
	} else {
		return fmt.Errorf("patch orchestrion.tool.go: could not locate import block")
	}

	if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
		return fmt.Errorf("write orchestrion.tool.go: %w", err)
	}
	return nil
}

func warmOrchestrionModuleCache(cfg config) error {
	commands := [][]string{
		{"mod", "download", "github.com/DataDog/dd-trace-go/v2"},
		{"list", "-mod=mod", "github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"},
		{"list", "-mod=mod", "github.com/DataDog/dd-trace-go/v2/profiler"},
		{"list", "-mod=mod", "github.com/DataDog/dd-trace-go/v2/instrumentation/env"},
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

func orchestrionBootstrapEnv() []string {
	env := append([]string{}, os.Environ()...)
	cacheRoot := filepath.Join(os.TempDir(), sharedOrchestrionCacheDirName)
	goModCache := filepath.Join(cacheRoot, "pkg", "mod")
	goBuildCache := filepath.Join(cacheRoot, "cache")

	env = append(env,
		"GO111MODULE=on",
		"GOPATH="+cacheRoot,
		"GOMODCACHE="+goModCache,
		"GOCACHE="+goBuildCache,
		"GOPROXY=https://proxy.golang.org,direct",
		"GOSUMDB=sum.golang.org",
	)
	return env
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
