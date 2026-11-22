/*
 * The full system: the PS sends CVA5 an image, CVA5 classifies it on the
 * accelerator, the answer comes back.
 *
 * Both processors, the DMA, the accelerator and two shared-memory protocols
 * in one loop, and every piece of it was proven separately before this
 * existed. Load examples/sw/server.elf into CVA5 with this app:
 *
 *     make -C examples/sw ps-image PS_APP=server.elf
 *     make -C tools/nn_accel headers       (also writes cva5_pixels.c)
 *
 * and build this instead of cva5_load.c as the Vitis application.
 *
 * What the two sides share is in cva5_ps.h: a page for the image, a page
 * for the job header, two counters. This side writes an image and
 * increments `request`; CVA5 runs the accelerator and increments
 * `response`. Neither ever writes the other's counter.
 *
 * The console is drained in the same loop, so CVA5's own line about each job
 * appears next to this side's. They are independent paths -- the mailbox and
 * the job block -- and seeing them agree is part of the demonstration.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdint.h>
#include "xil_printf.h"
#include "cva5_ps.h"
#include "cva5_mbox.h"
#include "cva5_image.h"
#include "cva5_boot.h"
#include "cva5_pixels.h"

/* Long enough that a working inference always lands -- it takes about 7,100
 * CVA5 cycles, 71 us -- and short enough that a wedged one is reported
 * rather than hanging the demo. These are PS polls of a PL register through
 * an AXI read, so each is hundreds of nanoseconds; a million is well over a
 * second. */
#define JOB_POLL_LIMIT 1000000u

static volatile uint8_t *const job_img =
    (volatile uint8_t *)(uintptr_t)JOB_IMG_BASE;

/*
 * Hand one image over and wait for the answer.
 *
 * The image goes in first and `request` last. On this side that ordering is
 * already guaranteed -- the PL window is Device memory and the ARM's stores
 * to it complete in order -- but it is the same rule CVA5 states with
 * `fence w,w` on the way back, and it is the rule the protocol rests on:
 * whoever sees the counter move must already be able to see what moved it.
 *
 * Returns 0 if a result came back.
 */
static int job_submit(const uint8_t *pixels, uint32_t seq) {
    uint32_t i, spins = 0;

    for (i = 0; i < JOB_IMG_SIZE; i++)
        job_img[i] = pixels[i];

    ps_wr(JOB_REQUEST_A, seq);

    while (ps_rd(JOB_RESPONSE_A) != seq) {
        if (++spins > JOB_POLL_LIMIT)
            return 1;
    }
    return 0;
}

int main(void) {
    uint32_t seq = 0, wrong = 0, spins = 0;
    uint32_t dropped_seen = 0;
    uint32_t k;

    xil_printf("\r\nCVA5 accelerator demo\r\n");

    if (cva5_pixel_images == 0) {
        xil_printf("no images -- run 'make -C tools/nn_accel headers'\r\n");
        return 1;
    }

    if (cva5_bring_up() != 0)
        return 1;

    /* Wait for the server to announce itself. A program that is not
     * server.elf never writes the magic, which is the difference between
     * "still starting" and "you loaded the wrong image". */
    xil_printf("waiting for the server ...\r\n");
    while (ps_rd(JOB_MAGIC_A) != JOB_MAGIC) {
        mbox_drain(cva5_console_put);
        if (++spins > JOB_POLL_LIMIT) {
            xil_printf("no server in CVA5's memory -- is this image "
                       "server.elf?\r\n");
            return 1;
        }
    }

    xil_printf("server up. sending %u images, %u bytes each\r\n\r\n",
               (unsigned)cva5_pixel_images, (unsigned)JOB_IMG_SIZE);
    xil_printf("  #  label  cva5   logits        cycles\r\n");

    for (k = 0; k < cva5_pixel_images; k++) {
        uint32_t cls, cycles, status, pad;
        int32_t l0, l1;

        seq++;
        if (job_submit(&cva5_pixels[k * JOB_IMG_SIZE], seq) != 0) {
            xil_printf("  %2u  no response from CVA5 -- is the core running?"
                       "\r\n", (unsigned)k);
            mbox_drain(cva5_console_put);
            return 1;
        }

        status = ps_rd(JOB_STATUS_A);
        l0     = (int32_t)ps_rd(JOB_LOGIT0_A);
        l1     = (int32_t)ps_rd(JOB_LOGIT1_A);
        cls    = ps_rd(JOB_CLASS_A);
        cycles = ps_rd(JOB_CYCLES_A);
        pad    = ps_rd(JOB_PADSEEN_A);

        if (status != JOB_OK) {
            xil_printf("  %2u  job failed, status %u\r\n",
                       (unsigned)k, (unsigned)status);
            wrong++;
            continue;
        }

        xil_printf("  %2u  %-6s %-6s %6d,%-6d %6u%s\r\n",
                   (unsigned)k,
                   cva5_pixel_classes[cva5_pixel_labels[k]],
                   cva5_pixel_classes[cls],
                   (int)l0, (int)l1, (unsigned)cycles,
                   pad ? "  pad bytes seen -- image not 4 per pixel" : "");

        if (cls != cva5_pixel_labels[k])
            wrong++;

        /* CVA5 prints its own line per job. Drain between images so the two
         * sides interleave in the order they happened. */
        mbox_drain(cva5_console_put);
    }

    xil_printf("\r\n%u of %u correct against the labels\r\n",
               (unsigned)(cva5_pixel_images - wrong),
               (unsigned)cva5_pixel_images);
    xil_printf("the PS never touched the accelerator: it wrote pixels into "
               "CVA5's\r\nmemory and read a classification back out\r\n");

    xil_printf("\r\ndraining CVA5's output:\r\n");
    for (;;) {
        uint32_t drop;
        mbox_drain(cva5_console_put);
        drop = ps_rd(MBOX_MAGIC_A) == MBOX_MAGIC ? ps_rd(MBOX_DROP_A) : 0u;
        if (drop != dropped_seen) {
            xil_printf("\r\n[%u characters dropped -- the ring filled]\r\n",
                       (unsigned)drop);
            dropped_seen = drop;
        }
    }
}
