//go:build !windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestVerbFromName(t *testing.T) {
	testCases := []struct {
		name string
		verb string
	}{
		{"/a/b/c/d/builder", ""},
		{"builder", ""},
		{"/a/b/c/d/builder-cc", "cc"},
		{"builder-ld", "ld"},
		{"c:\\builder\\builder.exe", ""},
		{"c:\\builder with spaces\\builder-cc.exe", "cc"},
	}

	for _, tc := range testCases {
		result := verbFromName(tc.name)
		if result != tc.verb {
			t.Fatalf("retrieved invalid verb %q from name %q", result, tc.name)
		}
	}
}

func TestModuleProxyFileURLUnixPath(t *testing.T) {
	proxyRoot := filepath.Join(t.TempDir(), "module_proxy")
	got, err := moduleProxyFileURL(proxyRoot)
	if err != nil {
		t.Fatalf("moduleProxyFileURL error: %v", err)
	}
	want := "file://" + filepath.ToSlash(proxyRoot)
	if !strings.HasPrefix(want, "file:///") {
		want = "file:///" + strings.TrimPrefix(filepath.ToSlash(proxyRoot), "/")
	}
	if got != want {
		t.Fatalf("moduleProxyFileURL=%q, want %q", got, want)
	}
}

func TestModuleProxyFileURLWindowsPath(t *testing.T) {
	got, err := moduleProxyFileURL(`C:\tmp\module_proxy`)
	if err != nil {
		t.Fatalf("moduleProxyFileURL error: %v", err)
	}
	if got != "file:///C:/tmp/module_proxy" {
		t.Fatalf("moduleProxyFileURL=%q, want %q", got, "file:///C:/tmp/module_proxy")
	}
}

func TestNormalizeGoModuleResolutionEnvUsesInitialWorkingDirForRelativeProxyRoot(t *testing.T) {
	baseDir := t.TempDir()
	otherDir := t.TempDir()
	relativeProxyRoot := filepath.Join("external", "rules_go_orchestrion_tool", "module_proxy")

	previousBaseDir := moduleProxyResolutionBaseDir
	moduleProxyResolutionBaseDir = baseDir
	defer func() {
		moduleProxyResolutionBaseDir = previousBaseDir
	}()

	previousWD, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	if err := os.Chdir(otherDir); err != nil {
		t.Fatalf("chdir otherDir: %v", err)
	}
	defer func() {
		_ = os.Chdir(previousWD)
	}()

	env, err := normalizeGoModuleResolutionEnv([]string{
		rulesGoOrchestrionModuleProxyRootEnvVar + "=" + relativeProxyRoot,
	})
	if err != nil {
		t.Fatalf("normalizeGoModuleResolutionEnv error: %v", err)
	}
	envMap := envSliceToMap(env)
	wantProxy, err := moduleProxyFileURLFromBase(relativeProxyRoot, baseDir)
	if err != nil {
		t.Fatalf("moduleProxyFileURLFromBase error: %v", err)
	}
	if envMap["GOPROXY"] != wantProxy {
		t.Fatalf("GOPROXY=%q, want %q", envMap["GOPROXY"], wantProxy)
	}
}

func TestExecuteCommandWithJobserverSkipsWovenWarmupWhenDisabled(t *testing.T) {
	sdkDir, callsPath := writeRecordingFakeGoSDK(t)

	cmd := exec.Command("/bin/sh", "-c", "true")
	if err := executeCommandWithJobserver(cmd, nil, "example.com/pkg", sdkDir, sdkDir, false, orchestrionModeTestOptimization, false); err != nil {
		t.Fatalf("executeCommandWithJobserver error: %v", err)
	}

	if data, err := os.ReadFile(callsPath); err == nil {
		t.Fatalf("expected no woven warmup go calls, got:\n%s", string(data))
	} else if !os.IsNotExist(err) {
		t.Fatalf("read calls log: %v", err)
	}
}

func TestExecuteCommandWithJobserverWarmsWovenPackagesWhenEnabled(t *testing.T) {
	sdkDir, callsPath := writeRecordingFakeGoSDK(t)

	cmd := exec.Command("/bin/sh", "-c", "true")
	if err := executeCommandWithJobserver(cmd, nil, "example.com/pkg", sdkDir, sdkDir, false, orchestrionModeTestOptimization, true); err != nil {
		t.Fatalf("executeCommandWithJobserver error: %v", err)
	}

	data, err := os.ReadFile(callsPath)
	if err != nil {
		t.Fatalf("read calls log: %v", err)
	}
	text := string(data)
	if !strings.Contains(text, "list -mod=mod github.com/DataDog/dd-trace-go/v2/ddtrace/tracer github.com/DataDog/dd-trace-go/v2/instrumentation/env") {
		t.Fatalf("expected woven warmup go list call, got:\n%s", text)
	}
}

