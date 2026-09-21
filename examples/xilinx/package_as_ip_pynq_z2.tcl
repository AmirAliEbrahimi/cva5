puts "This script will create a project for CVA5 in the ./vivado folder and package it as an IP"

# Create the project
create_project -force -part xc7z020clg400-1 CVA5IP ./vivado/CVA5IP
add_files -force {core examples/xilinx examples/sw}

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

# ---- Cached memory path: CVA5's AXI4 adapter for the I$/D$ line fills
# (its remaining dependencies live under core/, added above)
add_files -norecurse {
    apu/busses/multicore_arbiter.sv
    apu/busses/axi_adapter.sv
}
# cdc_2phase_clearable comes from examples/xilinx/debug/vendor/ (added with
# examples/xilinx above): a copy with its `include removed, because
# -import_files flattens the sources and the include path would not resolve.

set_property top cva5_top [current_fileset]
update_compile_order -fileset sources_1

# Now package as IP using intermediate project
ipx::package_project -root_dir ./vivado/ip_repo -vendor xilinx.com -library user -taxonomy /UserIP -import_files -set_current false -force
ipx::unload_core ./vivado/ip_repo/component.xml
ipx::edit_ip_in_project -upgrade true -name tmp_edit_project -directory ./vivado/ip_repo ./vivado/ip_repo/component.xml
ipx::update_source_project_archive -component [ipx::current_core]
ipx::associate_bus_interfaces -busif m_axi_dbg -clock clk [ipx::current_core]
ipx::associate_bus_interfaces -busif m_axi_mem -clock clk [ipx::current_core]
ipx::create_xgui_files [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::check_integrity [ipx::current_core]
ipx::save_core [ipx::current_core]
ipx::move_temp_component_back -component [ipx::current_core]
close_project -delete
close_project
