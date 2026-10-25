/* PYNQ-Z2 application: runs from main RAM, 128 KB at 0x8000_0000, of which
 * this region is the lower 124 KB.
 *
 * The top 4 KB is the mailbox -- CVA5's console when nothing is listening to
 * its UART, read out by the Zynq PS. It is deliberately OUTSIDE this region:
 * nothing is linked there, so `objcopy -O binary` of any image stops short of
 * it and neither loader writes over it. soc.h's MBOX_BASE is the address,
 * tools/check-soc-map.py checks that this region still ends exactly there,
 * and _stack_top below lands on the same boundary -- the stack grows down
 * from the mailbox, it does not grow into it.
 *
 * The layout is a contract with the hardware, in two places:
 *
 *   RAM_BASE + 0x00   the trap handler. cva5_wrapper's RESET_TVEC points here,
 *                     because nothing writes mtvec and the Debug Module now
 *                     occupies 0x0000_0000, so a trap cannot be left to go
 *                     there. trap.S provides it, and every image links trap.S.
 *   RAM_BASE + 0x40   _start, from crt0.S. cva5_wrapper's RESET_VEC points
 *                     here, and so will the boot ROM's ENTRY_ADDR.
 *
 * The ASSERT at the bottom is what keeps those from drifting: add enough to
 * the handler and the link fails, rather than the board jumping into the
 * middle of it.
 */
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { RAM (rwxai) : ORIGIN = 0x80000000, LENGTH = 124K }
SECTIONS {
  /* Drop non-code sections that would otherwise be allocated ahead of the
     code: the build-id note is ALLOC, and the first bytes of this region must
     be the trap handler. */
  /DISCARD/ : { *(.note*) *(.comment*) *(.riscv.attributes) }

  /* The handler, padded out to the entry point so _start lands at +0x40. */
  .trap ORIGIN(RAM) : {
    KEEP(*(.trap))
    . = 0x40;
  } > RAM

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

ASSERT(trap_entry == ORIGIN(RAM),
  "trap_entry must be at RAM_BASE: cva5_wrapper's RESET_TVEC is a hardware parameter")
ASSERT(_start == ORIGIN(RAM) + 0x40,
  "_start must be at RAM_BASE + 0x40: cva5_wrapper's RESET_VEC is a hardware parameter")
