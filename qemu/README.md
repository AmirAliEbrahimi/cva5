# QEMU model of the CVA5 PYNQ-Z2 system

`0001-cva5-pynq-machine.patch` adds a QEMU machine that mirrors
`examples/xilinx/cva5_wrapper.sv`:

| Address       | Size    | What                                      |
|---------------|---------|-------------------------------------------|
| `0x0000_0000` | 4 KiB   | Debug Module window (not modelled)        |
| `0x0200_0000` | 768 KiB | CLINT — `mtime`/`mtimecmp` and `msip`     |
| `0x0C00_0000` | 64 MiB  | PLIC                                      |
| `0x1000_0000` |         | AXI UART Lite, interrupt on PLIC source 1 |
| `0x2000_0000` | 8 MiB   | SPI (not modelled)                        |
| `0x2800_0000` | 4 KiB   | I2C (not modelled)                        |
| `0x8000_0000` | 128 KiB | main RAM; programs run here, entry at +0x40 |

The CLINT and the PLIC are QEMU's own devices rather than anything written
here, because `examples/sw/soc.h` uses the standard SiFive register layout for
both and says so. Two things are deliberately not the QEMU defaults:

- **The CLINT counts at 1 MHz**, not QEMU's 10 MHz default. `cva5_clint_axi`
  divides the 100 MHz system clock so `mtime` ticks once per microsecond,
  which is `soc.h`'s `CLINT_HZ` and what `timer.c`'s arithmetic assumes. A
  timer test against the default would be out by a factor of ten.
- **The mtimer is created without `rdtime`.** The core sets
  `INCLUDE_TIME_CSR` to 0, so `rdtime` traps as an illegal instruction on the
  board. Letting QEMU provide it would make the model more capable than the
  thing it models, which is the divergence `csrs.c` exists to catch.

**The SPI and the I2C are mapped unimplemented, not absent.** Both are real on
the board; modelling them means register-level models of two specific
third-party cores, and without something attached to the pins there would be
nothing for them to talk to. Mapped this way, a program touching them says so
in the QEMU log instead of reading zeros — which, on a status register, looks
exactly like a device reporting itself idle.

PLIC source 2 is the SPI's transfer-complete interrupt on the board. The source
exists here and stays low, so software that enables it waits rather than
receiving a fabricated interrupt.

### The UART's interrupt needs enabling here, and not on the board

`xilinx_uartlite` raises its interrupt only when both the status and control
`IE` bits are set — `(status & IE) && (control & IE)`. `cva5_uart` has no
control register at all: it decodes RX, TX and STAT, drops writes above
`0x08`, and its interrupt follows "receive FIFO not empty" unconditionally.

So a program that wants the UART's interrupt must write `UART_CTRL_IE` to
`UART_BASE + 0x0C`. On hardware that write is dropped and the interrupt would
have arrived anyway; here it is the difference between an interrupt and a
timeout. `examples/sw/plic.c` does it, and `soc.h` carries the definitions.

This one is worth keeping in mind in both directions: QEMU is the stricter of
the two, and matches `axi_uartlite`, so software that works here works on the
board but not necessarily the other way round.

## One change outside the machine

The patch also masks bit 0 of the PLIC's first enable word in
`hw/intc/sifive_plic.c`. Source 0 does not exist in a PLIC — the specification
reserves interrupt ID 0 — and `sifive_plic_write` already refuses a *priority*
write to it on those grounds, but the enable path stored the written word whole.
So `PLIC_ENABLE = 0xFFFFFFFF` left bit 0 set and read it back set, where the
CVA5 PLIC pins it low (checked in `test_benches/axi/tb_plic.sv`). That was the
one failing check when `examples/sw/plic.c` was first run against this machine.

### And the uartlite's interrupt

`xilinx_uartlite`'s interrupt was latched and could not be cleared.
`STATUS_IE` was used as a pending flag: `uart_update_irq` ORed it in whenever
the receive FIFO was non-empty, `uart_update_status` never cleared it — it
masks only bits 0 to 2 — and the transmit path set it on **every character
written**, under a comment reading `/* hax. */`.

So the interrupt asserted on the first byte received or the first character
printed and then stayed asserted for good. `plic.c` was interrupted by its own
`PASS` lines: it drains the FIFO, enables the interrupt, and finds `MEIP`
already set with nothing behind it — which is exactly what it reported.

In the real device STATUS bit 4 reports whether the interrupt is *enabled*, a
mirror of the control bit, and the interrupt follows the receive FIFO. The
patch makes the model do both, so draining the FIFO lowers the interrupt and
bit 4 means what the datasheet says.

### Both of those are outside hw/riscv/

