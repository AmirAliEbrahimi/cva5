/* CVA5 verilator sim: single 4 KB memory at 0x80000000 (STARTING_ADDR).
 *
 * Unlike fpga_link.ld, this does NOT reserve a slot for the trap handler ahead
 * of _start. Upstream's EXAMPLE_CONFIG has RESET_VEC at 0x8000_0000 and
 * RESET_TVEC at zero, and this fork does not modify cva5_config.sv, so _start
 * has to be the first thing in the image and the sim's trap behaviour stays
 * exactly as it was. crt0.S's .trap section is placed after the code here and
 * nothing reaches it. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { RAM (rwxai) : ORIGIN = 0x80000000, LENGTH = 4K }
SECTIONS {
  .text : {
    *(.text.init) *(.text*)
    *(.trap)
    *(.rodata*) *(.srodata*)
    . = ALIGN(4);            /* keep the loadable image a whole number of words */
  } > RAM
  .data : {
    *(.data*) *(.sdata*)
    . = ALIGN(4);
  } > RAM
  .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON); __bss_end = .; } > RAM
  . = ALIGN(16);
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
