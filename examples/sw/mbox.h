/*
 * CVA5's side of the mailbox: one character into a ring in the top of main
 * memory, for the Zynq PS to read out and print.
 *
 * soc.h has the layout and the reason this exists. This is the producer half
 * and nothing else; the consumer is examples/ps/cva5_load.c.
 *
 * It is a header of static inlines rather than a translation unit so that
 * turning the mailbox on is one -D on the command line and no change to any
 * target's source list. puts.c is the only includer.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/* Guard named for this side: examples/ps/cva5_mbox.h is the consumer and
 * uses CVA5_PS_MBOX_H. test_benches/sw/tb_mbox.c includes both, and with
 * one guard name between them the second include silently expanded to
 * nothing. */
#ifndef CVA5_SW_MBOX_H
#define CVA5_SW_MBOX_H

#include "soc.h"

#define MBOX_W(i)    (*(volatile unsigned int *)(MBOX_BASE + 4u * (i)))
#define MBOX_MAGIC_W MBOX_W(0)
#define MBOX_HEAD_W  MBOX_W(1)
#define MBOX_TAIL_W  MBOX_W(2)
#define MBOX_DROP_W  MBOX_W(3)
#define MBOX_DATA    ((volatile unsigned char *)(MBOX_BASE + MBOX_DATA_OFF))

/*
 * Publish a store before the index that makes it visible.
 *
 * CVA5 is in-order and the mailbox is ordinary memory to it, so this may well
 * compile to nothing that matters -- but the reader is on the other side of
 * an AXI port and a mux, and the rule it depends on is that the character is
 * in memory before the head that points past it. `fence w,w` is the statement
 * of that rule; soc.h's dev_fence() is `fence o,i`, which is a different one
 * (device ordering around an I/O read) and not what is wanted here.
 */
static inline void mbox_publish(void) {
#ifdef __riscv
    __asm__ volatile ("fence w,w" ::: "memory");
#else
    /* test_benches/sw/tb_mbox.c compiles this file for the host, to run the
     * ring against the PS's consumer. There is no reordering to stop there;
     * the barrier is the compiler's alone. */
    __asm__ volatile ("" ::: "memory");
#endif
}

/*
 * Initialise on first use rather than at startup.
 *
 * Two things load programs here: the PS, which zeroes magic before it
 * releases the core so that a previous run's buffer is never mistaken for
 * this one's, and OpenOCD, which does not and leaves whatever was in memory.
 * Checking the magic covers both -- after a JTAG load it is garbage and gets
 * set up here; after a PS load it is zero and gets set up here. Magic is
 * written LAST, so a consumer that sees it also sees head and tail.
 */
static inline void mbox_init_once(void) {
    if (MBOX_MAGIC_W == MBOX_MAGIC)
        return;
    MBOX_HEAD_W = 0u;
    MBOX_TAIL_W = 0u;
    MBOX_DROP_W = 0u;
    mbox_publish();
    MBOX_MAGIC_W = MBOX_MAGIC;
}

static inline void mbox_putc(char c) {
    unsigned int h, n;

    mbox_init_once();

    h = MBOX_HEAD_W;
    n = h + 1u;
    if (n == MBOX_DATA_SIZE)
        n = 0u;

    /* Full. Drop the character and count it. Blocking here would make the
     * mailbox change the timing of whatever is being measured -- timer.c
     * reports microseconds -- and a console is not worth that. */
    if (n == MBOX_TAIL_W) {
        MBOX_DROP_W = MBOX_DROP_W + 1u;
        return;
    }

    MBOX_DATA[h] = (unsigned char)c;
    mbox_publish();
    MBOX_HEAD_W = n;
}

#endif /* CVA5_SW_MBOX_H */
