// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package sdkvariants_test

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

func runfile(t *testing.T, env string) string {
	t.Helper()
	path, err := runfiles.Rlocation(os.Getenv(env))
	if err != nil {
		t.Fatalf("%s: %v", env, err)
	}
	return path
}

// The companion's MODULE.bazel instruments Go 1.26.3 by default and Go
// 1.25.9 with boringcrypto for sdk_version "1.25.9fips".
func TestDataBinariesBuildWithTheRequestedSDK(t *testing.T) {
	for env, want := range map[string]string{
		"GO_VERSION_TOOL":      "go1.26.3",
		"GO_VERSION_TOOL_1_26": "go1.26.3",
		"GO_VERSION_TOOL_FIPS": "go1.25.9 X:boringcrypto",
	} {
		out, err := exec.Command(runfile(t, env)).Output()
		if err != nil {
			t.Fatalf("%s: %v", env, err)
		}
		if got := strings.TrimSpace(string(out)); got != want {
			t.Errorf("%s printed %q, want %q", env, got, want)
		}
	}
}

func TestExecToolImportingTestingRuns(t *testing.T) {
	out, err := os.ReadFile(runfile(t, "TESTING_TOOL_OUTPUT"))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(out)); got != "short=false" {
		t.Errorf("testing_tool printed %q, want short=false", got)
	}
}
