#ifndef ASM_CFLAGS_EXPECTED
#error "ASM_CFLAGS_EXPECTED was not passed through to the assembler"
#endif

.text
.globl asm_cflags_value
.type asm_cflags_value, @function
asm_cflags_value:
	mov $123, %eax
	ret
