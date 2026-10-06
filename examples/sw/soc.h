/*
 * soc.h -- the PYNQ-Z2 CVA5 system's memory map.
 *
 * The single definition of the map: the RTL, this header and the QEMU machine
 * must agree. Peripherals live in one 64 KB window so that the crossbar needs
 * one rule for all of them and the APB decoder only looks at bits [15:12].
 *
 *   0x4000_0000  128 KB  main RAM; programs run from here
 *   0x5000_0000    4 KB  Debug Module (riscv-dbg)
 *   0x6000_0000    4 KB  UART
 *   0x6000_1000    4 KB  SPI master
 *   0x6000_2000    4 KB  interrupt controller
 *   0x6000_3000    4 KB  CLINT (mtime, mtimecmp, msip)
 *   0x8000_0000     1 KB  boot ROM, the reset vector
 */
#ifndef CVA5_SOC_H
#define CVA5_SOC_H

#define RAM_BASE        0x40000000u
#define RAM_SIZE        (128u * 1024u)

#define DM_BASE         0x50000000u

#define PERIPH_BASE     0x60000000u
#define UART_BASE       (PERIPH_BASE + 0x0000u)
#define SPI_BASE        (PERIPH_BASE + 0x1000u)
#define IRQ_BASE        (PERIPH_BASE + 0x2000u)
#define CLINT_BASE      (PERIPH_BASE + 0x3000u)

#define ROM_BASE        0x80000000u
#define ROM_SIZE        1024u

/* CLINT, as in the privileged specification */
#define CLINT_MSIP      (CLINT_BASE + 0x0000u)   /* software interrupt      */
#define CLINT_MTIMECMP  (CLINT_BASE + 0x4000u)   /* 64-bit compare value    */
#define CLINT_MTIME     (CLINT_BASE + 0xBFF8u)   /* 64-bit running counter  */

#define reg32(a)        (*(volatile unsigned int *)(a))

#endif /* CVA5_SOC_H */
