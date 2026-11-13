// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package wrapperdata

import (
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

func TestPublicData(t *testing.T) {
	args := flag.Args()
	if extra := os.Getenv("EXPECTED_RUNTIME_EXTRA"); extra != "" {
		if len(args) != 11 || args[10] != extra {
			t.Fatalf("runtime argument changed: %q", args)
		}
		args = args[:10]
	}
	if len(args) != 10 {
		t.Fatalf("expected location and rlocationpath, got %q", args)
	}
	expectedArgs := []string{"", `quote "inside"`, `trailing\`, "%PATH%", "bang!", "a&b|c<d>e^f", "λ words", "$(literal)"}
	if !reflect.DeepEqual(args[2:], expectedArgs) {
		t.Fatalf("literal arguments changed: %q", args[2:])
	}
	r, err := runfiles.New()
	if err != nil {
		t.Fatal(err)
	}
	source, err := r.Rlocation(filepath.ToSlash(filepath.Join(os.Getenv("TEST_WORKSPACE"), args[0])))
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	expected := os.Getenv("EXPECTED_PUBLIC_DATA")
	if expected == "" {
		expected = "public data"
	}
	if strings.TrimSpace(string(data)) != expected {
		t.Fatalf("wrong data: %q", data)
	}
	binary, err := r.Rlocation(args[1])
	if err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command(binary).CombinedOutput()
	if err != nil {
		t.Fatalf("data binary: %v: %s", err, output)
	}
	if strings.TrimSpace(string(output)) != "through-public-data" {
		t.Fatalf("x_defs lost: %q", output)
	}
}
