// Copyright 2017 The Bazel Authors. All rights reserved.
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
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
)

// runCommandWithJobserver executes a subprocess with the orchestrion jobserver
// URL set in the environment if a jobserver is provided. If importPath is
// non-empty, TOOLEXEC_IMPORTPATH is also set for orchestrion. The Go SDK's bin
// directory is prepended to PATH so orchestrion can find the `go` binary.
func (e *env) runCommandWithJobserver(args []string, jobserver *orchestrionJobserver, importPath string) error {
	span := beginProbe(
		"env.run_command_with_jobserver",
		newProbeField("argv0", filepath.Base(args[0])),
		newProbeField("arg_count", strconv.Itoa(len(args)-1)),
		newProbeField("import_path", importPath),
		newProbeField("jobserver", strconv.FormatBool(jobserver != nil && jobserver.URL() != "")),
	)
	cmd := exec.Command(args[0], args[1:]...)
	buf := &bytes.Buffer{}
	cmd.Stdout = buf
	cmd.Stderr = buf
	if cmd.Env == nil {
		cmd.Env = os.Environ()
	}
	if e.stdlibCache != "" {
		if info, err := os.Stat(e.stdlibCache); err == nil && info.IsDir() {
			cmd.Env = setEnv(cmd.Env, "GOCACHE", e.stdlibCache)
			cmd.Env = setEnv(cmd.Env, orchestrionStdlibCacheEnvVar, e.stdlibCache)
		}
	}
	goRootPath := e.goroot
	if goRootPath == "" {
		goRootPath = os.Getenv("GOROOT")
	}
	err := executeCommandWithJobserver(cmd, jobserver, importPath, e.sdk, goRootPath, e.verbose)
	span.End(err)
	os.Stderr.Write(relativizePaths(buf.Bytes()))
	return err
}
