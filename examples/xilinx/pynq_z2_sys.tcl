#==============================================================================
# CVA5 SoC block design for the PYNQ-Z2
#
# Builds a CVA5 (RISC-V) soft SoC that runs a demo application from block
# memory inside the core, with an AXI UART Lite for I/O. A single slide
# switch (SW0) drives
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
#
# cva5_uart is lowRISC's UART behind an AXI4-Lite adapter, replacing Xilinx's
# axi_uartlite. It keeps axi_uartlite's register map, so examples/sw and the
# QEMU machine need no change; the baud rate is a module parameter rather than
# an IP setting, defaulting to the 9600 axi_uartlite was configured for.
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_uart:1.0 cva5_uart_0
make_bd_pins_external -name uart_tx [get_bd_pins cva5_uart_0/tx]
make_bd_pins_external -name uart_rx [get_bd_pins cva5_uart_0/rx]

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
# 128 KB of local memory, preloaded with the image examples/sw builds.
set_property -dict [list CONFIG.WORDS {32768} CONFIG.LOCAL_MEM {ram.mif}] [get_bd_cells cva5_top_0]
# Core clock + active-low reset (cva5_top exposes 'clk' and 'rstn').
connect_bd_net [get_bd_pins cva5_top_0/clk]  [get_bd_pins clk_wiz_0/clk_out1]
connect_bd_net [get_bd_pins cva5_top_0/rstn] [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

# ---- Clock and reset handles ----------------------------------------------
set sys_clk  [get_bd_pins clk_wiz_0/clk_out1]
set sys_rstn [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

# No AXI automation: there is no Xilinx interconnect in this design, and no
# Xilinx UART either. The UART hangs off cva5_axi_xbar's peripheral port,
# wired explicitly below, so its clock and reset are connected here rather
# than by the automation rule.
connect_bd_net $sys_clk  [get_bd_pins cva5_uart_0/clk]
connect_bd_net $sys_rstn [get_bd_pins cva5_uart_0/rstn]

# ---- CLINT ------------------------------------------------------------------
# A peripheral on the bus, not something inside the CPU IP. mtime is 64 bits
# and it leaves as 64 plain nets, which is the price of the CLINT being where
# it belongs; cva5_top is the core, its memory and its debug module.
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_clint_axi:1.0 cva5_clint_0
connect_bd_net $sys_clk  [get_bd_pins cva5_clint_0/clk]
connect_bd_net $sys_rstn [get_bd_pins cva5_clint_0/rstn]
connect_bd_net [get_bd_pins cva5_clint_0/mtime] [get_bd_pins cva5_top_0/mtime]
connect_bd_net [get_bd_pins cva5_clint_0/mtip]  [get_bd_pins cva5_top_0/mtip]
connect_bd_net [get_bd_pins cva5_clint_0/msip]  [get_bd_pins cva5_top_0/msip]

# ---- Main RAM ---------------------------------------------------------------
# There is no memory IP here any more. Main memory is a 128 KB true dual-port
# block RAM inside cva5_top, inferred from RTL -- no axi_bram_ctrl, no
# blk_mem_gen. Instruction fetch owns one port and load/store the other, both a
# single cycle away, which is why the core needs no caches: the data cache used
# to sit in front of this same on-chip RAM and paid for it with the worst path
# in the SoC.
#
# The register slice on the cached path went with the caches. It was load
# bearing while it existed -- removing it cost 0.321 ns, because the crossbar
# runs in LatencyMode CUT_SLV_AX and left R fall-through into the fetch path --
# but there is no cached path left for it to cut.
#
# The debugger still has to reach the RAM to load programs, and it does so
# without leaving cva5_top: the Debug Module's system bus is split inside the
# wrapper, RAM-window accesses going straight to the RAM's second port and
# everything else out m_axi_dbg to the crossbar. That used to be a loop out of
# cva5_top into the crossbar and back in through an s_axi_ram slave, which was
# an AXI4 port, a full crossbar master and a protocol conversion to carry the
# debugger's single-beat Lite writes to memory one centimetre.

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
#   m_axi      -> s_axi_cpu    the core's peripheral bus
#   m_axi_dbg  -> s_axi_dbg    the debugger, for anything outside the RAM
#
# Every port is AXI4-Lite now, masters and slaves alike, and there is one
# crossbar rather than an AXI4 crossbar feeding a Lite one through a converter.
# Nothing left on this bus bursts: main memory is answered inside cva5_top and
# the peripherals are registers. That dropped eleven source files, the AXI4-to-
# Lite converter and its skid buffers, and the ID machinery that only a
# multi-beat, multi-outstanding bus needs.
#
# The next peripheral -- the SPI controller, a PLIC -- is a rule, a port and a
# line here.
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_axi_xbar:1.0 axi_xbar_0
connect_bd_net $sys_clk  [get_bd_pins axi_xbar_0/clk]
connect_bd_net $sys_rstn [get_bd_pins axi_xbar_0/rstn]

connect_bd_intf_net [get_bd_intf_pins cva5_top_0/m_axi]     [get_bd_intf_pins axi_xbar_0/s_axi_cpu]
connect_bd_intf_net [get_bd_intf_pins cva5_top_0/m_axi_dbg] [get_bd_intf_pins axi_xbar_0/s_axi_dbg]

connect_bd_intf_net [get_bd_intf_pins axi_xbar_0/m_axi_uart]  [get_bd_intf_pins cva5_uart_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_xbar_0/m_axi_clint] [get_bd_intf_pins cva5_clint_0/s_axi]

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

set uart_seg [cva5_seg {axi_xbar_0/m_axi_uart/SEG_cva5_uart_0_reg0} \
                       {axi_xbar_0/m_axi_uart/SEG_cva5_uart_0_Reg} \
                       {axi_xbar_0/m_axi_uart/SEG_cva5_uart_0_s_axi}]
if {$uart_seg eq ""} { error "the crossbar's peripheral port has no address segment" }
# 4K, which is the aperture cva5_uart's 12-bit address port gives it. A wider
# range here is refused: the segment cannot be larger than the IP's address
# block. The crossbar decodes a 64 KB window to this port and the UART aliases
# within it, exactly as axi_uartlite's four registers did.
set_property offset 0x10000000 $uart_seg
set_property range  4K         $uart_seg

# 64K, matching cva5_clint_axi's 16-bit slave address port.
set clint_seg [cva5_seg {axi_xbar_0/m_axi_clint/SEG_cva5_clint_0_reg0} \
                        {axi_xbar_0/m_axi_clint/SEG_cva5_clint_0_Reg} \
                        {axi_xbar_0/m_axi_clint/SEG_cva5_clint_0_s_axi}]
if {$clint_seg eq ""} { error "the crossbar's CLINT port has no address segment" }
set_property offset 0x02000000 $clint_seg
set_property range  64K        $clint_seg

# ---- Finalise -------------------------------------------------------------
regenerate_bd_layout
validate_bd_design

make_wrapper -files [get_files ./vivado/CVA5BD/CVA5BD.srcs/sources_1/bd/soc/soc.bd] -top
add_files ./vivado/CVA5BD/CVA5BD.gen/sources_1/bd/soc/hdl/soc_wrapper.v
update_compile_order -fileset sources_1

# ---- Constraints ----------------------------------------------------------
# Save the XDC next to the project and point this at it.
add_files -fileset constrs_1 -norecurse ./examples/xilinx/pynq_z2_cva5.xdc

# The JTAG clock, its clock-domain crossing and the waiver for the methodology
# check they provoke go in a second file, restricted to implementation. They
# all name cells inside cva5_top, which is a packaged IP synthesised out of
# context: during top-level synthesis that hierarchy is a black box, so every
# query in there returns nothing and the constraints fail with "No valid
# object(s) found" even though the implementation run resolves them fine. And a
# waiver created in an interactive session does nothing for a run -- it has to
# be in the build.
add_files -fileset constrs_1 -norecurse ./examples/xilinx/pynq_z2_jtag.xdc
set_property USED_IN {implementation} \
    [get_files ./examples/xilinx/pynq_z2_jtag.xdc]

#---- Close the project ----------------------------------------------------------
close_project