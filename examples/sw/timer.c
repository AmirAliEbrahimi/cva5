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

/* Every check below reads mip after storing to the CLINT, and that store is
 * posted: it retires when the store queue accepts it, not when the write has
 * crossed the crossbar. CSR instructions issue once they are the oldest
 * instruction, which the store already is, so `csrr mip` can run several
 * cycles ahead of the CLINT seeing the value -- and csr_unit.sv needs one
 * cycle more, because mip's bits are a registered copy of the pins
 * (csr_unit.sv:518-520). So nothing here reads mip once and concludes; it
 * polls until mip agrees or a bound runs out.
 *
 * Returns the number of polls it took, or -1 if the bound ran out. The count
 * is worth printing: it is the write latency through the crossbar, and it is
 * what made the single-read version of this test pass or fail by luck. */
#define MIP_POLL_LIMIT 100000u

static int mip_wait(unsigned int mask, int want_set) {
    for (unsigned int i = 0; i < MIP_POLL_LIMIT; i++)
        if (!!(read_mip() & mask) == !!want_set)
            return (int)i;
    return -1;
}

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

    /* --- a known state first.
     *
     * The CLINT is reset by rstn alone and never by ndmreset, deliberately: a
     * peripheral the debugger can reach must not be held in reset while the
     * debugger talks to the system bus. The consequence for software is that
     * `make timer` does not give you a fresh CLINT. The previous run's
     * mtimecmp is still armed, by now in the past, so mtip is already set when
     * this program starts, and its msip may still be set too. Disarm both and
     * wait for mip to follow before anything else is measured. */
    MTIMECMP_HI = 0xFFFFFFFFu;
    MTIMECMP_LO = 0xFFFFFFFFu;
    MSIP = 0u;
    if (mip_wait(MIP_MTIP | MIP_MSIP, 0) < 0) {
        puts("FAIL: mtip/msip still set after disarming the CLINT; mip:");
        put_uint(read_mip());
        for (;;) ;
    }

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

    /* --- does mtimecmp set mtip? Arm it one millisecond out.
     *
     * mtimecmp is disarmed and mtip is clear, both established above. Writing
     * the high half first keeps it that way throughout: every state the two
     * stores can be observed in -- 0xFFFFFFFF_FFFFFFFF, then
     * 0x00000000_FFFFFFFF, then the real value -- is still in the future, so
     * mtip cannot fire early. That is why the read below can be a single read
     * where the others cannot. */
    t0 = mtime_read() + 1000u;          /* 1000 ticks = 1 ms */
    MTIMECMP_HI = (unsigned int)(t0 >> 32);
    MTIMECMP_LO = (unsigned int)t0;

    if (read_mip() & MIP_MTIP) {
        puts("FAIL: mtip set before mtimecmp was reached");
        for (;;) ;
    }

    if (mip_wait(MIP_MTIP, 1) < 0) {
        puts("FAIL: mtip never set after mtimecmp passed; mip:");
        put_uint(read_mip());
        for (;;) ;
    }
    t1 = mtime_read();

    puts("mtip set, mtime - mtimecmp at that point:");
    put_uint(t1 - t0);

    /* --- and msip, a plain register the core sees as an interrupt.
     *
     * On failure, which half failed matters, so the register is read back. By
     * then the store is long gone from the store queue, so that read is a real
     * bus read rather than one forwarded out of the queue:
     *
     *   msip reads back 0  ->  the write never reached the CLINT: the bus
     *   msip reads back 1  ->  the CLINT has it and mip never saw it: the
     *                          msip net out of cva5_clint_axi, or the latch
     */
    MSIP = 1u;
    int polls = mip_wait(MIP_MSIP, 1);
    if (polls < 0) {
        puts("FAIL: msip did not reach mip; msip reads back:");
        put_uint(MSIP);
        for (;;) ;
    }
    puts("msip reached mip, polls:");
    put_uint((unsigned int)polls);

    MSIP = 0u;
    if (mip_wait(MIP_MSIP, 0) < 0) {
        puts("FAIL: msip did not clear; msip reads back:");
        put_uint(MSIP);
        for (;;) ;
    }

    /* Leave the CLINT disarmed, so the next run starts clean even without the
     * preamble above -- nothing else resets it. */
    MTIMECMP_HI = 0xFFFFFFFFu;
    MTIMECMP_LO = 0xFFFFFFFFu;

    puts("PASS clint");
    for (;;) ;
}
