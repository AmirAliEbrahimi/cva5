puts "This script will create a project for CVA5 in the ./vivado folder and package it as an IP"

# Shared with package_openhw_ips.tcl; see that file for the warnings it answers.
source ./examples/xilinx/ip_metadata.tcl

# Create the project
create_project -force -part xc7z020clg400-1 CVA5IP ./vivado/CVA5IP

# core/ goes in whole: every file under it is reached from cva5_top.
add_files -force {core}

# ---- This board's wrapper and its debug subsystem
# Listed file by file rather than by adding examples/xilinx recursively. The
# recursive form also swept in the peripheral IPs' sources -- the crossbar, the
# UART, the CLINT, the PLIC, the SPI, their vendored pulp copies -- none of
# which cva5_top instantiates, and the packager reported each one:
#
#   WARNING: [IP_Flow 19-3833] Unreferenced file from the top module is not
#            packaged: '.../examples/xilinx/vendor/uart.sv'.
#
# Twenty-one of those, and a reader cannot tell the harmless ones from a file
# that went unreferenced because a connection was lost. Those blocks are
# packaged separately by package_openhw_ips.tcl; nothing here needs them.
set soc_files {
    examples/xilinx/vendor/boot_rom.sv
    examples/xilinx/debug/vendor/cdc_2phase_clearable.sv
    examples/xilinx/debug/dm_sba_axil.sv
    examples/xilinx/debug/dm_mem_port.sv
    examples/xilinx/debug/cva5_ram_port.sv
    examples/xilinx/debug/cva5_ram_mux.sv
    examples/xilinx/debug/cva5_sba_split.sv
    examples/xilinx/debug/cva5_debug_subsys.sv
    examples/xilinx/cva5_wrapper.sv
    examples/xilinx/cva5_top.v
}
add_files -norecurse $soc_files

# ---- The main memory's preload image
# tdp_ram does $readmemh(PRELOAD_FILE, ...) with cva5_top's LOCAL_MEM, which is
# the bare name "ram.mif", so the file has to be IN the packaged IP: an
# out-of-context synthesis run resolves it against its own run directory and
# nowhere else.
#
# This used to arrive by accident. The line above was once
# `add_files -force {core examples/xilinx examples/sw}`, and examples/sw
# carried ram.mif along with the C sources; narrowing that list to stop
# twenty-one unreferenced-file warnings took the .mif with it, and synthesis
# reported
#
#   WARNING: [Synth 8-4445] could not open $readmem data file 'ram.mif'
#
# and carried on with an uninitialised memory. That is almost invisible on the
# board: the core executes zeros from RAM, traps, and parks -- which is what
# the preload image does on purpose anyway, so a silent board looks correct
# either way. Programs loaded over JTAG are unaffected, which is everything
# except what runs before the first `make load`.
#
# Hence the check rather than just the add: a missing image should stop the
# build, not produce an IP that is wrong in a way nothing downstream notices.
if {![file exists examples/sw/ram.mif]} {
    error "examples/sw/ram.mif is missing -- run 'make -C examples/sw ram' first"
}
add_files -norecurse {examples/sw/ram.mif}

# ---- Debug subsystem: pulp-platform riscv-dbg v0.9.0 + common_cells v1.24.0
# Explicit list: riscv-dbg ships two dmi_jtag_tap variants; only the BSCANE2
# one is used here (debug over the board's own USB-JTAG).
set dbg_files {
    third_party/common_cells/src/cdc_reset_ctrlr_pkg.sv
    third_party/common_cells/src/sync.sv
    third_party/common_cells/src/spill_register_flushable.sv
    third_party/common_cells/src/spill_register.sv
    third_party/common_cells/src/cdc_4phase.sv
    third_party/common_cells/src/cdc_reset_ctrlr.sv
    third_party/common_cells/src/fifo_v3.sv
    third_party/common_cells/src/deprecated/fifo_v2.sv
    third_party/riscv-dbg/src/dm_pkg.sv
    third_party/riscv-dbg/debug_rom/debug_rom.sv
    third_party/riscv-dbg/debug_rom/debug_rom_one_scratch.sv
    third_party/riscv-dbg/src/dm_csrs.sv
    third_party/riscv-dbg/src/dm_mem.sv
    third_party/riscv-dbg/src/dmi_cdc.sv
    third_party/riscv-dbg/src/dmi_bscane_tap.sv
    third_party/riscv-dbg/src/dm_sba.sv
    third_party/riscv-dbg/src/dm_top.sv
    third_party/riscv-dbg/src/dmi_jtag.sv
}
add_files -norecurse $dbg_files

# Nothing from apu/ is added. apu/busses/axi_adapter.sv and
# apu/busses/multicore_arbiter.sv used to be listed here for the I$/D$ line
# fills; the caches went when main memory moved inside cva5_top onto the local
# memory interface, and the packager has been reporting both files unreferenced
# ever since. They stay in the tree for the multi-hart APU, which is what they
# are for.

set_property top cva5_top [current_fileset]
update_compile_order -fileset sources_1

# Now package as IP using intermediate project
ipx::package_project -root_dir ./vivado/ip_repo -vendor xilinx.com -library user -taxonomy /UserIP -import_files -set_current false -force
ipx::unload_core ./vivado/ip_repo/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project -directory ./vivado/ip_repo ./vivado/ip_repo/component.xml
ipx::update_source_project_archive -component [ipx::current_core]
ipx::associate_bus_interfaces -busif m_axi_dbg -clock clk [ipx::current_core]

set cva5_desc "CVA5 RV32IM soft processor: the core, its JTAG debug module and"
append cva5_desc " its local memory, with an AXI4-Lite master for peripherals"
append cva5_desc " and a second for the debugger's system bus"
cva5_ip_metadata $cva5_desc 100000000

ipx::create_xgui_files [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::check_integrity [ipx::current_core]
ipx::save_core [ipx::current_core]
ipx::move_temp_component_back -component [ipx::current_core]
close_project -delete
close_project
