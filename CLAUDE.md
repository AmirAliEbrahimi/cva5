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
*inside* `cva5_axi_xbar` rather than in an IP of its own, and why
`cva5_axi_cut` spells its channel structs out by hand. Identical copies of a
*module* across IPs are a different and milder matter — `fifo_v3` is in both
`cva5_axi_xbar` and `cva5_uart` and synthesises without complaint.

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
