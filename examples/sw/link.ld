/* CVA5 verilator sim: single 4 KB memory at 0x80000000 (STARTING_ADDR). */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { RAM (rwxai) : ORIGIN = 0x80000000, LENGTH = 4K }
SECTIONS {
  .text : {
    *(.text.init) *(.text*)
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
