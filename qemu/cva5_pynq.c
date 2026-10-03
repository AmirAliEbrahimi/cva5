/*
 * QEMU model of the CVA5 PYNQ-Z2 system.
 *
 * Mirrors examples/xilinx/cva5_wrapper.sv from the CVA5 repository:
 *
 *   0x4000_0000  128 KiB  main RAM (AXI block RAM); programs run from here
 *   0x5000_0000    4 KiB  Debug Module window (not modelled)
 *   0x6000_0000           AXI UART Lite
 *   0x8000_0000    1 KiB  boot ROM in the CPU's local memory; reset vector
 *
 * The CPU is RV32IM, machine mode only, matching the wrapper's CPU_CONFIG
 * (misa reads 0x40001100 on hardware).
 *
 * Usage:
 *   qemu-system-riscv32 -M cva5-pynq -nographic -kernel app.elf
 *   qemu-system-riscv32 -M cva5-pynq -nographic -bios boot.elf -kernel app.elf
 *   qemu-system-riscv32 -M cva5-pynq -nographic -kernel app.elf -s -S   (gdb)
 *
 * Without -bios the boot ROM holds a two instruction stub that jumps to the
 * application, which is what the real ROM does after printing its banner.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/units.h"
#include "qapi/error.h"
#include "qemu/error-report.h"
#include "target/riscv/cpu.h"
#include "hw/core/boards.h"
#include "hw/core/loader.h"
#include "elf.h"
#include "hw/core/sysbus.h"
#include "hw/char/xilinx_uartlite.h"
#include "hw/misc/unimp.h"
#include "system/address-spaces.h"
#include "system/system.h"

#define CVA5_RAM_BASE   0x40000000
#define CVA5_RAM_SIZE   (128 * KiB)
#define CVA5_DM_BASE    0x50000000
#define CVA5_DM_SIZE    (4 * KiB)
#define CVA5_UART_BASE  0x60000000
#define CVA5_ROM_BASE   0x80000000
#define CVA5_ROM_SIZE   (1 * KiB)

static void cva5_pynq_init(MachineState *machine)
{
    MemoryRegion *sysmem = get_system_memory();
    MemoryRegion *ram = g_new(MemoryRegion, 1);
    MemoryRegion *rom = g_new(MemoryRegion, 1);
    RISCVCPU *cpu;
    DeviceState *uart;
    uint64_t entry;

    /* RV32IM, machine mode only: no A, C, F, D, and no S or U privilege */
    cpu = RISCV_CPU(object_new(machine->cpu_type));
    /*
     * The rv32 base CPU turns on a number of newer extensions by default;
     * switch off everything CVA5 does not implement so that misa and the
     * instruction set match the hardware (misa = 0x40001100, RV32IM).
     */
    static const char *const off[] = {
        "a", "c", "f", "d", "h", "s", "u",
        "zawrs", "zfa", "zfh", "zfhmin", "zba", "zbb", "zbc", "zbs",
        "zicbom", "zicbop", "zicboz", "zicond", "zihintpause", "zihintntl",
        "zksed", "zksh", "zkt", "sstc", "svadu", "svinval", "svnapot", "svpbmt",
    };
    for (int i = 0; i < ARRAY_SIZE(off); i++) {
        object_property_set_bool(OBJECT(cpu), off[i], false, NULL);
    }
    object_property_set_int(OBJECT(cpu), "resetvec", CVA5_ROM_BASE,
                            &error_abort);
    qdev_realize(DEVICE(cpu), NULL, &error_abort);

    /* Main RAM: the debugger loads programs here on hardware */
    memory_region_init_ram(ram, NULL, "cva5.ram", CVA5_RAM_SIZE, &error_fatal);
    memory_region_add_subregion(sysmem, CVA5_RAM_BASE, ram);

    /*
     * Boot ROM. The hardware's local memory is readable and writable by the
     * core, so this is RAM rather than ROM; only its contents are fixed.
     */
    memory_region_init_ram(rom, NULL, "cva5.rom", CVA5_ROM_SIZE, &error_fatal);
    memory_region_add_subregion(sysmem, CVA5_ROM_BASE, rom);

    /* AXI UART Lite. The hardware leaves its interrupt unconnected. */
    uart = qdev_new(TYPE_XILINX_UARTLITE);
    qdev_prop_set_enum(uart, "endianness", ENDIAN_MODE_LITTLE);
    qdev_prop_set_chr(uart, "chardev", serial_hd(0));
    sysbus_realize_and_unref(SYS_BUS_DEVICE(uart), &error_fatal);
    sysbus_mmio_map(SYS_BUS_DEVICE(uart), 0, CVA5_UART_BASE);

    /*
     * The Debug Module's window. QEMU debugs through its own gdbstub, so the
     * module itself is not modelled; mapping it keeps stray accesses visible
     * instead of aborting.
     */
    create_unimplemented_device("cva5.dm", CVA5_DM_BASE, CVA5_DM_SIZE);

    /* Boot ROM contents: -bios, or a stub that jumps to the application */
    if (machine->firmware) {
        if (load_elf(machine->firmware, NULL, NULL, NULL, NULL, NULL, NULL,
                     NULL, 0, EM_RISCV, 1, 0) <= 0) {
            error_report("could not load ROM image '%s'", machine->firmware);
            exit(1);
        }
    } else {
        uint32_t stub[] = {
            cpu_to_le32(0x400002b7),   /* lui t0, 0x40000 */
            cpu_to_le32(0x00028067),   /* jr  t0          */
        };
        rom_add_blob_fixed_as("cva5.rom.stub", stub, sizeof(stub),
                              CVA5_ROM_BASE, &address_space_memory);
    }

    /* The application, as built by tools/cva5-run */
    if (machine->kernel_filename) {
        if (load_elf(machine->kernel_filename, NULL, NULL, NULL, &entry, NULL,
                     NULL, NULL, 0, EM_RISCV, 1, 0) <= 0) {
            error_report("could not load kernel '%s'",
                         machine->kernel_filename);
            exit(1);
        }
        if (entry != CVA5_RAM_BASE) {
            warn_report("kernel entry is 0x%" PRIx64 ", but the boot ROM jumps "
                        "to 0x%x", entry, CVA5_RAM_BASE);
        }
    }
}

static void cva5_pynq_machine_init(MachineClass *mc)
{
    mc->desc = "CVA5 on the PYNQ-Z2 (RV32IM, machine mode)";
    mc->init = cva5_pynq_init;
    mc->min_cpus = 1;
    mc->max_cpus = 1;
    mc->default_cpus = 1;
    mc->default_cpu_type = TYPE_RISCV_CPU_BASE32;
}

DEFINE_MACHINE("cva5-pynq", cva5_pynq_machine_init)
