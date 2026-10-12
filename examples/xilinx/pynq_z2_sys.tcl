#==============================================================================
# CVA5 SoC block design for the PYNQ-Z2
#
# Builds a CVA5 (RISC-V) soft SoC that runs a demo application from block
# memory, with an AXI UART Lite for I/O. A single slide switch (SW0) drives
# the system reset.
#
# Install the PYNQ-Z2 / Digilent board support files before running:
#   https://github.com/Digilent/vivado-boards
#==============================================================================

# ---- Project --------------------------------------------------------------
create_project -force -part xc7z020clg400-1 CVA5BD ./vivado/CVA5BD
set_property board_part tul.com.tw:pynq-z2:part0:1.0 [current_project]
set_property ip_repo_paths [list ./vivado/ip_repo ./vivado/ip_repo_openhw] [current_project]
update_ip_catalog

# ---- Block design ---------------------------------------------------------
create_bd_design "soc"

# ---- UART -----------------------------------------------------------------
# PYNQ-Z2's USB-UART bridge is wired to the PS (MIO), not the PL, so the PL
# UART is brought out as external pins and routed to a PMOD (see XDC).
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 axi_uartlite_0
make_bd_pins_external -name uart_tx [get_bd_pins axi_uartlite_0/tx]
make_bd_pins_external -name uart_rx [get_bd_pins axi_uartlite_0/rx]

# ---- Reset ----------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0
# Active-low external reset. The externalised reset_sw port inherits this, so
# the whole reset chain (switch, clk_wiz, proc_sys_reset) is active-low:
# switch LOW (down) = reset asserted, switch HIGH (up) = run.
set_property -dict [list CONFIG.C_EXT_RESET_HIGH {0}] [get_bd_cells proc_sys_reset_0]

# ---- Clock ----------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
# Active-low reset to match (this renames the port from 'reset' to 'resetn').
set_property -dict [list CONFIG.RESET_TYPE {ACTIVE_LOW}] [get_bd_cells clk_wiz_0]
apply_bd_automation -rule xilinx.com:bd_rule:board \
  -config { Board_Interface {sys_clock ( System Clock ) } Manual_Source {Auto}} \
  [get_bd_pins clk_wiz_0/clk_in1]

# ---- One switch drives BOTH resets (active-low) --------------------------
make_bd_pins_external -name reset_sw [get_bd_pins proc_sys_reset_0/ext_reset_in]
connect_bd_net [get_bd_ports reset_sw] [get_bd_pins clk_wiz_0/resetn]

# Tie the clock network into the reset block. Done BEFORE the AXI automation
# so that automation reuses proc_sys_reset_0 instead of spawning a duplicate.
connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked]   [get_bd_pins proc_sys_reset_0/dcm_locked]

