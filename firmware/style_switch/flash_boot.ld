OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { ocr (rwx) : ORIGIN = 0xf9000000, LENGTH = 0x0f00 }
SECTIONS {
 .init : { KEEP(*(.init)) *(.text .text.*) *(.rodata .rodata.*) } > ocr
 /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) *(.eh_frame*) }
}
ASSERT(SIZEOF(.init) <= 0xf00, "Flash loader overlaps firmware OCR control state")
