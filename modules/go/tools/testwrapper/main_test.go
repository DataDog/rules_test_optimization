// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestChild(t *testing.T) {
	if os.Getenv("TOPT_WRAPPER_CHILD") != "1" {
		return
	}
	// Both configured and runtime arguments must arrive unchanged. In
	// particular, cmd.exe delayed expansion must not interpret !missing!.
	want := []string{"", `one"quote&`, "%PATH%", "bang!missing!", "a&b|c<d>e^f", "trailing\\", "λ words"}
	if !reflect.DeepEqual(os.Args[len(os.Args)-len(want):], want) {
		os.Exit(9)
	}
	os.Exit(7)
}

func TestLaunchPreservesArgsMetadataAndExitStatus(t *testing.T) {
	root := t.TempDir()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	launcher := filepath.Join(root, "nested launcher.exe")
	child := filepath.Join(root, "child.exe")
	binary, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(child, binary, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := configuration{Actual: "child.exe", Metadata: "metadata.json", Args: []string{"-test.run=^TestChild$", "--", "", `one"quote&`, "%PATH%"}}
	// Match the launcher's relative path to its neighboring raw executable.
	body, _ := json.Marshal(cfg)
	if err := os.WriteFile(launcher+".json", body, 0o600); err != nil {
		t.Fatal(err)
	}
	metadata := []byte(`{"bazel.target":"//fixture:test"}`)
	if err := os.WriteFile(filepath.Join(root, cfg.Metadata), metadata, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TOPT_WRAPPER_CHILD", "1")
	t.Setenv("TEST_UNDECLARED_OUTPUTS_DIR", root)
	var output bytes.Buffer
	code := run(launcher, []string{"bang!missing!", "a&b|c<d>e^f", "trailing\\", "λ words"}, nil, &output, &output)
	if code != 7 {
		t.Fatalf("exit=%d: %s", code, &output)
	}
	actual, err := os.ReadFile(filepath.Join(root, "bazel_target_metadata.json"))
	if err != nil || !bytes.Equal(actual, metadata) {
		t.Fatalf("metadata=%q, err=%v", actual, err)
	}
}

func TestMissingConfigurationFailsWithoutExecuting(t *testing.T) {
	var output bytes.Buffer
	if code := run(filepath.Join(t.TempDir(), "missing.exe"), nil, nil, &output, &output); code != 1 {
		t.Fatalf("exit=%d", code)
	}
	if !bytes.Contains(output.Bytes(), []byte("ddtest_go_test:")) {
		t.Fatal(&output)
	}
}

func TestInvalidConfigurationFails(t *testing.T) {
	for _, body := range []string{"{", `{}`, `{"actual":"child.exe"}`, `{"actual":"child.exe","metadata":"meta.json","args":5}`} {
		t.Run(body, func(t *testing.T) {
			launcher := filepath.Join(t.TempDir(), "test.exe")
			if err := os.WriteFile(launcher+".json", []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			var output bytes.Buffer
			if code := run(launcher, nil, nil, &output, &output); code != 1 || !bytes.Contains(output.Bytes(), []byte("ddtest_go_test:")) {
				t.Fatalf("exit=%d, output=%s", code, &output)
			}
		})
	}
}

func TestMissingMetadataFailsBeforeStartingChild(t *testing.T) {
	root := t.TempDir()
	launcher := filepath.Join(root, "test.exe")
	if err := os.WriteFile(launcher+".json", []byte(`{"actual":"absent.exe","metadata":"absent.json"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TEST_UNDECLARED_OUTPUTS_DIR", root)
	var output bytes.Buffer
	if code := run(launcher, nil, nil, &output, &output); code != 1 || !bytes.Contains(output.Bytes(), []byte("absent.json")) {
		t.Fatalf("exit=%d, output=%s", code, &output)
	}
}
