/* Startup for the CVA5 examples.
 *
 * After main() returns we execute 0x00a00013 (addi x0,x0,10), the
 * "success termination" NOP the Verilator testbench watches for to end the run
 * and flush the log.
 *
 * On the board _start sits at RAM_BASE + 0x40, because the first 0x40 bytes
 * hold the trap handler -- see trap.S, which every image links, and
 * fpga_link.ld, which places both and asserts their addresses.
 */

    .section .text.init
    .globl _start
_start:
    la   sp, _stack_top
    la   t0, __bss_start
    la   t1, __bss_end
1:  bgeu t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b
2:  call main
    addi x0, x0, 10        /* 0x00a00013 : success, terminate */
3:  j    3b
