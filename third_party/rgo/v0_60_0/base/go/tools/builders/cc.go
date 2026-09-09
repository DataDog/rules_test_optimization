package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

// absCCCompiler modifies CGO flags to workaround relative paths.
// Because go is having its own sandbox, all CGO flags should use
// absolute paths. However, CGO flags are embedded in the output
// so we cannot use absolute paths directly. Instead, use a placeholder
// for the absolute path and we replace CC with this builder so that
// we can expand the placeholder later.
func absCCCompiler(envNameList []string, argList []string) error {
	wrapped := cgoCompilerWrapperEnv(os.Environ(), envNameList, argList, abs("."), abs(os.Args[0]))
	for _, envName := range append([]string{"GO_CC", "GO_CC_ROOT", "CC"}, envNameList...) {
		if err := os.Setenv(envName, getEnv(wrapped, envName)); err != nil {
			return err
		}
	}
	return nil
}

// normalizeGoSubprocessCompilerEnv keeps Bazel compiler commands and
// path-bearing CGO flags anchored to the builder's initial working directory.
func normalizeGoSubprocessCompilerEnv(environ []string) []string {
	env := normalizeGoCompilerCommandEnv(append([]string{}, environ...))
	if getEnv(env, "CGO_ENABLED") != "1" {
		return env
	}
	return cgoCompilerWrapperEnv(
		env,
		cgoEnvVars,
		cgoAbsEnvFlags,
		moduleProxyResolutionBaseDir,
		absolutePathFromBase(os.Args[0], moduleProxyResolutionBaseDir),
	)
}

// cgoCompilerWrapperEnv prepares a Go subprocess to invoke the Bazel C
// compiler through this builder. Go runs C compilation from package-specific
// directories, so both the compiler and path-bearing CGO flags must remain
// anchored to the original execroot.
func cgoCompilerWrapperEnv(environ []string, envNameList, argList []string, root, builder string) []string {
	env := append([]string{}, environ...)
	if goCC := strings.TrimSpace(getEnv(env, "GO_CC")); goCC != "" && getEnv(env, "GO_CC_ROOT") != "" {
		// GoStdlib already installed the wrapper in the parent process. Keep it
		// idempotent, but normalize the wrapped compiler for nested go commands.
		return setEnv(env, "GO_CC", normalizeGoCompilerCommand(goCC, root))
	}

	cc := strings.TrimSpace(getEnv(env, "CC"))
	if cc == "" {
		return env
	}
	env = setEnv(env, "GO_CC", normalizeGoCompilerCommand(cc, root))
	env = setEnv(env, "GO_CC_ROOT", root)
	env = setEnv(env, "CC", quoteCommandArgs([]string{builder, "cc"}))
	for _, envName := range envNameList {
		args := strings.Fields(getEnv(env, envName))
		transformArgs(args, argList, func(path string) string {
			if filepath.IsAbs(path) || strings.HasPrefix(path, cgoAbsPlaceholder) {
				return path
			}
			return cgoAbsPlaceholder + path
		})
		env = setEnv(env, envName, strings.Join(args, " "))
	}
	return env
}

func cc(args []string) error {
	cc := os.Getenv("GO_CC")
	if cc == "" {
		return errors.New("GO_CC environment variable not set")
	}
	ccroot := os.Getenv("GO_CC_ROOT")
	if ccroot == "" {
		return errors.New("GO_CC_ROOT environment variable not set")
	}

	normalized, err := splitGoCommandArgs(cc)
	if err != nil {
		return fmt.Errorf("parse GO_CC command: %w", err)
	}
	if len(normalized) == 0 {
		return errors.New("GO_CC environment variable contains no command")
	}
	normalized = append(normalized, args...)
	transformArgs(normalized, cgoAbsEnvFlags, func(s string) string {
		if strings.HasPrefix(s, cgoAbsPlaceholder) {
			trimmed := strings.TrimPrefix(s, cgoAbsPlaceholder)
			abspath := filepath.Join(ccroot, trimmed)
			if _, err := os.Stat(abspath); err == nil {
				// Only return the abspath if it exists, otherwise it
				// means that either it won't have any effect or the original
				// value was not a relpath (e.g. a path with a XCODE placehold from
				// macos cc_wrapper)
				return abspath
			}
			return trimmed
		}
		return s
	})
	// The go command derives this seed from its action ID. That ID contains the
	// absolute -toolexec path, so otherwise identical stdlib actions running in
	// different Bazel sandboxes make the CGO archive outputs differ. Recompute
	// the seed from the compiler command after replacing ephemeral roots.
	normalizeCgoRandomSeed(normalized, ccroot)
	if runtime.GOOS == "windows" {
		cmd := exec.Command(normalized[0], normalized[1:]...)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	} else {
		return syscall.Exec(normalized[0], normalized, os.Environ())
	}
}

const cgoRandomSeedPrefix = "-frandom-seed="

func normalizeCgoRandomSeed(args []string, execRoot string) {
	hasRandomSeed := false
	for _, arg := range args {
		if strings.HasPrefix(arg, cgoRandomSeedPrefix) {
			hasRandomSeed = true
			break
		}
	}
	if !hasRandomSeed {
		return
	}

	workRoot := goBuildWorkRoot(args)
	digest := sha256.New()
	for _, arg := range args {
		if strings.HasPrefix(arg, cgoRandomSeedPrefix) {
			continue
		}
		normalized := arg
		if workRoot != "" {
			normalized = strings.ReplaceAll(normalized, workRoot, "$WORK")
		}
		if execRoot != "" {
			normalized = strings.ReplaceAll(normalized, execRoot, "$EXECROOT")
		}
		_, _ = io.WriteString(digest, normalized)
		_, _ = digest.Write([]byte{0})
	}
	seed := cgoRandomSeedPrefix + hex.EncodeToString(digest.Sum(nil))
	for i, arg := range args {
		if strings.HasPrefix(arg, cgoRandomSeedPrefix) {
			args[i] = seed
		}
	}
}

func goBuildWorkRoot(args []string) string {
	for i := 0; i+1 < len(args); i++ {
		if args[i] != "-o" && args[i] != "-c" {
			continue
		}
		for dir := filepath.Dir(args[i+1]); ; dir = filepath.Dir(dir) {
			base := filepath.Base(dir)
			if strings.HasPrefix(base, "go-build") {
				return dir
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
		}
	}
	return ""
}
