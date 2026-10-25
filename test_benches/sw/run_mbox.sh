#!/bin/sh
# The mailbox ring, both halves, on the host. See test_benches/sw/tb_mbox.c.
# Run from the repo root: sh test_benches/sw/run_mbox.sh
set -e
mkdir -p build/tb_mbox

# -Wall -Wextra -Werror applies to the production headers too: this is the
# only build either of them gets outside a cross-compiler, so it is the only
# place a sign-compare or an unused result in them is going to be caught.
# -iquote, not -I: examples/sw/stdio.h is the examples' own two-line stdio and
# an -I would put it ahead of the system one for this test's own <stdio.h>.
# -iquote dirs are searched for "..." includes only, which is what both
# production headers use for each other.
cc -std=c99 -Wall -Wextra -Werror -O1 \
   -iquote examples/sw -iquote examples/ps \
   test_benches/sw/tb_mbox.c -o build/tb_mbox/tb_mbox

# A bounded run. The failure this guards against is a ring whose two halves
# disagree about the wrap: the drain's "while tail != head" then never
# terminates, and an unbounded test would hang rather than report.
timeout 30 ./build/tb_mbox/tb_mbox || {
    status=$?
    [ $status -eq 124 ] && echo "FAIL tb_mbox: timed out -- the drain did not terminate"
    exit $status
}
