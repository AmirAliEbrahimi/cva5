/*
 * Smallest useful program for this system: print a line and stop.
 *
 *   tools/cva5-run  examples/sw/hello.c     on the board, over JTAG
 *   tools/cva5-qemu examples/sw/hello.c     under QEMU
 *
 * puts() comes from the runtime in this directory, which both scripts link in
 * by default; it writes to the AXI UART Lite at 0x6000_0000.
 */
#include <stdio.h>

int main(void) {
    puts("Hello from CVA5");

    /*
     * Park here. Returning would land in crt0's termination loop, which is
     * harmless but makes a halted CPU look like a crashed one in a debugger.
     */
    for (;;);
}
