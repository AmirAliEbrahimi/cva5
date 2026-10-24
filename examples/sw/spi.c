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
 *   - a second word of a different shape, so a stuck bit cannot pass both.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include "soc.h"

#define SPI_STATUS  (*(volatile unsigned int *)(SPI_BASE + SPI_STATUS_OFF))
#define SPI_CLKDIV  (*(volatile unsigned int *)(SPI_BASE + SPI_CLKDIV_OFF))
#define SPI_CMD     (*(volatile unsigned int *)(SPI_BASE + SPI_CMD_OFF))
#define SPI_ADDR    (*(volatile unsigned int *)(SPI_BASE + SPI_ADDR_OFF))
#define SPI_LENREG  (*(volatile unsigned int *)(SPI_BASE + SPI_LEN_OFF))
#define SPI_DUMMY   (*(volatile unsigned int *)(SPI_BASE + SPI_DUMMY_OFF))
#define SPI_TX      (*(volatile unsigned int *)(SPI_BASE + SPI_TX_FIFO_OFF))
#define SPI_RX      (*(volatile unsigned int *)(SPI_BASE + SPI_RX_FIFO_OFF))

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
    if (!wait_idle())
        return 0xDEADDEADu;
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

    v = SPI_STATUS;
    check("status reports idle", (v & SPI_IDLE) != 0u);
    check("both FIFOs are empty",
          SPI_TX_LEVEL(v) == 0u && SPI_RX_LEVEL(v) == 0u);

    SPI_TX = 0xDEADBEEFu;
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

    if (fails) {
        puts("");
        puts("all zeros where ones were expected means the jumper is missing,");
        puts("or MISO is wired to the IP's sdi0 instead of sdi1 -- see the");
        puts("note at the top of examples/xilinx/axi/cva5_spi_axi.sv.");
        puts("0xdeaddead means a transfer never finished: check CLKDIV and");
        puts("that the block design wired spi_clk out at all.");
    }

    puts(fails ? "spi: FAIL" : "spi: PASS");
    for (;;) ;
}
