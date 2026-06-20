# Building & running the example program on the CVA5 Verilator sim

Drop-in build wrapper for `examples/sw/main.c` from C source to a running Verilator simulation.

## Files added here
| file        | purpose                                                              |
|-------------|----------------------------------------------------------------------|
| `Makefile`  | front-end: build the program / FPGA image, run the sim, forward RTL targets |
| `link.ld`   | linker script: one 4 KB memory at `0x80000000` (the sim's base addr) |
| `crt0.S`    | startup: stack + bss + call `main`, then the terminate NOP           |
| `puts.c`    | minimal `puts` (toolchain has no libc); writes bytes to the UART     |
| `stdio.h`   | one-line stub so `#include <stdio.h>` in `main.c` resolves           |

## Prerequisites (Ubuntu / WSL)
```bash
sudo apt-get install -y verilator zlib1g-dev gcc-riscv64-unknown-elf
```
- `verilator` + `zlib1g-dev` — to build the sim. zlib's *headers* are required
  because tracing is on (`--trace-fst` pulls in GTKWave's `fstapi.h`).
- `gcc-riscv64-unknown-elf` — bare-metal RISC-V GCC (libc-less; that's why the
  program is built freestanding with its own `_start` and `puts`).

## Usage

Software targets (this makefile):
```bash
cd examples/sw
make            # main.c -> main.elf -> program.hex   (sim image)
make mif        # main.c -> main.elf -> mem.mif        (FPGA block-RAM image, no sim)
make run        # build program.hex + sim, then run the sim
make clean      # remove generated software files
```

Simulator targets (forwarded verbatim to `tools/cva5.mak`, the canonical RTL build):
```bash
make sim             # build the Verilator model -> test_benches/verilator/build/cva5-sim
make lint            # lint the RTL
make lint-full       # lint the RTL with -Wall
make clean-cva5-sim  # remove the simulator build directory
```

`make run` invokes the sim with the four positional arguments it requires:
```
cva5-sim <log_file> <signature_file> <program_file> <trace_file>
```
Outputs: `program_log.txt` (UART capture), `signature.txt`, `trace.fst`
(open with GTKWave / Surfer).

Knobs (override on the command line):

| variable        | default                | effect                                              |
|-----------------|------------------------|-----------------------------------------------------|
| `CROSS`         | `riscv64-unknown-elf-` | toolchain prefix (e.g. `riscv32-unknown-elf-`)      |
| `TRACE_ENABLE`  | `True`                 | `False` builds the sim without FST tracing (faster) |
| `DETERMINISTIC` | `0`                    | `1` for deterministic AXI DDR in the sim            |
| `TRACE`/`LOG`/`SIG` | `trace.fst` / …    | output filenames used by `make run`                 |

e.g. `make sim TRACE_ENABLE=False DETERMINISTIC=1`. The makefile does not
reimplement `tools/cva5.mak` — `sim`, `lint`, `lint-full`, and `clean-cva5-sim`
are delegated to it, so the RTL build keeps a single source of truth.

## How it maps to the hardware
- Program loads at `0x80000000` (`SimMem`/`AXIMem` `STARTING_ADDR`), 4 KB.
- Built for `RV32IM` (`-march=rv32im -mabi=ilp32`).
- The sim stops when the core retires `0x00a00013` (`addi x0,x0,10`), the
  "success termination" NOP `crt0.S` executes after `main()` returns. Without
  it the run never ends (and the buffered log never flushes).

## Notes
- The shipped `mem.mif` is the prebuilt image; `make` regenerates an equivalent
  `program.hex` from source (with clean LF endings).
- Putting your build on the FPGA: `program.hex` and `mem.mif` are the same format
  (one 32-bit word per line, what `$readmemh` and the `cva5_top` `LOCAL_MEM`
  parameter expect). `make mif` regenerates `examples/sw/mem.mif` directly from
  `main.c` with no simulator build; copy that to `vivado/ip_repo/src` and rebuild the Vivado project afterwards to bake
  the new image into block RAM (see `examples/xilinx`).
- This program loops forever printing "Hello World!" with a 1-second busy-wait.
  At RTL-sim speed (slower still with tracing) that's a long wait between lines.
  To iterate faster, shrink `usleep(1000*1000)` or `#define MHZ` in `main.c`, or
  make the loop finite so the run terminates and the log flushes.
