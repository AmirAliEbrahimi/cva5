# CVA5 on the PYNQ-Z2

Builds a CVA5 (RV32IM) soft SoC that runs the `examples/sw` demo program from
block RAM inside the core, with lowRISC's UART for console output. A single slide switch
(SW0) drives the system reset. This mirrors the existing Nexys A7 example.

## Files (in `examples/xilinx/`)

| file                          | purpose                                                                 |
|-------------------------------|-------------------------------------------------------------------------|
| `package_as_ip_pynq_z2.tcl`   | packages the CVA5 core as a Vivado IP into `./vivado/ip_repo`            |
| `pynq_z2_sys.tcl`             | builds the SoC block design (clock, reset, CVA5, UART) + XDC            |
| `pynq_z2_cva5.xdc`            | pins only — reset switch and PMOD UART                                  |
| `vendor/boot_rom.sv`          | riscv-dbg's boot ROM, hand-vendored (see Boot ROM)                      |
| `vendor/uart.sv`              | lowRISC's UART, hand-vendored (see UART)                                |
| `axi/cva5_uart.sv`            | that UART behind an AXI4-Lite slave port                                |
| `vendor/cva5_clint.sv`        | CVA5's CLINT, vendored with a 1 MHz prescaler (see CLINT)               |
| `axi/cva5_clint_axi.sv`       | that CLINT as a block-design peripheral                                 |
| `pynq_z2_jtag.xdc`            | JTAG clock, its CDC constraints, TIMING-9 waiver (implementation only)  |

## Open-hardware AXI blocks

The Xilinx IPs are replaced with open-hardware blocks, measured against the
all-Xilinx baseline of **WNS +0.107** at 100 MHz on the `xc7z020clg400-1`:

| Xilinx IP | replacement | licence | result |
|-----------|-------------|---------|--------|
| `axi_register_slice` | *removed* — see below | — | — |
| `axi_interconnect`   | `cva5_axi_xbar` (pulp `axi_lite_xbar`) | Solderpad 0.51 | same build |
| `axi_uartlite`       | `cva5_uart` (lowRISC `uart`) | Apache-2.0 | see below |
| `axi_bram_ctrl` + `blk_mem_gen` | *removed* — main memory is `tdp_ram` inside the core | — | — |
| `clk_wiz` | *kept* — the MMCM is a hard block | — | — |

`clk_wiz` is the only Xilinx IP left in the block design.

### Memory map

The addresses follow **CVA6's**, so the choices are a CORE-V convention rather
than ours, and anything written against a CORE-V system lands in the right
place. `examples/sw/soc.h` is the software copy and the single source of truth
for it.

| region | base | size | state |
|---|---|---|---|
| Debug Module | `0x0000_0000` | 4 KB | present |
| boot ROM | `0x0001_0000` | 64 KB | present (2 instructions; reset vector) |
| CLINT | `0x0200_0000` | 768 KB | present (64 KB decoded) |
| PLIC | `0x0C00_0000` | 64 MB | reserved |
| UART | `0x1000_0000` | 4 KB | present |
| timer | `0x1800_0000` | 4 KB | reserved |
| SPI | `0x2000_0000` | 8 MB | reserved |
| main RAM | `0x8000_0000` | 128 KB | present |

"Reserved" means the window is spoken for and nothing is there yet, so adding
the device later moves nothing. The sizes are CVA6's even where ours will be
smaller: the window is reserved, not the device.

The core's peripheral bus covers `0x0000_0000`–`0x7FFF_FFFF` — everything that
is not RAM is a peripheral, which is the whole of the split now that RAM is the
only thing above `0x8000_0000`. The crossbar decodes within it and returns a
DECERR for an address no slave claims, so the wide range costs nothing and the
CLINT and PLIC need no edit to it.

**The Debug Module at zero has one consequence worth knowing.** Nothing in
`examples/sw` writes `mtvec`, so the core's `RESET_TVEC` is the trap vector for
the whole life of the program — and it cannot be left at its reset value of
zero, because every trap would jump into the debug ROM and execute whatever it
found. So `trap.S` puts a trap handler at the base of RAM and `crt0.S`'s `_start`
sits 0x40 above it:

```
0x8000_0000   trap_entry    reads mcause/mepc/mtval into t0/t1/t2 and parks
0x8000_0040   _start        the boot ROM jumps here
```

