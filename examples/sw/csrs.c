/* Counter CSR check: which of Zicntr's three registers this core implements.
 *
 * cycle and instret are counted inside the core, so they work. time/timeh are
 * not: the count belongs to the CLINT, which publishes it on the bus at
 * CLINT_BASE + 0xBFF8, and feeding those 64 bits back into the core to serve
 * one CSR is the thing this configuration refuses to spend wires on. So
 * INCLUDE_TIME_CSR is clear and a read of time raises an illegal instruction,
 * which is what CVA6 does (no CSR_TIME case at all) and what lowRISC
 * documents for Ibex ("any access to these registers will trap").
 *
 * This test proves all three statements rather than asserting them, because a
 * CSR that silently reads zero and a CSR that traps look identical until
 * something depends on the difference.
 *
 * It installs its own mtvec while it runs. trap.S's handler parks on purpose
 * -- it is there to be read by a debugger, not returned from -- so a test that
 * expects a trap has to bring a handler that skips the faulting instruction
 * and returns. mtvec is restored before the test ends.
 *
 * NOTE: this one fails under QEMU on purpose. QEMU's virt machine implements
 * the time CSR, so rdtime succeeds there and the third check reports FAIL.
 * That is the one place where the board and tools/cva5-qemu diverge, and it is
 * recorded here rather than papered over.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include "soc.h"

#define MCAUSE_ILLEGAL 2u

volatile unsigned int trap_count;
volatile unsigned int trap_cause;

/* Skip the faulting instruction and come back. Saves what it uses: the code
 * around the faulting instruction has live registers and no reason to expect
 * a handler to have run at all.
 *
 * All CSR instructions here need Zicsr, which -march=rv32im has not implied
 * since the extension was split out of the base ISA -- the same .option
 * dance trap.S and timer.c use. */
__attribute__((naked, aligned(4))) static void csr_trap(void) {
    __asm__ volatile (
        ".option push\n"
        ".option arch, +zicsr\n"
        "addi sp, sp, -16\n"
        "sw   t0, 0(sp)\n"
        "sw   t1, 4(sp)\n"
        "csrr t0, mcause\n"
        "la   t1, trap_cause\n"
        "sw   t0, 0(t1)\n"
        "la   t1, trap_count\n"
        "lw   t0, 0(t1)\n"
        "addi t0, t0, 1\n"
        "sw   t0, 0(t1)\n"
        "csrr t0, mepc\n"
        "addi t0, t0, 4\n"          /* every CSR instruction here is 4 bytes */
        "csrw mepc, t0\n"
        "lw   t0, 0(sp)\n"
        "lw   t1, 4(sp)\n"
        "addi sp, sp, 16\n"
        "mret\n"
        ".option pop");
}

#define CSR_READ(name)                                  \
    ({                                                  \
        unsigned int _v;                                \
        __asm__ volatile (".option push\n"              \
                          ".option arch, +zicsr\n"      \
                          "csrr %0, " name "\n"         \
                          ".option pop"                 \
                          : "=r" (_v));                 \
        _v;                                             \
    })

#define CSR_WRITE(name, val)                            \
    do {                                                \
        unsigned int _v = (val);                        \
        __asm__ volatile (".option push\n"              \
                          ".option arch, +zicsr\n"      \
                          "csrw " name ", %0\n"         \
                          ".option pop"                 \
                          :: "r" (_v));                 \
    } while (0)

/* Did reading this CSR trap? Returns 1 if it did. */
#define TRAPPED(name)                                   \
    ({                                                  \
        unsigned int _before = trap_count;              \
        (void)CSR_READ(name);                           \
        trap_count != _before;                          \
    })

static int fails;

/* One line per check. puts() appends the newline itself, so the verdict and
 * the label have to be one string. */
static void check(const char *what, int ok) {
    char line[48];
    const char *tag = ok ? "PASS " : "FAIL ";
    unsigned n = 0;

    while (*tag)
        line[n++] = *tag++;
    while (*what && n < sizeof(line) - 1)
        line[n++] = *what++;
    line[n] = '\0';

    puts(line);
    if (!ok)
        fails++;
}

int main(void) {
    unsigned int mtvec_save = CSR_READ("mtvec");

    CSR_WRITE("mtvec", (unsigned int)(void *)csr_trap);  /* direct mode */

    /* --- Zicntr's two local counters work, and advance. */
    unsigned int c0 = CSR_READ("cycle");
    unsigned int i0 = CSR_READ("instret");
    for (volatile int i = 0; i < 100; i++)
        ;
    unsigned int c1 = CSR_READ("cycle");
    unsigned int i1 = CSR_READ("instret");

    check("rdcycle readable", trap_count == 0);
    check("rdcycle advances", c1 > c0);
    check("rdinstret advances", i1 > i0);

    /* --- and their machine-mode counterparts, which this core runs in. */
    trap_count = 0;
    unsigned int m0 = CSR_READ("mcycle");
    for (volatile int i = 0; i < 100; i++)
        ;
    unsigned int m1 = CSR_READ("mcycle");
    check("mcycle readable and advancing", trap_count == 0 && m1 > m0);

    /* --- time is not implemented, so reading it must trap, not read zero. */
    trap_count = 0;
    trap_cause = 0;
    int trapped = TRAPPED("time");
    check("rdtime traps", trapped);
    check("...as an illegal instruction", trap_cause == MCAUSE_ILLEGAL);

    trap_count = 0;
    trap_cause = 0;
    trapped = TRAPPED("timeh");
    check("rdtimeh traps", trapped && trap_cause == MCAUSE_ILLEGAL);

    /* --- and the count is still available, from the CLINT over the bus.
     *
     * Board only. The Verilator testbench is a different SoC -- 4 KB of
     * memory, no debug module, no CLINT -- so this one would be testing
     * nothing there. The CSR checks above are the part that is about the core
     * and they run in both places, which is what makes the sim useful for
     * this: it can be built with INCLUDE_TIME_CSR either way. */
#ifndef CVA5_SIM
    volatile unsigned int *mtime_lo =
        (volatile unsigned int *)(CLINT_BASE + CLINT_MTIME_OFF);
    unsigned int t0 = *mtime_lo;
    for (volatile int i = 0; i < 20000; i++)
        ;
    unsigned int t1 = *mtime_lo;
    check("the CLINT's mtime advances instead", t1 != t0);
#endif

    CSR_WRITE("mtvec", mtvec_save);

    puts(fails ? "csrs: FAIL" : "csrs: PASS");

    /* The sim terminates when main returns (crt0.S's addi x0,x0,10); on the
     * board there is nowhere to return to, so park and leave the registers
     * where a debugger can read them. */
#ifdef CVA5_SIM
    return fails;
#else
    for (;;)
        ;
#endif
}