`hw/intc/sifive_plic.c` and `hw/char/xilinx_uartlite.c` are shared with other
machines, and they change more often than a machine file does — so they are the
hunks most likely to need rebasing on a version bump. The PLIC one masks a
reserved bit and is hard to argue with; the uartlite one changes behaviour, and
although the behaviour it replaces is self-described as a hack, it is the hunk
to drop first if a rebase gets ugly.

Dropping the PLIC hunk costs one check in `plic.c`. Dropping the uartlite hunk
costs the whole interrupt half of `plic.c` under QEMU — the register half still
passes, and the board remains the place that half is really tested.

## What is modelled differently, and not patched

**The PLIC's gateway is edge-triggered and has no notion of a claim in
progress.** `sifive_plic_irq_request` sets the pending bit on any assertion
and ignores deassertion entirely, so pending is cleared only by a claim. Two
consequences follow for a level-sensitive source:

- a source that deasserts before its claim is completed stays pending, where
  hardware would have let it go quiet
- the pending bit is set even while a claim is in progress, which the PLIC
  specification says the gateway must not do — it forwards nothing until it
  receives the completion

This is **not** patched, and the reason is worth recording. Making the gateway
level-sensitive would mean clearing pending on deassertion, and a source that
pulses its interrupt — asserting and deasserting before the claim — would then
be lost entirely. That is a real regression for every other machine using this
PLIC, traded for one test here. Tracking the incoming level separately from the
pending bit would fix it properly, and is more than this patch should carry.

`examples/sw/plic.c` works around it instead, by not printing between the claim
and the read of the byte: printing writes the UART, the UART's interrupt is
level sensitive, and the byte is still in the FIFO at that point, so each
character re-asserts a line whose pending bit the model will not let go of. The
comment there says so, because the obvious tidy-up — printing each result as it
is computed — reintroduces it.


The CPU is RV32IM, machine mode only, matching the wrapper's `CPU_CONFIG`
(`misa` reads `0x40001100` on hardware). Programs built by `tools/cva5-run` run
unmodified.

QEMU is not vendored here, and a board model cannot be loaded into a stock
binary: QEMU has no plugin interface for machines, so it must be compiled in.

## Building

```bash
sudo apt install build-essential ninja-build meson pkg-config python3 \
                 libglib2.0-dev libpixman-1-dev libfdt-dev flex bison
tools/build-qemu                 # clone, patch and build into qemu-build/
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

`tools/build-qemu` skips the patch when it is already applied, so **an existing
`qemu-build/` does not pick up a change to the patch on its own**. Reverse the
old one first:

```bash
cd qemu-build
git checkout hw/riscv/Kconfig hw/riscv/meson.build && rm -f hw/riscv/cva5_pynq.c
cd .. && tools/build-qemu
```

Only `cva5_pynq.c` changes, so the rebuild is short.

If `configure` fails on the `dtc` subproject it is trying to fetch it over the
network; `--enable-fdt=system` uses an installed `libfdt` instead, which is
what the `libfdt-dev` above provides.

## Running

`tools/cva5-qemu` finds the binary `tools/build-qemu` produced:

```bash
tools/cva5-qemu examples/sw/hello.c          # build and run
tools/cva5-qemu -g examples/sw/hello.c       # stop and wait for GDB
```

Ctrl-A X quits QEMU. Or drive QEMU directly:

```bash
qemu-system-riscv32 -M cva5-pynq -nographic -kernel app.elf
qemu-system-riscv32 -M cva5-pynq -nographic -kernel app.elf -s -S   # wait for gdb
```

## Debugging

`-g` starts QEMU stopped at the reset vector with its gdbstub on port 1234:

```bash
tools/cva5-qemu -g examples/sw/hello.c
```

Then, in another terminal:

```bash
riscv64-unknown-elf-gdb build/run/app.elf -ex "target remote localhost:1234"
```

```
(gdb) break main
(gdb) continue
(gdb) info registers
(gdb) stepi
(gdb) x/3i $pc
(gdb) continue
```

This is QEMU's own gdbstub, so no OpenOCD and no board: `stepi` from the start
walks the boot ROM before reaching the application. `detach` leaves QEMU
running; Ctrl-A X stops it.

The reset vector is the boot ROM at `0x0001_0000`, as on the board, and `mtvec`
comes up at `RESET_TVEC` — so `info registers pc` at reset reads `0x00010000`,
`stepi` twice lands at `0x80000040`, and a trap reaches `trap_entry`. QEMU has
no property for a CPU's reset `mtvec`, and the CPU's own reset clears it, so the
machine restores it in a reset handler registered after `qdev_realize`.

## What is not modelled

Caches, the Debug Module, the SPI and I2C register sets, and timing. QEMU is
for running software quickly; the Verilator harness in `test_benches/debug`
runs the actual RTL when behaviour has to match the hardware, and the board is
the only place the pins mean anything.
