// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

// Command testwrapper launches a Windows test without cmd reinterpreting argv.
// The per-test configuration is a declared file beside the launcher symlink.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

type configuration struct {
	Actual   string   `json:"actual"`
	Metadata string   `json:"metadata"`
	Args     []string `json:"args"`
}

func main() { os.Exit(run(os.Args[0], os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }

func run(launcher string, extra []string, stdin io.Reader, stdout, stderr io.Writer) int {
	contents, err := os.ReadFile(launcher + ".json")
	var cfg configuration
	if err == nil {
		err = json.Unmarshal(contents, &cfg)
	}
	if err == nil && (cfg.Actual == "" || cfg.Metadata == "") {
		err = errors.New("incomplete launcher configuration")
	}
	if err != nil {
		fmt.Fprintln(stderr, "ddtest_go_test:", err)
		return 1
	}
	dir := filepath.Dir(launcher)
	if output := os.Getenv("TEST_UNDECLARED_OUTPUTS_DIR"); output != "" {
		metadata, readErr := os.ReadFile(filepath.Join(dir, filepath.FromSlash(cfg.Metadata)))
		if readErr != nil {
			fmt.Fprintln(stderr, "ddtest_go_test:", readErr)
			return 1
		}
		if err := os.WriteFile(filepath.Join(output, "bazel_target_metadata.json"), metadata, 0o644); err != nil {
			fmt.Fprintln(stderr, "ddtest_go_test:", err)
			return 1
		}
	}
	cmd := exec.Command(filepath.Join(dir, filepath.FromSlash(cfg.Actual)), append(cfg.Args, extra...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = stdin, stdout, stderr
	if err := cmd.Run(); err != nil {
		var exited *exec.ExitError
		if errors.As(err, &exited) {
			return exited.ExitCode()
		}
		fmt.Fprintln(stderr, "ddtest_go_test:", err)
		return 1
	}
	return 0
}
