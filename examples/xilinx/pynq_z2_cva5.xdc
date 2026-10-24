#==============================================================================
# Constraints for the CVA5 SoC on the PYNQ-Z2
#==============================================================================

# Pins only. The 125 MHz system clock (clk_in1) and its create_clock are
# applied automatically by the board automation / PYNQ-Z2 board file, so the
# clock pin is intentionally NOT constrained here. Don't add it, or you'll
# double-constrain it.
#
# The debug module's JTAG clock and its clock-domain crossing live in
# pynq_z2_jtag.xdc, which is implementation only because everything in it names
# a cell inside cva5_top -- a black box during top-level synthesis.

# ---- Reset: slide switch SW0 (active-low) --------------------------------
# Switch HIGH (up) = run, switch LOW (down) = reset asserted.
set_property -dict { PACKAGE_PIN M20 IOSTANDARD LVCMOS33 } [get_ports reset_sw] ;# SW0

# ---- UART on PMOD JA ------------------------------------------------------
# Connect an external 3.3 V USB-UART / FTDI adapter to PMOD JA and CROSS the
# lines:  FPGA uart_tx -> adapter RX,  FPGA uart_rx <- adapter TX.  Also tie
# the adapter ground to a PMOD GND pin.
set_property -dict { PACKAGE_PIN Y18 IOSTANDARD LVCMOS33 } [get_ports uart_tx] ;# JA1
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports uart_rx] ;# JA2

# ---- SPI on the Arduino shield header --------------------------------------
# Clock, MOSI and MISO take the board's dedicated SPI nets (the shield's ICSP
# header); the four chip selects take the Arduino slave-select net and three
# digital pins, which is how a multi-device shield is normally wired.
#
#   spi_clk     ck_sck   H15   Sch=sck
#   spi_mosi    ck_mosi  T12   Sch=ar_mosi_r
#   spi_miso    ck_miso  W15   Sch=miso
#   spi_csn[0]  ck_ss    F16   Sch=ss          (Arduino D10 / SS)
#   spi_csn[1]  ar[9]    V18                   D9
#   spi_csn[2]  ar[8]    V17                   D8
#   spi_csn[3]  ar[7]    U17                   D7
#
# For the loopback test in examples/sw/spi.c, jumper MOSI to MISO on the ICSP
# header -- no device needed, and it proves the receive path as well as the
# transmit one.
set_property -dict { PACKAGE_PIN H15 IOSTANDARD LVCMOS33 } [get_ports spi_clk]
set_property -dict { PACKAGE_PIN T12 IOSTANDARD LVCMOS33 } [get_ports spi_mosi]
set_property -dict { PACKAGE_PIN W15 IOSTANDARD LVCMOS33 } [get_ports spi_miso]
set_property -dict { PACKAGE_PIN F16 IOSTANDARD LVCMOS33 } [get_ports {spi_csn[0]}]
set_property -dict { PACKAGE_PIN V18 IOSTANDARD LVCMOS33 } [get_ports {spi_csn[1]}]
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {spi_csn[2]}]
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports {spi_csn[3]}]

# The SPI clock is generated inside the fabric by a divider off the 100 MHz
# system clock, so it is a data path as far as timing is concerned, not a
# clock. Nothing is clocked by it in this design -- the controller samples on
# its own clock -- so no create_generated_clock is wanted here.
