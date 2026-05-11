package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

const (
	// rulesGoOrchestrionModuleProxyRootEnvVar points at the declared offline Go
	// module proxy root staged by the Orchestrion tool repository.
	rulesGoOrchestrionModuleProxyRootEnvVar = "RULES_GO_ORCHESTRION_MODULE_PROXY_ROOT"
)

var legacyModuleProxyFallbackWarningOnce sync.Once
var moduleProxyResolutionBaseDir = mustGetwd()

// moduleProxyFileURL converts a filesystem path into the file:// URL syntax
// accepted by GOPROXY.
func moduleProxyFileURL(path string) (string, error) {
	return moduleProxyFileURLFromBase(path, moduleProxyResolutionBaseDir)
}

// moduleProxyFileURLFromBase resolves relative module proxy roots against the
// nearest ancestor that contains the staged Bazel path. Orchestrion toolexec
// subprocesses may start inside a package directory under the Go SDK, so simply
// joining the relative proxy path to the current directory can point at a
// nonexistent nested path instead of the execroot.
func moduleProxyFileURLFromBase(path, baseDir string) (string, error) {
	cleanedPath := strings.TrimSpace(path)
	if cleanedPath == "" {
		return "", fmt.Errorf("module proxy path is empty")
	}
	if isWindowsAbsolutePath(cleanedPath) {
		return "file:///" + strings.ReplaceAll(cleanedPath, "\\", "/"), nil
	}
	if !filepath.IsAbs(cleanedPath) {
		resolvedPath, err := resolveRelativeModuleProxyRoot(cleanedPath, baseDir)
		if err != nil {
			return "", err
		}
		cleanedPath = resolvedPath
	}
	absolutePath, err := filepath.Abs(cleanedPath)
	if err != nil {
		return "", fmt.Errorf("absolutize module proxy path %s: %w", cleanedPath, err)
	}
	slashPath := filepath.ToSlash(absolutePath)
	if !strings.HasPrefix(slashPath, "/") {
		slashPath = "/" + slashPath
	}
	return "file://" + slashPath, nil
}

// resolveRelativeModuleProxyRoot searches baseDir and its ancestors for a
// staged relative module-proxy path. If the path does not exist yet, it falls
// back to baseDir/path so existing tests and non-sandbox callers keep their
// deterministic URL behavior.
func resolveRelativeModuleProxyRoot(path, baseDir string) (string, error) {
	resolvedBaseDir := strings.TrimSpace(baseDir)
	if resolvedBaseDir == "" {
		return "", fmt.Errorf("module proxy path %s has no base dir", path)
	}
	absoluteBaseDir, err := filepath.Abs(resolvedBaseDir)
	if err != nil {
		return "", fmt.Errorf("absolutize module proxy base dir %s: %w", resolvedBaseDir, err)
	}
	fallback := filepath.Join(absoluteBaseDir, path)
	for dir := absoluteBaseDir; ; dir = filepath.Dir(dir) {
		candidate := filepath.Join(dir, path)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		} else if err != nil && !os.IsNotExist(err) {
			return "", fmt.Errorf("stat module proxy candidate %s: %w", candidate, err)
		}

		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
	}
	return fallback, nil
}

// normalizeGoModuleResolutionEnv applies the Go module-resolution defaults used
// by Orchestrion subprocesses. When the offline proxy is present, it becomes
// the sole module source for action-time module operations.
func normalizeGoModuleResolutionEnv(env []string) ([]string, error) {
	env = normalizeGoCompilerCommandEnv(env)

	moduleProxyRoot := strings.TrimSpace(getEnv(env, rulesGoOrchestrionModuleProxyRootEnvVar))
	if moduleProxyRoot != "" {
		proxyURL, err := moduleProxyFileURL(moduleProxyRoot)
		if err != nil {
			return nil, err
		}
		env = setEnv(env, "GOPROXY", proxyURL)
		env = setEnv(env, "GOSUMDB", "off")
		env = setEnv(env, "GOPRIVATE", "")
		env = setEnv(env, "GONOPROXY", "")
		env = setEnv(env, "GONOSUMDB", "")
		return env, nil
	}

	maybeWarnLegacyModuleProxyFallback(env)

	if strings.TrimSpace(getEnv(env, "GOPROXY")) == "" {
		env = setEnv(env, "GOPROXY", "https://proxy.golang.org,direct")
	}
	if strings.TrimSpace(getEnv(env, "GOSUMDB")) == "" {
		env = setEnv(env, "GOSUMDB", "sum.golang.org")
	}
	return env, nil
}

// normalizeGoCompilerCommandEnv makes Bazel execroot-relative compiler paths
// acceptable to Go subprocesses that validate CC, CXX, and FC before module
// resolution. Bare tool names such as "clang" are left untouched so Go can
// continue resolving them through PATH.
func normalizeGoCompilerCommandEnv(env []string) []string {
	for _, name := range []string{"CC", "CXX", "FC"} {
		value := strings.TrimSpace(getEnv(env, name))
		if value == "" {
			continue
		}
		args, err := splitGoCommandArgs(value)
		if err != nil || len(args) == 0 {
			continue
		}
		toolPath := args[0]
		if goCompilerPathIsAlreadyValid(toolPath) {
			continue
		}
		args[0] = absolutePathFromBase(toolPath, moduleProxyResolutionBaseDir)
		env = setEnv(env, name, quoteCommandArgs(args))
	}
	return env
}

// goCompilerPathIsAlreadyValid mirrors Go's CC/CXX/FC validation: absolute
// paths and bare command names are valid, while relative paths containing a
// directory component must be absolutized before invoking go commands.
func goCompilerPathIsAlreadyValid(path string) bool {
	return filepath.IsAbs(path) ||
		isWindowsAbsolutePath(path) ||
		strings.HasPrefix(path, "__BAZEL_") ||
		path == filepath.Base(path)
}

