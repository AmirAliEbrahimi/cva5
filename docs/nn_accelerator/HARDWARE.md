# Hardware

The block design, the wire format, and what `examples/xilinx/pynq_z2_nn_sys.tcl`
builds for you.

The script does all of this automatically:

```bash
vivado -mode batch -source examples/xilinx/package_as_ip_pynq_z2.tcl
vivado -mode batch -source examples/xilinx/pynq_z2_nn_sys.tcl -tclargs build
```

The rest of this document is what it builds, and how to do it by hand if the
script trips.

## Script status

The design described here was built in the GUI and runs on hardware: WNS
+0.139 ns, 50.2x measured speedup. The Tcl is a faithful transcription of that
design but **has not been executed end to end**.

The AXI connections use `apply_bd_automation`, the same mechanism as
`pynq_z2_sys.tcl`, so those are low risk. The IP configuration property names
(`CONFIG.C_USE_TX_CTRL`, `CONFIG.C_HAS_AXIS_TKEEP`, `CONFIG.M_TDATA_NUM_BYTES`)
were written from the GUI settings rather than read back from a saved design,
so one may be wrong for your IP version. If a `set_property` fails, add the IP
in the GUI, configure it, then read the real names:

```tcl
report_property [get_bd_cells axi_fifo_mm_s_0]
get_bd_addr_segs -of [get_bd_addr_spaces cva5_top_0/m_axi]
```

`validate_bd_design` runs before the wrapper is generated and catches any
unconnected interface or clock.

## Datapath

```
CVA5 m_axi (32b memory-mapped)
  └─ AXI Interconnect
       ├─ M00 → AXI Uartlite        0x6000_0000
       ├─ M01 → AXI GPIO            0x6001_0000
       └─ M02 → AXI4-Stream FIFO    0x6002_0000
                  ├ AXI_STR_TXD (32b) → DWC 32→48 → cnn_0.x
                  └ AXI_STR_RXD (32b) ←──────────── cnn_0.layer9_out
       AXI GPIO ch1 → ap_start
       AXI GPIO ch2 ← {ap_ready, ap_idle, ap_done} via Concat
```

CVA5 has a single 32-bit AXI master and no slave port, so it cannot be a DMA
target. The AXI4-Stream FIFO is the bridge: a memory-mapped slave with stream
ports, no descriptors, no shared DDR.

## IP to add

**Accelerator** — add `sw_14_5_rf4/cnn_prj/solution1/impl/ip/` to the IP repo
(Settings → IP → Repository), `update_ip_catalog`, then add `cnn_0`. Its input
should read `x_TDATA[47:0]`. If it reads `[511:0]`, the IP was generated
without `ChannelsLastConversion='internal'`.

**AXI4-Stream FIFO** — catalog name is "AXI4-Stream FIFO", VLNV
`xilinx.com:ip:axi_fifo_mm_s`. Do not confuse it with "AXI4-Stream **Data**
FIFO" (`axis_data_fifo`), which is stream-to-stream and cannot talk to CVA5.

Configure: AXI4 Lite data interface, Transmit Data enabled, Receive Data
enabled, depth 512 both ways, TKEEP off. **Uncheck Enable Transmit Control** —
that adds an `AXI_STR_TXC` port for AXI Ethernet control frames that you do
not need.

**AXI4-Stream Data Width Converter** — 32 in, 48 out.

**AXI GPIO** — dual channel. Ch1: All Outputs, width 1. Ch2: All Inputs,
width 3.

**Concat** — three 1-bit inputs to one 3-bit vector for the GPIO status
channel.

**Constant** — width 1, value 1, for `axi_str_rxd_tlast`.

Interconnect: raise master ports from 2 to 4.

## Wiring

Connect at the **interface** level, not pin by pin. Drag from the `+` bundle
marker to the other `+` bundle marker. If Vivado shows an interface broken out
into individual pins (`x_TDATA`, `x_TREADY`, `x_TVALID` listed separately),
the bundled connection was never made and some signals — usually TREADY — are
floating.

