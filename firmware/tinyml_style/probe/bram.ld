OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { bram (rwx) : ORIGIN = 0xf9000000, LENGTH = 0xc00 }
SECTIONS {
  .init : { KEEP(*(.init)) } > bram
  .text : { *(.text .text.*) } > bram
  .rodata : { *(.rodata .rodata.*) } > bram
  .data : { *(.data .data.*) } > bram
  .bss (NOLOAD) : { *(.bss .bss.*) } > bram
  ASSERT(SIZEOF(.bss) == 0, "probe must not require BSS initialization")
}