// absolutePathFromBase resolves path against the builder's initial working
// directory. Orchestrion may later run commands from synthetic module
// directories, but Bazel tool paths are relative to the original execroot.
func absolutePathFromBase(path, baseDir string) string {
	if isWindowsAbsolutePath(path) || filepath.IsAbs(path) {
		return path
	}
	if strings.TrimSpace(baseDir) != "" {
		path = filepath.Join(baseDir, path)
	}
	absolutePath, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return absolutePath
}

// quoteCommandArgs formats a Go tool command environment value after the first
// executable path has been normalized. It keeps arguments parseable by the same
// quote rules Go uses for CC, CXX, and FC.
func quoteCommandArgs(args []string) string {
	quoted := make([]string, 0, len(args))
	for _, arg := range args {
		quoted = append(quoted, quoteGoCommandArg(arg))
	}
	return strings.Join(quoted, " ")
}

// splitGoCommandArgs splits a Go command environment value using the same
// quoting model as cmd/internal/quoted.Split: whitespace separates arguments,
// and matching outer single or double quotes group one argument without
// interpreting backslashes.
func splitGoCommandArgs(value string) ([]string, error) {
	var fields []string
	for len(value) > 0 {
		for len(value) > 0 && isGoCommandSpace(value[0]) {
			value = value[1:]
		}
		if len(value) == 0 {
			break
		}
		if value[0] == '"' || value[0] == '\'' {
			quote := value[0]
			value = value[1:]
			i := 0
			for i < len(value) && value[i] != quote {
				i++
			}
			if i >= len(value) {
				return nil, fmt.Errorf("unterminated %c string", quote)
			}
			fields = append(fields, value[:i])
			value = value[i+1:]
			continue
		}
		i := 0
		for i < len(value) && !isGoCommandSpace(value[i]) {
			i++
		}
		fields = append(fields, value[:i])
		value = value[i:]
	}
	return fields, nil
}

// quoteGoCommandArg quotes one command argument only when Go's command
// environment parser requires it.
func quoteGoCommandArg(arg string) string {
	if !strings.ContainsAny(arg, " \t\n\r'\"") {
		return arg
	}
	if !strings.Contains(arg, "'") {
		return "'" + arg + "'"
	}
	if !strings.Contains(arg, "\"") {
		return "\"" + arg + "\""
	}
	return arg
}

// isGoCommandSpace reports the ASCII whitespace bytes recognized by Go's
// command environment parser.
func isGoCommandSpace(value byte) bool {
	return value == ' ' || value == '\t' || value == '\n' || value == '\r'
}

// normalizeGoActionCacheEnv ensures Orchestrion subprocesses have writable Go
// caches without defaulting into persistent user-cache locations.
func normalizeGoActionCacheEnv(env []string) ([]string, error) {
	goPath := strings.TrimSpace(getEnv(env, "GOPATH"))
	if goPath == "" {
		goPath = filepath.Join(os.TempDir(), orchestrionSharedCacheDirName, "gopath")
	}

	goModCache := strings.TrimSpace(getEnv(env, "GOMODCACHE"))
	if goModCache == "" {
		goModCache = filepath.Join(goPath, "pkg", "mod")
	}

	goBuildCache := strings.TrimSpace(getEnv(env, "GOCACHE"))
	if goBuildCache == "" {
		goBuildCache = filepath.Join(goPath, "cache")
	}

	for _, dir := range []string{goPath, goModCache, goBuildCache} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("prepare orchestrion go cache dir %s: %w", dir, err)
		}
	}

	env = setEnv(env, "GOPATH", goPath)
	env = setEnv(env, "GOMODCACHE", goModCache)
	env = setEnv(env, "GOCACHE", goBuildCache)
	return env, nil
}

// orchestrionActionCacheRoot returns the action-local cache root used by the
// builder-owned Orchestrion caches.
func orchestrionActionCacheRoot(env []string) (string, error) {
	if goPath := strings.TrimSpace(getEnv(env, "GOPATH")); goPath != "" {
		return filepath.Join(filepath.Clean(goPath), "cache", orchestrionPersistentCacheDirName), nil
	}
	return filepath.Join(os.TempDir(), orchestrionSharedCacheDirName, "cache", orchestrionPersistentCacheDirName), nil
}

// isWindowsAbsolutePath reports whether a path uses a Windows drive-prefix
// absolute form so tests can validate URL formatting on any host platform.
func isWindowsAbsolutePath(path string) bool {
	if len(path) < 3 {
		return false
	}
	drive := path[0]
	if !((drive >= 'a' && drive <= 'z') || (drive >= 'A' && drive <= 'Z')) {
		return false
	}
	if path[1] != ':' {
		return false
	}
	return path[2] == '\\' || path[2] == '/'
}

// maybeWarnLegacyModuleProxyFallback emits a single actionable warning when an
// Orchestrion action falls back to the legacy online module-resolution path.
func maybeWarnLegacyModuleProxyFallback(env []string) {
	if strings.TrimSpace(getEnv(env, rulesGoOrchestrionVersionFileEnvVar)) == "" {
		return
	}
	legacyModuleProxyFallbackWarningOnce.Do(func() {
		fmt.Fprintf(os.Stderr, "orchestrion: offline module proxy artifacts are missing; falling back to the legacy online module-resolution path. Rerun 'bazel sync --only=rules_go_orchestrion_tool --repo_env=FETCH_SALT=$(date +%%s)' to regenerate the tool repo.\n")
	})
}
