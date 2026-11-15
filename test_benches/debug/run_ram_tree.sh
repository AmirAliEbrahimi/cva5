#!/bin/sh
# Verilator testbench: three masters onto one cva5_ram_port through two
# cva5_ram_mux instances, the tree cva5_wrapper builds.
# Run from the repo root: sh test_benches/debug/run_ram_tree.sh
set -e
mkdir -p build/tb_ram_tree

verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style \
  -Wno-TIMESCALEMOD \
  examples/xilinx/debug/cva5_ram_mux.sv \
  examples/xilinx/debug/cva5_ram_port.sv \
  test_benches/debug/tb_ram_tree.sv \
  --top-module tb_ram_tree -Mdir build/tb_ram_tree

./build/tb_ram_tree/Vtb_ram_tree
