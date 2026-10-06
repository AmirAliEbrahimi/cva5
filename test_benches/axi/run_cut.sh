#!/usr/bin/env bash
# Lint and run the cva5_axi_cut testbench under Verilator.
#   test_benches/axi/run_cut.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

CC=third_party/common_cells/src
BUILD=test_benches/axi/build

if [ ! -f $CC/spill_register.sv ]; then
    echo "common_cells is missing; run: git submodule update --init --recursive" >&2
    exit 1
fi

# The vendored copies must match the submodules they were generated from.
python3 -I tools/vendor-pulp-sv.py --check

DESIGN="examples/fpga/axi/cva5_axi_cut.sv
        examples/fpga/vendor/axi_cut.sv
        $CC/spill_register.sv
        $CC/spill_register_flushable.sv"

# The design is held to -Wall; the testbench is not (it leaves AXI attributes
# unread and drives the clock with a blocking assignment).
echo "== lint =="
verilator --lint-only -Wall -Wno-DECLFILENAME --top-module cva5_axi_cut $DESIGN

echo "== build =="
rm -rf "$BUILD"
verilator --binary -j 0 --timing \
    -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
    --top-module tb_axi_cut \
    -Mdir "$BUILD" -o tb_axi_cut \
    $DESIGN test_benches/axi/tb_axi_cut.sv

echo "== run =="
"$BUILD/tb_axi_cut"
