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
# The polarity of the external reset is declared on the port, below, not here.
# proc_sys_reset's C_EXT_RESET_HIGH is read-only in Vivado 2025.1 -- it takes
# the polarity by propagation from whatever drives ext_reset_in now -- so
# setting it directly fails:
#
#   CRITICAL WARNING: [BD 41-737] Cannot set the parameter C_EXT_RESET_HIGH on
#                     /proc_sys_reset_0. It is read-only.
#
# It failed silently in the sense that mattered: the design still came up
# active-low, because the net reset_sw also drives clk_wiz_0/resetn and that
# pin's polarity propagated into the port. The whole reset chain therefore
# depended on the clk_wiz connection for its sense, which is not something to
# leave implicit.
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0

# ---- Clock ----------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
# Active-low reset to match (this renames the port from 'reset' to 'resetn').
set_property -dict [list CONFIG.RESET_TYPE {ACTIVE_LOW}] [get_bd_cells clk_wiz_0]
# The board rule creates the sys_clock port and then sets its frequency, and
# complains about its own intermediate step on the way:
#
#   WARNING: [BD 5-670] It is required to provide a frequency value for a user
#            created input clock port. Please use the <-freq_hz $freq_val>
#            argument of the create_bd_port command.
#
# The advice is addressed to whoever creates the port, and that is Vivado: the
# INFO lines right after it show the rule creating sys_clock, setting FREQ_HZ to
# 100 MHz and then to the board's real 125 MHz. Creating the port here instead,
# with -freq_hz, would answer the warning and take the clock pin constraint away
# from the board file with it -- pynq_z2_cva5.xdc deliberately does not
# constrain that pin, so it would have to grow a PACKAGE_PIN and a create_clock
# that the board file currently supplies. Not worth it for a warning the tool
# raises about itself.
apply_bd_automation -rule xilinx.com:bd_rule:board \
  -config { Board_Interface {sys_clock ( System Clock ) } Manual_Source {Auto}} \
  [get_bd_pins clk_wiz_0/clk_in1]

# ---- One switch drives BOTH resets (active-low) --------------------------
# Created rather than externalised, so that the polarity is stated once, on the
# port, and both consumers take it from there:
# switch LOW (down) = reset asserted, switch HIGH (up) = run.
create_bd_port -dir I -type rst reset_sw
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports reset_sw]
connect_bd_net [get_bd_ports reset_sw] [get_bd_pins proc_sys_reset_0/ext_reset_in]
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

# ---- The PS, as a master into CVA5's main memory ---------------------------
# This is the first Xilinx IP here that is not replaceable and not a PLL: it is
# the hard processor system, so there is nothing to swap it for. Adding it also
# means this stops being a PL-only design: the PS runs software of its own,
# bare metal, and brings the PL up with it.
#
# What it buys: the PS can write a program into CVA5's main memory and release
# the core, which is what OpenOCD does over JTAG today but without the JTAG.
# The same port is what a DMA feeding an accelerator would use later --
# cva5_ram_mux arbitrates the two of them against the debugger.
#
# A GP port and not an HP port: HP ports are PS *slaves*, for PL masters
# reaching DDR. This is the PS mastering into the PL, which is what GP is for.
# 32 bits wide, which matches, so no data-width conversion.
#
# GP1 specifically, and the reason is the address. A Zynq-7000 GP master's
# window is fixed in the PS, not assignable: GP0 is 0x4000_0000-0x7FFF_FFFF
# and GP1 is 0x8000_0000-0xBFFF_FFFF (UG585 Table 4-1). Main memory is at
# 0x8000_0000, so GP0 cannot reach it at all --
#
#   ERROR: [BD 41-70] The proposed address '0x8000_0000 [ 128K ]' must fit an
#          available aperture through master interface '/ps7_0/M_AXI_GP0' into
#          address space '/ps7_0/Data'. Valid apertures are
#          {<0x4000_0000 [ 1G ]>}.
#
# GP0 would have worked only by giving the PS a different address for the same
# memory, 0x4000_0000 against the core's 0x8000_0000. That is a second number
# for one thing: examples/sw/soc.h would no longer describe the PS's view,
# tools/check-soc-map.py could not check it, and every loader would carry the
# offset. The two ports are otherwise identical -- same AXI3, same 12-bit IDs,
# same width -- so GP1 costs nothing and keeps one address for main memory.
#
# Only GP1 is enabled, and three of the preset's defaults are turned off:
# GP0 (see below), the USB controller, and the FCLK/FRST pair. The rest is left
# alone -- the DDR and MIO settings are the board's and this design has no
# business second-guessing them.
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7_0
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
  -config {make_external "FIXED_IO, DDR" apply_board_preset "1" \
           Master "Disable" Slave "Disable"} [get_bd_cells ps7_0]
