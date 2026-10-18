#!/bin/sh
# Verilator testbench: the vendored CLINT's prescaled mtime, against an
# instance with TICKS_PER_USEC = 1 that must behave as upstream did.
# Run from the repo root: sh test_benches/debug/run_clint.sh
set -e
mkdir -p build/tb_clint
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  examples/xilinx/vendor/cva5_clint.sv \
  test_benches/debug/tb_clint.sv \
  --top-module tb_clint -Mdir build/tb_clint
./build/tb_clint/Vtb_clint