func TestExecuteCommandWithJobserverSkipsWovenWarmupWhenJobserverStarted(t *testing.T) {
	sdkDir, callsPath := writeRecordingFakeGoSDK(t)

	cmd := exec.Command("/bin/sh", "-c", "true")
	jobserver := &orchestrionJobserver{url: "http://127.0.0.1:1"}
	if err := executeCommandWithJobserver(cmd, jobserver, "example.com/pkg", sdkDir, sdkDir, false, orchestrionModeTestOptimization, true); err != nil {
		t.Fatalf("executeCommandWithJobserver error: %v", err)
	}

	if data, err := os.ReadFile(callsPath); err == nil {
		t.Fatalf("expected no duplicate woven warmup go calls, got:\n%s", string(data))
	} else if !os.IsNotExist(err) {
		t.Fatalf("read calls log: %v", err)
	}
}

func writeRecordingFakeGoSDK(t *testing.T) (string, string) {
	t.Helper()
	sdkDir := t.TempDir()
	binDir := filepath.Join(sdkDir, "bin")
	srcDir := filepath.Join(sdkDir, "src")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatalf("mkdir fake sdk bin: %v", err)
	}
	if err := os.MkdirAll(srcDir, 0o755); err != nil {
		t.Fatalf("mkdir fake sdk src: %v", err)
	}
	callsPath := filepath.Join(t.TempDir(), "go.calls")
	t.Setenv("FAKE_GO_CALLS", callsPath)
	goPath := filepath.Join(binDir, "go")
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_GO_CALLS"
if [ "$1" = "list" ]; then
  cat <<'EOF'
github.com/DataDog/dd-trace-go/v2/ddtrace/tracer
github.com/DataDog/dd-trace-go/v2/instrumentation/env
EOF
  exit 0
fi
if [ "$1" = "mod" ] && [ "$2" = "download" ]; then
  exit 0
