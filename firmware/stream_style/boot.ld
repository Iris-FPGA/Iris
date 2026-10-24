OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { ocr (rx) : ORIGIN = 0xf9000000, LENGTH = 0x1f00 }
SECTIONS {
 .init : { KEEP(*(.init)) } > ocr
 /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) }
}
ASSERT(SIZEOF(.init) <= 0x1f00, "Boot payload exceeds OCR area below diagnostic word")
