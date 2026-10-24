/*
 * cva5_i2c_axi -- Alex Forencich's i2c_master_axil as a block-design
 * peripheral.
 *
 * An I2C master with a 32-bit AXI4-Lite slave port, command/write/read FIFOs
 * and a programmable prescaler, from third_party/verilog-i2c. MIT licensed,
 * which is the one place this tree departs from Apache or Solderpad: MIT is
 * more permissive than both and compatible with anything done with this fork,
 * but it carries no explicit patent grant. The alternative was OpenTitan's
 * i2c, which is Apache-2.0 and arrives with TLUL and the prim library in tow.
 *
 * Unlike every other peripheral here this one needs no protocol adaptation:
 * its slave port is already AXI4-Lite, 32-bit, with prot, strb, bresp and
 * rresp present. So this wrapper does three small things.
 *
 * It inverts the reset. Forencich's cores take an active-high synchronous
 * `rst`; everything else in this block design is active-low `rstn`. It is
 * registered locally from rstn alone and never ndmreset, because the debugger
 * can reach this peripheral over the system bus -- the rule in CLAUDE.md.
 *
 * It turns the core's open-drain triplets into two `inout` pins. The core
 * drives scl_o/scl_t and sda_o/sda_t with the convention its own header shows
 * (`assign scl_pin = scl_t ? 1'bz : scl_o`), where t and o are the same
 * signal: low means drive low, high means release. Vivado infers an IOBUF per
 * inout at the top level, and the bus needs external pull-ups -- the PYNQ-Z2
 * has them on the Arduino header's ar_scl/ar_sda, which is where these go.
 *
 * And it widens the address port. The device decodes four words, so the core's
 * slave address bus is 4 bits; this offers the 4 KB that is the floor for a
 * Vivado address segment, and the device aliases within the window.
 *
 * Register map, byte offsets (the full bit layout is in examples/sw/soc.h):
 *
 *   0x0  STATUS    busy, bus state, missed-ack, and the three FIFO flags.
 *                  Writing clears the sticky bits.
 *   0x4  COMMAND   7-bit address plus start/read/write/write-multiple/stop
 *   0x8  DATA      a byte out, or a byte in -- reading pops the read FIFO
 *   0xC  PRESCALE  16-bit, clk / (4 x the wanted SCL rate)
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_i2c_axi #(
    //Width of the slave's address bus, and so the address block this IP
    //offers the block design. The device decodes 16 bytes; 12 bits is the 4 KB
    //floor a Vivado address segment can be given. Master ports obey the
    //opposite rule and stay 32 bits wide; see CLAUDE.md.
    parameter int unsigned ADDR_WIDTH = 12,

    //clk / (4 x SCL). At 100 MHz: 250 for 100 kHz, 62 for 400 kHz. Software
    //can change it at runtime through the PRESCALE register; this is only the
    //value the core comes up with.
    parameter int unsigned DEFAULT_PRESCALE = 250,

    //Command, write and read FIFO depths, in entries.
    parameter int unsigned FIFO_DEPTH = 32
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

    //I2C, open drain. External pull-ups are required and the PYNQ-Z2's
    //Arduino header has them.
    inout  wire         scl,
    inout  wire         sda
);

    //Active-high and synchronous, which is what Forencich's cores want, and
    //from rstn alone -- never ndmreset, because cpu_hold asserts ndmreset and
    //THEN talks to the system bus, so a peripheral the debugger can reach must
    //not be held in reset by it.
    logic rst;
    always_ff @(posedge clk or negedge rstn) begin
        if (~rstn)
            rst <= 1'b1;
        else
            rst <= 1'b0;
    end

    logic scl_i, scl_o, scl_t;
    logic sda_i, sda_o, sda_t;

    //Open drain: t and o carry the same value, low drives the line low and
    //high releases it, which is the convention i2c_master.v's own header
    //documents.
    //
    //The buffers are instantiated rather than inferred, and that is not a
    //stylistic choice. Written as
    //
    //    assign scl = scl_t ? 1'bz : scl_o;
    //
    //it simulates correctly and SYNTHESISES WRONG, because a block design
    //synthesises each IP out of context: in that run this module is the top,
    //there is no I/O buffer for the high-Z to attach to, and Vivado resolves
    //it away --
    //
    //  CRITICAL WARNING: [Synth 8-5799] Converted tricell instance 'i_1' to
    //                    logic
    //
    //-- one per line. The released state goes with it and the pin is driven
    //high instead of let go, so this master fights every slave that pulls the
    //line down to ACK. Everything short of an actual transfer still passes:
    //the registers read back, the controller reports idle, and an addressed
    //slave never answers -- which is indistinguishable from an empty bus.
    //
    //An IOBUF is a real cell rather than an inferred one, so it survives the
    //out-of-context boundary. Verilator has no UNISIM library, so
    //test_benches/axi/IOBUF_stub.v models it -- a real model and not a tie-off,
    //so that what the bench drives through is the structure synthesis builds
    //rather than a second expression of the same intent. What the bench cannot
    //check is that Vivado keeps the cell; the packaging log does that, by not
    //reporting 8-5799.
    IOBUF scl_buf (.I(scl_o), .O(scl_i), .T(scl_t), .IO(scl));
    IOBUF sda_buf (.I(sda_o), .O(sda_i), .T(sda_t), .IO(sda));

    i2c_master_axil #(
        .DEFAULT_PRESCALE (DEFAULT_PRESCALE),
        .FIXED_PRESCALE (0),
        .CMD_FIFO (1),
        .CMD_FIFO_DEPTH (FIFO_DEPTH),
        .WRITE_FIFO (1),
        .WRITE_FIFO_DEPTH (FIFO_DEPTH),
        .READ_FIFO (1),
        .READ_FIFO_DEPTH (FIFO_DEPTH)
    ) i2c_inst (
        .clk (clk),
        .rst (rst),

        .s_axil_awaddr (s_axi_awaddr[3:0]),
        .s_axil_awprot (s_axi_awprot),
        .s_axil_awvalid (s_axi_awvalid),
        .s_axil_awready (s_axi_awready),
        .s_axil_wdata (s_axi_wdata),
        .s_axil_wstrb (s_axi_wstrb),
        .s_axil_wvalid (s_axi_wvalid),
        .s_axil_wready (s_axi_wready),
        .s_axil_bresp (s_axi_bresp),
        .s_axil_bvalid (s_axi_bvalid),
        .s_axil_bready (s_axi_bready),
        .s_axil_araddr (s_axi_araddr[3:0]),
        .s_axil_arprot (s_axi_arprot),
        .s_axil_arvalid (s_axi_arvalid),
        .s_axil_arready (s_axi_arready),
        .s_axil_rdata (s_axi_rdata),
        .s_axil_rresp (s_axi_rresp),
        .s_axil_rvalid (s_axi_rvalid),
        .s_axil_rready (s_axi_rready),

        .i2c_scl_i (scl_i),
        .i2c_scl_o (scl_o),
        .i2c_scl_t (scl_t),
        .i2c_sda_i (sda_i),
        .i2c_sda_o (sda_o),
        .i2c_sda_t (sda_t)
    );

    //The device decodes four words; the rest of the window aliases onto them.
    logic _unused;
    assign _unused = &{1'b0, s_axi_awaddr[ADDR_WIDTH-1:4],
                       s_axi_araddr[ADDR_WIDTH-1:4]};

endmodule
