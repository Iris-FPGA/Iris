/* Sapphire start.S ABI; the board integration must supply a reserved DDR window.
 * DDR must be initialized before _start. This is not a BRAM bootloader image. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY {
  ddr (rwx) : ORIGIN = __iris_ddr_base, LENGTH = __iris_ddr_bytes
  control_data (rw) : ORIGIN = 0xf9001000, LENGTH = 0x1000
  control_stack (rw) : ORIGIN = 0xf9002000, LENGTH = 0x2000
}
SECTIONS {
  .init : { KEEP(*(.init)) } > ddr
  .text : { *(.text .text.*) *(.gnu.linkonce.t.*) } > ddr
  .fini : { KEEP(*(.fini)) } > ddr
  .rodata : ALIGN(16) { *(.rodata .rodata.* .rdata .gnu.linkonce.r.*) } > ddr
  .preinit_array : ALIGN(4) {
    PROVIDE_HIDDEN(__preinit_array_start = .);
    KEEP(*(.preinit_array))
    PROVIDE_HIDDEN(__preinit_array_end = .);
  } > ddr
  .init_array : ALIGN(4) {
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*))) KEEP(*(.init_array))
    PROVIDE_HIDDEN(__init_array_end = .);
  } > ddr
  .fini_array : ALIGN(4) {
    PROVIDE_HIDDEN(__fini_array_start = .);
    KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*))) KEEP(*(.fini_array))
    PROVIDE_HIDDEN(__fini_array_end = .);
  } > ddr
  .tinyml_driver_data : ALIGN(16) {
    __iris_driver_data_start = .; *(.sdata.layer_mode)
    . = ALIGN(4); __iris_driver_data_end = .;
  } > control_data AT> ddr
  __iris_driver_data_lma = LOADADDR(.tinyml_driver_data);
  .data : ALIGN(16) {
    _data = .;
    *(.data .data.* .gnu.linkonce.d.*)
    . = ALIGN(8); __global_pointer$ = . + 0x7f0;
    *(.sdata .sdata.* .srodata .srodata.* .gnu.linkonce.s.*)
    . = ALIGN(4); _edata = .;
  } > ddr
  _data_lma = LOADADDR(.data);
  /* Vendor interrupt mailboxes are CPU scalar control state, never DMA data.
   * Select these input sections before the general DDR BSS wildcard. */
  .tinyml_driver_bss (NOLOAD) : ALIGN(16) {
    __iris_driver_bss_start = .;
    *(.bss.global_intr_id .bss._ZL8conv_int .bss._ZL4intr .bss.hw_accel_setting .sbss.accel_count)
    . = ALIGN(16); __iris_driver_bss_end = .;
  } > control_data
  .bss (NOLOAD) : ALIGN(16) {
    __bss_start = .;
    *(.sbss .sbss.* .bss .bss.* .gnu.linkonce.b.* .gnu.linkonce.sb.*) *(COMMON)
    . = ALIGN(16); _end = .; end = .;
  } > ddr
  .heap (NOLOAD) : {
    . += 0x200000; _heap_end = .;
  } > ddr
  .stack (NOLOAD) : ALIGN(16) {
    __iris_stack_bottom = .; . += 0x2000; _sp = .;
  } > control_stack
  .tinyml_control (NOLOAD) : ALIGN(16) {
    __iris_control_start = .; KEEP(*(.tinyml_control)) __iris_control_end = .;
  } > control_data
  .tinyml_arena (NOLOAD) : ALIGN(64) {
    __iris_arena_start = .; KEEP(*(.tinyml_arena)) __iris_arena_end = .;
  } > ddr
  ASSERT(SIZEOF(.tinyml_arena) > 0, "missing DDR tensor arena")
  ASSERT(SIZEOF(.tinyml_control) + SIZEOF(.tinyml_driver_bss) + SIZEOF(.tinyml_driver_data) <= LENGTH(control_data), "OCR control data too large")
  ASSERT(__iris_arena_end <= ORIGIN(ddr) + LENGTH(ddr), "DDR window too small")
}
