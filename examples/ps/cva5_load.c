/*
 * Load a CVA5 program from the Zynq PS, bare metal.
 *
 * What OpenOCD's load_program does over JTAG, done by the ARM core over
 * M_AXI_GP1 instead: hold the CPU, write the image into main memory, read it
 * back, release the CPU. No JTAG cable, no host.
 *
 * Build it as a Vitis application on ps7_cortexa9_0 against the XSA this
 * design exports. The image comes from cva5_image.c, which is generated --
 * see cva5_image.h.
 *
 * The only BSP dependency is xil_printf.h, for the report. Everything else is
 * register writes through cva5_ps.h, which is deliberate: a loader that only
 * needs a stack and a UART can be dropped into an FSBL hook or a second-stage
 * boot image without carrying a BSP's worth of drivers with it.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdint.h>
#include "xil_printf.h"
#include "cva5_ps.h"
#include "cva5_mbox.h"
#include "cva5_image.h"

/* The PL's AXI windows are mapped device, non-cacheable, by the standard
 * Zynq-7000 translation table: 0x8000_0000-0xBFFF_FFFF is C=0. So these stores
 * reach the PL in order and nothing needs flushing. If you remap that range
 * cacheable, every write below needs Xil_DCacheFlushRange after it, and the
 * read-back verify would be checking the cache rather than the RAM -- which
 * passes while the core executes whatever was there before. */
static volatile uint32_t *const ram = (volatile uint32_t *)(uintptr_t)RAM_BASE;

/* Enable the PS-PL level shifters. The FSBL normally does this; see the note
 * in cva5_ps.h for why it is repeated here. */
static void ps_pl_enable(void) {
    ps_wr(SLCR_UNLOCK, SLCR_UNLOCK_KEY);
    ps_wr(SLCR_LVL_SHFTR, SLCR_LVL_SHFTR_ALL);
    ps_wr(SLCR_LOCK, SLCR_LOCK_KEY);
}

static void cpu_halt_init(void) {
    ps_wr(GPIO_DIRM_2, ps_rd(GPIO_DIRM_2) | CPU_HALT_BIT);
    ps_wr(GPIO_OEN_2,  ps_rd(GPIO_OEN_2)  | CPU_HALT_BIT);
}

static void cpu_halt_set(int held) {
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
static uint32_t load_image(void) {
    uint32_t i, bad = 0;

    for (i = 0; i < cva5_image_words; i++)
        ram[i] = cva5_image[i];

    for (i = 0; i < cva5_image_words; i++) {
        uint32_t got = ram[i];
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

/* The drain's sink. CVA5's puts() ends a line with '\n' alone; a terminal on
 * this side wants both. */
static void console_put(char c) {
    if (c == '\n')
        xil_printf("\r\n");
    else
        xil_printf("%c", c);
}

int main(void) {
    uint32_t bad;
    uint32_t dropped_seen = 0;

    xil_printf("\r\nCVA5 loader\r\n");

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

    /* Hold the core before writing. cpu_halt joins ndmreset in the CPU's
     * reset and is absent from the RAM path's, so this stops the core without
     * touching the memory the next lines are about to write. */
    cpu_halt_set(1);
    mbox_reset();
    xil_printf("cpu held, loading %u words to 0x%08x ...\r\n",
               (unsigned)cva5_image_words, (unsigned)RAM_BASE);

    bad = load_image();
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

    /*
     * Then be its console.
     *
     * This is the mailbox's whole point: CVA5's UART is on PMOD JA and the
     * board's one USB-UART belongs to this processor, so without this the
     * program's output has nowhere to go unless an FTDI adapter is attached.
     * A program built WITHOUT -DCVA5_MBOX never sets the magic and nothing is
     * printed below -- which is not an error, just a program whose output is
     * going to the UART only.
     *
     * No exit condition, because a console does not have one. The PS reads
     * main memory while the core runs it; cva5_ram_mux arbitrates the two,
     * one owner at a time, and a read here costs the core one transaction.
     */
    xil_printf("draining CVA5's output:\r\n");
    for (;;) {
        uint32_t drop;

        mbox_drain(console_put);

        /* Reported rather than hidden: a full ring means CVA5 outran this
         * loop and the output on screen has a hole in it. */
        drop = ps_rd(MBOX_MAGIC_A) == MBOX_MAGIC ? ps_rd(MBOX_DROP_A) : 0u;
        if (drop != dropped_seen) {
            xil_printf("\r\n[%u characters dropped -- the ring filled]\r\n",
                       (unsigned)drop);
            dropped_seen = drop;
        }
    }
}
