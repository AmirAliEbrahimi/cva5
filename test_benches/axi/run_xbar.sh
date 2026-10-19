#!/usr/bin/env bash
# Lint and run the cva5_axi_xbar testbench under Verilator.
#   test_benches/axi/run_xbar.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

A=third_party/axi/src
C=third_party/common_cells/src
V=examples/xilinx/vendor
BUILD=test_benches/axi/build/xbar

if [ ! -f $C/spill_register.sv ] || [ ! -f $A/axi_pkg.sv ]; then
    echo "submodules are missing; run: git submodule update --init --recursive" >&2
    exit 1
fi

# The vendored copies must match the submodules they were generated from.
python3 -I tools/vendor-pulp-sv.py --check

# Compile order matters: packages first, then the design.
# One source of truth with the Vivado packaging script, so what is
# simulated here is exactly what gets synthesised.
#
# The crossbar is AXI4-Lite on every port now, so the testbench's slaves are
# four-register Lite models written inline rather than the real cva5_axi_ram
# this used to instantiate. Nothing on this bus bursts: main memory is answered
# inside cva5_top through the local memory interface and never appears here.
DESIGN=$(python3 -I tools/ip-filelist.py cva5_axi_xbar)

# UNOPTFLAT is inherent to struct-bundled AXI: pulp packs each channel's
# forward and backward signals into one struct, so Verilator sees a cycle at
# struct granularity where the individual fields have none. It is a simulation
# scheduling hint, not a combinational loop, and does not affect synthesis.
# The remaining suppressions are upstream style in third_party.
THIRD_PARTY_NOISE="-Wno-UNOPTFLAT -Wno-UNSIGNED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
                   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
                   -Wno-VARHIDDEN -Wno-ASCRANGE -Wno-CASEINCOMPLETE
                   -Wno-PINCONNECTEMPTY -Wno-GENUNNAMED -Wno-CMPCONST"

echo "== lint (our wrapper is held to -Wall) =="
verilator --lint-only -Wall $THIRD_PARTY_NOISE --top-module cva5_axi_xbar $DESIGN

# Three configurations: the widths the block design deploys, full 32-bit
# ports, and a narrow pair -- so the M_*_ADDR_WIDTH truncation path does not
# rot untested at either extreme. The block design itself keeps both master
# ports at 32 (see CLAUDE.md); these parameters exist so that the truncation
# the crossbar performs is exercised, not because the hardware narrows them.
rm -rf "$BUILD"
status=0
for cfg in "12 16" "32 32" "4 6"; do
    set -- $cfg
    uart_aw=$1; clint_aw=$2
    dir="$BUILD/aw${uart_aw}_${clint_aw}"
    echo "== build (UART_AW=$uart_aw CLINT_AW=$clint_aw) =="
    mkdir -p "$dir"
    verilator --binary -j 0 --timing \
        $THIRD_PARTY_NOISE -Wno-BLKSEQ -Wno-INITIALDLY \
        --top-module tb_axi_xbar \
        -GUART_AW=$uart_aw -GCLINT_AW=$clint_aw \
        -Mdir "$dir" -o tb_axi_xbar \
        $DESIGN test_benches/axi/tb_axi_xbar.sv
    echo "== run =="
    "$dir/tb_axi_xbar" || status=1
done
exit $status
