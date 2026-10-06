#==============================================================================
# Package the open-hardware AXI blocks as Vivado IP.
#
#   source ./examples/fpga/package_openhw_ips.tcl
#
# Run this from the repository root, before pynq_z2_sys.tcl. Each IP lands in
# its own directory under ./vivado/ip_repo_openhw, which pynq_z2_sys.tcl adds
# to the project's IP repository paths alongside ./vivado/ip_repo (the CVA5
# core IP, packaged by package_as_ip_pynq_z2.tcl).
#
# Needs the submodules:  git submodule update --init --recursive
#
# These replace the Xilinx AXI infrastructure IPs one at a time. Only the
# blocks a PL-only SoC cannot provide itself stay Xilinx: the MMCM (clk_wiz).
#==============================================================================

set openhw_repo ./vivado/ip_repo_openhw

# Each entry: IP name -> source files, top module first.
#
# The files under examples/fpga/vendor are generated include-free copies of
# pulp-platform sources; see tools/vendor-pulp-sv.py for why they exist.
dict set openhw_ips cva5_axi_cut {
    examples/fpga/axi/cva5_axi_cut.sv
    examples/fpga/vendor/axi_cut.sv
    third_party/common_cells/src/spill_register.sv
    third_party/common_cells/src/spill_register_flushable.sv
}

# AXI interfaces Vivado infers from the port names, to be bound to the clock.
dict set openhw_busifs cva5_axi_cut {s_axi m_axi}

foreach ip [dict keys $openhw_ips] {
    set files [dict get $openhw_ips $ip]
    set out   $openhw_repo/$ip

    foreach f $files {
        if {![file exists $f]} {
            error "$ip: missing $f -- run 'git submodule update --init --recursive'"
        }
    }

    puts "==> packaging $ip"
    create_project -force -part xc7z020clg400-1 ${ip}_pkg ./vivado/${ip}_pkg
    add_files -norecurse $files
    set_property top $ip [current_fileset]
    update_compile_order -fileset sources_1

    ipx::package_project -root_dir $out -vendor xilinx.com -library user \
        -taxonomy /UserIP -import_files -set_current false -force
    ipx::unload_core $out/component.xml
    ipx::edit_ip_in_project -upgrade true -name ${ip}_edit -directory $out \
        $out/component.xml
    ipx::update_source_project_archive -component [ipx::current_core]

    # Vivado infers the AXI interfaces from the port names, but not which
    # clock drives them. The block design wires clk and rstn by hand, so this
    # is only so the interfaces report a clock domain.
    foreach busif [dict get $openhw_busifs $ip] {
        ipx::associate_bus_interfaces -busif $busif -clock clk [ipx::current_core]
    }

    ipx::create_xgui_files [ipx::current_core]
    ipx::update_checksums [ipx::current_core]
    ipx::check_integrity [ipx::current_core]
    ipx::save_core [ipx::current_core]
    ipx::move_temp_component_back -component [ipx::current_core]
    close_project -delete
    close_project
    puts "==> $ip packaged in $out"
}
