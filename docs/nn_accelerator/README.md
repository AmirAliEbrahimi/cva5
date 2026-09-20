# CNN accelerator for CVA5 on the PYNQ-Z2

A quantized CNN generated with [hls4ml](https://github.com/fastmachinelearning/hls4ml),
attached to CVA5 over AXI-Stream, with the same inference implemented in C on
the same core so the two can be compared directly.

## Build it

```bash
make -C tools/nn_accel
```

That is the whole thing: creates a Python venv, trains the network, generates
and synthesises the accelerator, exports the IP, writes the C headers, builds
the benchmark, packages CVA5 as IP, and builds the bitstream. About three
hours, most of it Vivado.

Then program the board and open a serial terminal at 9600 8N1.

Stages run individually if you want them:

```bash
make -C tools/nn_accel venv        # .venv + pinned requirements
make -C tools/nn_accel train       # -> model_6_8.pt
make -C tools/nn_accel precision   # precision/accuracy table (informational)
make -C tools/nn_accel ip          # HLS synthesis + IP export
make -C tools/nn_accel headers     # weights.h + images.h -> examples/sw/
make -C tools/nn_accel mif         # build bench.c -> examples/sw/mem.mif
make -C tools/nn_accel bitstream   # package CVA5, build the SoC
```

Knobs:

```bash
make -C tools/nn_accel CLASS_A=3 CLASS_B=5     # cat vs dog instead
make -C tools/nn_accel PRECISION=12,5 RF=8     # different operating point
make -C tools/nn_accel N_IMAGES=4              # fewer test images
make -C tools/nn_accel JOBS=8                  # Vivado parallelism
make -C tools/nn_accel bitstream BUILD=0       # block design, no implementation
make -C tools/nn_accel clean                   # generated artifacts
make -C tools/nn_accel distclean               # also .venv, datasets, vivado/
```

Requirements: Vivado / Vitis 2025.1 (the free ML Standard edition covers
`xc7z020`), Python 3.10+, a RISC-V GCC, `make`, and a PYNQ-Z2.

## On Windows

The toolchain naturally splits: Vivado and `vitis-run` are Windows binaries,
while `make` and the RISC-V compiler are easiest to get in WSL. Pick one of
these.

**Everything native on Windows.** One `make`, no split. You need two things
Windows does not ship with:

```powershell
winget install GnuWin32.Make          # or: choco install make
```

and a RISC-V compiler — the
[xPack build](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases)
is a zip with no installer. Put both on PATH, then:

```powershell
make -C tools\nn_accel CROSS=riscv-none-elf-
```

The Makefile already picks `.venv\Scripts\python.exe` when `OS=Windows_NT`.

**Split between WSL and PowerShell.** Nothing new to install if you already
have `make` and `riscv64-unknown-elf-gcc` in WSL. The stages divide cleanly:
`mif` needs only the RISC-V toolchain, `ip` and `bitstream` need only Xilinx.

In WSL:

```bash
make -C tools/nn_accel mif        # venv, train, headers, bench.c
```

Then in PowerShell, from the repo root:

```powershell
cd tools\nn_accel
.venv\Scripts\python sweep.py generate --model model_6_8.pt --precision "14,5" --rf 4
cd sw_14_5_rf4 && vitis-run --mode hls --tcl build_prj.tcl && cd ..\..\..
vivado -mode batch -source examples\xilinx\package_as_ip_pynq_z2.tcl
vivado -mode batch -source examples\xilinx\pynq_z2_nn_sys.tcl -tclargs build sw_14_5_rf4 4
```

The venv is shared — WSL and Windows Python both read the same
`tools/nn_accel/.venv` if the repo is on a Windows drive, though you may need
to create it from whichever side you run Python on.

**Calling Windows Vivado from WSL** is possible via `cmd.exe` interop, but only
if the repo lives on `/mnt/c` or `/mnt/d`, and the path translation and
quoting are fiddly enough that the split above is usually less trouble.

## Result

CIFAR-10 frog vs ship, 32x32x3, PYNQ-Z2 at 100 MHz:

| | cycles | time |
|---|---|---|
| Software (CVA5, RV32IM) | 1,530,838 | 15.3 ms |
| Hardware end-to-end | 30,498 | 305 µs |
| — accelerator compute | 6,947 | 69.5 µs (22%) |
| — data movement | 23,551 | 235 µs (77%) |
| **Speedup** | | **50.2x** |
| Speedup if transfer were free | | 220x |

Hardware and software agree on 8/8 images; both reach 7/8 against ground truth
(the miss is an image the model itself is uncertain about, margin 0.03).

The gap between 50x and 220x is the point. The accelerator is 220x faster than
the CPU at the arithmetic, but feeding it over 32-bit AXI-Lite costs 3.4x the
compute time, so on a 129,000-MAC workload the interface — not the compute —
sets the achievable speedup.

For comparison, the e-GPU work reports 3.6–15.1x with 20–24% of runtime in
transfer using a dedicated DMA. Same phenomenon, different operating point.

## Configuration

| | |
|---|---|
| Precision | `ap_fixed<14,5>` — 5 integer bits including sign, 9 fractional |
| Reuse factor | 4 |
| DSP / LUT / FF / BRAM18 | 115 / 30,312 / 17,967 / 35 |
| Occupancy with CVA5 | 63% LUT, 52% DSP |
| Timing | WNS +0.139 ns at 100 MHz |
| Accuracy | 95.9% (float reference 96.1%) |
| Interface | 48-bit AXI-Stream in, 32-bit out |

CVA5 alone measures 3,020 LUT / 4 DSP post-implementation.

## Network

`Conv2d(3,4,3)` -> ReLU -> `MaxPool(4)` -> `Conv2d(4,8,3)` -> ReLU ->
`MaxPool(4)` -> `Linear(32,2)`. **474 parameters.**

That is the ceiling for a 7020 shared with CVA5, not a starting point — 4 and
8 filters at 32x32 already needs 115 DSPs. Widening the conv layers changes
every resource number and requires a fresh sweep.

At this size the network separates colour statistics rather than recognizing
objects, so accuracy depends heavily on the class pair: frog vs ship reaches
96%, cat vs dog (the hardest CIFAR pair) reaches 67%. Same hardware, same
69.5 us — the accelerator's cost does not depend on task difficulty.
`tools/nn_accel/pair_search.py` screens all 45 pairs.

## What lives where

| | |
|---|---|
| `tools/nn_accel/Makefile` | the entry point for everything below |
| `tools/nn_accel/train.py` | CIFAR-10 two-class training |
| `tools/nn_accel/pair_search.py` | screen all 45 class pairs |
| `tools/nn_accel/evaluate.py` | precision choice from measured dynamic range |
| `tools/nn_accel/sweep.py` | HLS generation, 2025.x fixes, IP export |
| `tools/nn_accel/ref_const.py` | host reference for the board self test |
| `tools/nn_accel/export_{weights,images}.py` | C headers for the benchmark |
| `examples/sw/bench.c` | the benchmark, runs on CVA5 |
| `examples/sw/printf.c` | minimal printf — no libc, no float |
| `examples/xilinx/pynq_z2_nn_sys.tcl` | the block design |
| `docs/nn_accelerator/HARDWARE.md` | block design detail, wire format |
| `docs/nn_accelerator/GOTCHAS.md` | failures that produce wrong results silently |

## Changes to the base CVA5

Local memory grows from 4 KB to 64 KB — images and weights do not fit
otherwise. Four numbers have to agree, and all four are already set:

| Where | Setting |
|---|---|
| `examples/xilinx/cva5_wrapper.sv` | `WORDS = 16384` |
| `examples/xilinx/cva5_top.v` | `WORDS = 16384` |
| `examples/sw/link.ld` | `LENGTH = 64K` |
| `examples/sw/Makefile` | `RAM_SIZE ?= 65536` |

`BRAM_ADDR_W` is derived with `$clog2(WORDS)`, so nothing else in the RTL
changes. 64 KB costs about 15 BRAM36 of the ~122 left after the accelerator.

Backward compatible: `make -C examples/sw run` still builds and runs the
original `main.c` demo on Verilator, whose `SimMem` is a sparse map rather
than a fixed array.

`examples/sw/Makefile` gains an `APP` knob — `make mif APP=bench` builds the
benchmark, plain `make mif` still builds the demo.

## Reading the output

```
accelerator: idle=1

img  truth  hw pred / logits          sw pred / logits          cycles hw/sw
  0  frog   frog 2.769/-3.855   frog 2.996/-4.019   30686/1531145
  ...

accuracy      hw 7/8   sw 7/8   agree 8/8
hardware         30498 cycles     304 us
software       1530838 cycles   15308 us
speedup             50.19x
```

The `agree` column is the strongest signal available — two independent
implementations converging is better evidence than either one matching a
reference.

| Symptom | Meaning |
|---|---|
| `idle=0` at startup | `ap_rst_n` polarity wrong |
| TX vacancy timeout | FIFO not accepting — address, or clock/reset unconnected |
| RX timeout | data in, nothing out — `ap_start` not reaching the IP, or `layer9_out` / TLAST not wired |
| logits near zero, constant across images | untrained weights in the IP |
| ~70% accuracy | pixel ordering (NCHW fed to a channels-last port) |
| hw and sw disagree | something wrong in the hardware path |

`GOTCHAS.md` covers each of these, plus the ones that produce no symptom at
all beyond a wrong number.

## Verification already done

- Software inference checked against PyTorch over 24 images: max error 3.95
  Q9 LSB (0.0077 float), argmax agreement 100%
- `printf` output compared character-for-character with glibc for every format
  string used
- Pixel conversion matches a float reference to 0 LSB across all 256 values
- Word stream and chunk boundaries checked against a mock FIFO
