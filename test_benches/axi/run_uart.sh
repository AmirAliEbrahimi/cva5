#!/usr/bin/env bash
# Lint and run the cva5_uart testbench under Verilator.
#   test_benches/axi/run_uart.sh
#
# lowRISC's UART behind its AXI4-Lite adapter, with tx tied back to rx, so one
# run covers the adapter, both FIFOs and both serial state machines.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

CC=third_party/common_cells/src
BUILD=test_benches/axi/build/uart

if [ ! -f $CC/fifo_v3.sv ]; then
    echo "common_cells is missing; run: git submodule update --init --recursive" >&2
    exit 1
fi

# One source of truth with the Vivado packaging script, so what is simulated
# here is exactly what gets synthesised.
DESIGN=$(python3 -I tools/ip-filelist.py cva5_uart)

# The adapter is held to -Wall. The vendored UART is not: it is upstream's code
# and its unused-signal tie-offs are deliberate.
echo "== lint =="
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
    -Wno-PINCONNECTEMPTY \
    --top-module cva5_uart $DESIGN

echo "== build =="
rm -rf "$BUILD"
mkdir -p "$BUILD"
# --assert turns on fifo_v3's full_write and empty_read properties.
verilator --binary -j 0 --timing --assert \
    -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -Wno-DECLFILENAME -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
    --top-module tb_cva5_uart \
    -Mdir "$BUILD" -o tb_cva5_uart \
    $DESIGN test_benches/axi/tb_cva5_uart.sv

echo "== run =="
"$BUILD/tb_cva5_uart"
