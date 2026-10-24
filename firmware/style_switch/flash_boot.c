// Read-only SPI boot. The build binds exact byte count and FNV to the payload.
// Firmware/model bytes occupy a separate Flash region after both FPGA images.
#include <stdint.h>
#include "bsp.h"
#include "spi.h"

__attribute__((noreturn)) void flash_boot(void) {
    const uint32_t spi = SYSTEM_SPI_0_IO_CTRL;
    Spi_Config config = {0, 0, 0, 9, 4, 4, 4}; // Mode 0, 5 MHz at 100 MHz.
    spi_applyConfig(spi, &config);
    // Efinity's spi_low_power_mode leaves the boot Flash in deep power-down.
    // A queued SS-disable must finish before measuring the wake-up interval.
    spi_select(spi, 0);
    spi_write(spi, 0xab); // Release deep power-down; harmless when awake.
    spi_diselect(spi, 0);
    while (spi_cmdAvailability(spi) != SYSTEM_SPI_0_IO_PARAMETER_CMD_FIFO_DEPTH) {}
    volatile uint32_t *time_low = (volatile uint32_t *)(SYSTEM_CLINT_CTRL + 0xbff8);
    uint32_t wake = *time_low;
    while ((uint32_t)(*time_low - wake) < 100000u) {} // 1 ms > Flash tRES1.
    spi_select(spi, 0);
    spi_write(spi, 0x03); // READ with a 24-bit address; no Flash writes.
    spi_write(spi, (PAYLOAD_OFFSET >> 16) & 255);
    spi_write(spi, (PAYLOAD_OFFSET >> 8) & 255);
    spi_write(spi, PAYLOAD_OFFSET & 255);
    volatile uint8_t *destination = (volatile uint8_t *)0x00800000u;
    for (unsigned i = 0; i < PAYLOAD_BYTES; ++i)
        destination[i] = (uint8_t)spi_read(spi);
    spi_diselect(spi, 0);
    asm volatile(".word 0x0000500f\n fence rw,rw" ::: "memory");
    uint32_t hash = 0x811c9dc5u;
    for (unsigned i = 0; i < PAYLOAD_BYTES; ++i)
        hash = (hash ^ destination[i]) * 0x01000193u;
    if (hash != PAYLOAD_FNV) {
        *(volatile uint32_t *)0xf9000ffcu = 0xbadbee02u;
        for (;;) {}
    }
    // Match the existing OCR stream bootstrap's camera-settle interval.
    const uint32_t start = *time_low;
    while ((uint32_t)(*time_low - start) < 200000000u) {}
    asm volatile("fence.i" ::: "memory");
    ((void (*)(void))0x00800000u)();
    for (;;) {}
}
