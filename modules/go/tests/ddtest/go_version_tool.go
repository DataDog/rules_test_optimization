// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

// Command go_version_tool prints the Go version it was built with, with its
// GOEXPERIMENT values after X:.
package main

import (
	"fmt"
	"runtime"
)

func main() {
	fmt.Println(runtime.Version())
}
