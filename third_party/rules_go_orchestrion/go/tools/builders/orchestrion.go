// Copyright 2024 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	// orchestrionJobserverURLEnvVar is the environment variable used by orchestrion
	// to locate the jobserver.
	orchestrionJobserverURLEnvVar = "ORCHESTRION_JOBSERVER_URL"

	// toolexecImportPathEnvVar is the environment variable used by orchestrion
	// to know the import path of the package being compiled.
	toolexecImportPathEnvVar = "TOOLEXEC_IMPORTPATH"

	// orchestrionSkipPinEnvVar is set to skip orchestrion's auto-pinning behavior
	// which tries to modify go.mod files (not needed in Bazel builds).
	orchestrionSkipPinEnvVar = "DD_ORCHESTRION_IS_GOMOD_VERSION"

	// jobserverStartTimeout is the maximum time to wait for the jobserver to start.
	jobserverStartTimeout = 10 * time.Second

	// jobserverPollInterval is the interval to poll for the URL file.
	jobserverPollInterval = 50 * time.Millisecond
)

// ensureGoModuleCacheEnv provisions a writable Go cache/module cache for
// orchestrion subprocesses. Some Bazel sandboxes do not provide GOPATH or
// GOMODCACHE, but orchestrion shells out to `go list` while loading injector
// configuration from orchestrion.tool.go.
func ensureGoModuleCacheEnv(env []string, verbose bool) ([]string, error) {
	cacheRoot := getEnv(env, "GOPATH")
	if cacheRoot == "" {
		if home := getEnv(env, "HOME"); home != "" {
			cacheRoot = filepath.Join(home, "go")
		}
	}
	if cacheRoot == "" {
		if homeDir, err := os.UserHomeDir(); err == nil && homeDir != "" {
			cacheRoot = filepath.Join(homeDir, "go")
		}
	}
	if cacheRoot == "" {
		cacheRoot = filepath.Join(os.TempDir(), fmt.Sprintf("orchestrion-go-cache-%d", os.Getpid()))
	}

	goModCache := getEnv(env, "GOMODCACHE")
	if goModCache == "" {
		goModCache = filepath.Join(cacheRoot, "pkg", "mod")
	}

	goBuildCache := getEnv(env, "GOCACHE")
	if goBuildCache == "" {
		if userCacheDir, err := os.UserCacheDir(); err == nil && userCacheDir != "" {
			goBuildCache = filepath.Join(userCacheDir, "go-build")
		} else {
			goBuildCache = filepath.Join(cacheRoot, "cache")
		}
	}

	for _, dir := range []string{goModCache, goBuildCache} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("creating orchestrion go cache dir %s: %w", dir, err)
		}
	}

	env = setEnv(env, "GOPATH", cacheRoot)
	env = setEnv(env, "GOMODCACHE", goModCache)
	env = setEnv(env, "GOCACHE", goBuildCache)
	env = setEnv(env, "GOPROXY", "https://proxy.golang.org,direct")
	env = setEnv(env, "GOSUMDB", "sum.golang.org")

	if verbose {
		fmt.Fprintf(os.Stderr, "orchestrion: using GOPATH=%s GOMODCACHE=%s GOCACHE=%s GOPROXY=%s\n", cacheRoot, goModCache, goBuildCache, getEnv(env, "GOPROXY"))
	}

	return env, nil
}

// orchestrionJobserver manages the lifecycle of an orchestrion jobserver process.
type orchestrionJobserver struct {
	url     string
	urlFile string
	cmd     *exec.Cmd
}

