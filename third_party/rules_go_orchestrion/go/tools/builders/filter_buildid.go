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

func filterBuildIDMustGetwd() string {
	wd, err := os.Getwd()
	if err != nil {
		return "<getwd error: " + err.Error() + ">"
	}
	return wd
}

func appendOrchestrionFilterLog(line string) {
	f, err := os.OpenFile("/tmp/orchestrionfilterbuildid.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(line + "\n")
}

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
	debugTrace := os.Getenv("ORCHESTRION_DEBUG_TRACE") == "1"
	workdir := ""
	if len(toolArgs) > 0 && strings.HasPrefix(toolArgs[0], "--workdir=") {
		workdir = strings.TrimPrefix(toolArgs[0], "--workdir=")
		toolArgs = toolArgs[1:]
	}
	if workdir == "" {
		workdir = strings.TrimSpace(os.Getenv("RULES_GO_ORCHESTRION_WORKDIR"))
	}
	mentionsTesting := strings.Contains(strings.Join(toolArgs, " "), "testing")
	if mentionsTesting {
		line := "orchestrionfilterbuildid: bootstrap ORCHESTRION_DEBUG_TRACE=" + os.Getenv("ORCHESTRION_DEBUG_TRACE") +
			" workdir=" + workdir + " cwd_before=" + filterBuildIDMustGetwd()
		_, _ = os.Stderr.WriteString(line + "\n")
		appendOrchestrionFilterLog(line)
	}
	if workdir != "" {
		if err := os.Chdir(workdir); err != nil {
			line := "orchestrionfilterbuildid: failed chdir to RULES_GO_ORCHESTRION_WORKDIR=" + workdir + ": " + err.Error()
			if debugTrace || mentionsTesting {
				_, _ = os.Stderr.WriteString(line + "\n")
			}
			appendOrchestrionFilterLog(line)
		} else if debugTrace || mentionsTesting {
			line := "orchestrionfilterbuildid: chdir RULES_GO_ORCHESTRION_WORKDIR=" + workdir + " cwd_after=" + filterBuildIDMustGetwd()
			_, _ = os.Stderr.WriteString(line + "\n")
			appendOrchestrionFilterLog(line)
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
	if debugTrace {
		_, _ = os.Stderr.WriteString("orchestrionfilterbuildid: tool args=" + strings.Join(newArgs, " ") + "\n")
		appendOrchestrionFilterLog("tool args=" + strings.Join(newArgs, " "))
	}
	logTestingPackage := false
	if strings.TrimSpace(os.Getenv("TOOLEXEC_IMPORTPATH")) == "" {
		if pkg := packageFromCompileArgs(newArgs); pkg != "" {
			_ = os.Setenv("TOOLEXEC_IMPORTPATH", pkg)
			logTestingPackage = pkg == "testing"
			if debugTrace {
				_, _ = os.Stderr.WriteString("orchestrionfilterbuildid: synthesized TOOLEXEC_IMPORTPATH=" + pkg + "\n")
				appendOrchestrionFilterLog("synthesized TOOLEXEC_IMPORTPATH=" + pkg)
			}
		}
	} else if debugTrace {
		_, _ = os.Stderr.WriteString("orchestrionfilterbuildid: existing TOOLEXEC_IMPORTPATH=" + os.Getenv("TOOLEXEC_IMPORTPATH") + "\n")
		appendOrchestrionFilterLog("existing TOOLEXEC_IMPORTPATH=" + os.Getenv("TOOLEXEC_IMPORTPATH"))
		logTestingPackage = strings.TrimSpace(os.Getenv("TOOLEXEC_IMPORTPATH")) == "testing"
	}
	if logTestingPackage || mentionsTesting {
		line := "orchestrionfilterbuildid: testing-related compile TOOLEXEC_IMPORTPATH=" + os.Getenv("TOOLEXEC_IMPORTPATH") + " args=" + strings.Join(newArgs, " ")
		_, _ = os.Stderr.WriteString(line + "\n")
		appendOrchestrionFilterLog(line)
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
