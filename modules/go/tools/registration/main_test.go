// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTestPackage(t *testing.T) {
	dir := t.TempDir()
	write := func(name, content string) string {
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		return path
	}
	internal := write("a_test.go", "package widget\n")
	external := write("b_test.go", "// Copyright\n\npackage widget_test\n")
	library := write("widget.go", "package widget\n")
	generator := write("gen.go", "//go:build ignore\n\npackage main\n")
	other := write("other_test.go", "package gadget_test\n")
	asm := write("x.s", "TEXT ·f(SB),0,$0\n")
	for _, c := range []struct {
		files []string
		want  string
	}{
		{[]string{internal, library}, "widget"},
		{[]string{internal, external, library}, "widget_test"},
		{[]string{internal, generator, asm}, "widget"},
		{[]string{internal, external, other}, ""},
		{[]string{asm}, ""},
	} {
		got, err := testPackage(c.files)
		if got != c.want || (err == nil) != (c.want != "") {
			t.Errorf("%v: %q, %v; want %q", c.files, got, err, c.want)
		}
	}
	if got := source("widget_test"); got != "package widget_test\nimport __dd_ci_runtime \"github.com/DataDog/ddtest/ddto/testopt\"\nfunc init() { __dd_ci_runtime.RegisterTestPackage() }\n" {
		t.Errorf("source: %q", got)
	}
}
