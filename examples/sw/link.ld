/* CVA5: single 64 KB memory at 0x80000000 (STARTING_ADDR).
 *
 * LENGTH must equal WORDS * 4 from examples/xilinx/cva5_wrapper.sv and
 * cva5_top.v, and RAM_SIZE on the make line. All four have to agree or the
 * generated mem.mif is silently the wrong length. */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { RAM (rwxai) : ORIGIN = 0x80000000, LENGTH = 64K }
SECTIONS {
  .text : {
    /* First in the image: CVA5's RESET_VEC is ORIGIN(RAM), so whatever lands
     * at 0x80000000 is what executes out of reset. KEEP also stops
     * --gc-sections discarding it, since nothing references _start. */
    KEEP(*(.text.init))
    *(.text*)
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

  /* Xilinx's riscv32-xilinx-elf toolchain defaults to --build-id, which emits
   * an ALLOC+LOAD .note.gnu.build-id. Unmentioned here it is an orphan
   * section, and the linker places orphans before .text -- i.e. on the reset
   * vector. The core then executes 36 bytes of hash before reaching _start,
   * with no stack and no .bss clear. Nothing errors; the board just goes
   * quiet. Discarding them also keeps them out of mem.mif. */
  /DISCARD/ : { *(.note*) *(.comment) *(.riscv.attributes) }
}

/* If _start is not at the reset vector the core starts mid-garbage. Make that
 * a link error instead of a silent hang. */
ASSERT(_start == ORIGIN(RAM), "_start must sit at the reset vector -- an orphan section is being placed before .text")
