#include <stdint.h>
#include "bsp.h"
#include "clint.h"
#ifndef IRIS_PROBE_BASE
#define IRIS_PROBE_BASE 0x00f00000u
#endif

// Select the BRAM or mixed DDR-code linker script. Results remain in BRAM.
void probe_main(void) {
    volatile uint32_t *status = (volatile uint32_t *)0xf9000e00;
    volatile uint32_t *ddr = (volatile uint32_t *)IRIS_PROBE_BASE;
    for (unsigned i = 0; i < 20; ++i) status[i] = 0;
    status[0] = 1;
    bsp_init();
    uart_writeStr(BSP_UART_TERMINAL, "IRIS BRAM DDR probe\r\n");
    status[0] = 2;
    for (unsigned i = 0; i < 16384; ++i) ddr[i] = 0xa5000000u + i;
    __asm__ volatile("fence rw,rw" ::: "memory");
    status[0] = 3;
    for (unsigned i = 0; i < 16384; ++i) {
        uint32_t v = ddr[i];
        if (v != 0xa5000000u + i) {
            if (status[1]++ == 0) {
                status[2] = (uint32_t)&ddr[i];
                status[3] = v;
                status[4] = 0xa5000000u + i;
            }
        }
    }
    status[0] = 9;
    const uint64_t hold_begin = clint_getTime(BSP_CLINT);
    while (clint_getTime(BSP_CLINT) - hold_begin < 3u * SYSTEM_CLINT_HZ) {}
    for (unsigned i = 0; i < 16384; ++i)
        if (ddr[i] != 0xa5000000u + i) ++status[16];
    // Sparse writes must preserve neighbouring lanes. Sequential full-array
    // patterns cannot detect a controller/PHY that mishandles byte strobes.
    status[0] = 10;
    for (unsigned i = 0; i < 4096; ++i) ddr[i * 4 + 1] = 0xc3000000u + i;
    for (unsigned i = 0; i < 16384; ++i) {
        const uint32_t expected = (i % 4 == 1) ? 0xc3000000u + i / 4 : 0xa5000000u + i;
        if (ddr[i] != expected) ++status[17];
    }
    volatile uint8_t *sparse = (volatile uint8_t *)ddr;
    for (unsigned i = 0; i < 4096; ++i) sparse[i * 16 + 9] = 0x5bu;
    for (unsigned i = 0; i < 16384; ++i) {
        uint32_t expected = (i % 4 == 1) ? 0xc3000000u + i / 4 : 0xa5000000u + i;
        if (i % 4 == 2) expected = (expected & 0xffff00ffu) | 0x5b00;
        if (ddr[i] != expected) ++status[18];
    }
    // Permute every word, immediately checking all four lanes of its line.
    // Inverse(317) modulo 16384 is 7701, so the expected value follows from
    // the visit number without storing a second reference array in DDR.
    status[0] = 11;
    for (unsigned i = 0; i < 16384; ++i) ddr[i] = 0xa5000000u + i;
    for (unsigned i = 0; i < 16384; ++i) {
        const unsigned index = (i * 317u + 11u) & 16383u;
        ddr[index] = 0xc3000000u + index;
        for (unsigned lane = 0; lane < 4; ++lane) {
            const unsigned j = (index & ~3u) + lane;
            const unsigned visit = ((j - 11u) * 7701u) & 16383u;
            const uint32_t expected = (visit <= i ? 0xc3000000u : 0xa5000000u) + j;
            const uint32_t actual = ddr[j];
            if (actual != expected) {
                if (status[19]++ == 0 && status[1] == 0) {
                    status[2] = (uint32_t)&ddr[j];
                    status[3] = actual;
                    status[4] = expected;
                }
            }
        }
    }
    status[0] = 4;
    for (unsigned i = 0; i < 16384; ++i) ddr[i] = 0x5a000000u + i * 2654435761u;
    __asm__ volatile("fence rw,rw" ::: "memory");
    for (unsigned i = 0; i < 16384; ++i)
        if (ddr[i] != 0x5a000000u + i * 2654435761u) ++status[5];
    status[0] = 5;
    volatile uint8_t *bytes = (volatile uint8_t *)ddr;
    for (unsigned i = 0; i < 65536; ++i) bytes[i] = (uint8_t)(i * 29 + 37);
    for (unsigned i = 0; i < 65536; ++i)
        if (bytes[i] != (uint8_t)(i * 29 + 37)) ++status[9];
    for (unsigned i = 0; i < 16384; ++i) {
        unsigned j = i * 4;
        uint32_t expected = (uint8_t)(j * 29 + 37) |
            ((uint32_t)(uint8_t)((j + 1) * 29 + 37) << 8) |
            ((uint32_t)(uint8_t)((j + 2) * 29 + 37) << 16) |
            ((uint32_t)(uint8_t)((j + 3) * 29 + 37) << 24);
        if (ddr[i] != expected) ++status[10];
    }
    status[0] = 6;
    volatile uint16_t *halves = (volatile uint16_t *)ddr;
    for (unsigned i = 0; i < 32768; ++i) halves[i] = (uint16_t)(i * 317 + 41);
    for (unsigned i = 0; i < 32768; ++i)
        if (halves[i] != (uint16_t)(i * 317 + 41)) ++status[11];
    status[0] = 7;
    for (unsigned i = 0; i < 16384; ++i) {
        uint32_t value = 0x51a73480u + i;
        ddr[i] = value;
        if (ddr[i] != value) ++status[12];
    }
    for (unsigned i = 0; i < 65536; ++i) {
        uint8_t value = (uint8_t)(i * 17 + 31);
        bytes[i] = value;
        if (bytes[i] != value) ++status[13];
    }
    for (unsigned i = 0; i < 32768; ++i) {
        uint16_t value = (uint16_t)(i * 719 + 91);
        halves[i] = value;
        if (halves[i] != value) ++status[14];
    }
    // Distinct instruction in each 32-bit lane tests executable DDR as well.
    status[0] = 8;
    ddr[0] = 0x12345537u;  // lui a0,0x12345
    ddr[1] = 0x67850513u;  // addi a0,a0,0x678
    ddr[2] = 0x00150513u;  // addi a0,a0,1
    ddr[3] = 0x00008067u;  // ret
    __asm__ volatile("fence rw,rw; fence.i" ::: "memory");
    status[15] = ((uint32_t (*)(void))ddr)();
    uart_writeStr(BSP_UART_TERMINAL, "DDR probe errors=");
    uart_writeHex(BSP_UART_TERMINAL, status[1]);
    uart_writeHex(BSP_UART_TERMINAL, status[5]);
    uart_writeStr(BSP_UART_TERMINAL, "\r\n");
    status[0] = (status[1] || status[5] || status[9] || status[10] || status[11] || status[12] || status[13] || status[14] || status[15] != 0x12345679u || status[16] || status[17] || status[18] || status[19]) ? 0xbad00001u : 0x600d0001u;
    for (;;) {}
}
