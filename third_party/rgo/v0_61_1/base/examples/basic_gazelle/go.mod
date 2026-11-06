// Go uses this file to track module dependencies and to mark the root directory
// of a Go module. This file is maintained with Go tools outside of Bazel.
// For example, you can use 'bazel run @rules_go//go -- mod tidy' or
// 'go mod tidy' to add requirements for missing modules.
//
// Gazelle's go_deps module extension imports dependency declarations
// from this file.

module github.com/bazel-contrib/rules_go/examples/basic_gazelle

go 1.26.0
