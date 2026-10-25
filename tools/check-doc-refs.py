#!/usr/bin/env python3
"""Check that filenames named in the docs exist.

    python3 tools/check-doc-refs.py README.md examples/xilinx/README.pynq_z2.md

The three long documents in this tree name source files constantly -- which
script packages the IP, which `.xdc` holds a constraint, which testbench covers
a block. A file that gets renamed leaves the old name behind in prose, where
nothing compiles it and nothing runs it.

That happened: the README said the TIMING-9 methodology waiver lived in
`pynq_z2_waivers.xdc`. There has never been a file by that name -- the waiver
is at the bottom of `pynq_z2_jtag.xdc`, next to the clock-domain constraints it
belongs with. A reader chasing the waiver would have found nothing and
reasonably concluded the waiver itself was missing.

Two kinds of reference, resolved two ways:

- **A reference with a `/` is a path.** It is resolved relative to the
  document's own directory first, then from the repo root, because
  `README.pynq_z2.md` lives in `examples/xilinx/` and quite reasonably writes
  `axi/cva5_uart.sv` rather than spelling out the whole path every time.
- **A bare filename is a prose mention** -- "the store queue drains in
  `load_store_unit.sv`" -- and is satisfied by a file of that name anywhere in
  the tree. Demanding a full path in running prose would make the docs worse to
  read, and the loose check still catches what matters: `pynq_z2_waivers.xdc`
  fails because no file anywhere bears that name.

UPSTREAM below is the exception list: files named in the docs that belong to
Verilator or to a submodule's upstream tree, and so are not expected here. It
is deliberately an explicit list rather than a pattern -- a typo in a local
filename should fail, and a wildcard would hide it.
"""

import os
import re
import sys

# Named in the docs, owned by someone else. Not missing, not ours.
UPSTREAM = {
    "fstapi.h",         # Verilator's FST writer, in the Verilator install
    "prim_assert.sv",   # lowRISC, pulled in by the opentitan-derived sources
    "xil_printf.h",     # Xilinx BSP, in the Vitis platform the PS app builds against
}

# Build products. Named in the docs because that is what you are told to
# generate, absent until you generate it.
GENERATED = {
    "ram.mif",              # make -C examples/sw ram
    "examples/sw/ram.mif",
    "soc_wrapper.v",        # Vivado's make_wrapper, in pynq_z2_sys.tcl
    "cva5_image.c",         # make -C examples/sw ps-image
}

# Submodule-resident files the docs mention by bare name. These have to be
# declared rather than inferred: in a clone without --recurse-submodules the
# submodule directories are empty, so there is nothing to find them in, and
# waving through every unresolved bare name in that situation would let the
# stale reference this tool exists to catch pass unnoticed. Adding a name here
# is the cost of mentioning a submodule file in prose.
SUBMODULE_FILES = {
    "spi_master_controller.sv",     # third_party/axi_spi_master
    "spi_master_rx.sv",             # third_party/axi_spi_master
    "spi_master_tx.sv",             # third_party/axi_spi_master
}

# Extensions worth checking. Prose mentions plenty of other backticked things
# -- signal names, Tcl commands, register fields -- and those are not paths.
EXTS = r"sv|v|md|tcl|xdc|py|sh|c|h|cfg|mif|mk"


def basenames():
    """Every filename in the tree, for resolving bare prose mentions."""
    found = set()
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d != ".git"]
        found.update(files)
    return found


def empty_submodules():
    """Submodule paths that have not been checked out.

    `git clone` without --recurse-submodules leaves these as empty
    directories, and much of this tree's third-party RTL lives in them. A
    *path* into one is not stale, it is just not here yet, so it is reported
    as unresolved rather than failed. Bare filenames stay strict even then,
    via SUBMODULE_FILES -- see the note there for why.
    """
    try:
        with open(".gitmodules") as f:
            paths = re.findall(r"^\s*path\s*=\s*(\S+)", f.read(), re.M)
    except FileNotFoundError:
        return []
    return [p for p in paths if not os.path.isdir(p) or not os.listdir(p)]


def check(path, names, skip_submodules):
    base = os.path.dirname(path) or "."
    src = open(path).read()
    refs = sorted(set(re.findall(r"`([A-Za-z0-9_./-]+\.(?:" + EXTS + r"))`", src)))

    missing, unresolved = [], []
    for ref in refs:
        if ref in UPSTREAM or ref in GENERATED:
            continue
        if os.path.exists(os.path.join(base, ref)) or os.path.exists(ref):
            continue
        # A bare filename is a prose mention: anywhere in the tree will do.
        if "/" not in ref and ref in names:
            continue
        # A path into a submodule nobody has checked out.
        if any(ref.startswith(p + "/") for p in skip_submodules):
            unresolved.append(ref)
            continue
        # A declared submodule-resident file, with its submodule absent.
        if ref in SUBMODULE_FILES and skip_submodules:
            unresolved.append(ref)
            continue
        missing.append(ref)

    for ref in missing:
        hint = ""
        if "/" not in ref and skip_submodules:
            hint = (" (if it lives in a submodule, add it to SUBMODULE_FILES"
                    " in this script)")
        print(f"{path}: names {ref}, which does not exist{hint}",
              file=sys.stderr)
    for ref in unresolved:
        print(f"{path}: names {ref}, not checkable (submodule not checked out)")
    return len(refs), missing


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    names = basenames()
    skip = empty_submodules()
    if skip:
        print(f"note: {len(skip)} submodule(s) not checked out "
              f"-- references into them are not checked")

    total_refs = 0
    total_missing = 0
    for path in argv[1:]:
        n, missing = check(path, names, skip)
        total_refs += n
        total_missing += len(missing)

    if total_missing:
        print(f"{total_missing} dangling file reference(s)", file=sys.stderr)
        return 1
    strict = "" if skip else ", all resolved"
    print(f"doc refs ok ({total_refs} file references across "
          f"{len(argv) - 1} documents{strict})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
