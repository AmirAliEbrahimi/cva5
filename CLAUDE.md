# Working in this repository

Notes for anyone — human or otherwise — editing this fork. Everything here cost
at least one Vivado build cycle to learn, and none of it is catchable by the
Verilator testbenches: these are block-design and IP-packaging rules, not RTL
behaviour.

## Two files hold the same port list

`examples/xilinx/cva5_top.v` is a plain-Verilog, port-for-port wrapper around
`examples/xilinx/cva5_wrapper.sv`. It exists only because Vivado's IP packager
cannot analyse a SystemVerilog top, which it reports on every run:

```
INFO: [IP_Flow 19-5654] Module 'cva5_top' uses SystemVerilog sources with a
      Verilog top file. These SystemVerilog files will not be analysed by the
      packager.
```

**A port added to `cva5_wrapper.sv` must be added to `cva5_top.v` as well.** The
packager reads only the Verilog file when it works out the interface list, so a
port present in just the SystemVerilog is invisible to it. The IP then packages
without complaint and the failure surfaces much later:

```
CRITICAL WARNING: [IP_Flow 19-3152] Bus Interface 'clk': ASSOCIATED_BUSIF bus
                  '<name>' does not exist.
WARNING: [BD 5-232] No interface pins matched 'get_bd_intf_pins cva5_top_0/<name>'
ERROR:   [BD 5-106] Arguments to the connect_bd_intf_net command cannot be empty.
```

A check worth running after touching either file:

```sh
python3 - <<'EOF'
import re
w=open('examples/xilinx/cva5_wrapper.sv').read()
t=open('examples/xilinx/cva5_top.v').read()
hdr=w[w.index('module cva5_wrapper'):]
plist=hdr[hdr.index('\n    (')+1:hdr.index('\n    );')]
ports=sorted(set(re.findall(r'\b(clk|rstn|ndmreset|jtag_\w+|[ms]_axi_\w+)\b(?=\s*[,\)])', plist)))
missing=[p for p in ports if f'.{p}(' not in t]
print(f"{len(ports)} wrapper ports; missing from cva5_top.v: {missing or 'none'}")
EOF
```

## A field added to a config struct has to be filled in three places

`cpu_config_t` and its nested structs are declared in
`core/types_and_interfaces/cva5_config.sv`, and SystemVerilog's named
assignment patterns require **every** field, so adding one breaks each literal
that builds the struct until it is listed there too. There are three:

```
core/types_and_interfaces/cva5_config.sv   EXAMPLE_CONFIG (upstream's; the Verilator sim uses it)
examples/litex/litex_wrapper.sv            the LiteX SoC
examples/xilinx/cva5_wrapper.sv            this board
```

Give a new field the value that preserves existing behaviour in the first two
and the value this board wants in the third, so a fork-local knob changes
nothing anywhere else. `INCLUDE_TIME_CSR` is the worked example: 1 upstream and
in LiteX, both of which drive the `mtime` port, and 0 here, where nothing does.

The Verilator core sim takes `EXAMPLE_CONFIG`, which makes it the one place a
core-level knob can be exercised in **both** positions without a bitstream —
`make -C examples/sw run-csrs` against the bit set, then cleared, is how the
`time` CSR change was checked before it ever reached hardware.

## AXI address port widths: narrow slaves, wide masters

Vivado reads an AXI port's address width as two different things depending on
the port's direction, and the two rules point in opposite directions. Both
failures look identical — `ERROR: [BD 41-70] ... must fit an available
aperture` — which is what makes them easy to confuse.

**A slave port's address width sizes the address block that slave offers.**
Keep these as narrow as the device decodes. `cva5_uart`'s `s_axi` is 12 bits so
it offers 4 KB; `cva5_top`'s `s_axi_clint` is 16 bits for 64 KB. A 32-bit slave
port offers a 4 GB block, and a 4 GB block can only be placed at zero:

```
Slave segment '/cva5_uart_0/s_axi/reg0' is being assigned into address space
  '/axi_xbar_0/m_axi_periph' at <0x0_0000_0000 [ 4G ]>.
ERROR: [BD 41-70] The proposed address '0x0_1000_0000 [ 4G ]' must fit ...
```

**A master port's address width is the address space Vivado thinks that port
can reach.** Keep these at 32. A master with a 12-bit address bus cannot emit
`0x1000_0000`, so no slave can be placed there:

```
Slave segment '/cva5_uart_0/s_axi/reg0' is being assigned into address space
  '/axi_xbar_0/m_axi_uart' at <0x0000_0000 [ 4K ]>.
ERROR: [BD 41-70] The proposed address '0x1000_0000 [ 4K ]' must fit an
       available aperture ... Valid apertures are {<0x0000_0000 [ 4K ]>}.
```

