# QEMU model of the CVA5 PYNQ-Z2 system

`cva5_pynq.c` is a QEMU machine that mirrors `examples/xilinx/cva5_wrapper.sv`:

| Address       | Size    | What                                               |
|---------------|---------|----------------------------------------------------|
| `0x4000_0000` | 128 KiB | main RAM; programs run from here                    |
| `0x5000_0000` | 4 KiB   | Debug Module window (not modelled)                  |
| `0x6000_0000` |         | AXI UART Lite                                       |
| `0x8000_0000` | 1 KiB   | boot ROM, the reset vector                          |

The CPU is RV32IM, machine mode only, matching the wrapper's `CPU_CONFIG`
(`misa` reads `0x40001100` on hardware).

Programs built by `tools/cva5-run` run unmodified.

## Building

```bash
git clone https://gitlab.com/qemu-project/qemu
cd qemu
cp /path/to/cva5/qemu/cva5_pynq.c hw/riscv/
```

Then register it, by adding to `hw/riscv/meson.build`:

```meson
riscv_ss.add(when: 'CONFIG_CVA5_PYNQ', if_true: files('cva5_pynq.c'))
```

and to `hw/riscv/Kconfig`:

```kconfig
config CVA5_PYNQ
    bool
    default y
    depends on RISCV32
    select XILINX
    select UNIMP
```

and build:

```bash
./configure --target-list=riscv32-softmmu
make -j$(nproc)
```

## Running

```bash
qemu-system-riscv32 -M cva5-pynq -nographic -kernel app.elf
qemu-system-riscv32 -M cva5-pynq -nographic -bios boot.elf -kernel app.elf
qemu-system-riscv32 -M cva5-pynq -nographic -kernel app.elf -s -S   # wait for gdb
```

With `-bios` the real boot ROM runs, banner and all. Without it the ROM holds a
stub that jumps straight to the application.

`tools/cva5-qemu` wraps all of this; see the top-level README.

## What is not modelled

Caches, the Debug Module, timing, and the hls4ml accelerator. QEMU is for
running software quickly; the Verilator harness in `test_benches/debug` runs the
actual RTL when behaviour has to match the hardware.
