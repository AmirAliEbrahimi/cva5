/* PLIC check: does a device interrupt reach the core, and does the PLIC's
 * filtering actually filter?
 *
 * Polled, not interrupt driven. Taking a real external interrupt needs
 * mstatus.MIE, mie.MEIE and a handler that claims and completes, and trap.S
 * parks by design -- so this reads mip instead, the same way timer.c reads it
 * for mtip.
 *
 * Two sources are wired: the UART's receive interrupt and the SPI's end of
 * transfer. This test is about the UART's, because !rx_fifo_empty is level
 * sensitive and asserted until software reads the byte, which is the harder
 * case and the one whose complete-ordering trap is worth pinning down. The
 * SPI's source is checked in spi.c, where there is a transfer to raise it.
 *
 * Nothing in software can raise the UART's, so this test needs one keypress on
 * the serial console. It then
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
#include "mip.h"

#define PLIC_PRIORITY(src) (*(volatile unsigned int *)(PLIC_BASE + PLIC_PRIORITY_OFF(src)))
#define PLIC_PENDING   (*(volatile unsigned int *)(PLIC_BASE + PLIC_PENDING_OFF))
#define PLIC_ENABLE    (*(volatile unsigned int *)(PLIC_BASE + PLIC_ENABLE_OFF))
#define PLIC_THRESHOLD (*(volatile unsigned int *)(PLIC_BASE + PLIC_THRESHOLD_OFF))
#define PLIC_CLAIM     (*(volatile unsigned int *)(PLIC_BASE + PLIC_CLAIM_OFF))

#define UART_RX    (*(volatile unsigned int *)(UART_BASE + UART_RX_OFF))
#define UART_STAT  (*(volatile unsigned int *)(UART_BASE + UART_STAT_OFF))
#define UART_CTRL  (*(volatile unsigned int *)(UART_BASE + UART_CTRL_OFF))

#define UART_SRC_BIT (1u << PLIC_SRC_UART)

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
    putstr(ok ? "PASS " : "FAIL ");
    puts(what);
    if (!ok)
        fails++;
}

/* Register dumps read better in hex, and a zero has to show up as a zero
 * rather than as nothing at all. */
static void put_hex(const char *label, unsigned int v) {
    static const char digits[] = "0123456789abcdef";
    char buf[11];
    unsigned n = 0;

    /* Only the value is buffered. The label goes straight out, so there is no
     * length to get wrong -- the fixed buffer this replaced truncated a long
     * one into the middle of the number. */
    buf[n++] = '0';
    buf[n++] = 'x';
    for (int i = 0; i < 8; i++)
        buf[n++] = digits[(v >> (28 - 4 * i)) & 0xFu];
    buf[n] = '\0';
    putstr(label);
    puts(buf);
}

