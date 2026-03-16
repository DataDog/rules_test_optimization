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
	"crypto/sha256"
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
	"log",
	"log/slog",
	"net/http",
}

var orchestrionCacheStdlibPackages = []string{
	"flag",
	"fmt",
	"log",
	"log/slog",
	"net/http",
	"os",
	"os/exec",
	"runtime",
	"testing",
	"testing/internal/testdeps",
	"io/ioutil",
}

const orchestrionStdlibExportManifestName = "exports.txt"
const orchestrionStdlibExportDirName = "orchestrioncache"

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

func readImportcfgLines(importcfgPath string) ([]string, error) {
	data, err := os.ReadFile(importcfgPath)
	if err != nil {
		return nil, err
	}
	return strings.Split(string(data), "\n"), nil
}

func writeImportcfgLines(importcfgPath string, lines []string) error {
	return os.WriteFile(importcfgPath, []byte(strings.Join(lines, "\n")), 0o644)
}

func parsePackagefileDirective(line string) (pkg, archivePath string, ok bool) {
	if !strings.HasPrefix(line, "packagefile ") {
		return "", "", false
	}
	parts := strings.SplitN(strings.TrimPrefix(line, "packagefile "), "=", 2)
	if len(parts) != 2 {
		return "", "", false
	}
	return parts[0], parts[1], true
}

func parseImportmapDirective(line string) (pkg, mappedTo string, ok bool) {
	if !strings.HasPrefix(line, "importmap ") {
		return "", "", false
	}
	parts := strings.SplitN(strings.TrimPrefix(line, "importmap "), "=", 2)
	if len(parts) != 2 {
		return "", "", false
	}
	return parts[0], parts[1], true
}

func rewriteImportcfgPackagefiles(importcfgPath string, exports map[string]string, skip func(string) bool) error {
	if len(exports) == 0 {
		return nil
	}
	lines, err := readImportcfgLines(importcfgPath)
	if err != nil {
		return err
	}
	replaced := false
	for i, line := range lines {
		pkg, _, ok := parsePackagefileDirective(line)
		if !ok {
			continue
		}
		if skip != nil && skip(pkg) {
			continue
		}
		exportPath, ok := exports[pkg]
		if !ok || strings.TrimSpace(exportPath) == "" {
			continue
		}
		lines[i] = fmt.Sprintf("packagefile %s=%s", pkg, exportPath)
		replaced = true
	}
	if !replaced {
		return nil
	}
	return writeImportcfgLines(importcfgPath, lines)
}

func appendMissingImportcfgPackagefiles(importcfgPath string, exports map[string]string) error {
	if len(exports) == 0 {
		return nil
	}
	lines, err := readImportcfgLines(importcfgPath)
	if err != nil {
		return err
	}
	existing := make(map[string]bool, len(lines))
	for _, line := range lines {
		pkg, _, ok := parsePackagefileDirective(line)
		if ok {
			existing[pkg] = true
		}
	}
	missing := make([]string, 0, len(exports))
	for pkg, exportPath := range exports {
		if strings.TrimSpace(exportPath) == "" || existing[pkg] {
			continue
		}
		missing = append(missing, pkg)
	}
	if len(missing) == 0 {
		return nil
	}
	sort.Strings(missing)
	for _, pkg := range missing {
		lines = append(lines, fmt.Sprintf("packagefile %s=%s", pkg, exports[pkg]))
	}
	return writeImportcfgLines(importcfgPath, lines)
}

func rewriteImportcfgForOrchestrionStdlib(importcfgPath string, goenv *env) error {
	if goenv == nil || goenv.sdk == "" || goenv.goroot == "" {
		return nil
	}
	goenv.goroot = abs(goenv.goroot)
	goenv.sdk = abs(goenv.sdk)

	exports, err := resolveBazelStdlibPkgArchives(goenv, orchestrionInstrumentedStdlibPackages)
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		return nil
	}
	return rewriteImportcfgPackagefiles(importcfgPath, exports, func(pkg string) bool {
		return pkg == "runtime" || pkg == "testing"
	})
}

func rewriteImportcfgForPersistedStdlib(importcfgPath string, goenv *env) error {
	if goenv == nil || goenv.sdk == "" || goenv.goroot == "" {
		return nil
	}
	exports, err := readPersistedOrchestrionStdlibExports(goenv)
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		return nil
	}
	return rewriteImportcfgPackagefiles(importcfgPath, exports, nil)
}

func appendMissingPersistedStdlibPackagefiles(importcfgPath string, goenv *env) error {
	if goenv == nil || goenv.sdk == "" || goenv.goroot == "" {
		return nil
	}
	exports, err := readPersistedOrchestrionStdlibExports(goenv)
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		return nil
	}
	return appendMissingImportcfgPackagefiles(importcfgPath, exports)
}