# Only what this design needs is set. The board preset has already configured
# the DDR, the MIO and the clocks; overriding more of it here would be guessing
# at property names for no gain, and anything left at its preset default that
# does not reach a pin costs nothing.
#
# PCW_USE_M_AXI_GP0 is set to 0 explicitly. The board preset turns GP0 on, and
# enabling GP1 does not turn it off, so both ports appear and the unused one is
# left dangling -- which validate_bd_design catches, not elaboration:
#
#   WARNING: [BD 41-2670] Found an incomplete address path from address space
#            '/ps7_0/Data' to master interface '/ps7_0/M_AXI_GP0'.
#   ERROR: [BD 41-758] The following clock pins are not connected to a valid
#          clock source: /ps7_0/M_AXI_GP0_ACLK
#
# This is the one preset default overridden rather than left alone, because it
# is the one that costs something: a second PS master into the PL that nothing
# drives.
#
# USB0 off. The preset enables the board's USB host on MIO 28-39; nothing in
# this design or in the bare-metal loader touches it, and a peripheral left on
# is a block that has to be configured correctly to not misbehave.
#
# FCLK_CLK0 and FCLK_RESET0_N off. Both are PS outputs into the PL and both are
# unused here: the PL's clock comes from the board's own oscillator through
# clk_wiz, and its reset comes from reset_sw through proc_sys_reset. That is
# deliberate and not an oversight -- see the M_AXI_GP1_ACLK note below. Note
# what disabling them does NOT affect: the PS-PL level shifters, which are a
# separate PS register and are what the bare-metal FSBL's ps7_post_config()
# enables after the bitstream loads. Without that call the PS's writes never
# reach the PL, FCLK or no FCLK.
#
# What stays: DDR (bare-metal code and data live there), FIXED_IO (the MIO
# pins, PS_CLK and PS_SRSTB -- the PS does not boot without it), the MIO
# peripherals the preset set up, and the EMIO GPIO below.
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {0} \
    CONFIG.PCW_USE_M_AXI_GP1 {1} \
    CONFIG.PCW_USB0_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_EN_CLK0_PORT {0} \
    CONFIG.PCW_EN_RST0_PORT {0} \
    CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {1} \
    CONFIG.PCW_GPIO_EMIO_GPIO_IO {1} \
] [get_bd_cells ps7_0]

