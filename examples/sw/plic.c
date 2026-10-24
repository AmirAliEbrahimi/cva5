/* PLIC check: does a device interrupt reach the core, and does the PLIC's
 * filtering actually filter?
 *
 * Polled, not interrupt driven. Taking a real external interrupt needs
 * mstatus.MIE, mie.MEIE and a handler that claims and completes, and trap.S
 * parks by design -- so this reads mip instead, the same way timer.c reads it
 * for mtip.
 *
 * The one source wired today is the UART's receive interrupt, !rx_fifo_empty:
 * level sensitive, asserted until software reads the byte. Nothing in software
 * can raise it, so this test needs one keypress on the serial console. It then
 * does all of its filtering checks against that one asserted source, which is
 * the only way they mean anything: with nothing pending, "priority 0 does not
 * interrupt" and "the threshold suppresses it" pass whether or not the
 * hardware works. The first version of this test checked them before the
 * keypress, so they proved nothing, and it waited for the key with a loop
 * bound meant for bus latency -- about a millisecond -- so it never got that
 * far anyway.
 *
 * Order:
 *   1. the register file answers over the bus at the standard offsets, and
 *      source 0's enable bit stays low;
 *   2. one keypress -> the UART's irq -> PLIC pending -> mip.MEIP;
 *   3. a threshold above the source's priority holds MEIP down, and lowering
 *      it brings MEIP back, with the source pending throughout;
 *   4. priority 0 holds MEIP down the same way, whatever the threshold;
 *   5. claim names the UART and suppresses it while in progress;
 *   6. reading the byte and then completing leaves the core quiet -- in that
 *      order, because completing a level source that is still asserted
 *      re-raises it immediately.
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

#define UART_SRC_BIT (1u << PLIC_SRC_UART)
#define MIP_MEIP     (1u << 11)

static inline unsigned int read_mip(void) {
    unsigned int v;
    __asm__ volatile (".option push\n"
                      ".option arch, +zicsr\n"
                      "csrr %0, mip\n"
                      ".option pop"
                      : "=r" (v));
    return v;
}

/* Waits on the bus, in microseconds. A store to a peripheral is posted, so mip
 * can be read before the write has crossed the crossbar, and mip's bits are a
 * registered copy of the pins on top of that -- so poll, with a bound. This is
 * not the bound to use when waiting on a person; see the keypress below. */
#define MIP_POLL_LIMIT 100000u

static int mip_wait(unsigned int mask, int want_set) {
    for (unsigned int i = 0; i < MIP_POLL_LIMIT; i++)
        if (!!(read_mip() & mask) == !!want_set)
            return (int)i;
    return -1;
}

/* mtime, for waits measured in real time. One tick is one microsecond; the low
 * half wraps, so retry while the high half is moving. */