// ensureGoModExists creates a minimal go.mod file in the current directory if one
// doesn't exist. This is required by orchestrion to function properly.
// If srcDirs contains directories with orchestrion.yml, it copies them to the
// current directory so orchestrion can find its configuration.
// Returns a cleanup function that removes the temporary files we created.
func ensureGoModExists(srcDirs []string, verbose bool) (cleanup func(), err error) {
	const goModFile = "go.mod"
	const goSumFile = "go.sum"
	const orchestrionYML = "orchestrion.yml"
	const orchestrionToolGo = "orchestrion.tool.go"

	var filesToCleanup []string

	if verbose {
		cwd, _ := os.Getwd()
		fmt.Fprintf(os.Stderr, "orchestrion: ensureGoModExists cwd=%s srcDirs=%v\n", cwd, srcDirs)
	}

	// Prefer copying pinned module metadata from the source directory. Orchestrion
	// needs the real module requirements from `orchestrion pin`; a synthetic
	// minimal go.mod is only a fallback when the package has no module files.
	if _, err := os.Stat(goModFile); os.IsNotExist(err) {
		var copiedGoMod bool
		for _, dir := range srcDirs {
			goModSrc := filepath.Join(dir, goModFile)
			if _, err := os.Stat(goModSrc); err == nil {
				if verbose {
					fmt.Fprintf(os.Stderr, "orchestrion: Found %s\n", goModSrc)
				}
				if err := copyOrchFile(goModSrc, goModFile); err != nil {
					return nil, fmt.Errorf("copying go.mod: %w", err)
				}
				filesToCleanup = append(filesToCleanup, goModFile)
				copiedGoMod = true
				if verbose {
					fmt.Fprintf(os.Stderr, "orchestrion: Copied go.mod to cwd\n")
				}

				goSumSrc := filepath.Join(dir, goSumFile)
				if _, err := os.Stat(goSumSrc); err == nil {
					if verbose {
						fmt.Fprintf(os.Stderr, "orchestrion: Found %s\n", goSumSrc)
					}
					if err := copyOrchFile(goSumSrc, goSumFile); err != nil {
						return nil, fmt.Errorf("copying go.sum: %w", err)
					}
					filesToCleanup = append(filesToCleanup, goSumFile)
					if verbose {
						fmt.Fprintf(os.Stderr, "orchestrion: Copied go.sum to cwd\n")
					}
				}
				break
			}
		}

		if !copiedGoMod {
			content := []byte("module bazel_orchestrion_temp\n\ngo 1.21\n")
			if err := os.WriteFile(goModFile, content, 0644); err != nil {
				return nil, fmt.Errorf("creating temporary go.mod: %w", err)
			}
			filesToCleanup = append(filesToCleanup, goModFile)
			if verbose {
				fmt.Fprintf(os.Stderr, "orchestrion: Created temporary go.mod\n")
			}
		}
	}

	// Look for orchestrion.yml in source directories and copy it to cwd
	// Also look for orchestrion.tool.go which may contain additional config imports
	for _, dir := range srcDirs {
		ymlSrc := filepath.Join(dir, orchestrionYML)
		if _, err := os.Stat(ymlSrc); err == nil {
			if verbose {
				fmt.Fprintf(os.Stderr, "orchestrion: Found %s\n", ymlSrc)
			}
			// Copy orchestrion.yml to current directory
			if _, err := os.Stat(orchestrionYML); os.IsNotExist(err) {
				if err := copyOrchFile(ymlSrc, orchestrionYML); err != nil {
					return nil, fmt.Errorf("copying orchestrion.yml: %w", err)
				}
				filesToCleanup = append(filesToCleanup, orchestrionYML)
				if verbose {
					fmt.Fprintf(os.Stderr, "orchestrion: Copied orchestrion.yml to cwd\n")
				}
			}
		}

		toolGoSrc := filepath.Join(dir, orchestrionToolGo)
		if _, err := os.Stat(toolGoSrc); err == nil {
			if verbose {
				fmt.Fprintf(os.Stderr, "orchestrion: Found %s\n", toolGoSrc)
			}
			// Copy orchestrion.tool.go to current directory
			if _, err := os.Stat(orchestrionToolGo); os.IsNotExist(err) {
				if err := copyOrchFile(toolGoSrc, orchestrionToolGo); err != nil {
					return nil, fmt.Errorf("copying orchestrion.tool.go: %w", err)
				}
				filesToCleanup = append(filesToCleanup, orchestrionToolGo)
				if verbose {
					fmt.Fprintf(os.Stderr, "orchestrion: Copied orchestrion.tool.go to cwd\n")
				}
			}
		}
	}

	if verbose {
		logOrchestrionTempModuleState()
	}

	return func() {
		for _, f := range filesToCleanup {
			os.Remove(f)
		}
	}, nil
}

func logOrchestrionTempModuleState() {
	cwd, _ := os.Getwd()
	fmt.Fprintf(os.Stderr, "orchestrion: temp module cwd=%s\n", cwd)
	for _, name := range []string{"go.mod", "go.sum", "orchestrion.tool.go", "orchestrion.yml"} {
		if info, err := os.Stat(name); err == nil {
			fmt.Fprintf(os.Stderr, "orchestrion: temp file %s size=%d\n", name, info.Size())
		} else if os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "orchestrion: temp file %s missing\n", name)
		} else {
			fmt.Fprintf(os.Stderr, "orchestrion: temp file %s stat error: %v\n", name, err)
		}
	}
	if data, err := os.ReadFile("go.mod"); err == nil {
		fmt.Fprintf(os.Stderr, "orchestrion: temp go.mod has dd-trace-go/v2=%t orchestrion/all/v2=%t\n",
			strings.Contains(string(data), "github.com/DataDog/dd-trace-go/v2"),
			strings.Contains(string(data), "github.com/DataDog/dd-trace-go/orchestrion/all/v2"))
	}
}

