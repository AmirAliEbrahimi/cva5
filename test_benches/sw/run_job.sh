#!/bin/sh
# The job block, both halves, on the host. See test_benches/sw/tb_job.c.
# Run from the repo root: sh test_benches/sw/run_job.sh
set -e
mkdir -p build/tb_job

# -Wall -Wextra -Werror reaches the production headers, and here that is not
# incidental: both soc.h and cva5_ps.h are included, and a shared constant
# that stops agreeing becomes a macro redefinition, which -Werror turns into
# the build failure this test wants. Half the checking happens right here.
#
# -iquote, not -I, for the reason run_mbox.sh gives: examples/sw/stdio.h is
# the examples' own two-line stdio and would shadow the system one.
cc -std=c99 -Wall -Wextra -Werror -O1 \
   -iquote examples/sw -iquote examples/ps \
   test_benches/sw/tb_job.c -o build/tb_job/tb_job

# Bounded. job_pending() is a comparison of two words in a page this test
# owns, so nothing here can legitimately spin -- but the protocol under test
# is two counters, and getting those wrong is exactly how a loop stops
# terminating.
timeout 30 ./build/tb_job/tb_job || {
    status=$?
    [ $status -eq 124 ] && echo "FAIL tb_job: timed out"
    exit $status
}
