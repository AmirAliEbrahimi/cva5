/* The trap handler, in its own file because two images need it.
 *
 * Nothing in these examples writes mtvec, so the core's RESET_TVEC is the trap
 * vector for the whole life of the program -- and with the Debug Module at
 * 0x0000_0000 it cannot be left at its reset value of zero, or every trap
 * would jump into the debug ROM and execute whatever was there. RESET_TVEC
 * therefore points at the base of RAM, and this has to be the first thing in
 * the image.
 *
 * fpga_link.ld places .trap at ORIGIN(RAM), pads it to 0x40 so _start lands
 * just above, and asserts both addresses. That assert is why this is a
 * separate file rather than part of crt0.S: the preload image (idle.S) does
 * not link crt0.S, so a handler defined there would leave trap_entry
 * undefined and break `make ram`.
 *
 * The sim's link.ld places .trap after the code instead -- upstream's
 * EXAMPLE_CONFIG has RESET_VEC at 0x8000_0000 and RESET_TVEC at zero, and this
 * fork does not modify cva5_config.sv -- so there this is 16 unreachable bytes
 * and the sim's trap behaviour is unchanged.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

    .section .trap, "ax"
    /* csrr needs Zicsr, which -march=rv32im has not implied since the
     * extension was split out of the base ISA. Enabled here rather than in
     * the Makefile's ARCH so it reaches only this handler; the core does
     * implement the CSRs (INCLUDE_UNIT.CSR and INCLUDE_ZICNTR are both set). */
    .option push
    .option arch, +zicsr
    .globl trap_entry
trap_entry:
    /* Park, with the cause where a debugger can read it:
     *   t0 = mcause   why
     *   t1 = mepc     the instruction that did it
     *   t2 = mtval    the address or instruction word involved
     *
     * Deliberately no printing. A trap can arrive with a broken stack or
     * before the UART is usable, and a handler that faults while reporting a
     * fault tells you nothing. `make load`'s OpenOCD can read these three
     * registers, which is enough to name any trap this design can take.
     */
    csrr t0, mcause
    csrr t1, mepc
    csrr t2, mtval
1:  j    1b
    .option pop
