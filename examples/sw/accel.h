/*
 * One inference on the accelerator, for the programs that just want the
 * answer.
 *
 * This was inside cifar.c until server.c needed the same six lines. It is
 * not a general driver and there is deliberately no abstraction in it: the
 * sequence below is load-bearing in three places and each one has already
 * cost a debugging session, so it exists once.
 *
 * examples/sw/accel.c does NOT use this. Its job is to check each step
 * separately -- that the control block answers, that the DMA stores what is
 * written to it, that a result appears -- and a function that does all of
 * them at once would defeat it.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CVA5_SW_ACCEL_H
#define CVA5_SW_ACCEL_H

#include "soc.h"
#include "mip.h"

#define ACCEL(off) (*(volatile unsigned int *)(ACCEL_BASE + (off)))

/*
 * Run the accelerator over ACCEL_IMG_BYTES at `img`, which must be in main
 * memory and four-byte aligned. Returns 1 and fills the logits, 0 if no
 * result arrived, -1 if a result was already waiting and could not be
 * cleared -- a stuck line, not a slow inference, and wants saying
 * differently -- or -2 if waiting on the interrupt was woken by a
 * source that was not the accelerator. `cycles` and `raw` may be NULL.
 *
 * Three things here are not obvious and all three have been wrong at some
 * point:
 *
 *   The accelerator starts BEFORE the DMA, so the stream has somewhere to go
 *   the moment it moves.
 *
 *   DMA_START carries bit 31 because aximm2s reads the top byte's strobe. A
 *   plain write clears the flags and starts nothing, which on a scope and in
 *   software both look exactly like a DMA that was never connected.
 *
 *   The DMA takes an OFFSET within RAM, not a pointer -- ACCEL_RAM_OFF. Its
 *   address port is only as wide as the window, so a pointer puts the top
 *   bits nowhere and it reads from offset zero, which streams the reset
 *   vector into the accelerator and returns a confident wrong answer.
 */
/*
 * Open PLIC source 3 so an inference can be waited on rather than polled.
 *
 * Call once, before the first accel_infer(..., 1). Everything here outlives
 * a program load: the PLIC resets from rstn alone and never from ndmreset,
 * so an earlier run's enables, priorities and -- the one that bites -- its
 * pending bits are all still set. A pending bit on source 3 would satisfy
 * the very first wait before the accelerator had done anything.
 *
 * Draining is safe at this point because accel_infer() clears any waiting
 * result first, and the accelerator's irq IS result_valid, so the line is
 * already low by the time a claim is taken.
 */
static inline void accel_irq_arm(void) {
    int i;

    PLIC_THRESHOLD = 0u;
    PLIC_PRIORITY(PLIC_SRC_ACCEL) = 1u;
    PLIC_ENABLE = PLIC_ENABLE | (1u << PLIC_SRC_ACCEL);
    /* The claim below reads a different register from the writes above, so
     * without this it can issue before they land -- and a claim taken with
     * the priority still at 0 returns 0 and drains nothing. */
    dev_fence();

    for (i = 0; i < 4; i++) {
        unsigned int stale = PLIC_CLAIM;
        if (!stale)
            break;
        PLIC_CLAIM = stale;
        dev_fence();
    }
}

/*
 * `use_irq` waits on mip.MEIP instead of spinning on ACCEL_STATUS. The
 * inference takes the same 7,093 cycles either way -- what changes is that
 * the core is not reading a register 7,000 times to find out.
 *
 * The claim-read-complete order is not interchangeable. The accelerator's
 * irq is result_valid, so reading ACCEL_RESULT is what lowers the line;
 * completing before that read leaves it high and the PLIC's gateway raises
 * the source again immediately. test_benches/axi/tb_irq_concat.sv checks
 * both orders for exactly this reason.
 */
static inline int accel_infer(const void *img, int *l0, int *l1,
                              unsigned int *cycles, unsigned int *raw,
                              int use_irq) {
    unsigned int claimed = 0u;
    unsigned int t0 = 0, t1 = 0, spins = 0, r;

    /*
     * Throw away a result nobody collected, before starting one of our own.
     *
     * result_valid resets from rstn and nothing else, and loading a program
     * does not assert rstn -- cpu_halt resets the CPU and deliberately not
     * the peripherals. So a result left behind by an earlier run of a
     * different program is still waiting here, and without this the poll
     * below returns it instantly: the right shape of answer, the wrong
     * image, and about 31 cycles instead of 7,100. accel.c in particular
     * ends on a deliberately mis-packed inference.
     *
     * Bounded rather than a while loop. If the line is stuck high -- the
     * output stream holding tvalid, which beats result_read because the
     * clear is the else branch of that assignment -- then draining can
     * never finish, and a wedged accelerator should be reported by the
     * timeout below rather than by hanging here.
     */
    for (spins = 0; spins < 8u; spins++) {
        if (!(ACCEL(ACCEL_STATUS_OFF) & ACCEL_ST_RESULT))
            break;
        (void)ACCEL(ACCEL_RESULT_OFF);
    }
    if (ACCEL(ACCEL_STATUS_OFF) & ACCEL_ST_RESULT)
        return -1;      /* stuck high: not ours to interpret */
    spins = 0;

#ifdef __riscv
    __asm__ volatile (".option push\n.option arch, +zicsr\n"
                      "csrr %0, mcycle\n.option pop" : "=r" (t0));
#endif

    ACCEL(ACCEL_CTRL_OFF)  = ACCEL_CTRL_START;
    ACCEL(DMA_ADDRLO_OFF)  = ACCEL_RAM_OFF(img);
    ACCEL(DMA_LENLO_OFF)   = ACCEL_IMG_BYTES;
    ACCEL(DMA_CONTROL_OFF) = DMA_START;

    if (use_irq) {
        if (mip_wait(MIP_MEIP, 1) < 0)
            return 0;
        claimed = PLIC_CLAIM;
        if (claimed != PLIC_SRC_ACCEL)
            return -2;      /* something else's interrupt, or none */
    } else {
        while (!(ACCEL(ACCEL_STATUS_OFF) & ACCEL_ST_RESULT)) {
            if (++spins > 2000000u)
                return 0;
        }
    }

#ifdef __riscv
    __asm__ volatile (".option push\n.option arch, +zicsr\n"
                      "csrr %0, mcycle\n.option pop" : "=r" (t1));
#endif

    /* One inference is one beat: two ap_fixed<14,5> logits, element zero in
     * the low lane, sign bit at 13. accel_logit() in soc.h says why reading
     * the lane as int16_t gives a plausible wrong answer. */
    r = ACCEL(ACCEL_RESULT_OFF);
    *l0 = accel_logit(r);
    *l1 = accel_logit(r >> 16);
    if (cycles) *cycles = t1 - t0;
    /* The word as it arrived, padding bits and all. Decoded logits cannot
     * be turned back into it, and the padding is what would show a packing
     * change -- it is how the sign-extension bug was identified. */
    if (raw) *raw = r;

    /* After the result read, never before: the line is low now, so the
     * source stays quiet instead of coming straight back. */
    if (use_irq) {
        PLIC_CLAIM = claimed;
        dev_fence();
    }
    return 1;
}

#endif /* CVA5_SW_ACCEL_H */
