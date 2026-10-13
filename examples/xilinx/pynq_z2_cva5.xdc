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
# system clock. riscv-dbg crosses between the two domains with a two-phase
# handshake (dmi_cdc), which is what makes the crossing safe; this line is what
# stops the timer trying to prove it with setup checks that cannot be met and
# do not mean anything. It has to come with the create_clock above, not after
# it: on its own, the create_clock would replace 243 critical warnings with a
# heap of impossible paths between the two domains.
#
# One group means "asynchronous to every other clock in the design", so the
# CLINT's or a second clock's arrival needs no edit here.
set_clock_groups -asynchronous -name jtag_tck_async -group [get_clocks jtag_tck]

# ---- Reset: slide switch SW0 (active-low) --------------------------------
# Switch HIGH (up) = run, switch LOW (down) = reset asserted.
set_property -dict { PACKAGE_PIN M20 IOSTANDARD LVCMOS33 } [get_ports reset_sw] ;# SW0

# ---- UART on PMOD JA ------------------------------------------------------
# Connect an external 3.3 V USB-UART / FTDI adapter to PMOD JA and CROSS the
# lines:  FPGA uart_tx -> adapter RX,  FPGA uart_rx <- adapter TX.  Also tie
# the adapter ground to a PMOD GND pin.
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports uart_tx] ;# JA1
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports uart_rx] ;# JA2
