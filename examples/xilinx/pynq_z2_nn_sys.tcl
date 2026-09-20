#==============================================================================
# CVA5 + CNN accelerator SoC for the PYNQ-Z2
#
# Extends examples/xilinx/pynq_z2_sys.tcl with an hls4ml-generated CNN
# accelerator reachable from CVA5 over AXI-Stream:
#
#   CVA5 m_axi (32b MM)
#     └─ AXI Interconnect
#          ├─ AXI Uartlite        0x6000_0000
#          ├─ AXI GPIO            0x6001_0000   ap_start out, status in
#          └─ AXI4-Stream FIFO    0x6002_0000
#               ├ AXI_STR_TXD (32b) → DWC 32→48 → cnn_0/x
#               └ AXI_STR_RXD (32b) ←──────────── cnn_0/layer9_out
#
# Prerequisites:
#   1. CVA5 packaged as IP:
#        vivado -mode batch -source examples/xilinx/package_as_ip_pynq_z2.tcl
#   2. Accelerator IP exported by tools/nn_accel/sweep.py, i.e. a directory
#        tools/nn_accel/sw_14_5_rf4/cnn_prj/solution1/impl/ip/
#   3. PYNQ-Z2 board files installed (Digilent/vivado-boards)
#   4. examples/sw/mem.mif built with: make -C examples/sw mif APP=bench
#
# Run from the repository root:
#   vivado -mode batch -source examples/xilinx/pynq_z2_nn_sys.tcl
#
# To also synthesize and implement (~25 min), append -tclargs build:
#   vivado -mode batch -source examples/xilinx/pynq_z2_nn_sys.tcl -tclargs build
#
# Normally driven by:  make -C tools/nn_accel bitstream
#==============================================================================

# ---- Configuration --------------------------------------------------------

# Arguments, all optional, normally supplied by tools/nn_accel/Makefile:
#   [0] build | nobuild   run implementation, or stop after the block design
#   [1] <ipdir>           hls4ml output directory name, e.g. sw_14_5_rf4
#   [2] <jobs>            Vivado parallelism
set DO_BUILD  [expr {[llength $argv] > 0 && [lindex $argv 0] eq "build"}]
set IP_NAME   [expr {[llength $argv] > 1 ? [lindex $argv 1] : "sw_14_5_rf4"}]
set JOBS      [expr {[llength $argv] > 2 ? [lindex $argv 2] : 4}]

set CNN_IP_DIR "./tools/nn_accel/$IP_NAME/cnn_prj/solution1/impl/ip"

# hls4ml names the output port after the final layer index, which depends on
# the network. Check firmware/cnn.cpp if the connection below fails.
set CNN_OUT_PORT "layer9_out"

# TDATA width of the accelerator input, in bytes. 48 bits = 6 bytes = one RGB
# pixel of ap_fixed<14,5> in three 16-bit lanes. If the IP reports [511:0]
# instead, it was generated without ChannelsLastConversion='internal'.
set CNN_IN_BYTES 6

if {![file isdirectory $CNN_IP_DIR]} {
    puts "ERROR: accelerator IP not found at $CNN_IP_DIR"
    puts "       run: make -C tools/nn_accel ip"
    exit 1
}

# ---- Project --------------------------------------------------------------
create_project -force -part xc7z020clg400-1 CVA5NN ./vivado/CVA5NN
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]
set_property ip_repo_paths [list ./vivado/ip_repo $CNN_IP_DIR] [current_project]
update_ip_catalog

create_bd_design "soc"

# ---- UART -----------------------------------------------------------------
# PYNQ-Z2's USB-UART bridge is wired to the PS (MIO), not the PL, so the PL
# UART is brought out as external pins and routed to a PMOD (see XDC).
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 axi_uartlite_0
make_bd_pins_external -name uart_tx [get_bd_pins axi_uartlite_0/tx]
make_bd_pins_external -name uart_rx [get_bd_pins axi_uartlite_0/rx]

# ---- Reset ----------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0
set_property -dict [list CONFIG.C_EXT_RESET_HIGH {0}] [get_bd_cells proc_sys_reset_0]

# ---- Clock ----------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list CONFIG.RESET_TYPE {ACTIVE_LOW}] [get_bd_cells clk_wiz_0]
apply_bd_automation -rule xilinx.com:bd_rule:board \
  -config { Board_Interface {sys_clock ( System Clock ) } Manual_Source {Auto}} \
  [get_bd_pins clk_wiz_0/clk_in1]