# Fail here, with the pin list in hand, rather than later with a dangling net.
# These three are what the properties above are for, and a property name that
# a future Vivado renames would otherwise leave them silently absent.
foreach pin {M_AXI_GP1_ACLK GPIO_O} {
    if {[llength [get_bd_pins -quiet ps7_0/$pin]] == 0} {
        error "ps7_0 has no $pin pin. The PS configuration above did not take\
 -- check the property names with: report_property \[get_bd_cells ps7_0\]"
    }
}
if {[llength [get_bd_intf_pins -quiet ps7_0/M_AXI_GP1]] == 0} {
    error "ps7_0 has no M_AXI_GP1 interface. PCW_USE_M_AXI_GP1 did not take."
}
# And the other way round: everything switched off must actually be gone. GP0
# left on fails validate_bd_design much later on a dangling M_AXI_GP0_ACLK; the
# other three would survive as unconnected pins and quietly undo the point of
# turning them off.
if {[llength [get_bd_intf_pins -quiet ps7_0/M_AXI_GP0]] != 0} {
    error "ps7_0 still has an M_AXI_GP0 interface. PCW_USE_M_AXI_GP0 0 did not\
 take, and an unconnected PS master will fail validate_bd_design."
}
if {[llength [get_bd_intf_pins -quiet ps7_0/USBIND_0]] != 0} {
    error "ps7_0 still has a USBIND_0 interface. PCW_USB0_PERIPHERAL_ENABLE 0\
 did not take."
}
foreach pin {FCLK_CLK0 FCLK_RESET0_N} {
    if {[llength [get_bd_pins -quiet ps7_0/$pin]] != 0} {
        error "ps7_0 still has a $pin pin. PCW_EN_CLK0_PORT /\
 PCW_EN_RST0_PORT 0 did not take."
    }
}
# GPIO_O is the one PS output this design does use, so it is checked for
# presence rather than absence -- that is the foreach above.

# The PS's AXI port runs on OUR clock, not on FCLK_CLK0. That is the whole
# reason there is no clock-domain crossing anywhere in this: M_AXI_GP1_ACLK is
# an input, so feeding it clk_out1 puts the port in the 100 MHz domain the rest
# of the design already lives in. Using FCLK_CLK0 instead would mean an axi_cdc
# and a second clock group in the XDC, for nothing.
connect_bd_net $sys_clk [get_bd_pins ps7_0/M_AXI_GP1_ACLK]

# AXI3 to AXI4. A Zynq-7000 PS master is AXI3: 4-bit burst length, WID on the
# write channel, no QOS or REGION. cva5_top's slave port is AXI4. The converter
# is instantiated here rather than left to apply_bd_automation because this
# script runs on every build and a conversion that automation inserts is
# invisible in it -- and if a future Vivado stops inserting one, the failure is
# a protocol violation at run time rather than an error here.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 ps_axi4_0
set_property -dict [list \
    CONFIG.SI_PROTOCOL {AXI3} \
    CONFIG.MI_PROTOCOL {AXI4} \
] [get_bd_cells ps_axi4_0]
connect_bd_net $sys_clk  [get_bd_pins ps_axi4_0/aclk]
connect_bd_net $sys_rstn [get_bd_pins ps_axi4_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7_0/M_AXI_GP1] \
                    [get_bd_intf_pins ps_axi4_0/S_AXI]

# ---- cpu_halt, from the PS's EMIO GPIO ------------------------------------
# The PS has to hold the core while it writes a program, or the core runs off
# into a half-written image. cpu_halt joins ndmreset in cva5_wrapper's CPU
# reset and is deliberately absent from the RAM path's reset, so the PS can
# hold the core and write memory at the same time -- the same thing OpenOCD's
# cpu_hold does with ndmreset.
#
# EMIO rather than an AXI4-Lite control register: it is one bit that changes
# twice per program load, so a register would cost a seventh crossbar port and
# a software driver to set one bit. EMIO costs a GPIO bank the PS already has.
#
# Bank 2 is the EMIO bank; bit 0 of it is cpu_halt. From Linux this is a
# gpiochip line, not an AXI write.
#
# No xlslice. PCW_GPIO_EMIO_GPIO_IO is 1, so GPIO_O is one bit wide and there
# is nothing to slice out of it -- and xlslice refuses the job anyway:
#
#   ERROR: [IP_Flow 19-3458] Validation failed for parameter 'Din
#          Width(DIN_WIDTH)' ... Value '1' is out of the range (2,4096)
#
# A single-bit vector connects to a scalar pin directly. Widening the EMIO
# bank to 2 bits just to give the slice something legal to do would be a
# wasted PS pin and an extra cell, and Vivado reports xlslice as unsupported
# from 2025.2 besides.
#
# The PS presents GPIO_I/GPIO_O/GPIO_T as one GPIO_0 interface, so taking a net
# off GPIO_O alone draws a warning:
#
#   WARNING: [BD 41-1306] The connection to interface pin </ps7_0/GPIO_O> is
#            being overridden by the user with net <ps7_0_GPIO_O>. This pin
#            will not be connected as a part of interface connection <GPIO_0>
#
# It is expected and the connection is made. Its caveat is about write_bd_tcl
# not reproducing the net, which does not apply here: this script IS the block
# design's source, not something generated from one.
connect_bd_net [get_bd_pins ps7_0/GPIO_O] [get_bd_pins cva5_top_0/cpu_halt]

