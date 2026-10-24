.section .init
.global _start
_start:
    la sp, _sp
    csrw mie, zero
    csrw mstatus, zero
    la t0, trap_entry
    csrw mtvec, t0
    la a0, _data_lma
    la a1, _data
    la a2, _edata
1:  bgeu a1, a2, 2f
    lw t0, 0(a0)
    sw t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    j 1b
2:  la a0, __bss_start
    la a1, _end
3:  bgeu a0, a1, 4f
    sw zero, 0(a0)
    addi a0, a0, 4
    j 3b
4:  call main
5:  j 5b