# ---- One switch drives BOTH resets (active-low) --------------------------
make_bd_pins_external -name reset_sw [get_bd_pins proc_sys_reset_0/ext_reset_in]
connect_bd_net [get_bd_ports reset_sw] [get_bd_pins clk_wiz_0/resetn]

connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked]   [get_bd_pins proc_sys_reset_0/dcm_locked]

# ---- Processor ------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_top:1.0 cva5_top_0

# Configure the IP instance rather than relying on its packaged defaults.
#
# WORDS sets the local memory depth in 32-bit words. It must match LENGTH in
# examples/sw/link.ld and RAM_SIZE on the examples/sw make line
# (WORDS * 4 == RAM_SIZE == LENGTH). The packaged default is whatever the RTL
# held when package_as_ip_pynq_z2.tcl last ran, which is not necessarily this.
#
# LOCAL_MEM must be an ABSOLUTE path. tdp_ram.sv does
# $readmemh(PRELOAD_FILE, mem, 0) with a relative filename, and if it does not
# resolve the block RAM comes up empty -- the CPU then executes garbage while
# the design still builds and closes timing, so the only symptom is silence.
set_property -dict [list \
    CONFIG.WORDS     {16384} \
    CONFIG.LOCAL_MEM [file normalize ./examples/sw/mem.mif] \
] [get_bd_cells cva5_top_0]

if {![file exists [file normalize ./examples/sw/mem.mif]]} {
    puts "ERROR: examples/sw/mem.mif not found."
    puts "       Build it first: make -C examples/sw mif APP=bench"
    exit 1
}
puts "LOCAL_MEM: [file normalize ./examples/sw/mem.mif]"

connect_bd_net [get_bd_pins cva5_top_0/clk]  [get_bd_pins clk_wiz_0/clk_out1]
connect_bd_net [get_bd_pins cva5_top_0/rstn] [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

# ---- Accelerator ----------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:hls:cnn:1.0 cnn_0
connect_bd_net [get_bd_pins cnn_0/ap_clk]    [get_bd_pins clk_wiz_0/clk_out1]
connect_bd_net [get_bd_pins cnn_0/ap_rst_n]  [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

# ---- Stream FIFO: the bridge from CVA5's memory-mapped bus to AXI-Stream --
# CVA5 has a single 32-bit AXI master and no slave port, so it cannot be a DMA
# target. This IP is a memory-mapped slave with stream ports: no descriptors,
# no shared DDR.
#
# Enable Transmit Control is OFF: that port (AXI_STR_TXC) is for AXI Ethernet
# control frames and would otherwise dangle.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_fifo_mm_s:4.3 axi_fifo_mm_s_0
set_property -dict [list \
    CONFIG.C_DATA_INTERFACE_TYPE {0} \
    CONFIG.C_USE_TX_DATA {1} \
    CONFIG.C_USE_TX_CTRL {0} \
    CONFIG.C_USE_RX_DATA {1} \
    CONFIG.C_TX_FIFO_DEPTH {512} \
    CONFIG.C_RX_FIFO_DEPTH {512} \
    CONFIG.C_HAS_AXIS_TKEEP {false} \
    CONFIG.C_HAS_AXIS_TSTRB {false} \
] [get_bd_cells axi_fifo_mm_s_0]

# ---- Width converter: 32b words in, 48b pixels out ------------------------
# 48 bits does not divide into 32, so two pixels span exactly three words.
# Any transfer chunk must be a multiple of 3 words -- see examples/sw/bench.c.
create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter:1.1 axis_dwidth_converter_0
set_property -dict [list \
    CONFIG.S_TDATA_NUM_BYTES {4} \
    CONFIG.M_TDATA_NUM_BYTES $CNN_IN_BYTES \
] [get_bd_cells axis_dwidth_converter_0]
connect_bd_net [get_bd_pins axis_dwidth_converter_0/aclk]    [get_bd_pins clk_wiz_0/clk_out1]
connect_bd_net [get_bd_pins axis_dwidth_converter_0/aresetn] [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

# ---- GPIO: ap_start out, {ready,idle,done} in -----------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_0
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {1} \
    CONFIG.C_ALL_OUTPUTS {1} \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO2_WIDTH {3} \
    CONFIG.C_ALL_INPUTS_2 {1} \
] [get_bd_cells axi_gpio_0]

# GPIO wants one vector, the accelerator gives three pins.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0
set_property -dict [list CONFIG.NUM_PORTS {3}] [get_bd_cells xlconcat_0]

# cnn_0 has no TLAST. The stream FIFO needs one to complete a packet, so tie
# it high: each result word becomes its own packet, which is correct because
# one inference produces exactly one 32-bit result.
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_0
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells xlconstant_0]

# ---- Stream wiring --------------------------------------------------------
# Connect at INTERFACE level. Pin-by-pin wiring leaves signals (usually
# TREADY) floating while the diagram still looks connected.
connect_bd_intf_net [get_bd_intf_pins axi_fifo_mm_s_0/AXI_STR_TXD] \
                    [get_bd_intf_pins axis_dwidth_converter_0/S_AXIS]
connect_bd_intf_net [get_bd_intf_pins axis_dwidth_converter_0/M_AXIS] \
                    [get_bd_intf_pins cnn_0/x]
connect_bd_intf_net [get_bd_intf_pins cnn_0/$CNN_OUT_PORT] \
                    [get_bd_intf_pins axi_fifo_mm_s_0/AXI_STR_RXD]
connect_bd_net [get_bd_pins xlconstant_0/dout] \
               [get_bd_pins axi_fifo_mm_s_0/axi_str_rxd_tlast]

# ---- Control wiring -------------------------------------------------------
connect_bd_net [get_bd_pins axi_gpio_0/gpio_io_o] [get_bd_pins cnn_0/ap_start]
connect_bd_net [get_bd_pins cnn_0/ap_done]  [get_bd_pins xlconcat_0/In0]
connect_bd_net [get_bd_pins cnn_0/ap_idle]  [get_bd_pins xlconcat_0/In1]
connect_bd_net [get_bd_pins cnn_0/ap_ready] [get_bd_pins xlconcat_0/In2]
connect_bd_net [get_bd_pins xlconcat_0/dout] [get_bd_pins axi_gpio_0/gpio2_io_i]

# ---- Processor -> peripherals via AXI interconnect ------------------------
# Automation creates the interconnect on the first call and extends it on the
# rest, reusing proc_sys_reset_0 because the clock network is already tied in.
foreach slave { /axi_uartlite_0/S_AXI /axi_gpio_0/S_AXI /axi_fifo_mm_s_0/S_AXI } {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
      -config [list Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
                    Master {/cva5_top_0/m_axi} Slave $slave \
                    ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}] \
      [get_bd_intf_pins $slave]
}

