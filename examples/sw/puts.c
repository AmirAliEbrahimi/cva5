/* Minimal puts() for the CVA5 examples (no libc in the toolchain).
 * Targets the AXI UART Lite the SoC instantiates at 0x60000000:
 *   0x04 = Tx FIFO (write), 0x08 = status (bit 3 = Tx FIFO full).
 * Polls Tx-full before each write so it is correct on real hardware as well
 * as in the Verilator testbench. */
#define UART_BASE 0x60000000u
#define UART_TX   (*(volatile unsigned int *)(UART_BASE + 0x04u))
#define UART_STAT (*(volatile unsigned int *)(UART_BASE + 0x08u))
#define TX_FULL   (1u << 3)

static void uart_putc(char c) {
    while (UART_STAT & TX_FULL) ;   /* wait for room in the Tx FIFO */
    UART_TX = (unsigned char)c;
}

int puts(const char *s) {
    while (*s) uart_putc(*s++);
    uart_putc('\n');
    return 0;
}
