/* CLINT check: does mtime tick once per microsecond, and does mtimecmp set
 * mtip?
 *
 * Polled, not interrupt driven. Taking a real timer interrupt needs mstatus.MIE
 * and mie.MTIE set and a handler that does something other than park, and
 * trap.S parks -- so this reads mip instead. Enabling interrupts is the step
 * after the PLIC, when there is a handler worth jumping to.
 *
 * The number that matters is the first one printed. mtime is prescaled in
 * hardware so that one tick is one microsecond (see
 * examples/xilinx/vendor/cva5_clint.sv); if the prescaler or the core clock
 * disagree, the measured microseconds per 1000 iterations will be wrong by
 * exactly that ratio.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include "soc.h"

#define MTIME_LO   (*(volatile unsigned int *)(CLINT_BASE + CLINT_MTIME_OFF))
#define MTIME_HI   (*(volatile unsigned int *)(CLINT_BASE + CLINT_MTIME_OFF + 4))
#define MTIMECMP_LO (*(volatile unsigned int *)(CLINT_BASE + CLINT_MTIMECMP_OFF))
#define MTIMECMP_HI (*(volatile unsigned int *)(CLINT_BASE + CLINT_MTIMECMP_OFF + 4))
#define MSIP       (*(volatile unsigned int *)(CLINT_BASE + CLINT_MSIP_OFF))

/* mip, read with Zicsr enabled just for this instruction -- the Makefile's
 * -march is rv32im and has not implied Zicsr since the extension was split
 * out of the base ISA. The same trick trap.S uses. */
static inline unsigned int read_mip(void) {
    unsigned int v;
    __asm__ volatile (".option push\n"
                      ".option arch, +zicsr\n"
                      "csrr %0, mip\n"
                      ".option pop"
                      : "=r" (v));
    return v;
}

#define MIP_MTIP (1u << 7)
#define MIP_MSIP (1u << 3)

/* 64-bit mtime read. mtime is two 32-bit registers, so the low half can wrap
 * between the two reads; retry until the high half is stable. */
static unsigned long long mtime_read(void) {
    unsigned int hi, lo, hi2;
    do {
        hi = MTIME_HI;
        lo = MTIME_LO;
        hi2 = MTIME_HI;
    } while (hi != hi2);
    return ((unsigned long long)hi << 32) | lo;
}

static void put_uint(unsigned long long v) {
    char buf[21];
    int i = 20;
    buf[20] = '\0';
    if (v == 0) { buf[--i] = '0'; }
    while (v) { buf[--i] = (char)('0' + (v % 10)); v /= 10; }
    puts(&buf[i]);
}

int main(void) {
    volatile unsigned int spin = 0;
    unsigned long long t0, t1;

    puts("CLINT check");

    /* --- is it counting at all? */
    t0 = mtime_read();
    for (unsigned int i = 0; i < 100000u; i++) spin++;
    t1 = mtime_read();

    if (t1 == t0) {
        puts("FAIL: mtime did not advance");
        for (;;) ;
    }

    puts("elapsed us for 100000 iterations:");
    put_uint(t1 - t0);

    /* --- does mtimecmp set mtip? Arm it one millisecond out. */
    MTIMECMP_HI = 0xFFFFFFFFu;          /* park it high while writing the low half */
    MTIMECMP_LO = 0xFFFFFFFFu;
    if (read_mip() & MIP_MTIP) {
        puts("FAIL: mtip set with mtimecmp at its maximum");
        for (;;) ;
    }

    t0 = mtime_read() + 1000u;          /* 1000 ticks = 1 ms */
    MTIMECMP_HI = (unsigned int)(t0 >> 32);
    MTIMECMP_LO = (unsigned int)t0;

    if (read_mip() & MIP_MTIP) {
        puts("FAIL: mtip set before mtimecmp was reached");
        for (;;) ;
    }

    while (!(read_mip() & MIP_MTIP)) ;
    t1 = mtime_read();

    puts("mtip set, mtime - mtimecmp at that point:");
    put_uint(t1 - t0);

    /* --- and msip, which is a plain register the core sees as an interrupt */
    MSIP = 1u;
    if (!(read_mip() & MIP_MSIP)) {
        puts("FAIL: msip did not reach mip");
        for (;;) ;
    }
    MSIP = 0u;
    if (read_mip() & MIP_MSIP) {
        puts("FAIL: msip did not clear");
        for (;;) ;
    }

    puts("PASS clint");
    for (;;) ;
}
