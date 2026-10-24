/*
 * SoC memory map -- the one place software gets an address from.
 *
 * The addresses follow CVA6's, so that anything written against a CORE-V
 * system lands in the right place here, and so the choices are someone
 * else's convention rather than ours:
 *
 *   0x0000_0000   4 KB    Debug Module (riscv-dbg: ROM, program buffer, data)
 *   0x0001_0000  64 KB    boot ROM -- the reset vector
 *   0x0200_0000 768 KB    CLINT -- mtime/mtimecmp, software IRQ
 *   0x0C00_0000  64 MB    PLIC                                  [reserved]
 *   0x1000_0000   4 KB    UART
 *   0x1800_0000   4 KB    timer                                 [reserved]
 *   0x2000_0000   8 MB    SPI                                   [reserved]
 *   0x3000_0000  64 KB    Ethernet                              [not planned]
 *   0x4000_0000   4 KB    GPIO                                  [not planned]
 *   0x8000_0000 128 KB    main RAM -- programs run here
 *
 * "reserved" means nothing is there yet and the address is spoken for, so that
 * adding the device later moves nothing. The sizes are CVA6's too, even where
 * ours will be smaller: the window is what is reserved, not the device.
 *
 * CVA6 has a boot ROM at 0x0001_0000 because its main memory is external DDR,
 * which comes up empty -- something has to exist at reset to fill it. Ours is
 * on-chip block RAM that $readmemh initialises from examples/sw/ram.mif at
 * FPGA configuration, so the bitstream could do that job on its own. There is
 * a ROM anyway, and the reset vector points at it rather than at RAM:
 *
 *   - RAM is writable, and `make load` writes it. A reset vector in RAM means
 *     the first instruction after reset is whatever the last load left there,
 *     which during bring-up is the thing being debugged.
 *   - It is two instructions in LUTs -- lui/jalr to APP_ENTRY -- so it costs
 *     essentially nothing and cannot be corrupted by software or by the
 *     debugger.
 *
 * Software does not need ROM_BASE: nothing is callable there and the ROM's
 * only job is the jump. It is here because the map is here.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef CVA5_SOC_H
#define CVA5_SOC_H

#define DM_BASE     0x00000000u
#define ROM_BASE    0x00010000u
#define CLINT_BASE  0x02000000u
/* Standard CLINT layout, as SiFive, CVA6, OpenTitan and QEMU's virt use it.
 * mtime and mtimecmp are each two 32-bit registers, low half first. */
#define CLINT_MSIP_OFF     0x0000u
#define CLINT_MTIMECMP_OFF 0x4000u
#define CLINT_MTIME_OFF    0xBFF8u
/* mtime ticks per second. The hardware prescales the core clock so that one
 * tick is one microsecond at any core frequency -- see
 * examples/xilinx/vendor/cva5_clint.sv, and CLOCK_MHZ in cva5_wrapper.sv,
 * which is the divider. Software should use this rather than the core clock. */
#define CLINT_HZ    1000000u
#define PLIC_BASE   0x0C000000u
/* Standard PLIC layout, the same one QEMU's virt and SiFive parts use. One
 * context (hart 0, M-mode), so the per-context strides do not come up here.
 *
 * Three things have to be true at once before eip reaches mip.MEIP: the source
 * is pending, it is enabled, and its priority is STRICTLY above the threshold.
 * Priority 0 therefore never interrupts, whatever the threshold is.
 *
 * And a level-sensitive source that is still asserted goes straight back to
 * pending when it is completed -- quiet the device first, then write complete,
 * or the same source is handed back on the next claim. The UART's irq is
 * !rx_fifo_empty, so "quiet the device" means read the byte. */
#define PLIC_PRIORITY_OFF(src) (4u * (src))
#define PLIC_PENDING_OFF   0x001000u
#define PLIC_ENABLE_OFF    0x002000u
#define PLIC_THRESHOLD_OFF 0x200000u
#define PLIC_CLAIM_OFF     0x200004u
/* Interrupt sources, numbered from 1. Source 0 does not exist and the hardware
 * pins its priority and enable bit low, as the spec requires. */
#define PLIC_SRC_UART      1u
#define TIMER_BASE  0x18000000u
#define SPI_BASE    0x20000000u

#define RAM_BASE    0x80000000u
#define RAM_SIZE    0x00020000u   /* 128 KB on the board; 4 KB in the sim */

/*
 * The Verilator testbench is a different SoC, not a model of this one: 4 KB of
 * memory, no debug module, and a UART that is one always_ff block which turns
 * any write on the peripheral bus into a character without decoding an address
 * at all. What it does need is for the store to be routed to the peripheral
 * bus in the first place, and that routing comes from PERIPHERAL_BUS_ADDR in
 * core/types_and_interfaces/cva5_config.sv -- upstream's shared EXAMPLE_CONFIG,
 * which this fork deliberately does not modify. That range is
 * 0x6000_0000-0x6FFF_FFFF, so the sim build keeps the old address.
 *
 * tools/cva5.mak and the sim targets in examples/sw/Makefile define CVA5_SIM.
 */
#ifdef CVA5_SIM
  #define UART_BASE 0x60000000u
#else
  #define UART_BASE 0x10000000u
#endif

/* AXI UART Lite register offsets and status bits. cva5_uart keeps
 * axi_uartlite's layout: status is {tx_full, tx_empty, rx_full, rx_valid}, so
 * rx_valid is bit 0 and reading UART_RX_OFF pops the byte. */
#define UART_RX_OFF   0x00u
#define UART_TX_OFF   0x04u
#define UART_STAT_OFF 0x08u
#define UART_RX_VALID (1u << 0)
#define UART_TX_FULL  (1u << 3)

/*
 * Where a trap goes. Nothing in these examples writes mtvec, so this is the
 * core's RESET_TVEC and it is the trap vector for the whole life of the
 * program. It has to be a real address: the Debug Module is at 0x0000_0000
 * now, so leaving the reset value at zero would send every trap into the
 * middle of the debug ROM.
 *
 * crt0.S puts the handler at the base of RAM and _start at RAM_BASE + 0x40.
 * cva5_wrapper's RESET_VEC and fpga_link.ld both depend on that 0x40, and the
 * link script asserts it, so the three cannot drift apart silently.
 */
#define TRAP_ENTRY  RAM_BASE
#define APP_ENTRY   (RAM_BASE + 0x40u)

#endif /* CVA5_SOC_H */
