# Gotchas

Every failure below produced plausible-looking output with no error from any
tool. All were found by comparing against a host reference, which is the
argument for keeping `tools/nn_accel/ref_const.py` and the `agree` column in `examples/sw/bench.c`.

---

## 1. Untrained weights synthesized into IP

**Symptom.** Hardware runs, returns logits, gets chance accuracy. All logits
cluster within 0.04 of each other and barely change between images. A constant
test image gives nearly the same answer as real ones.

**Cause.** The sweep script built `SmallCNN()` fresh and never loaded the
trained `state_dict`. Every synthesized configuration contained PyTorch's
default random initialization.

**Detection.** For `Conv2d(3,4,3)` the default init is uniform over
±1/√27 = ±0.192. Weights sitting neatly inside that band are untrained.

```bash
grep "w2\[108\]" tools/nn_accel/sw_14_5_rf4/firmware/weights/w2.h
```

**Fix.** `tools/nn_accel/sweep.py` now loads the trained model and aborts if the peak
parameter magnitude is under 0.193.

---

## 2. Channels-first data fed to a channels-last port

**Symptom.** ~70% accuracy instead of 96%. Looks exactly like a precision
problem, and survives every precision change.

**Cause.** `ChannelsLastConversion='internal'` leaves the input port expecting
NHWC — one RGB pixel per beat. Feeding an NCHW array delivers pixels in the
wrong order.

**Detection.** `full` + NCHW and `internal` + NHWC give byte-identical results
(mean error 0.00471 in both). `internal` + NCHW gives 0.1379.

**Fix.** `tools/nn_accel/evaluate.py` transposes before `predict()`; `examples/sw/bench.c` streams in
raster order.

---

## 3. Precision needs range *and* resolution, and range is invisible untrained

**Symptom.** `ap_fixed<12,2>`, `<10,2>`, `<8,2>` and `<8,4>` all collapse to
~60% accuracy with mean error ~2.3 — identical across resolutions spanning
64×.

**Cause.** Saturation, not quantization. Trained logits reach ±7.3, so 2
integer bits (±2) and 4 (±8) both clip. When error ignores resolution, the
problem is range.

**Why it was missed.** The precision study initially ran on an untrained
model whose activations were around 0.02. Everything fit in ±2, so only
resolution appeared to matter, and the conclusion "2 integer bits suffice"
generalized from a model with a thousandth of the real dynamic range.

**Detection.** Once range is fixed, error scales cleanly with resolution:
2.57, 2.04, 0.689, 0.157, 0.039 for 3, 5, 7, 9, 11 fractional bits.

**Fix.** `tools/nn_accel/evaluate.py` measures the peak at every layer with forward hooks and
picks integer bits from that, then sweeps total width.

---

## 4. AXI GPIO tri-state resets to input

**Symptom.** `ap_start` never asserts. Data enters the FIFO, the accelerator
never runs, RX times out.

**Cause.** The GPIO TRI register resets to `0xFFFFFFFF` (all inputs) even when
the IP is configured "All Outputs". The Default Tri State Value field greys
out but still resets high.

**Fix.** Software writes the TRI registers in `accel_reset()`.

---

## 5. Broken-out interface pins look connected

**Symptom.** Stream stalls partway. `TDFV` shows the FIFO drained some words
and stopped.

**Cause.** When an interface is wired pin-by-pin instead of as a bundle,
Vivado displays the sub-pins and any signal you missed — usually TREADY —
floats. The diagram looks wired.

**Detection.** If `x_TDATA[47:0]`, `x_TREADY` and `x_TVALID` are listed
separately rather than as a single `x` bundle, the interface connection was
never made.

**Fix.** Connect bundle to bundle. `validate_bd_design` lists what is missing.

---

## 6. Missing TLAST on the receive path

**Symptom.** RX times out even with `layer9_out` correctly wired.

**Cause.** The AXI4-Stream FIFO needs TLAST to complete a packet. `cnn_0` has
no TLAST port, so `RDFO` stays 0 forever.

**Fix.** Tie `axi_str_rxd_tlast` high with a Constant. One inference produces
one 32-bit result, so every beat being its own packet is correct.

---

## 7. FIFO residue between inferences

**Symptom.** ~30,000 cycles per inference becomes 3,300,000. `TDFV` never
returns to full between images.

**Cause.** Leftover words in the TX FIFO carry into the next image, and the
vacancy poll spins waiting for room the accelerator frees only slowly.

