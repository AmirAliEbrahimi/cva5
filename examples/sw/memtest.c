/*
 * Main RAM test, run on the CPU.
 *
 * This is the only thing that reads and writes all 128 KB of main memory. The
 * Hello World demo is 200 bytes and lives at the bottom of it, so without this
 * the great majority of the array is never addressed by anything: the memory
 * is 32 block RAMs, eight deep in the cascade and four wide, and a test that
 * touches only the first few kilobytes proves one row of them.
 *
 * It also covers the only two things between the core and that array --
 * cva5_ram_port's byte-enable and address muxes -- from the core's side.
 * The bus side of the same muxes is covered on the way in, since `make
 * memtest` puts this program there over the debug module's system bus access.
 *
 * Three passes, each aimed at something specific:
 *
 *   1. address-in-address and its inverse over 92 KB, so every word in the
 *      region is written, read back, and then written again with the opposite
 *      value: a stuck bit or a cascade row that decodes wrongly shows up as a
 *      mismatch whichever way it is stuck.
 *   2. byte stores over 4 KB, which is the only way to put partial byte
 *      enables on the RAM from software.
 *   3. a strided walk, 64 interleaved sequences 4 KB apart, so consecutive
 *      accesses land in different cascade rows rather than marching through
 *      one of them.
 *
 * The region is RAM_BASE+0x8000 to RAM_BASE+0x1F000: clear of the program at
 * the base of RAM, and 4 KB below _stack_top at the top of the 128 KB.
 *
 * Build and run with:  make memtest
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdio.h>
#include "soc.h"

/* Clear of the program at the base of RAM, and 4 KB below _stack_top. */
#define TEST_BASE (RAM_BASE + 0x8000u)
#define TEST_END  (RAM_BASE + 0x1F000u)

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
