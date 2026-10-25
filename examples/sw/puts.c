/* Minimal puts() for the CVA5 examples (no libc in the toolchain).
 * Targets the AXI UART Lite, whose address comes from soc.h -- 0x1000_0000 on
 * the board, 0x6000_0000 in the Verilator sim, for the reason soc.h gives.
 * Polls Tx-full before each write so it is correct on real hardware as well
 * as in the testbench. */
#include "soc.h"

#ifdef CVA5_MBOX
#include "mbox.h"
#endif

#define UART_TX   (*(volatile unsigned int *)(UART_BASE + UART_TX_OFF))
#define UART_STAT (*(volatile unsigned int *)(UART_BASE + UART_STAT_OFF))

/*
 * Every character goes to the UART, and with -DCVA5_MBOX to the mailbox as
 * well -- see soc.h for what that is and why the board needs it.
 *
 * Both, not either. The UART transmits whether or not an adapter is listening
 * (nothing gates the Tx FIFO on a receiver, so the wait below always
 * completes), so a mailbox build still works on a bench with the FTDI
 * attached, and one binary covers both setups. The cost is a handful of
 * instructions per character on a path that is already waiting on a 115200
 * baud FIFO.
 */
static void uart_putc(char c) {
    while (UART_STAT & UART_TX_FULL) ;   /* wait for room in the Tx FIFO */
    UART_TX = (unsigned char)c;
#ifdef CVA5_MBOX
    mbox_putc(c);
#endif
}

/* Like puts, without the newline. Exists so that a caller printing a label and
 * then a value does not have to assemble the two in a buffer of its own: the
 * fixed-size buffers that replaced it in plic.c and spi.c silently truncated
 * the label, and a 49-character one came out of the board as
 * "draining a source lef0x00000001". */
int putstr(const char *s) {
    while (*s) uart_putc(*s++);
    return 0;
}

int puts(const char *s) {
    putstr(s);
    uart_putc('\n');
    return 0;
}