`M_UART_ADDR_WIDTH` and `M_CLINT_ADDR_WIDTH` are both 32 while `cva5_uart`'s
`s_axi` is 12 and `cva5_clint_axi`'s is 16; a wide master driving a narrow
slave is the working arrangement, and the `M_*_ADDR_WIDTH` parameters on
`cva5_axi_xbar` exist so `run_xbar.sh` can sweep the truncation path, not
because the block design should narrow them.

Also: a BD address segment's range cannot exceed the slave's address block, so
`set_property range` has to match what the slave port's width implies.

## Only one packaged IP may carry a package

`axi_pkg` is a SystemVerilog package, and two packaged IPs in one block design
that both define it collide. That is why the AXI4-Lite peripheral fan-out lives
*inside* `cva5_axi_xbar` rather than in an IP of its own, and `cva5_axi_xbar`
is the only IP here that carries the package at all. A second IP that wants
pulp's AXI types has to spell its channel structs out by hand instead —
`cva5_axi_cut` did, while it existed.

Identical copies of a *module* across IPs are a different and milder matter —
`fifo_v3` is in both `cva5_axi_xbar` and `cva5_uart` and synthesises without
complaint.

## A vendored copy of an `apu/` block has to be renamed

`tools/compile_order` lists the `apu/` sources for the core simulation —
`apu/clint/clint.sv`, `apu/plic/*.sv` — so a vendored copy that keeps its
upstream module name puts two *different* modules with one name into the same
compilation. That is unlike the harmless duplicate-module case above: these
copies have diverged, so which one wins changes behaviour.

Both vendored blocks are therefore `cva5_*`: `cva5_clint`, `cva5_clint_wrapper`,
`cva5_plic`, `cva5_plic_gateway`, `cva5_plic_cmptree`, `cva5_plic_wrapper`.
Rename the instantiations too, including a module's recursive instantiations of
itself — `plic_cmptree` instantiates two of itself per level.

Where the copy is a pure rename, make the build prove it instead of trusting
it. `test_benches/axi/run_plic.sh` renames upstream with the same expression
and diffs from `module` down, so the licence header and the vendoring note are
ignored and a single changed line of logic is not:

```sh
RENAME='s/\bmodule (plic|plic_gateway|plic_cmptree|plic_wrapper)\b/module cva5_\1/; ...'
diff <(sed -E "$RENAME" apu/plic/$f.sv | sed -n '/^module /,$p') \
     <(sed -n '/^module /,$p' examples/xilinx/vendor/cva5_$f.sv)
```

Where it is not a pure rename — `cva5_clint` added a prescaler — say so in the
file's header and list what changed, because nothing can check that for you.

## Comment text that starts a line with "verilator" is a pragma

A vendoring note in `cva5_plic.sv` wrapped so that a line began
`// Verilator simulation, ...`, and the lint run failed with
`Unknown verilator comment: 'verilator simulation, so ...'`. Verilator reads
`// verilator <word>` as a directive wherever it appears, so a comment line
must not begin with that word. Reword the sentence; do not add a suppression.

## Reading a device register after writing a different one needs a fence

A store to a peripheral is posted. `load_store_unit.sv` guarantees that stores
do not reorder among themselves and that an earlier load beats a later store —
but **not** that a later load waits for an earlier store. So this reads the
register as it was before the write:

```c
SPI_TX = word;
v = SPI_STATUS;            /* may be issued before the TX write lands */
```

A write followed by a read of the **same** address is safe, because the store
queue forwards to the load. That is what makes this so good at hiding: every
"reads back" check in `examples/sw` passes, only the cross-register ones race,
and **simulation cannot see it at all** — every testbench here drives AXI from
a strictly ordered master, so the bench passes with 73 checks while the board
fails.

`fence o,i` is the fix and the core already implements it: predecessor
`o` is device output, successor `i` device input, which
`load_store_unit.sv:237` counts as a nontrivial fence and which holds the unit
until the store queue has drained and no write is outstanding. `soc.h` wraps it
as `dev_fence()`.

Two things it is not. It is not `mip_wait()`: `mip`'s bits are a registered
copy of the interrupt pins, so they lag by a cycle no fence covers, and
`csrr mip` is not a load. And it is not something to put after every write —
`timer.c` measures the crossbar's write latency by counting polls between a
store to `msip` and `mip` agreeing, and a fence there would report zero by
construction.

The bug this was found by is the shape to recognise. `spi.c` opened its
interrupt section with

```c
PLIC_PRIORITY(PLIC_SRC_SPI) = 3u;
for (...) { stale = PLIC_CLAIM; if (!stale) break; ... }
```

