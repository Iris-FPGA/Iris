// Small firmware + weights fit in the existing 16KiB OCR initial contents.
// Copy once into DDR, audit the copy, then enter the normal firmware startup.
#include "soc.h"
.section .init
.global _start
_start:
    csrw mie, zero
    csrw mstatus, zero
    la t0, boot_fail
    csrw mtvec, t0
    la t0, payload
    la t1, payload_end
    li t2, 0x00800000
1:  bgeu t0, t1, 2f
    lw t3, 0(t0)
    sw t3, 0(t2)
    addi t0, t0, 4
    addi t2, t2, 4
    j 1b
2:  .word 0x0000500f
    fence rw, rw
    li t0, 0x00800000
    li t1, PAYLOAD_BYTES
    li t2, 0x811c9dc5
    li t4, 0x01000193
3:  lbu t3, 0(t0)
    xor t2, t2, t3
    mul t2, t2, t4
    addi t0, t0, 1
    addi t1, t1, -1
    bnez t1, 3b
    li t3, PAYLOAD_FNV
    bne t2, t3, boot_fail
    // Allow camera I2C setup and video reset release after DDR calibration.
    // This is a startup delay, not a per-frame cache-reset workaround.
    li t0, SYSTEM_CLINT_CTRL + 0xbff8
    lw t1, 0(t0)
    li t3, 200000000
4:  lw t2, 0(t0)
    sub t2, t2, t1
    bltu t2, t3, 4b
    fence.i
    li t0, 0x00800000
    jr t0
boot_fail:
    li t0, 0xf9001ffc
    li t1, 0xbadbee00
    sw t1, 0(t0)
5:  j 5b
.balign 4
payload:
    .incbin "stream_style-live.bin"
.balign 4
payload_end:
