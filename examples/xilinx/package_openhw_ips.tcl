#==============================================================================
# Package the open-hardware AXI blocks as Vivado IP.
#
#   source ./examples/xilinx/package_openhw_ips.tcl
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

# Sourced twice in one interactive Vivado session, `dict set` would add to
# whatever these already held, and an IP removed from this file would go on
# being packaged from the stale copy in memory. Start from nothing.
unset -nocomplain openhw_ips openhw_busifs openhw_sim_only

set openhw_repo ./vivado/ip_repo_openhw

# Each entry: IP name -> source files, in compile order: packages and leaf
# modules first, the wrapper (the IP's top) last. Verilator needs that order
# and reads these lists through tools/ip-filelist.py, so that what is
# simulated is exactly what is synthesised. Vivado is told the top module
# explicitly below and does its own dependency analysis.
#
# The files under examples/xilinx/vendor are generated self-contained copies of
# pulp-platform sources; see tools/vendor-pulp-sv.py for why they exist.
#
# Only one IP here may carry axi_pkg, or two packaged IPs in one block design
# would both define it. The crossbar needs it (axi_xbar's configuration struct
# is an axi_pkg type); cva5_axi_cut spells its channel structs out by hand
# instead so that it does not.
dict set openhw_ips cva5_axi_cut {
    third_party/common_cells/src/spill_register_flushable.sv
    third_party/common_cells/src/spill_register.sv
    examples/xilinx/vendor/axi_cut.sv
    examples/xilinx/axi/cva5_axi_cut.sv
}

dict set openhw_ips cva5_axi_xbar {
    third_party/axi/src/axi_pkg.sv
    third_party/common_cells/src/cf_math_pkg.sv
    third_party/common_cells/src/lzc.sv
    third_party/common_cells/src/counter.sv
    third_party/common_cells/src/delta_counter.sv
    third_party/common_cells/src/rr_arb_tree.sv
    third_party/common_cells/src/onehot_to_bin.sv
    third_party/common_cells/src/addr_decode.sv
    third_party/common_cells/src/fifo_v3.sv
    third_party/common_cells/src/spill_register_flushable.sv
    third_party/common_cells/src/spill_register.sv
    third_party/axi/src/axi_err_slv.sv
    third_party/axi/src/axi_id_prepend.sv
    examples/xilinx/vendor/axi_demux_simple.sv
    examples/xilinx/vendor/axi_demux.sv
    examples/xilinx/vendor/axi_mux.sv
    examples/xilinx/vendor/axi_multicut.sv
    examples/xilinx/vendor/axi_lite_to_axi.sv
    examples/xilinx/vendor/axi_xbar_unmuxed.sv
    examples/xilinx/vendor/axi_xbar.sv
    third_party/wb2axip/rtl/sfifo.v
    third_party/wb2axip/rtl/skidbuffer.v
    third_party/wb2axip/rtl/axi_addr.v
    third_party/wb2axip/rtl/axi2axilite.v
    examples/xilinx/axi/cva5_axi_xbar.sv
}

# SIMULATION ONLY -- not packaged, not in the block design.
#
# cva5_axi_ram was an attempt to replace axi_bram_ctrl + blk_mem_gen with
# ZipCPU's demofull plus an inferred block-RAM array. It works, and its
# testbench passes, but it costs 0.13 ns of setup slack against the Xilinx
# pair on this part at 100 MHz, so the block design keeps the Xilinx IPs.
# See README.pynq_z2.md for the measurements.
#
# The file list stays here so tools/ip-filelist.py can build the crossbar
# testbench's source list -- tb_axi_xbar uses this as its memory slave, which
# is a better test than a behavioural model because it is a real AXI4 slave.
# The loop below skips it, so nothing is packaged and nothing is synthesised.
dict set openhw_ips cva5_axi_ram {
    third_party/wb2axip/rtl/skidbuffer.v
    third_party/wb2axip/rtl/axi_addr.v
    third_party/wb2axip/rtl/demofull.v
    examples/xilinx/axi/cva5_axi_ram.sv
}

# AXI interfaces Vivado infers from the port names, to be bound to the clock.
dict set openhw_busifs cva5_axi_cut {s_axi m_axi}
dict set openhw_busifs cva5_axi_xbar {s_axi_cpu s_axi_mem s_axi_dbg m_axi_ram m_axi_periph}
dict set openhw_busifs cva5_axi_ram {s_axi}

# Entries present for the testbenches' file lists but deliberately not
# packaged. See the note above cva5_axi_ram.
set openhw_sim_only {cva5_axi_ram}

foreach ip [dict keys $openhw_ips] {
    if {[lsearch -exact $openhw_sim_only $ip] >= 0} {
        puts "package_openhw_ips: skipping $ip (simulation only)"
        continue
    }
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
