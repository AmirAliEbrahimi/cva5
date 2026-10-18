#!/usr/bin/env python3
"""Produce self-contained copies of pulp-platform SystemVerilog sources.

Vivado's IP packager (`ipx::package_project -import_files`) flattens every
source into one directory, so a `` `include "axi/typedef.svh" `` inside a
vendored file can no longer resolve. Two transformations make the sources
stand on their own:

1. Macro-only headers (`axi/typedef.svh`, `axi/assign.svh`,
   `common_cells/registers.svh`, `common_cells/assertions.svh`) are inlined
   where they are included, recursively. This is what a preprocessor would do
   anyway; the headers carry `ifndef` guards, so including one twice in a
   compilation unit is harmless.

2. Modules whose name ends in `_intf` are dropped. They wrap the real module
   in SystemVerilog interface ports (`AXI_BUS`, `AXI_LITE`), which a Vivado
   block design cannot carry, and keeping them would drag in axi_intf.sv.

Usage:
    tools/vendor-pulp-sv.py                 # regenerate examples/xilinx/vendor
    tools/vendor-pulp-sv.py --check         # fail if the copies are stale

The generated files are committed so that building the IP needs nothing but
Vivado; rerun this after bumping a submodule.
"""

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "examples" / "xilinx" / "vendor"

# Where `include "<path>"` is looked up.
INCLUDE_DIRS = [
    ROOT / "third_party" / "axi" / "include",
    ROOT / "third_party" / "common_cells" / "include",
]

# Sources to vendor, relative to the repository root. Files that need no
# change are not listed; add them to the IP straight from third_party.
SOURCES = [
    "third_party/axi/src/axi_cut.sv",
    "third_party/axi/src/axi_xbar.sv",
    "third_party/axi/src/axi_xbar_unmuxed.sv",
    "third_party/axi/src/axi_demux.sv",
    "third_party/axi/src/axi_demux_simple.sv",
    "third_party/axi/src/axi_mux.sv",
    "third_party/axi/src/axi_lite_to_axi.sv",
    "third_party/axi/src/axi_multicut.sv",
    "third_party/axi/src/axi_lite_demux.sv",
    "third_party/axi/src/axi_lite_mux.sv",
    "third_party/axi/src/axi_lite_xbar.sv",
]

INCLUDE_RE = re.compile(r'^\s*`include\s+"([^"]+)"')
MODULE_RE = re.compile(r'^\s*module\s+(\w+)')
ENDMODULE_RE = re.compile(r'^\s*endmodule')


def find_include(name: str) -> pathlib.Path | None:
    for d in INCLUDE_DIRS:
        p = d / name
        if p.exists():
            return p
    return None


def inline_includes(lines: list[str], unresolved: set[str],
                    seen: tuple[str, ...] = ()) -> list[str]:
    out = []
    for line in lines:
        m = INCLUDE_RE.match(line)
        if not m:
            out.append(line)
            continue
        name = m.group(1)
        if name in seen:
            raise RuntimeError(f"circular include of {name}")
        path = find_include(name)
        if path is None:
            # Left verbatim on purpose. These sit inside conditionals the
            # build never takes (`ifdef UVM`), so the preprocessor never
            # reaches them. Inlining would need a full preprocessor; leaving
            # the line means that if one ever does end up on a live path, the
            # build fails loudly instead of quietly compiling the wrong thing.
            unresolved.add(name)
            out.append(line)
            continue
        out.append(f"// ---- inlined from {name} ----\n")
        out.extend(inline_includes(path.read_text().splitlines(keepends=True),
                                   unresolved, seen + (name,)))
        out.append(f"// ---- end of {name} ----\n")
    return out


def drop_intf_modules(lines: list[str]) -> tuple[list[str], list[str]]:
    """Remove every module whose name ends in _intf. Returns (lines, dropped)."""
    out, dropped = [], []
    skipping = None
    for line in lines:
        if skipping is None:
            m = MODULE_RE.match(line)
            if m and m.group(1).endswith("_intf"):
                skipping = m.group(1)
                dropped.append(skipping)
                continue
            out.append(line)
        else:
            if ENDMODULE_RE.match(line):
                skipping = None
    return out, dropped


def submodule_version(path: pathlib.Path) -> str:
    for parent in path.parents:
        if (parent / ".git").exists():
            try:
                return subprocess.run(
                    ["git", "-C", str(parent), "describe", "--tags", "--always"],
                    capture_output=True, text=True, check=True).stdout.strip()
            except subprocess.CalledProcessError:
                return "unknown"
    return "unknown"


def render(src: pathlib.Path, rel: str) -> tuple[str, list[str]]:
    lines = src.read_text().splitlines(keepends=True)
    unresolved: set[str] = set()
    lines = inline_includes(lines, unresolved)
    lines, dropped = drop_intf_modules(lines)
    body = "".join(lines).rstrip() + "\n"

    dropped_note = (", ".join(dropped)) if dropped else "none"
    header = (
        f"// GENERATED by tools/vendor-pulp-sv.py -- do not edit.\n"
        f"//\n"
        f"// Source  : {rel} ({submodule_version(src)})\n"
        f"// Changes : headers inlined; interface-port modules dropped ({dropped_note}).\n"
        + (f"// Left    : `include {', '.join(sorted(unresolved))} (inside a conditional"
           f" the build never takes).\n" if unresolved else "")
        +         f"//\n"
        f"// Vivado's IP packager flattens sources into one directory, so the\n"
        f"// original `include paths cannot resolve, and a block design cannot\n"
        f"// use SystemVerilog interface ports.\n"
        f"//\n"
        f"// Regenerate with: tools/vendor-pulp-sv.py\n"
        f"\n"
    )
    return header + body, dropped


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="exit non-zero if a generated file is out of date")
    args = ap.parse_args()

    OUT.mkdir(parents=True, exist_ok=True)
    stale, problems = [], []
    for rel in SOURCES:
        src = ROOT / rel
        if not src.exists():
            print(f"missing {rel} -- did you run 'git submodule update --init'?",
                  file=sys.stderr)
            return 1
        dst = OUT / src.name
        text, dropped = render(src, rel)

        # A vendored file with no modules left is a transformation bug, not a
        # valid result; fail loudly rather than emit something that silently
        # disappears from the build.
        if not re.search(r'^\s*module\s+\w+', text, re.M):
            problems.append(f"{rel}: no modules survived vendoring")

        if args.check:
            if not dst.exists() or dst.read_text() != text:
                stale.append(str(dst.relative_to(ROOT)))
        else:
            dst.write_text(text)
            print(f"wrote {dst.relative_to(ROOT)}"
                  + (f"  (dropped {', '.join(dropped)})" if dropped else ""))

    if problems:
        for p in problems:
            print(p, file=sys.stderr)
        return 1
    if stale:
        print("stale vendored files: " + ", ".join(stale), file=sys.stderr)
        print("run tools/vendor-pulp-sv.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
