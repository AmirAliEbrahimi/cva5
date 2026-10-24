/* I2C check: does the controller answer, and does the bus work?
 *
 * The register half needs nothing attached. The bus half is a scan: every
 * 7-bit address from 0x08 to 0x77 is addressed for a write and the ACK bit
 * reported, which is the standard way to bring an I2C bus up and the only test
 * here that proves the pins.
 *
 * Why a scan rather than a fixed address. With nothing on the bus, a transfer
 * to any address comes back as a missed ACK -- and so does a transfer on a bus
 * whose SCL and SDA are constrained to the wrong balls, or shorted, or without
 * pull-ups. A missed ACK therefore says nothing about the wiring. One device
 * answering says the pins are right, the open-drain tie-off drives and
 * releases, the prescaler produces a legal SCL, and the ACK is sampled at the
 * right edge -- the whole path, in one bit.
 *
 * So: with nothing attached this prints no devices and passes, having checked
 * only what it can. Hang any I2C device off the Arduino header's SCL/SDA
 * (J3 pins 9 and 10, pull-ups already on the board) and it should appear.
 *
 * What it proves, in order:
 *   - the register file answers over the bus at the offsets soc.h gives;
 *   - prescale reads back, so the window decodes and the device is not
 *     aliasing one register onto another;
 *   - the bus comes up idle with both lines released;
 *   - an address nothing answers is reported as a missed ACK rather than
 *     hanging, and the sticky bit clears when written;
 *   - the scan, which is informational unless something answers.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <stdio.h>
#include "soc.h"

#define I2C_STATUS   (*(volatile unsigned int *)(I2C_BASE + I2C_STATUS_OFF))
#define I2C_COMMAND  (*(volatile unsigned int *)(I2C_BASE + I2C_COMMAND_OFF))
#define I2C_DATA     (*(volatile unsigned int *)(I2C_BASE + I2C_DATA_OFF))
#define I2C_PRESCALE (*(volatile unsigned int *)(I2C_BASE + I2C_PRESCALE_OFF))

static int fails;

static void check(const char *what, int ok) {
    putstr(ok ? "PASS " : "FAIL ");
    puts(what);
    if (!ok)
        fails++;
}

static void put_hex(const char *label, unsigned int v) {
    static const char digits[] = "0123456789abcdef";
    char buf[11];
    unsigned n = 0;

    buf[n++] = '0';
    buf[n++] = 'x';
    for (int i = 0; i < 8; i++)
        buf[n++] = digits[(v >> (28 - 4 * i)) & 0xFu];
    buf[n] = '\0';
    putstr(label);
    puts(buf);
}

/* Waits for the controller to finish and the bus to go idle.
 *
 * Bounded in bus time rather than loop count: at the slowest prescale a byte
 * plus its ACK is nine SCL periods, and this allows far more than that. A
 * transfer that has not finished by then is not slow, it is stuck -- which is
 * what an SCL held low by a confused slave looks like.
 */
static int wait_idle(void) {
    for (unsigned int i = 0; i < 2000000u; i++) {
        dev_fence();
        if (!(I2C_STATUS & (I2C_BUSY | I2C_BUS_ACTIVE)))
            return 1;
    }
    return 0;
}

/* Addresses a slave for a one-byte write and reports whether anything
 * answered. Returns 1 on ACK, 0 on no answer, -1 if the bus hung. */
static int probe(unsigned int addr) {
    /* Clear the sticky bits first -- missed-ack is in byte 0 and the two
     * overflow bits in byte 1, and a 32-bit store carries all three. */
    I2C_STATUS = I2C_STICKY;
    dev_fence();

    I2C_DATA = 0x00u;
    I2C_COMMAND = I2C_CMD_ADDR(addr) | I2C_CMD_START | I2C_CMD_WRITE |
                  I2C_CMD_STOP;
    if (!wait_idle())
        return -1;

    dev_fence();
    return (I2C_STATUS & I2C_MISSED_ACK) ? 0 : 1;
}

int main(void) {
    unsigned int v;

    puts("I2C check");

    /* --- the register file.
     *
     * Nothing resets this peripheral but rstn, so the prescale may be whatever
     * a previous run left. Write it before reading anything that depends on
     * it. */
    I2C_PRESCALE = I2C_PRESCALE_100K;
    dev_fence();
    check("prescale reads back", I2C_PRESCALE == I2C_PRESCALE_100K);

    I2C_PRESCALE = I2C_PRESCALE_400K;
    dev_fence();
    check("and a second value, so it is not stuck",
          I2C_PRESCALE == I2C_PRESCALE_400K);
    I2C_PRESCALE = I2C_PRESCALE_100K;

    /* STATUS is a different register from PRESCALE, so this needs the fence
     * for the reason soc.h gives. */
    dev_fence();
    v = I2C_STATUS;
    check("the controller is idle", (v & (I2C_BUSY | I2C_BUS_ACTIVE)) == 0u);
    check("the read FIFO is empty", (v & I2C_RD_EMPTY) != 0u);
    check("the write FIFO is empty", (v & I2C_WR_EMPTY) != 0u);
    check("the command FIFO is empty", (v & I2C_CMD_EMPTY) != 0u);

    /* Bus control low with the bus idle means this master has released both
     * lines. With the board's pull-ups that is SCL and SDA both high -- which
     * cannot be read back directly, but a master that thought it held the bus
     * here would be driving one of them low. */
    check("and this master is not holding the bus",
          (v & I2C_BUS_CONTROL) == 0u);

    /* --- the sticky bits clear */
    I2C_STATUS = I2C_STICKY;
    dev_fence();
    check("the sticky bits start clear", (I2C_STATUS & I2C_STICKY) == 0u);

    /* --- an address nothing answers.
     *
     * 0x7B is in the reserved high range, so no real device should sit there
     * even on a populated bus -- which keeps this check meaningful whether or
     * not something is attached. */
    puts("");
    int r = probe(0x7Bu);
    if (r < 0) {
        puts("FAIL: the bus never went idle");
        put_hex("  status: ", I2C_STATUS);
        puts("");
        puts("SCL stuck low is a slave holding the clock, or SCL and SDA");
        puts("shorted together. Check the pull-ups are present and that");
        puts("nothing is driving the lines.");
        for (;;) ;
    }
    check("an unanswered address is reported, not hung", r == 0);
    check("and it set the missed-ack bit",
          (I2C_STATUS & I2C_MISSED_ACK) != 0u);

    I2C_STATUS = I2C_MISSED_ACK;
    dev_fence();
    check("which clears when written", (I2C_STATUS & I2C_MISSED_ACK) == 0u);

    /* --- the scan */
    puts("");
    puts("scanning 0x08..0x77...");

    int found = 0;
    for (unsigned int a = 0x08u; a <= 0x77u; a++) {
        int got = probe(a);
        if (got < 0) {
            put_hex("  bus hung at address ", a);
            fails++;
            break;
        }
        if (got) {
            put_hex("  device answered at ", a);
            found++;
        }
    }

    if (found) {
        put_hex("devices found: ", (unsigned int)found);
        check("the bus works end to end", 1);
    } else {
        puts("no devices answered.");
        puts("");
        puts("That is the expected result with nothing attached, and it is");
        puts("also what a mis-wired bus looks like -- the register checks");
        puts("above pass either way. To prove the pins, hang any I2C device");
        puts("off the Arduino header: SCL on J3 pin 9, SDA on J3 pin 10.");
    }

    puts(fails ? "i2c: FAIL" : "i2c: PASS");
    for (;;) ;
}
