OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY {
  ddr (rx) : ORIGIN = 0x00800000, LENGTH = 0x00100000
  control (rw) : ORIGIN = 0xf9001000, LENGTH = 0x1000
  stack (rw) : ORIGIN = 0xf9002000, LENGTH = 0x2000
}
SECTIONS {
  .init : { KEEP(*(.init)) } > ddr
  .text : { *(.text .text.*) } > ddr
  .rodata : ALIGN(16) { *(.rodata .rodata.* .srodata.*) } > ddr
  .data : ALIGN(4) { _data = .; *(.data .data.* .sdata.*) . = ALIGN(4); _edata = .; } > control AT> ddr
  _data_lma = LOADADDR(.data);
  .bss (NOLOAD) : ALIGN(16) { __bss_start = .; *(.bss .bss.* .sbss .sbss.*) *(COMMON) . = ALIGN(4); _end = .; } > control
  .stack (NOLOAD) : { . += 0x2000; _sp = .; } > stack
}