// copyOrchFile copies a file from src to dst. This is a simple wrapper
// that reads the entire file and writes it to the destination.
// Note: There's also a copyFile in cgo2.go with different implementation.
func copyOrchFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0644)
}

// startOrchestrionJobserver starts an orchestrion jobserver and returns the server
// instance. The caller must call cleanup() when done to terminate the server.
// If orchestrionPath is empty or ORCHESTRION_JOBSERVER_URL is already set,
// this returns nil (no server needed).
// goSdkPath is the path to the Go SDK, used to set PATH and GOROOT for the server.
func startOrchestrionJobserver(orchestrionPath, goSdkPath string, verbose bool) (*orchestrionJobserver, error) {
	if orchestrionPath == "" {
		return nil, nil
	}

	// If ORCHESTRION_JOBSERVER_URL is already set, we don't need to start a server
	if os.Getenv(orchestrionJobserverURLEnvVar) != "" {
		return nil, nil
	}

	// Create a temporary file for the URL
	tmpDir := os.TempDir()
	urlFile := filepath.Join(tmpDir, fmt.Sprintf("orchestrion-jobserver-%d.url", os.Getpid()))

	// Start the orchestrion server process
	cmd := exec.Command(orchestrionPath, "server",
		"-url-file="+urlFile,
		"-inactivity-timeout=5m",
	)
	cmd.Stdout = os.Stderr // Redirect to stderr for debugging
	cmd.Stderr = os.Stderr

	// Set up environment with proper PATH and GOROOT for the server process
	// The server needs access to the go binary to load its configuration
	cmd.Env = os.Environ()
	var err error
	cmd.Env, err = ensureGoModuleCacheEnv(cmd.Env, verbose)
	if err != nil {
		return nil, err
	}
	if goSdkPath != "" {
		absGoSdkPath := goSdkPath
		if !filepath.IsAbs(goSdkPath) {
			if abs, err := filepath.Abs(goSdkPath); err == nil {
				absGoSdkPath = abs
			}
		}
		goBinPath := filepath.Join(absGoSdkPath, "bin")
		cmd.Env = prependToPath(cmd.Env, goBinPath)
		cmd.Env = setEnv(cmd.Env, "GOROOT", absGoSdkPath)
		// Prevent go from trying to download different toolchains
		cmd.Env = setEnv(cmd.Env, "GOTOOLCHAIN", "local")
		// Disable external package driver
		cmd.Env = setEnv(cmd.Env, "GOPACKAGESDRIVER", "off")

		if verbose {
			fmt.Fprintf(os.Stderr, "DEBUG: Starting orchestrion jobserver with PATH including %s, GOROOT=%s\n", goBinPath, absGoSdkPath)
		}
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("failed to start orchestrion jobserver: %w", err)
	}

	// Wait for the URL file to be created and populated
	url, err := waitForURLFile(urlFile, jobserverStartTimeout)
	if err != nil {
		// Kill the process if we failed to get the URL
		_ = cmd.Process.Kill()
		_ = os.Remove(urlFile)
		return nil, fmt.Errorf("failed to get orchestrion jobserver URL: %w", err)
	}

	return &orchestrionJobserver{
		url:     url,
		urlFile: urlFile,
		cmd:     cmd,
	}, nil
}

// URL returns the jobserver URL.
func (j *orchestrionJobserver) URL() string {
	if j == nil {
		return ""
	}
	return j.url
}

// cleanup terminates the jobserver and removes the URL file.
func (j *orchestrionJobserver) cleanup() {
	if j == nil {
		return
	}
	if j.cmd != nil && j.cmd.Process != nil {
		_ = j.cmd.Process.Kill()
		_ = j.cmd.Wait() // Reap the process
	}
	if j.urlFile != "" {
		_ = os.Remove(j.urlFile)
	}
}

// waitForURLFile waits for the URL file to be created and contain a valid URL.
func waitForURLFile(path string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil && len(data) > 0 {
			url := strings.TrimSpace(string(data))
			if url != "" {
				return url, nil
			}
		}
		time.Sleep(jobserverPollInterval)
	}

	return "", fmt.Errorf("timeout waiting for orchestrion jobserver URL file: %s", path)
}