The claim was issued before the priority write landed, so it was taken with the
priority still 0, returned 0, and drained nothing — and the preamble written to
clear a stale interrupt left it pending. The symptom looked like an interrupt
stuck on, i.e. like a hardware fault in the thing the test was checking.

## An inferred tri-state does not survive a packaged IP

A block design synthesises each IP **out of context**: in that run the IP is
the top, so a high-Z written at its boundary has no I/O buffer to attach to and
Vivado resolves it away.

```
CRITICAL WARNING: [Synth 8-5799] Converted tricell instance 'i_1' to logic
```

`cva5_i2c_axi` had `assign scl = scl_t ? 1'bz : scl_o;`, one per line, and got
one warning per line. What that leaves is a pin **driven high** where it should
be released, so on an open-drain bus the master fights every slave that pulls
the line down to ACK — a contention between two push-pull drivers, which is
the one failure here that can damage a part.

**Instantiate `IOBUF` rather than inferring it.** A real cell survives the
out-of-context boundary; an expression does not.

The reason this is in this file rather than a code comment is how it hides.
Everything short of a transfer still passes — registers read back, the
controller reports idle, an addressed slave never answers — and "no device
answered" is also the correct result on an empty bus. And **no testbench here
could see it**: the RTL that synthesises wrong simulates right, which is the
same shape as the device-fence bug above, where the bench's strictly ordered
AXI master hid a race the board had.

Verilator has no UNISIM library, so `test_benches/axi/IOBUF_stub.v` models the
primitive. It is a real model, not a tie-off like
`test_benches/debug/BSCANE2_stub.v` — the released state is the whole point,
and a stub that drove the line would hide the bug the explicit buffer exists to
prevent. Changing it to `assign IO = I;` reproduces 8-5799's effect and
`tb_i2c` fails on a missed ACK, which is the check that this stays fixed. What
simulation still cannot check is that Vivado keeps the cell; the packaging log
does that, by not reporting 8-5799.

## A block design connects nets to whole pins

There is no way to attach two nets to two bits of one vector pin in a block
design, so a PLIC that takes its sources as `irq_srcs[N-1:0]` cannot have two
devices wired into it directly. Vivado's answer is `xlconcat`;
`cva5_irq_concat` is ours, and it is one assignment.

Two things about it that are not visible in the RTL:

**The ports are named by PLIC source number, not bit index**, because the two
differ by one — RISC-V reserves source 0, so `irq_srcs[0]` is source 1. The
order has to match `examples/sw/soc.h`'s `PLIC_SRC_*`. A swap costs nothing in
area or timing, passes synthesis, passes lint, and shows up only on hardware,
as one device's interrupt attributed to another. That is why
`test_benches/axi/tb_irq_concat.sv` drives the concat into a real PLIC and
claims each source by number rather than checking the assignment.

**A pulse does not need `EDGE_SENSITIVE`.** The SPI's `irq` is end-of-transfer,
one cycle wide, and both sources are left level sensitive, because
`cva5_plic_gateway` latches: `ip <= (ip | raise) & ~in_progress & ~claim`. Edge
mode would be worse, not better — its edge path is `irq ^ irq_r`, both edges,
so a pulse would raise a second time as it fell. The bench pulses one cycle and
checks it, because that is a claim about vendored upstream code.

## Peripherals the debugger can reach must not reset on ndmreset

`ndmreset` is the Debug Module's "reset the system but not me" request, and
OpenOCD's `cpu_hold` asserts it *before* talking to the system bus — and
*holds* it for the whole program load. Anything held in reset by it never
answers that access. So the Debug Module, the RAM port, `cva5_sba_split` and
the CLINT all reset from `rstn` alone; only the core itself uses `rst`, which is
`~rstn | ndmreset`.

This is not only about peripherals answering. State on the debugger's path
counts too: `cva5_sba_split`'s registered response select, written inline in
the wrapper, first used `rst`. Held in reset it would have read zero
throughout the load and routed every response to the side the request did not
go to, so every `make load` would have hung — in simulation as well, which is
why it was worth making the split a module with one explicit reset port.

The rule has a cost in software, and it is easy to forget: anything that resets
from `rstn` alone **survives a program reload**. The CLINT's `mtimecmp` and
`msip` do, which is why `examples/sw/timer.c` opens by disarming them, and the
PLIC's pending bits, enables and priorities do, which is why `plic.c` and
`spi.c` claim and complete whatever they find before arming anything. A test
that assumes a clean peripheral passes on the first run after a power cycle and
fails on the second.

## The packaging logs are a check, so keep them readable

