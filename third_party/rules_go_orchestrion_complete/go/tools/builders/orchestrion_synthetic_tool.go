// Copyright 2018 The Bazel Authors. All rights reserved.
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

import (
	"io"
	"os"
)

// syntheticOrchestrionToolGoGeneral materializes the generic tools package that
// pins Orchestrion and every dd-trace-go integration required by generic
// Orchestrion workflows.
const syntheticOrchestrionToolGoGeneral = `//go:build tools

package tools

import (
	_ "github.com/DataDog/orchestrion"
	_ "github.com/DataDog/dd-trace-go/v2/orchestrion"
	_ "github.com/DataDog/dd-trace-go/contrib/net/http/v2"
	_ "github.com/DataDog/dd-trace-go/contrib/log/slog/v2"
)
`

// syntheticOrchestrionToolGoTestOptimization keeps the action-time synthetic
// module scoped to CI Visibility packages needed by dd_topt_go_test.
const syntheticOrchestrionToolGoTestOptimization = `//go:build tools

package tools

import (
	_ "github.com/DataDog/orchestrion"
	_ "github.com/DataDog/dd-trace-go/v2/orchestrion"
)
`

// syntheticOrchestrionToolGo preserves the historical generic synthetic module
// content for existing tests and generic Orchestrion callers.
const syntheticOrchestrionToolGo = syntheticOrchestrionToolGoGeneral

// syntheticOrchestrionToolGoForMode returns the synthetic module pin file for
// the selected Orchestrion mode.
func syntheticOrchestrionToolGoForMode(mode string) string {
	if effectiveOrchestrionMode(mode) == orchestrionModeTestOptimization {
		return syntheticOrchestrionToolGoTestOptimization
	}
	return syntheticOrchestrionToolGoGeneral
}

// copyArchiveFile copies generated archive and cache artifacts without
// preserving the original file mode or link relationship.
func copyArchiveFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}
