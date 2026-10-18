#!/bin/sh
# Verilator testbench: the boot ROM's lui/jalr pair, decoded and checked
# against its ENTRY_ADDR parameter for six entry addresses.
# Run from the repo root: sh test_benches/debug/run_boot_rom.sh
set -e
mkdir -p build/tb_boot_rom
verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  examples/xilinx/vendor/boot_rom.sv \
  test_benches/debug/tb_boot_rom.sv \
  --top-module tb_boot_rom -Mdir build/tb_boot_rom
./build/tb_boot_rom/Vtb_boot_rom