static unsigned long long mtime_read(void) {
    volatile unsigned int *lo =
        (volatile unsigned int *)(CLINT_BASE + CLINT_MTIME_OFF);
    volatile unsigned int *hi =
        (volatile unsigned int *)(CLINT_BASE + CLINT_MTIME_OFF + 4);
    unsigned int h, l, h2;
    do {
        h = *hi;
        l = *lo;
        h2 = *hi;
    } while (h != h2);
    return ((unsigned long long)h << 32) | l;
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

/* Register dumps read better in hex, and a zero has to show up as a zero
 * rather than as nothing at all. */
static void put_hex(const char *label, unsigned int v) {
    static const char digits[] = "0123456789abcdef";
    char buf[32];
    unsigned n = 0;

    while (*label && n < sizeof(buf) - 11)
        buf[n++] = *label++;
    buf[n++] = '0';
    buf[n++] = 'x';
    for (int i = 0; i < 8; i++)
        buf[n++] = digits[(v >> (28 - 4 * i)) & 0xFu];
    buf[n] = '\0';
    puts(buf);
}

int main(void) {
    puts("PLIC check");

    /* --- a known state. Like the CLINT, the PLIC resets from rstn alone and
     * never from ndmreset, so a previous run's settings are still here. */
    PLIC_THRESHOLD = 0u;
    PLIC_ENABLE = 0u;
    PLIC_PRIORITY(PLIC_SRC_UART) = 0u;

    /* Drain whatever the UART already holds, so its irq starts low. */
    while (UART_STAT & UART_RX_VALID)
        (void)UART_RX;

    if (mip_wait(MIP_MEIP, 0) < 0) {
        put_hex("FAIL: meip stuck high with nothing enabled; pending ",
                PLIC_PENDING);
        for (;;) ;
    }

    /* --- 1. the register file */
    PLIC_PRIORITY(PLIC_SRC_UART) = 7u;
    check("priority reads back", PLIC_PRIORITY(PLIC_SRC_UART) == 7u);

    PLIC_THRESHOLD = 5u;
    check("threshold reads back", PLIC_THRESHOLD == 5u);
    PLIC_THRESHOLD = 0u;

    PLIC_ENABLE = 0xFFFFFFFFu;
    check("enable sets the UART's bit", (PLIC_ENABLE & UART_SRC_BIT) != 0u);
    check("and leaves source 0 pinned low", (PLIC_ENABLE & 1u) == 0u);

    PLIC_PRIORITY(PLIC_SRC_UART) = 3u;

    /* --- 2. one keypress.
     *
     * Timed with mtime rather than a loop count, so the deadline is in real
     * seconds whatever the core is doing. On timeout the dump separates the
     * three ways this can fail:
     *
     *   rx_valid 0, pending 0  no byte arrived: no terminal open, wrong port,
     *                          or the PMOD jumpers are off
     *   rx_valid 1, pending 0  the UART has it, the PLIC does not: the irq net
     *                          in the block design, or the source number
     *   pending 1, meip 0      the PLIC has it, the core does not: eip into
     *                          cva5_top, or enable/priority/threshold
     */
    puts("");
    puts("press a key on this console (waiting 30s)...");

    unsigned long long deadline = mtime_read() + 30ull * CLINT_HZ;
    int saw_meip = 0;

    while (mtime_read() < deadline) {
        if (read_mip() & MIP_MEIP) {
            saw_meip = 1;
            break;
        }
    }

    if (!saw_meip) {
        puts("FAIL: no external interrupt within 30s");
        put_hex("  uart status:   ", UART_STAT);
        put_hex("  plic pending:  ", PLIC_PENDING);
        put_hex("  plic enable:   ", PLIC_ENABLE);
        put_hex("  plic priority: ", PLIC_PRIORITY(PLIC_SRC_UART));
        put_hex("  plic threshold:", PLIC_THRESHOLD);
        put_hex("  mip:           ", read_mip());
        for (;;) ;
    }

    check("a keypress reaches mip.MEIP", 1);
    check("the UART has the byte", (UART_STAT & UART_RX_VALID) != 0u);
    check("and the PLIC has it pending", (PLIC_PENDING & UART_SRC_BIT) != 0u);

    /* --- 3. the threshold, against a source that really is pending */
    PLIC_THRESHOLD = 7u;              /* above the source's priority of 3 */
    check("a threshold above the priority holds meip down",
          mip_wait(MIP_MEIP, 0) >= 0);
    check("while the source stays pending underneath",
          (PLIC_PENDING & UART_SRC_BIT) != 0u);
    check("and a claim reads 0 while suppressed", PLIC_CLAIM == 0u);

    PLIC_THRESHOLD = 0u;
    check("lowering the threshold brings meip back",
          mip_wait(MIP_MEIP, 1) >= 0);

    /* --- 4. priority 0 never interrupts */
    PLIC_PRIORITY(PLIC_SRC_UART) = 0u;
    check("priority 0 holds meip down", mip_wait(MIP_MEIP, 0) >= 0);
    PLIC_PRIORITY(PLIC_SRC_UART) = 3u;
    check("and restoring the priority brings it back",
          mip_wait(MIP_MEIP, 1) >= 0);

    /* --- 5. claim */
    unsigned int id = PLIC_CLAIM;
    check("claim names the UART", id == PLIC_SRC_UART);
    check("claiming suppresses it while in progress",
          mip_wait(MIP_MEIP, 0) >= 0);

    /* --- 6. quiet the device, THEN complete. The other order re-raises the
     * interrupt immediately, because the irq is level sensitive and the byte
     * is still in the FIFO -- correct hardware behaviour, and the thing most
     * likely to look like a stuck interrupt in a handler. */
    put_hex("byte received: ", UART_RX);
    check("reading the byte clears rx_valid",
          (UART_STAT & UART_RX_VALID) == 0u);

    PLIC_CLAIM = id;                  /* complete */
    check("completing a quiet source leaves meip down",
          mip_wait(MIP_MEIP, 0) >= 0);
    check("and nothing is pending", (PLIC_PENDING & UART_SRC_BIT) == 0u);

    PLIC_ENABLE = 0u;
    puts(fails ? "plic: FAIL" : "plic: PASS");
    for (;;) ;
}
