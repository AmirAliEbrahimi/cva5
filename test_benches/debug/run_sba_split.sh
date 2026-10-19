#!/bin/sh
# Verilator testbench: dm_sba_axil -> cva5_sba_split -> { cva5_ram_port +
# tdp_ram, a Lite peripheral model }. The debugger's path to memory, which
# every program load goes through.
# Run from the repo root: sh test_benches/debug/run_sba_split.sh
set -e
mkdir -p build/tb_sba_split

echo "== lint (ours is held to -Wall) =="
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
  --top-module cva5_sba_split examples/xilinx/debug/cva5_sba_split.sv

verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  core/common_components/ram/tdp_ram.sv \
  examples/xilinx/debug/cva5_ram_port.sv \
  examples/xilinx/debug/dm_sba_axil.sv \
  examples/xilinx/debug/cva5_sba_split.sv \
  test_benches/debug/tb_sba_split.sv \
  --top-module tb_sba_split -Mdir build/tb_sba_split
./build/tb_sba_split/Vtb_sba_split