func rewriteImportcfgForStdlibRoots(importcfgPath string, goenv *env, roots []string) error {
	if goenv == nil || goenv.sdk == "" || goenv.goroot == "" || len(roots) == 0 {
		return nil
	}
	exports, err := resolveInstrumentedStdlibExports(goenv, roots)
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		return nil
	}
	return rewriteImportcfgPackagefiles(importcfgPath, exports, nil)
}

func rewriteImportcfgForCacheStdlibPackages(importcfgPath string, goenv *env, packages []string) error {
	if goenv == nil || goenv.sdk == "" || goenv.goroot == "" || len(packages) == 0 {
		return nil
	}
	exports, err := resolveCacheStdlibExports(goenv, packages)
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		return nil
	}
	return rewriteImportcfgPackagefiles(importcfgPath, exports, nil)
}

func rewriteImportcfgForExactStdlibPackages(importcfgPath string, goenv *env, packages []string) error {
	if goenv == nil || goenv.goroot == "" || goenv.installSuffix == "" || len(packages) == 0 {
		return nil
	}
	exports, err := resolveBazelStdlibPkgArchives(goenv, packages)
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		return nil
	}
	return rewriteImportcfgPackagefiles(importcfgPath, exports, nil)
}

func appendMissingPackagefiles(importcfgPath string, exports map[string]string, _ string) error {
	return appendMissingImportcfgPackagefiles(importcfgPath, exports)
}

func appendOrReplaceImportcfgDirectives(importcfgPath string, directives []string, _ string) error {
	if len(directives) == 0 {
		return nil
	}
	lines, err := readImportcfgLines(importcfgPath)
	if err != nil {
		return err
	}
	indexes := make(map[string]int, len(lines))
	for i, line := range lines {
		if pkg, _, ok := parsePackagefileDirective(line); ok {
			indexes["packagefile "+pkg] = i
			continue
		}
		if pkg, _, ok := parseImportmapDirective(line); ok {
			indexes["importmap "+pkg] = i
		}
	}

	for _, line := range directives {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var key string
		switch {
		case strings.HasPrefix(line, "packagefile "):
			rest := strings.TrimPrefix(line, "packagefile ")
			parts := strings.SplitN(rest, "=", 2)
			if len(parts) != 2 {
				continue
			}
			key = "packagefile " + parts[0]
		case strings.HasPrefix(line, "importmap "):
			rest := strings.TrimPrefix(line, "importmap ")
			parts := strings.SplitN(rest, "=", 2)
			if len(parts) != 2 {
				continue
			}
			key = "importmap " + parts[0]
		default:
			continue
		}
		if i, ok := indexes[key]; ok {
			if lines[i] != line {
				lines[i] = line
			}
			continue
		}
		indexes[key] = len(lines)
		lines = append(lines, line)
	}

	return writeImportcfgLines(importcfgPath, lines)
}

func appendMissingModulePackagefiles(importcfgPath string, goenv *env, packages []string, orchestrionPath, moduleDir string) error {
	if len(packages) == 0 || goenv == nil || goenv.sdk == "" {
		return nil
	}
	forcedExportRoot := detectExistingModuleExportRoot(importcfgPath)
	exports, err := resolveModuleExportsForPackagesWithRoot(goenv, packages, orchestrionPath, moduleDir, forcedExportRoot)
	if err != nil {
		return err
	}
	directives := make([]string, 0, len(exports))
	for pkg, exportPath := range exports {
		if strings.TrimSpace(exportPath) == "" {
			continue
		}
		directives = append(directives, fmt.Sprintf("packagefile %s=%s", pkg, exportPath))
	}
	sort.Strings(directives)
	if forcedExportRoot != "" {
		return appendMissingPackagefiles(importcfgPath, exports, "module-forced-root")
	}
	return appendOrReplaceImportcfgDirectives(importcfgPath, directives, "module")
}

func detectExistingModuleExportRoot(importcfgPath string) string {
	data, err := os.ReadFile(importcfgPath)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "packagefile github.com/DataDog/dd-trace-go/") {
			continue
		}
		parts := strings.SplitN(strings.TrimPrefix(line, "packagefile "), "=", 2)
		if len(parts) != 2 {
			continue
		}
		if root := moduleExportRootFromPath(strings.TrimSpace(parts[1])); root != "" {
			return root
		}
	}
	return ""
}

func moduleExportRootFromPath(path string) string {
	path = abs(path)
	marker := string(filepath.Separator) + "module-exports" + string(filepath.Separator)
	idx := strings.Index(path, marker)
	if idx < 0 {
		return ""
	}
	base := path[idx+len(marker):]
	parts := strings.Split(base, string(filepath.Separator))
	if len(parts) < 1 || strings.TrimSpace(parts[0]) == "" {
		return ""
	}
	root := filepath.Join(path[:idx+len(marker)], parts[0])
	// Older experiments used an additional family segment under the request key.
	// If the second component does not look like a go cache prefix dir, keep it as
	// part of the root so those paths still coalesce correctly.
	if len(parts) >= 2 {
		second := strings.TrimSpace(parts[1])
		if second != "" && len(second) > 2 {
			root = filepath.Join(root, second)
		}
	}
	return root
}

