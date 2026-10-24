#include "soc.h"
.section .init
.global _start
_start:
    csrw mie, zero
    csrw mstatus, zero
    li sp, 0xf9003ff0
    la t0, boot_fault
    csrw mtvec, t0
    call flash_boot
boot_fault:
    li t0, 0xf9000ffc
    li t1, 0xbadbee01
    sw t1, 0(t0)
1:  j 1b
