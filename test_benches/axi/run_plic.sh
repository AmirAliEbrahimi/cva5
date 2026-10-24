#!/usr/bin/env bash
# Lint and run the cva5_plic_axi testbench under Verilator, and check that the
# vendored copies still match apu/plic.
#   bash test_benches/axi/run_plic.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

# The vendored copies differ from apu/plic by exactly one thing: the module
# names. Prove it rather than trust it -- rename upstream the same way and
# compare from `module` down, so the licence header and the vendoring note are
# ignored but a single changed line of logic is not.
RENAME='s/\bmodule (plic|plic_gateway|plic_cmptree|plic_wrapper)\b/module cva5_\1/; s/^(\s*)(plic_gateway|plic_cmptree|plic)(\s+#\()/\1cva5_\2\3/'
for f in plic plic_gateway plic_cmptree plic_wrapper; do
    if ! diff -q \
        <(sed -E "$RENAME" "apu/plic/$f.sv" | sed -n '/^module /,$p') \
        <(sed -n '/^module /,$p' "examples/xilinx/vendor/cva5_$f.sv") >/dev/null
    then
        echo "examples/xilinx/vendor/cva5_$f.sv has drifted from apu/plic/$f.sv:" >&2
        diff <(sed -E "$RENAME" "apu/plic/$f.sv" | sed -n '/^module /,$p') \
             <(sed -n '/^module /,$p' "examples/xilinx/vendor/cva5_$f.sv") >&2 || true
        exit 1
    fi
done
echo "== vendored PLIC matches apu/plic (names aside) =="

BUILD=test_benches/axi/build/plic

# One source of truth with the Vivado packaging script, so what is simulated
# here is exactly what gets synthesised.
DESIGN=$(python3 -I tools/ip-filelist.py cva5_plic_axi)

# Upstream style in apu/plic, all of it in code this fork only renamed:
#
#   PINCONNECTEMPTY  plic.sv leaves the comparison tree's highest_priority and
#                    highest_valid unconnected, and this IP leaves the
#                    wishbone side of the wrapper unconnected.
#   UNDRIVEN         wb_dat_o, for the same reason: AXI = 1 selects the other
#                    port and the wishbone outputs go nowhere.
#   LATCH            the wrapper's bus state machine is a `unique case` over
#                    every value of its 5-state enum with no default. Three of
#                    the eight encodings of the 3-bit state are unreachable --
#                    reset forces IDLE and every transition names a state --
#                    and `unique case` is a full-case hint, so Vivado infers
#                    no latch. Verilator does not apply the hint here.
#   ASCRANGE         `logic[NUM_SOURCES:1] irq_srcs` meeting this IP's
#                    [NUM_SOURCES-1:0] port, which is the bit numbering the
#                    spec uses meeting what a block design can carry.
UPSTREAM_NOISE="-Wno-UNUSEDSIGNAL -Wno-ASCRANGE -Wno-WIDTHEXPAND
                -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY
                -Wno-UNDRIVEN -Wno-LATCH"

echo "== lint (our wrapper is held to -Wall) =="
verilator --lint-only -Wall $UPSTREAM_NOISE --top-module cva5_plic_axi $DESIGN

# Three configurations: eight sources, which exercises the priority tree, the
# edge path and ties; two, which is what the block design deploys now that the
# SPI's interrupt is wired alongside the UART's; and one, which is the narrowest
# the PLIC can be built and takes different widths inside it -- a 1-bit claim id
# and a 2-entry padded source vector. Testing only the wide one would leave the
# shipped configuration unexercised.
#
# How the sources reach a 2-source PLIC through cva5_irq_concat, and which port
# becomes which source number, is tb_irq_concat's job.
rm -rf "$BUILD"
status=0
for n in 8 2 1; do
    dir="$BUILD/src$n"
    echo "== build (NUM_SOURCES=$n) =="
    mkdir -p "$dir"
    verilator --binary -j 0 --timing \
        $UPSTREAM_NOISE -Wno-BLKSEQ -Wno-INITIALDLY -Wno-WIDTHTRUNC \
        --top-module tb_plic -GNUM_SOURCES=$n \
        -Mdir "$dir" -o tb_plic \
        $DESIGN test_benches/axi/tb_plic.sv
    echo "== run =="
    "$dir/tb_plic" || status=1
done
exit $status
