// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package asmcflags

import "testing"

func TestAsmCflags(t *testing.T) {
	if got, want := Value(), 123; got != want {
		t.Fatalf("Value() = %d, want %d", got, want)
	}
}
