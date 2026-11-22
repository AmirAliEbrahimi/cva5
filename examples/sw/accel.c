/*
 * accel.c -- drive the hls4ml accelerator from CVA5.
 *
 * The whole point of the second version of this design is that this file is
 * short. The first one stored 1,536 words into a memory-mapped FIFO by hand
 * and spent 77% of an inference doing it; here the image stays where it is
 * and the DMA reads it, so the driver writes an address, a length and a
 * start bit.
 *
 * What it checks, in order, because each step can only be interpreted if the
 * one before it worked:
 *
 *   1. The control block answers at all, and the accelerator is idle.
 *   2. The DMA keeps an address and a length written to it. A window that
 *      decodes but does not store is what a wrong ACCEL_BASE looks like.
 *   3. An inference completes and a result appears.
 *   4. PADSEEN is zero, which is the only evidence that the image in memory
 *      is laid out the way the data path requires. Nothing downstream can
 *      tell a mis-packed image from a correct one.
 *   5. Deliberately mis-packing one, to show PADSEEN catching it. A test
 *      that only ever passes proves the detector is wired, not that it works.
 *
 * Build and run:  make -C examples/sw accel
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdio.h>
#include "soc.h"
#include "mip.h"

#define ACCEL(off) (*(volatile unsigned int *)(ACCEL_BASE + (off)))

/* The image lives in main memory, well above this program and below the
 * stack. memtest.c uses the same region and for the same reason. */
#define IMG_ADDR (RAM_BASE + 0x8000u)

static void puthex(unsigned v) {
    char b[11];
    b[0] = '0'; b[1] = 'x';
    for (int i = 0; i < 8; i++) {
        unsigned nib = (v >> ((7 - i) * 4)) & 0xF;
        b[2 + i] = (char)(nib < 10 ? '0' + nib : 'a' + nib - 10);
    }
    b[10] = '\0';
    putstr(b);
}

static void putdec(unsigned v) {
    char b[11];
    int i = 10;
    b[10] = '\0';
    if (v == 0) { putstr("0"); return; }
    while (v && i) { b[--i] = (char)('0' + v % 10); v /= 10; }
    putstr(&b[i]);
}

/*
 * Fill the image. Four bytes a pixel -- R, G, B, 0 -- which is what makes one
 * pixel one word and the DMA's beat the accelerator's beat.
 *
 * `pad` is what goes in the fourth byte. Zero is correct; anything else is
 * the mistake this driver then demonstrates being caught.
 */
static void fill_image(unsigned char pad) {
    volatile unsigned int *px = (volatile unsigned int *)IMG_ADDR;
    for (unsigned i = 0; i < ACCEL_IMG_PIXELS; i++) {
        unsigned r = i & 0xFF;
        unsigned g = (i >> 2) & 0xFF;
        unsigned b = (i >> 4) & 0xFF;
        px[i] = r | (g << 8) | (b << 16) | ((unsigned)pad << 24);
    }
    dev_fence();
}

/* Returns 1 if a result arrived, 0 if it timed out. */
static int run_once(void) {
    unsigned spins = 0;

    ACCEL(ACCEL_CTRL_OFF) = ACCEL_CTRL_START;

    /* The DMA last, so the stream has somewhere to go the moment it starts.
     * Starting it needs bit 31 set -- a plain write clears the flags and
     * starts nothing, which looks exactly like a DMA that is not connected. */
    ACCEL(DMA_ADDRLO_OFF)  = ACCEL_RAM_OFF(IMG_ADDR);
    ACCEL(DMA_LENLO_OFF)   = ACCEL_IMG_BYTES;
    ACCEL(DMA_CONTROL_OFF) = DMA_START;

    while (!(ACCEL(ACCEL_STATUS_OFF) & ACCEL_ST_RESULT)) {
        if (++spins > 2000000u)
            return 0;
    }
    return 1;
}

