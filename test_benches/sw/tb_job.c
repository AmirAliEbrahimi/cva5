/*
 * The job block, both halves, on the host.
 *
 * CVA5's side (examples/sw/job.h) and the PS's (examples/ps/cva5_ps.h) are
 * two hand-written copies of one layout, compiled by different toolchains
 * for different processors, and nothing at build time on the board brings
 * them together. The mailbox has the same shape and the same test; this is
 * that test for the protocol that carries work rather than characters.
 *
 * Two kinds of disagreement are possible and only one of them is loud.
 *
 * The constants that share a name -- JOB_BASE, JOB_MAGIC, JOB_IMG_BASE --
 * collide at compile time if they ever differ, because both headers are
 * included here and a macro redefined with different tokens is an error
 * under -Werror. Those need no runtime check and get none.
 *
 * The ones that do NOT share a name are the danger: soc.h says
 * JOB_REQUEST_OFF is 0x04, cva5_ps.h says JOB_REQUEST_A is JOB_BASE + 0x04,
 * and if one moves the other is silently still valid C. On the board that
 * is a PS reading a field CVA5 never wrote -- a classification that is
 * whatever was in memory. Those are checked one at a time below.
 *
 * Then the protocol itself, against a real shared page.
 *
 * Run from the repo root: sh test_benches/sw/run_job.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>

#include "soc.h"        /* CVA5's view */
#include "job.h"        /* CVA5's half of the protocol */
#include "cva5_ps.h"    /* the PS's view, written by hand to match */

static int checks = 0, failures = 0;

static void check(const char *what, int ok) {
    checks++;
    if (!ok) { failures++; printf("  FAIL %s\n", what); }
}

static void check_eq(const char *what, unsigned long got, unsigned long want) {
    checks++;
    if (got != want) {
        failures++;
        printf("  FAIL %s: got 0x%lx, want 0x%lx\n", what, got, want);
    }
}

/* The PS addresses the fields absolutely; CVA5 addresses them by offset.
 * This is the pairing that can drift without either side noticing. */
static void check_layout(void) {
    check_eq("magic address",    JOB_MAGIC_A,    JOB_BASE + JOB_MAGIC_OFF);
    check_eq("request address",  JOB_REQUEST_A,  JOB_BASE + JOB_REQUEST_OFF);
    check_eq("response address", JOB_RESPONSE_A, JOB_BASE + JOB_RESPONSE_OFF);
    check_eq("status address",   JOB_STATUS_A,   JOB_BASE + JOB_STATUS_OFF);
    check_eq("logit0 address",   JOB_LOGIT0_A,   JOB_BASE + JOB_LOGIT0_OFF);
    check_eq("logit1 address",   JOB_LOGIT1_A,   JOB_BASE + JOB_LOGIT1_OFF);
    check_eq("class address",    JOB_CLASS_A,    JOB_BASE + JOB_CLASS_OFF);
    check_eq("cycles address",   JOB_CYCLES_A,   JOB_BASE + JOB_CYCLES_OFF);
    check_eq("pad_seen address", JOB_PADSEEN_A,  JOB_BASE + JOB_PADSEEN_OFF);

    /* Every field has to fit in the page, or it lands in the image. */
    check("the header fits in its page", JOB_PADSEEN_OFF + 4u <= JOB_SIZE);

    /* One image, exactly. If these ever differ the PS writes a different
     * number of bytes than the DMA reads, and the accelerator is fed a
     * sliding window of the right-looking thing. */
    check_eq("image page is one image", JOB_IMG_SIZE, ACCEL_IMG_BYTES);

    /* The three reserved pages must sit below the mailbox and above the
     * linker's region, in that order and without overlapping. */
    check("job block is below the image",  JOB_BASE + JOB_SIZE <= JOB_IMG_BASE);
    check("image is below the mailbox",    JOB_IMG_BASE + JOB_IMG_SIZE <= MBOX_BASE);
    check("the mailbox ends main memory",  MBOX_BASE + MBOX_SIZE == RAM_BASE + RAM_SIZE);
    check("stack top is the job block",    STACK_TOP == JOB_BASE);
}