func resolveBazelStdlibPkgArchives(goenv *env, packages []string) (map[string]string, error) {
	if goenv == nil || goenv.goroot == "" || goenv.installSuffix == "" || len(packages) == 0 {
		return nil, nil
	}
	pkgRoot := filepath.Join(abs(goenv.goroot), "pkg", goenv.installSuffix)
	exports := make(map[string]string, len(packages))
	for _, pkg := range packages {
		archive := filepath.Join(pkgRoot, filepath.FromSlash(pkg)+".a")
		info, err := os.Stat(archive)
		if err != nil || info.IsDir() {
			continue
		}
		exports[pkg] = archive
	}
	return exports, nil
}

func resolveModuleExportsForPackages(goenv *env, packages []string, orchestrionPath, moduleDir string) (map[string]string, error) {
	return resolveModuleExportsForPackagesWithRoot(goenv, packages, orchestrionPath, moduleDir, "")
}

func resolveModuleExportsForPackagesWithRoot(goenv *env, packages []string, orchestrionPath, moduleDir, forcedExportRoot string) (map[string]string, error) {
	if len(packages) == 0 || goenv == nil || goenv.sdk == "" {
		return nil, nil
	}
	if goenv.goroot != "" {
		goenv.goroot = abs(goenv.goroot)
		goenv.sdk = abs(goenv.sdk)
		if err := ensureGoRootCompatibility(goenv.goroot, goenv.sdk, false); err != nil {
			return nil, err
		}
	}
	args := goenv.goCmd("list")
	if orchestrionPath != "" {
		args = append(args, "-toolexec", abs(orchestrionPath)+" toolexec")
	}
	args = append(args,
		"-export",
		"-deps",
		"-f",
		"{{if .Export}}{{.ImportPath}}={{.Export}}{{end}}",
	)
	args = append(args, packages...)

	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = "."
	if moduleDir != "" {
		cmd.Dir = abs(moduleDir)
	}
	cmd.Env = append([]string{}, os.Environ()...)
	cmd.Env = setEnv(cmd.Env, "GO111MODULE", "on")
	cmd.Env = setEnv(cmd.Env, "GOWORK", "off")
	cmd.Env = setEnv(cmd.Env, orchestrionJobserverURLEnvVar, "")
	cmd.Env = setEnv(cmd.Env, "DD_ORCHESTRION_IS_GOMOD_VERSION", "")
	if goenv.goroot != "" {
		cmd.Env = setEnv(cmd.Env, "GOROOT", abs(goenv.goroot))
	}
	goBin := filepath.Join(abs(goenv.sdk), "bin")
	cmd.Env = setEnv(cmd.Env, "PATH", goBin+string(os.PathListSeparator)+getEnv(cmd.Env, "PATH"))
	gopath := getEnv(cmd.Env, "GOPATH")
	if gopath == "" {
		gopath = filepath.Join(os.TempDir(), "datadog-orchestrion-go-cache")
	}
	gopath = abs(gopath)
	if err := os.MkdirAll(gopath, 0o755); err != nil {
		return nil, fmt.Errorf("prepare module gopath: %w", err)
	}
	cmd.Env = setEnv(cmd.Env, "GOPATH", gopath)
	gomodcache := getEnv(cmd.Env, "GOMODCACHE")
	if gomodcache == "" {
		gomodcache = filepath.Join(gopath, "pkg", "mod")
	}
	gomodcache = abs(gomodcache)
	if err := os.MkdirAll(gomodcache, 0o755); err != nil {
		return nil, fmt.Errorf("prepare module gomodcache: %w", err)
	}
	cmd.Env = setEnv(cmd.Env, "GOMODCACHE", gomodcache)
	var gocache string
	if forcedExportRoot != "" {
		gocache = abs(forcedExportRoot)
	} else {
		requestKey, err := moduleExportRequestKey(cmd.Dir)
		if err != nil {
			return nil, fmt.Errorf("derive module export request key: %w", err)
		}
		gocache = filepath.Join(gopath, "cache", "module-exports", requestKey)
	}
	gocache = abs(gocache)
	if err := os.MkdirAll(gocache, 0o755); err != nil {
		return nil, fmt.Errorf("prepare module gocache: %w", err)
	}
	if goenv.stdlibCache != "" {
		// The Bazel stdlib cache is the right archive family, but it lives under
		// a read-only output tree. Clone it into a writable helper cache so
		// go list -export can build Datadog helper packages against the same woven
		// stdlib artifacts without mutating Bazel outputs.
		if err := syncDirectoryTree(goenv.stdlibCache, gocache); err != nil {
			return nil, fmt.Errorf("clone woven stdlib cache into helper gocache: %w", err)
		}
	} else {
		if err := seedWovenStdlibCache(goenv, gocache); err != nil {
			return nil, fmt.Errorf("seed module gocache from woven stdlib cache: %w", err)
		}
	}
	cmd.Env = setEnv(cmd.Env, "GOCACHE", gocache)
	cmd.Env = setEnv(cmd.Env, orchestrionStdlibCacheEnvVar, goenv.stdlibCache)
	if getEnv(cmd.Env, "GOPROXY") == "" {
		cmd.Env = setEnv(cmd.Env, "GOPROXY", "https://proxy.golang.org,direct")
	}
	if getEnv(cmd.Env, "GOSUMDB") == "" {
		cmd.Env = setEnv(cmd.Env, "GOSUMDB", "sum.golang.org")
	}
	if getEnv(cmd.Env, "GOFLAGS") == "" {
		cmd.Env = setEnv(cmd.Env, "GOFLAGS", "-mod=mod")
	}
	if getEnv(cmd.Env, "HOME") == "" {
		homePath := filepath.Join(os.TempDir(), "datadog-orchestrion-home")
		if err := os.MkdirAll(homePath, 0o755); err != nil {
			return nil, fmt.Errorf("prepare module home: %w", err)
		}
		cmd.Env = setEnv(cmd.Env, "HOME", homePath)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("go list module exports for %v: %w\n%s", packages, err, string(output))
	}
	exports := make(map[string]string)
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
	if err := sanitizeModuleExportArchives(exports); err != nil {
		return nil, err
	}
	return exports, nil
}