**Fix.** Reset both FIFOs at the start of every inference.

---

## 8. Chunk size must divide by 3

48-bit beats and 32-bit words mean two pixels span three words. A transfer
chunk that is not a multiple of 3 splits a pixel across a packet boundary and
desynchronizes the width converter for the rest of the image.

The FIFO depth of 512 is **not** a multiple of 3. `examples/sw/bench.c` uses 384.

---

## 9. Block design does not configure the CVA5 IP instance

**Symptom.** Design builds, closes timing, utilisation looks right, address
map is correct -- and the UART says nothing. Not even a hello-world image
prints.

**Cause.** `create_bd_cell` instantiates `cva5_top` with the IP's *packaged*
defaults. Two of them matter:

- `WORDS` is the local memory depth. The packaged default is whatever the RTL
  held when `package_as_ip_pynq_z2.tcl` last ran, which is not necessarily the
  16384 that `link.ld` and `RAM_SIZE` assume.
- `LOCAL_MEM` defaults to the bare string `"mem.mif"`. `tdp_ram.sv` does
  `$readmemh(PRELOAD_FILE, mem, 0)` with that relative name, and if it does
  not resolve, the block RAM comes up empty. The CPU then executes whatever is
  in an uninitialised BRAM.

Nothing errors. An empty memory synthesises and routes perfectly.

**Detection.** Compare a working block design against the generated one:

```tcl
open_bd_design [get_files soc.bd]
write_bd_tcl -force /tmp/bd.tcl
```

and diff. The working design carries an explicit
`set_property -dict {CONFIG.WORDS ... CONFIG.LOCAL_MEM ...}` on `cva5_top_0`.

**Fix.** `pynq_z2_nn_sys.tcl` now sets both, with `LOCAL_MEM` passed through
`file normalize` so it is absolute, and aborts if `mem.mif` is missing.

---

## 10. Orphan section on the reset vector

**Symptom.** Board completely silent. Not even a hello-world image prints.
Bitstream builds, closes timing, utilisation and address map are correct.

**Cause.** CVA5's `RESET_VEC` is `0x80000000`, so whatever sits at
`ORIGIN(RAM)` is what executes out of reset. Xilinx's `riscv32-xilinx-elf`
toolchain defaults to `--build-id`, emitting an ALLOC+LOAD
`.note.gnu.build-id`. The linker script did not mention `.note*`, so it was an
orphan section -- and the linker places orphans before `.text`:

```
0 .note.gnu.build-id 00000024  80000000  80000000  ... ALLOC, LOAD
1 .text              000000c8  80000024  80000024
```

The core executes 36 bytes of build-ID hash with no stack pointer and no
`.bss` clear, then falls into `_start`.

The Ubuntu `riscv64-unknown-elf` toolchain does not default to `--build-id`,
which is why this only appears with the Vitis-bundled compiler.

**Detection.**

```bash
riscv64-unknown-elf-nm main.elf | grep -w _start     # must be 80000000
riscv64-unknown-elf-objdump -h main.elf | head
```

**Fix.** `link.ld` discards `.note*`, `.comment` and `.riscv.attributes`, and
asserts `_start == ORIGIN(RAM)` so a recurrence is a link error rather than a
silent hang. `CFLAGS` also passes `-Wl,--build-id=none`.

---

## 11. Vivado 2025.1 toolchain changes

- `vitis_hls` batch binary is gone. Use `vitis-run --mode hls --tcl`.
- hls4ml emits `config_array_partition -maximum_size`, which 2025.1 renamed to
  `-complete_threshold`. hls4ml wraps it in `catch{}`, so it fails **silently**
  and the partition threshold is never applied. `tools/nn_accel/sweep.py` patches it.
- Default implementation strategy misses timing by ~70 ps. Use
  `Performance_ExplorePostRoutePhysOpt`.

---

## 12. No printf, no FPU

`examples/sw/puts.c` provides only `puts()`, and the build is `-nostdlib`.
`examples/sw/printf.c` adds `%d %u %s %c %x %%` with width, `-` and `0` flags.

CVA5 is RV32IM. Any float would pull in soft-float, which would both bloat the
image and distort the cycle counts the benchmark exists to measure. Everything
is Q9 fixed point — the same scale as `ap_fixed<14,5>`, so hardware and
software logits are directly comparable.
