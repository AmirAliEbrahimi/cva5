# CNN accelerator for CVA5 on the PYNQ-Z2

> **Status on this branch.** The toolchain, the RTL, the block design and a
> driver are all in. `make bitstream` and `make baseline` still fail with a
> message: the SoC is built from `examples/xilinx/pynq_z2_sys.tcl` now, which
> picks the accelerator up automatically when its IP exists. The first
> version's single benchmark program is replaced by two: `examples/sw/accel.c` brings the
> data path up, and `examples/sw/cifar.c` is the demo. Read "Second
> iteration" below before anything else here — the numbers in **Result** are
> from the first version, and the first version is not what this builds.
>
> The second version synthesises, implements and closes: **WNS +0.226 ns** at
> 100 MHz, routed, no failing endpoints, 61.7% slice occupancy. What is not
> measured yet is the end-to-end cycle count with the DMA doing the transfer:
>
> ```
> make -C tools/nn_accel headers     # weights.h, images.h from the model
> make -C examples/sw accel          # the path: PASS accel, pad bytes 0
> make -C examples/sw cifar          # the demo: hardware vs software, timed
> ```
>
> **It works on hardware.** Eight CIFAR images, hardware and software
> agreeing on all eight and both 8/8 against the labels, both logits
> matching in sign, pad counter clean. `PASS cifar`.
>
> **And the full system works.** The PS writes a CIFAR image into CVA5's
> main memory over `M_AXI_GP1`, CVA5 runs the accelerator over it out of
> that memory, and the classification comes back through the job block
> while CVA5's own account of it comes back through the mailbox: **8 of 8
> correct**, 7,093 cycles a job.
>
> The logits are bit-identical to the ones `cifar.c` gets from the same
> images in `.rodata` -- 929,-626 through -1542,1806 on all eight. Two
> entirely different delivery paths, the same numbers, which says the PS's
> byte-at-a-time copy into the image page preserves the layout the DMA
> needs exactly rather than approximately.
>
> On the interrupt (`ACCEL_IRQ=1`) the same eight images give the same
> eight answers in **7,110 cycles** against 7,093 polling. Seventeen cycles
> is what the claim, the complete and the `mip` poll cost; what it buys is
> roughly seven thousand AXI reads the core no longer issues while the
> accelerator works. Polling stays the default, because on this workload
> the core has nothing else to do with that time and a wait that never
> wakes is a worse failure than a busy loop -- but the choice is now
> measured rather than assumed, and the moment CVA5 runs anything
> concurrent it inverts.
>
> **7,097 cycles end to end**, identical on all eight
> images, against 30,498 in the first version and a compute floor of 6,947.
> The transfer has disappeared behind the compute, which is what the second
> version existed to do and within 2% of what "Second iteration" predicted.
> The 77% is gone.
>
> The software baseline is now an honest one. `cifar.c`'s Q9 reference first
> came in at 2.6M cycles against the first version's 1.53M, which made the
> speedup it printed a measurement of unoptimized C. Zero-padding each
> convolution's input instead of testing every tap for the edge brought it
> to **1,013,943 cycles** — below the first version's software as well as
> its own, bit-identical output, 2.6x on the board against 5.1x on the host
> at the same `-Os`. CVA5 recovers half of what a cached machine does from
> the same change, which is what no caches and an in-order pipeline look
> like: the loads this did not remove now dominate.
>
> So the end-to-end figure is **142.9x**, 7,093 cycles against 1,013,943,
> and unlike the first version's 50.2x it is not mostly transfer. The
> comparable claim is that the 220x "if transfer were free" ceiling and the
> measured speedup are now within 1.5x of each other rather than 4.4x.

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

### The result comes back packed the same way, and it bit me

`result_t` is `nnet::array<ap_fixed<14,5>, 2>`: two logits in one 32-bit
beat. The same byte-padding rule that makes the input 24 bits applies on the
way out — each 14-bit element is padded to a 16-bit lane, value in the low
bits, element 0 in `[13:0]` and element 1 in `[29:16]`, the top two bits of
each lane unused.

**So the sign bit is bit 13, not bit 15.** The first version of `cifar.c`
read each lane as an `int16_t`, which is the obvious thing and is wrong: a
negative logit has bit 13 set and bits 15:14 clear, so it comes back as a
large positive number. The argmax of two logits then inverts whenever
exactly one of them is negative, which for a two-class network is most
images — the board classified all eight backwards while the accelerator was
computing them correctly. Nothing about the output says this is happening:
the result is a plausible class, confidently wrong.

`accel_logit()` in `soc.h` does the sign extension, and `cifar.c` checks the
signs of both logits against software separately from the argmax, because
the argmax only compares the two logits with each other and so survives a
decode that mangles both the same way. `test_benches/sw/tb_cifar.c` pins
eight raw lane pairs measured on hardware against their decoded values.

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

### Building it

```sh
make -C tools/nn_accel ip          # train if needed, generate and export the IP
make -C examples/sw ram            # the preload image
```

then, from the repo root in Vivado's Tcl console:

```tcl
source ./examples/xilinx/package_as_ip_pynq_z2.tcl
source ./examples/xilinx/package_openhw_ips.tcl
source ./examples/xilinx/pynq_z2_sys.tcl
```

`pynq_z2_sys.tcl` finds the accelerator IP at
`tools/nn_accel/sw_14_5_rf4/cnn_prj/solution1/impl/ip` and includes it; set
`ACCEL_IP_DIR` for another configuration, or `ACCEL 0` to leave it out. The
SoC builds fine without it, which is the normal case for anyone working on
the processor.

