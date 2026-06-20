#==============================================================================
# Constraints for the CVA5 SoC on the PYNQ-Z2
#==============================================================================

# The 125 MHz system clock (clk_in1) and its create_clock are applied
# automatically by the board automation / PYNQ-Z2 board file, so the clock
# pin is intentionally NOT constrained here. Don't add it, or you'll
# double-constrain it.

# ---- Reset: slide switch SW0 (active-low) --------------------------------
# Switch HIGH (up) = run, switch LOW (down) = reset asserted.
set_property -dict { PACKAGE_PIN M20 IOSTANDARD LVCMOS33 } [get_ports reset_sw] ;# SW0

# ---- UART on PMOD JA ------------------------------------------------------
# Connect an external 3.3 V USB-UART / FTDI adapter to PMOD JA and CROSS the
# lines:  FPGA uart_tx -> adapter RX,  FPGA uart_rx <- adapter TX.  Also tie
# the adapter ground to a PMOD GND pin.
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports uart_tx] ;# JA1
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports uart_rx] ;# JA2
