package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestShouldSkipOrchestrionForImportPathSkipsRuntimePackages(t *testing.T) {
	tests := []struct {
		name       string
		importPath string
		want       bool
	}{
		{
			name:       "rules_go helper",
			importPath: "github.com/bazelbuild/rules_go/go/tools/bzltestutil",
			want:       true,
		},
		{
			name:       "dd trace v2 runtime",
			importPath: "github.com/DataDog/dd-trace-go/v2/ddtrace/tracer",
			want:       true,
		},
		{
			name:       "dd trace contrib runtime",
			importPath: "github.com/DataDog/dd-trace-go/contrib/net/http/v2",
			want:       true,
		},
		{
			name:       "dd trace v1 runtime",
			importPath: "gopkg.in/DataDog/dd-trace-go.v1/ddtrace/tracer",
			want:       true,
		},
		{
			name:       "consumer package",
			importPath: "example.com/monorepo/service/worker/notifications",
			want:       false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shouldSkipOrchestrionForImportPath(tt.importPath); got != tt.want {
				t.Fatalf("shouldSkipOrchestrionForImportPath(%q) = %t, want %t", tt.importPath, got, tt.want)
			}
		})
	}
}

func TestExistingArchivesByPackagePathKeepsFirstArchive(t *testing.T) {
	archives := existingArchivesByPackagePath([]archive{
		{
			importPath:  "first",
			packagePath: "github.com/DataDog/dd-trace-go/v2/ddtrace/tracer",
			file:        "tracer.x",
		},
		{
			importPath:  "second",
			packagePath: "github.com/DataDog/dd-trace-go/v2/ddtrace/tracer",
			file:        "other.x",
		},
		{
			importPath:  "empty",
			packagePath: "",
			file:        "missing.x",
		},
	})

	got := archives["github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"]
	if got.importPath != "first" || got.file != "tracer.x" {
		t.Fatalf("existing archive = %#v, want first tracer archive", got)
	}
	if _, ok := archives[""]; ok {
		t.Fatal("existingArchivesByPackagePath kept an empty package path")
	}
}

func TestSyntheticHelperOverridesUseExistingArchives(t *testing.T) {
	tracerPkg := "github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"
	integrationsPkg := "github.com/DataDog/dd-trace-go/v2/internal/civisibility/integrations"
	transitivePkg := "github.com/tinylib/msgp/msgp"
	derivedPkg := "github.com/DataDog/dd-trace-go/v2/internal/civisibility/utils/impactedtests"
	existingArchives := map[string]archive{
		tracerPkg: {
			packagePath: tracerPkg,
			file:        "bazel-out/pkg/tracer.x",
		},
		transitivePkg: {
			packagePath: transitivePkg,
			file:        "bazel-out/pkg/msgp.x",
		},
	}

	rootSet := syntheticSourceCompiledSet([]string{integrationsPkg, tracerPkg}, existingArchives)
	if rootSet[tracerPkg] {
		t.Fatal("syntheticSourceCompiledSet kept tracer on the source-compiled path")
	}
	if !rootSet[integrationsPkg] {
		t.Fatal("syntheticSourceCompiledSet dropped the integration helper root")
	}

	state := syntheticTestmainHelperDecisionState{
		metaCache: map[string]*modulePackageMetadata{
			integrationsPkg: {
				ImportPath: integrationsPkg,
				Imports:    []string{derivedPkg, tracerPkg, transitivePkg},
			},
			tracerPkg: {
				ImportPath: tracerPkg,
				Imports:    []string{"log/slog"},
			},
			derivedPkg: {
				ImportPath: derivedPkg,
				Imports:    []string{tracerPkg},
			},
			transitivePkg: {
				ImportPath: transitivePkg,
				Imports:    []string{"bytes"},
			},
		},
		sourceDecisions: map[string]bool{
			integrationsPkg: true,
			derivedPkg:      false,
			tracerPkg:       true,
			transitivePkg:   true,
		},
	}
	adjusted := state.withExistingArchiveOverrides(rootSet, existingArchives)
	if adjusted.sourceDecisions[tracerPkg] {
		t.Fatal("existing tracer archive stayed in the source-compiled decision set")
	}
	if adjusted.sourceDecisions[transitivePkg] {
		t.Fatal("existing transitive archive stayed in the source-compiled decision set")
	}
	if !adjusted.sourceDecisions[derivedPkg] {
		t.Fatal("package importing an existing archive stayed on the module-export path")
	}
	if got, want := strings.Join(adjusted.externalPackages, ","), tracerPkg+","+transitivePkg; got != want {
		t.Fatalf("externalPackages = %v, want %s", adjusted.externalPackages, want)
	}

	relevant := syntheticRelevantExistingArchives([]string{integrationsPkg, tracerPkg}, adjusted, existingArchives)
	if len(relevant) != 2 {
		t.Fatalf("relevant existing archives = %v, want tracer and transitive package", relevant)
	}
	if _, ok := relevant[tracerPkg]; !ok {
		t.Fatal("relevant existing archives dropped the tracer package")
	}
	if _, ok := relevant[transitivePkg]; !ok {
		t.Fatal("relevant existing archives dropped the transitive package")
	}

	exports := map[string]string{
		tracerPkg:     "module-cache/tracer.a",
		transitivePkg: "module-cache/msgp.a",
	}
	preferExistingArchiveExports(exports, existingArchives)
	if got, want := exports[tracerPkg], "bazel-out/pkg/tracer.x"; got != want {
		t.Fatalf("preferExistingArchiveExports tracer = %q, want %q", got, want)
	}
	if got, want := exports[transitivePkg], "bazel-out/pkg/msgp.x"; got != want {
		t.Fatalf("preferExistingArchiveExports transitive = %q, want %q", got, want)
	}
}

