#!/usr/bin/env bash
# Lint and run the cva5_irq_concat testbench under Verilator.
#   bash test_benches/axi/run_irq_concat.sh
#
# The bench needs the PLIC as well as the concat, because what it checks is the
# composition: which port becomes which PLIC source. Both file lists come from
# the Vivado packaging script, so what is simulated is what is synthesised.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

BUILD=test_benches/axi/build/irq_concat

CONCAT=$(python3 -I tools/ip-filelist.py cva5_irq_concat)
PLIC=$(python3 -I tools/ip-filelist.py cva5_plic_axi)

# Upstream style in apu/plic, in code this fork only renamed. The same list
# run_plic.sh carries, and for the same reasons -- see the comment there.
UPSTREAM_NOISE="-Wno-UNUSEDSIGNAL -Wno-ASCRANGE -Wno-WIDTHEXPAND
                -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY
                -Wno-UNDRIVEN -Wno-LATCH"

# The concat on its own, at -Wall with nothing suppressed: it is ours, it is
# one assignment, and there is nothing in it for upstream noise to excuse.
echo "== lint (cva5_irq_concat, -Wall, no waivers) =="
verilator --lint-only -Wall --top-module cva5_irq_concat $CONCAT

echo "== build =="
rm -rf "$BUILD"
mkdir -p "$BUILD"
verilator --binary -j 0 --timing \
    $UPSTREAM_NOISE -Wno-BLKSEQ -Wno-INITIALDLY -Wno-WIDTHTRUNC \
    --top-module tb_irq_concat \
    -Mdir "$BUILD" -o tb_irq_concat \
    $CONCAT $PLIC test_benches/axi/tb_irq_concat.sv

echo "== run =="
"$BUILD/tb_irq_concat"
