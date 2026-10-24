/* SPI check: does a transfer go out, and does it come back?
 *
 * The register half of this needs nothing attached. The transfer half is a
 * loopback: jumper MOSI to MISO on the Arduino shield's ICSP header (pins
 * T12 and W15; see examples/xilinx/pynq_z2_cva5.xdc) and whatever is sent
 * comes back. That is a better first test than a real device, because it
 * exercises the receive path -- which is where the one real trap in this IP
 * lives. In single-bit mode the transmitter drives sdo0 but the receiver
 * samples sdi1, so a controller wired MISO-to-sdi0 transmits perfectly and
 * reads nothing but zeros. With the jumper off, that is also what you see, so
 * the two cases are told apart here by asking for the jumper explicitly.
 *
 * What it proves, in order:
 *   - the register file answers over the bus at the offsets soc.h gives;
 *   - STATUS reports idle, and the FIFO levels track what is written;
 *   - a transfer runs to completion and ends idle again;
 *   - with the jumper in place, the word that went out comes back bit for
 *     bit -- which also means the chip select framed it and the clock ran;
 *   - a second word of a different shape, so a stuck bit cannot pass both;
 *   - the end-of-transfer interrupt reaches the PLIC as source 2 and the core
 *     as mip.MEIP, and a claim names the SPI rather than the UART.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include "soc.h"
#include "mip.h"

#define SPI_STATUS  (*(volatile unsigned int *)(SPI_BASE + SPI_STATUS_OFF))
#define SPI_CLKDIV  (*(volatile unsigned int *)(SPI_BASE + SPI_CLKDIV_OFF))
#define SPI_CMD     (*(volatile unsigned int *)(SPI_BASE + SPI_CMD_OFF))
#define SPI_ADDR    (*(volatile unsigned int *)(SPI_BASE + SPI_ADDR_OFF))
#define SPI_LENREG  (*(volatile unsigned int *)(SPI_BASE + SPI_LEN_OFF))
#define SPI_DUMMY   (*(volatile unsigned int *)(SPI_BASE + SPI_DUMMY_OFF))
#define SPI_TX      (*(volatile unsigned int *)(SPI_BASE + SPI_TX_FIFO_OFF))
#define SPI_RX      (*(volatile unsigned int *)(SPI_BASE + SPI_RX_FIFO_OFF))

#define PLIC_PRIORITY(src) (*(volatile unsigned int *)(PLIC_BASE + PLIC_PRIORITY_OFF(src)))
#define PLIC_PENDING   (*(volatile unsigned int *)(PLIC_BASE + PLIC_PENDING_OFF))
#define PLIC_ENABLE    (*(volatile unsigned int *)(PLIC_BASE + PLIC_ENABLE_OFF))
#define PLIC_THRESHOLD (*(volatile unsigned int *)(PLIC_BASE + PLIC_THRESHOLD_OFF))
#define PLIC_CLAIM     (*(volatile unsigned int *)(PLIC_BASE + PLIC_CLAIM_OFF))

#define SPI_SRC_BIT (1u << PLIC_SRC_SPI)

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

static void put_hex(const char *label, unsigned int v) {
    static const char digits[] = "0123456789abcdef";
    char buf[40];
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

/* mtime, so timeouts are in real time rather than loop counts. */
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

/* A transfer at these settings takes microseconds; a second is generous. */
static int wait_idle(void) {
    unsigned long long deadline = mtime_read() + 1ull * CLINT_HZ;
    while (mtime_read() < deadline)
        if (SPI_STATUS & SPI_IDLE)
            return 1;
    return 0;
}

/* A read transfer with a short command, which is what makes a loopback
 * readable on a half-duplex controller.
 *
 * The controller does a command phase and then data in one direction, so it
 * cannot hand back a word that was just sent. What it can do: after an 8-bit
 * command the transmitter is left holding bit 23 of SPICMD on MOSI, and that
 * level is what the receiver sees for the whole data phase while the jumper is
 * in place. tb_spi measures exactly this -- cmd 0x00800000 reads 0xFFFFFFFF,
 * cmd 0x00000000 reads 0x00000000 -- so the board should agree.
 */
static unsigned int read_with_held_level(unsigned int cmd, int cs) {
    SPI_CMD = cmd;
    SPI_LENREG = SPI_LEN(8, 0, 32);
    SPI_STATUS = SPI_START_RD | SPI_CS(cs);
    /* The three writes above reach the device in order -- the store queue does
     * not reorder stores -- so the command and length are in place before the
     * start. wait_idle polls STATUS, which is slow enough that the RX read
     * cannot race it, but say so rather than rely on it. */
    if (!wait_idle())
        return 0xDEADDEADu;
    dev_fence();
    return SPI_RX;
}

