// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package ddtestfixture

import (
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