`fpga_link.ld` asserts both addresses, so the hardware parameters and the image
cannot drift apart silently. The handler lives in its own file because the
preload image (`idle.S`) does not link `crt0.S`, and an assert on a symbol that
image lacks would break `make ram` — grow the handler past its slot and the link
fails rather than the board jumping into the middle of it. The handler
deliberately does not print: a trap can arrive with a broken stack or before
the UART is usable, and a handler that faults while reporting a fault tells you
nothing. `make load`'s OpenOCD can read those three registers.

### Boot ROM

`RESET_VEC` is `0x0001_0000`, CVA6's boot ROM address, and the ROM there is two
instructions:

```
0x0001_0000   lui  x1, %hi(0x8000_0040)
0x0001_0004   jalr x0, %lo(0x8000_0040)(x1)
```

CVA6 needs a ROM because its main memory is external DDR, which comes up empty.
Ours is on-chip block RAM that `$readmemh` initialises from `ram.mif` at FPGA
configuration, so the bitstream could put the reset vector straight into RAM —
and did, until this change. The ROM is there for a different reason: RAM is
writable and `make load` writes it, so a reset vector in RAM means the first
instruction after reset is whatever the last load left behind, which during
bring-up is exactly the thing under test. Two instructions in LUTs cannot be
corrupted by software or by the debugger.

`vendor/boot_rom.sv` is hand-vendored from `third_party/riscv-dbg/tb/boot_rom.sv`
(Solderpad 0.51), which is in riscv-dbg's testbench directory and so outside the
vendored source set. `ENTRY_ADDR` is a parameter, passed `APP_ENTRY` by the
wrapper, so the ROM and `fpga_link.ld` cannot disagree about where the program
starts. The lui/jalr pair is built as a real `%hi`/`%lo` pair: upstream splits
the address as `{addr[31:12], addr[11:0]}`, which is wrong whenever bit 11 is
set, because `jalr` sign-extends its immediate and a low half of `0x800`–`0xFFF`
then subtracts. `test_benches/debug/run_boot_rom.sh` decodes what the ROM
returns and recomputes the target for six entry addresses, including that case.

The core has one instruction bus, so `IBUS_ADDR` has to span both the Debug
Module and the ROM, and `cva5_wrapper` splits it by address. Its top is
`0x0001_FFFF` rather than `ROM_BASE + 0xFFF` to keep the window a power of two:
fetch range-checks every PC against it, and `pc <= 0x0001_FFFF` is `~|pc[31:17]`
where `pc <= 0x0001_0FFF` is a magnitude comparator — and fetch is this design's
critical path. It also keeps `BUS_RANGE` equal to `SCRATCH_RANGE`, so
`branch_predictor.sv`'s `get_memory_width()` still takes the scratch branch and
`BTAG_W` stays 6.

Addresses on the instruction bus that are in neither window read as zero, which
decodes as an illegal instruction and traps. Withholding the acknowledge instead
would hang fetch with nothing to show why.

QEMU models both: `qemu/0001-cva5-pynq-machine.patch` puts the same two
instructions at `0x0001_0000`, points `resetvec` there, and restores `mtvec` to
`RESET_TVEC` in a reset handler, because QEMU has no property for a CPU's reset
`mtvec` and the CPU's own reset clears it. So a trap under QEMU reaches
`trap_entry` as it does on the board.

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

That slice was `cva5_axi_cut`, the first Xilinx IP this fork replaced —
`axi_register_slice` swapped for pulp's `axi_cut`, measured at WNS +0.122
against the all-Xilinx baseline's +0.107. It outlived the path it was cutting
by several patches, packaged and benched but absent from the block design, and
is now deleted along with the vendored AXI4 crossbar sources that the Lite-only
bus stopped using: `axi_cut`, `axi_xbar`, `axi_xbar_unmuxed`, `axi_demux`,
`axi_demux_simple`, `axi_mux` and `axi_multicut`. All seven are regenerable
from the submodule with `tools/vendor-pulp-sv.py` if a bursting master ever
comes back.

`make ram` builds the preload image the bitstream bakes in. It is a park loop
that prints nothing, so a freshly programmed board is silent and the UART
carries only what you load over JTAG.

The debugger still has to reach that RAM to load programs, and the local
memory interface has no handshake — the core raises `en` and expects its data
next cycle, with no way to be told to wait. So `cva5_ram_port` sits in front
of the load/store port and gives the debugger only the cycles the core leaves
idle. The core can never be stalled by it; the debugger can always wait, since
SBA is paced by JTAG. During `make load` the core is in reset and every cycle
is idle.

