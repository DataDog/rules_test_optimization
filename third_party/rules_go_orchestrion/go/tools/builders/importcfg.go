// Copyright 2019 The Bazel Authors. All rights reserved.
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
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

var orchestrionInstrumentedStdlibPackages = []string{
	"testing",
}

type archive struct {
	label, importPath, packagePath, file string
	importPathAliases                    []string
}

// checkImports verifies that each import in files refers to a
// direct dependency in archives or to a standard library package
// listed in the file at stdPackageListPath. checkImports returns
// a map from source import paths to elements of archives or to nil
// for standard library packages.
func checkImports(files []fileInfo, archives []archive, stdPackageListPath string, importPath string, recompileInternalDeps []string) (map[string]*archive, error) {
	// Read the standard package list.
	packagesTxt, err := ioutil.ReadFile(stdPackageListPath)
	if err != nil {
		return nil, err
	}
	stdPkgs := make(map[string]bool)
	for len(packagesTxt) > 0 {
		n := bytes.IndexByte(packagesTxt, '\n')
		var line string
		if n < 0 {
			line = string(packagesTxt)
			packagesTxt = nil
		} else {
			line = string(packagesTxt[:n])
			packagesTxt = packagesTxt[n+1:]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		stdPkgs[line] = true
	}

	// Index the archives.
	importToArchive := make(map[string]*archive)
	importAliasToArchive := make(map[string]*archive)
	for i := range archives {
		arc := &archives[i]
		importToArchive[arc.importPath] = arc
		for _, imp := range arc.importPathAliases {
			importAliasToArchive[imp] = arc
		}
	}
	// Construct recompileInternalDeps as a map to check if there are imports that are disallowed.
	recompileInternalDepMap := make(map[string]struct{})
	for _, dep := range recompileInternalDeps {
		recompileInternalDepMap[dep] = struct{}{}
	}
	// Build the import map.
	imports := make(map[string]*archive)
	var derr depsError
	for _, f := range files {
		for _, imp := range f.imports {
			path := imp.path
			if _, ok := imports[path]; ok || path == "C" || isRelative(path) {
				// TODO(#1645): Support local (relative) import paths. We don't emit
				// errors for them here, but they will probably break something else.
				continue
			}
			if _, ok := recompileInternalDepMap[path]; ok {
				return nil, fmt.Errorf("dependency cycle detected between %q and %q in file %q", importPath, path, f.filename)
			}
			if stdPkgs[path] {
				imports[path] = nil
			} else if arc := importToArchive[path]; arc != nil {
				imports[path] = arc
			} else if arc := importAliasToArchive[path]; arc != nil {
				imports[path] = arc
			} else {
				derr.missing = append(derr.missing, missingDep{f.filename, path})
			}
		}
	}
	if len(derr.missing) > 0 {
		return nil, derr
	}
	return imports, nil
}

// buildImportcfgFileForCompile writes an importcfg file to be consumed by the
// compiler. The file is constructed from direct dependencies and std imports.
// The caller is responsible for deleting the importcfg file.
func buildImportcfgFileForCompile(imports map[string]*archive, installSuffix, dir string) (string, error) {
	buf := &bytes.Buffer{}
	goroot, ok := os.LookupEnv("GOROOT")
	if !ok {
		return "", errors.New("GOROOT not set")
	}
	goroot = abs(goroot)

	sortedImports := make([]string, 0, len(imports))
	for imp := range imports {
		sortedImports = append(sortedImports, imp)
	}
	sort.Strings(sortedImports)

	for _, imp := range sortedImports {
		if arc := imports[imp]; arc == nil {
			// std package
			path := filepath.Join(goroot, "pkg", installSuffix, filepath.FromSlash(imp))
			fmt.Fprintf(buf, "packagefile %s=%s.a\n", imp, path)
		} else {
			if imp != arc.packagePath {
				fmt.Fprintf(buf, "importmap %s=%s\n", imp, arc.packagePath)
			}
			fmt.Fprintf(buf, "packagefile %s=%s\n", arc.packagePath, arc.file)
		}
	}

	f, err := ioutil.TempFile(dir, "importcfg")
	if err != nil {
		return "", err
	}
	filename := f.Name()
	if _, err := io.Copy(f, buf); err != nil {
		f.Close()
		os.Remove(filename)
		return "", err
	}
	if err := f.Close(); err != nil {
		os.Remove(filename)
		return "", err
	}
	return filename, nil
}

func buildImportcfgFileForLink(archives []archive, stdPackageListPath, installSuffix, dir string) (string, error) {
	buf := &bytes.Buffer{}
	goroot, ok := os.LookupEnv("GOROOT")
	if !ok {
		return "", errors.New("GOROOT not set")
	}
	prefix := abs(filepath.Join(goroot, "pkg", installSuffix))
	stdPackageListFile, err := os.Open(stdPackageListPath)
	if err != nil {
		return "", err
	}
	defer stdPackageListFile.Close()
	scanner := bufio.NewScanner(stdPackageListFile)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fmt.Fprintf(buf, "packagefile %s=%s.a\n", line, filepath.Join(prefix, filepath.FromSlash(line)))
	}
	if err := scanner.Err(); err != nil {
		return "", err
	}
	depsSeen := map[string]string{}
	for _, arc := range archives {
		if prevLabel, ok := depsSeen[arc.packagePath]; ok {
			return "", fmt.Errorf(`
package conflict error: %s: multiple copies of package passed to linker:
    %s
    %s
Set "importmap" to different paths or use 'bazel cquery' to ensure only one
package with this path is linked.`,
				arc.packagePath,
				arc.importPath,
				prevLabel)
		}
		// TODO(zbarsky): The labels are empty, and `importPath` contains the label.
		// The parsing is incorrect because arrchiveMultiFlag assuming the formatting from
		// `compilepkg.bzl` but `_format_archive` in `link.bzl` formats differently.
		depsSeen[arc.packagePath] = arc.importPath
		fmt.Fprintf(buf, "packagefile %s=%s\n", arc.packagePath, arc.file)
	}
	f, err := ioutil.TempFile(dir, "importcfg")
	if err != nil {
		return "", err
	}
	filename := f.Name()
	if _, err := io.Copy(f, buf); err != nil {
		f.Close()
		os.Remove(filename)
		return "", err
	}
	if err := f.Close(); err != nil {
		os.Remove(filename)
		return "", err
	}
	return filename, nil
}

