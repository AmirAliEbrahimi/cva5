# CNN accelerator for CVA5 on the PYNQ-Z2

> **Status on this branch.** The Python toolchain is ported and the
> accelerator's interface has changed; the driver and the block design have
> not been ported yet and `make mif`, `make bitstream` and `make baseline`
> fail with a message saying so. Read "Second iteration" below before
> anything else here — the numbers in **Result** are from the first one.

## Second iteration: where the 77% went

The first version measured 30,498 cycles end to end, of which 23,551 — 77% —
was CVA5 storing 1,536 words into a memory-mapped stream FIFO by hand, about
15 cycles a word through the peripheral bus. The accelerator itself took
6,947.

The second version deletes that work rather than speeding it up. The image
stays in main memory and a DMA reads it, so the transfer overlaps the compute
instead of preceding it, and the end-to-end figure should land near the
6,947-cycle floor. That is roughly **4x, not the 220x** the "if transfer were
free" line suggests — the compute is still the compute.

Three things change to make it possible.

**`axi_fifo_mm_s` goes.** It only ever existed because CVA5 had no way to be a
DMA target. A DMA master on the RAM port reads main memory directly; the FIFO
and the 23,551 cycles go together.

**The input precision becomes `ap_ufixed<8,0>`.** hls4ml packs io_stream
channels into one AXI beat and pads each element to a byte, so 3 x
`ap_fixed<14,5>` padded 14 to 16 and gave a 48-bit port. 3 x 8 gives 24. This
is the one precision in the network that can change without re-opening
GOTCHAS #3: that is about saturation in logits reaching ±7.3, and the input
is pixel data in [0,1] because `train.py` uses `ToTensor()` alone. Zero
integer bits is the range, not a compromise, and 8 fractional bits resolves
all 256 levels of what is 8-bit source data to begin with.

**Images are stored 4 bytes per pixel.** R, G, B and a zero. That costs 1 KB
an image and buys the entire data path: one pixel is exactly one 32-bit word,
so the DMA's beat and the accelerator's 24-bit beat are 1:1 and what sits
between them is a lane select — `tdata[23:0]` — rather than a width converter
with state. Packed 3-byte pixels put two pixels across three words, which is
where the 3:2 gearbox and GOTCHAS #8's "chunk must divide by 3" came from.
Both stop existing. The image also gets *smaller*: 4096 bytes against 6144.

A consequence worth stating: with `ap_ufixed<8,0>` the pixel byte **is** the
fixed-point value, so nothing converts anything. The DMA moves the image and
no software touches it. The convention is `v/256` everywhere now rather than
`v/255` — in the hardware for free, in `evaluate.py`, and in the driver's Q9
path where `round(v/255*512)` becomes `v << 1`, exact instead of rounded. One
convention in three places, rather than folding a 256/255 correction into
conv1's weights where the exported weights and the hls4ml model could drift
apart.

What is removed from the block design along the way: `axi_fifo_mm_s`,
`axis_dwidth_converter`, `axi_gpio`, `xlconcat`, `xlconstant` — replaced by
the DMA, the lane select, an AXI4-Lite control block of ours, and
`cva5_irq_concat`, which already exists.

### What the input change cost: nothing

Measured on one model in one sitting, `evaluate.py` with and without
`--legacy-input`, which reverts both halves — no `LayerName` override and
`v/255` instead of `v/256`:

| precision | legacy | 24-bit input |
|---|---|---|
| float | 93.00% | 92.90% |
| `ap_fixed<8,5>` | 52.70% | 52.15% |
| `ap_fixed<10,5>` | 58.20% | 56.70% |
| `ap_fixed<12,5>` | 85.80% | 85.50% |
| **`ap_fixed<14,5>`** | **91.75%** | **91.80%** |
| `ap_fixed<16,5>` | 92.60% | 92.60% |

At the operating point the 24-bit input is 0.05 points *ahead*, and on 2000
test samples one image is 0.05 points — so that is one image, which is to say
nothing. At `<16,5>` the two are identical.

The rows below 12 bits move by a point in both directions, but they sit at
52–58% on a 93% task: broken either way, and the ordering between two broken
configurations is not a measurement.

Two things this rules out. The 8-bit input is not a precision loss — it has
*more* fractional bits than `ap_fixed<10,5>` gives the input, and the source
is 8-bit data to begin with. And the `v/256` convention is not a distortion
worth correcting: the float column moves by 0.10 points, which is two images.

**The model is not the one the table below was written against.** That one
records 95.9% against a 96.1% float reference; legacy on *this* `model_6_8.pt`
gives 91.75% against 93.00%. Same class pair, different weights. The
quantization gap is what carries over between models — 0.2 points there, 1.25
here — and comparing accuracy figures across the two would attribute a retrain
to a precision change.

**The measurement that gates all of it** is the stream width hls4ml actually
reports. `sweep.py` now reads it back out of the generated
`firmware/defines.h` and refuses to continue if the input override did not
take — an unknown layer name is silently ignored by hls4ml, and the first
sign would otherwise be a 48-bit port in Vivado an hour later. Run
`make -C tools/nn_accel ip` and it prints the element type and the implied
port width. It says 24, and the generated `firmware/defines.h` reads
`typedef nnet::array<ap_ufixed<8,0>, 3*1> input_t;`.

That check had to be made to run, which is a lesson of its own. The IP's
directory name is `sw_<precision>_rf<rf>` and does not mention the input
precision, so the first attempt found a 48-bit IP already sitting there,
reported "Nothing to be done for 'ip'", and skipped the recipe —
`check_input_type` included. A check inside a recipe is worth nothing when
the recipe does not run. `tools/nn_accel/Makefile` now keeps a `.config`
stamp in that directory holding the precision, the reuse factor and the
input precision, and rewrites it only when one of them changes, so the IP
rebuilds exactly when its configuration moves.


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
| Accuracy | 95.9% (float reference 96.1%) — **an earlier `model_6_8.pt`**; see above |
| Interface | ~~48-bit~~ **24-bit** AXI-Stream in, 32-bit out |

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
