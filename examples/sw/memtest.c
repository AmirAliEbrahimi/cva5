/*
 * Main RAM test, run on the CPU.
 *
 * This is the only test that exercises the cached path -- the core's
 * mem_interface, through cva5_axi_cut and the crossbar's s_axi_mem port, to
 * the memory. Everything reachable over JTAG goes through the debug module's
 * system bus access instead, which takes a different crossbar port entirely,
 * and the Hello World demo is 200 bytes: a handful of cache lines, no
 * writebacks worth the name.
 *
 * Three passes, each aimed at something specific:
 *
 *   1. address-in-address and its inverse over 92 KB. The D$ is 8 KB,
 *      direct-mapped with 16-byte lines, so a walk this size evicts every
 *      line many times over -- burst line fills in one direction and dirty
 *      writebacks in the other.
 *   2. byte stores over 4 KB, which is the only way to put partial wstrb
 *      on the bus from software.
 *   3. a strided walk, 64 interleaved sequences 4 KB apart, so consecutive
 *      accesses always miss and the fill/writeback pair never gets to batch.
 *
 * The region is 0x40008000-0x4001F000: clear of the program at the base of
 * RAM, and 4 KB below _stack_top at 0x40020000.
 *
 * Build and run with:  make memtest
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdio.h>

#define TEST_BASE 0x40008000u
#define TEST_END  0x4001F000u

static void puthex(unsigned v) {
    char b[11];
    b[0] = '0'; b[1] = 'x';
    for (int i = 0; i < 8; i++) {
        unsigned n = (v >> ((7 - i) * 4)) & 0xF;
        b[2 + i] = n < 10 ? ('0' + n) : ('a' + n - 10);
    }
    b[10] = 0;
    puts(b);
}

int main(void) {
    volatile unsigned *p;
    volatile unsigned char *b;
    unsigned errs = 0;

    /* 1. address-in-address, then inverted: line fills and writebacks */
    for (unsigned pass = 0; pass < 2; pass++) {
        unsigned mask = pass ? 0xFFFFFFFFu : 0u;
        for (p = (volatile unsigned *)TEST_BASE; (unsigned)p < TEST_END; p++)
            *p = (unsigned)p ^ mask;
        for (p = (volatile unsigned *)TEST_BASE; (unsigned)p < TEST_END; p++)
            if (*p != (((unsigned)p) ^ mask)) {
                if (errs < 5) { puts("mismatch at"); puthex((unsigned)p); puthex(*p); }
                errs++;
            }
    }

    /* 2. byte stores: partial wstrb on the bus */
    for (p = (volatile unsigned *)TEST_BASE; (unsigned)p < TEST_BASE + 4096; p++)
        *p = 0;
    b = (volatile unsigned char *)TEST_BASE;
    for (unsigned i = 0; i < 4096; i++) b[i] = (unsigned char)(i & 0xFF);
    for (unsigned i = 0; i < 4096; i++)
        if (b[i] != (unsigned char)(i & 0xFF)) {
            if (errs < 5) { puts("byte mismatch at"); puthex(TEST_BASE + i); }
            errs++;
        }

    /* 3. strided walk: every access misses */
    for (unsigned s = 0; s < 64; s++)
        for (p = (volatile unsigned *)(TEST_BASE + 4 * s); (unsigned)p < TEST_END; p += 1024)
            *p = (unsigned)p + s;
    for (unsigned s = 0; s < 64; s++)
        for (p = (volatile unsigned *)(TEST_BASE + 4 * s); (unsigned)p < TEST_END; p += 1024)
            if (*p != (unsigned)p + s) {
                if (errs < 5) { puts("stride mismatch at"); puthex((unsigned)p); }
                errs++;
            }

    if (errs) { puts("FAIL errors:"); puthex(errs); }
    else      { puts("PASS memtest"); }

    while (1) { }
    return 0;
}