func sanitizeModuleExportArchives(exports map[string]string) error {
	for pkg, archivePath := range exports {
		archivePath = strings.TrimSpace(archivePath)
		if archivePath == "" {
			continue
		}
		if _, err := readArchiveEntry(archivePath, "link.deps"); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return fmt.Errorf("inspect module export archive for %s: %w", pkg, err)
		}
		sanitizedPath := archivePath + ".nolinkdeps"
		if _, err := os.Stat(sanitizedPath); err != nil {
			if !os.IsNotExist(err) {
				return fmt.Errorf("stat sanitized module export archive for %s: %w", pkg, err)
			}
			if err := copyArchiveWithoutEntries(archivePath, sanitizedPath, map[string]bool{"link.deps": true}); err != nil {
				return fmt.Errorf("sanitize module export archive for %s: %w", pkg, err)
			}
		}
		exports[pkg] = sanitizedPath
	}
	return nil
}

func moduleExportRequestKey(moduleDir string) (string, error) {
	moduleDir = abs(moduleDir)
	var b strings.Builder
	b.WriteString(moduleDir)
	b.WriteString("\n")
	for _, name := range []string{"go.mod", "orchestrion.tool.go", "orchestrion.yml"} {
		path := filepath.Join(moduleDir, name)
		data, err := os.ReadFile(path)
		if err != nil {
			if os.IsNotExist(err) {
				b.WriteString(name)
				b.WriteString("=missing\n")
				continue
			}
			return "", err
		}
		sum := sha256.Sum256(data)
		b.WriteString(name)
		b.WriteString("=")
		b.WriteString(fmt.Sprintf("%x", sum[:8]))
		b.WriteString("\n")
	}
	key := sha256.Sum256([]byte(b.String()))
	return fmt.Sprintf("%x", key[:8]), nil
}

func currentWovenStdlibCacheKey(goenv *env) (string, error) {
	if goenv == nil || goenv.stdlibCache == "" {
		return "default", nil
	}
	exports, err := readStdlibCacheManifest(goenv.stdlibCache, []string{"testing", "runtime", "fmt", "flag", "log"})
	if err != nil {
		return "", err
	}
	if len(exports) == 0 {
		return "default", nil
	}
	var b strings.Builder
	keys := make([]string, 0, len(exports))
	for pkg := range exports {
		keys = append(keys, pkg)
	}
	sort.Strings(keys)
	for _, pkg := range keys {
		b.WriteString(pkg)
		b.WriteString("=")
		b.WriteString(filepath.Base(exports[pkg]))
		b.WriteString("\n")
	}
	sum := sha256.Sum256([]byte(b.String()))
	return fmt.Sprintf("%x", sum[:8]), nil
}

func readAllStdlibCacheManifest(cacheRoot string) (map[string]string, error) {
	if cacheRoot == "" {
		return nil, nil
	}
	manifestPath := filepath.Join(abs(cacheRoot), orchestrionStdlibCacheManifestName)
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	exports := make(map[string]string)
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[1]) == "" {
			continue
		}
		exportPath := parts[1]
		if !filepath.IsAbs(exportPath) {
			exportPath = filepath.Join(abs(cacheRoot), exportPath)
		}
		if _, err := os.Stat(exportPath); err == nil {
			exports[parts[0]] = exportPath
		}
	}
	return exports, nil
}