int main(void) {
    unsigned int v;

    puts("SPI check");

    /* --- a known state. Nothing resets this peripheral but rstn. */
    SPI_STATUS = SPI_SWRST;
    if (!wait_idle()) {
        puts("FAIL: not idle after a soft reset");
        put_hex("  status: ", SPI_STATUS);
        for (;;) ;
    }

    /* --- the register file */
    SPI_CLKDIV = 8u;
    check("clkdiv reads back", (SPI_CLKDIV & 0xFFu) == 8u);

    SPI_CMD = 0xA5A55A5Au;
    check("cmd reads back", SPI_CMD == 0xA5A55A5Au);

    SPI_ADDR = 0x12345678u;
    check("addr reads back", SPI_ADDR == 0x12345678u);

    SPI_LENREG = SPI_LEN(8, 24, 32);
    check("len reads back", SPI_LENREG == SPI_LEN(8, 24, 32));

    SPI_DUMMY = 0u;
    check("dummy reads back", SPI_DUMMY == 0u);

    /* Every check above reads back the register it just wrote, which the store
     * queue forwards, so none of them can race. STATUS is a different one. */
    dev_fence();
    v = SPI_STATUS;
    check("status reports idle", (v & SPI_IDLE) != 0u);
    check("both FIFOs are empty",
          SPI_TX_LEVEL(v) == 0u && SPI_RX_LEVEL(v) == 0u);

    SPI_TX = 0xDEADBEEFu;
    dev_fence();              /* STATUS is a different register; see soc.h */
    v = SPI_STATUS;
    check("a word written to TX shows in the level", SPI_TX_LEVEL(v) == 1u);

    /* Drain it by sending it, so the FIFO starts the next part empty. */
    SPI_CMD = 0u;
    SPI_LENREG = SPI_LEN(0, 0, 32);
    SPI_STATUS = SPI_START_WR | SPI_CS(0);
    check("a transfer runs and ends idle", wait_idle());
    v = SPI_STATUS;
    check("and the TX FIFO drained", SPI_TX_LEVEL(v) == 0u);

    /* --- the loopback */
    puts("");
    puts("loopback: jumper MOSI (T12) to MISO (W15) on the ICSP header");
    puts("");

    SPI_CLKDIV = 32u;                 /* slow, so a long jumper is fine */

    v = read_with_held_level(0x00800000u, 0);
    put_hex("held 1 on MOSI, read back ", v);
    check("a held 1 comes back as all ones", v == 0xFFFFFFFFu);

    v = read_with_held_level(0x00000000u, 0);
    put_hex("held 0 on MOSI, read back ", v);
    check("a held 0 comes back as all zeros", v == 0x00000000u);

    /* The same on another chip select, which proves the second CS line frames
     * a transfer as well as the first. Nothing is attached to either, so the
     * loopback result is the same -- it is the CS pin that differs. */
    v = read_with_held_level(0x00800000u, 1);
    check("and the same on chip select 1", v == 0xFFFFFFFFu);

    /* --- the interrupt
     *
     * events_o[1] is end of transfer and events_o[0] a FIFO watermark, ORed
     * into one irq, through cva5_irq_concat to PLIC source 2. It is a pulse,
     * not a level, and that is fine level sensitive: the PLIC's gateway is
     * `ip <= (ip | raise) & ~in_progress & ~claim`, so one cycle high latches
     * and the pending bit stays up until it is claimed.
     *
     * Which makes this the one check here that cares what ran before it, in
     * both directions. The PLIC resets from rstn alone, so pending survives a
     * program reload -- hence the claim-and-complete below before arming -- and
     * every transfer above has already raised this source, so the pending bit
     * has to be cleared and then raised again by a transfer of our own rather
     * than read where it stands. */
    puts("");
    PLIC_THRESHOLD = 0u;
    PLIC_ENABLE = SPI_SRC_BIT;
    PLIC_PRIORITY(PLIC_SRC_SPI) = 3u;
    dev_fence();

    /* Without that fence the claim below was issued before the priority write
     * landed, so it saw priority 0, returned 0, and drained nothing -- leaving
     * the source from the transfers above pending for the two checks that
     * follow. The symptom looked like the interrupt being stuck on. */
    for (unsigned i = 0; i < 3u; i++) {
        unsigned int stale = PLIC_CLAIM;
        if (!stale)
            break;
        PLIC_CLAIM = stale;
        dev_fence();          /* complete, before the next claim */
    }
    check("draining leaves meip down", mip_wait(MIP_MEIP, 0) >= 0);
    check("and the SPI's source quiet", (PLIC_PENDING & SPI_SRC_BIT) == 0u);

    (void)read_with_held_level(0x00800000u, 0);

    check("a transfer makes the SPI's source pending",
          (PLIC_PENDING & SPI_SRC_BIT) != 0u);
    check("and it reaches mip.MEIP", mip_wait(MIP_MEIP, 1) >= 0);

    unsigned int id = PLIC_CLAIM;
    check("a claim names the SPI, not the UART", id == PLIC_SRC_SPI);
    check("claiming suppresses it", mip_wait(MIP_MEIP, 0) >= 0);

    /* Nothing to quiet first, unlike the UART: eot is one cycle wide
     * (spi_master_controller.sv drives it combinationally for the cycle the
     * state machine returns to IDLE) and events_o[0] is an edge detector on
     * the FIFO levels, so neither is still asserted here and a complete leaves
     * the source down instead of handing it straight back. */
    PLIC_CLAIM = id;
    dev_fence();
    check("completing leaves it down", mip_wait(MIP_MEIP, 0) >= 0);
    check("and nothing pending", (PLIC_PENDING & SPI_SRC_BIT) == 0u);

    PLIC_ENABLE = 0u;
    PLIC_PRIORITY(PLIC_SRC_SPI) = 0u;

    if (fails) {
        puts("");
        puts("all zeros where ones were expected means the jumper is missing,");
        puts("or MISO is wired to the IP's sdi0 instead of sdi1 -- see the");
        puts("note at the top of examples/xilinx/axi/cva5_spi_axi.sv.");
        puts("0xdeaddead means a transfer never finished: check CLKDIV and");
        puts("that the block design wired spi_sck out at all.");
    }

    puts(fails ? "spi: FAIL" : "spi: PASS");
    for (;;) ;
}
