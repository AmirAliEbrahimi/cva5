/*
 * server.c -- CVA5 classifies whatever the PS puts in front of it.
 *
 * This is the system the project is for. The accelerator has until now only
 * seen images linked into .rodata, which demonstrates a data path; here the
 * image arrives at run time from the other processor, over the same
 * M_AXI_GP1 port that loaded this program, and the answer goes back the same
 * way. Nothing new is built to do it -- the PS writing main memory, the DMA
 * reading main memory and the mailbox were each already working and proven
 * separately on hardware. What was missing was somewhere for the two sides
 * to agree about a unit of work, which is soc.h's job block.
 *
 * The loop is deliberately dull:
 *
 *     announce that a server is listening
 *     forever:
 *         wait for request != response
 *         run the accelerator over the image page
 *         write the result, then the response counter
 *
 * There is no software reference here and that is the point of the split:
 * examples/sw/cifar.c checks the hardware against software on fixed images
 * and answers "is it right", and this answers "does the system work". Doing
 * both in one program would put a million-odd cycles of reference
 * arithmetic per image in the middle of the thing being demonstrated, and
 * would mean linking the weights into a program whose whole appeal is that
 * it is 1.7 KB and gets its work from the other processor.
 *
 * Build and run:
 *     make -C examples/sw server        # load over JTAG, then feed it
 * or load it from the PS, which is the interesting way:
 *     make -C examples/sw ps-image PS_APP=server.elf
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdio.h>
#include "soc.h"
#include "accel.h"
#include "job.h"

static void putdec(unsigned v) {
    char b[11];
    int i = 10;
    b[10] = '\0';
    if (v == 0) { putstr("0"); return; }
    while (v && i) { b[--i] = (char)('0' + v % 10); v /= 10; }
    putstr(&b[i]);
}

static void putsigned(int v) {
    if (v < 0) { putstr("-"); putdec((unsigned)(-v)); }
    else putdec((unsigned)v);
}

static void puthex8(unsigned v) {
    char b[11];
    int i;
    b[0] = '0'; b[1] = 'x';
    for (i = 0; i < 8; i++) {
        unsigned nib = (v >> ((7 - i) * 4)) & 0xF;
        b[2 + i] = (char)(nib < 10 ? '0' + nib : 'a' + nib - 10);
    }
    b[10] = '\0';
    putstr(b);
}

int main(void) {
    unsigned int served = 0;

    puts("server: the PS sends images, the accelerator classifies them");
    putstr("  job block   "); puthex8(JOB_BASE);
    putstr("  image at "); puthex8(JOB_IMG_BASE); puts("");
    putstr("  image page  "); putdec(JOB_IMG_SIZE);
    puts(" bytes, 4 per pixel, R G B 0");

    /* The accelerator has to be there. A control window that decodes to
     * nothing reads as zero, and zero has ACCEL_ST_IDLE clear -- so this
     * also catches a bitstream built without the hls4ml IP, which otherwise
     * presents as every job timing out. */
    if (!(ACCEL(ACCEL_STATUS_OFF) & ACCEL_ST_IDLE)) {
        puts("  FAIL the accelerator is not idle -- is the IP in this"
             " bitstream?");
        return 1;
    }

    job_listen();
    puts("  listening");

    for (;;) {
        unsigned int seq, cycles = 0, pad_before, pad, cls;
        int l0 = 0, l1 = 0, ok;
        unsigned int raw = 0, st_before, st_after;

        st_before = ACCEL(ACCEL_STATUS_OFF);

        while (!job_pending())
            ;

        /* Snapshot the request before the work, not after: the PS may
         * submit again while this inference is running. */
        seq = job_request();

        /* PADSEEN counts since rstn, so the only meaningful number for one
         * job is the difference across it. Reporting the raw counter is
         * how the first version of cifar.c blamed a clean image for an
         * earlier test's deliberate mis-packing. */
        pad_before = ACCEL(ACCEL_PADSEEN_OFF);

        ok = accel_infer((const void *)JOB_IMG_BASE, &l0, &l1, &cycles, &raw);
        pad = ACCEL(ACCEL_PADSEEN_OFF) - pad_before;
        cls = (l1 > l0) ? 1u : 0u;

        st_after = ACCEL(ACCEL_STATUS_OFF);

        if (ok != 1) {
            job_complete(seq, JOB_ERR_TIMEOUT, 0, 0, 0u, 0u, pad);
            putstr("  job "); putdec(seq);
            putstr(ok == -1 ? ": a result was already waiting and would not"
                              " clear"
                            : ": no result from the accelerator");
            putstr("  status "); puthex8(st_before);
            putstr(" -> "); puthex8(st_after); puts("");
            continue;
        }

        /* The first job prints what the registers actually said. 31 cycles
         * means the poll never waited, which means a result was there
         * before this one started -- a different fault from a wrong
         * answer, and they look the same in a table of classes. */
        if (seq == 1u) {
            putstr("  first job: status "); puthex8(st_before);
            putstr(" -> "); puthex8(st_after);
            putstr("  raw "); puthex8(raw);
            putstr("  "); putdec(cycles); puts(" cycles");
        }

        job_complete(seq, JOB_OK, l0, l1, cls, cycles, pad);
        served++;

        /* The console line is for a human watching; the PS reads the job
         * block, not this. */
        putstr("  job "); putdec(seq);
        putstr(": class "); putdec(cls);
        putstr("  logits "); putsigned(l0); putstr(","); putsigned(l1);
        putstr("  "); putdec(cycles); putstr(" cycles");
        if (pad) { putstr("  pad "); putdec(pad); putstr(" <- not 4 bytes"
                                                         " per pixel"); }
        puts("");
    }
}
