/*
 * Boot ROM for the PYNQ-Z2 CVA5 example.
 *
 * Lives in the CPU's local memory at the reset vector (0x8000_0000). It prints
 * a short banner so a reset is visible on the console, then jumps to the
 * application in main RAM at 0x4000_0000, which the debugger loads over JTAG.
 *
 * Keep this small: the ROM is 256 words and is baked into the bitstream.
 */
    .equ UART_BASE, 0x60000000
    .equ UART_TX,   0x04
    .equ UART_STAT, 0x08
    .equ TX_FULL,   0x08
    .equ APP_BASE,  0x40000000

    .section .text.init
    .globl _start
_start:
    li   a0, UART_BASE
    la   a1, banner

putc_loop:
    lbu  a2, 0(a1)                  /* next character, 0 ends the string */
    beqz a2, done
wait_tx:
    lw   a3, UART_STAT(a0)
    andi a3, a3, TX_FULL
    bnez a3, wait_tx                /* spin while the Tx FIFO is full */
    sw   a2, UART_TX(a0)
    addi a1, a1, 1
    j    putc_loop

done:
    li   t0, APP_BASE
    jr   t0

    .section .rodata
banner:
    .asciz "\r\nCVA5 boot: starting application at 0x40000000\r\n"
