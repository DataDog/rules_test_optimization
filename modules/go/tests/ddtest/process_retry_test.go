// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package ddtestfixture

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/DataDog/ddtest/ddto/propagation"
	"github.com/DataDog/ddtest/ddto/testopt"
)

func TestManagedProcessRetryRunsInNewProcess(t *testing.T) {
	// Bazel owns this directory across attempts; t.TempDir would be removed
	// before the deferred child runs. No timing or private retry API is needed.
	directory := os.Getenv("TEST_TMPDIR")
	if directory == "" {
		t.Fatal("this regression must run under Bazel")
	}
	marker := filepath.Join(directory, "managed-retry-pid")
	pid := strconv.Itoa(os.Getpid())
	file, err := os.OpenFile(marker, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err == nil {
		if _, ok := propagation.FromContext(testopt.Context(t)); !ok {
			file.Close()
			t.Fatal("the original attempt is not instrumented")
		}
		if _, err := file.WriteString(pid); err != nil {
			file.Close()
			t.Fatal(err)
		}
		if err := file.Close(); err != nil {
			t.Fatal(err)
		}
		t.Fatal("the original attempt fails to require a managed process retry")
	}
	if !errors.Is(err, os.ErrExist) {
		t.Fatal(err)
	}
	originalPID, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if value, err := strconv.Atoi(string(originalPID)); err != nil || value <= 0 {
		t.Fatalf("the original attempt did not record its PID: %q", originalPID)
	}
	if string(originalPID) == pid {
		t.Fatal("the retry reused the original process")
	}
}
