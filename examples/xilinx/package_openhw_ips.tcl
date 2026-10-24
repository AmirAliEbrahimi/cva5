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
# would both define it. The crossbar needs it (axi_lite_xbar's configuration
# struct is an axi_pkg type), which is why it is the only IP here that does,
# and why the AXI4-Lite fan-out lives inside it rather than in an IP of its
# own. A second IP that wants pulp AXI types has to spell its channel structs
# out by hand, the way cva5_axi_cut did before it was deleted.
dict set openhw_ips cva5_axi_xbar {
    third_party/axi/src/axi_pkg.sv
    third_party/common_cells/src/cf_math_pkg.sv
    third_party/common_cells/src/lzc.sv
    third_party/common_cells/src/counter.sv
    third_party/common_cells/src/delta_counter.sv
    third_party/common_cells/src/onehot_to_bin.sv
    third_party/common_cells/src/rr_arb_tree.sv
    third_party/common_cells/src/addr_decode.sv
    third_party/common_cells/src/fifo_v3.sv
    third_party/common_cells/src/spill_register_flushable.sv
    third_party/common_cells/src/spill_register.sv
    third_party/axi/src/axi_err_slv.sv
    examples/xilinx/vendor/axi_lite_to_axi.sv
    examples/xilinx/vendor/axi_lite_demux.sv
    examples/xilinx/vendor/axi_lite_mux.sv
    examples/xilinx/vendor/axi_lite_xbar.sv
    examples/xilinx/axi/cva5_axi_xbar.sv
}

# lowRISC's UART, replacing Xilinx's axi_uartlite. The register map is
# axi_uartlite's, so examples/sw and the QEMU machine are unchanged -- see the
# note at the top of examples/xilinx/vendor/uart.sv for that and the other
# divergence from upstream.
#
# fifo_v3 appears here and in cva5_axi_xbar, and these are the first two
# packaged IPs in one block design to share a module. The hazard the axi_pkg
# note above describes is specific to packages, which are compilation-unit
# scoped; identical copies of a module are not the same problem. If synthesis
# does complain that fifo_v3 is declared more than once, the fix is a renamed
# vendored copy for this IP, not a change to the UART.

# The CLINT, as a peripheral rather than something inside the CPU IP. mtime,
# mtip and msip leave as plain nets and land on cva5_top's interrupt inputs.
dict set openhw_ips cva5_clint_axi {
    examples/xilinx/vendor/cva5_clint.sv
    examples/xilinx/vendor/cva5_clint_wrapper.sv
    examples/xilinx/axi/cva5_clint_axi.sv
}

# pulp-platform's SPI master, replacing Xilinx's axi_quad_spi. Four chip
# selects, a clock divider, command/address/length registers and 32-bit TX and
# RX FIFOs. Solderpad 0.51.
#
# Listed straight from the submodule rather than vendored: the CLINT and the
# PLIC needed renamed copies because tools/compile_order compiles the apu/
# originals into the core simulation, and nothing here collides with that.
# These files carry no `include directives either, so tools/vendor-pulp-sv.py
# does not come into it.
#
# Its slave port is full AXI4; cva5_spi_axi presents an AXI4-Lite one and ties
# off the burst fields, which is all a single-beat master needs.
dict set openhw_ips cva5_spi_axi {
    third_party/axi_spi_master/spi_master_clkgen.sv
    third_party/axi_spi_master/spi_master_fifo.sv
    third_party/axi_spi_master/spi_master_rx.sv
    third_party/axi_spi_master/spi_master_tx.sv
    third_party/axi_spi_master/spi_master_controller.sv
    third_party/axi_spi_master/spi_master_axi_if.sv
    third_party/axi_spi_master/axi_spi_master.sv
    examples/xilinx/axi/cva5_spi_axi.sv
}

# Upstream CVA5's own PLIC, vendored under a new name -- the platform
# interrupt controller, aggregating device interrupts into the core's single
# external interrupt. The register map is the standard RISC-V one, so software
# written against QEMU's virt or a SiFive part works unchanged.
#
# Compile order matters here: the gateway and the comparison tree are
# instantiated by cva5_plic, which cva5_plic_wrapper instantiates in turn.
dict set openhw_ips cva5_plic_axi {
    examples/xilinx/vendor/cva5_plic_gateway.sv
    examples/xilinx/vendor/cva5_plic_cmptree.sv
    examples/xilinx/vendor/cva5_plic.sv
    examples/xilinx/vendor/cva5_plic_wrapper.sv
    examples/xilinx/axi/cva5_plic_axi.sv
}

dict set openhw_ips cva5_uart {
    third_party/common_cells/src/fifo_v3.sv
    examples/xilinx/vendor/uart.sv
    examples/xilinx/axi/cva5_uart.sv
}

# SIMULATION ONLY -- not packaged, not in the block design.
#
# cva5_axi_ram was an attempt to replace axi_bram_ctrl + blk_mem_gen with
# ZipCPU's demofull plus an inferred block-RAM array. It works and its
# testbench passes, but it cost 0.13 ns of setup slack against the Xilinx pair
# on this part at 100 MHz, so the block design kept the Xilinx IPs. That
# question is now moot in both directions: main memory moved inside the core
# as a tdp_ram driven by the local memory interface, and the block design has
# no memory IP of any kind. See README.pynq_z2.md for the measurements.
#
# Nothing instantiates it now either: the crossbar is AXI4-Lite on every port,
# so tb_axi_xbar's slaves are Lite register models and it no longer needs a
# bursting AXI4 slave. The file list stays because this is the thing to reach
# for if main memory ever moves back out of cva5_top, and because deleting a
# measured dead end loses the measurement. The loop below skips it, so nothing
# is packaged and nothing is synthesised.
dict set openhw_ips cva5_axi_ram {
    third_party/wb2axip/rtl/skidbuffer.v
    third_party/wb2axip/rtl/axi_addr.v
    third_party/wb2axip/rtl/demofull.v
    examples/xilinx/axi/cva5_axi_ram.sv
}

# AXI interfaces Vivado infers from the port names, to be bound to the clock.
dict set openhw_busifs cva5_axi_xbar {s_axi_cpu s_axi_dbg m_axi_uart m_axi_clint m_axi_plic}
dict set openhw_busifs cva5_axi_ram {s_axi}
dict set openhw_busifs cva5_uart {s_axi}
dict set openhw_busifs cva5_clint_axi {s_axi}
dict set openhw_busifs cva5_plic_axi {s_axi}
dict set openhw_busifs cva5_spi_axi {s_axi}

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
