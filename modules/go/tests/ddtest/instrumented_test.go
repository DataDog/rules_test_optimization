// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package ddtestfixture

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/DataDog/ddtest/ddto/propagation"
	"github.com/DataDog/ddtest/ddto/testopt"
)

// Mini gives a test's context its trace only when ddtest instrumented the
// test's testing package and linked Mini.
func TestInstrumented(t *testing.T) {
	if _, ok := propagation.FromContext(testopt.Context(t)); !ok {
		t.Fatal("the test's context has no trace: the test is not instrumented")
	}
}

func TestAuxiliaryProcessKeepsNativeFailure(t *testing.T) {
	if os.Getenv("RTO_AUXILIARY_FAILURE") == "1" {
		t.Cleanup(func() { t.Error("intentional auxiliary failure") })
		return
	}

	child := exec.Command(os.Args[0], "-test.run=^TestAuxiliaryProcessKeepsNativeFailure$", "-test.v")
	// Keep the inherited CI Visibility switch: the macro must prevent ordinary
	// helpers from becoming test sessions, even when process retries are enabled.
	child.Env = append(os.Environ(),
		"RTO_AUXILIARY_FAILURE=1",
		"DD_CIVISIBILITY_RETRY_EXECUTION_MODE=process",
		"DD_CIVISIBILITY_EARLY_FLAKE_DETECTION_ENABLED=false",
		"DD_CIVISIBILITY_FLAKY_RETRY_ENABLED=true",
		"DD_CIVISIBILITY_FLAKY_RETRY_COUNT=1",
		"TEST_UNDECLARED_OUTPUTS_DIR="+t.TempDir(),
	)
	output, err := child.CombinedOutput()
	exitError, ok := err.(*exec.ExitError)
	if !ok || exitError.ExitCode() != 1 ||
		!strings.Contains(string(output), "--- FAIL: TestAuxiliaryProcessKeepsNativeFailure") ||
		!strings.Contains(string(output), "intentional auxiliary failure") {
		t.Fatalf("auxiliary test lost its native failure: %v\n%s", err, output)
	}
}
