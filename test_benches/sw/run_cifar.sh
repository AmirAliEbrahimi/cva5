#!/bin/sh
# examples/sw/cifar.c's software reference against a NumPy model of the same
# integer arithmetic. See test_benches/sw/tb_cifar.c.
# Run from the repo root: sh test_benches/sw/run_cifar.sh
set -e
OUT=build/tb_cifar
mkdir -p $OUT

# The fixture and the reference answers. NumPy only -- no torch, and no
# trained model: this checks cifar.c's indexing, not the network.
python3 test_benches/sw/gen_cifar_fixture.py $OUT

# -iquote, not -I, for the same reason run_mbox.sh uses it: examples/sw/stdio.h
# is the examples' own two-line stdio, and an -I would put it ahead of the
# system one for this test's own <stdio.h> -- and for cifar.c's, which is
# where printf and fputs come from here. -iquote dirs are searched for "..."
# includes only, which is what soc.h, images.h, weights.h and cifar.c itself
# all use. tb_cifar.c defines putstr before including cifar.c, which is the
# one symbol the examples' stdio.h would have declared.
#
# $OUT first, so the fixture's images.h and weights.h win over a real pair
# left in examples/sw by an earlier export.
cc -std=c99 -Wall -Wextra -Werror -O1 \
   -iquote $OUT -iquote examples/sw \
   test_benches/sw/tb_cifar.c -o $OUT/tb_cifar

# Bounded: sw_infer is a fixed number of multiply-accumulates with no data
# dependence, so a run that does not finish in seconds is an index gone
# negative, not a slow machine.
timeout 60 $OUT/tb_cifar || {
    status=$?
    [ $status -eq 124 ] && echo "FAIL tb_cifar: timed out"
    exit $status
}
