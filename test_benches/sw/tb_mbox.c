/*
 * The mailbox ring, both halves, on the host.
 *
 * CVA5's producer (examples/sw/mbox.h) and the PS's consumer
 * (examples/ps/cva5_mbox.h) are compiled here UNMODIFIED and run against each
 * other. They are the only two pieces of this design that have to agree on a
 * layout without a compiler able to check it: one is built by a RISC-V
 * toolchain against examples/sw/soc.h, the other by an ARM toolchain against
 * examples/ps/cva5_ps.h, and the two headers are separate copies. A
 * disagreement about where `tail` lives, or about which way the wrap goes,
 * produces garbage on a console and nothing else -- no build error on either
 * side, and no way to tell it from a broken AXI path.
 *
 * The trick that makes this possible: both halves address the mailbox through
 * a literal, MBOX_BASE, so the test maps a page AT that address with
 * MAP_FIXED rather than parameterising the production code for the test's
 * benefit. 0x8001F000 is an ordinary user address on Linux and the mailbox is
 * exactly one page.
 *
 * What is NOT tested here: anything about the AXI path, the arbitration, or
 * the real concurrency between a running core and a polling PS. The producer
 * and consumer are called from one thread in a chosen order. What is tested
 * is that they agree.
 *
 * Build and run: sh test_benches/sw/run_mbox.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include "mbox.h"       /* CVA5's producer, examples/sw */
#include "cva5_mbox.h"  /* the PS's consumer, examples/ps */

static int checks, failures;

static void ck(const char *what, int ok) {
    checks++;
    if (!ok) {
        failures++;
        printf("FAIL: %s\n", what);
    }
}

/* The drain's sink, standing in for the PS console. */
static char sink[64 * 1024];
static unsigned sink_len;

static void sink_put(char c) {
    if (sink_len < sizeof sink - 1)
        sink[sink_len++] = c;
    sink[sink_len] = '\0';   /* terminate as we go: the strcmp checks below
                              * otherwise read whatever a previous, longer
                              * case left behind -- which is how this test
                              * first "failed" */
}

static void sink_clear(void) {
    sink_len = 0;
    sink[0] = '\0';
}

static void produce(const char *s) {
    while (*s)
        mbox_putc(*s++);
}

