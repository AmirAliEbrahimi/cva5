/* Reading mip, and why every check here polls it.
 *
 * Shared by timer.c, plic.c and spi.c, which had three copies of this between
 * them.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef CVA5_MIP_H
#define CVA5_MIP_H

/* mip, read with Zicsr enabled just for this instruction -- the Makefile's
 * -march is rv32im and has not implied Zicsr since the extension was split out
 * of the base ISA. The same trick trap.S uses. */
static inline unsigned int read_mip(void) {
    unsigned int v;
    __asm__ volatile (".option push\n"
                      ".option arch, +zicsr\n"
                      "csrr %0, mip\n"
                      ".option pop"
                      : "=r" (v));
    return v;
}

/* The three interrupts a RISC-V hart gets, and all three are wired on this
 * board: MSIP and MTIP straight from the CLINT, MEIP from the PLIC. */
#define MIP_MSIP (1u << 3)
#define MIP_MTIP (1u << 7)
#define MIP_MEIP (1u << 11)

/* Every check that stores to a peripheral and then reads mip is racing that
 * store: it is posted, so it retires when the store queue accepts it, not when
 * the write has crossed the crossbar. CSR instructions issue once they are the
 * oldest instruction, which the store already is, so `csrr mip` can run
 * several cycles ahead of the device seeing the value -- and csr_unit.sv needs
 * one cycle more, because mip's bits are a registered copy of the pins
 * (csr_unit.sv:518-520). So nothing reads mip once and concludes; it polls
 * until mip agrees or a bound runs out.
 *
 * Returns the number of polls it took, or -1 if the bound ran out. The count
 * is worth printing: it is the write latency through the crossbar, and it is
 * what made the single-read version of these tests pass or fail by luck.
 *
 * This is the bound for waiting on the bus, not on a person. A test that waits
 * for a keypress measures the deadline with mtime instead; see plic.c. */
#define MIP_POLL_LIMIT 100000u

static inline int mip_wait(unsigned int mask, int want_set) {
    for (unsigned int i = 0; i < MIP_POLL_LIMIT; i++)
        if (!!(read_mip() & mask) == !!want_set)
            return (int)i;
    return -1;
}

#endif
