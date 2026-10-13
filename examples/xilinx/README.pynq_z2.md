# CVA5 on the PYNQ-Z2

Builds a CVA5 (RV32IM) soft SoC that runs the `examples/sw` demo program from
block RAM inside the core, with an AXI UART Lite for console output. A single slide switch
(SW0) drives the system reset. This mirrors the existing Nexys A7 example.

## Files (in `examples/xilinx/`)

| file                          | purpose                                                                 |
|-------------------------------|-------------------------------------------------------------------------|
| `package_as_ip_pynq_z2.tcl`   | packages the CVA5 core as a Vivado IP into `./vivado/ip_repo`            |
| `pynq_z2_sys.tcl`             | builds the SoC block design (clock, reset, CVA5, AXI UART Lite) + XDC    |
| `pynq_z2_cva5.xdc`            | pin constraints — reset switch and PMOD UART                            |

## Open-hardware AXI blocks

Two of the Xilinx AXI IPs are replaced with pulp-platform blocks, both
measured to cost nothing against the all-Xilinx baseline of **WNS +0.107** at
100 MHz on the `xc7z020clg400-1`:

| Xilinx IP | replacement | result |
|-----------|-------------|--------|
| `axi_register_slice` | `cva5_axi_cut` (pulp `axi_cut`) | **+0.122** (baseline +0.107) |
| `axi_interconnect`   | `cva5_axi_xbar` (pulp `axi_xbar`) | same build |
| `axi_bram_ctrl` + `blk_mem_gen` | *kept* — see below | — |
| `clk_wiz` | *kept* — the MMCM is a hard block | — |

### Memory

Main memory is 128 KB of **true dual-port block RAM inside `cva5_top`**,
inferred from `tdp_ram.sv` — no `axi_bram_ctrl`, no `blk_mem_gen`, no Xilinx
memory IP at all. Instruction fetch owns one port and load/store the other, so
both are a single cycle away and **neither cache is enabled**.

That is how upstream configures this core, and it is how lowRISC's
ibex-demo-system is built: a `ram_2p` with fetch on one port and everything
else on the other. The caches were ours, and they were expensive. The data
cache sat in front of on-chip RAM that was already a few cycles away and paid
for it with the worst path in the SoC — tag RAM output, into the hit
comparator's carry chain, into the store queue's attribute RAM *address*. The
register slice on the cached path, itself load bearing at 0.321 ns, existed
only to cut the burst path the instruction cache created. All of it is gone.

The reset vector is the bottom of RAM, so there is no separate boot ROM
either. `make ram` builds the preload image the bitstream bakes in. It is a park loop
that prints nothing, so a freshly programmed board is silent and the UART
carries only what you load over JTAG.

The debugger still has to reach that RAM to load programs, and the local
memory interface has no handshake — the core raises `en` and expects its data
next cycle, with no way to be told to wait. So `cva5_ram_port` sits in front
of the load/store port and gives the debugger only the cycles the core leaves
idle. The core can never be stalled by it; the debugger can always wait, since
SBA is paced by JTAG. During `make load` the core is in reset and every cycle
is idle.

`cva5_ram_port` is a full AXI4 slave rather than AXI4-Lite, because the
crossbar's RAM port is AXI4 and a block design will not join the two
protocols. SBA only ever issues single beats, but handling bursts costs little
and is what a future master on that port would want.

The crossbar still has its third slave port, unconnected now that the cached
master is gone. Shrinking it is a separate change, deliberately not folded in
here so this one can be measured on its own.

Build order from the repository root:

```tcl
# make -C examples/sw ram                            ;# ram.mif, baked into the IP
source ./examples/xilinx/package_as_ip_pynq_z2.tcl   ;# CVA5 core as IP
source ./examples/xilinx/package_openhw_ips.tcl      ;# the two AXI blocks
source ./examples/xilinx/pynq_z2_sys.tcl             ;# the SoC block design
```