`cva5_ram_port` is a full AXI4 slave rather than AXI4-Lite. SBA only ever
issues single beats, but handling bursts costs little and is what a future
master on that port would want — main memory moving back out of `cva5_top`, for
one.

The debugger reaches it without leaving `cva5_top`. `cva5_sba_split` sits
between `dm_sba_axil` and the rest of the design and routes the system bus by
address: inside the RAM window to the RAM port, everything else out `m_axi_dbg`
to the crossbar, which decodes it as before. Nothing outside the RAM window is
claimed, so an unmapped address still gets its DECERR from the crossbar's error
slave and OpenOCD still sees `sberror=2`.

That replaced a loop. The system bus used to leave `cva5_top` through
`m_axi_dbg`, cross the crossbar and come back in through an `s_axi_ram` slave
to reach a RAM inside the module it started from. The loop existed because the
crossbar's RAM master was built for the cached master, whose bursts needed a
full AXI4 path; once the caches were gone the debugger was its only remaining
client, and it is AXI4-Lite with one outstanding single-beat transaction. The
loop cost a crossbar master port, a protocol conversion, an IP boundary and 11
source files to carry single words a few hundred micrometres.

`cva5_sba_split` is its own module rather than glue inside the wrapper so that
`run_sba_split.sh` can drive the real `dm_sba_axil`, the real `cva5_ram_port`
and the real `tdp_ram` through it. One detail of it is worth stating because
getting it wrong hangs every program load: its registered select must reset
from `rstn` alone, never from `ndmreset`. `cpu_hold` asserts `ndmreset` and
*holds* it while loading, so a select held in reset through that would route
every response to the side the request never went to.

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

The crossbar is AXI4-Lite on every port now, masters and slaves alike: one
`axi_lite_xbar` rather than an AXI4 crossbar feeding a Lite one through a
converter. Nothing left on this bus bursts — main memory is answered inside
`cva5_top` and the peripherals are registers — so the AXI4-to-Lite conversion,
its skid buffers and the ID machinery that only a multi-beat, multi-outstanding
bus needs all went with the RAM master port. The file left the IP's list with
them: `axi_demux`, `axi_demux_simple`, `axi_mux`, `axi_multicut`, `axi_xbar`,
`axi_xbar_unmuxed`, `axi_id_prepend`, `axi2axilite`, `axi_addr`, `sfifo` and
`skidbuffer`. `cva5_axi_xbar.sv` went from 830 lines to 370.

(For the record, since it may matter again if a bursting master ever returns:
the AXI4-to-Lite conversion used ZipCPU's formally verified `axi2axilite`.
pulp's `axi_to_axi_lite` was tried first and missed 100 MHz by 3.2 ns — its
burst splitter, ID queue and atomic filter are built for a general AXI port,
none of which a window carrying single-beat register accesses can reach.)

From the crossbar onwards the address decode lives in the RTL, as parameters
taken from `examples/sw/soc.h`, not in the Vivado address editor. An address
in no window, or a master reaching for a slave it is not wired to, returns a
DECERR instead of landing somewhere unexpected.

Validated on hardware, not just in simulation: boot banner over the UART
(CPU to the peripheral port), `make load` (debugger to RAM), a 128 KB walk
over system bus access with zero errors, a deliberate unmapped read returning
`sberror=2` rather than hanging, a full GDB session (reset, load, breakpoint,
single step, register and memory access, asynchronous halt), and `make
memtest` passing -- the only test that addresses all 128 KB.

Run `./test_benches/axi/run_xbar.sh` and
`sh test_benches/debug/run_sba_split.sh` before spending a synthesis run — 30
checks across three port-width configurations, and 73. The first takes its file
list from `package_openhw_ips.tcl` via `tools/ip-filelist.py`, so what is
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
| + CDC bus skew + waiver | — | — | **+0.426** |
| + CVA6 memory map | fetch BRAM → branch predictor | 8.853 | **+0.291** |
| + boot ROM | register file → divider CLZ | 9.586 | **+0.319** |
| + lowRISC UART | load queue index → RAM enable | 8.832 | **+0.551** |
| + CLINT as a peripheral | — | — | **—** (not built alone) |
| + SBA split, Lite-only bus, `time` unimplemented | load queue index → RAM address | 8.665 | **+0.414** |

Which one reports as WNS is decided by placement, so fixing any one of them
promotes the next. A change that re-places a few hundred registers re-deals
the whole hand — the JTAG row moved 0.2 ns on a constraint change that added
no logic and touched nothing on the path that reported.

