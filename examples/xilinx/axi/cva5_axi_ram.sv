/*
 * cva5_axi_ram -- the SoC's main RAM, as a single AXI4 slave.
 *
 * Replaces Xilinx's axi_bram_ctrl + blk_mem_gen pair. The AXI side is
 * ZipCPU's demofull (WB2AXIP, Apache 2.0), a formally verified AXI4 slave
 * that sustains one beat per clock on both channels. demofull deliberately
 * leaves the storage to the integrator and documents the exact array it
 * expects, which is what this file supplies: the standard simple-dual-port
 * inference template, one write port and one registered read port, which
 * Vivado maps onto block RAM.
 *
 * Sizing is by SIZE_BYTES, which must be a power of two. 128 KB is
 * RAM_SIZE in examples/sw/soc.h and costs 32 RAMB36 on the xc7z020 -- the
 * same as the IP pair it replaces.
 *
 * Reset is active low (S_AXI_ARESETN), matching proc_sys_reset's
 * peripheral_aresetn and the rest of this SoC.
 *
 * Read-during-write to the same address returns the old data. AXI does not
 * order a read against a write on the other channel without a barrier, so
 * this is the normal behaviour of a memory slave rather than a limitation
 * of this one; the only master that both reads and writes here is CVA5's
 * cache, which orders its own fills and writebacks.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_axi_ram #(
    // Size of the memory in bytes; must be a power of two.
    parameter int unsigned SIZE_BYTES = 32'd131072,   // 128 KB
    // Transaction ID width. The crossbar's master ports carry 8 bits.
    parameter int unsigned ID_WIDTH   = 32'd8,
    // Address bits the slave decodes. Derived from SIZE_BYTES; the block
    // design truncates the master's address down to this width.
    parameter int unsigned ADDR_WIDTH = $clog2(SIZE_BYTES),
    // How many block RAMs Vivado groups behind one decode stage. See the
    // note on the array below: on 7-series at this width it sets the depth
    // of the fabric output mux, not a hardware cascade. 128 KB is 32 block
    // RAMs, so 8 gives four groups behind a 4-to-1 mux, 16 gives two behind
    // a 2-to-1, and 32 gives one group with no output mux at all.
    //
    // Exposed as a parameter because it is the only knob here measured to
    // move the design's critical path (8 was worth 0.084 ns over the
    // default) and the sweep above 8 is unexplored. Changing it from the
    // block design needs a regenerate and resynthesis, but no repackaging.
    parameter int unsigned CASCADE_HEIGHT = 32'd8
    ) (
        input logic clk,
        input logic rstn, //Synchronous active low

        input logic [ID_WIDTH-1:0] s_axi_awid,
        input logic [ADDR_WIDTH-1:0] s_axi_awaddr,
        input logic [7:0] s_axi_awlen,
        input logic [2:0] s_axi_awsize,
        input logic [1:0] s_axi_awburst,
        input logic s_axi_awlock,
        input logic [3:0] s_axi_awcache,
        input logic [2:0] s_axi_awprot,
        input logic [3:0] s_axi_awqos,
        input logic s_axi_awvalid,
        output logic s_axi_awready,

        input logic [31:0] s_axi_wdata,
        input logic [3:0] s_axi_wstrb,
        input logic s_axi_wlast,
        input logic s_axi_wvalid,
        output logic s_axi_wready,

        output logic [ID_WIDTH-1:0] s_axi_bid,
        output logic [1:0] s_axi_bresp,
        output logic s_axi_bvalid,
        input logic s_axi_bready,

        input logic [ID_WIDTH-1:0] s_axi_arid,
        input logic [ADDR_WIDTH-1:0] s_axi_araddr,
        input logic [7:0] s_axi_arlen,
        input logic [2:0] s_axi_arsize,
        input logic [1:0] s_axi_arburst,
        input logic s_axi_arlock,
        input logic [3:0] s_axi_arcache,
        input logic [2:0] s_axi_arprot,
        input logic [3:0] s_axi_arqos,
        input logic s_axi_arvalid,
        output logic s_axi_arready,

        output logic [ID_WIDTH-1:0] s_axi_rid,
        output logic [31:0] s_axi_rdata,
        output logic [1:0] s_axi_rresp,
        output logic s_axi_rlast,
        output logic s_axi_rvalid,
        input logic s_axi_rready
    );

    localparam int unsigned LSB   = 2;                       // 32-bit words
    localparam int unsigned WORDS = SIZE_BYTES / 4;
    localparam int unsigned WADDR = ADDR_WIDTH - LSB;        // word address bits

    logic             mem_we;
    logic [WADDR-1:0] mem_waddr;
    logic [31:0]      mem_wdata;
    logic [3:0]       mem_wstrb;
    logic             mem_rd;
    logic [WADDR-1:0] mem_raddr;
    logic [31:0]      mem_rdata;

    demofull #(
        .C_S_AXI_ID_WIDTH   (ID_WIDTH),
        .C_S_AXI_DATA_WIDTH (32),
        .C_S_AXI_ADDR_WIDTH (ADDR_WIDTH),
        // No exclusive access: CVA5's cached master does not issue it, and
        // leaving it on costs a lock-tracking register file.
        .OPT_LOCK           (1'b0)
    ) axi_inst (
        .o_we     (mem_we),
        .o_waddr  (mem_waddr),
        .o_wdata  (mem_wdata),
        .o_wstrb  (mem_wstrb),
        .o_rd     (mem_rd),
        .o_raddr  (mem_raddr),
        .i_rdata  (mem_rdata),

        .S_AXI_ACLK    (clk),
        .S_AXI_ARESETN (rstn),

        .S_AXI_AWID    (s_axi_awid),
        .S_AXI_AWADDR  (s_axi_awaddr),
        .S_AXI_AWLEN   (s_axi_awlen),
        .S_AXI_AWSIZE  (s_axi_awsize),
        .S_AXI_AWBURST (s_axi_awburst),
        .S_AXI_AWLOCK  (s_axi_awlock),
        .S_AXI_AWCACHE (s_axi_awcache),
        .S_AXI_AWPROT  (s_axi_awprot),
        .S_AXI_AWQOS   (s_axi_awqos),
        .S_AXI_AWVALID (s_axi_awvalid),
        .S_AXI_AWREADY (s_axi_awready),

        .S_AXI_WDATA   (s_axi_wdata),
        .S_AXI_WSTRB   (s_axi_wstrb),
        .S_AXI_WLAST   (s_axi_wlast),
        .S_AXI_WVALID  (s_axi_wvalid),
        .S_AXI_WREADY  (s_axi_wready),

        .S_AXI_BID     (s_axi_bid),
        .S_AXI_BRESP   (s_axi_bresp),
        .S_AXI_BVALID  (s_axi_bvalid),
        .S_AXI_BREADY  (s_axi_bready),

        .S_AXI_ARID    (s_axi_arid),
        .S_AXI_ARADDR  (s_axi_araddr),
        .S_AXI_ARLEN   (s_axi_arlen),
        .S_AXI_ARSIZE  (s_axi_arsize),
        .S_AXI_ARBURST (s_axi_arburst),
        .S_AXI_ARLOCK  (s_axi_arlock),
        .S_AXI_ARCACHE (s_axi_arcache),
        .S_AXI_ARPROT  (s_axi_arprot),
        .S_AXI_ARQOS   (s_axi_arqos),
        .S_AXI_ARVALID (s_axi_arvalid),
        .S_AXI_ARREADY (s_axi_arready),

        .S_AXI_RID     (s_axi_rid),
        .S_AXI_RDATA   (s_axi_rdata),
        .S_AXI_RRESP   (s_axi_rresp),
        .S_AXI_RLAST   (s_axi_rlast),
        .S_AXI_RVALID  (s_axi_rvalid),
        .S_AXI_RREADY  (s_axi_rready)
    );

    //------------------------------------------------------------------
    // The storage. This is the array demofull documents in its header: a
    // byte-enabled write port and a registered read port, no reset on the
    // data, which is what Vivado needs to infer block RAM rather than
    // flip-flops.
    //
    // cascade_height is worth 0.084 ns on this design, but NOT for the
    // reason the attribute's name suggests. Byte enables force 36-bit
    // primitives, so 128 KB is 32 RAMB36 of 1024 words each, and the real
    // hardware cascade path cannot be used here at all: UG473 restricts
    // CASCADEIN/CASCADEOUT to 64K x 1 in true-dual-port mode, and this is a
    // 32-bit simple-dual-port array. Measured placement confirms it -- the
    // eight members of a group land in three different BRAM columns, which a
    // real cascade could never do, since it needs adjacent sites in one.
    //
    // What the attribute actually does on 7-series at this width is
    // restructure the fabric: instead of one 32-to-1 output mux with 32
    // block RAMs feeding it, four groups of eight are decoded separately and
    // combined 4-to-1. That is a shallower mux on the read path, and it is
    // the whole of the gain. It does not make the placement more compact,
    // and it does not keep the RAM out of the core's BRAM columns -- the
    // core's block RAMs sit together in one column regardless, with the
    // critical path's two endpoints on adjacent sites.
    //
    // 32 RAMB36 is therefore the floor for 128 KB with byte enables. The
    // only way to a smaller footprint is a smaller SIZE_BYTES, and 128 KB
    // is the requirement -- the Xilinx axi_bram_ctrl and blk_mem_gen pair
    // this replaces met 100 MHz at that size, so shrinking the memory would
    // not be closing timing, it would be changing the design.
    //
    // Since the gain came from mux depth, CASCADE_HEIGHT is a parameter and
    // the sweep above 8 is the open question: 16 gives a 2-to-1 output mux,
    // 32 gives none. Deeper grouping decodes more addresses per stage, so it
    // is not free -- the point is that nobody has measured where the optimum
    // is, and the read path is the one structural difference left between
    // this array and the generated macro it replaces.
    //------------------------------------------------------------------
    (* ram_style = "block", cascade_height = CASCADE_HEIGHT *)
    logic [31:0] mem [WORDS];

    always_ff @(posedge clk) begin
        if (mem_we) begin
            for (int b = 0; b < 4; b++)
                if (mem_wstrb[b])
                    mem[mem_waddr][8*b +: 8] <= mem_wdata[8*b +: 8];
        end
        if (mem_rd)
            mem_rdata <= mem[mem_raddr];
    end

endmodule