func seedWovenStdlibCache(goenv *env, cacheRoot string) error {
	if goenv == nil || goenv.stdlibCache == "" || cacheRoot == "" {
		return nil
	}
	sourceExports, err := readAllStdlibCacheManifest(goenv.stdlibCache)
	if err != nil {
		return err
	}
	if len(sourceExports) == 0 {
		return nil
	}
	needed := make(map[string]bool, len(orchestrionCacheStdlibPackages))
	for _, pkg := range orchestrionCacheStdlibPackages {
		needed[pkg] = true
	}
	packages := make([]string, 0, len(needed))
	for pkg := range needed {
		if _, ok := sourceExports[pkg]; ok {
			packages = append(packages, pkg)
		}
	}
	sort.Strings(packages)
	if len(packages) == 0 {
		return nil
	}
	destExports, err := resolveCacheStdlibExportsAt(goenv, packages, cacheRoot)
	if err != nil {
		return err
	}
	if len(destExports) == 0 {
		return nil
	}
	var manifest strings.Builder
	for _, pkg := range packages {
		src := sourceExports[pkg]
		dst := destExports[pkg]
		if src == "" || dst == "" {
			continue
		}
		if err := syncGoCachePrefixDir(src, dst); err != nil {
			return fmt.Errorf("sync seeded stdlib cache prefix for %s: %w", pkg, err)
		}
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		if err := copyArchiveFile(src, dst); err != nil {
			return fmt.Errorf("copy seeded stdlib archive %s -> %s: %w", src, dst, err)
		}
		relDst := dst
		if rel, err := filepath.Rel(cacheRoot, dst); err == nil {
			relDst = rel
		}
		manifest.WriteString(pkg)
		manifest.WriteString("=")
		manifest.WriteString(relDst)
		manifest.WriteString("\n")
	}
	if manifest.Len() == 0 {
		return nil
	}
	manifestPath := filepath.Join(abs(cacheRoot), orchestrionStdlibCacheManifestName)
	if err := os.WriteFile(manifestPath, []byte(manifest.String()), 0o644); err != nil {
		return fmt.Errorf("write seeded stdlib cache manifest at %s: %w", manifestPath, err)
	}
	return nil
}

func syncDirectoryTree(srcRoot, dstRoot string) error {
	srcRoot = abs(srcRoot)
	dstRoot = abs(dstRoot)
	return filepath.Walk(srcRoot, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(srcRoot, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		dstPath := filepath.Join(dstRoot, rel)
		if info.IsDir() {
			return os.MkdirAll(dstPath, info.Mode().Perm())
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		if err := os.MkdirAll(filepath.Dir(dstPath), 0o755); err != nil {
			return err
		}
		return copyArchiveFile(path, dstPath)
	})
}

func syncGoCachePrefixDir(srcExport, dstExport string) error {
	srcDir := filepath.Dir(srcExport)
	dstDir := filepath.Dir(dstExport)
	if srcDir == "" || dstDir == "" || srcDir == dstDir {
		return nil
	}
	entries, err := os.ReadDir(srcDir)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dstDir, 0o755); err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		srcPath := filepath.Join(srcDir, entry.Name())
		dstPath := filepath.Join(dstDir, entry.Name())
		if err := copyArchiveFile(srcPath, dstPath); err != nil {
			return err
		}
	}
	return nil
}

func rewriteImportcfgForStdlibClosure(importcfgPath string, goenv *env, pkg string, exclude map[string]bool) error {
	if goenv == nil || goenv.sdk == "" || goenv.goroot == "" || pkg == "" {
		return nil
	}
	exports, err := resolveStdlibExportsForPackage(goenv, pkg)
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		return nil
	}
	return rewriteImportcfgPackagefiles(importcfgPath, exports, func(pkg string) bool {
		return exclude[pkg]
	})
}

