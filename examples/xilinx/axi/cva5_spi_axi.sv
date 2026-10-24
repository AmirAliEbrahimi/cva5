/*
 * cva5_spi_axi -- pulp-platform's axi_spi_master as a block-design peripheral.
 *
 * Replaces Xilinx's axi_quad_spi. Four chip selects, a programmable clock
 * divider, command/address/length registers and 32-bit TX and RX FIFOs, from
 * third_party/axi_spi_master (Solderpad 0.51).
 *
 * The sources are listed straight from the submodule rather than vendored: the
 * reason the CLINT and the PLIC needed renamed copies is that tools/compile_order
 * compiles the apu/ originals into the core simulation, and two different
 * modules sharing a name in one compilation is a trap. Nothing else in this
 * tree is called axi_spi_master or spi_master_*, and these files carry no
 * `include directives, so there is nothing to flatten either.
 *
 * Two things this wrapper exists to do.
 *
 * First, the protocol. axi_spi_master's slave port is full AXI4 -- awid[15:0],
 * awlen[7:0], wlast, and *user fields -- and this SoC's bus is AXI4-Lite from
 * end to end. A Lite transaction is a single-beat AXI4 one, so the burst
 * fields are tied off here rather than by restoring the AXI4-to-Lite converter
 * that came out with the caches: AWLEN 0, WLAST 1, IDs and USER zero, and the
 * echoed BID/RID/RLAST dropped. cva5_sba_split does exactly this to reach the
 * RAM port; it costs no logic beyond the constants.
 *
 * Of those, only AWLEN/ARLEN are load bearing -- the slave's write FSM counts
 * beats from AWLEN and never looks at WLAST, which a mutation confirmed: tying
 * WLAST low leaves every test passing. It stays 1 because that is what the
 * protocol says a single-beat write looks like, not because this slave checks.
 *
 * Second, the pins. The IP brings out four data lines in each direction for
 * quad mode. This exposes plain SPI -- one mosi, one miso -- because a block
 * design has nothing to tie three unused input lines to without a Xilinx
 * constant block, and because the PMOD header this lands on carries one of
 * each. Quad would be a parameter and three more pins.
 *
 * Which line is MISO is worth stating, because it is not the obvious one.
 * In single-bit mode the transmitter drives sdo0 (spi_master_tx.sv: `sdo0 =
 * data_int[31]`) but the receiver samples **sdi1**, not sdi0
 * (spi_master_rx.sv: `data_int_next = {data_int[30:0], sdi1}`). That is the
 * usual two-wire convention -- MOSI on line 0, MISO on line 1 -- expressed
 * through the quad pin names. So spi_miso lands on sdi1 here; sdi0, sdi2 and
 * sdi3 are tied low and sdo1..3 left dangling, which is harmless for outputs.
 * Connecting MISO to sdi0 instead gives a controller that transmits correctly
 * and reads back nothing but zeros.
 *
 * Register map, byte offsets into the window (word addressing, 5 bits of word
 * address, so the whole device decodes 128 bytes):
 *
 *   0x00  STATUS   transfer state, FIFO levels
 *   0x04  CLKDIV   SPI clock divider off this clock
 *   0x08  SPICMD   command bits, with their length in SPILEN
 *   0x0C  SPIADR   address bits
 *   0x10  SPILEN   command / address / data lengths
 *   0x14  SPIDUM   dummy cycles between phases
 *   0x20+ writes land in the TX FIFO   (word address bit 3)
 *   0x40+ reads come from the RX FIFO  (word address bit 4)
 *
 * events_o[1] is end-of-transfer and events_o[0] a FIFO watermark; both leave
 * as `irq` for a PLIC source, ORed, because the PLIC has one line per device
 * and software reads STATUS to find out which.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_spi_axi #(
    //Width of the slave's address bus, and so the size of the address block
    //this IP offers the block design. The device decodes 128 bytes; 12 bits is
    //the 4 KB floor a Vivado address segment can be given, the same floor
    //cva5_uart sits at. A 32-bit port would offer 4 GB and could only be
    //placed at zero -- see CLAUDE.md.
    parameter int unsigned ADDR_WIDTH = 12,

    //TX and RX FIFO depth, in 32-bit words.
    parameter int unsigned BUFFER_DEPTH = 8
) (
    input logic clk,
    input logic rstn,

    //AXI4-Lite slave. Vivado infers the interface from these names.
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [2:0]  s_axi_awprot,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,

    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,

    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,

    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [2:0]  s_axi_arprot,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,

    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    //SPI, to the pins.
    //
    //sck, not spi_clk, because Vivado's packager infers bus interfaces from
    //port names and a name containing "clk" on an output got this one read as a
    //clock interface:
    //
    //  INFO:    [IP_Flow 19-5107] Inferred bus interface 'spi_clk' of
    //           definition 'xilinx.com:signal:clock:1.0'
    //  WARNING: [IP_Flow 19-4751] Bus Interface 'spi_clk': FREQ_HZ bus
    //           parameter is missing for output clock interface
    //
    //It is not a clock in the block design's sense -- it is a divided serial
    //clock on its way to a pin, nothing in the design is clocked from it, and
    //there is no single frequency to declare since software sets the divider.
    //The conventional SPI name has no "clk" in it, so it stops the inference
    //and is the better name anyway.
    output logic        spi_sck,
    output logic [3:0]  spi_csn,
    output logic        spi_mosi,
    input  logic        spi_miso,

    //To the PLIC: end of transfer, or a FIFO watermark.
    output logic        irq
);

    //----------------------------------------------------------------
    // Lite to single-beat AXI4
    //----------------------------------------------------------------
    localparam int unsigned ID_WIDTH   = 16;  //axi_spi_master's defaults
    localparam int unsigned USER_WIDTH = 4;

    logic [ID_WIDTH-1:0]   bid, rid;
    logic                  rlast;
    logic [USER_WIDTH-1:0] buser, ruser;

    //----------------------------------------------------------------
    // The IP
    //----------------------------------------------------------------
    logic sdo0;
    logic [1:0] spi_mode;
    logic [1:0] events;

    assign spi_mosi = sdo0;
    assign irq = |events;

    axi_spi_master #(
        .AXI4_ADDRESS_WIDTH (32),
        .AXI4_RDATA_WIDTH (32),
        .AXI4_WDATA_WIDTH (32),
        .AXI4_USER_WIDTH (USER_WIDTH),
        .AXI4_ID_WIDTH (ID_WIDTH),
        .BUFFER_DEPTH (BUFFER_DEPTH)
    ) spi_inst (
        .s_axi_aclk (clk),
        .s_axi_aresetn (rstn),

        //AW: a Lite write is one beat
        .s_axi_awid ('0),
        .s_axi_awaddr (32'(s_axi_awaddr)),
        .s_axi_awlen (8'd0),
        .s_axi_awuser ('0),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),

        .s_axi_wdata (s_axi_wdata),
        .s_axi_wstrb (s_axi_wstrb),
        .s_axi_wlast (1'b1),
        .s_axi_wuser ('0),
        .s_axi_wvalid (s_axi_wvalid),
        .s_axi_wready (s_axi_wready),

        .s_axi_bid (bid),
        .s_axi_bresp (s_axi_bresp),
        .s_axi_buser (buser),
        .s_axi_bvalid (s_axi_bvalid),
        .s_axi_bready (s_axi_bready),

        .s_axi_arid ('0),
        .s_axi_araddr (32'(s_axi_araddr)),
        .s_axi_arlen (8'd0),
        .s_axi_aruser ('0),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),

        .s_axi_rid (rid),
        .s_axi_rdata (s_axi_rdata),
        .s_axi_rresp (s_axi_rresp),
        .s_axi_rlast (rlast),
        .s_axi_ruser (ruser),
        .s_axi_rvalid (s_axi_rvalid),
        .s_axi_rready (s_axi_rready),

        .events_o (events),

        .spi_clk (spi_sck),
        .spi_csn0 (spi_csn[0]),
        .spi_csn1 (spi_csn[1]),
        .spi_csn2 (spi_csn[2]),
        .spi_csn3 (spi_csn[3]),
        .spi_mode (spi_mode),
        .spi_sdo0 (sdo0),
        .spi_sdo1 (),
        .spi_sdo2 (),
        .spi_sdo3 (),
        .spi_sdi0 (1'b0),
        .spi_sdi1 (spi_miso),   //single-bit mode samples sdi1; see above
        .spi_sdi2 (1'b0),
        .spi_sdi3 (1'b0)
    );

    //The echoed ID, USER and RLAST have nowhere to go on a Lite master, and
    //spi_mode only matters to the quad lines this wrapper does not bring out.
    logic _unused;
    assign _unused = &{1'b0, bid, rid, rlast, buser, ruser, spi_mode,
                       s_axi_awprot, s_axi_arprot};

endmodule