func rewriteImportcfgForOrchestrionStdlib(importcfgPath string, goenv *env) error {
	if goenv == nil || goenv.sdk == "" || goenv.goroot == "" {
		return nil
	}

	exports, err := resolveInstrumentedStdlibExports(goenv, orchestrionInstrumentedStdlibPackages)
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		return nil
	}

	data, err := os.ReadFile(importcfgPath)
	if err != nil {
		return err
	}

	lines := strings.Split(string(data), "\n")
	replaced := 0
	for i, line := range lines {
		if !strings.HasPrefix(line, "packagefile ") {
			continue
		}
		rest := strings.TrimPrefix(line, "packagefile ")
		parts := strings.SplitN(rest, "=", 2)
		if len(parts) != 2 {
			continue
		}
		if exportPath, ok := exports[parts[0]]; ok && exportPath != "" {
			lines[i] = fmt.Sprintf("packagefile %s=%s", parts[0], exportPath)
			replaced++
		}
	}

	if replaced == 0 {
		return nil
	}

	updated := strings.Join(lines, "\n")
	if err := os.WriteFile(importcfgPath, []byte(updated), 0o644); err != nil {
		return err
	}
	if os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
		fmt.Fprintf(os.Stderr, "orchestrion link debug: rewrote %d stdlib packagefile entries in %s\n", replaced, importcfgPath)
	}
	return nil
}