fi
exit 0
`
	if err := os.WriteFile(goPath, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake go: %v", err)
	}
	return sdkDir, callsPath
}

func TestNormalizeGoModuleResolutionEnvWithModuleProxy(t *testing.T) {
	proxyRoot := filepath.Join(t.TempDir(), "module_proxy")
	env, err := normalizeGoModuleResolutionEnv([]string{
		rulesGoOrchestrionModuleProxyRootEnvVar + "=" + proxyRoot,
		"GOPROXY=https://proxy.golang.org,direct",
		"GOSUMDB=sum.golang.org",
	})
	if err != nil {
		t.Fatalf("normalizeGoModuleResolutionEnv error: %v", err)
	}
	envMap := envSliceToMap(env)
	wantProxy, err := moduleProxyFileURL(proxyRoot)
	if err != nil {
		t.Fatalf("moduleProxyFileURL error: %v", err)
	}
	if envMap["GOPROXY"] != wantProxy {
		t.Fatalf("GOPROXY=%q, want %q", envMap["GOPROXY"], wantProxy)
	}
	if envMap["GOSUMDB"] != "off" {
		t.Fatalf("GOSUMDB=%q, want off", envMap["GOSUMDB"])
	}
	for _, name := range []string{"GOPRIVATE", "GONOPROXY", "GONOSUMDB"} {
		if value, ok := envMap[name]; !ok || value != "" {
			t.Fatalf("%s=%q, want empty string", name, value)
		}
	}
}

func TestNormalizeGoModuleResolutionEnvPreservesExplicitValues(t *testing.T) {
	env, err := normalizeGoModuleResolutionEnv([]string{
		"GOPROXY=https://example.invalid",
		"GOSUMDB=corp.sumdb",
		"GOPRIVATE=example.com/private",
		"GONOPROXY=example.com/private",
		"GONOSUMDB=example.com/private",
	})
	if err != nil {
		t.Fatalf("normalizeGoModuleResolutionEnv error: %v", err)
	}
	envMap := envSliceToMap(env)
	if envMap["GOPROXY"] != "https://example.invalid" {
		t.Fatalf("GOPROXY=%q", envMap["GOPROXY"])
	}
	if envMap["GOSUMDB"] != "corp.sumdb" {
		t.Fatalf("GOSUMDB=%q", envMap["GOSUMDB"])
	}
	if envMap["GOPRIVATE"] != "example.com/private" {
		t.Fatalf("GOPRIVATE=%q", envMap["GOPRIVATE"])
	}
	if envMap["GONOPROXY"] != "example.com/private" {
		t.Fatalf("GONOPROXY=%q", envMap["GONOPROXY"])
	}
	if envMap["GONOSUMDB"] != "example.com/private" {
		t.Fatalf("GONOSUMDB=%q", envMap["GONOSUMDB"])
	}
}

func TestNormalizeGoModuleResolutionEnvFillsDefaults(t *testing.T) {
	env, err := normalizeGoModuleResolutionEnv(nil)
	if err != nil {
		t.Fatalf("normalizeGoModuleResolutionEnv error: %v", err)
	}
	envMap := envSliceToMap(env)
	if envMap["GOPROXY"] != "https://proxy.golang.org,direct" {
		t.Fatalf("GOPROXY=%q", envMap["GOPROXY"])
	}
	if envMap["GOSUMDB"] != "sum.golang.org" {
		t.Fatalf("GOSUMDB=%q", envMap["GOSUMDB"])
	}
}

func TestNormalizeGoModuleResolutionEnvAbsolutizesRelativeCompilerPaths(t *testing.T) {
	baseDir := t.TempDir()
	previousBaseDir := moduleProxyResolutionBaseDir
	moduleProxyResolutionBaseDir = baseDir
	defer func() {
		moduleProxyResolutionBaseDir = previousBaseDir
	}()

	env, err := normalizeGoModuleResolutionEnv([]string{
		"CC=external/llvm_toolchain/bin/cc_wrapper.sh",
		"CXX='external/llvm_toolchain/bin/cxx wrapper.sh' -stdlib=libc++",
		"FC=external/llvm_toolchain/bin/flang",
	})
	if err != nil {
		t.Fatalf("normalizeGoModuleResolutionEnv error: %v", err)
	}
	envMap := envSliceToMap(env)
	if got, want := envMap["CC"], filepath.Join(baseDir, "external/llvm_toolchain/bin/cc_wrapper.sh"); got != want {
		t.Fatalf("CC=%q, want %q", got, want)
	}
	if got, want := envMap["CXX"], "'"+filepath.Join(baseDir, "external/llvm_toolchain/bin/cxx wrapper.sh")+"' -stdlib=libc++"; got != want {
		t.Fatalf("CXX=%q, want %q", got, want)
	}
	if got, want := envMap["FC"], filepath.Join(baseDir, "external/llvm_toolchain/bin/flang"); got != want {
		t.Fatalf("FC=%q, want %q", got, want)
	}
}

func TestNormalizeGoModuleResolutionEnvPreservesValidCompilerCommands(t *testing.T) {
	env, err := normalizeGoModuleResolutionEnv([]string{
		"CC=clang",
		"CXX=/usr/bin/clang++",
		`FC=C:\Toolchains\flang.exe -O2`,
	})
	if err != nil {
		t.Fatalf("normalizeGoModuleResolutionEnv error: %v", err)
	}
	envMap := envSliceToMap(env)
	if envMap["CC"] != "clang" {
		t.Fatalf("CC=%q, want clang", envMap["CC"])
	}
	if envMap["CXX"] != "/usr/bin/clang++" {
		t.Fatalf("CXX=%q, want /usr/bin/clang++", envMap["CXX"])
	}
	if envMap["FC"] != `C:\Toolchains\flang.exe -O2` {
		t.Fatalf("FC=%q, want Windows absolute path", envMap["FC"])
	}
}

func TestNormalizeGoActionCacheEnvTreatsEmptyValuesAsUnset(t *testing.T) {
	env, err := normalizeGoActionCacheEnv([]string{
		"GOPATH=",
		"GOMODCACHE=",
		"GOCACHE=",
	})
	if err != nil {
		t.Fatalf("normalizeGoActionCacheEnv error: %v", err)
	}
	envMap := envSliceToMap(env)
	if envMap["GOPATH"] == "" || envMap["GOMODCACHE"] == "" || envMap["GOCACHE"] == "" {
		t.Fatalf("normalizeGoActionCacheEnv left cache env empty: %#v", envMap)
	}
	if !strings.Contains(envMap["GOPATH"], "datadog-orchestrion-go-cache") {
		t.Fatalf("GOPATH=%q does not use orchestrion temp cache root", envMap["GOPATH"])
	}
	if envMap["GOMODCACHE"] != filepath.Join(envMap["GOPATH"], "pkg", "mod") {
		t.Fatalf("GOMODCACHE=%q, want %q", envMap["GOMODCACHE"], filepath.Join(envMap["GOPATH"], "pkg", "mod"))
	}
	if envMap["GOCACHE"] != filepath.Join(envMap["GOPATH"], "cache") {
		t.Fatalf("GOCACHE=%q, want %q", envMap["GOCACHE"], filepath.Join(envMap["GOPATH"], "cache"))
	}
}

func TestIsOrchestrionJobserverConnectionFailure(t *testing.T) {
	output := "failed to connect to NATS job server at nats://127.0.0.1:64506 after 15 attempts"
	if !isOrchestrionJobserverConnectionFailure(output) {
		t.Fatalf("isOrchestrionJobserverConnectionFailure(%q) = false, want true", output)
	}
	if isOrchestrionJobserverConnectionFailure("compilepkg: unrelated failure") {
		t.Fatal("isOrchestrionJobserverConnectionFailure matched an unrelated error")
	}
}

func envSliceToMap(env []string) map[string]string {
	result := make(map[string]string, len(env))
	for _, entry := range env {
		parts := strings.SplitN(entry, "=", 2)
		if len(parts) != 2 {
			continue
		}
		result[parts[0]] = parts[1]
	}
	return result
}
