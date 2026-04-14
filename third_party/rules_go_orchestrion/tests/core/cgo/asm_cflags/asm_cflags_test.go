package asmcflags

import "testing"

func TestAsmCflags(t *testing.T) {
	if got, want := Value(), 123; got != want {
		t.Fatalf("Value() = %d, want %d", got, want)
	}
}
