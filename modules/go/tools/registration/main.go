// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

// Command registration writes the file that registers a Go test package with
// Mini, the runtime of ddtest instrument: the file that ddtest instrument
// writes as zz_dd_ci_visibility_test.go. It goes in the test's external
// package when one of its sources declares it, and in its own package
// otherwise.
//
// Usage: registration -o OUT SRC...
package main

import (
	"errors"
	"flag"
	"fmt"
	"go/ast"
	"go/build/constraint"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strings"
)

const runtimeImport = "github.com/DataDog/ddtest/ddto/testopt"

func main() {
	out := flag.String("o", "", "the registration file to write")
	flag.Parse()
	name, err := testPackage(flag.Args())
	if err == nil && *out == "" {
		err = errors.New("-o is required")
	}
	if err == nil {
		err = os.WriteFile(*out, []byte(source(name)), 0o644)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "registration:", err)
		os.Exit(1)
	}
}

func source(name string) string {
	return "package " + name + "\nimport __dd_ci_runtime \"" + runtimeImport + "\"\nfunc init() { __dd_ci_runtime.RegisterTestPackage() }\n"
}

// testPackage returns the package that the registration joins: the external
// test package when a source declares one, the package under test otherwise.
func testPackage(files []string) (string, error) {
	names := map[string]bool{}
	for _, file := range files {
		if !strings.HasSuffix(file, ".go") {
			continue
		}
		parsed, err := parser.ParseFile(token.NewFileSet(), file, nil, parser.PackageClauseOnly|parser.ParseComments)
		if err != nil {
			return "", err
		}
		if ignored(parsed.Comments) {
			continue
		}
		names[parsed.Name.Name] = true
	}
	var external, internal []string
	for name := range names {
		if strings.HasSuffix(name, "_test") {
			external = append(external, name)
		} else {
			internal = append(internal, name)
		}
	}
	sort.Strings(external)
	sort.Strings(internal)
	switch {
	case len(external) == 1:
		return external[0], nil
	case len(external) == 0 && len(internal) == 1:
		return internal[0], nil
	case len(names) == 0:
		return "", errors.New("no Go sources")
	}
	return "", fmt.Errorf("sources declare packages %s", strings.Join(append(internal, external...), ", "))
}

// ignored reports whether a //go:build constraint excludes the file on every
// platform, such as //go:build ignore on generators kept next to tests: the
// go command never sets the ignore tag. Other constraints, such as !windows,
// hold for some platform, and rules_go applies them itself.
func ignored(groups []*ast.CommentGroup) bool {
	for _, group := range groups {
		for _, comment := range group.List {
			if !constraint.IsGoBuild(comment.Text) {
				continue
			}
			expr, err := constraint.Parse(comment.Text)
			return err == nil && !satisfiable(expr)
		}
	}
	return false
}

// satisfiable reports whether some set of tags other than ignore satisfies
// expr. A constraint with too many tags to enumerate counts as satisfiable.
func satisfiable(expr constraint.Expr) bool {
	var tags []string
	collect(expr, map[string]bool{"ignore": true}, &tags)
	if len(tags) > 16 {
		return true
	}
	for set := 0; set < 1<<len(tags); set++ {
		if expr.Eval(func(tag string) bool {
			for i, name := range tags {
				if name == tag {
					return set&(1<<i) != 0
				}
			}
			return false
		}) {
			return true
		}
	}
	return false
}

func collect(expr constraint.Expr, seen map[string]bool, tags *[]string) {
	switch expr := expr.(type) {
	case *constraint.TagExpr:
		if !seen[expr.Tag] {
			seen[expr.Tag] = true
			*tags = append(*tags, expr.Tag)
		}
	case *constraint.NotExpr:
		collect(expr.X, seen, tags)
	case *constraint.AndExpr:
		collect(expr.X, seen, tags)
		collect(expr.Y, seen, tags)
	case *constraint.OrExpr:
		collect(expr.X, seen, tags)
		collect(expr.Y, seen, tags)
	}
}