Each wrapper under `axi/` presents flat AXI ports so Vivado's IP packager
infers the bus interfaces; the pulp modules underneath take SystemVerilog
structs, which a block design cannot carry. `tools/vendor-pulp-sv.py`
generates the include-free copies in `vendor/`, because the IP packager
flattens sources and the pulp `` `include `` paths then cannot resolve.
`tools/vendor-pulp-sv.py --check` fails if they are stale.

The crossbar's peripheral port converts AXI4 to AXI4-Lite with ZipCPU's
formally verified `axi2axilite`. pulp's `axi_to_axi_lite` was tried first and
missed 100 MHz by 3.2 ns: its burst splitter, ID queue and atomic filter are
built for a general AXI port, none of which a window carrying single-beat
register accesses can reach.

From the crossbar onwards the address decode lives in the RTL, as parameters
taken from `examples/sw/soc.h`, not in the Vivado address editor. An address
in no window, or a master reaching for a slave it is not wired to, returns a
DECERR instead of landing somewhere unexpected.

Validated on hardware, not just in simulation: boot banner over the UART
(CPU to the peripheral port), `make load` (debugger to RAM), a 128 KB walk
over system bus access with zero errors, a deliberate unmapped read returning
`sberror=2` rather than hanging, a full GDB session (reset, load, breakpoint,
single step, register and memory access, asynchronous halt), and `make
memtest` passing -- the last of which is the only test that touches the
cached path through `cva5_axi_cut`.

Run `./test_benches/axi/run_cut.sh` and `./test_benches/axi/run_xbar.sh`
before spending a synthesis run — 216 and 131 checks. Both take their file
lists from `package_openhw_ips.tcl` via `tools/ip-filelist.py`, so what is
simulated is exactly what is synthesised.

### Why the memory is still Xilinx

Replacing `axi_bram_ctrl` + `blk_mem_gen` was attempted twice and abandoned
on measurement both times. Recorded here so it is not attempted a third time
the same way:

| attempt | WNS |
|---------|-----|
| baseline, all Xilinx | **+0.107** |
| `demofull` + inferred block RAM behind AXI4 | −0.107, −0.023 with `cascade_height` |
| block RAM on CVA5's native `mem_interface` | −0.143 |
| the same, with a registered read return | −0.316 |

In both designs the failing path is the core's own fetch-to-predictor
recurrence — I$ or BP tag read, tag compare, early branch flush, PC select,
branch predictor table address — and it is routing-dominated, 56–74% of the
budget. The Xilinx pair keeps that path shorter than anything hand-built
here, and the reason was never established.

Things that were measured along the way, so they are not retried:

- `cascade_height` on an inferred array is worth 0.084 ns, but **not** via a
  hardware cascade: UG473 restricts `CASCADEIN`/`CASCADEOUT` to 64K x 1 in
  true-dual-port mode, and a 32-bit byte-enabled array is neither. It only
  shallows the fabric output mux. Placement confirms it — the members of a
  cascade group land in different BRAM columns, which a real cascade cannot.
- Block RAM displacement is **not** the mechanism. The core's block RAMs
  cluster on consecutive sites by themselves, with the critical path's launch
  and capture adjacent, whichever memory is used.
- A pblock confining the AXI blocks to a clock-region strip costs 0.077 ns.
  Placement reached +0.029 and routing lost it; this is not a
  placement-freedom problem.
- 32 RAMB36 is the floor for 128 KB with byte enables, so the footprint
  cannot shrink without shrinking `RAM_SIZE`.
- The JTAG domain is intentionally left unconstrained, which is why the build
  reports ~247 critical warnings (`TIMING-17`). Constraining it creates a TCK
  clock, and that in turn produces the CDC and clock-relationship warnings
  that then want waiving. lowRISC's `ibex-demo-system` ships the same
  `riscv-dbg` on this same part with a single `create_clock` on the input pin
  and nothing else; this follows that. Note it does mean the debug domain is
  untimed.

## Prerequisites

- Vivado (part `xc7z020clg400-1`).
- PYNQ-Z2 board files installed (Digilent `vivado-boards`):
  https://github.com/Digilent/vivado-boards
- Run from the **repo root** so the relative paths in the scripts resolve.

## Build (Vivado Tcl console, from the repo root)

```tcl
source ./examples/xilinx/package_as_ip_pynq_z2.tcl   ;# package CVA5 as IP
source ./examples/xilinx/pynq_z2_sys.tcl             ;# build the SoC + add the XDC
```

Then in the GUI: **Generate Bitstream**, open the **Hardware Manager**, and
program the device.

The demo program is `examples/sw/mem.mif` (the `cva5_top` `LOCAL_MEM`
parameter). To change it, rebuild the software under `examples/sw` and copy the
generated `program.hex` over `examples/sw/mem.mif` as they share the same
one-word-per-line hex format that `$readmemh` expects, then re-run the build.

## Pin map (`xc7z020clg400-1`)

| Signal     | FPGA pin | Board location      | Notes                                  |
|------------|----------|---------------------|----------------------------------------|
| `reset_sw` | `M20`    | Slide switch **SW0**| Active-low: switch **down = reset**, **up = run** |
| `uart_tx`  | `Y18`    | PMOD **JA pin 1**   | FPGA → bridge                          |
| `uart_rx`  | `Y19`    | PMOD **JA pin 2**   | bridge → FPGA                          |

The 125 MHz board clock is applied automatically by board automation, and the
`clk_wiz` produces the ~100 MHz core clock which matches `#define MHZ 100` in
the demo, so its `usleep` timing is correct.

## Reset on SW0 — needs debouncing

SW0 feeds the reset chain (`proc_sys_reset` + `clk_wiz`, both active-low)
directly. A slide switch is mechanical and bounces, so a single toggle can
produce several reset edges. That is usually harmless on a reset line but can
cause a glitchy or partial reset. For a clean reset, add a debouncer or drive the reset from an already-debounced source. *(Known limitation / TODO.)*

## UART over the onboard USB-UART (no external adapter)

The PYNQ-Z2's USB-UART bridge is wired to the PS (MIO14/15), not the PL, so this
design brings the PL UART out to **PMOD JA**. To reach the onboard bridge from
the PL, jumper PMOD JA to the board's **J13** header. **two wires, straight
across**:

- **JA pin 1** (`uart_tx`) → **J13 pin 1**
- **JA pin 2** (`uart_rx`) → **J13 pin 2**

No crossover is needed; the straight mapping already lands the FPGA's TX on the
bridge's RX and the FPGA's RX on the bridge's TX. No ground jumper is needed
either. PMOD JA and J13 share the board's common ground. The same micro-USB
that programs the board then also carries the serial console.

**Terminal settings:** 9600 baud, 8N1, no flow control (the AXI UART Lite
default. Raise `C_BAUDRATE` on the IP if you want faster). Open it on the COM
port the board enumerates as.

**Make sure nothing else is driving the bridge** at the same time: no PS UART
console on those lines, and **close Vivado's Hardware Manager / programmer**
connection before opening the serial terminal as JTAG and UART share the one
FT2232 over the same micro-USB.