# ---- The PS into main memory ----------------------------------------------
# cva5_ram_mux is behind this port and arbitrates it against the debugger's
# system bus. One owner at a time, alternating priority, and the owner is held
# until its response completes -- see the header of cva5_ram_mux.sv, in
# particular the note on what a master that stops accepting read data does to
# the other master.
connect_bd_intf_net [get_bd_intf_pins ps_axi4_0/M_AXI] \
                    [get_bd_intf_pins cva5_top_0/s_axi_ext]

# No AXI automation: there is no Xilinx interconnect in this design, and no
# Xilinx UART either. The UART hangs off cva5_axi_xbar's peripheral port,
# wired explicitly below, so its clock and reset are connected here rather
# than by the automation rule.
connect_bd_net $sys_clk  [get_bd_pins cva5_uart_0/clk]
connect_bd_net $sys_rstn [get_bd_pins cva5_uart_0/rstn]

# ---- CLINT ------------------------------------------------------------------
# A peripheral on the bus, not something inside the CPU IP. Two nets go back to
# cva5_top and they are interrupts, not data: RISC-V gives the timer and
# software interrupts their own mip bits (MTIP, cause 7; MSIP, cause 3), so
# they come from the CLINT directly and never through a PLIC, which aggregates
# device interrupts into MEIP alone. When the PLIC arrives, external makes
# three, and three is the whole of it however many peripherals the bus carries.
#
# mtime's 64-bit count does not go back. It fed one CSR (time/timeh) and the
# core now reports that CSR as unimplemented, so software reads the count where
# this peripheral publishes it, at CLINT_BASE + 0xBFF8. The port stays on the
# IP, unconnected, for a second hart or a wfi test that wants it.
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_clint_axi:1.0 cva5_clint_0
connect_bd_net $sys_clk  [get_bd_pins cva5_clint_0/clk]
connect_bd_net $sys_rstn [get_bd_pins cva5_clint_0/rstn]
connect_bd_net [get_bd_pins cva5_clint_0/mtip]  [get_bd_pins cva5_top_0/mtip]
connect_bd_net [get_bd_pins cva5_clint_0/msip]  [get_bd_pins cva5_top_0/msip]

# ---- PLIC -------------------------------------------------------------------
# The platform interrupt controller: every device interrupt on the bus arrives
# here and leaves as one wire, eip, which is the core's external interrupt.
# Together with the CLINT's two that makes three interrupt inputs on cva5_top,
# and three is all RISC-V gives a hart however many peripherals the bus grows.
#
# NUM_SOURCES is 2: the UART and the SPI. The sources themselves are wired
# below, once the SPI cell exists.
#
# EDGE_SENSITIVE stays 0 for both, which is also right for the SPI's pulse --
# see the interrupt-sources section for why. Sensitivity is a parameter rather
# than a port so that unused sources need nothing tied to them, which on a
# block design would otherwise mean a Xilinx constant block.
#
# Reset from rstn alone, never ndmreset, for the same reason as the CLINT: the
# debugger can reach it over the system bus. Note what that means for software:
# the pending bits, the enables and the priorities all survive a program
# reload, so a test has to put the PLIC into a known state before trusting it.
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_plic_axi:1.0 cva5_plic_0
set_property -dict [list CONFIG.NUM_SOURCES {2}] [get_bd_cells cva5_plic_0]
connect_bd_net $sys_clk  [get_bd_pins cva5_plic_0/clk]
connect_bd_net $sys_rstn [get_bd_pins cva5_plic_0/rstn]
connect_bd_net [get_bd_pins cva5_plic_0/eip] [get_bd_pins cva5_top_0/external]

