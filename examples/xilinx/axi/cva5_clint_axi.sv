/*
 * cva5_clint_axi -- the CLINT as a block-design peripheral.
 *
 * mtime, mtimecmp, msip and the timer and software interrupts, at the standard
 * layout (msip +0x0, mtimecmp +0x4000, mtime +0xBFF8) that SiFive, CVA6,
 * OpenTitan and QEMU's virt all use.
 *
 * This exists so the CLINT is a peripheral on the bus rather than something
 * inside the CPU IP. It first shipped inside cva5_top, because mtime is 64
 * bits and keeping it there saved 66 signals in the block design -- which was
 * optimising the wrong thing: cva5_top is the core, its memory and its debug
 * module, and a timer is none of those.
 *
 * The 66 signals are the price and they are paid here: mtime, mtip and msip
 * leave as plain nets and go to cva5_top's interrupt inputs.
 *
 * cva5_clint_wrapper's AXI4-Lite port has no awprot, arprot, wstrb, bresp or
 * rresp, so this supplies them. Nothing in the CLINT can fail and the crossbar
 * has already decided the address is in its window, so both responses are
 * constant OKAY. The write strobes are dropped: a sub-word write to one of
 * these registers writes the whole word, and software writes them a word at a
 * time, which is what the layout is designed for.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_clint_axi #(
    //Core clocks per microsecond, so that mtime counts microseconds rather
    //than core clocks. See examples/xilinx/vendor/cva5_clint.sv.
    parameter int unsigned CLOCK_MHZ = 100,

    //Width of the slave's address bus, and so the size of the address block
    //this IP offers the block design: 16 bits is the 64 KB the CLINT decodes.
    //A 32-bit port would offer 4 GB, which can only be placed at zero. The
    //opposite rule applies to master ports -- see README.pynq_z2.md.
    parameter int unsigned ADDR_WIDTH = 16
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

    //To the core
    output logic [63:0] mtime,
    output logic        mtip,
    output logic        msip
);

    //Active-high, and from rstn alone. A peripheral the debugger can reach
    //must not be reset by ndmreset: cpu_hold asserts it and THEN talks to the
    //system bus, so an access to a peripheral held in reset never completes.
    //That is why ndmreset does not leave cva5_top to get here.
    logic rst;
    always_ff @(posedge clk or negedge rstn) begin
        if (~rstn)
            rst <= 1'b1;
        else
            rst <= 1'b0;
    end

    cva5_clint_wrapper #(
        .NUM_CORES (1),
        .AXI (1'b1),
        .TICKS_PER_USEC (CLOCK_MHZ)
    ) clint_inst (
        .clk (clk),
        .rst (rst),
        .mtime (mtime),
        .msip (msip),
        .mtip (mtip),

        //Wishbone side unused; AXI = 1 selects the AXI-Lite port
        .wb_cyc (1'b0),
        .wb_stb (1'b0),
        .wb_we (1'b0),
        .wb_adr ('0),
        .wb_dat_i ('0),
        .wb_dat_o (),
        .wb_ack (),

        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awaddr (32'(s_axi_awaddr)),
        .s_axi_awready (s_axi_awready),
        .s_axi_wvalid (s_axi_wvalid),
        .s_axi_wdata (s_axi_wdata),
        .s_axi_wready (s_axi_wready),
        .s_axi_bvalid (s_axi_bvalid),
        .s_axi_bready (s_axi_bready),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_araddr (32'(s_axi_araddr)),
        .s_axi_arready (s_axi_arready),
        .s_axi_rvalid (s_axi_rvalid),
        .s_axi_rdata (s_axi_rdata),
        .s_axi_rready (s_axi_rready)
    );

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

endmodule