func resolveInstrumentedStdlibExports(goenv *env, packages []string) (map[string]string, error) {
	if len(packages) == 0 {
		return nil, nil
	}
	if goenv != nil {
		goenv.goroot = abs(goenv.goroot)
		goenv.sdk = abs(goenv.sdk)
	}
	if persisted, err := readPersistedOrchestrionStdlibExports(goenv); err != nil {
		return nil, err
	} else if len(persisted) > 0 {
		return persisted, nil
	}
	exports := make(map[string]string, len(packages))
	if info, err := os.Stat(goenv.goroot); err != nil || !info.IsDir() {
		return nil, nil
	}
	if err := ensureGoRootCompatibility(goenv.goroot, goenv.sdk, false); err != nil {
		return nil, err
	}
	gorootSrc := filepath.Join(goenv.goroot, "src")
	if info, err := os.Stat(gorootSrc); err != nil || !info.IsDir() {
		return nil, nil
	}

	baseEnv := append([]string{}, os.Environ()...)
	baseEnv = setEnv(baseEnv, "GOROOT", goenv.goroot)
	baseEnv = setEnv(baseEnv, "GO111MODULE", "off")
	baseEnv = setEnv(baseEnv, "GOWORK", "off")
	orchestrionCachePath := goenv.stdlibCache
	if orchestrionCachePath == "" {
		orchestrionCachePath = filepath.Join(goenv.goroot, ".gocache")
	}
	cachePath := ""
	if info, err := os.Stat(orchestrionCachePath); err == nil && info.IsDir() {
		cachePath = orchestrionCachePath
	}
	if cachePath == "" {
		cachePath = getEnv(baseEnv, "GOCACHE")
	}
	if cachePath == "" {
		if goenv.stdlibCache != "" {
			cachePath = goenv.stdlibCache
		} else {
			cachePath = filepath.Join(goenv.goroot, ".gocache")
		}
	}
	cachePath = abs(cachePath)
	if err := os.MkdirAll(cachePath, 0o755); err != nil {
		return nil, fmt.Errorf("prepare stdlib export cache: %w", err)
	}
	baseEnv = setEnv(baseEnv, "GOCACHE", cachePath)
	if getEnv(baseEnv, "HOME") == "" {
		homePath := filepath.Join(goenv.goroot, ".home")
		if err := os.MkdirAll(homePath, 0o755); err != nil {
			return nil, fmt.Errorf("prepare stdlib export home: %w", err)
		}
		baseEnv = setEnv(baseEnv, "HOME", homePath)
	}
	args := append(
		goenv.goCmd(
			"list",
			"-export",
			"-deps",
			"-f",
			"{{if and .Standard .Export}}{{.ImportPath}}={{.Export}}{{end}}",
		),
		packages...,
	)
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = gorootSrc
	cmd.Env = append([]string{}, baseEnv...)
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
	return exports, nil
}

func resolveCacheStdlibExports(goenv *env, packages []string) (map[string]string, error) {
	cacheRoot := ""
	if goenv != nil {
		cacheRoot = goenv.stdlibCache
	}
	return resolveCacheStdlibExportsAt(goenv, packages, cacheRoot)
}

func resolveCacheStdlibExportsAt(goenv *env, packages []string, cacheRoot string) (map[string]string, error) {
	if len(packages) == 0 || goenv == nil || goenv.goroot == "" || goenv.sdk == "" {
		return nil, nil
	}
	cacheRoot = strings.TrimSpace(cacheRoot)
	if cacheRoot != "" {
		if manifestExports, err := readStdlibCacheManifest(cacheRoot, packages); err == nil && len(manifestExports) > 0 {
			return manifestExports, nil
		}
	}
	goenv.goroot = abs(goenv.goroot)
	goenv.sdk = abs(goenv.sdk)
	if info, err := os.Stat(goenv.goroot); err != nil || !info.IsDir() {
		return nil, nil
	}
	if err := ensureGoRootCompatibility(goenv.goroot, goenv.sdk, false); err != nil {
		return nil, err
	}
	gorootSrc := filepath.Join(goenv.goroot, "src")
	if info, err := os.Stat(gorootSrc); err != nil || !info.IsDir() {
		return nil, nil
	}

	baseEnv := append([]string{}, os.Environ()...)
	baseEnv = setEnv(baseEnv, "GOROOT", goenv.goroot)
	baseEnv = setEnv(baseEnv, "GO111MODULE", "off")
	baseEnv = setEnv(baseEnv, "GOWORK", "off")
	cachePath := cacheRoot
	if cachePath == "" {
		cachePath = getEnv(baseEnv, "GOCACHE")
	}
	if cachePath == "" {
		cachePath = filepath.Join(goenv.goroot, ".gocache")
	}
	cachePath = abs(cachePath)
	if err := os.MkdirAll(cachePath, 0o755); err != nil {
		return nil, fmt.Errorf("prepare stdlib cache exports: %w", err)
	}
	baseEnv = setEnv(baseEnv, "GOCACHE", cachePath)
	if getEnv(baseEnv, "HOME") == "" {
		homePath := filepath.Join(goenv.goroot, ".home")
		if err := os.MkdirAll(homePath, 0o755); err != nil {
			return nil, fmt.Errorf("prepare stdlib cache exports home: %w", err)
		}
		baseEnv = setEnv(baseEnv, "HOME", homePath)
	}
	args := append(
		goenv.goCmd(
			"list",
			"-export",
			"-deps",
			"-f",
			"{{if and .Standard .Export}}{{.ImportPath}}={{.Export}}{{end}}",
		),
		packages...,
	)
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = gorootSrc
	cmd.Env = append([]string{}, baseEnv...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("go list cache stdlib exports: %w\n%s", err, string(output))
	}
	exports := make(map[string]string, len(packages))
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
	return exports, nil
}