# ---- Address map ----------------------------------------------------------
# Auto-assign puts one peripheral at 0x0, which is the null-pointer address: a
# stray write through an uninitialised pointer would toggle ap_start instead
# of trapping. These must match the constants in examples/sw/bench.c.
set_property offset 0x60000000 [get_bd_addr_segs {cva5_top_0/m_axi/SEG_axi_uartlite_0_Reg}]
set_property offset 0x60010000 [get_bd_addr_segs {cva5_top_0/m_axi/SEG_axi_gpio_0_Reg}]
set_property offset 0x60020000 [get_bd_addr_segs {cva5_top_0/m_axi/SEG_axi_fifo_mm_s_0_Mem0}]

# ---- Finalise -------------------------------------------------------------
regenerate_bd_layout
validate_bd_design

make_wrapper -files [get_files ./vivado/CVA5NN/CVA5NN.srcs/sources_1/bd/soc/soc.bd] -top
add_files ./vivado/CVA5NN/CVA5NN.gen/sources_1/bd/soc/hdl/soc_wrapper.v
update_compile_order -fileset sources_1

add_files -fileset constrs_1 -norecurse ./examples/xilinx/pynq_z2_cva5.xdc

# ---- Optional build -------------------------------------------------------
# The default implementation strategy misses timing by ~70 ps on the conv2
# multiplier path (combinational DSP48E1 into a carry chain, 9.84 ns of a
# 10 ns budget). Performance_ExplorePostRoutePhysOpt closes at about
# WNS +0.139 ns.
if {$DO_BUILD} {
    set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
    launch_runs impl_1 -to_step write_bitstream -jobs $JOBS
    wait_on_run impl_1
    puts "\n---- timing ----"
    open_run impl_1
    report_timing_summary -max_paths 1 -file ./vivado/CVA5NN/timing_summary.rpt
    puts [report_timing_summary -no_header -no_detailed_paths -return_string]
    report_utilization -file ./vivado/CVA5NN/utilization.rpt
    puts "\nbitstream: ./vivado/CVA5NN/CVA5NN.runs/impl_1/soc_wrapper.bit"
} else {
    puts "\nBlock design built. To implement:"
    puts "  open ./vivado/CVA5NN/CVA5NN.xpr and set impl strategy to"
    puts "  Performance_ExplorePostRoutePhysOpt, or re-run this script with"
    puts "  -tclargs build"
}

close_project