The last row is three patches measured together — the debugger's RAM loop
replaced by `cva5_sba_split`, the crossbar collapsed to AXI4-Lite throughout,
and `mtime`'s 64 wires out of `cva5_top` — because each one changes
`cva5_top`'s port list and so needs its own repackage. It landed with **zero
failing endpoints, WHS +0.036**, and the worst path in the same structure as
the row above it: the load queue's FIFO index into the main RAM's address and
enable pins, 80% routing, 8 levels of logic. Fifteen of the twenty worst setup
paths are that same source register going to different `local_mem` pins, and
the twenty span 0.414 to 0.599 ns. Nothing from the rewritten bus appears
anywhere in them — no crossbar, no split, no UART, no CLINT — which is what a
bus carrying single-beat register traffic should look like. The whole Lite
crossbar costs 605 LUTs and 278 flops; the CLINT 193 and 175.

Two rows are worth reading together. The memory map changed no logic on the
reported path — seven address constants, of which the live ones all reduce to
equal or cheaper comparisons — and cost 0.135 ns; its data path delay was
*faster* than the row above it (8.853 against 8.889) and the whole difference
was clock skew between the two RAM sites (−0.218 against −0.095). Then the
boot ROM added logic to the instruction fetch path and the number went *up*
0.028 ns, with the worst path leaving fetch entirely for upstream's divider.
Neither direction was predictable from the change, which is the point.

**So judge a change here on two things: does the design still close, and does
the worst path land in the RTL that changed.** Not on which way the number
moved. A delta under ~0.25 ns is not evidence of anything.

The limiter as of the UART build is the load-store unit's load-queue read
index into main memory's enable pin — `lfsr_read_index/value_reg[1]` into
`local_mem/mem_reg_2_0_1/ENARDEN`, 8.832 ns, 8 logic levels, and **79%
routing**. Paths 2 and 3 are the same source into two other RAMB36 enables at
+0.601 and +0.634. At 79% interconnect there is almost no logic to remove: it
is one register fanning out to the enables of a 32-block array.

The build before it was limited by upstream's divider input instead — the
register file read, four `CARRY4` of signed-divide negation, the
count-leading-zeros tree, into the divider's input FIFO, with the branch
predictor's tag bank behind it at +0.339. Three different subsystems inside
0.074 ns in that build, and a fourth taking the lead in the next one.

For most of this work the limiter was instruction fetch instead: local memory
read, next PC, branch-predictor tag bank, in one cycle, with 4.33 ns of its
8.889 spent before any logic ran — 2.454 ns of RAMB36 access plus 1.879 ns
getting out of a 32-block array. The boot ROM added logic to that path and it
stopped being the limiter, which says more about the size of the cluster than
about either change.

Hold is the one thing a slower clock cannot rescue, because its requirement is
edge-to-same-edge: **WHS +0.029**. It has read 0.019 to 0.029 across builds and
has never failed. Vivado's hold fixing stops at met rather than maximising, so
a number drifting down within that band is the tool satisficing, not the design
degrading; the only reading that means anything is a negative one, which arrives
as a reported failure.

### UART

`cva5_uart` is lowRISC's `uart` from ibex-demo-system behind an AXI4-Lite slave
port, replacing Xilinx's `axi_uartlite`. 8N1, 9600 baud, 32-byte FIFOs each way.

It keeps **axi_uartlite's register map**, which is the point:

```
+0x00  RX    read pops a byte from the receive FIFO
+0x04  TX    write pushes a byte into the transmit FIFO
+0x08  STAT  bit 0 RX has data, 1 RX full, 2 TX empty, 3 TX full
```

lowRISC's own map reports RX *empty* in bit 0 and TX full in bit 1. Reporting
axi_uartlite's bits instead costs two lines in the vendored file and means
`examples/sw`, `soc.h` and the QEMU machine — which models `xilinx_uartlite` —
all work unchanged, with no per-target `#ifdef`. Software written against
lowRISC's map would need adjusting; this tree has none.

The other divergence from upstream is the FIFOs: `fifo_v3` from pulp's
`common_cells`, already vendored and packaged here, rather than OpenTitan's
`prim_fifo_sync`, which would bring `prim_fifo_sync_cnt`, `prim_util_pkg` and
`prim_assert.sv` with its four `.svh` macro headers — and those headers need
include directories that a Vivado packaged IP flattens away. Both are at the
top of `vendor/uart.sv`.

