package asmcflags

/*
extern int asm_cflags_value(void);
*/
import "C"

// Value returns the sentinel integer emitted by the assembly helper.
func Value() int {
	return int(C.asm_cflags_value())
}