func readStdlibCacheManifest(cacheRoot string, packages []string) (map[string]string, error) {
	if cacheRoot == "" {
		return nil, nil
	}
	manifestPath := filepath.Join(abs(cacheRoot), orchestrionStdlibCacheManifestName)
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	needed := make(map[string]bool, len(packages))
	for _, pkg := range packages {
		needed[pkg] = true
	}
	exports := make(map[string]string, len(packages))
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 || !needed[parts[0]] {
			continue
		}
		exportPath := parts[1]
		if !filepath.IsAbs(exportPath) {
			exportPath = filepath.Join(abs(cacheRoot), exportPath)
		}
		if _, err := os.Stat(exportPath); err == nil {
			exports[parts[0]] = exportPath
		}
	}
	return exports, nil
}

func orchestrionStdlibExportRoot(goenv *env) string {
	if goenv == nil || goenv.goroot == "" || goenv.installSuffix == "" {
		return ""
	}
	return filepath.Join(abs(goenv.goroot), "pkg", orchestrionStdlibExportDirName, goenv.installSuffix)
}

func orchestrionStdlibExportManifestPath(goenv *env) string {
	root := orchestrionStdlibExportRoot(goenv)
	if root == "" {
		return ""
	}
	return filepath.Join(root, orchestrionStdlibExportManifestName)
}

func readPersistedOrchestrionStdlibExports(goenv *env) (map[string]string, error) {
	manifestPath := orchestrionStdlibExportManifestPath(goenv)
	root := orchestrionStdlibExportRoot(goenv)
	if manifestPath == "" {
		return nil, nil
	}
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	exports := make(map[string]string)
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		exportPath := parts[1]
		if !filepath.IsAbs(exportPath) && root != "" {
			exportPath = filepath.Join(root, filepath.FromSlash(exportPath))
		}
		if _, err := os.Stat(exportPath); err == nil {
			exports[parts[0]] = exportPath
		}
	}
	return exports, nil
}

func rewriteImportcfgForAllStdlibExports(importcfgPath string, goenv *env) error {
	if goenv == nil || goenv.sdk == "" || goenv.goroot == "" {
		return nil
	}
	stdlibPkgRoot := filepath.Join(abs(goenv.goroot), "pkg")
	data, err := os.ReadFile(importcfgPath)
	if err != nil {
		return err
	}
	var stdPkgs []string
	seen := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "packagefile ") {
			continue
		}
		rest := strings.TrimPrefix(line, "packagefile ")
		parts := strings.SplitN(rest, "=", 2)
		if len(parts) != 2 {
			continue
		}
		importPath := parts[0]
		archivePath := parts[1]
		if strings.Contains(importPath, ".") || seen[importPath] {
			continue
		}
		if !filepath.IsAbs(archivePath) {
			archivePath = abs(archivePath)
		}
		if !strings.HasPrefix(archivePath, stdlibPkgRoot+string(filepath.Separator)) {
			continue
		}
		seen[importPath] = true
		stdPkgs = append(stdPkgs, importPath)
	}
	if len(stdPkgs) == 0 {
		return nil
	}
	exports, err := resolveInstrumentedStdlibExports(goenv, stdPkgs)
	if err != nil {
		return err
	}
	return rewriteImportcfgPackagefiles(importcfgPath, exports, nil)
}

func rewriteImportcfgForDefaultCacheStdlibExports(importcfgPath string, goenv *env) error {
	if goenv == nil || goenv.sdk == "" || goenv.goroot == "" {
		return nil
	}
	exports, err := resolveCacheStdlibExports(goenv, orchestrionCacheStdlibPackages)
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		return nil
	}
	return rewriteImportcfgPackagefiles(importcfgPath, exports, nil)
}

func rewriteImportcfgForCacheStdlibClosures(importcfgPath string, goenv *env, packages []string) error {
	if goenv == nil || goenv.sdk == "" || goenv.goroot == "" || len(packages) == 0 {
		return nil
	}
	exports := make(map[string]string)
	for _, pkg := range packages {
		if pkg == "" {
			continue
		}
		var (
			pkgExports map[string]string
			err        error
		)
		if strings.Contains(pkg, ".") {
			pkgExports, err = resolveStdlibExportsForPackage(goenv, pkg)
		} else {
			pkgExports, err = resolveCacheStdlibExports(goenv, []string{pkg})
		}
		if err != nil {
			return err
		}
		for importPath, exportPath := range pkgExports {
			if exportPath != "" {
				exports[importPath] = exportPath
			}
		}
	}
	if len(exports) == 0 {
		return nil
	}
	return rewriteImportcfgPackagefiles(importcfgPath, exports, nil)
}

