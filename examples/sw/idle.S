/* The image the bitstream preloads into main memory.
 *
 * Deliberately silent and deliberately nothing: a freshly programmed board
 * parks here and says not a word, so the only thing that ever appears on the
 * UART is whatever you load over JTAG. The reset vector is the bottom of main
 * memory, so this is what the core executes until `make load` replaces it.
 *
 * No crt0, no stack, no .bss to clear -- there is nothing here to need them.
 */
.section .text.init
.globl _start
_start:
1:  j 1b
