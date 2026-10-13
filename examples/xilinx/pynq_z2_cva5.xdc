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
# Two constraints, because neither alone is right and they are not
# interchangeable:
#
#   set_clock_groups -asynchronous     stops the timer computing setup and hold
#                                      between two clocks whose phase relation
#                                      is unknowable. Without it the clocks are
#                                      "related with no common node", which
#                                      Vivado reports as a critical warning
#                                      saying the design could fail -- and it is
#                                      right, because those numbers are fiction.
#
#   set_bus_skew                       bounds the spread between the payload's
#                                      own bits, which is the requirement the
#                                      handshake actually has. It is NOT a
#                                      timing exception, so the clock group does
#                                      not override it; report_bus_skew checks it
#                                      independently and reports a slack.
#
# What does not work is set_max_delay -datapath_only, which was the previous
# attempt: a clock group outranks it in Vivado's exception precedence, so the two
# cannot be combined -- the group wins and the bound is silently discarded -- and
# used alone instead of the group it leaves the clocks related, which is the
# critical warning above.
#
# The value is the number of destination cycles the payload is held for. The
# destination sees the request only after a two-stage synchroniser, so the data
# has at least two destination clocks to settle, and the handshake holds it until
# the acknowledge returns. Two destination periods is therefore conservative in
# the safe direction: 2 x 10 ns for the request (TCK into the core's clock) and
# 2 x 100 ns for the response (the core's clock into TCK). Measured skew is
# 1.857 ns against the 20 ns requirement, so neither bound puts the router under
# any pressure -- they exist to keep it that way.
#
# Found via the one i_dmi_cdc instance rather than by filtering every cell in
# the design on its hierarchical name, for the reason XDCB #1 gives above.
set dmi_cdc [get_cells -quiet -hierarchical i_dmi_cdc]
if {[llength $dmi_cdc] != 1} {
    puts "ERROR: pynq_z2_cva5.xdc: expected 1 i_dmi_cdc, found [llength $dmi_cdc]"
}
set_clock_groups -asynchronous -name jtag_tck_async -group [get_clocks jtag_tck]
set_bus_skew 20.000 \
    -from [get_cells $dmi_cdc/i_cdc_req/i_src/data_src_q_reg*] \
    -to   [get_cells $dmi_cdc/i_cdc_req/i_dst/data_dst_q_reg*]
set_bus_skew 200.000 \
    -from [get_cells $dmi_cdc/i_cdc_resp/i_src/data_src_q_reg*] \
    -to   [get_cells $dmi_cdc/i_cdc_resp/i_dst/data_dst_q_reg*]

# ---- Reset: slide switch SW0 (active-low) --------------------------------
# Switch HIGH (up) = run, switch LOW (down) = reset asserted.
set_property -dict { PACKAGE_PIN M20 IOSTANDARD LVCMOS33 } [get_ports reset_sw] ;# SW0

# ---- UART on PMOD JA ------------------------------------------------------
# Connect an external 3.3 V USB-UART / FTDI adapter to PMOD JA and CROSS the
# lines:  FPGA uart_tx -> adapter RX,  FPGA uart_rx <- adapter TX.  Also tie
# the adapter ground to a PMOD GND pin.
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports uart_tx] ;# JA1
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports uart_rx] ;# JA2
