package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	rulesGoOrchestrionVersionFileEnvVar = "RULES_GO_ORCHESTRION_VERSION_FILE"
	defaultDDTraceGoVersion             = "v2.9.0-dev.0.20260408173856-00e7bd515e27"
)

var ddTraceGoModules = []string{
	"github.com/DataDog/dd-trace-go/v2",
	"github.com/DataDog/dd-trace-go/contrib/net/http/v2",
	"github.com/DataDog/dd-trace-go/contrib/log/slog/v2",
}

type goListModule struct {
	Path    string `json:"Path"`
	Version string `json:"Version"`
	Replace *struct {
		Version string `json:"Version"`
		Path    string `json:"Path"`
	} `json:"Replace"`
}

type orchestrionVersionConfig struct {
	Modules map[string]string `json:"modules"`
}

type ddTraceValidationManifest struct {
	Key             string            `json:"key"`
	ModuleRoot      string            `json:"module_root"`
	Target          string            `json:"target"`
	GoTool          string            `json:"go_tool"`
	Orchestrion     string            `json:"orchestrion"`
	Configured      map[string]string `json:"configured"`
	Resolved        map[string]string `json:"resolved"`
	ValidationCache string            `json:"validation_cache"`
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
	versions, err := resolveModuleVersionsFromModule(goExe, moduleDir, env, []string{modulePath})
	if err != nil {
		return "", err
	}
	version := strings.TrimSpace(versions[modulePath])
	if version == "" {
		return "", fmt.Errorf("resolve %s version in %s: empty module version", modulePath, moduleDir)
	}
	return version, nil
}

func resolveModuleVersionsFromModule(goExe, moduleDir string, env []string, modulePaths []string) (map[string]string, error) {
	if goExe == "" {
		return nil, fmt.Errorf("resolve module versions in %s: go binary unavailable", moduleDir)
	}
	if len(modulePaths) == 0 {
		return nil, nil
	}
	cmd := exec.Command(goExe, append([]string{"list", "-mod=mod", "-m", "-json"}, modulePaths...)...)
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
		return nil, fmt.Errorf("resolve module versions in %s: %w: %s", moduleDir, err, strings.TrimSpace(string(output)))
	}
	decoder := json.NewDecoder(strings.NewReader(string(output)))
	versions := make(map[string]string, len(modulePaths))
	for {
		var module goListModule
		if err := decoder.Decode(&module); err != nil {
			if err == io.EOF {
				break
			}
			return nil, fmt.Errorf("parse module versions in %s: %w", moduleDir, err)
		}
		modulePath := strings.TrimSpace(module.Path)
		if modulePath == "" && len(modulePaths) == 1 {
			modulePath = modulePaths[0]
		}
		if modulePath == "" {
			continue
		}
		if module.Replace != nil {
			if strings.TrimSpace(module.Replace.Version) == "" {
				return nil, fmt.Errorf("resolve %s version in %s: local replace targets are not supported", modulePath, moduleDir)
			}
			versions[modulePath] = module.Replace.Version
			continue
		}
		if strings.TrimSpace(module.Version) == "" {
			return nil, fmt.Errorf("resolve %s version in %s: empty module version", modulePath, moduleDir)
		}
		versions[modulePath] = module.Version
	}
	for _, modulePath := range modulePaths {
		if strings.TrimSpace(versions[modulePath]) == "" {
			return nil, fmt.Errorf("resolve %s version in %s: empty module version", modulePath, moduleDir)
		}
	}
	return versions, nil
}

func validateResolvedDDTraceGoVersion(goExe, moduleDir string, env []string, verbose bool) error {
	configured, err := configuredDDTraceGoVersions()
	if err != nil {
		return err
	}
	moduleDir = abs(moduleDir)
	cacheKey, err := validationCacheKey(goExe, moduleDir, env, configured)
	if err != nil {
		return err
	}
	cacheRoot, err := orchestrionPersistentCacheRoot(env)
	if err != nil {
		return err
	}
	paths := orchestrionCachePaths(cacheRoot, "validation", cacheKey)
	if cacheEntryReady(paths) {
		if verbose {
			fmt.Fprintf(os.Stderr, "orchestrion: validation cache hit key=%s moduleDir=%s\n", cacheKey, moduleDir)
		}
		return nil
	}

	releaseLock, err := acquireCacheLock(paths.lockDir, cacheLockTimeout, cacheLockStaleAfter)
	if err != nil {
		return err
	}
	defer releaseLock()

	if cacheEntryReady(paths) {
		if verbose {
			fmt.Fprintf(os.Stderr, "orchestrion: validation cache hit after wait key=%s moduleDir=%s\n", cacheKey, moduleDir)
		}
		return nil
	}

	resolved, err := resolveModuleVersionsFromModule(goExe, moduleDir, env, ddTraceGoModules)
	if err != nil {
		return err
	}
	for _, modulePath := range ddTraceGoModules {
		if verbose {
			fmt.Fprintf(os.Stderr, "orchestrion: configured dd-trace-go version=%s resolved=%s module=%s moduleDir=%s\n", configured[modulePath], resolved[modulePath], modulePath, moduleDir)
		}
		if resolved[modulePath] != configured[modulePath] {
			return fmt.Errorf("configured dd-trace-go version mismatch: configured %s, resolved %s for %s (module root %s). Repin the local Go module files to match the configured versions", configured[modulePath], resolved[modulePath], modulePath, moduleDir)
		}
	}
	manifest := ddTraceValidationManifest{
		Key:             cacheKey,
		ModuleRoot:      moduleDir,
		Target:          goTargetIdentity(env),
		GoTool:          abs(goExe),
		Orchestrion:     orchestrionVersionIdentity,
		Configured:      copyDDTraceGoVersions(configured),
		Resolved:        resolved,
		ValidationCache: validationCacheABIVersion,
	}
	if err := os.MkdirAll(paths.entryDir, 0o755); err != nil {
		return fmt.Errorf("prepare validation cache dir %s: %w", paths.entryDir, err)
	}
	if err := writeJSONAtomically(paths.manifestPath, manifest); err != nil {
		return fmt.Errorf("write validation cache manifest %s: %w", paths.manifestPath, err)
	}
	if err := writeReadySentinel(paths.readyPath); err != nil {
		return fmt.Errorf("write validation cache ready file %s: %w", paths.readyPath, err)
	}
	return nil
}

func validationCacheKey(goExe, moduleDir string, env []string, configured map[string]string) (string, error) {
	fileParts := []string{
		"module_root=" + abs(moduleDir),
		"configured_versions=" + ddTraceVersionsDigest(configured),
		"go_tool=" + abs(goExe),
		"orchestrion=" + orchestrionVersionIdentity,
		"target=" + goTargetIdentity(env),
		"validation_cache=" + validationCacheABIVersion,
	}
	for _, name := range []string{"go.mod", "go.sum", "orchestrion.tool.go", "orchestrion.yml"} {
		digest, err := digestFileOrMissing(filepath.Join(moduleDir, name))
		if err != nil {
			return "", err
		}
		fileParts = append(fileParts, name+"="+digest)
	}
	return stableDigestParts(fileParts...), nil
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