# ---- Processor ------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_top:1.0 cva5_top_0
# Core clock + active-low reset (cva5_top exposes 'clk' and 'rstn').
connect_bd_net [get_bd_pins cva5_top_0/clk]  [get_bd_pins clk_wiz_0/clk_out1]
connect_bd_net [get_bd_pins cva5_top_0/rstn] [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

# ---- Clock and reset handles ----------------------------------------------
set sys_clk  [get_bd_pins clk_wiz_0/clk_out1]
set sys_rstn [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

# No AXI automation: there is no Xilinx interconnect in this design. The UART
# hangs off cva5_axi_xbar's peripheral port, wired explicitly below, so its
# clock and reset are connected here rather than by the automation rule.
connect_bd_net $sys_clk  [get_bd_pins axi_uartlite_0/s_axi_aclk]
connect_bd_net $sys_rstn [get_bd_pins axi_uartlite_0/s_axi_aresetn]

# ---- Main RAM: AXI BRAM, 128 KB at 0x4000_0000 -----------------------------
# Programs run from here: the CPU reaches it through its caches (m_axi_mem),
# the debugger loads it over SBA (m_axi_dbg).
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_0
set_property -dict [list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.DATA_WIDTH {32}] [get_bd_cells axi_bram_ctrl_0]
apply_bd_automation -rule xilinx.com:bd_rule:bram_cntlr -config {BRAM "Auto"} \
  [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA]
# Memory depth follows the 128 KB address range assigned below.
connect_bd_net $sys_clk  [get_bd_pins axi_bram_ctrl_0/s_axi_aclk]
connect_bd_net $sys_rstn [get_bd_pins axi_bram_ctrl_0/s_axi_aresetn]

# ---- Register slice on the cached path --------------------------------------
# cva5_axi_cut wraps pulp-platform's axi_cut and replaces Xilinx's
# axi_register_slice.
#
# It is load bearing, measured: removing it costs 0.321 ns, and the path that
# then fails runs from the crossbar's read skid buffer into the branch
# predictor's table. The read channel is the reason -- the crossbar runs in
# LatencyMode CUT_SLV_AX, which registers AW and AR only, so R is fall-through
# from the RAM all the way to the slave port, and CVA5's cache feeds rvalid
# straight into the fetch path. This cut terminates that.
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_axi_cut:1.0 slice_mem
connect_bd_net $sys_clk  [get_bd_pins slice_mem/clk]
connect_bd_net $sys_rstn [get_bd_pins slice_mem/rstn]
connect_bd_intf_net [get_bd_intf_pins cva5_top_0/m_axi_mem] [get_bd_intf_pins slice_mem/s_axi]

# ---- Crossbar -------------------------------------------------------------
# cva5_axi_xbar wraps pulp-platform's axi_xbar and replaces Xilinx's AXI
# Interconnect (which Vivado 2025.1 marks discontinued).
#
# Unlike the interconnect, the address decode lives inside the IP, as
# parameters taken from examples/sw/soc.h -- the Vivado address editor no
# longer decides it. An address in no window, or a master reaching for a
# slave it is not wired to, returns a DECERR rather than landing somewhere
# unexpected. The segments assigned below are bookkeeping for point-to-point
# links, not decoding.
#
#   m_axi      -> s_axi_cpu    peripherals only
#   m_axi_mem  -> s_axi_mem    RAM only (through the register slice)
#   m_axi_dbg  -> s_axi_dbg    both
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_axi_xbar:1.0 axi_xbar_0
connect_bd_net $sys_clk  [get_bd_pins axi_xbar_0/clk]
connect_bd_net $sys_rstn [get_bd_pins axi_xbar_0/rstn]

connect_bd_intf_net [get_bd_intf_pins cva5_top_0/m_axi]     [get_bd_intf_pins axi_xbar_0/s_axi_cpu]
connect_bd_intf_net [get_bd_intf_pins slice_mem/m_axi]      [get_bd_intf_pins axi_xbar_0/s_axi_mem]
connect_bd_intf_net [get_bd_intf_pins cva5_top_0/m_axi_dbg] [get_bd_intf_pins axi_xbar_0/s_axi_dbg]

connect_bd_intf_net [get_bd_intf_pins axi_xbar_0/m_axi_ram]    [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_xbar_0/m_axi_periph] [get_bd_intf_pins axi_uartlite_0/S_AXI]

# ---- Address map ----------------------------------------------------------
# Every link here is point to point, so nothing in the block design decodes
# an address. The crossbar passes the full address through and each slave
# takes the low bits of it, which is what the Xilinx interconnect did before;
# the segments therefore sit at the real addresses from examples/sw/soc.h and
# the address editor describes what the hardware actually does.
assign_bd_address

proc cva5_seg {args} {
    foreach p $args {
        set s [get_bd_addr_segs -quiet $p]
        if {$s ne ""} { return $s }
    }
    return ""
}

set ram_seg [cva5_seg {axi_xbar_0/m_axi_ram/SEG_axi_bram_ctrl_0_Mem0} \
                      {axi_xbar_0/m_axi_ram/SEG_axi_bram_ctrl_0_reg0}]
if {$ram_seg eq ""} { error "the crossbar's RAM port has no address segment" }
set_property offset 0x40000000 $ram_seg
set_property range  128K       $ram_seg

set uart_seg [cva5_seg {axi_xbar_0/m_axi_periph/SEG_axi_uartlite_0_Reg}]
if {$uart_seg eq ""} { error "the crossbar's peripheral port has no address segment" }
set_property offset 0x60000000 $uart_seg
set_property range  64K        $uart_seg

# ---- Finalise -------------------------------------------------------------
regenerate_bd_layout
validate_bd_design

make_wrapper -files [get_files ./vivado/CVA5BD/CVA5BD.srcs/sources_1/bd/soc/soc.bd] -top
add_files ./vivado/CVA5BD/CVA5BD.gen/sources_1/bd/soc/hdl/soc_wrapper.v
update_compile_order -fileset sources_1

# ---- Constraints ----------------------------------------------------------
# Save the XDC next to the project and point this at it.
add_files -fileset constrs_1 -norecurse ./examples/xilinx/pynq_z2_cva5.xdc

#---- Close the project ----------------------------------------------------------
close_project