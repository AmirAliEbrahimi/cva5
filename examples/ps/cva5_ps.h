/*
 * What the Zynq PS needs to know about the CVA5 subsystem in the PL.
 *
 * This is a FOURTH copy of part of the memory map, and it exists for the same
 * reason the OpenOCD config is a third: nothing here can include
 * examples/sw/soc.h. That header is compiled by a RISC-V toolchain and has
 * RISC-V inline assembly in it; this file is compiled by an ARM one, for the
 * processor on the other side of the AXI port. tools/check-soc-map.py reads
 * all four and fails if RAM_BASE ever disagrees.
 *
 * Only the RAM window is here. The PS reaches main memory and nothing else:
 * M_AXI_GP1 goes to cva5_top's s_axi_ext, which is behind cva5_ram_mux and
 * lands on the RAM port. The peripherals are on the crossbar, on the other
 * side of the core, and the PS has no path to them. That is deliberate --
 * see README.pynq_z2.md.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef CVA5_PS_H
#define CVA5_PS_H

#include <stdint.h>

/* Main memory, as the PS sees it -- the same address the core sees, which is
 * what choosing M_AXI_GP1 over GP0 bought. A Zynq-7000 GP master's window is
 * fixed in the PS: GP0 is 0x4000_0000-0x7FFF_FFFF and GP1 is
 * 0x8000_0000-0xBFFF_FFFF (UG585 Table 4-1). */
#define RAM_BASE    0x80000000u
#define RAM_SIZE    0x00020000u   /* 128 KB; cva5_top's WORDS parameter x 4 */

/* crt0.S puts the trap handler at the base of RAM and _start 0x40 above it.
 * The loader does not jump anywhere -- releasing cpu_halt resets the core,
 * which fetches from the boot ROM and ends up here -- but the entry point is
 * worth stating where someone reading a hex dump will want it. */
#define APP_ENTRY   (RAM_BASE + 0x40u)

/*
 * cpu_halt, on EMIO GPIO bit 0.
 *
 * The PS GPIO controller has four banks. Banks 0 and 1 are the 54 MIO pins;
 * banks 2 and 3 are the 64 EMIO lines, so EMIO 0 is bank 2 bit 0 -- global
 * GPIO number 54, which is the number a Linux gpiochip would use. Bare metal
 * addresses the bank directly and the global numbering does not come into it.
 *
 * Register offsets from UG585 Chapter 14. DATA_2 is the output register,
 * DIRM_2 sets direction (1 = output) and OEN_2 enables the driver; a line
 * needs both DIRM and OEN or it reads back as whatever the PL drives.
 *
 * The PS_ prefix on this base address and on PS_SLCR_BASE is not decoration.
 * tools/check-soc-map.py reads every `#define <NAME>_BASE 0x...u` in this
 * file and compares it against the same name in the other three copies of the
 * map; soc.h reserves 0x4000_0000 for a GPIO on CVA5's own bus, so a bare
 * GPIO_BASE here would one day be reported as that window disagreeing with
 * itself.
 */
#define PS_GPIO_BASE 0xE000A000u
#define GPIO_DATA_2 (PS_GPIO_BASE + 0x048u)
#define GPIO_DIRM_2 (PS_GPIO_BASE + 0x284u)
#define GPIO_OEN_2  (PS_GPIO_BASE + 0x288u)
#define CPU_HALT_BIT 0x1u

/*
 * SLCR, for the PS-PL level shifters.
 *
 * The FSBL's ps7_post_config() enables these after the bitstream loads, and
 * in a normal boot that has already happened before main() runs. It is done
 * again in cva5_load.c because when it has NOT happened -- a bitstream loaded
 * from XSCT after the app was already running, say -- every PS write into the
 * PL is swallowed silently and the symptom is a loader that reports success
 * and a core that runs garbage. Setting them twice costs four register writes.
 */
#define PS_SLCR_BASE     0xF8000000u
#define SLCR_UNLOCK      (PS_SLCR_BASE + 0x008u)
#define SLCR_UNLOCK_KEY  0x0000DF0Du
#define SLCR_LOCK        (PS_SLCR_BASE + 0x004u)
#define SLCR_LOCK_KEY    0x0000767Bu
#define SLCR_LVL_SHFTR   (PS_SLCR_BASE + 0x900u)
#define SLCR_LVL_SHFTR_ALL 0xFu

static inline void ps_wr(uint32_t addr, uint32_t val) {
    *(volatile uint32_t *)(uintptr_t)addr = val;
}

static inline uint32_t ps_rd(uint32_t addr) {
    return *(volatile uint32_t *)(uintptr_t)addr;
}

#endif /* CVA5_PS_H */
