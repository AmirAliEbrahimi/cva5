#!/bin/sh
# Build and run the JTAG simulation harness, then drive it with OpenOCD:
#
#   sh test_benches/debug/run_jtag.sh            # build and run, waits for a debugger
#   openocd -f test_benches/debug/cva5-sim.cfg -c "init; sim_check; shutdown"
#
# Run from the repo root. boot.mif is copied here automatically.
set -e
ROOT=$(pwd)
RD=$ROOT/third_party/riscv-dbg
CC=third_party/common_cells/src
OUT=build/tb_jtag
mkdir -p $OUT

if [ ! -f examples/sw/boot.mif ]; then
  echo "examples/sw/boot.mif missing; build it with: make -C examples/sw boot"
  exit 1
fi
cp examples/sw/boot.mif .

# The DPI sources are C. Verilator would hand them to g++, whose name mangling
# leaves jtag_tick undefined at link time, so build them with gcc first.
gcc -c -O1 -I$RD/tb/remote_bitbang \
    $RD/tb/remote_bitbang/sim_jtag.c $RD/tb/remote_bitbang/remote_bitbang.c
ar rcs $OUT/libsimjtag.a sim_jtag.o remote_bitbang.o
rm -f sim_jtag.o remote_bitbang.o

# dmi_jtag_tap replaces dmi_bscane_tap here: a simulation cannot drive the
# FPGA's own TAP. Both files define the same module, so only one is compiled.
verilator --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-style \
  -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN \
  -Ithird_party/common_cells/include -LDFLAGS "$ROOT/$OUT/libsimjtag.a" \
  $(grep -v '^[[:space:]]*$' tools/compile_order) \
  $CC/cdc_reset_ctrlr_pkg.sv $CC/sync.sv $CC/spill_register_flushable.sv \
  $CC/spill_register.sv $CC/cdc_4phase.sv $CC/cdc_reset_ctrlr.sv \
  examples/xilinx/debug/vendor/cdc_2phase_clearable.sv $CC/fifo_v3.sv \
  $CC/deprecated/fifo_v2.sv \
  $RD/src/dm_pkg.sv $RD/debug_rom/debug_rom.sv $RD/debug_rom/debug_rom_one_scratch.sv \
  $RD/src/dm_csrs.sv $RD/src/dm_mem.sv $RD/src/dmi_cdc.sv \
  $RD/src/dm_sba.sv $RD/src/dm_top.sv $RD/src/dmi_jtag.sv $RD/src/dmi_jtag_tap.sv \
  test_benches/debug/tc_clk_sim.sv \
  examples/xilinx/debug/dm_sba_axil.sv examples/xilinx/debug/cva5_debug_subsys.sv \
  examples/xilinx/debug/dm_mem_port.sv \
  examples/xilinx/cva5_wrapper.sv \
  $RD/tb/SimJTAG.sv test_benches/debug/tb_jtag.sv \
  --top-module tb_jtag -Mdir $OUT

exec ./$OUT/Vtb_jtag
