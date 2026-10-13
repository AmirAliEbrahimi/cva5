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

### Replacing the memory behind AXI: three attempts that failed

Putting the RAM behind an AXI slave, in place of `axi_bram_ctrl` +
`blk_mem_gen`, was attempted three times and abandoned on measurement every
time. Recorded so it is not attempted a fourth way:

| attempt | WNS |
|---------|-----|
| baseline, all Xilinx | **+0.107** |
| `demofull` + inferred block RAM behind AXI4 | −0.107, −0.023 with `cascade_height` |
| block RAM on CVA5's native `mem_interface` | −0.143 |
| the same, with a registered read return | −0.316 |

In all of them the failing path is the core's own fetch-to-predictor
recurrence — I$ or BP tag read, tag compare, early branch flush, PC select,
branch predictor table address — routing-dominated at 56–74% of the budget.

The resolution was not a better AXI slave. It was that the AXI memory path
should not exist: upstream runs this core from local memory with both caches
off, and once it does, the memory needs no bus master at all and the
fetch-to-predictor recurrence is the only thing left of this path. See
**Memory** above. The one bus master that remains is the debugger, which is
why `cva5_ram_port` exists and why it is the shape it is.

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

### Timing: there is no single critical path

The design closes at 100 MHz, and the number it closes by is not a score. On
the routed run, **112 setup paths sit within 0.22 ns of WNS and over 1000
within 1.0 ns** — the query hit its own `-max_paths` limit, so the real count
is higher. Four consecutive builds produced four *different* worst paths, all
inside 0.6 ns of each other:

| build | worst path | arrival | WNS |
|-------|-----------|---------|-----|
| local memory, caches off | debugger → RAM enable | 8.831 | **+0.485** |
| + buffered bus write | load-store → RAM enable | 9.157 | **+0.063** |
| + core out of the W handshake | d_tlb → RAM write data | 8.571 | **+0.582** |
| + JTAG clock constrained | fetch BRAM → branch predictor | 8.889 | **+0.378** |

Which one reports as WNS is decided by placement, so fixing any one of them
promotes the next. A change that re-places a few hundred registers re-deals
the whole hand — the last row moved 0.2 ns on a constraint change that added
no logic and touched nothing on the path that reported.

**So judge a change here on two things: does the design still close, and does
the worst path land in the RTL that changed.** Not on which way the number
moved. A delta under ~0.25 ns is not evidence of anything.

The current limiter is instruction fetch reading local memory, computing the
next PC, and addressing the branch predictor's tag bank in one cycle. 4.33 ns
of its 8.889 is spent before any logic runs: 2.454 ns of RAMB36 access plus
1.879 ns getting out of a 32-block array. It is upstream's fetch path, and it
exists in this shape because the core runs from local memory with no I$ —
which is the configuration upstream ships.

Hold is the one thing a slower clock cannot rescue: **WHS +0.028**, met but
thin, and worth a glance after any change that moves placement.

### The JTAG domain is constrained

It was not, for a long time, and the build reported 243 `TIMING-17` critical
warnings — every register in `i_dmi_jtag` reached by no timing clock at all.
That is not cosmetic: a register with no clock has no requirement, so nothing
stops the placer putting the two ends of the TAP's shift chain at opposite
corners of the die. It worked because 10 MHz forgives almost anything on a
part that closes at 100 MHz.

Two constraints in `pynq_z2_cva5.xdc` fix it, and they have to go together:

- `create_clock` at 100 ns on the `BSCANE2` TCK pin — the 10 MHz the OpenOCD
  config asks the adapter for. Found through the cell, not by filtering every
  pin in the design on its hierarchical name (`XDCB #1`).
- `set_max_delay -datapath_only 10.000` between TCK and the system clock in
  both directions. **Not** `set_clock_groups -asynchronous`, which was the
  first attempt and was wrong: `cdc_2phase_clearable` states its own
  requirement in its header — *"max_delay of min_period(src_clk_i, dst_clk_i)
  through the paths async_req, async_ack, async_data"* — and marks those nets
  `dont_touch` so they survive synthesis to be constrained. A clock group
  removes the paths from analysis instead of bounding them, and the handshake
  is only safe because `async_data` is held stable while a two-stage
  synchroniser carries `async_req` across. That argument needs the data path
  bounded. With the group in place `report_cdc` returned two Critical rows and
  849 endpoint pairs it could not classify.

The two cannot be combined: `set_clock_groups` outranks `set_max_delay` in
Vivado's exception precedence, so leaving the group in would silently discard
the bound and look like it had worked.

## Prerequisites

- Vivado (part `xc7z020clg400-1`).
- PYNQ-Z2 board files installed (Digilent `vivado-boards`):
  https://github.com/Digilent/vivado-boards
- Run from the **repo root** so the relative paths in the scripts resolve.

## Build (Vivado Tcl console, from the repo root)

```sh
make -C examples/sw ram                              # ram.mif, baked into the IP
```
```tcl
source ./examples/xilinx/package_as_ip_pynq_z2.tcl   ;# package CVA5 as IP
source ./examples/xilinx/package_openhw_ips.tcl      ;# the open-hardware AXI blocks
source ./examples/xilinx/pynq_z2_sys.tcl             ;# build the SoC + add the XDC
```

Then in the GUI: **Generate Bitstream**, open the **Hardware Manager**, and
program the device.

The image the bitstream preloads is `examples/sw/ram.mif`, named by `cva5_top`'s
`LOCAL_MEM` parameter and built by `make -C examples/sw ram`. It is a park loop
that prints nothing, so a freshly programmed board is silent. Programs are
normally loaded over JTAG instead — `make -C examples/sw load` — which needs no
Vivado rebuild at all; the preload only decides what runs before the first load.
Point `IDLE_SRCS` at something else if you want the board to come up doing
something.

## What is tested, and how

| check | command | covers |
|-------|---------|--------|
| crossbar | `sh test_benches/axi/run_xbar.sh` | 131 checks, decode and DECERR |
| register cut | `sh test_benches/axi/run_cut.sh` | 216 checks |
| RAM port | `sh test_benches/debug/run_ram_port.sh` | 1110 checks: core-versus-bus arbitration against the real `tdp_ram` |
| SBA bridge | `sh test_benches/debug/run_tb.sh` | DMI → DM → SBA → AXI4-Lite |
| silent boot | program the board | the preload prints nothing |
| debugger load | `make -C examples/sw load` | SBA block write, verify, release |
| DM bring-up | `openocd … -c "init; p1_diag; shutdown"` | DM, SBA, RAM read/write over JTAG |
| **all of main memory** | `make -C examples/sw memtest` | **the only thing that addresses all 128 KB**, so the only thing that reaches cascade rows above the first. Prints on the serial console, not the terminal |
| QEMU parity | `tools/cva5-qemu` | same reset vector and map as the board |

Run the four simulation checks before spending a synthesis run. All of the
above pass on the current design.

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
