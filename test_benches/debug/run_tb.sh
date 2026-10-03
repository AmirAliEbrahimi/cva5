#!/bin/sh
# Verilator testbench: DMI -> dm_top -> SBA -> dm_sba_axil -> AXI4-Lite RAM model
# Run from the repo root: sh test_benches/debug/run_tb.sh
set -e
mkdir -p build/tb_sba
RD=third_party/riscv-dbg; CC=third_party/common_cells/src
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  -Ithird_party/common_cells/include \
  $CC/cdc_reset_ctrlr_pkg.sv $CC/sync.sv $CC/fifo_v3.sv $CC/deprecated/fifo_v2.sv \
  $RD/src/dm_pkg.sv $RD/debug_rom/debug_rom.sv $RD/debug_rom/debug_rom_one_scratch.sv \
  $RD/src/dm_csrs.sv $RD/src/dm_mem.sv $RD/src/dm_sba.sv $RD/src/dm_top.sv \
  examples/xilinx/debug/dm_sba_axil.sv test_benches/debug/tb_sba.sv \
  --top-module tb_sba -Mdir build/tb_sba
./build/tb_sba/Vtb_sba
