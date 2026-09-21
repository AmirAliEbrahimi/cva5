/* PYNQ-Z2 application: runs from main RAM (AXI BRAM), 128 KB at 0x4000_0000.
 * The boot ROM jumps here; the debugger loads this image over SBA. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { RAM (rwxai) : ORIGIN = 0x40000000, LENGTH = 128K }
SECTIONS {
  /* Drop non-code sections that would otherwise be allocated ahead of the
     code: the build-id note is ALLOC, and the boot ROM jumps to the start of
     this region, so the first bytes must be _start. */
  /DISCARD/ : { *(.note*) *(.comment*) *(.riscv.attributes) }
  .text : {
    *(.text.init) *(.text*)
    *(.rodata*) *(.srodata*)
    . = ALIGN(4);
  } > RAM
  .data : {
    *(.data*) *(.sdata*)
    . = ALIGN(4);
  } > RAM
  .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON); __bss_end = .; } > RAM
  . = ALIGN(16);
  _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
