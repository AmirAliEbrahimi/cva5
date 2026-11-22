#!/bin/sh
# examples/sw/cifar.c's software reference against an independent model of
# the same integer arithmetic. See test_benches/sw/tb_cifar.c.
# Run from the repo root: sh test_benches/sw/run_cifar.sh
set -e
OUT=build/tb_cifar
mkdir -p $OUT

# The fixture and the reference answers. Standard library only -- no torch,
# no NumPy, no trained model, nothing from tools/nn_accel's venv: this
# checks cifar.c's indexing, not the network, and must run in a fresh
# clone. Takes about a quarter of a second.
python3 test_benches/sw/gen_cifar_fixture.py $OUT

# cifar.c is compiled from a copy in $OUT, next to the fixture headers, and
# this is not tidiness. For a quoted #include, the first directory searched is
# the one holding the *including file* -- before any -iquote or -I. So a
# cifar.c compiled in place finds examples/sw/images.h whenever a real export
# has been run there, whatever this command line says, and the test then
# measures the trained network against the fixture's expected numbers and
# reports failures that mean nothing. Moving the file moves that first
# directory. tb_cifar.c's compile-time check on N_IMAGES catches it anyway.
cp examples/sw/cifar.c $OUT/cifar.c

# -iquote, not -I, for the same reason run_mbox.sh uses it: examples/sw/stdio.h
# is the examples' own two-line stdio, and an -I would put it ahead of the
# system one for this test's own <stdio.h> -- and for cifar.c's, which is
# where printf and fputs come from here. -iquote dirs are searched for "..."
# includes only, which is what soc.h, images.h, weights.h and cifar.c itself
# all use. tb_cifar.c defines putstr before including cifar.c, which is the
# one symbol the examples' stdio.h would have declared.
#
# $OUT first so tb_cifar.c's #include "cifar.c" finds the copy; examples/sw
# second, for soc.h, which only exists there.
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
