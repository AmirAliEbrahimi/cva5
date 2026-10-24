#!/usr/bin/env bash
# Lint and run the cva5_spi_axi testbench under Verilator.
#   bash test_benches/axi/run_spi.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

if [ ! -f third_party/axi_spi_master/axi_spi_master.sv ]; then
    echo "submodule missing; run: git submodule update --init --recursive" >&2
    exit 1
fi

BUILD=test_benches/axi/build/spi

# One source of truth with the Vivado packaging script, so what is simulated
# here is exactly what gets synthesised.
DESIGN=$(python3 -I tools/ip-filelist.py cva5_spi_axi)

# Upstream style in third_party/axi_spi_master, none of it ours:
#
#   BLKSEQ        pulp's register block assigns with `=` inside always_ff,
#                 throughout spi_master_axi_if.sv
#   UNUSEDPARAM   OFFSET_BIT, computed and never used
#   CASEINCOMPLETE/LATCH   the AXI burst FSMs have no default arm
#   WIDTH*        the usual mixed-width arithmetic
UPSTREAM_NOISE="-Wno-BLKSEQ -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-LATCH
                -Wno-CASEINCOMPLETE -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
                -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY
                -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-ASCRANGE"

echo "== lint (our wrapper is held to -Wall) =="
verilator --lint-only -Wall $UPSTREAM_NOISE --top-module cva5_spi_axi $DESIGN

echo "== build =="
rm -rf "$BUILD"
mkdir -p "$BUILD"
verilator --binary -j 0 --timing \
    $UPSTREAM_NOISE -Wno-INITIALDLY \
    --top-module tb_spi \
    -Mdir "$BUILD" -o tb_spi \
    $DESIGN test_benches/axi/tb_spi.sv

echo "== run =="
"$BUILD/tb_spi"
