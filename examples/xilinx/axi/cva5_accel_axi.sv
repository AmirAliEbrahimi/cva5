/*
 * cva5_accel_axi -- the hls4ml accelerator's attachment to CVA5.
 *
 * One AXI4-Lite slave for software, one AXI4 master into main memory, a
 * 24-bit stream out to the accelerator and a 32-bit stream back. It replaces
 * five Xilinx IPs from the first version of this design: axi_fifo_mm_s,
 * axis_dwidth_converter, axi_gpio, xlconcat and xlconstant.
 *
 * WHAT MOVES, AND WHY THIS SHAPE.
 *
 * The first version had CVA5 store the image into a memory-mapped stream
 * FIFO a word at a time: 1,536 stores through the peripheral bus, about 15
 * cycles each, 23,551 of the 30,498 cycles an inference took. Seventy-seven
 * per cent of the time was the processor acting as a DMA.
 *
 * So there is a real DMA here, ZipCPU's aximm2s (Apache-2.0, already a
 * submodule), reading main memory over cva5_top's s_axi_acc port. The image
 * stays where it was loaded, CVA5 writes an address and a length, and the
 * transfer overlaps the compute instead of preceding it. The compute itself
 * is 6,947 cycles and does not move, so the ceiling is about four times
 * faster end to end -- not the 220x that "if the transfer were free" suggests.
 *
 * The RETURN path is not a DMA, and that is deliberate. The accelerator
 * produces exactly one 32-bit beat per inference: layer9_out_TDATA is
 * [31:0] and one inference is one result. A second DMA to move four bytes
 * would be a second AXI master, a fourth port on the arbitration tree and
 * another set of descriptors to program, all to avoid a register read. So
 * the result is captured here and read over the Lite port.
 *
 * ap_start, ap_done, ap_idle and ap_ready are register bits rather than an
 * axi_gpio. The old design needed GPIO because it had no register block of
 * its own; this one does. GOTCHAS #4 -- axi_gpio's tri-state resets to input
 * and ap_start never asserts -- stops being possible.
 *
 * REGISTER MAP, byte offsets in a 4 KB window.
 *
 *   0x000-0x01F  the DMA's own registers, aximm2s's map unchanged:
 *                  0x000 CMD_CONTROL  [31] busy [30] err [29] complete
 *                                     [28] continuous [27] !increment
 *                  0x008 CMD_ADDRLO   where to read the image from
 *                  0x018 CMD_LENLO    how many bytes
 *   0x020  CTRL     [0] ap_start. Set by software, cleared here when the
 *                   accelerator takes it (ap_ready), which is what ap_ctrl_hs
 *                   wants and what software should not have to time.
 *   0x024  STATUS   [0] ap_done [1] ap_idle [2] ap_ready
 *                   [3] result_valid [4] the DMA's own completion
 *   0x028  RESULT   the last beat the accelerator produced. Reading it
 *                   clears result_valid, so a stale result cannot be
 *                   mistaken for a fresh one.
 *   0x02C  PADSEEN  beats whose dropped lane was not zero -- see
 *                   cva5_axis_lane.sv. Non-zero means the image in memory is
 *                   not 4 bytes per pixel, which nothing else can detect.
 *
 * The address decode is one bit: addr[5] picks the DMA's registers or these.
 * AXI4-Lite has no bursts and the crossbar in front allows two outstanding
 * transactions, so the selection is latched per transaction rather than
 * demultiplexed per channel.
 *
 * The master port carries read channels only. aximm2s does not write, so AW,
 * W and B are tied off here rather than left floating; cva5_ram_mux grants on
 * awvalid | arvalid, so a port that never raises awvalid simply never asks
 * for a write.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_accel_axi #(
    //Main memory's address width as cva5_top presents it: RAM_ADDR_W+2 bytes
    //of byte address. The DMA addresses the same window the core does.
    parameter int unsigned ADDR_WIDTH = 17,

    //Echoed by everything on the RAM path; 12 is what a Zynq PS master
    //carries and what cva5_ram_mux is parameterised to here.
    parameter int unsigned ID_WIDTH = 12,

    //The accelerator's input beat. 24 bits is three channels of
    //ap_ufixed<8,0>; see cva5_axis_lane.sv for why it is a lane select and
    //not a width converter.
    parameter int unsigned STREAM_WIDTH = 24,

    //The DMA's internal FIFO, log2 of its depth in beats. 10 is 1024 words,
    //one whole 32x32 image, so a transfer never stalls on the FIFO.
    parameter int unsigned LGFIFO = 10
) (
    input  logic clk,
    input  logic rstn,

    //---- AXI4-Lite slave: software ---------------------------------------
    input  logic [11:0] s_axi_awaddr,
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
    input  logic [11:0] s_axi_araddr,
    input  logic [2:0]  s_axi_arprot,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    //---- AXI4 master: main memory, through cva5_top's s_axi_acc ----------
    output logic [ID_WIDTH-1:0]   m_axi_awid,
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [31:0]           m_axi_wdata,
    output logic [3:0]            m_axi_wstrb,
    output logic                  m_axi_wlast,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    input  logic [ID_WIDTH-1:0]   m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready,
    output logic [ID_WIDTH-1:0]   m_axi_arid,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]            m_axi_arlen,
    output logic [2:0]            m_axi_arsize,
    output logic [1:0]            m_axi_arburst,
    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    input  logic [ID_WIDTH-1:0]   m_axi_rid,
    input  logic [31:0]           m_axi_rdata,
    input  logic [1:0]            m_axi_rresp,
    input  logic                  m_axi_rlast,
    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,

    //---- to and from the accelerator -------------------------------------
    output logic [STREAM_WIDTH-1:0] m_axis_tdata,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic                    m_axis_tlast,

    input  logic [31:0]             s_axis_tdata,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,

    output logic                    ap_start,
    input  logic                    ap_done,
    input  logic                    ap_idle,
    input  logic                    ap_ready,

    //Level-high while a result is waiting to be read. For the PLIC, so an
    //inference does not have to be polled for.
    output logic                    irq
);

    //---- Transaction routing ---------------------------------------------
    //addr[5]: low half is the DMA's 32-byte register map, high half is ours.
    logic aw_is_reg, ar_is_reg;
    assign aw_is_reg = s_axi_awaddr[5];
    assign ar_is_reg = s_axi_araddr[5];

    //The write data channel carries no address, so the choice made at AW is
    //held for W and B. W is not accepted before its AW has been, which is
    //legal -- a master may present W first -- and keeps one rule instead of
    //two.
    //The address is latched with it. AXI lets the master drop AWADDR as soon
    //as AW handshakes, and W can be a cycle or more later: decoding the write
    //from the live s_axi_awaddr reads whatever is on the bus by then, which
    //in this bench was zero and silently wrote CMD_CONTROL instead of CTRL.
    logic aw_held, w_to_reg;
    logic [11:0] aw_addr_q;
    always_ff @(posedge clk) begin
        if (~rstn) begin
            aw_held   <= 1'b0;
            w_to_reg  <= 1'b0;
            aw_addr_q <= '0;
        end else begin
            if (s_axi_awvalid & s_axi_awready) begin
                aw_held   <= 1'b1;
                w_to_reg  <= aw_is_reg;
                aw_addr_q <= s_axi_awaddr;
            end
            if (s_axi_bvalid & s_axi_bready)
                aw_held <= 1'b0;
        end
    end

    logic r_from_reg;
    always_ff @(posedge clk) begin
        if (~rstn)
            r_from_reg <= 1'b0;
        else if (s_axi_arvalid & s_axi_arready)
            r_from_reg <= ar_is_reg;
    end

    //---- Our own registers ------------------------------------------------
    logic        start_q;
    logic [31:0] result_q;
    logic        result_valid;
    logic [15:0] pad_seen;

    assign ap_start = start_q;
    assign irq      = result_valid;

    //The accelerator takes ap_start on ap_ready; holding it longer would
    //start a second inference the moment the first finished.
    logic reg_wr;
    logic [31:0] reg_rdata;

    assign s_axis_tready = 1'b1;   //a single beat; never a reason to stall

    logic result_read;

    always_ff @(posedge clk) begin
        if (~rstn) begin
            start_q      <= 1'b0;
            result_q     <= '0;
            result_valid <= 1'b0;
        end else begin
            if (reg_wr && aw_addr_q[4:2] == 3'd0)
                start_q <= s_axi_wdata[0];
            else if (ap_ready)
                start_q <= 1'b0;

            if (s_axis_tvalid & s_axis_tready) begin
                result_q     <= s_axis_tdata;
                result_valid <= 1'b1;
            end else if (result_read)
                result_valid <= 1'b0;
        end
    end

    //---- The register block's AXI4-Lite side ------------------------------
    logic reg_awready, reg_wready, reg_bvalid, reg_arready, reg_rvalid;

    //One transaction at a time, which is all the crossbar in front issues
    //for a Lite slave and all these four registers need.
    assign reg_awready = ~aw_held;
    assign reg_wready  = aw_held & w_to_reg & ~reg_bvalid;
    assign reg_wr      = aw_held & w_to_reg & s_axi_wvalid & reg_wready;

    always_ff @(posedge clk) begin
        if (~rstn)
            reg_bvalid <= 1'b0;
        else if (reg_wr)
            reg_bvalid <= 1'b1;
        else if (s_axi_bready)
            reg_bvalid <= 1'b0;
    end

    assign reg_arready = ~reg_rvalid;
    always_ff @(posedge clk) begin
        if (~rstn) begin
            reg_rvalid  <= 1'b0;
            result_read <= 1'b0;
        end else begin
            result_read <= 1'b0;
            if (s_axi_arvalid & s_axi_arready & ar_is_reg) begin
                reg_rvalid <= 1'b1;
                case (s_axi_araddr[4:2])
                    3'd0: reg_rdata <= {31'd0, start_q};
                    3'd1: reg_rdata <= {27'd0, dma_int, result_valid,
                                        ap_ready, ap_idle, ap_done};
                    3'd2: begin reg_rdata <= result_q; result_read <= 1'b1; end
                    3'd3: reg_rdata <= {16'd0, pad_seen};
                    default: reg_rdata <= 32'd0;
                endcase
            end else if (s_axi_rready)
                reg_rvalid <= 1'b0;
        end
    end

    //---- The DMA ----------------------------------------------------------
    logic        dma_awready, dma_wready, dma_bvalid, dma_arready, dma_rvalid;
    logic [1:0]  dma_bresp, dma_rresp;
    logic [31:0] dma_rdata;
    logic        dma_int;
    logic [31:0] dma_axis_tdata;
    logic        dma_axis_tvalid, dma_axis_tready, dma_axis_tlast;

    aximm2s #(
        .C_AXI_ADDR_WIDTH (ADDR_WIDTH),
        .C_AXI_DATA_WIDTH (32),
        .C_AXI_ID_WIDTH   (ID_WIDTH),
        .LGFIFO           (LGFIFO),
        .OPT_TLAST        (1'b1),
        .OPT_UNALIGNED    (1'b0)
    ) dma (
        .S_AXI_ACLK (clk),
        .S_AXI_ARESETN (rstn),

        .S_AXIL_AWVALID (s_axi_awvalid & ~aw_is_reg),
        .S_AXIL_AWREADY (dma_awready),
        .S_AXIL_AWADDR (s_axi_awaddr[4:0]),
        .S_AXIL_AWPROT (s_axi_awprot),
        .S_AXIL_WVALID (s_axi_wvalid & aw_held & ~w_to_reg),
        .S_AXIL_WREADY (dma_wready),
        .S_AXIL_WDATA (s_axi_wdata),
        .S_AXIL_WSTRB (s_axi_wstrb),
        .S_AXIL_BVALID (dma_bvalid),
        .S_AXIL_BREADY (s_axi_bready & aw_held & ~w_to_reg),
        .S_AXIL_BRESP (dma_bresp),
        .S_AXIL_ARVALID (s_axi_arvalid & ~ar_is_reg),
        .S_AXIL_ARREADY (dma_arready),
        .S_AXIL_ARADDR (s_axi_araddr[4:0]),
        .S_AXIL_ARPROT (s_axi_arprot),
        .S_AXIL_RVALID (dma_rvalid),
        .S_AXIL_RREADY (s_axi_rready & ~r_from_reg),
        .S_AXIL_RDATA (dma_rdata),
        .S_AXIL_RRESP (dma_rresp),

        .M_AXI_ARVALID (m_axi_arvalid),
        .M_AXI_ARREADY (m_axi_arready),
        .M_AXI_ARID (m_axi_arid),
        .M_AXI_ARADDR (m_axi_araddr),
        .M_AXI_ARLEN (m_axi_arlen),
        .M_AXI_ARSIZE (m_axi_arsize),
        .M_AXI_ARBURST (m_axi_arburst),
        .M_AXI_ARLOCK (),
        .M_AXI_ARCACHE (),
        .M_AXI_ARPROT (),
        .M_AXI_ARQOS (),
        .M_AXI_RVALID (m_axi_rvalid),
        .M_AXI_RREADY (m_axi_rready),
        .M_AXI_RID (m_axi_rid),
        .M_AXI_RDATA (m_axi_rdata),
        .M_AXI_RLAST (m_axi_rlast),
        .M_AXI_RRESP (m_axi_rresp),

        .M_AXIS_TVALID (dma_axis_tvalid),
        .M_AXIS_TREADY (dma_axis_tready),
        .M_AXIS_TDATA (dma_axis_tdata),
        .M_AXIS_TLAST (dma_axis_tlast),

        //aximm2s's own completion interrupt. Surfaced in STATUS
        //rather than dropped: the DMA finishing and the
        //accelerator finishing are different events, and a
        //transfer that completed while the result never arrived
        //is the symptom of a stream that is not connected.
        .o_int (dma_int)
    );

    //The master port never writes. Tied off rather than left dangling: a
    //floating awvalid into cva5_ram_mux would ask for a write that nothing
    //would ever supply data for, and hold the port for good.
    assign m_axi_awid    = '0;
    assign m_axi_awaddr  = '0;
    assign m_axi_awlen   = '0;
    assign m_axi_awsize  = 3'd2;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = 1'b0;
    assign m_axi_wdata   = '0;
    assign m_axi_wstrb   = '0;
    assign m_axi_wlast   = 1'b0;
    assign m_axi_wvalid  = 1'b0;
    assign m_axi_bready  = 1'b1;

    //---- 32 bits of memory word to 24 bits of pixel -----------------------
    cva5_axis_lane #(
        .S_WIDTH (32),
        .M_WIDTH (STREAM_WIDTH)
    ) lane (
        .clk (clk),
        .rstn (rstn),
        .s_axis_tdata (dma_axis_tdata),
        .s_axis_tvalid (dma_axis_tvalid),
        .s_axis_tready (dma_axis_tready),
        .s_axis_tlast (dma_axis_tlast),
        .m_axis_tdata (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tlast (m_axis_tlast),
        .pad_seen (pad_seen)
    );

    //---- The Lite responses, back to the one slave port -------------------
    assign s_axi_awready = aw_is_reg ? reg_awready : dma_awready;
    assign s_axi_wready  = aw_held ? (w_to_reg ? reg_wready : dma_wready)
                                   : 1'b0;
    assign s_axi_bvalid  = w_to_reg ? reg_bvalid : dma_bvalid;
    assign s_axi_bresp   = w_to_reg ? 2'b00      : dma_bresp;
    assign s_axi_arready = ar_is_reg ? reg_arready : dma_arready;
    assign s_axi_rvalid  = r_from_reg ? reg_rvalid : dma_rvalid;
    assign s_axi_rdata   = r_from_reg ? reg_rdata  : dma_rdata;
    assign s_axi_rresp   = r_from_reg ? 2'b00      : dma_rresp;

endmodule
