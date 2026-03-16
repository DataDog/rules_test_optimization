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
	"os"
	"os/exec"
	"runtime"
	"strings"
	"syscall"
)

// filterBuildID executes the tool on the command line, filtering out any
// -buildid arguments. It is intended to be used with -toolexec.
func filterBuildID(args []string) error {
	newArgs := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "-buildid" {
			i++
			continue
		}
		newArgs = append(newArgs, arg)
	}
	if orchestrion := strings.TrimSpace(os.Getenv("RULES_GO_ORCHESTRION_FILTERBUILDID")); orchestrion != "" {
		orchestrionArgs := []string{orchestrion}
		logLevel := os.Getenv("ORCHESTRION_LOG_LEVEL")
		if logLevel == "" && os.Getenv("ORCHESTRION_DEBUG_TRACE") == "1" {
			logLevel = "TRACE"
		}
		if logLevel != "" {
			orchestrionArgs = append(orchestrionArgs, "--log-level="+logLevel)
		}
		orchestrionArgs = append(orchestrionArgs, "toolexec")
		newArgs = append(orchestrionArgs, newArgs...)
	}
	if runtime.GOOS == "windows" {
		cmd := exec.Command(newArgs[0], newArgs[1:]...)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd.Run()
	} else {
		return syscall.Exec(newArgs[0], newArgs, os.Environ())
	}
}

// orchestrionFilterBuildID is a stdlib-focused toolexec wrapper.
// Some stdlib compiles arrive without TOOLEXEC_IMPORTPATH even though the
// compile command still carries `-p <importpath>`. Orchestrion needs the import
// path for aspect matching, so restore it before delegating to
// `orchestrion toolexec builder filterbuildid ...`.
func orchestrionFilterBuildID(args []string) error {
	if len(args) == 0 {
		return filterBuildID(args)
	}

	orchestrion := args[0]
	toolArgs := args[1:]
	workdir := ""
	if len(toolArgs) > 0 && strings.HasPrefix(toolArgs[0], "--workdir=") {
		workdir = strings.TrimPrefix(toolArgs[0], "--workdir=")
		toolArgs = toolArgs[1:]
	}
	if workdir == "" {
		workdir = strings.TrimSpace(os.Getenv("RULES_GO_ORCHESTRION_WORKDIR"))
	}
	if workdir != "" {
		if err := os.Chdir(workdir); err != nil {
			return err
		}
	}
	newArgs := make([]string, 0, len(toolArgs))
	for i := 0; i < len(toolArgs); i++ {
		arg := toolArgs[i]
		if arg == "-buildid" {
			i++
			continue
		}
		newArgs = append(newArgs, arg)
	}
	if strings.TrimSpace(os.Getenv("TOOLEXEC_IMPORTPATH")) == "" {
		if pkg := packageFromCompileArgs(newArgs); pkg != "" {
			_ = os.Setenv("TOOLEXEC_IMPORTPATH", pkg)
		}
	}
	orchestrionArgs := []string{orchestrion}
	logLevel := os.Getenv("ORCHESTRION_LOG_LEVEL")
	if logLevel == "" && os.Getenv("ORCHESTRION_DEBUG_TRACE") == "1" {
		logLevel = "TRACE"
	}
	if logLevel != "" {
		orchestrionArgs = append(orchestrionArgs, "--log-level="+logLevel)
	}
	orchestrionArgs = append(orchestrionArgs, "toolexec")
	orchestrionArgs = append(orchestrionArgs, newArgs...)
	cmd := exec.Command(orchestrionArgs[0], orchestrionArgs[1:]...)
	cmd.Env = os.Environ()
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func packageFromCompileArgs(args []string) string {
	for i := 0; i < len(args); i++ {
		if args[i] == "-p" && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}