`fifo_v3` is now carried by two packaged IPs in one block design, this one and
`cva5_axi_xbar`. That is new, and the note in `package_openhw_ips.tcl` says what
to do if synthesis objects: the hazard that script warns about is specific to
*packages*, which are compilation-unit scoped, and two identical copies of a
module are a different thing.

The UART's own bus is ibex-demo-system's device interface — a request pulse,
read data one cycle later, no way to stall — so `cva5_uart` is a protocol
adapter rather than a register file. One transaction at a time, writes granted
ahead of reads so a program spinning on `STAT` cannot starve its own output.

Its AXI address port is **12 bits wide, and that is load bearing**. Vivado
infers a packaged IP's address block from the width of its AXI address port, so
a 32-bit port produces a 4 GB aperture — and a 4 GB aperture can only be placed
at zero, after which the address editor refuses the real offset:

```
ERROR: [BD 41-70] The proposed address '0x0_1000_0000 [ 4G ]' must fit an
available aperture ... Valid apertures are {<0x0_0000_0000 [ 4G ]>}
```

`cva5_clint_axi`'s 16-bit slave port gets its 64 KB block the same way. The
segment's range in `pynq_z2_sys.tcl` has to match the block the port implies,
so the UART's is 4K rather than the 64K the crossbar decodes to that port; the
UART aliases within the window, as `axi_uartlite`'s four registers did. The
*master* ports obey the opposite rule and stay 32 bits wide; `CLAUDE.md` has
both error messages side by side, because they are the same error text.

`run_uart.sh` ties `tx` back to `rx`, so one run covers the adapter, both FIFOs
and both serial state machines. It decodes the line independently of the
receiver, so a byte that round-trips through a malformed frame cannot pass, and
it measures the bit period in clocks — 8 at the testbench's 1 MHz / 125 kbaud,
which is the same divider that gives 10416 on the board.

### CLINT

`mtime`, `mtimecmp`, `msip` and the timer and software interrupts, at CVA6's
`0x0200_0000`. The standard layout, as SiFive, CVA6, OpenTitan and QEMU's
`virt` all use it:

```
+0x0000  msip      software interrupt pending, bit 0
+0x4000  mtimecmp  64-bit, low word first
+0xBFF8  mtime     64-bit, low word first
```

Before this the wrapper had a bare `mtime` counter incrementing every clock and
both interrupt structs tied to zero. Now `m_interrupt.timer` is `mtip` and
`m_interrupt.software` is `msip`. `external` stays low until the PLIC arrives;
the UART's `irq` is what will feed it.

**Two wires enter `cva5_top` from the CLINT, and they are interrupts, not
data.** RISC-V gives the timer and software interrupts their own `mip` bits —
MTIP, cause 7, and MSIP, cause 3 — so they come from the CLINT directly and
never through a PLIC, which aggregates *device* interrupts into MEIP alone.
That is also why a PLIC is the wrong home for a tick: its claim/complete
handshake is two memory-mapped accesses in the handler just to learn who
interrupted, and `mtip`/`msip` are per-hart state where a PLIC is shared. When
the PLIC lands, `external` makes three, and three is the whole of it however
many peripherals the bus carries.

**`mtime` ticks once per microsecond, not once per clock.** That is the one
divergence from `apu/clint/clint.sv`, which increments unconditionally.
Upstream's behaviour is legal — the privileged spec asks only for a constant
frequency — but every RISC-V system puts `mtime` at 1 MHz, so software ported
from any of them carries that in its delay constants, and at 100 MHz every one
of those delays would be a hundred times too short. The
divider is `CLOCK_MHZ` in `cva5_wrapper.sv`, so a clock change is one edit and
`soc.h`'s `CLINT_HZ` is the software-side copy of the same number.

The vendored copies are `vendor/cva5_clint.sv` and
`vendor/cva5_clint_wrapper.sv`, **renamed rather than shadowing upstream**:
`tools/compile_order` lists `apu/clint/clint.sv` for the Verilator simulation,
so a vendored copy keeping the name `clint` would put two different modules
with one name into the same compilation. The wrapper is vendored only to plumb
`TICKS_PER_USEC` through to the `clint` instance — upstream instantiates it
with `NUM_CORES` alone, which would pin the prescaler to its default whatever
the clock was.

Two Verilator warnings on the vendored wrapper are upstream's and are left
alone: a width mismatch in the multicore `mtimecmp` indexing, and a latch
inferred for `next_state` because its `unique case` has no `default`. All five
states are covered, so synthesis treats the case as full.

