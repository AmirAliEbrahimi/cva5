/*
 * CVA5's side of the job block: take an image from the PS, give back a
 * classification.
 *
 * soc.h has the layout and the reason this exists. This is the server half;
 * the client is examples/ps/cva5_load.c. Like mbox.h it is static inlines in
 * a header rather than a translation unit, so that a program becomes a
 * server by including it and no target's source list changes.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/* Guard named for this side: examples/ps/cva5_ps.h holds the client's copy
 * of the same layout. test_benches/sw/tb_job.c includes both, and the
 * mailbox already taught this tree what one shared guard name does -- the
 * second include silently expands to nothing and the test passes having
 * checked one file against itself. */
#ifndef CVA5_SW_JOB_H
#define CVA5_SW_JOB_H

#include "soc.h"

#define JOB_W(off) (*(volatile unsigned int *)(JOB_BASE + (off)))

/*
 * Publish the payload before the counter that announces it.
 *
 * Same rule as mbox_publish(), and for the same reason: CVA5 is in-order
 * and this is ordinary memory to it, but the reader is on the other side of
 * an AXI port and a mux, and what it depends on is that the result fields
 * are in memory before the `response` that says to read them. `fence w,w`
 * is that statement. dev_fence()'s `fence o,i` is a different one.
 */
static inline void job_publish(void) {
#ifdef __riscv
    __asm__ volatile ("fence w,w" ::: "memory");
#else
    __asm__ volatile ("" ::: "memory");
#endif
}

/*
 * Announce that a server is listening.
 *
 * Counters first, magic last, so a PS that sees the magic also sees a
 * consistent pair. Both counters are reset here rather than preserved: the
 * PS zeroes this page before it releases the core, but OpenOCD does not, and
 * a stale `request` left by a previous run would otherwise look like a job
 * waiting the instant the server starts.
 */
static inline void job_listen(void) {
    JOB_W(JOB_REQUEST_OFF)  = 0u;
    JOB_W(JOB_RESPONSE_OFF) = 0u;
    JOB_W(JOB_STATUS_OFF)   = JOB_OK;
    JOB_W(JOB_LOGIT0_OFF)   = 0u;
    JOB_W(JOB_LOGIT1_OFF)   = 0u;
    JOB_W(JOB_CLASS_OFF)    = 0u;
    JOB_W(JOB_CYCLES_OFF)   = 0u;
    JOB_W(JOB_PADSEEN_OFF)  = 0u;
    job_publish();
    JOB_W(JOB_MAGIC_OFF)    = JOB_MAGIC;
}

/* The sequence number of the job waiting, or the current response if there
 * is none. Compare against job_done() rather than testing a flag: a job
 * finishing and the next one arriving are then distinguishable, which with
 * a flag they are not. */
static inline unsigned int job_request(void) { return JOB_W(JOB_REQUEST_OFF); }
static inline unsigned int job_done(void)    { return JOB_W(JOB_RESPONSE_OFF); }
static inline int job_pending(void) { return job_request() != job_done(); }

/*
 * Finish the job numbered `seq`.
 *
 * `seq` is the request value read when the work STARTED, not the one
 * current now. If the PS submits again while CVA5 is mid-inference,
 * setting response to the live request would mark that second job complete
 * with the first job's answer -- and since the image buffer is one page,
 * the second job's image is already in place, so nothing about the result
 * would look wrong.
 */
static inline void job_complete(unsigned int seq, unsigned int status,
                                int l0, int l1, unsigned int cls,
                                unsigned int cycles, unsigned int pad) {
    JOB_W(JOB_STATUS_OFF)  = status;
    JOB_W(JOB_LOGIT0_OFF)  = (unsigned int)l0;
    JOB_W(JOB_LOGIT1_OFF)  = (unsigned int)l1;
    JOB_W(JOB_CLASS_OFF)   = cls;
    JOB_W(JOB_CYCLES_OFF)  = cycles;
    JOB_W(JOB_PADSEEN_OFF) = pad;
    job_publish();
    JOB_W(JOB_RESPONSE_OFF) = seq;
}

#endif /* CVA5_SW_JOB_H */