/*
 * The protocol, with both halves running against one page.
 *
 * CVA5's half is called through job.h's inlines, which address JOB_BASE
 * directly, so the page has to BE at JOB_BASE -- the same trick tb_mbox
 * uses. Nothing is mocked: the server-side code under test is the code the
 * board runs.
 */
static void check_protocol(void) {
    unsigned int seq;

    /* Garbage first, the way a JTAG load leaves memory. job_listen() must
     * not trust any of it. */
    memset((void *)(uintptr_t)JOB_BASE, 0xA5, JOB_SIZE);

    check("no magic before listening", ps_rd(JOB_MAGIC_A) != JOB_MAGIC);
    job_listen();
    check_eq("magic after listening", ps_rd(JOB_MAGIC_A), JOB_MAGIC);
    check_eq("request cleared",  ps_rd(JOB_REQUEST_A),  0u);
    check_eq("response cleared", ps_rd(JOB_RESPONSE_A), 0u);
    check("nothing pending at startup", !job_pending());

    /* The PS submits. */
    ps_wr(JOB_REQUEST_A, 1u);
    check("a submitted job is pending", job_pending());
    seq = job_request();
    check_eq("the server sees job 1", seq, 1u);

    job_complete(seq, JOB_OK, -1331, 1786, 1u, 7097u, 0u);
    check("nothing pending once complete", !job_pending());
    check_eq("the PS sees response 1",  ps_rd(JOB_RESPONSE_A), 1u);
    check_eq("status",  ps_rd(JOB_STATUS_A), JOB_OK);
    /* Compared as the 32-bit words they are. Widening one side to long
     * through int32_t sign-extends it and the other does not, which is a
     * trap this test fell into before it caught anything else. */
    check_eq("logit0",  ps_rd(JOB_LOGIT0_A), (uint32_t)-1331);
    check_eq("logit1",  ps_rd(JOB_LOGIT1_A), 1786u);
    check_eq("class",   ps_rd(JOB_CLASS_A),  1u);
    check_eq("cycles",  ps_rd(JOB_CYCLES_A), 7097u);

    /*
     * The hazard job_complete()'s seq argument exists for.
     *
     * The PS submits job 3 while the server is still working on job 2. If
     * the server finished by setting response to whatever request says NOW,
     * job 3 would be marked complete carrying job 2's answer -- and since
     * the image page is one page, job 3's image is already sitting in it, so
     * nothing about the result would look wrong to either side.
     */
    ps_wr(JOB_REQUEST_A, 2u);
    seq = job_request();                 /* the server takes job 2 */
    ps_wr(JOB_REQUEST_A, 3u);            /* the PS submits job 3 meanwhile */
    job_complete(seq, JOB_OK, 5, -5, 0u, 1234u, 0u);
    check_eq("completing 2 does not claim 3", ps_rd(JOB_RESPONSE_A), 2u);
    check("job 3 is still pending", job_pending());
    check_eq("and it is job 3", job_request(), 3u);

    /* An inference that never returned. The status field is the only thing
     * that distinguishes it from a confident answer of class 0. */
    seq = job_request();
    job_complete(seq, JOB_ERR_TIMEOUT, 0, 0, 0u, 0u, 0u);
    check_eq("timeout reported", ps_rd(JOB_STATUS_A), JOB_ERR_TIMEOUT);
    check("the job still completes", !job_pending());
}

int main(void) {
    void *p;

    printf("tb_job: CVA5's job server against the PS's view of the same"
           " memory\n");

    /* job.h's inlines dereference JOB_BASE, so the page must be there. */
    p = mmap((void *)(uintptr_t)JOB_BASE, JOB_SIZE + JOB_IMG_SIZE,
             PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (p != (void *)(uintptr_t)JOB_BASE) {
        printf("FAIL tb_job: could not map the job page at 0x%lx\n",
               (unsigned long)JOB_BASE);
        return 1;
    }

    check_layout();
    check_protocol();

    printf("%s tb_job: %d checks, %d failures\n",
           failures ? "FAIL" : "PASS", checks, failures);
    return failures ? 1 : 0;
}
