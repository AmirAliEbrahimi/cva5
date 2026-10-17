/* Minimal puts() for the CVA5 examples (no libc in the toolchain).
 * Targets the AXI UART Lite, whose address comes from soc.h -- 0x1000_0000 on
 * the board, 0x6000_0000 in the Verilator sim, for the reason soc.h gives.
 * Polls Tx-full before each write so it is correct on real hardware as well
 * as in the testbench. */
#include "soc.h"

#define UART_TX   (*(volatile unsigned int *)(UART_BASE + UART_TX_OFF))
#define UART_STAT (*(volatile unsigned int *)(UART_BASE + UART_STAT_OFF))

static void uart_putc(char c) {
    while (UART_STAT & UART_TX_FULL) ;   /* wait for room in the Tx FIFO */
    UART_TX = (unsigned char)c;
}

int puts(const char *s) {
    while (*s) uart_putc(*s++);
    uart_putc('\n');
    return 0;
}