int main(void) {
    puts("PLIC check");

    /* --- a known state. Like the CLINT, the PLIC resets from rstn alone and
     * never from ndmreset, so a previous run's settings are still here: the
     * enables, the priorities, and the pending bits. Pending matters most now
     * that the SPI is source 2 -- `make -C examples/sw spi` leaves its
     * end-of-transfer interrupt latched, and this test would then see MEIP
     * before any key was pressed and fail on a byte the UART never had. */
    PLIC_THRESHOLD = 0u;
    PLIC_ENABLE = 0u;
    for (unsigned s = 1u; s <= PLIC_NUM_SOURCES; s++)
        PLIC_PRIORITY(s) = 0u;

    /* Drain whatever the UART already holds, so its irq starts low. Before the
     * claims below, so a level source that is still asserted cannot come
     * straight back. */
    while (UART_STAT & UART_RX_VALID)
        (void)UART_RX;

    /* Claim and complete anything already latched. A claim only returns an
     * enabled source whose priority is above the threshold, so everything is
     * opened up for the duration and shut again after. */
    PLIC_ENABLE = 0xFFFFFFFFu;
    for (unsigned s = 1u; s <= PLIC_NUM_SOURCES; s++)
        PLIC_PRIORITY(s) = 1u;
    /* The claim is a read of a different register from the writes above, so
     * without this it can be issued before they land -- and a claim taken with
     * the priorities still at 0 returns 0 and drains nothing. See soc.h. */
    dev_fence();
    for (unsigned i = 0; i < PLIC_NUM_SOURCES + 1u; i++) {
        unsigned int stale = PLIC_CLAIM;
        if (!stale)
            break;
        put_hex("draining a source left pending by an earlier run: ", stale);
        PLIC_CLAIM = stale;
        dev_fence();          /* complete, before the next claim */
    }
    PLIC_ENABLE = 0u;
    for (unsigned s = 1u; s <= PLIC_NUM_SOURCES; s++)
        PLIC_PRIORITY(s) = 0u;

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

    /* The register check wanted every bit; the interrupt checks want exactly
     * one source, so that "pending", "claim" and MEIP can only be about the
     * UART. The SPI is source 2 and nothing here drives it, but leaving it
     * enabled would make every check below conditional on that staying true. */
    PLIC_ENABLE = UART_SRC_BIT;
    check("and enable narrows back to one source", PLIC_ENABLE == UART_SRC_BIT);

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
    /*
     * Enable the UART's interrupt. cva5_uart drops this write -- it has no
     * control register and its interrupt follows "receive FIFO not empty"
     * unconditionally -- so on the board this line does nothing and the
     * section below passed without it.
     *
     * axi_uartlite gates its interrupt on this bit, though, and so does
     * QEMU's xilinx_uartlite: there the interrupt is (status & IE) &&
     * (control & IE), so without this the keypress below never reaches the
     * PLIC and the wait times out. The register map is axi_uartlite's, so
     * setting it is what the map says to do either way.
     */
    UART_CTRL = UART_CTRL_IE;

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

    /* --- 5. claim, then quiet the device, and only then report
     *
     * Nothing may print between the claim and the read of the byte. Printing
     * writes the UART, and the UART's interrupt is level sensitive: while the
     * byte is still in the receive FIFO the line is still high, so every
     * character sent keeps asserting it.
     *
     * On this hardware that is harmless -- the PLIC's gateway forwards
     * nothing for a source whose claim is in progress, which is what the
     * specification requires. QEMU's PLIC does not implement that: its
     * gateway sets the pending bit on any assertion, claimed or not, and
     * ignores deassertion entirely, so the pending bit it sets during the
     * claim window survives the byte being read and reappears the moment the
     * complete lifts the claim. The checks below then fail on a model
     * limitation rather than on anything this SoC does.
     *
     * So the results are captured first and printed afterwards. The order of
     * bus operations is what the test is about; where the PASS lines come out
     * is not.
     */
    unsigned int id = PLIC_CLAIM;
    int claim_named_uart = (id == PLIC_SRC_UART);
    int claim_suppressed = (mip_wait(MIP_MEIP, 0) >= 0);

    /* Quiet the device BEFORE completing. The other order re-raises the
     * interrupt immediately, because the irq is level sensitive and the byte
     * is still in the FIFO -- correct hardware behaviour, and the thing most
     * likely to look like a stuck interrupt in a handler. */
    unsigned int rx_byte = UART_RX;
    int rx_valid_cleared = ((UART_STAT & UART_RX_VALID) == 0u);

    check("claim names the UART", claim_named_uart);
    check("claiming suppresses it while in progress", claim_suppressed);
    put_hex("byte received: ", rx_byte);
    check("reading the byte clears rx_valid", rx_valid_cleared);

    PLIC_CLAIM = id;                  /* complete */
    /* mip.MEIP is already down from the claim, so mip_wait would return
     * immediately whether or not the complete has landed, and the pending read
     * after it would race. */
    dev_fence();
    check("completing a quiet source leaves meip down",
          mip_wait(MIP_MEIP, 0) >= 0);
    check("and nothing is pending", (PLIC_PENDING & UART_SRC_BIT) == 0u);

    PLIC_ENABLE = 0u;
    puts(fails ? "plic: FAIL" : "plic: PASS");
    for (;;) ;
}
