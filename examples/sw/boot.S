/*
 * Boot ROM for the PYNQ-Z2 CVA5 example.
 *
 * Lives in the CPU's local memory at the reset vector (0x8000_0000) and does
 * one thing: jump to the application in main RAM at 0x4000_0000, which the
 * debugger loads over System Bus Access.
 *
 * Keep this tiny: the ROM is 256 words and is baked into the bitstream.
 */
    .section .text.init
    .globl _start
_start:
    li   t0, 0x40000000
    jr   t0
