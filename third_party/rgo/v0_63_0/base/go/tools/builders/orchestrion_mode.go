// Copyright 2026 The Bazel Go Rules Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import "fmt"

const (
	// orchestrionModeGeneral preserves the current generic Orchestrion behavior.
	orchestrionModeGeneral = "general"
	// orchestrionModeTestOptimization enables Test Optimization-specific build input and closure choices.
	orchestrionModeTestOptimization = "test_optimization"
)

// validateOrchestrionMode normalizes and validates the builder-facing Orchestrion mode flag.
func validateOrchestrionMode(mode string) (string, error) {
	switch mode {
	case "", orchestrionModeGeneral:
		return orchestrionModeGeneral, nil
	case orchestrionModeTestOptimization:
		return orchestrionModeTestOptimization, nil
	default:
		return "", fmt.Errorf("invalid Orchestrion mode %q; expected %q or %q", mode, orchestrionModeGeneral, orchestrionModeTestOptimization)
	}
}

// effectiveOrchestrionMode returns the mode that should be used by helper code
// that receives env values constructed directly by tests or legacy callers.
func effectiveOrchestrionMode(mode string) string {
	if mode == orchestrionModeTestOptimization {
		return orchestrionModeTestOptimization
	}
	return orchestrionModeGeneral
}