**The CLINT is a crossbar peripheral**, reached through the AXI4-Lite fan-out
below, so the debugger sees it as well as the core — `p1_diag` reads `mtime`
twice over SBA and reports the microseconds between them. It first shipped
split off the core's peripheral bus inside `cva5_wrapper`, the way the Debug
Module's registers are, which cost nothing but left it invisible to the
debugger.

It is its own block-design IP, `cva5_clint_axi`. It first shipped *inside*
`cva5_top` to avoid the signals that crossing the boundary costs, which was
optimising the wrong thing: `cva5_top` is the core, its memory and its debug
module, and a timer is none of those.

#### `time` is not implemented, and that is the normal arrangement

Moving the CLINT out meant `mtip`, `msip` *and* `mtime[63:0]` crossed back into
`cva5_top` — 66 nets, 64 of which served one CSR. Inside the core `mtime`
reaches only the `time`/`timeh` read mux and the Sstc `stip` comparison, and
Sstc is off here (`MODES : M`, `INCLUDE_SSTC : 0`).

So `time` is now reported as unimplemented and those 64 wires are gone.
`INCLUDE_TIME_CSR` is a new bit in `csr_config_t`, defaulting to 1 so nothing
else in the tree changes, and `cva5_wrapper.sv` clears it. `INCLUDE_ZICNTR`
stays **1**: `cycle` and `instret` come from counters inside the core and cost
no wires, and `mcycle`/`minstret` were never gated by it anyway — they are
machine CSRs, and this core runs M-mode only.

That split is not an invention. CVA6 serves `CSR_CYCLE` and `CSR_INSTRET` under
`RVZicntr` from its own counters, has no `CSR_TIME` case at all — a read falls
through to `read_access_exception` — and its port list has no 64-bit time input
either, just `irq_i[1:0]`, `ipi_i` and `time_irq_i`. lowRISC documents the same
for Ibex: the user-mode `time(h)` registers "are not implemented in Ibex" and
"any access to these registers will trap." Where richer software expects `time`
to work, M-mode firmware fills the gap rather than hardware — OpenSBI
trap-and-emulates TIME reads for platforms that do not implement the CSR.

The count is still there, at `CLINT_BASE + 0xBFF8`, which is where `timer.c`
and `p1_diag` already read it. `make -C examples/sw csrs` proves all three
behaviours on hardware — `rdcycle`/`rdinstret` advancing, `rdtime` taking an
illegal-instruction trap, the CLINT's `mtime` advancing over the bus — with its
own trap handler, since `trap.S`'s parks by design.

**This is the one place the board and QEMU diverge.** QEMU's `virt` implements
`time`, so `rdtime` succeeds there and `csrs` reports FAIL on that check under
`tools/cva5-qemu`. A trap is loud and `trap.S` leaves `mcause` where a debugger
can read it, which is the behaviour worth having; the alternative was a CSR
that silently reads zero.

**A port added to `cva5_wrapper.sv` has to be added to `cva5_top.v` as well.**
That file is a plain-Verilog, port-for-port wrapper that exists only because
Vivado's IP packager cannot analyse a SystemVerilog top — it says so every run:
`Module 'cva5_top' uses SystemVerilog sources with a Verilog top file`. The
packager reads `cva5_top.v` and nothing else for the interface list, so a port
present only in the SystemVerilog is invisible to it: the IP packages without
complaint, `associate_bus_interfaces` reports
`ASSOCIATED_BUSIF bus '<name>' does not exist`, and the block design then fails
with `No interface pins matched`. It is the one file in this example whose
contents are pure duplication, and the one most easily forgotten.

**Its reset is `rstn` alone, never `ndmreset`** — the rule the Debug Module and
the RAM port already follow, and for the same reason: `cpu_hold` asserts
`ndmreset` and *then* talks to the system bus, so a peripheral the debugger can
reach must not be held in reset by it, or the access never completes. Now that
the CLINT is outside `cva5_top`, `ndmreset` simply never reaches it.

`clint_wrapper` ignores write strobes, so a sub-word write to one of its
registers writes the whole word. Software writes these a word at a time, which
is what the layout is for.

### The bus is AXI4-Lite end to end

Two slave ports and two master ports, one `axi_lite_xbar`, no protocol
conversion anywhere:

```
cva5_top/m_axi      -> s_axi_cpu    the core's peripheral bus
cva5_top/m_axi_dbg  -> s_axi_dbg    the debugger, for anything outside the RAM

m_axi_uart  -> cva5_uart/s_axi      0x1000_0000
m_axi_clint -> cva5_clint_0/s_axi   0x0200_0000
```

