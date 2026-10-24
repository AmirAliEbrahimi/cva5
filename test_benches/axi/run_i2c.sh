#!/usr/bin/env bash
# Lint and run the cva5_i2c_axi testbench under Verilator.
#   bash test_benches/axi/run_i2c.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

if [ ! -f third_party/verilog-i2c/rtl/i2c_master_axil.v ]; then
    echo "submodule missing; run: git submodule update --init --recursive" >&2
    exit 1
fi

BUILD=test_benches/axi/build/i2c

# One source of truth with the Vivado packaging script, so what is simulated
# here is exactly what gets synthesised.
DESIGN=$(python3 -I tools/ip-filelist.py cva5_i2c_axi)

# Upstream style in third_party/verilog-i2c: Verilog-2001 throughout, so
# unsized constants and mixed-width arithmetic are everywhere.
#
# SELRANGE is the one worth naming: axis_fifo carries optional tid/tdest/tuser
# fields, and with them disabled -- which is how the I2C master instantiates it
# -- their bit selects index past the end of the packed register. Every one of
# those selects sits behind `ENABLE ? ... : 0` with ENABLE constant zero, so
# the expression is dead and synthesis drops it; Verilator range-checks it
# anyway.
UPSTREAM_NOISE="-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL
                -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-UNOPTFLAT
                -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-BLKSEQ -Wno-SYNCASYNCNET
                -Wno-SELRANGE -Wno-GENUNNAMED -Wno-IMPLICIT -Wno-ASCRANGE
                -Wno-PINCONNECTEMPTY -Wno-UNDRIVEN -Wno-VARHIDDEN -Wno-PINMISSING"

echo "== lint (our wrapper is held to -Wall) =="
verilator --lint-only -Wall $UPSTREAM_NOISE --top-module cva5_i2c_axi $DESIGN

echo "== build =="
rm -rf "$BUILD"
mkdir -p "$BUILD"
verilator --binary -j 0 --timing \
    $UPSTREAM_NOISE -Wno-INITIALDLY -Wno-MULTIDRIVEN \
    --top-module tb_i2c \
    -Mdir "$BUILD" -o tb_i2c \
    $DESIGN test_benches/axi/tb_i2c.sv

echo "== run =="
"$BUILD/tb_i2c"