int main(void) {
    unsigned status, v, pad_clean, pad_dirty;
    int fails = 0;

    puts("accel: hls4ml accelerator over the DMA");

    status = ACCEL(ACCEL_STATUS_OFF);
    putstr("  status      "); puthex(status); puts("");
    if (!(status & ACCEL_ST_IDLE)) {
        puts("  FAIL accelerator is not idle at reset");
        fails++;
    }

    /* A window that decodes but does not store is what a wrong ACCEL_BASE
     * looks like: every read returns something, and nothing works. */
    ACCEL(DMA_ADDRLO_OFF) = ACCEL_RAM_OFF(IMG_ADDR);
    ACCEL(DMA_LENLO_OFF)  = ACCEL_IMG_BYTES;
    v = ACCEL(DMA_ADDRLO_OFF);
    if (v != ACCEL_RAM_OFF(IMG_ADDR)) {
        putstr("  FAIL DMA address read back "); puthex(v);
        putstr(" wanted "); puthex(ACCEL_RAM_OFF(IMG_ADDR)); puts("");
        fails++;
    }
    v = ACCEL(DMA_LENLO_OFF);
    if (v != ACCEL_IMG_BYTES) {
        putstr("  FAIL DMA length read back "); puthex(v); puts("");
        fails++;
    }

    /* A correctly packed image. */
    fill_image(0x00);
    if (!run_once()) {
        puts("  FAIL no result -- check that the stream reaches the accelerator");
        putstr("  status      "); puthex(ACCEL(ACCEL_STATUS_OFF)); puts("");
        fails++;
    } else {
        putstr("  result      "); puthex(ACCEL(ACCEL_RESULT_OFF)); puts("");
        if (ACCEL(ACCEL_STATUS_OFF) & ACCEL_ST_RESULT) {
            puts("  FAIL reading the result did not clear its valid bit");
            fails++;
        }
    }
    pad_clean = ACCEL(ACCEL_PADSEEN_OFF);
    putstr("  pad bytes   "); putdec(pad_clean);
    puts(pad_clean ? "  <- the image is not 4 bytes per pixel" : "  (clean)");
    if (pad_clean != 0) fails++;

    /* And the same image packed wrongly, to show the detector working.
     * Without this the zero above means only that the counter is wired. */
    fill_image(0xA5);
    if (!run_once()) {
        puts("  FAIL no result on the mis-packed run");
        fails++;
    } else {
        putstr("  result      "); puthex(ACCEL(ACCEL_RESULT_OFF));
        puts("  (mis-packed, expected to differ)");
    }
    pad_dirty = ACCEL(ACCEL_PADSEEN_OFF);
    putstr("  pad bytes   "); putdec(pad_dirty); puts("");
    if (pad_dirty <= pad_clean) {
        puts("  FAIL a mis-packed image was not reported");
        fails++;
    }

    /*
     * The interrupt, which until patch 0068 was a port nobody had seen
     * assert. Last, because it needs the data path above it to work, and
     * because arming the PLIC changes state a failure here would otherwise
     * be blamed on.
     *
     * The accelerator's irq is result_valid, which makes it a level like
     * the UART's and not a pulse like the SPI's: reading ACCEL_RESULT is
     * what lowers it, so the read that collects the answer is also the
     * acknowledgement. Completing before that read leaves the line high and
     * the source comes straight back.
     */
    puts("  -- interrupt, PLIC source 3");
    PLIC_THRESHOLD = 0u;
    PLIC_PRIORITY(PLIC_SRC_ACCEL) = 1u;
    PLIC_ENABLE = PLIC_ENABLE | (1u << PLIC_SRC_ACCEL);
    dev_fence();
    for (v = 0; v < 4u; v++) {              /* drain an earlier run's pending */
        unsigned stale = PLIC_CLAIM;
        if (!stale) break;
        PLIC_CLAIM = stale;
        dev_fence();
    }
    if (mip_wait(MIP_MEIP, 0) < 0) {
        puts("  FAIL meip is high before an inference has been started");
        fails++;
    }

    fill_image(0x00);
    if (!run_once()) {
        puts("  FAIL no result on the interrupt run");
        fails++;
    } else {
        /* run_once polls the status, so by here the result is waiting and
         * the line has been up for a while. */
        if (mip_wait(MIP_MEIP, 1) < 0) {
            puts("  FAIL a waiting result did not raise meip");
            fails++;
        }
        v = PLIC_CLAIM;
        if (v != PLIC_SRC_ACCEL) {
            putstr("  FAIL claimed source "); putdec(v);
            putstr(" wanted "); putdec(PLIC_SRC_ACCEL); puts("");
            fails++;
        }
        /* Complete FIRST, with the result still unread, to show the source
         * coming back -- an inference whose answer nobody collected must
         * not be lost. */
        PLIC_CLAIM = v;
        dev_fence();
        if (mip_wait(MIP_MEIP, 1) < 0) {
            puts("  FAIL completing with the result unread lost the"
                 " interrupt");
            fails++;
        }
        /* Now the other order: claim, read the result, then complete. */
        v = PLIC_CLAIM;
        (void)ACCEL(ACCEL_RESULT_OFF);
        PLIC_CLAIM = v;
        dev_fence();
        if (mip_wait(MIP_MEIP, 0) < 0) {
            puts("  FAIL reading the result did not drop the interrupt");
            fails++;
        }
    }
    PLIC_ENABLE = PLIC_ENABLE & ~(1u << PLIC_SRC_ACCEL);
    PLIC_PRIORITY(PLIC_SRC_ACCEL) = 0u;

    if (fails) { putstr("FAIL accel: "); putdec((unsigned)fails); puts(" problems"); }
    else       puts("PASS accel");
    return 0;
}
