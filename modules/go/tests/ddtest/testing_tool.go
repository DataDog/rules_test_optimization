// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

// Command testing_tool imports testing, as some generators do, and runs as an
// exec tool below an instrumented test.
package main

import (
	"flag"
	"fmt"
	"testing"
)

func main() {
	testing.Init()
	flag.Parse()
	fmt.Printf("short=%t\n", testing.Short())
}
