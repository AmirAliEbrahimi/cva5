#!/bin/sh
# Verilator testbench: cva5_axis_lane, the 32-to-24 lane select between the
# DMA and the accelerator.
# Run from the repo root: sh test_benches/axi/run_axis_lane.sh
set -e
mkdir -p build/tb_axis_lane

# Held to -Wall on its own: it is ten lines of wires and a counter, and a
# width mistake in it is invisible everywhere downstream.
verilator --lint-only -Wall --timing -Wno-TIMESCALEMOD \
  --top-module cva5_axis_lane examples/xilinx/axi/cva5_axis_lane.sv

verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  examples/xilinx/axi/cva5_axis_lane.sv test_benches/axi/tb_axis_lane.sv \
  --top-module tb_axis_lane -Mdir build/tb_axis_lane

timeout 60 ./build/tb_axis_lane/Vtb_axis_lane
