/*
 * The PS's half of the mailbox: read what CVA5 wrote and hand it to a sink.
 *
 * cva5_ps.h has the layout and the reason this exists; examples/sw/mbox.h is
 * the producer. This is a header of static inlines, and the drain takes the
 * sink as a function pointer, so that test_benches/sw/tb_mbox.c can run the
 * REAL consumer against the REAL producer on a host instead of a second
 * implementation that agrees with neither.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CVA5_PS_MBOX_H
#define CVA5_PS_MBOX_H

#include <stdint.h>
#include "cva5_ps.h"

/*
 * Zero the mailbox header before releasing the core.
 *
 * CVA5 sets it up itself when the magic does not match -- which covers a JTAG
 * load, where nothing clears it -- but it would match after a previous run on
 * this board, and the head and tail left over from that run would make this
 * one's first characters look like a buffer that had already been consumed.
 * Clearing magic here means every PS-loaded run starts from empty.
 */
static inline void mbox_reset(void) {
    ps_wr(MBOX_MAGIC_A, 0u);
    ps_wr(MBOX_HEAD_A, 0u);
    ps_wr(MBOX_TAIL_A, 0u);
    ps_wr(MBOX_DROP_A, 0u);
}

/*
 * Print whatever CVA5 has written, and advance tail past it.
 *
 * Word reads, with the byte picked out here: CVA5 stores single bytes into
 * what is ordinary memory to it, but a byte read from this side would be a
 * narrow AXI transfer for nothing. A word read may catch neighbouring bytes
 * mid-write, which does not matter -- the only byte used is one below head,
 * and CVA5 publishes head after the store.
 *
 * Returns the number of characters printed.
 */
static inline uint32_t mbox_drain(void (*put)(char)) {
    uint32_t head, tail, n = 0;

    if (ps_rd(MBOX_MAGIC_A) != MBOX_MAGIC)
        return 0;

    head = ps_rd(MBOX_HEAD_A);
    tail = ps_rd(MBOX_TAIL_A);

    while (tail != head) {
        uint32_t w = ps_rd(MBOX_DATA_A + (tail & ~3u));
        char c = (char)((w >> (8u * (tail & 3u))) & 0xFFu);

        put(c);

        if (++tail == MBOX_DATA_SIZE)
            tail = 0;
        n++;
    }

    ps_wr(MBOX_TAIL_A, tail);
    return n;
}

#endif /* CVA5_PS_MBOX_H */