It got there in two steps. First the peripheral window was one AXI4 master port
converted to Lite once and then fanned out by a Lite crossbar — which was the
right shape while the cached master still needed AXI4, and which is why the
alternative (a converter per peripheral, five of them with the timer, the SPI
and the PLIC to come) was rejected. Then the cached master went, the debugger's
RAM loop went with it, and there was nothing left on the bus that bursts: one
Lite crossbar does the whole job, and the next peripheral is a rule, a port and
a line in `pynq_z2_sys.tcl`.

`axi_lite_demux`, `axi_lite_mux` and `axi_lite_xbar` are vendored by
`tools/vendor-pulp-sv.py` like the rest of the pulp sources, and need only
`spill_register`, `fifo_v3`, `rr_arb_tree` and `addr_decode`. The crossbar's
error path reaches `axi_err_slv` through `axi_lite_to_axi`, which is why that
pair and `counter`/`delta_counter` are still in the IP's file list.

Keeping it **inside `cva5_axi_xbar`** rather than splitting the Lite stage into
an IP of its own stays deliberate: `axi_pkg` is a package, and the note in
`package_openhw_ips.tcl` explains why only one packaged IP in a block design may
carry it.

An address no rule claims gets a DECERR from the error slave rather than
hanging, whichever master asked — `run_xbar.sh` checks exactly that, along with
the decode, both masters reaching both slaves, cross-contamination, the address
truncation each master port performs, and the window boundaries, at three
different port-width configurations.

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
- `set_clock_groups -asynchronous` on `jtag_tck`, so the timer does not compute
  setup and hold between two clocks whose phase relationship is unknowable.
