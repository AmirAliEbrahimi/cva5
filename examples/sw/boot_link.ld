/* Boot ROM: CVA5 local memory, 1 KB at the reset vector. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { ROM (rxai) : ORIGIN = 0x80000000, LENGTH = 1K }
SECTIONS {
  /* Drop non-code sections that would otherwise be allocated ahead of the
     code: the build-id note is ALLOC, so without this the reset vector holds
     note bytes instead of instructions. */
  /DISCARD/ : { *(.note*) *(.comment*) *(.riscv.attributes) }
  .text : { *(.text.init) *(.text*) *(.rodata*) . = ALIGN(4); } > ROM
}
