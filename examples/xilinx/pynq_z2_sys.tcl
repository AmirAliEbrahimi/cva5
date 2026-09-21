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
set_property ip_repo_paths ./vivado/ip_repo [current_project]
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

# ---- Processor -> UART via AXI interconnect -------------------------------
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
  -config { Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
            Master {/cva5_top_0/m_axi} Slave {/axi_uartlite_0/S_AXI} \
            ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} \
  [get_bd_intf_pins axi_uartlite_0/S_AXI]

# ---- Main RAM: AXI BRAM, 128 KB at 0x4000_0000 -----------------------------
# Programs run from here: the CPU reaches it through its caches (m_axi_mem),
# the debugger loads it over SBA (m_axi_dbg).
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_0
set_property -dict [list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.DATA_WIDTH {32}] [get_bd_cells axi_bram_ctrl_0]
apply_bd_automation -rule xilinx.com:bd_rule:bram_cntlr -config {BRAM "Auto"} \
  [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA]
# Memory depth follows the 128 KB address range assigned below.

# ---- One interconnect for every master -------------------------------------
# All three masters (CPU peripherals m_axi, CPU cached memory via slice_mem,
# debugger SBA m_axi_dbg) share the interconnect the CPU->UART automation
# created, so each can reach both the UART and the RAM. The ports are wired
# explicitly: apply_bd_automation refuses an existing interconnect when the
# master is a register slice's M_AXI.
set intc [get_bd_cells -of_objects [get_bd_intf_pins -of_objects \
            [get_bd_intf_nets -of_objects [get_bd_intf_pins axi_uartlite_0/S_AXI]] \
            -filter {MODE == Master}]]
set sys_clk  [get_bd_pins clk_wiz_0/clk_out1]
set sys_rstn [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

# A register slice on the cached path. The adapter computes arvalid
# combinationally out of its arbiter FIFO and the crossbar grants in the same
# cycle; without a break that path misses 100 MHz. One extra cycle on a line
# fill is irrelevant next to the BRAM access itself.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 slice_mem
connect_bd_intf_net [get_bd_intf_pins cva5_top_0/m_axi_mem] [get_bd_intf_pins slice_mem/S_AXI]
connect_bd_net $sys_clk  [get_bd_pins slice_mem/aclk]
connect_bd_net $sys_rstn [get_bd_pins slice_mem/aresetn]

# S00 = m_axi (already connected by the automation above), M00 = UART.
# Add S01 = cached memory path, S02 = debugger SBA, M01 = RAM.
set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {2}] [get_bd_cells $intc]

connect_bd_intf_net [get_bd_intf_pins slice_mem/M_AXI]        [get_bd_intf_pins $intc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins cva5_top_0/m_axi_dbg]   [get_bd_intf_pins $intc/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins $intc/M01_AXI]          [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]

foreach pin {S01_ACLK S02_ACLK M01_ACLK} {
    connect_bd_net $sys_clk [get_bd_pins $intc/$pin]
}
foreach pin {S01_ARESETN S02_ARESETN M01_ARESETN} {
    connect_bd_net $sys_rstn [get_bd_pins $intc/$pin]
}
connect_bd_net $sys_clk  [get_bd_pins axi_bram_ctrl_0/s_axi_aclk]
connect_bd_net $sys_rstn [get_bd_pins axi_bram_ctrl_0/s_axi_aresetn]

# ---- Address map ----------------------------------------------------------
assign_bd_address
set_property offset 0x60000000 [get_bd_addr_segs {cva5_top_0/m_axi/SEG_axi_uartlite_0_Reg}]
set_property offset 0x60000000 [get_bd_addr_segs {cva5_top_0/m_axi_dbg/SEG_axi_uartlite_0_Reg}]
set_property range  128K       [get_bd_addr_segs {cva5_top_0/m_axi_dbg/SEG_axi_bram_ctrl_0_Mem0}]
set_property offset 0x40000000 [get_bd_addr_segs {cva5_top_0/m_axi_dbg/SEG_axi_bram_ctrl_0_Mem0}]
# The cached path's address space stays with the master, but name it either
# way in case the register slice carries it.
proc cva5_seg {args} {
    foreach p $args {
        set s [get_bd_addr_segs -quiet $p]
        if {$s ne ""} { return $s }
    }
    return ""
}
set mem_ram_seg [cva5_seg {cva5_top_0/m_axi_mem/SEG_axi_bram_ctrl_0_Mem0} \
                          {slice_mem/M_AXI/SEG_axi_bram_ctrl_0_Mem0}]
if {$mem_ram_seg eq ""} { error "cached path has no RAM address segment" }
set_property range  128K       $mem_ram_seg
set_property offset 0x40000000 $mem_ram_seg
# The CPU's peripheral bus only decodes 0x6xxx_xxxx, so exclude RAM from it for now.
set cpu_ram_seg [get_bd_addr_segs -quiet {cva5_top_0/m_axi/SEG_axi_bram_ctrl_0_Mem0}]
if {$cpu_ram_seg ne ""} { exclude_bd_addr_seg $cpu_ram_seg }
# Likewise the cached path only ever targets RAM; keep the UART out of it.
set mem_uart_seg [cva5_seg {cva5_top_0/m_axi_mem/SEG_axi_uartlite_0_Reg} \
                           {slice_mem/M_AXI/SEG_axi_uartlite_0_Reg}]
if {$mem_uart_seg ne ""} { exclude_bd_addr_seg $mem_uart_seg }

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