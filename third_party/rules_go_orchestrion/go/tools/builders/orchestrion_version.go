package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	rulesGoOrchestrionVersionFileEnvVar = "RULES_GO_ORCHESTRION_VERSION_FILE"
	defaultDDTraceGoVersion             = "v2.6.0"
)

var ddTraceGoModules = []string{
	"github.com/DataDog/dd-trace-go/v2",
	"github.com/DataDog/dd-trace-go/contrib/net/http/v2",
	"github.com/DataDog/dd-trace-go/contrib/log/slog/v2",
}

type goListModule struct {
	Version string `json:"Version"`
	Replace *struct {
		Version string `json:"Version"`
		Path    string `json:"Path"`
	} `json:"Replace"`
}

type orchestrionVersionConfig struct {
	Modules map[string]string `json:"modules"`
}

func defaultDDTraceGoVersions() map[string]string {
	versions := make(map[string]string, len(ddTraceGoModules))
	for _, modulePath := range ddTraceGoModules {
		versions[modulePath] = defaultDDTraceGoVersion
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

func configuredDDTraceGoVersions() (map[string]string, error) {
	versionFile := strings.TrimSpace(os.Getenv(rulesGoOrchestrionVersionFileEnvVar))
	if versionFile == "" {
		return defaultDDTraceGoVersions(), nil
	}
	content, err := os.ReadFile(versionFile)
	if err != nil {
		return nil, fmt.Errorf("read configured dd-trace-go version file %s: %w", versionFile, err)
	}
	trimmed := strings.TrimSpace(string(content))
	if trimmed == "" {
		return defaultDDTraceGoVersions(), nil
	}
	if !strings.HasPrefix(trimmed, "{") {
		versions := defaultDDTraceGoVersions()
		for _, modulePath := range ddTraceGoModules {
			versions[modulePath] = trimmed
		}
		return versions, nil
	}

	var decoded orchestrionVersionConfig
	if err := json.Unmarshal(content, &decoded); err != nil {
		return nil, fmt.Errorf("parse configured dd-trace-go version file %s: %w", versionFile, err)
	}
	if len(decoded.Modules) == 0 {
		return defaultDDTraceGoVersions(), nil
	}
	versions := make(map[string]string, len(ddTraceGoModules))
	for _, modulePath := range ddTraceGoModules {
		version := strings.TrimSpace(decoded.Modules[modulePath])
		if version == "" {
			return nil, fmt.Errorf("configured dd-trace-go version file %s is missing %s", versionFile, modulePath)
		}
		versions[modulePath] = version
	}
	for modulePath := range decoded.Modules {
		if !containsString(ddTraceGoModules, modulePath) {
			return nil, fmt.Errorf("configured dd-trace-go version file %s contains unsupported module %s", versionFile, modulePath)
		}
	}
	return versions, nil
}

func resolveGoExecutable(goSdkPath string) string {
	if goSdkPath != "" {
		goExe := filepath.Join(abs(goSdkPath), "bin", "go")
		if runtime.GOOS == "windows" {
			goExe += ".exe"
		}
		if _, err := os.Stat(goExe); err == nil {
			return goExe
		}
	}
	if goExe, err := exec.LookPath("go"); err == nil {
		return goExe
	}
	gorootGo := filepath.Join(getEnv(os.Environ(), "GOROOT"), "bin", "go")
	if runtime.GOOS == "windows" {
		gorootGo += ".exe"
	}
	if _, err := os.Stat(gorootGo); err == nil {
		return gorootGo
	}
	return ""
}

func resolveModuleVersionFromModule(goExe, moduleDir string, env []string, modulePath string) (string, error) {
	if goExe == "" {
		return "", fmt.Errorf("resolve %s version in %s: go binary unavailable", modulePath, moduleDir)
	}
	cmd := exec.Command(goExe, "list", "-mod=mod", "-m", "-json", modulePath)
	cmd.Dir = moduleDir
	cmdEnv := setEnv(env, "GO111MODULE", "on")
	cmdEnv = setEnv(cmdEnv, "GOWORK", "off")
	if strings.TrimSpace(getEnv(cmdEnv, "GOPROXY")) == "" {
		cmdEnv = setEnv(cmdEnv, "GOPROXY", "https://proxy.golang.org,direct")
	}
	if strings.TrimSpace(getEnv(cmdEnv, "GOSUMDB")) == "" {
		cmdEnv = setEnv(cmdEnv, "GOSUMDB", "sum.golang.org")
	}
	cmd.Env = cmdEnv
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("resolve %s version in %s: %w: %s", modulePath, moduleDir, err, strings.TrimSpace(string(output)))
	}
	var module goListModule
	if err := json.Unmarshal(output, &module); err != nil {
		return "", fmt.Errorf("parse %s version in %s: %w", modulePath, moduleDir, err)
	}
	if module.Replace != nil {
		if strings.TrimSpace(module.Replace.Version) == "" {
			return "", fmt.Errorf("resolve %s version in %s: local replace targets are not supported", modulePath, moduleDir)
		}
		return module.Replace.Version, nil
	}
	if strings.TrimSpace(module.Version) == "" {
		return "", fmt.Errorf("resolve %s version in %s: empty module version", modulePath, moduleDir)
	}
	return module.Version, nil
}

func validateResolvedDDTraceGoVersion(goExe, moduleDir string, env []string, verbose bool) error {
	configured, err := configuredDDTraceGoVersions()
	if err != nil {
		return err
	}
	for _, modulePath := range ddTraceGoModules {
		resolved, err := resolveModuleVersionFromModule(goExe, moduleDir, env, modulePath)
		if err != nil {
			return err
		}
		if verbose {
			fmt.Fprintf(os.Stderr, "orchestrion: configured dd-trace-go version=%s resolved=%s module=%s moduleDir=%s\n", configured[modulePath], resolved, modulePath, moduleDir)
		}
		if resolved != configured[modulePath] {
			return fmt.Errorf("configured dd-trace-go version mismatch: configured %s, resolved %s for %s (module root %s). Repin the local Go module files to match the configured versions", configured[modulePath], resolved, modulePath, moduleDir)
		}
	}
	return nil
}

func syntheticOrchestrionGoMod(versions map[string]string) string {
	return fmt.Sprintf(`module bazel_orchestrion_temp

go 1.21

require (
	github.com/DataDog/orchestrion v1.5.0
	github.com/DataDog/dd-trace-go/v2 %s
	github.com/DataDog/dd-trace-go/contrib/net/http/v2 %s
	github.com/DataDog/dd-trace-go/contrib/log/slog/v2 %s
)
`, versions["github.com/DataDog/dd-trace-go/v2"], versions["github.com/DataDog/dd-trace-go/contrib/net/http/v2"], versions["github.com/DataDog/dd-trace-go/contrib/log/slog/v2"])
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
