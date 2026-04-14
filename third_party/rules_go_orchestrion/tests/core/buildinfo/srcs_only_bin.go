package main

import (
	"fmt"
	"runtime/debug"
)

func main() {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		fmt.Println("NO_BUILD_INFO")
		return
	}

	fmt.Printf("Path=%s\n", info.Path)
	fmt.Printf("GoVersion=%s\n", info.GoVersion)
}