int main(void) {
    void *page = mmap((void *)(uintptr_t)MBOX_BASE, MBOX_SIZE,
                      PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    unsigned i;

    if (page != (void *)(uintptr_t)MBOX_BASE) {
        printf("FAIL: could not map a page at MBOX_BASE (0x%08x)\n",
               (unsigned)MBOX_BASE);
        return 1;
    }

    /* The two headers' idea of the layout. If these differ the rest is
     * meaningless, so they are checked first and by name. */
    ck("both halves agree on MBOX_DATA_SIZE",
       MBOX_DATA_SIZE == MBOX_SIZE - MBOX_DATA_OFF);
    ck("the consumer's head address is the producer's head word",
       MBOX_HEAD_A == MBOX_BASE + 4u);
    ck("the consumer's tail address is the producer's tail word",
       MBOX_TAIL_A == MBOX_BASE + 8u);
    ck("the consumer's dropped address is the producer's dropped word",
       MBOX_DROP_A == MBOX_BASE + 0xCu);
    ck("the data area starts past the four header words",
       MBOX_DATA_OFF >= 16u);

    /* A PS-loaded run starts here: the loader clears the header, the program
     * runs and writes, the loader drains. */
    memset(page, 0xA5, MBOX_SIZE);      /* whatever the last run left */
    mbox_reset();

    sink_clear();
    ck("an empty mailbox drains nothing", mbox_drain(sink_put) == 0);

    produce("hello\n");
    sink_clear();
    ck("six characters come back", mbox_drain(sink_put) == 6);
    ck("and they are the ones that went in", strcmp(sink, "hello\n") == 0);
    ck("the producer set the magic", MBOX_MAGIC_W == MBOX_MAGIC);
    ck("nothing was dropped", MBOX_DROP_W == 0);

    /* Drained twice with nothing in between. */
    sink_clear();
    ck("a second drain finds nothing", mbox_drain(sink_put) == 0);

    /* Interleaved: write a little, read a little, around the wrap. The ring
     * is MBOX_DATA_SIZE bytes and this pushes several times that through it,
     * so every byte of the data area is used and the wrap is crossed
     * repeatedly -- which is where an off-by-one in either half shows up. */
    {
        unsigned total = 0, got = 0;
        char expect[8];
        int ok = 1, bounded = 1;

        for (i = 0; i < 4u * MBOX_DATA_SIZE; i++) {
            char c = (char)('a' + (i % 26u));
            mbox_putc(c);
            total++;

            /* The invariant, checked on every character rather than at the
             * end. An index that leaves the data area walks off the page on
             * the next access, and a test that dies of a segfault or spins
             * forever has told you far less than one that names the rule it
             * broke. Both of those were real outcomes while mutating this.
             *
             * Both sides' views are checked, not one: the two halves name
             * these words from separate headers, so a consumer pointed at the
             * wrong word is exactly the failure worth catching and the
             * producer's own view would look fine throughout. */
            if (MBOX_HEAD_W >= MBOX_DATA_SIZE || MBOX_TAIL_W >= MBOX_DATA_SIZE
                || ps_rd(MBOX_HEAD_A) >= MBOX_DATA_SIZE
                || ps_rd(MBOX_TAIL_A) >= MBOX_DATA_SIZE) {
                bounded = 0;
                break;
            }

            if ((i % 7u) == 6u) {       /* drain in chunks of seven */
                sink_clear();
                got += mbox_drain(sink_put);
            }
        }
        ck("head and tail stay inside the data area, every character", bounded);
        if (!bounded) {
            printf("      producer sees head=%u tail=%u;"
                   " consumer sees head=%u tail=%u; data area is %u bytes\n",
                   MBOX_HEAD_W, MBOX_TAIL_W,
                   (unsigned)ps_rd(MBOX_HEAD_A), (unsigned)ps_rd(MBOX_TAIL_A),
                   (unsigned)MBOX_DATA_SIZE);
            goto done;
        }
        sink_clear();
        got += mbox_drain(sink_put);

        ck("interleaved writing and draining loses nothing",
           got == total && MBOX_DROP_W == 0);

        /* The last seven characters are the tail of the run, in order. */
        for (i = 0; i < 7u && i < sink_len; i++) {
            unsigned idx = (4u * MBOX_DATA_SIZE) - sink_len + i;
            expect[i] = (char)('a' + (idx % 26u));
            if (sink[i] != expect[i])
                ok = 0;
        }
        ck("and the last characters are in order", ok);
    }

    /* Overflow. Fill the ring with nobody draining and the producer must drop
     * rather than overwrite what the consumer has not read -- and must say
     * how many. */
    mbox_reset();
    sink_clear();
    for (i = 0; i < MBOX_DATA_SIZE + 100u; i++)
        mbox_putc('x');

    ck("a full ring drops rather than overwrites",
       MBOX_DROP_W == 101u);
    ck("and what is left is one byte short of the data area, which is the\n"
       "      price of telling empty from full",
       mbox_drain(sink_put) == MBOX_DATA_SIZE - 1u);
    ck("every surviving character is intact",
       sink_len == MBOX_DATA_SIZE - 1u && sink[0] == 'x'
       && sink[sink_len - 1] == 'x');

    /* After a JTAG load nothing clears the header, so the producer has to
     * recognise the garbage and start over by itself. */
    memset(page, 0x5A, MBOX_SIZE);
    sink_clear();
    ck("a garbage header is not mistaken for a mailbox",
       mbox_drain(sink_put) == 0);
    produce("jtag\n");
    sink_clear();
    ck("and the producer initialises it on first use",
       mbox_drain(sink_put) == 5 && strcmp(sink, "jtag\n") == 0);

done:
    printf("%s tb_mbox: %d checks", failures ? "FAIL" : "PASS", checks);
    if (failures)
        printf(", %d failed", failures);
    printf("\n");
    return failures != 0;
}
