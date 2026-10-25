#!/bin/sh
# Verilator testbench: cva5_ram_mux giving two AXI4 masters -- the debugger and
# an external one -- a turn each on the real cva5_ram_port.
# Run from the repo root: sh test_benches/debug/run_ram_mux.sh
set -e
mkdir -p build/tb_ram_mux

# The mux is held to -Wall on its own first. It is small, it is ours, and the
# arbitration is the kind of thing a width or a dangling signal hides in.
verilator --lint-only -Wall --timing -Wno-TIMESCALEMOD \
  --top-module cva5_ram_mux \
  examples/xilinx/debug/cva5_ram_mux.sv

verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  examples/xilinx/debug/cva5_ram_mux.sv \
  examples/xilinx/debug/cva5_ram_port.sv \
  test_benches/debug/tb_ram_mux.sv \
  --top-module tb_ram_mux -Mdir build/tb_ram_mux
./build/tb_ram_mux/Vtb_ram_mux
