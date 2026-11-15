#!/bin/sh
# Verilator testbench: cva5_accel_axi end to end -- software programs a
# transfer, the DMA reads an image, the lane select narrows it, a model
# accelerator consumes it, and software reads the result back.
# Run from the repo root: sh test_benches/axi/run_accel.sh
set -e
mkdir -p build/tb_accel

verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  examples/xilinx/axi/cva5_accel_axi.sv \
  examples/xilinx/axi/cva5_axis_lane.sv \
  third_party/wb2axip/rtl/aximm2s.v \
  third_party/wb2axip/rtl/skidbuffer.v \
  third_party/wb2axip/rtl/sfifo.v \
  test_benches/axi/tb_accel.sv \
  --top-module tb_accel -Mdir build/tb_accel

timeout 120 ./build/tb_accel/Vtb_accel
