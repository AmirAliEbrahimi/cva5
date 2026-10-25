/*
 * cva5_plic_axi -- the PLIC as a block-design peripheral.
 *
 * The platform interrupt controller: one line into the core carrying whichever
 * device interrupt is currently the highest priority one that is pending,
 * enabled, and above this target's threshold. Device interrupts arrive here as
 * plain nets, software claims and completes them through the register map, and
 * only `eip` leaves for the CPU.
 *
 * That division is the architecture's, not a choice: RISC-V gives the timer
 * and software interrupts their own mip bits (MTIP, cause 7; MSIP, cause 3),
 * which is why they come straight from the CLINT, and gives every device
 * interrupt the single external bit (MEIP, cause 11), which is what this
 * block drives. So cva5_top takes three interrupt inputs in total, however
 * many peripherals the bus grows.
 *
 * cva5_plic_wrapper's AXI4-Lite port has no awprot, arprot, wstrb, bresp or
 * rresp, so this supplies them -- the same omission cva5_clint_axi covers.
 * Nothing in the PLIC can fail an access and the crossbar has already decided
 * the address is in its window, so both responses are constant OKAY. The write
 * strobes are dropped: every register here is written a word at a time.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_plic_axi #(
    //Interrupt sources, numbered from 1 -- source 0 does not exist, and the
    //PLIC hardwires its priority and enable to zero as the spec requires.
    //Upstream supports up to 32; the header in cva5_plic.sv explains why more
    //would want a different design.
    parameter int unsigned NUM_SOURCES = 8,

    //Priority levels, as a width: 4 bits is 15 usable levels, since 0 means
    //"never interrupt". A threshold of 0 lets everything through.
    parameter int unsigned PRIORITY_W = 4,

    //Where the register stage sits in the priority comparison tree. The
    //wrapper corrects it down if it would fall off the end of the tree.
    parameter int unsigned REG_STAGE = 1,

    //Per source, from bit 0 = source 1: 1 for edge sensitive (either edge), 0
    //for level sensitive and active high. A parameter rather than a port
    //because a block design has nothing to tie an unused input vector to
    //without a Xilinx constant block, and sensitivity is a property of the
    //device wired in, fixed at build time -- cva5_uart's irq is
    //!rx_fifo_empty, which is level and stays up until software drains the
    //FIFO.
    parameter logic [31:0] EDGE_SENSITIVE = 32'h0,

    //Width of the slave's address bus, and so the size of the address block
    //this IP offers the block design. The PLIC decodes addr[25:2], so 26 bits
    //is exactly what it answers to: 64 MB, which is also the window
    //examples/sw/soc.h reserves at 0x0C00_0000 and what the standard map
    //needs, since threshold and claim live at +0x200000. Master ports obey the
    //opposite rule and stay 32 bits wide; see README.pynq_z2.md.
    parameter int unsigned ADDR_WIDTH = 26
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

    //Device interrupts. Bit 0 is source 1, so irq_srcs[i] is source i+1 --
    //a flat vector from zero because a block design cannot carry a port
    //declared [NUM_SOURCES:1]. Unused bits are tied low.
    input  logic [NUM_SOURCES-1:0] irq_srcs,


    //To the core: the external interrupt, mip.MEIP.
    output logic        eip
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

    cva5_plic_wrapper #(
        .NUM_SOURCES (NUM_SOURCES),
        .NUM_TARGETS (1),
        .PRIORITY_W (PRIORITY_W),
        .REG_STAGE (REG_STAGE),
        .AXI (1'b1)
    ) plic_inst (
        .clk (clk),
        .rst (rst),

        .irq_srcs (irq_srcs),
        .edge_sensitive (EDGE_SENSITIVE[NUM_SOURCES-1:0]),
        .eip (eip),

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

    //The strobes have nowhere to go: cva5_plic_wrapper writes whole words.
    logic _unused;
    assign _unused = &{1'b0, s_axi_wstrb, s_axi_awprot, s_axi_arprot};

endmodule