`19-3833` — "Unreferenced file from the top module is not packaged" — is the
**only** thing that checks the file lists in `package_openhw_ips.tcl` and
`package_as_ip_pynq_z2.tcl`. Verilator reads the same lists and says nothing
about a file no one instantiates, so a dependency that has gone dead shows up
here and nowhere else. That is worth one line of log and useless under
twenty-one, which is what `add_files -force {core examples/xilinx examples/sw}`
produced: every peripheral IP's sources, swept into the core IP's project,
reported one by one. Both scripts list files explicitly for that reason. If a
`19-3833` appears, something is actually wrong — a file that lost its
instantiation, or a list entry left behind by a refactor.

Four warnings these scripts raise are structural. Do not spend a patch on them:

- `19-5101`, SystemVerilog top not fully supported — raised for every IP but
  `cva5_top`. The `19-5107` lines that follow show inference working anyway,
  because these wrappers keep flat port lists. The cure is a Verilog shim per
  block, and the first section of this file is about the cost of the one shim
  that already exists.
- `19-2187`, missing Product Guide — it wants a vendor datasheet.
- `19-11888` and `19-11770` appear twice each, once from
  `ipx::package_project` and once from `ipx::check_integrity`.
  `cva5_ip_metadata` in `examples/xilinx/ip_metadata.tcl` answers the second;
  the first is raised before there is a component to set anything on.
- `BD 5-670`, no frequency on a user-created input clock port — raised by the
  board automation rule about the port **it** creates, two lines before it sets
  the frequency itself. Answering it means creating `sys_clock` by hand, which
  takes the clock pin constraint away from the board file; `pynq_z2_cva5.xdc`
  deliberately does not constrain that pin.

## A derived parameter must not be a parameter of a packaged IP

`cva5_top` had `parameter RAM_ADDR_W = $clog2(WORDS)`, and the packager reports
what it does with a default expression like that:

```
INFO: [IP_Flow 19-818] Not transferring value dependency attribute
      "spirit:ceil(spirit:log(2,spirit:decode(id('MODELPARAM_VALUE.WORDS'))))"
      into user parameter "RAM_ADDR_W".
```

The dependency is dropped, so the IP offers a second knob that does not follow
the first. Nothing in the block design sets `RAM_ADDR_W` today, but the window
`cva5_sba_split` decodes is cut from it, and a value out of step with `WORDS`
aims the debugger's writes at the wrong side of the split — silently, and only
on hardware. It is a `localparam` now, which cannot be overridden and leaves
nothing to get out of step. Anything derivable from another parameter belongs
in the body, not the parameter list.

## Port names decide what Vivado thinks a port is

The packager infers bus interfaces from names alone, which is how `s_axi*`
becomes an AXI interface and `irq` becomes `xilinx.com:signal:interrupt:1.0`
with the right sensitivity, both without being asked. The same mechanism read
the SPI's serial clock *output*, then named `spi_clk`, as a clock interface:

```
INFO:    [IP_Flow 19-5107] Inferred bus interface 'spi_clk' of definition
         'xilinx.com:signal:clock:1.0'
WARNING: [IP_Flow 19-4751] Bus Interface 'spi_clk': FREQ_HZ bus parameter is
         missing for output clock interface
```

It is a divided data output on its way to a pin; nothing is clocked from it and
software sets the divider, so there is no frequency to declare. The port is
`spi_sck` now. Rename the port rather than removing the inferred interface in
the script — a suppression has to be remembered for the next block whose output
has `clk` in its name.

## A read-only block-design parameter means the value lives somewhere else

```
CRITICAL WARNING: [BD 41-737] Cannot set the parameter C_EXT_RESET_HIGH on
                  /proc_sys_reset_0. It is read-only.
```

Vivado 2025.1 derives `proc_sys_reset`'s external reset polarity by propagation
instead of taking it as a setting, so the `set_property` that used to configure
it fails. It failed in the way that is worst to inherit: the design still came
up active-low, because the same net drives `clk_wiz_0/resetn` and *that* pin's
polarity propagated into the port. The reset sense of the whole SoC rested on
an unrelated connection. `reset_sw` is now created with `create_bd_port` and
given `CONFIG.POLARITY ACTIVE_LOW` directly, which is where propagation reads
it from anyway.

## Timing numbers are not a per-patch score

Over 100 setup paths sit within 0.22 ns of WNS and over 1000 within 1.0 ns, so
the worst path moves between unrelated subsystems on any change that perturbs
placement — it has been the load-store unit, the fetch-to-branch-predictor
recurrence and the divider's input in consecutive builds. Judge a change on
whether the design still closes and whether the worst path lands in the RTL
that changed, not on which way the number moved. `README.pynq_z2.md` keeps the
build-by-build history and the measurements behind this.

## Delivery

Patches only. Commits are authored by the repository owner, carry no
third-party attribution, and are never pushed from a tooling session — the
owner applies the patch files and pushes. Documentation-only patches are not
wanted; fold doc changes into the substantive patch they belong to.
