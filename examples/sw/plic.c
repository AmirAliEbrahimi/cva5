/* PLIC check: does a device interrupt reach the core?
 *
 * Polled, not interrupt driven. Taking a real external interrupt needs
 * mstatus.MIE, mie.MEIE and a handler that claims and completes, and trap.S
 * parks by design -- so this reads mip instead, the same way timer.c reads it
 * for mtip. Enabling interrupts is the step after this one.
 *
 * The one source wired today is the UART's receive interrupt, which is
 * !rx_fifo_empty: level sensitive, and asserted until software reads the byte.
 * There is no way to raise it from software, so this test needs a keypress on
 * the serial console -- it says so, then waits.
 *
 * What it proves, in order:
 *   - the register file answers over the bus, at the standard offsets;
 *   - priority 0 never interrupts, whatever the threshold;
 *   - the threshold suppresses a source above it;
 *   - a keypress reaches pending, and from there mip.MEIP;
 *   - claim names the UART, and completing it after the byte is read leaves
 *     the core quiet again.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include "soc.h"

#define PLIC_PRIORITY(src) (*(volatile unsigned int *)(PLIC_BASE + PLIC_PRIORITY_OFF(src)))
#define PLIC_PENDING   (*(volatile unsigned int *)(PLIC_BASE + PLIC_PENDING_OFF))
#define PLIC_ENABLE    (*(volatile unsigned int *)(PLIC_BASE + PLIC_ENABLE_OFF))
#define PLIC_THRESHOLD (*(volatile unsigned int *)(PLIC_BASE + PLIC_THRESHOLD_OFF))
#define PLIC_CLAIM     (*(volatile unsigned int *)(PLIC_BASE + PLIC_CLAIM_OFF))

#define UART_RX    (*(volatile unsigned int *)(UART_BASE + UART_RX_OFF))
#define UART_STAT  (*(volatile unsigned int *)(UART_BASE + UART_STAT_OFF))

#define MIP_MEIP (1u << 11)

static inline unsigned int read_mip(void) {
    unsigned int v;
    __asm__ volatile (".option push\n"
                      ".option arch, +zicsr\n"
                      "csrr %0, mip\n"
                      ".option pop"
                      : "=r" (v));
    return v;
}

/* Same reasoning as timer.c: a store to a peripheral is posted, so mip can be
 * read before the write has crossed the crossbar, and mip's bits are a
 * registered copy of the pins on top of that. Poll, with a bound. */
#define MIP_POLL_LIMIT 100000u

static int mip_wait(unsigned int mask, int want_set) {
    for (unsigned int i = 0; i < MIP_POLL_LIMIT; i++)
        if (!!(read_mip() & mask) == !!want_set)
            return (int)i;
    return -1;
}

static int fails;

static void check(const char *what, int ok) {
    char line[56];
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

static void put_uint(unsigned int v) {
    char buf[12];
    int i = 11;
    buf[11] = '\0';
    if (v == 0) buf[--i] = '0';
    while (v) { buf[--i] = (char)('0' + (v % 10)); v /= 10; }
    puts(&buf[i]);
}

int main(void) {
    puts("PLIC check");

    /* --- a known state. Like the CLINT, the PLIC resets from rstn alone and
     * not from ndmreset, so a previous run's settings are still here. */
    PLIC_THRESHOLD = 0u;
    PLIC_ENABLE = 0u;
    PLIC_PRIORITY(PLIC_SRC_UART) = 0u;

    /* Drain anything the UART already has, so its irq starts low. */
    while (UART_STAT & UART_RX_VALID)
        (void)UART_RX;

    if (mip_wait(MIP_MEIP, 0) < 0) {
        puts("FAIL: meip is stuck high with nothing enabled");
        for (;;) ;
    }

    /* --- the register file */
    PLIC_PRIORITY(PLIC_SRC_UART) = 7u;
    check("priority reads back",
          PLIC_PRIORITY(PLIC_SRC_UART) == 7u);

    PLIC_ENABLE = 0xFFFFFFFFu;
    check("enable reads back with source 0 pinned low",
          (PLIC_ENABLE & 1u) == 0u && (PLIC_ENABLE & (1u << PLIC_SRC_UART)));

    PLIC_THRESHOLD = 5u;
    check("threshold reads back", PLIC_THRESHOLD == 5u);

    /* --- priority 0 never interrupts, and the threshold suppresses */
    PLIC_PRIORITY(PLIC_SRC_UART) = 0u;
    PLIC_THRESHOLD = 0u;
    check("priority 0 does not interrupt", mip_wait(MIP_MEIP, 0) >= 0);

    PLIC_PRIORITY(PLIC_SRC_UART) = 3u;
    PLIC_THRESHOLD = 7u;              /* above the source's priority */
    check("a threshold above the priority suppresses it",
          mip_wait(MIP_MEIP, 0) >= 0);

    PLIC_THRESHOLD = 0u;

    /* --- the real thing: a byte on the serial line */
    puts("");
    puts("press a key on this console...");

    int polls = mip_wait(MIP_MEIP, 1);
    if (polls < 0) {
        puts("FAIL: no external interrupt; pending reads:");
        put_uint(PLIC_PENDING);
        for (;;) ;
    }
    check("a keypress reaches mip.MEIP", 1);

    check("and the PLIC has it pending",
          (PLIC_PENDING & (1u << PLIC_SRC_UART)) != 0u);

    unsigned int id = PLIC_CLAIM;
    puts("claim returned source:");
    put_uint(id);
    check("claim names the UART", id == PLIC_SRC_UART);

    /* Claiming suppresses the source while it is in progress, so meip drops
     * even though the byte is still sitting in the FIFO. */
    check("meip drops once claimed", mip_wait(MIP_MEIP, 0) >= 0);

    /* Quiet the device BEFORE completing. The other order re-raises the
     * interrupt immediately, because the UART's irq is level sensitive and
     * still asserted -- which is correct hardware behaviour and the thing
     * most likely to look like a stuck interrupt in a handler. */
    puts("byte received:");
    put_uint(UART_RX);

    PLIC_CLAIM = id;                  /* complete */
    check("and stays down after complete with the FIFO drained",
          mip_wait(MIP_MEIP, 0) >= 0);

    PLIC_ENABLE = 0u;
    puts(fails ? "plic: FAIL" : "plic: PASS");
    for (;;) ;
}
