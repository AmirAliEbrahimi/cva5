# CVA5 on the PYNQ-Z2

Builds a CVA5 (RV32IM) soft SoC that runs the `examples/sw` demo program from
block RAM, with an AXI UART Lite for console output. A single slide switch
(SW0) drives the system reset. This mirrors the existing Nexys A7 example.

## Files (in `examples/fpga/`)

| file                          | purpose                                                                 |
|-------------------------------|-------------------------------------------------------------------------|
| `package_as_ip_pynq_z2.tcl`   | packages the CVA5 core as a Vivado IP into `./vivado/ip_repo`            |
| `package_openhw_ips.tcl`      | packages the open-hardware AXI blocks into `./vivado/ip_repo_openhw`     |
| `pynq_z2_sys.tcl`             | builds the SoC block design (clock, reset, CVA5, AXI UART Lite) + XDC    |
| `pynq_z2_cva5.xdc`            | pin constraints — reset switch and PMOD UART                            |
| `axi/`                        | flat-port wrappers round the pulp-platform AXI blocks                   |
| `vendor/`                     | generated include-free copies of pulp sources (`tools/vendor-pulp-sv.py`)|

## Prerequisites

- Vivado (part `xc7z020clg400-1`).
- PYNQ-Z2 board files installed (Digilent `vivado-boards`):
  https://github.com/Digilent/vivado-boards
- The submodules: `git submodule update --init --recursive`
- Run from the **repo root** so the relative paths in the scripts resolve.

## Build (Vivado Tcl console, from the repo root)

```tcl
source ./examples/fpga/package_as_ip_pynq_z2.tcl   ;# package CVA5 as IP
source ./examples/fpga/package_openhw_ips.tcl      ;# package the AXI blocks
source ./examples/fpga/pynq_z2_sys.tcl             ;# build the SoC + add the XDC
```

Then in the GUI: **Generate Bitstream**, open the **Hardware Manager**, and
program the device.

The demo program is `examples/sw/mem.mif` (the `cva5_top` `LOCAL_MEM`
parameter). To change it, rebuild the software under `examples/sw` and copy the
generated `program.hex` over `examples/sw/mem.mif` as they share the same
one-word-per-line hex format that `$readmemh` expects, then re-run the build.

## Replacing the Xilinx IPs

The block design is moving to open-hardware (pulp-platform) AXI blocks, one IP
at a time, each step gated on the board still running Hello World, `make load`
and a GDB session. Only the MMCM (`clk_wiz`) is meant to stay Xilinx.

| Xilinx IP              | replacement                        | state |
|------------------------|------------------------------------|-------|
| `axi_register_slice`   | `cva5_axi_cut` (pulp `axi_cut`)    | done  |
| `axi_interconnect`     | `axi_xbar`                         | next  |
| `axi_bram_ctrl`+`blk_mem_gen` | `axi_to_mem` + inferred BRAM | todo  |
| `axi_uartlite`         | `axi_lite_to_apb` + `apb_uart`     | todo  |
| —                      | `clint`, simple interrupt controller | todo |
| —                      | `apb_spi_master` (4 chip selects)  | todo  |
| `proc_sys_reset`       | reset synchroniser                 | todo  |
| `clk_wiz`              | *stays* — the MMCM is a hard block | —     |

Each wrapper under `axi/` presents flat AXI ports so Vivado's IP packager
infers the bus interfaces; the pulp modules underneath take SystemVerilog
structs, which a block design cannot carry. `tools/vendor-pulp-sv.py`
generates the include-free copies in `vendor/`, because the IP packager
flattens sources and the pulp `` `include `` paths then cannot resolve.

Each block has a Verilator testbench under `test_benches/axi/`; run
`test_benches/axi/run_cut.sh` before spending a synthesis run.

## Pin map (`xc7z020clg400-1`)

| Signal     | FPGA pin | Board location      | Notes                                  |
|------------|----------|---------------------|----------------------------------------|
| `reset_sw` | `M20`    | Slide switch **SW0**| Active-low: switch **down = reset**, **up = run** |
| `uart_tx`  | `Y18`    | PMOD **JA pin 1**   | FPGA → bridge                          |
| `uart_rx`  | `Y19`    | PMOD **JA pin 2**   | bridge → FPGA                          |

The 125 MHz board clock is applied automatically by board automation, and the
`clk_wiz` produces the ~100 MHz core clock which matches `#define MHZ 100` in
the demo, so its `usleep` timing is correct.

## Reset on SW0 — needs debouncing

SW0 feeds the reset chain (`proc_sys_reset` + `clk_wiz`, both active-low)
directly. A slide switch is mechanical and bounces, so a single toggle can
produce several reset edges. That is usually harmless on a reset line but can
cause a glitchy or partial reset. For a clean reset, add a debouncer or drive the reset from an already-debounced source. *(Known limitation / TODO.)*

## UART over the onboard USB-UART (no external adapter)

The PYNQ-Z2's USB-UART bridge is wired to the PS (MIO14/15), not the PL, so this
design brings the PL UART out to **PMOD JA**. To reach the onboard bridge from
the PL, jumper PMOD JA to the board's **J13** header. **two wires, straight
across**:

- **JA pin 1** (`uart_tx`) → **J13 pin 1**
- **JA pin 2** (`uart_rx`) → **J13 pin 2**

No crossover is needed; the straight mapping already lands the FPGA's TX on the
bridge's RX and the FPGA's RX on the bridge's TX. No ground jumper is needed
either. PMOD JA and J13 share the board's common ground. The same micro-USB
that programs the board then also carries the serial console.

**Terminal settings:** 9600 baud, 8N1, no flow control (the AXI UART Lite
default. Raise `C_BAUDRATE` on the IP if you want faster). Open it on the COM
port the board enumerates as.

**Make sure nothing else is driving the bridge** at the same time: no PS UART
console on those lines, and **close Vivado's Hardware Manager / programmer**
connection before opening the serial terminal as JTAG and UART share the one
FT2232 over the same micro-USB.
