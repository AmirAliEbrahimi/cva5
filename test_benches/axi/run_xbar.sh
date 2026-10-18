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
# The RAM is instantiated for real in the testbench, so the crossbar and
# the memory are covered together. Both IPs list skidbuffer.v and
# axi_addr.v, which is correct -- each is packaged separately in Vivado --
# but one Verilator run must see each file once, so deduplicate here while
# keeping compile order.
DESIGN=$( { python3 -I tools/ip-filelist.py cva5_axi_xbar
            python3 -I tools/ip-filelist.py cva5_axi_ram
          } | tr " " "\n" | awk 'NF && !seen[$0]++' | tr "\n" " ")

# UNOPTFLAT is inherent to struct-bundled AXI: pulp packs each channel's
# forward and backward signals into one struct, so Verilator sees a cycle at
# struct granularity where the individual fields have none. It is a simulation
# scheduling hint, not a combinational loop, and does not affect synthesis.
# SYNCASYNCNET is the two upstream styles meeting: pulp's cells reset
# asynchronously, ZipCPU's synchronously, and here they share one reset net.
# That is safe because the net is proc_sys_reset's peripheral_aresetn, already
# synchronised to this clock and released synchronously, so both kinds of flop
# leave reset on the same edge.
#
# The remaining suppressions are upstream style in third_party.
THIRD_PARTY_NOISE="-Wno-UNOPTFLAT -Wno-UNSIGNED -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
                   -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
                   -Wno-VARHIDDEN -Wno-ASCRANGE -Wno-CASEINCOMPLETE
                   -Wno-PINCONNECTEMPTY -Wno-GENUNNAMED -Wno-CMPCONST
                   -Wno-SYNCASYNCNET"

echo "== lint (our wrapper is held to -Wall) =="
verilator --lint-only -Wall $THIRD_PARTY_NOISE --top-module cva5_axi_xbar $DESIGN

# Three configurations: the widths the block design deploys, full 32-bit
# ports, and a narrow pair -- so the M_*_ADDR_WIDTH truncation path does not
# rot untested at either extreme.
rm -rf "$BUILD"
status=0
for cfg in "17 12 16" "32 32 32" "17 4 6"; do
    set -- $cfg
    ram_aw=$1; uart_aw=$2; clint_aw=$3
    dir="$BUILD/aw${ram_aw}_${uart_aw}_${clint_aw}"
    echo "== build (RAM_AW=$ram_aw UART_AW=$uart_aw CLINT_AW=$clint_aw) =="
    mkdir -p "$dir"
    verilator --binary -j 0 --timing \
        $THIRD_PARTY_NOISE -Wno-BLKSEQ -Wno-INITIALDLY \
        --top-module tb_axi_xbar \
        -GRAM_AW=$ram_aw -GUART_AW=$uart_aw -GCLINT_AW=$clint_aw \
        -Mdir "$dir" -o tb_axi_xbar \
        $DESIGN test_benches/axi/tb_axi_xbar.sv
    echo "== run =="
    "$dir/tb_axi_xbar" || status=1
done
exit $status
