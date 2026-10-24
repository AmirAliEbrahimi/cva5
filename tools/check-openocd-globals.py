#!/usr/bin/env python3
"""Catch Tcl procs that read a global without declaring it.

    python3 tools/check-openocd-globals.py examples/xilinx/openocd/*.cfg

Tcl procedures do not see global variables unless they say `global NAME`, and
reading an undeclared one is not an error until the line actually runs:

    proc p1_diag {} {
        global RAM_BASE UART_BASE
        ...
        set a [expr {$CLINT_BASE + $CLINT_MTIME_OFF}]   ;# never declared
    }

That exact omission shipped. The RAM, UART and Debug Module checks above it all
passed, and the failure came on a board, from a diagnostic whose whole purpose
is to be trustworthy when something else is broken.

It survived because of where it was: everything these configs do is a
procedure, several of their branches only run when hardware misbehaves, and
nothing simulates OpenOCD. A linter is the only thing that reads the lines that
have not run yet.

The check is deliberately narrow -- a name assigned by a top-level `set`, used
as `$NAME` inside a proc, not declared `global` and not assigned locally first.
It does not parse Tcl, so it will not catch every scoping mistake; it catches
this one, which is the one that happened.
"""

import re
import sys


def check(path):
    src = open(path).read()
    defined = set(re.findall(r"^set\s+([A-Za-z_][A-Za-z0-9_]*)\s", src, re.M))
    procs = re.findall(r"^proc\s+(\w+)\s*\{[^}]*\}\s*\{(.*?)\n\}", src, re.S | re.M)

    problems = []
    for name, body in procs:
        declared = set()
        for line in re.findall(r"^\s*global\s+(.*)$", body, re.M):
            declared |= set(line.split())
        local = set(re.findall(r"\bset\s+([A-Za-z_][A-Za-z0-9_]*)\s", body))
        local |= set(re.findall(r"\bfor\s*\{\s*set\s+(\w+)", body))
        local |= set(re.findall(r"\bforeach\s+(\w+)", body))
        used = set(re.findall(r"\$([A-Za-z_][A-Za-z0-9_]*)", body))
        missing = sorted((used & defined) - declared - local)
        if missing:
            problems.append((name, missing))

    for name, missing in problems:
        for var in missing:
            print(f"{path}: proc {name}: reads ${var} without 'global {var}'",
                  file=sys.stderr)
    return len(procs), problems


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    total_procs = 0
    total_bad = 0
    for path in argv[1:]:
        n, problems = check(path)
        total_procs += n
        total_bad += len(problems)
    if total_bad:
        print(f"{total_bad} proc(s) with an undeclared global", file=sys.stderr)
        return 1
    print(f"openocd globals ok ({total_procs} procs checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
