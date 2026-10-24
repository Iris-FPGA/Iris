.section .init
.global _start
_start:
    li sp, 0xf9000df0
    la t0, probe_trap
    csrw mtvec, t0
    csrw mie, zero
    csrw mstatus, zero
    call probe_main
1:  j 1b
.align 2
probe_trap:
    li t0, 0xf9000e00
    li t1, 0xdead0001
    sw t1, 0(t0)
    csrr t1, mcause
    sw t1, 24(t0)
    csrr t1, mepc
    sw t1, 28(t0)
    csrr t1, mtval
    sw t1, 32(t0)
2:  j 2b