func rewriteImportcfgFromCurrentStdlibEntries(importcfgPath string, goenv *env) error {
	if goenv == nil {
		return nil
	}
	lines, err := readImportcfgLines(importcfgPath)
	if err != nil {
		return err
	}
	packages := make([]string, 0)
	seen := make(map[string]struct{})
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "packagefile ") {
			continue
		}
		rest := strings.TrimSpace(strings.TrimPrefix(line, "packagefile "))
		parts := strings.SplitN(rest, "=", 2)
		if len(parts) != 2 {
			continue
		}
		pkg := strings.TrimSpace(parts[0])
		if pkg == "" || strings.Contains(pkg, ".") {
			continue
		}
		if _, ok := seen[pkg]; ok {
			continue
		}
		seen[pkg] = struct{}{}
		packages = append(packages, pkg)
	}
	if len(packages) == 0 {
		return nil
	}
	var exports map[string]string
	if goenv.stdlibCache != "" {
		exports, err = readStdlibCacheManifest(goenv.stdlibCache, packages)
		if err != nil {
			return err
		}
	}
	if len(exports) == 0 {
		exports, err = resolveStdlibExportsForPackageSet(goenv, packages)
	}
	if err != nil {
		return err
	}
	if len(exports) == 0 {
		return nil
	}
	return rewriteImportcfgPackagefiles(importcfgPath, exports, nil)
}

func resolveStdlibExportsForPackageSet(goenv *env, packages []string) (map[string]string, error) {
	all := make(map[string]string)
	for _, pkg := range packages {
		exports, err := resolveStdlibExportsForPackage(goenv, pkg)
		if err != nil {
			return nil, err
		}
		for importPath, exportPath := range exports {
			if strings.TrimSpace(exportPath) == "" {
				continue
			}
			all[importPath] = exportPath
		}
	}
	return all, nil
}

func resolveStdlibExportsForPackage(goenv *env, pkg string) (map[string]string, error) {
	if pkg == "" {
		return nil, nil
	}
	if goenv != nil {
		goenv.goroot = abs(goenv.goroot)
		goenv.sdk = abs(goenv.sdk)
	}
	if info, err := os.Stat(goenv.goroot); err != nil || !info.IsDir() {
		return nil, nil
	}
	if err := ensureGoRootCompatibility(goenv.goroot, goenv.sdk, false); err != nil {
		return nil, err
	}
	gorootSrc := filepath.Join(goenv.goroot, "src")
	if info, err := os.Stat(gorootSrc); err != nil || !info.IsDir() {
		return nil, nil
	}

	args := goenv.goCmd(
		"list",
		"-export",
		"-deps",
		"-f",
		"{{if and .Standard .Export}}{{.ImportPath}}={{.Export}}{{end}}",
		pkg,
	)

	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = "."
	cmd.Env = append([]string{}, os.Environ()...)
	cmd.Env = setEnv(cmd.Env, "GOROOT", goenv.goroot)
	cmd.Env = setEnv(cmd.Env, "GO111MODULE", "on")
	cmd.Env = setEnv(cmd.Env, "GOWORK", "off")
	cachePath := goenv.stdlibCache
	if cachePath == "" {
		cachePath = getEnv(cmd.Env, "GOCACHE")
	}
	if cachePath == "" {
		cachePath = filepath.Join(goenv.goroot, ".gocache")
	}
	cachePath = abs(cachePath)
	if err := os.MkdirAll(cachePath, 0o755); err != nil {
		return nil, fmt.Errorf("prepare stdlib closure cache: %w", err)
	}
	cmd.Env = setEnv(cmd.Env, "GOCACHE", cachePath)
	goPath := getEnv(cmd.Env, "GOPATH")
	if goPath == "" {
		goPath = filepath.Join(os.TempDir(), "datadog-orchestrion-go-cache")
	}
	goPath = abs(goPath)
	if err := os.MkdirAll(goPath, 0o755); err != nil {
		return nil, fmt.Errorf("prepare stdlib closure gopath: %w", err)
	}
	cmd.Env = setEnv(cmd.Env, "GOPATH", goPath)
	modCache := getEnv(cmd.Env, "GOMODCACHE")
	if modCache == "" {
		modCache = filepath.Join(goPath, "pkg", "mod")
	}
	modCache = abs(modCache)
	if err := os.MkdirAll(modCache, 0o755); err != nil {
		return nil, fmt.Errorf("prepare stdlib closure gomodcache: %w", err)
	}
	cmd.Env = setEnv(cmd.Env, "GOMODCACHE", modCache)
	if getEnv(cmd.Env, "GOPROXY") == "" {
		cmd.Env = setEnv(cmd.Env, "GOPROXY", "https://proxy.golang.org,direct")
	}
	if getEnv(cmd.Env, "GOSUMDB") == "" {
		cmd.Env = setEnv(cmd.Env, "GOSUMDB", "sum.golang.org")
	}
	if getEnv(cmd.Env, "HOME") == "" {
		homePath := filepath.Join(goenv.goroot, ".home")
		if err := os.MkdirAll(homePath, 0o755); err != nil {
			return nil, fmt.Errorf("prepare stdlib closure home: %w", err)
		}
		cmd.Env = setEnv(cmd.Env, "HOME", homePath)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("go list stdlib closure exports for %s: %w\n%s", pkg, err, string(output))
	}
	exports := make(map[string]string)
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
