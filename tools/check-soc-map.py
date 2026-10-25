#!/usr/bin/env python3
"""Check that the four copies of the memory map agree.

    python3 tools/check-soc-map.py

`examples/sw/soc.h` calls itself "the one place software gets an address from",
and for CVA5's software it is. Three others cannot include it:

    examples/xilinx/axi/cva5_axi_xbar.sv        parameters, because the decode
                                                lives in the crossbar rather
                                                than in the Vivado address
                                                editor
    examples/xilinx/openocd/cva5-pynq-z2-p1.cfg Tcl, because p1_diag probes
                                                every peripheral over JTAG
                                                before any software runs
    examples/ps/cva5_ps.h                       the Zynq PS's side, compiled
                                                by an ARM toolchain -- soc.h
                                                has RISC-V inline assembly in
                                                it

So there are four copies and nothing but a comment keeping them together. A
disagreement is not a build error in any of them: the crossbar would decode a
window software never uses, and the debugger would read an address that
returns a decode error -- which arrives as "SBA error 2" and looks exactly like
a broken bus, which is the failure this tool exists to prevent being
misdiagnosed.

Checked here: every *_BASE that appears in more than one of the four files
holds the same value. Names absent from a file are not an error -- the
debugger has no reason to know about the timer window, the crossbar has no
port for the Debug Module, and the PS reaches main memory and nothing else.
"""

import re
import sys

SOC = "examples/sw/soc.h"
XBAR = "examples/xilinx/axi/cva5_axi_xbar.sv"
OCD = "examples/xilinx/openocd/cva5-pynq-z2-p1.cfg"
PS = "examples/ps/cva5_ps.h"
LD = "examples/sw/fpga_link.ld"

# The crossbar calls the UART's window PERIPH_BASE, for the historical reason
# that it was the only peripheral when the port was named.
ALIASES = {"PERIPH_BASE": "UART_BASE"}


def canon(name):
    return ALIASES.get(name, name)


def from_soc(path):
    src = open(path).read()
    return {canon(n): int(v, 16)
            for n, v in re.findall(r"#define\s+(\w+_BASE)\s+0x([0-9A-Fa-f]+)u", src)}


def from_xbar(path):
    src = open(path).read()
    return {canon(n): int(v.replace("_", ""), 16)
            for n, v in re.findall(
                r"parameter logic \[31:0\] (\w+_BASE)\s*=\s*32'h([0-9A-Fa-f_]+)", src)}


def from_ocd(path):
    src = open(path).read()
    return {canon(n): int(v, 16)
            for n, v in re.findall(r"^set\s+(\w+_BASE)\s+0x([0-9A-Fa-f]+)", src, re.M)}


def check_link_script(path, mbox_base):
    """The linker region must end exactly where the mailbox starts.

    This one is not a name in two files, it is an arithmetic relationship, so
    it gets its own check. The mailbox lives in the top 4 KB of main memory
    and is deliberately outside the region fpga_link.ld allocates from --
    nothing is linked there, so no image overwrites it and `objcopy -O binary`
    stops short of it. _stack_top is the end of that region, so the same
    number is also where the stack starts growing down FROM. Raise the region
    and the stack grows into the mailbox; lower it and memtest's TEST_END,
    which soc.h derives from MBOX_BASE, stops covering memory that is really
    there. Neither shows up as a build error.
    """
    src = open(path).read()
    m = re.search(r"ORIGIN\s*=\s*(0x[0-9A-Fa-f]+)\s*,\s*LENGTH\s*=\s*(\d+)K", src)
    if not m:
        print(f"check-soc-map: no MEMORY region found in {path}", file=sys.stderr)
        return 1
    origin = int(m.group(1), 16)
    end = origin + int(m.group(2)) * 1024
    if end != mbox_base:
        print(f"check-soc-map: {path}'s RAM region ends at 0x{end:08X} but "
              f"soc.h puts MBOX_BASE at 0x{mbox_base:08X} -- the stack would "
              f"{'overrun' if end > mbox_base else 'leave a gap below'} it",
              file=sys.stderr)
        return 1
    return 0


def main():
    try:
        maps = [("soc.h", from_soc(SOC)),
                ("cva5_axi_xbar.sv", from_xbar(XBAR)),
                ("p1 openocd cfg", from_ocd(OCD)),
                ("cva5_ps.h", from_soc(PS))]
    except FileNotFoundError as e:
        print(f"check-soc-map: {e}", file=sys.stderr)
        return 2

    names = sorted(set().union(*(m.keys() for _, m in maps)))
    bad = 0
    for name in names:
        seen = {label: m[name] for label, m in maps if name in m}
        if len(set(seen.values())) > 1:
            bad += 1
            where = ", ".join(f"{k}=0x{v:08X}" for k, v in seen.items())
            print(f"check-soc-map: {name} disagrees: {where}", file=sys.stderr)

    soc = dict(maps[0][1])
    if "MBOX_BASE" in soc:
        bad += check_link_script(LD, soc["MBOX_BASE"])

    if bad:
        print(f"{bad} disagreement(s)", file=sys.stderr)
        return 1
    shared = sum(1 for n in names
                 if sum(1 for _, m in maps if n in m) > 1)
    print(f"soc map ok ({len(names)} addresses, {shared} in more than one file)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
