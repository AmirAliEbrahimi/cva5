#==============================================================================
# Constraints for the CVA5 SoC on the PYNQ-Z2
#==============================================================================

# The 125 MHz system clock (clk_in1) and its create_clock are applied
# automatically by the board automation / PYNQ-Z2 board file, so the clock
# pin is intentionally NOT constrained here. Don't add it, or you'll
# double-constrain it.

# ---- JTAG: the FPGA's own TAP (BSCANE2) ----------------------------------
# The debug module's DTM hangs off the FPGA's JTAG chain through two BSCANE2
# primitives inside riscv-dbg's dmi_jtag_tap. TCK comes out of the USER3
# instance and clocks the whole DTM: the TAP shift registers, the DMI FSM, and
# the TCK half of the clock-domain crossing into the core's clock. Nothing
# creates a clock for it, so 243 register pins are reached by no timing clock
# at all and report_methodology says so 243 times (TIMING-17). Those are not
# cosmetic: a register with no clock has no requirement, so nothing stops the
# placer putting the two halves of the TAP's shift chain at opposite corners
# of the die.
#
# 100 ns is the 10 MHz that examples/xilinx/openocd/pynq-z2-jtag.cfg asks the
# adapter for. The DTM is a shift register and a small FSM, so the number only
# has to be honest about the cable, not tight.
#
# Found through the cell rather than by filtering every pin in the design on
# its hierarchical name, which is what XDCB #1 asks for: `get_pins -hierarchical
# -filter {NAME =~ ...}` walks the whole pin list, while -of_objects starts from
# the one cell. The instance is named rather than selected by REF_NAME ==
# BSCANE2 because there are two of them and only this one has TCK connected.
#
# If riscv-dbg ever renames it, create_clock gets an empty object list and stops
# the run, which is the right way to find out.
set tck_pin [get_pins -quiet -filter {REF_PIN_NAME == TCK} \
                 -of_objects [get_cells -quiet -hierarchical i_tap_dtmcs]]
if {[llength $tck_pin] != 1} {
    puts "ERROR: pynq_z2_cva5.xdc: expected 1 BSCANE2 TCK pin, found [llength $tck_pin]"
}
create_clock -period 100.000 -name jtag_tck -waveform {0.000 50.000} $tck_pin

# TCK is driven by whatever the cable is doing and has no relationship to the
# system clock, so the paths between the two domains must not be analysed as if
# they were synchronous. What they must not be is unanalysed either, and that is
# the difference between the two ways of saying it.
#
# riscv-dbg crosses between the domains with two cdc_2phase_clearable instances
# inside dmi_cdc, and that module states what it needs in its own header:
#
#   CONSTRAINT: Requires max_delay of min_period(src_clk_i, dst_clk_i) through
#   the paths async_req, async_ack, async_data.
#
# The handshake is what makes the crossing safe, but only on one condition: the
# payload (async_data) is deliberately not synchronised, so correctness depends
# on it having settled by the time the destination domain sees the synchronised
# request. A two-stage sync on async_req gives it two destination cycles to do
# that -- and only a bound on the data path turns "two cycles" into a guarantee
# rather than an expectation. The module marks async_req, async_ack and
# async_data `dont_touch` precisely so they survive synthesis and can be
# constrained; the same applies to the cdc_4phase crossings inside
# cdc_reset_ctrlr, which carry the identical note.
#
# min_period(TCK, system clock) = min(100, 10) = 10 ns. Constraining clock to
# clock covers every crossing in both directions, including the reset
# controller's, without naming a single net -- and keeps covering them when the
# CLINT or a second clock arrives.
#
# This REPLACES a set_clock_groups -asynchronous, which was wrong in a way that
# is quiet: a clock group outranks set_max_delay in Vivado's exception
# precedence, so the two cannot be combined -- the group would win and the bound
# would be silently ignored. It also outranked reality, which is how 849
# endpoint pairs came back from report_cdc as Critical with the payload
# unclassified: paths the timer had been told to stop looking at.
set other_clks [remove_from_collection [get_clocks] [get_clocks jtag_tck]]
if {[llength $other_clks] == 0} {
    puts "ERROR: pynq_z2_cva5.xdc: no system clock found to bound the JTAG CDC against"
}
set_max_delay -datapath_only 10.000 -from [get_clocks jtag_tck] -to $other_clks
set_max_delay -datapath_only 10.000 -from $other_clks -to [get_clocks jtag_tck]

# ---- Reset: slide switch SW0 (active-low) --------------------------------
# Switch HIGH (up) = run, switch LOW (down) = reset asserted.
set_property -dict { PACKAGE_PIN M20 IOSTANDARD LVCMOS33 } [get_ports reset_sw] ;# SW0

# ---- UART on PMOD JA ------------------------------------------------------
# Connect an external 3.3 V USB-UART / FTDI adapter to PMOD JA and CROSS the
# lines:  FPGA uart_tx -> adapter RX,  FPGA uart_rx <- adapter TX.  Also tie
# the adapter ground to a PMOD GND pin.
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports uart_tx] ;# JA1
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports uart_rx] ;# JA2
