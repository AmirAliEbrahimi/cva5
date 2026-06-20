/* Startup for the CVA5 verilator sim.
 * After main() returns we execute 0x00a00013 (addi x0,x0,10), the
 * "success termination" NOP the testbench watches for to end the run
 * and flush the log. */
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