# ---- SPI --------------------------------------------------------------------
# pulp-platform's axi_spi_master, in place of axi_quad_spi. Four chip selects
# out to the Arduino shield header; see the XDC for the pins and for the
# loopback jumper the software test uses.
#
# Its irq -- end of transfer, or a FIFO watermark, ORed into one line -- goes
# to the PLIC as source 2; see the interrupt-sources section below.
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_spi_axi:1.0 cva5_spi_0
connect_bd_net $sys_clk  [get_bd_pins cva5_spi_0/clk]
connect_bd_net $sys_rstn [get_bd_pins cva5_spi_0/rstn]

make_bd_pins_external -name spi_sck  [get_bd_pins cva5_spi_0/spi_sck]
make_bd_pins_external -name spi_mosi [get_bd_pins cva5_spi_0/spi_mosi]
make_bd_pins_external -name spi_miso [get_bd_pins cva5_spi_0/spi_miso]
make_bd_pins_external -name spi_csn  [get_bd_pins cva5_spi_0/spi_csn]

# ---- I2C --------------------------------------------------------------------
# Alex Forencich's i2c_master_axil, in place of Xilinx's axi_iic. The only
# peripheral here whose slave port is already AXI4-Lite, so cva5_i2c_axi is a
# reset inversion, the open-drain triplets and a wider address port and nothing
# else.
#
# The IP carries no inout and resolves no tri-state. An inferred high-Z inside
# an IP does not survive that IP's own out-of-context synthesis run -- Vivado
# converts the tricell to logic (Synth 8-5799), the line is driven high rather
# than released, and every slave ACK becomes invisible. cva5_i2c_axi.sv has the
# full account and the three other arrangements that were built.
#
# So the pad is Vivado's. package_openhw_ips.tcl declares the triplets as an
# IIC bus interface, and exporting that whole interface -- rather than making
# six scalar pins external -- is what makes the wrapper generator instantiate
# the buffers. It only does that for an interface port that declares the
# _I/_O/_T group; three loose scalars get three ports and no buffer.
#
# Open drain, so the bus needs external pull-ups, which the PYNQ-Z2 has on the
# Arduino header (R49/R50, 2.2k to 3V3 on AR_SCL/AR_SDA).
#
# No interrupt: this master has no irq output at all, so unlike the SPI there
# is nothing to add to cva5_irq_concat. It is polled through STATUS.
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_i2c_axi:1.0 cva5_i2c_0
connect_bd_net $sys_clk  [get_bd_pins cva5_i2c_0/clk]
connect_bd_net $sys_rstn [get_bd_pins cva5_i2c_0/rstn]

# One interface port, not six pins. Fail loudly if the IP has no IIC interface,
# because make_bd_intf_pins_external on an empty list is silent and the design
# would come out with no I2C pins at all.
set i2c_intf [get_bd_intf_pins -quiet cva5_i2c_0/IIC]
if {[llength $i2c_intf] == 0} {
    error "cva5_i2c_0 has no IIC interface pin. The packager did not create\
it -- re-run package_openhw_ips.tcl and check for the \"declared IIC\
interface\" line, and see the note in cva5_i2c_axi.sv."
}
make_bd_intf_pins_external -name i2c $i2c_intf