// executeCommandWithJobserver runs a command with the orchestrion jobserver URL set
// in the environment if a jobserver is provided. If importPath is non-empty,
// TOOLEXEC_IMPORTPATH is also set (required by orchestrion toolexec).
// If goSdkPath is non-empty, the Go SDK's bin directory is prepended to PATH.
func executeCommandWithJobserver(cmd *exec.Cmd, jobserver *orchestrionJobserver, importPath, goSdkPath string, verbose bool) error {
	if goSdkPath != "" {
		// Set PATH in the current process so that child processes inherit it
		// This is needed because exec.Command looks up the path using the current process's PATH
		goBinPath := filepath.Join(goSdkPath, "bin")
		currentPath := os.Getenv("PATH")
		newPath := goBinPath + string(os.PathListSeparator) + currentPath
		os.Setenv("PATH", newPath)
		os.Setenv("GOROOT", goSdkPath)
	}

	// Let cmd inherit the modified environment from the current process
	// Don't set cmd.Env explicitly so it uses the process environment
	if cmd.Env == nil {
		cmd.Env = os.Environ()
	}
	var err error
	cmd.Env, err = ensureGoModuleCacheEnv(cmd.Env, verbose)
	if err != nil {
		return err
	}

	if jobserver != nil && jobserver.URL() != "" {
		cmd.Env = appendEnvIfNotExists(cmd.Env, orchestrionJobserverURLEnvVar, jobserver.URL())
		cmd.Env = appendEnvIfNotExists(cmd.Env, orchestrionSkipPinEnvVar, "true")
		// Disable external package driver to ensure go command is used directly
		cmd.Env = setEnv(cmd.Env, "GOPACKAGESDRIVER", "off")
		// Prevent go from trying to download different toolchains
		cmd.Env = setEnv(cmd.Env, "GOTOOLCHAIN", "local")
		// Also ensure GOROOT is set correctly in cmd.Env
		if goSdkPath != "" {
			cmd.Env = setEnv(cmd.Env, "GOROOT", goSdkPath)
		}
	}
	if importPath != "" {
		cmd.Env = appendEnvIfNotExists(cmd.Env, toolexecImportPathEnvVar, importPath)
	}
	if verbose {
		fmt.Fprintf(os.Stderr, "orchestrion: command env importpath=%s GOROOT=%s GOPATH=%s GOMODCACHE=%s GOCACHE=%s GOTOOLCHAIN=%s GOPACKAGESDRIVER=%s DD_ORCHESTRION_IS_GOMOD_VERSION=%s\n",
			importPath,
			getEnv(cmd.Env, "GOROOT"),
			getEnv(cmd.Env, "GOPATH"),
			getEnv(cmd.Env, "GOMODCACHE"),
			getEnv(cmd.Env, "GOCACHE"),
			getEnv(cmd.Env, "GOTOOLCHAIN"),
			getEnv(cmd.Env, "GOPACKAGESDRIVER"),
			getEnv(cmd.Env, orchestrionSkipPinEnvVar),
		)
	}

	return runAndLogCommand(cmd, verbose)
}

// setEnv sets an environment variable, replacing any existing value.
func setEnv(env []string, key, value string) []string {
	if env == nil {
		env = os.Environ()
	}
	prefix := key + "="
	for i, e := range env {
		if strings.HasPrefix(e, prefix) {
			env[i] = prefix + value
			return env
		}
	}
	return append(env, prefix+value)
}

// getEnv returns the value of an environment variable from env, or an empty
// string if the key is not present.
func getEnv(env []string, key string) string {
	if env == nil {
		return ""
	}
	prefix := key + "="
	for _, e := range env {
		if strings.HasPrefix(e, prefix) {
			return strings.TrimPrefix(e, prefix)
		}
	}
	return ""
}

// prependToPath prepends a directory to the PATH environment variable.
func prependToPath(env []string, dir string) []string {
	if env == nil {
		env = os.Environ()
	}
	for i, e := range env {
		if strings.HasPrefix(e, "PATH=") {
			env[i] = "PATH=" + dir + string(os.PathListSeparator) + e[5:]
			return env
		}
	}
	return append(env, "PATH="+dir)
}

// appendEnvIfNotExists appends key=value to env if key is not already set.
func appendEnvIfNotExists(env []string, key, value string) []string {
	if env == nil {
		env = os.Environ()
	}
	prefix := key + "="
	for _, e := range env {
		if strings.HasPrefix(e, prefix) {
			return env // Already set
		}
	}
	return append(env, prefix+value)
}