- `set_bus_skew` on each `cdc_2phase_clearable` payload — two destination
  periods, so 20 ns for the request (TCK into the core's clock) and 200 ns for
  the response.

The second one is the part that took three tries, so the reasoning is worth
keeping. `cdc_2phase_clearable` states its requirement in its own header —
*"max_delay of min_period(src_clk_i, dst_clk_i) through the paths async_req,
async_ack, async_data"* — and marks those nets `dont_touch` so they survive
synthesis to be constrained. The handshake is only safe because `async_data`
is held stable while a two-stage synchroniser carries `async_req` across, and
that argument needs the data bounded, not ignored.

Each of the two obvious ways to write it leaves one critical warning, and they
cannot be combined, because **`set_clock_groups` outranks `set_max_delay` in
Vivado's exception precedence** — the group wins and the bound is silently
discarded:

| constraint | what is left |
|---|---|
| `set_clock_groups` alone | `report_cdc`: 2 Critical, 849 endpoint pairs with the payload unclassified — nothing is bounded |
| `set_max_delay -datapath_only` alone | `TIMING-6` Critical: clocks *"related with no common node, the design could fail in hardware"* |

`set_bus_skew` is the way out, because **it is not a timing exception**: the
clock group does not override it and `report_bus_skew` checks it separately.
Measured on the routed design with both in force — requirement 20.000, actual
**1.857**, slack **+18.143** over 41 endpoints, and `report_methodology` at
**0 violations**. The router is under no pressure from the bound; it is there
to keep things that way.

One Warning remains after that, and it is waived in `pynq_z2_waivers.xdc`:
**TIMING-9, "Unknown CDC Logic"** — no double-register synchroniser on the
capture side. That is structural for any handshake CDC. The payload
deliberately has no synchroniser, which is the point of qualifying it with a
handshake: req and ack cross through three ASYNC_REG stages, and putting a
synchroniser on the payload would break the protocol rather than secure it.
AMD's own `set_bus_skew` example documents this exact topology.

Two things about that waiver worth knowing before touching it:

- **The rule is `TIMING-9`, not `TIMING-1`.** The implementation log prints
  "TIMING #1 Warning", which is a *count within the TIMING category*, not a
  rule ID — `TIMING-1` is "Invalid Clock Waveform on Clock Modifying Block"
  and waiving it does nothing. This cost a run to learn once already.
- **It is design-wide, because it has to be.** `create_waiver` rejects
  `-from`/`-to` for anything but `-type CDC` (Vivado_Tcl 4-903), so a
  methodology waiver cannot be scoped to an instance. TIMING-9 is therefore
  the build's only automatic alarm for an asynchronous crossing that genuinely
  forgot its synchroniser, and it will not fire for a new one either. If
  another clock domain is ever added, read `report_cdc` by hand: **Unsafe** and
  **No ASYNC_REG** are the columns that matter, and both are zero today.

All of this lives in `pynq_z2_jtag.xdc` with `USED_IN {implementation}`, and
that scoping is load bearing. Every query in that file names a cell inside
`cva5_top`, which is a packaged IP synthesised out of context: during top-level
synthesis the whole hierarchy is a black box, so `get_cells -hierarchical
i_tap_dtmcs` returns nothing and `create_clock` and `set_clock_groups` fail with
*"No valid object(s) found"* — while the implementation run, reading the same
file against the full netlist, resolves them fine. Unscoped, the file works and
complains at you every synthesis run. The waiver has the same requirement for a
different reason: methodology checks run after place and route, and a waiver
created in an interactive session does nothing for a run at all.

One more XDC constraint that is easy to get wrong: **there is no control flow
in an XDC.** `set` is allowed; `if` is rejected outright with *"Command 'if' is
not supported in the xdc constraint file"*. Guards like `if {[llength $x] != 1}`
silently do nothing useful — and nothing is lost by dropping them, because
`create_clock` and `set_bus_skew` both fail loudly on an empty collection,
which is all the guard was there to say.

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
| crossbar | `test_benches/axi/run_xbar.sh` | 30 checks × 3 port-width configurations: decode, both masters to both slaves, cross-contamination, address truncation, window boundaries, DECERR |
| RAM port | `sh test_benches/debug/run_ram_port.sh` | 1110 checks: core-versus-bus arbitration against the real `tdp_ram` |
| boot ROM | `sh test_benches/debug/run_boot_rom.sh` | decodes the lui/jalr pair and recomputes its target for six entry addresses |
| UART | `test_benches/axi/run_uart.sh` | loopback: adapter, both FIFOs, frame shape, bit period, status bits |
| CLINT | `sh test_benches/debug/run_clint.sh` | mtime tick rate, writes, mtimecmp→mtip at the boundary, msip |
| CLINT on hardware | `make -C examples/sw timer` | measures mtime's rate against a busy loop, then mtimecmp and msip |
| counter CSRs, in the core sim | `make -C examples/sw run-csrs` | `rdcycle`/`rdinstret`/`mcycle` readable and advancing, `rdtime` and `rdtimeh` taking an illegal-instruction trap. The only place both polarities of `INCLUDE_TIME_CSR` can be run: the sim takes upstream's `EXAMPLE_CONFIG`, so with the bit set the three trap checks are *expected* to fail |
| counter CSRs, on hardware | `make -C examples/sw csrs` | the same checks plus the CLINT's `mtime` advancing over the bus. Prints on the serial console. Fails under QEMU on purpose |
| SBA bridge | `sh test_benches/debug/run_tb.sh` | DMI → DM → SBA → AXI4-Lite |
| debugger bus split | `sh test_benches/debug/run_sba_split.sh` | 73 checks: `dm_sba_axil` → `cva5_sba_split` → the real RAM port and `tdp_ram` on one side, a peripheral on the other. Routing, window edges, error propagation, byte strobes, and collisions with the core's port |
| silent boot | program the board | the preload prints nothing |
| debugger load | `make -C examples/sw load` | SBA block write, verify, release |
| DM bring-up | `openocd … -c "init; p1_diag; shutdown"` | DM, SBA, RAM read/write over JTAG |
| **all of main memory** | `make -C examples/sw memtest` | **the only thing that addresses all 128 KB**, so the only thing that reaches cascade rows above the first. Prints on the serial console, not the terminal |
| QEMU parity | `tools/cva5-qemu` | same reset vector and map as the board. `csrs` is the known exception: QEMU implements `time` |

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

**Terminal settings:** 9600 baud, 8N1, no flow control. That was `axi_uartlite`'s
default and `cva5_uart` keeps it, so nothing changed when the UART was replaced.
It is now `BAUD_RATE` on `cva5_uart` rather than `C_BAUDRATE` on an IP, so
raising it is an edit to `examples/xilinx/axi/cva5_uart.sv` (or an override in
`pynq_z2_sys.tcl`) and a rebuild. Open it on the COM port the board enumerates
as.

**Make sure nothing else is driving the bridge** at the same time: no PS UART
console on those lines, and **close Vivado's Hardware Manager / programmer**
connection before opening the serial terminal as JTAG and UART share the one
FT2232 over the same micro-USB.
