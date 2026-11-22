/*
 * Bringing CVA5 up from the PS: level shifters, halt, load, verify.
 *
 * This was inside cva5_load.c until cva5_demo.c needed the same sequence.
 * It is proven on hardware exactly as written and the order matters in
 * places that are not obvious -- hold the core before writing memory,
 * enable the shifters before touching anything in the PL -- so it exists
 * once rather than in two files that drift.
 *
 * Static inlines in a header because there is no build system on this side:
 * a Vitis application is a directory of sources, and adding a .c means
 * adding it to that project.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CVA5_BOOT_H
#define CVA5_BOOT_H

#include <stdint.h>
#include "xil_printf.h"
#include "cva5_ps.h"
#include "cva5_image.h"

/* The PL's AXI windows are mapped device, non-cacheable, by the standard
 * Zynq-7000 translation table: 0x8000_0000-0xBFFF_FFFF is C=0. So these
 * stores reach the PL in order and nothing needs flushing. If you remap that
 * range cacheable, every write below needs Xil_DCacheFlushRange after it, and
 * the read-back verify would be checking the cache rather than the RAM --
 * which passes while the core executes whatever was there before. */
#define CVA5_RAM ((volatile uint32_t *)(uintptr_t)RAM_BASE)

/* Enable the PS-PL level shifters. The FSBL normally does this; see the note
 * in cva5_ps.h for why it is repeated here. */
static inline void ps_pl_enable(void) {
    ps_wr(SLCR_UNLOCK, SLCR_UNLOCK_KEY);
    ps_wr(SLCR_LVL_SHFTR, SLCR_LVL_SHFTR_ALL);
    ps_wr(SLCR_LOCK, SLCR_LOCK_KEY);
}

static inline void cpu_halt_init(void) {
    ps_wr(GPIO_DIRM_2, ps_rd(GPIO_DIRM_2) | CPU_HALT_BIT);
    ps_wr(GPIO_OEN_2,  ps_rd(GPIO_OEN_2)  | CPU_HALT_BIT);
}

static inline void cpu_halt_set(int held) {
    uint32_t d = ps_rd(GPIO_DATA_2);
    ps_wr(GPIO_DATA_2, held ? (d | CPU_HALT_BIT) : (d & ~CPU_HALT_BIT));
}

/*
 * Writes the image and reads it back.
 *
 * The read-back is not ceremony. This path has an AXI3-to-AXI4 converter, an
 * arbiter shared with the debugger, and a BRAM port shared with the core --
 * and the one failure it is really looking for is the quiet one: level
 * shifters off, or the core still running and writing over the image. Both
 * produce a loader that finishes happily and a core that executes nonsense.
 *
 * Returns the number of words that differ.
 */
static inline uint32_t cva5_load_image(void) {
    uint32_t i, bad = 0;

    for (i = 0; i < cva5_image_words; i++)
        CVA5_RAM[i] = cva5_image[i];

    for (i = 0; i < cva5_image_words; i++) {
        uint32_t got = CVA5_RAM[i];
        if (got != cva5_image[i]) {
            if (bad < 5)
                xil_printf("  mismatch @0x%08x: got 0x%08x exp 0x%08x\r\n",
                           (unsigned)(RAM_BASE + 4u * i), (unsigned)got,
                           (unsigned)cva5_image[i]);
            bad++;
        }
    }
    return bad;
}

/*
 * Hold the core, load, verify, release. Returns 0 on success.
 *
 * The order is the part worth keeping together: the shifters go on first or
 * every write below is swallowed, and the core is held before memory is
 * written or it runs over the image as it arrives. cpu_halt joins ndmreset
 * in the CPU's reset and is absent from the RAM path's, so holding it stops
 * the core without touching the memory being written.
 */
static inline int cva5_bring_up(void) {
    uint32_t bad;

    if (cva5_image_words == 0) {
        xil_printf("the image is empty -- run 'make -C examples/sw ps-image'\r\n");
        return 1;
    }
    if (cva5_image_words * 4u > RAM_SIZE) {
        xil_printf("the image is %u bytes and main memory is %u\r\n",
                   (unsigned)(cva5_image_words * 4u), (unsigned)RAM_SIZE);
        return 1;
    }

    ps_pl_enable();
    cpu_halt_init();
    cpu_halt_set(1);
    mbox_reset();
    xil_printf("cpu held, loading %u words to 0x%08x ...\r\n",
               (unsigned)cva5_image_words, (unsigned)RAM_BASE);

    bad = cva5_load_image();
    if (bad) {
        xil_printf("verify failed: %u of %u words differ -- cpu left held\r\n",
                   (unsigned)bad, (unsigned)cva5_image_words);
        xil_printf("if every word reads back as 0 or as the same value, the\r\n"
                   "PS-PL level shifters are the first thing to check\r\n");
        return 1;
    }

    xil_printf("verified, releasing the cpu (entry 0x%08x)\r\n",
               (unsigned)APP_ENTRY);
    cpu_halt_set(0);
    return 0;
}

/* The drain's sink. CVA5's puts() ends a line with '\n' alone; a terminal on
 * this side wants both. */
static inline void cva5_console_put(char c) {
    if (c == '\n')
        xil_printf("\r\n");
    else
        xil_printf("%c", c);
}

#endif /* CVA5_BOOT_H */