func resolveInstrumentedStdlibExports(goenv *env, packages []string) (map[string]string, error) {
	if len(packages) == 0 {
		return nil, nil
	}
	exports := make(map[string]string, len(packages))
	remaining := make([]string, 0, len(packages))
	for _, pkg := range packages {
		if pkg == "testing" {
			if archivePath, err := findWovenTestingArchive(goenv.goroot); err != nil {
				return nil, err
			} else if archivePath != "" {
				exports[pkg] = archivePath
				continue
			}
		}
		remaining = append(remaining, pkg)
	}
	if len(remaining) == 0 {
		return exports, nil
	}
	if info, err := os.Stat(goenv.goroot); err != nil || !info.IsDir() {
		if os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
			fmt.Fprintf(os.Stderr, "orchestrion link debug: skipping stdlib export resolution, goroot unavailable: %s err=%v\n", goenv.goroot, err)
		}
		return nil, nil
	}
	if err := ensureGoRootCompatibility(goenv.goroot, goenv.sdk, os.Getenv("ORCHESTRION_DEBUG_TRACE") != ""); err != nil {
		return nil, err
	}
	gorootSrc := filepath.Join(goenv.goroot, "src")
	if info, err := os.Stat(gorootSrc); err != nil || !info.IsDir() {
		if os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
			fmt.Fprintf(os.Stderr, "orchestrion link debug: skipping stdlib export resolution, goroot/src unavailable: %s err=%v\n", gorootSrc, err)
		}
		return nil, nil
	}

	args := append(
		goenv.goCmd(
			"list",
			"-export",
			"-f",
			"{{if .Export}}{{.ImportPath}}={{.Export}}{{end}}",
		),
		packages...,
	)

	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = gorootSrc
	cmd.Env = append([]string{}, os.Environ()...)
	cmd.Env = setEnv(cmd.Env, "GOROOT", goenv.goroot)
	cmd.Env = setEnv(cmd.Env, "GO111MODULE", "off")
	cmd.Env = setEnv(cmd.Env, "GOWORK", "off")
	cachePath := getEnv(cmd.Env, "GOCACHE")
	if cachePath == "" {
		cachePath = filepath.Join(goenv.goroot, ".gocache")
	}
	cachePath = abs(cachePath)
	if err := os.MkdirAll(cachePath, 0o755); err != nil {
		return nil, fmt.Errorf("prepare stdlib export cache: %w", err)
	}
	cmd.Env = setEnv(cmd.Env, "GOCACHE", cachePath)
	if getEnv(cmd.Env, "HOME") == "" {
		homePath := filepath.Join(goenv.goroot, ".home")
		if err := os.MkdirAll(homePath, 0o755); err != nil {
			return nil, fmt.Errorf("prepare stdlib export home: %w", err)
		}
		cmd.Env = setEnv(cmd.Env, "HOME", homePath)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("go list stdlib exports: %w\n%s", err, string(output))
	}

	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[1]) == "" {
			continue
		}
		exports[parts[0]] = parts[1]
	}
	if os.Getenv("ORCHESTRION_DEBUG_TRACE") != "" {
		fmt.Fprintf(os.Stderr, "orchestrion link debug: resolved stdlib exports %v\n", exports)
	}
	return exports, nil
}

func findWovenTestingArchive(goroot string) (string, error) {
	cacheRoot := filepath.Join(goroot, ".gocache")
	info, err := os.Stat(cacheRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	if !info.IsDir() {
		return "", nil
	}
	var match string
	err = filepath.Walk(cacheRoot, func(path string, info os.FileInfo, err error) error {
		if err != nil || info == nil || info.IsDir() {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil
		}
		if bytes.Contains(data, []byte("instrumentTestingM")) ||
			bytes.Contains(data, []byte("instrumentTestingTFunc")) ||
			bytes.Contains(data, []byte("github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations/gotesting")) {
			match = path
			return io.EOF
		}
		return nil
	})
	if err != nil && !errors.Is(err, io.EOF) {
		return "", err
	}
	return match, nil
}

type depsError struct {
	missing []missingDep
	known   []string
}

type missingDep struct {
	filename, imp string
}

var _ error = depsError{}

func (e depsError) Error() string {
	buf := bytes.NewBuffer(nil)
	fmt.Fprintf(buf, "missing strict dependencies:\n")
	for _, dep := range e.missing {
		fmt.Fprintf(buf, "\t%s: import of %q\n", dep.filename, dep.imp)
	}
	if len(e.known) == 0 {
		fmt.Fprintln(buf, "No dependencies were provided.")
	} else {
		fmt.Fprintln(buf, "Known dependencies are:")
		for _, imp := range e.known {
			fmt.Fprintf(buf, "\t%s\n", imp)
		}
	}
	fmt.Fprint(buf, "Check that imports in Go sources match importpath attributes in deps.")
	return buf.String()
}

func isRelative(path string) bool {
	return strings.HasPrefix(path, "./") || strings.HasPrefix(path, "../")
}

type archiveMultiFlag []archive

func (m *archiveMultiFlag) String() string {
	if m == nil || len(*m) == 0 {
		return ""
	}
	return fmt.Sprint(*m)
}

func (m *archiveMultiFlag) Set(v string) error {
	parts := strings.Split(v, "=")
	if len(parts) != 3 {
		return fmt.Errorf("badly formed -arc flag: %s", v)
	}
	importPaths := strings.Split(parts[0], ":")
	a := archive{
		importPath:        importPaths[0],
		importPathAliases: importPaths[1:],
		packagePath:       parts[1],
		file:              abs(parts[2]),
	}
	*m = append(*m, a)
	return nil
}
