// Unless explicitly stated otherwise all files in this repository are licensed under
// the Apache 2.0 License.
//
// This product includes software developed at Datadog
// (https://www.datadoghq.com/) Copyright 2025-Present Datadog, Inc.

package asmcflags

/*
extern int asm_cflags_value(void);
*/
import "C"

// Value returns the sentinel integer emitted by the assembly helper.
func Value() int {
	return int(C.asm_cflags_value())
}
