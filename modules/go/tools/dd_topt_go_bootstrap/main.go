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
	defaultRulesGoRemote         = "https://github.com/darccio/rules_go.git"
	defaultRulesGoCommit         = "1a1b95dce9e67870fd8143d2f707028fa0acb222"
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

	managedBlock := fmt.Sprintf(`%s
git_override(
    module_name = "rules_go",
    remote = "%s",
    commit = "%s",
)
%s
`, managedBlockStart, cfg.rulesGoRemote, cfg.rulesGoCommit, managedBlockEnd)

	text, err = replaceManagedBlock(text, managedBlock)
	if err != nil {
		return err
	}

	if err := os.WriteFile(cfg.moduleFile, []byte(text), 0o644); err != nil {
		return fmt.Errorf("write MODULE.bazel: %w", err)
	}
	return nil
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

func runOrchestrionPin(cfg config) error {
	cmd := exec.Command("go", "run", "github.com/DataDog/orchestrion@"+cfg.orchestrionVersion, "pin")
	cmd.Dir = cfg.goModuleDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), "GO111MODULE=on")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("run orchestrion pin in %s: %w", cfg.goModuleDir, err)
	}
	return nil
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