| From | To |
|---|---|
| Interconnect `M01_AXI` | `axi_gpio_0/S_AXI` |
| Interconnect `M02_AXI` | `axi_fifo_mm_s_0/S_AXI` |
| `axi_fifo_mm_s_0/AXI_STR_TXD` | `axis_dwidth_converter_0/S_AXIS` |
| `axis_dwidth_converter_0/M_AXIS` | `cnn_0/x` |
| `cnn_0/layer9_out` | `axi_fifo_mm_s_0/AXI_STR_RXD` |
| `xlconstant_0/dout` | `axi_fifo_mm_s_0/axi_str_rxd_tlast` |
| `axi_gpio_0/gpio_io_o[0]` | `cnn_0/ap_start` |
| `cnn_0/ap_done`,`ap_idle`,`ap_ready` | `xlconcat_0/In0..In2` |
| `xlconcat_0/dout[2:0]` | `axi_gpio_0/gpio2_io_i` |
| `clk_wiz_0/clk_out1` | `cnn_0/ap_clk`, DWC `aclk`, FIFO `s_axi_aclk` |
| `proc_sys_reset_0/peripheral_aresetn` | `cnn_0/ap_rst_n`, DWC `aresetn`, FIFO `s_axi_aresetn` |

`m_axis_tkeep[5:0]` and `m_axis_tlast` from the DWC have no counterpart on
`cnn_0` and stay unconnected. That warning is expected.

`cnn_0` does not generate TLAST, which is why `axi_str_rxd_tlast` is tied
high: each result word becomes a single-word packet, which is correct here
since one inference produces exactly one 32-bit result.

Validate before building — it lists unconnected interface pins explicitly,
which is faster than reading the diagram:

```tcl
validate_bd_design
```

## Addresses

Auto-assign puts the GPIO at `0x0`. Move it. `0x0` is the null-pointer
address: a stray write through an uninitialized pointer would toggle
`ap_start` instead of trapping.

| IP | Base | Range |
|---|---|---|
| `axi_uartlite_0` | `0x6000_0000` | 64K |
| `axi_gpio_0` | `0x6001_0000` | 64K |
| `axi_fifo_mm_s_0` | `0x6002_0000` | 4K |

These match the constants in `examples/sw/bench.c`.

## Implementation

The default strategy misses timing by about 70 ps on the conv2 multiplier
path — a combinational DSP48E1 followed by a carry chain, 9.84 ns of a 10 ns
budget.

Use **Performance_ExplorePostRoutePhysOpt**. That closes at roughly
WNS +0.139 ns.

If you want margin rather than a strategy fix, set
`config_schedule -enable_dsp_full_reg=true` in the generated `build_prj.tcl`
and re-synthesize. hls4ml writes `false`, which leaves the DSP output
unregistered. Costs a cycle or two of latency and some FFs; you have 83% of
FFs free.

## Register map used by the software

AXI GPIO:

| Offset | Register |
|---|---|
| `0x00` | ch1 data — bit 0 = `ap_start` |
| `0x04` | ch1 direction — write 0 for output |
| `0x08` | ch2 data — {ready, idle, done} |
| `0x0C` | ch2 direction — write 1 for input |

AXI4-Stream FIFO (AXI4-Lite mode, PG080):

| Offset | Register |
|---|---|
| `0x08` | TDFR — write `0xA5` to reset TX |
| `0x0C` | TDFV — TX vacancy, words |
| `0x10` | TDFD — TX data |
| `0x14` | TLR — TX length in bytes, triggers send |
| `0x18` | RDFR — write `0xA5` to reset RX |
| `0x1C` | RDFO — RX occupancy, words |
| `0x20` | RDFD — RX data |
| `0x24` | RLR — RX length |

## Wire format

The accelerator expects one RGB pixel per 48-bit beat, raster order,
channels-last:

```
beat 0:    [R(0,0), G(0,0), B(0,0)]
beat 1:    [R(0,1), G(0,1), B(0,1)]
...
beat 1023: [R(31,31), G(31,31), B(31,31)]
```

Each `ap_fixed<14,5>` value occupies its own 16-bit lane — byte-aligned, not
bit-packed. Verified by building the same model at `ap_fixed<12,5>` and
observing `x_TDATA` stayed `[47:0]` rather than shrinking to `[39:0]`.

48 bits does not divide into 32, so **two pixels span exactly three words**:

```
word0 = R0 | (G0 << 16)
word1 = B0 | (R1 << 16)
word2 = G1 | (B1 << 16)
```

Any transfer chunk must therefore be a multiple of 3 words. The FIFO depth
(512) is not, which is why `examples/sw/bench.c` uses 384-word chunks — 128 pixel pairs,
four chunks per image.
