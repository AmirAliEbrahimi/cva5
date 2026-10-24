#!/usr/bin/env python3
"""Check that the three copies of the memory map agree.

    python3 tools/check-soc-map.py

`examples/sw/soc.h` calls itself "the one place software gets an address from",
and for software it is. The hardware and the debugger cannot include it:

    examples/xilinx/axi/cva5_axi_xbar.sv        parameters, because the decode
                                                lives in the crossbar rather
                                                than in the Vivado address
                                                editor
    examples/xilinx/openocd/cva5-pynq-z2-p1.cfg Tcl, because p1_diag probes
                                                every peripheral over JTAG
                                                before any software runs

So there are three copies and nothing but a comment keeping them together. A
disagreement is not a build error in any of them: the crossbar would decode a
window software never uses, and the debugger would read an address that
returns a decode error -- which arrives as "SBA error 2" and looks exactly like
a broken bus, which is the failure this tool exists to prevent being
misdiagnosed.

Checked here: every *_BASE that appears in more than one of the three files
holds the same value. Names absent from a file are not an error -- the
debugger has no reason to know about the timer window, and the crossbar has no
port for the Debug Module.
"""

import re
import sys

SOC = "examples/sw/soc.h"
XBAR = "examples/xilinx/axi/cva5_axi_xbar.sv"
OCD = "examples/xilinx/openocd/cva5-pynq-z2-p1.cfg"

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


def main():
    try:
        maps = [("soc.h", from_soc(SOC)),
                ("cva5_axi_xbar.sv", from_xbar(XBAR)),
                ("p1 openocd cfg", from_ocd(OCD))]
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

    if bad:
        print(f"{bad} address(es) out of step", file=sys.stderr)
        return 1
    shared = sum(1 for n in names
                 if sum(1 for _, m in maps if n in m) > 1)
    print(f"soc map ok ({len(names)} addresses, {shared} in more than one file)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
