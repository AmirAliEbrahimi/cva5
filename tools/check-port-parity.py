#!/usr/bin/env python3
"""Check that cva5_top.v and cva5_wrapper.sv have the same ports.

    python3 tools/check-port-parity.py

`cva5_top.v` is a plain-Verilog, port-for-port shim around `cva5_wrapper.sv`.
It exists because Vivado's IP packager will not analyse a SystemVerilog top --
it reports

    INFO: [IP_Flow 19-5654] Module 'cva5_top' uses SystemVerilog sources with
                            a Verilog top file. These SystemVerilog files will
                            not be analysed by the packager.

and packages the Verilog header it can read. Which means the IP's interface is
whatever `cva5_top.v` declares, and a port added to the wrapper but not to the
shim is simply not on the IP. The block design then cannot connect it, and
nothing in simulation notices, because simulation instantiates the wrapper.

So: a port added to one has to be added to the other. This is the check for
that, and it matters most when something is being wired out of the core --
`cva5_ram_mux`'s external slave port, say, which is 29 signals that all have
to appear in both files.

Direction is compared too. A port that exists in both but is an input in one
and an output in the other passes a name-only check and then fails in a way
that looks like a dead net in the block design.

Not checked: widths. The shim declares plain `input foo` where the wrapper has
`input logic [31:0] foo`, because the shim's widths come through from the
instantiation, so there is nothing to compare.
"""

import re
import sys

WRAPPER = "examples/xilinx/cva5_wrapper.sv"
TOP     = "examples/xilinx/cva5_top.v"

# Deliberately on the wrapper and not on the shim: the board's DTM sits on the
# FPGA's own TAP (BSCANE2) and ignores these, so cva5_top.v ties them off at
# the instantiation rather than carrying them out to the IP. The simulation
# harness drives them, building riscv-dbg's dmi_jtag_tap instead.
#
# Listed by name on purpose. A pattern would swallow a real omission, which is
# the whole failure this script exists to catch.
WRAPPER_ONLY = {
    "jtag_tck",
    "jtag_tms",
    "jtag_trst_n",
    "jtag_tdi",
    "jtag_tdo",
}


def header(path, module):
    """The text between `module <name>` and the `);` that closes its ports."""
    src = open(path).read()
    i = src.index("module " + module)
    # Skip a parameter block if there is one: its closing ")" is not the
    # port list's.
    j = src.index("\n    (", i)
    k = src.index("\n    );", j)
    return src[j:k]


def ports(path, module):
    """{name: direction} for the module's port list."""
    body = header(path, module)
    # Strip comments so a port name mentioned in prose is not picked up.
    body = re.sub(r"//[^\n]*", "", body)
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)

    found = {}
    for m in re.finditer(
            r"\b(input|output|inout)\b"          # direction
            r"((?:\s+(?:wire|reg|logic|signed|unsigned))*)"   # optional type
            r"(?:\s*\[[^\]]*\])*"               # optional packed dimension
            r"\s+(\w+)",                        # the name
            body):
        found[m.group(3)] = m.group(1)
    return found


def main():
    try:
        w = ports(WRAPPER, "cva5_wrapper")
        t = ports(TOP, "cva5_top")
    except (FileNotFoundError, ValueError) as e:
        print(f"check-port-parity: {e}", file=sys.stderr)
        return 2

    if not w or not t:
        print("check-port-parity: parsed no ports -- the module header shape "
              "has changed and this script needs updating", file=sys.stderr)
        return 2

    bad = 0
    waived = 0

    for name in sorted(set(w) - set(t)):
        if name in WRAPPER_ONLY:
            waived += 1
            continue
        bad += 1
        print(f"check-port-parity: {name} ({w[name]}) is on cva5_wrapper.sv "
              f"but not cva5_top.v -- the packaged IP will not have it",
              file=sys.stderr)

    for name in sorted(set(t) - set(w)):
        bad += 1
        print(f"check-port-parity: {name} ({t[name]}) is on cva5_top.v but "
              f"not cva5_wrapper.sv", file=sys.stderr)

    for name in sorted(set(w) & set(t)):
        if w[name] != t[name]:
            bad += 1
            print(f"check-port-parity: {name} is {w[name]} on "
                  f"cva5_wrapper.sv and {t[name]} on cva5_top.v",
                  file=sys.stderr)

    if bad:
        print(f"{bad} port mismatch(es)", file=sys.stderr)
        return 1

    print(f"port parity ok ({len(w) - waived} shared ports, directions agree;"
          f" {waived} wrapper-only by design)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