Then Generate Bitstream, and on the board:

```sh
make -C examples/sw accel
```

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
make -C tools/nn_accel demo        # cross-compile the demo and load it
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
make -C tools/nn_accel all        # venv, train, IP, headers
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

| | HLS estimate | implemented |
|---|---|---|
| Precision | `ap_fixed<14,5>` — 5 integer bits including sign, 9 fractional | |
| Input precision | `ap_ufixed<8,0>` (was `ap_fixed<14,5>`) | |
| Reuse factor | 4 | |
| Interface | **24-bit** AXI-Stream in (was 48), 32-bit out | |
| `cnn_0` LUT | 30,352 | **12,388** |
| `cnn_0` FF | 18,915 | **13,765** |
| `cnn_0` DSP | 88 | **115** |
| `cnn_0` block RAM | 33 x18 | **10 x36 + 2 x18** |
| Whole-system occupancy | | **40.8% LUT, 54.1% DSP, 61.7% slices** |
| Timing | | **WNS +0.226 ns at 100 MHz** |
| Accuracy | 95.9% (float reference 96.1%) — **an earlier `model_6_8.pt`**; see above | |

The implemented column is `report_utilization -hierarchical` on the routed
build with the PS, the peripherals and the DMA in it; the per-block table is
in `examples/xilinx/README.pynq_z2.md`. The estimate column is
`cnn_prj/solution1/syn/report/cnn_csynth.rpt`.

**Do not size a network off the HLS estimate.** On this design it is wrong in
both directions and by different factors:

- **LUTs: 2.45x too high.** 30,352 estimated, 12,388 implemented. This is
  what the first version of this file recorded as the accelerator's size,
  which made the design look like it occupied 63% of the device when it
  occupies 41%. A network rejected as not fitting on that basis would have
  fitted with room to spare.
- **DSPs: 24% too low.** 88 estimated, 115 implemented — and DSPs are the
  binding constraint here at 54% of the part. Headroom that exists in the
  estimate does not exist on the die.
- Flops and block RAM land within about 30% and 50% respectively, high in
  both cases.

The 2.45x also disposes of a more interesting story that the numbers seemed
to tell. 30,352 is this project's estimate, with the 24-bit input; the
30,312 recorded for the 48-bit version differs from it by 0.1%. The
accelerator did not shrink when the input narrowed, which is the same
measurement "What the input change cost" reports from the accuracy side:
nothing changed because nothing much depended on it.

### If the accelerator ever stops closing timing

The first version missed by about 70 ps on the conv2 multiplier path -- a
combinational DSP48E1 into a carry chain -- and the note recorded then was
to switch the implementation strategy to
`Performance_ExplorePostRoutePhysOpt`. **That is not what this tree does and
the advice is withdrawn.** The current build closes at WNS +0.226 with the
default strategy, and a design that needs a non-default strategy to close
has no margin left for the next change.

The option worth keeping is in the HLS rather than in implementation: set

```tcl
config_schedule -enable_dsp_full_reg=true
```

in the generated `build_prj.tcl` and re-synthesise. hls4ml writes `false`,
which leaves the DSP48 output unregistered; registering it costs a cycle or
two of latency and some flops, and the design has 81% of its flops free. It
buys margin on exactly the path that was the problem, inside the block that
owns it, without changing how the rest of the SoC is built.

CVA5 alone measured 3,020 LUT / 4 DSP post-implementation. `cva5_top_0` in
this build measures 4,900 LUT / 4 DSP, the difference being the two added AXI
slave ports, the two-level `cva5_ram_mux` tree and the boot ROM — not the core,
which is untouched.

## Network

`Conv2d(3,4,3)` -> ReLU -> `MaxPool(4)` -> `Conv2d(4,8,3)` -> ReLU ->
`MaxPool(4)` -> `Linear(32,2)`. **474 parameters.**

That is the ceiling for a 7020 shared with CVA5, not a starting point — 4 and
8 filters at 32x32 already needs 115 DSPs of the part's 220, and the DSP
count is the one HLS *under*-estimates. Widening the conv layers changes
every resource number and requires a fresh sweep, implemented rather than
estimated.

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
| `tools/nn_accel/export_{weights,images}.py` | `weights.h` and `images.h`, generated into `examples/sw` |
| `examples/sw/accel.c` | brings the data path up: the control block, the DMA, the pad counter |
| `examples/sw/cifar.c` | fixed images: accelerator against the same network in Q9 C, both timed |
| `examples/sw/server.c` | the full system: classifies whatever the PS puts in the job page |
| `examples/ps/cva5_demo.c` | the other half of it — the PS sends images and prints the answers |
| `examples/sw/accel.h` | one inference, shared by `cifar.c` and `server.c` |
| `test_benches/sw/run_job.sh` | the job protocol, both halves, on the host |
| `test_benches/sw/run_cifar.sh` | `cifar.c`'s software reference against an independent model of it — no venv needed |
| `examples/xilinx/axi/cva5_accel_axi.sv` | the DMA, the lane select and the control registers |
| `examples/xilinx/axi/cva5_axis_lane.sv` | 32 → 24 lane select, and the pad counter |
| `examples/xilinx/pynq_z2_sys.tcl` | the block design — one SoC now, accelerator included when its IP exists |
| `docs/nn_accelerator/HARDWARE.md` | **the first version's** block design — kept as a record, builds nothing here |
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