# ---- Interrupt sources ------------------------------------------------------
# cva5_plic_axi takes its sources as one vector, and a block design connects a
# net to a whole pin, so two devices cannot be attached to two bits of it
# directly. Vivado's answer is xlconcat; cva5_irq_concat is ours, and it is one
# assignment.
#
# The source numbers are the ones examples/sw/soc.h declares, and the two must
# agree -- a swap here is invisible in synthesis and shows up on hardware as
# one device's interrupt attributed to the other:
#
#   src1 -> PLIC source 1   the UART's receive interrupt, !rx_fifo_empty:
#                           level sensitive, and up until software reads the
#                           byte, so it re-raises after a complete if the FIFO
#                           still has one.
#   src2 -> PLIC source 2   the SPI's end of transfer: a pulse, not a level.
#
# Both are left level sensitive, the pulse included, because the PLIC's gateway
# latches: `ip <= (ip | raise) & ~in_progress & ~claim`, so one cycle high is
# enough and the pending bit stays up until it is claimed. Edge mode would be
# worse here, not better -- cva5_plic_gateway's edge path is `irq ^ irq_r`,
# both edges, so a pulse would raise a second time as it fell.
create_bd_cell -type ip -vlnv xilinx.com:user:cva5_irq_concat:1.0 irq_concat_0
connect_bd_net [get_bd_pins cva5_uart_0/irq] [get_bd_pins irq_concat_0/src1]
connect_bd_net [get_bd_pins cva5_spi_0/irq]  [get_bd_pins irq_concat_0/src2]
connect_bd_net [get_bd_pins irq_concat_0/irq_srcs] \
               [get_bd_pins cva5_plic_0/irq_srcs]

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
connect_bd_intf_net [get_bd_intf_pins axi_xbar_0/m_axi_plic]  [get_bd_intf_pins cva5_plic_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_xbar_0/m_axi_spi]   [get_bd_intf_pins cva5_spi_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_xbar_0/m_axi_i2c]   [get_bd_intf_pins cva5_i2c_0/s_axi]

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

# 64M, matching cva5_plic_axi's 26-bit slave address port and the window
# examples/sw/soc.h reserves. The standard PLIC map needs up to 0x200004, so
# anything from 4M up would do; 64M is what the device decodes and what CVA6
# reserves, and a segment cannot exceed the slave's block anyway.
set plic_seg [cva5_seg {axi_xbar_0/m_axi_plic/SEG_cva5_plic_0_reg0} \
                       {axi_xbar_0/m_axi_plic/SEG_cva5_plic_0_Reg} \
                       {axi_xbar_0/m_axi_plic/SEG_cva5_plic_0_s_axi}]
if {$plic_seg eq ""} { error "the crossbar's PLIC port has no address segment" }
set_property offset 0x0C000000 $plic_seg
set_property range  64M        $plic_seg

# 4K, the floor a Vivado address segment can be given and what cva5_spi_axi's
# 12-bit slave port offers. The device itself decodes 128 bytes and aliases
# within the window; the crossbar decodes the full 8 MB CVA6 reserves to this
# port.
set spi_seg [cva5_seg {axi_xbar_0/m_axi_spi/SEG_cva5_spi_0_reg0} \
                      {axi_xbar_0/m_axi_spi/SEG_cva5_spi_0_Reg} \
                      {axi_xbar_0/m_axi_spi/SEG_cva5_spi_0_s_axi}]
if {$spi_seg eq ""} { error "the crossbar's SPI port has no address segment" }
set_property offset 0x20000000 $spi_seg
set_property range  4K         $spi_seg

# 4K, which is both what cva5_i2c_axi's 12-bit slave port offers and the whole
# window the crossbar decodes to this port -- the I2C is the one peripheral
# here with no CVA6 window to inherit, so examples/sw/soc.h gives it the
# minimum rather than reserving megabytes it will never use. The device decodes
# sixteen bytes and aliases through the rest.
set i2c_seg [cva5_seg {axi_xbar_0/m_axi_i2c/SEG_cva5_i2c_0_reg0} \
                      {axi_xbar_0/m_axi_i2c/SEG_cva5_i2c_0_Reg} \
                      {axi_xbar_0/m_axi_i2c/SEG_cva5_i2c_0_s_axi}]
