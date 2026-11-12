// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package recursiveargs

import (
	"flag"
	"os"
	"strings"
	"testing"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

func TestRecursiveMakeArgs(t *testing.T) {
	args := flag.Args()
	if len(args) != 2 || args[1] != "$(literal)" {
		t.Fatalf("wrong argv: %q", args)
	}
	r, err := runfiles.New()
	if err != nil {
		t.Fatal(err)
	}
	path, err := r.Rlocation(args[0])
	if err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(body)) != "public data" {
		t.Fatalf("wrong data: %q", body)
	}
}
