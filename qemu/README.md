# QEMU model of the CVA5 PYNQ-Z2 system

`0001-cva5-pynq-machine.patch` adds a QEMU machine that mirrors
`examples/xilinx/cva5_wrapper.sv`:

| Address       | Size    | What                                      |
|---------------|---------|-------------------------------------------|
| `0x4000_0000` | 128 KiB | main RAM; programs run from here          |
| `0x5000_0000` | 4 KiB   | Debug Module window (not modelled)        |
| `0x6000_0000` |         | AXI UART Lite                             |
| `0x8000_0000` | 1 KiB   | boot ROM, the reset vector                |

The CPU is RV32IM, machine mode only, matching the wrapper's `CPU_CONFIG`
(`misa` reads `0x40001100` on hardware). Programs built by `tools/cva5-run` run
unmodified.

QEMU is not vendored here, and a board model cannot be loaded into a stock
binary: QEMU has no plugin interface for machines, so it must be compiled in.

## Building

```bash
sudo apt install build-essential ninja-build meson pkg-config python3 \
                 libglib2.0-dev libpixman-1-dev libfdt-dev flex bison
tools/build-qemu                 # clone, patch and build into build/qemu
```

The patch is tested against the tag `tools/build-qemu` pins (`v11.1.2`). For a
different version, `tools/build-qemu --tag vX.Y.Z`; the patch may then need
rebasing.

To apply it to a QEMU tree you already have:

```bash
cd /path/to/qemu
git apply /path/to/cva5/qemu/0001-cva5-pynq-machine.patch
./configure --target-list=riscv32-softmmu && make -j$(nproc)
```

## Running

`tools/cva5-qemu` finds the binary `tools/build-qemu` produced:

```bash
tools/cva5-qemu hello.c          # build and run
tools/cva5-qemu --rom hello.c    # run the real boot ROM first, banner and all
tools/cva5-qemu -g hello.c       # wait for GDB on port 1234
```

Ctrl-A X quits QEMU. Or drive QEMU directly:

```bash
qemu-system-riscv32 -M cva5-pynq -nographic -kernel app.elf
qemu-system-riscv32 -M cva5-pynq -nographic -bios boot.elf -kernel app.elf
qemu-system-riscv32 -M cva5-pynq -nographic -kernel app.elf -s -S   # wait for gdb
```

## What is not modelled

Caches, the Debug Module, timing, and the hls4ml accelerator. QEMU is for
running software quickly; the Verilator harness in `test_benches/debug` runs the
actual RTL when behaviour has to match the hardware.
