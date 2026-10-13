#!/bin/sh
# Verilator testbench: cva5_ram_port arbitrating the real tdp_ram between the
# core's local memory port and an AXI4 master.
# Run from the repo root: sh test_benches/debug/run_ram_port.sh
set -e
mkdir -p build/tb_ram_port
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  core/common_components/ram/tdp_ram.sv \
  examples/xilinx/debug/cva5_ram_port.sv \
  test_benches/debug/tb_ram_port.sv \
  --top-module tb_ram_port -Mdir build/tb_ram_port
./build/tb_ram_port/Vtb_ram_port
