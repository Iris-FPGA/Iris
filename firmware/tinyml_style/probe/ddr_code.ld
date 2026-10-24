/* Execute the diagnostic loops from DDR while preserving the control stack
 * and trap report in BRAM. This exercises simultaneous instruction/data
 * traffic, which a BRAM-only diagnostic does not cover. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY {
  bram (rwx) : ORIGIN = 0xf9000000, LENGTH = 0xc00
  ddr (rwx) : ORIGIN = 0x00800000, LENGTH = 0x10000
}
SECTIONS {
  .init : { KEEP(*(.init)) } > bram
  .text : { *(.text .text.*) } > ddr
  .rodata : { *(.rodata .rodata.*) } > ddr
  .data : { *(.data .data.*) } > ddr
  .bss (NOLOAD) : { *(.bss .bss.*) } > ddr
  ASSERT(SIZEOF(.bss) == 0, "probe must not require BSS initialization")
}
