package main

import "testing"

func TestValidateOrchestrionMode(t *testing.T) {
	for _, mode := range []string{"", orchestrionModeGeneral, orchestrionModeTestOptimization} {
		got, err := validateOrchestrionMode(mode)
		if err != nil {
			t.Fatalf("validateOrchestrionMode(%q) error: %v", mode, err)
		}
		if mode == "" {
			mode = orchestrionModeGeneral
		}
		if got != mode {
			t.Fatalf("validateOrchestrionMode(%q) = %q, want %q", mode, got, mode)
		}
	}
	if _, err := validateOrchestrionMode("invalid"); err == nil {
		t.Fatal("validateOrchestrionMode accepted invalid mode")
	}
}
