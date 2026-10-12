#!/usr/bin/env python3
"""Print the source files of one open-hardware IP, in compile order.

examples/xilinx/package_openhw_ips.tcl is the single source of truth for what
goes into each IP. The Verilator run scripts read the list from here so that
what is simulated is exactly what is synthesised: a file in one list and not
the other is the kind of difference that only shows up as a wasted synthesis
run.

The lists are kept in compile order (packages first, the wrapper last) because
Verilator needs that. Vivado does its own dependency analysis and is told the
top module explicitly, so the same order suits it.

    tools/ip-filelist.py cva5_axi_xbar
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TCL = ROOT / "examples" / "xilinx" / "package_openhw_ips.tcl"


def filelist(ip: str) -> list[str]:
    text = TCL.read_text()
    m = re.search(r"dict set openhw_ips " + re.escape(ip) + r"\s*\{(.*?)\n\}",
                  text, re.S)
    if not m:
        raise SystemExit(f"{TCL.name}: no IP named {ip!r}")
    return m.group(1).split()


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <ip-name>")
    files = filelist(sys.argv[1])
    missing = [f for f in files if not (ROOT / f).exists()]
    if missing:
        print("missing: " + " ".join(missing), file=sys.stderr)
        print("run: git submodule update --init --recursive", file=sys.stderr)
        return 1
    print(" ".join(files))
    return 0


if __name__ == "__main__":
    sys.exit(main())