func TestLinkArchiveForExistingDependencyUsesExecrootRelativeFullArchive(t *testing.T) {
	oldwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	execroot := t.TempDir()
	if err := os.Chdir(execroot); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(oldwd); err != nil {
			t.Fatal(err)
		}
	})

	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	exportArchive := filepath.Join(cwd, "bazel-out", "pkg", "tracer.x")
	want := filepath.Join("bazel-out", "pkg", "tracer.a")
	if got := linkArchiveForExistingDependency(exportArchive); got != want {
		t.Fatalf("linkArchiveForExistingDependency() = %q, want %q", got, want)
	}
}

func TestLinkArchiveForExistingDependencyKeepsExternalAbsolutePath(t *testing.T) {
	oldwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	execroot := t.TempDir()
	if err := os.Chdir(execroot); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(oldwd); err != nil {
			t.Fatal(err)
		}
	})

	exportArchive := filepath.Join(t.TempDir(), "tracer.x")
	want := strings.TrimSuffix(exportArchive, ".x") + ".a"
	if got := linkArchiveForExistingDependency(exportArchive); got != want {
		t.Fatalf("linkArchiveForExistingDependency() = %q, want %q", got, want)
	}
}

func TestSyntheticHelperManifestKeepsExecrootRelativeDependencies(t *testing.T) {
	paths := orchestrionCachePaths(t.TempDir(), "synthetic-testmain-helpers", "abc123")
	if err := os.MkdirAll(paths.entryDir, 0o755); err != nil {
		t.Fatalf("mkdir helper cache: %v", err)
	}
	compilePath := filepath.Join(paths.entryDir, "exports", "manual", "helper.iface.a")
	linkPath := filepath.Join(paths.entryDir, "exports", "manual", "helper.a")
	if err := os.MkdirAll(filepath.Dir(compilePath), 0o755); err != nil {
		t.Fatalf("mkdir helper exports: %v", err)
	}

	execrootArchive := filepath.Join("bazel-out", "pkg", "tracer.x")
	compiled := map[string]compiledModuleArchive{
		"example.com/helper": {
			compilePath: compilePath,
			linkPath:    linkPath,
			linkClosure: map[string]string{
				"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer": execrootArchive,
			},
		},
	}
	if err := writeSyntheticTestmainHelperManifest(paths.entryDir, compiled, syntheticTestmainHelperDecisionState{}, []string{"key=value"}); err != nil {
		t.Fatalf("writeSyntheticTestmainHelperManifest error: %v", err)
	}

	got, _, err := loadSyntheticTestmainHelperCache(paths)
	if err != nil {
		t.Fatalf("loadSyntheticTestmainHelperCache error: %v", err)
	}
	gotArchive := got["example.com/helper"]
	if gotArchive.compilePath != compilePath {
		t.Fatalf("compilePath = %q, want %q", gotArchive.compilePath, compilePath)
	}
	if gotArchive.linkPath != linkPath {
		t.Fatalf("linkPath = %q, want %q", gotArchive.linkPath, linkPath)
	}
	if got := gotArchive.linkClosure["github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"]; got != execrootArchive {
		t.Fatalf("execroot dependency = %q, want %q", got, execrootArchive)
	}
}

func TestSyntheticHelperManifestKeepsExternalAbsoluteDependencies(t *testing.T) {
	paths := orchestrionCachePaths(t.TempDir(), "synthetic-testmain-helpers", "abc123")
	if err := os.MkdirAll(paths.entryDir, 0o755); err != nil {
		t.Fatalf("mkdir helper cache: %v", err)
	}
	externalArchive := filepath.Join(t.TempDir(), "external", "tracer.a")
	compiled := map[string]compiledModuleArchive{
		"example.com/helper": {
			compilePath: externalArchive,
			linkPath:    externalArchive,
			linkClosure: map[string]string{
				"github.com/DataDog/dd-trace-go/v2/ddtrace/tracer": externalArchive,
			},
		},
	}
	if err := writeSyntheticTestmainHelperManifest(paths.entryDir, compiled, syntheticTestmainHelperDecisionState{}, []string{"key=value"}); err != nil {
		t.Fatalf("writeSyntheticTestmainHelperManifest error: %v", err)
	}

	got, _, err := loadSyntheticTestmainHelperCache(paths)
	if err != nil {
		t.Fatalf("loadSyntheticTestmainHelperCache error: %v", err)
	}
	gotArchive := got["example.com/helper"]
	if gotArchive.compilePath != externalArchive {
		t.Fatalf("compilePath = %q, want %q", gotArchive.compilePath, externalArchive)
	}
	if gotArchive.linkPath != externalArchive {
		t.Fatalf("linkPath = %q, want %q", gotArchive.linkPath, externalArchive)
	}
	if got := gotArchive.linkClosure["github.com/DataDog/dd-trace-go/v2/ddtrace/tracer"]; got != externalArchive {
		t.Fatalf("external dependency = %q, want %q", got, externalArchive)
	}
}

func TestWaitForJobserverReadyAcceptsListeningTCPPort(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	if err := waitForJobserverReady("nats://"+listener.Addr().String(), time.Second); err != nil {
		t.Fatalf("waitForJobserverReady() error = %v", err)
	}
}

func TestWaitForJobserverReadyRejectsURLWithoutHost(t *testing.T) {
	if err := waitForJobserverReady("nats://", time.Millisecond); err == nil {
		t.Fatal("waitForJobserverReady() succeeded for URL without host")
	}
}