if {$i2c_seg eq ""} { error "the crossbar's I2C port has no address segment" }
set_property offset 0x28000000 $i2c_seg
set_property range  4K         $i2c_seg

# ---- Where the PS sees CVA5's main memory ---------------------------------
# The same 0x8000_0000 the core sees it at. There is no reason for the PS's
# view to differ, and an identical map means a loader on the PS uses the
# addresses in examples/sw/soc.h unchanged, and that tools/check-soc-map.py
# keeps covering the whole thing.
#
# 128 KB, which is what the slave port offers: cva5_top's s_axi_ext address
# bus is $clog2(WORDS)+2 bits wide for exactly this reason, so Vivado infers
# an address block of the right size instead of a 4 GB aperture it would then
# refuse to place anywhere but zero.
set ps_ram_seg [cva5_seg {ps7_0/Data/SEG_cva5_top_0_reg0} \
                         {ps7_0/Data/SEG_cva5_top_0_Reg} \
                         {ps7_0/Data/SEG_cva5_top_0_s_axi_ext}]
if {$ps_ram_seg eq ""} {
    error "the PS has no address segment for cva5_top's external port. List\
 what it does have with: get_bd_addr_segs -of \[get_bd_addr_spaces\
 ps7_0/Data\]"
}
set_property offset 0x80000000 $ps_ram_seg
set_property range  128K       $ps_ram_seg

# ---- Finalise -------------------------------------------------------------
regenerate_bd_layout
validate_bd_design

make_wrapper -files [get_files ./vivado/CVA5BD/CVA5BD.srcs/sources_1/bd/soc/soc.bd] -top
set soc_wrapper ./vivado/CVA5BD/CVA5BD.gen/sources_1/bd/soc/hdl/soc_wrapper.v
add_files $soc_wrapper
update_compile_order -fileset sources_1

# ---- The I2C pad, checked ---------------------------------------------------
#
# Nothing in this repository holds the I2C tri-state; the IIC interface is
# exported above and the wrapper generator is what instantiates the buffers.
# This is the one place that can be confirmed, and unlike an inferred
# tri-state -- which only becomes a buffer during synthesis and never appears
# in this file -- a declared interface puts the IOBUFs here textually. So
# counting them is meaningful, and an empty count means the pad is missing
# rather than merely invisible.
#
# Worth having because the failure is silent downstream: no buffers means the
# lines are driven instead of released, and the first symptom is an I2C scan
# that finds nothing, which is also what an empty bus looks like.
set fh [open $soc_wrapper r]
set wrapper_rtl [read $fh]
close $fh

set n_iobuf [regexp -all {\mIOBUF\M} $wrapper_rtl]
if {$n_iobuf < 2} {
    error "soc_wrapper.v has $n_iobuf IOBUF instances, expected at least 2\
(scl and sda). The IIC interface did not produce a pad. Check the packaging\
log for the \"declared IIC interface\" line, and see the note in\
cva5_i2c_axi.sv."
}

# And report the inout names the wrapper actually created, because the XDC has
# to constrain those exact names and Vivado derives them from the interface
# port rather than from anything written here. A mismatch is an XDC error on a
# missing port, which is a fine way to fail -- but knowing the real names
# beforehand is cheaper than reading that error.
set wrapper_inouts {}
foreach line [split $wrapper_rtl "\n"] {
    if {[regexp {^\s*inout\s+(?:wire\s+)?(\w+)} $line -> nm]} {
        lappend wrapper_inouts $nm
    }
}
puts "I2C: $n_iobuf IOBUF instances in soc_wrapper.v"
puts "I2C: wrapper inout ports: $wrapper_inouts"

foreach want {i2c_scl_io i2c_sda_io} {
    if {[lsearch -exact $wrapper_inouts $want] < 0} {
        error "pynq_z2_cva5.xdc constrains $want, which the wrapper does not\
have. Its inouts are: $wrapper_inouts. Rename the two I2C constraints to\
match, or rename the interface port above."
    }
}

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