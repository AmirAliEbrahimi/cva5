/*
 * cva5_axi_cut -- AXI4 register slice for the CVA5 SoC.
 *
 * A drop-in replacement for Xilinx's axi_register_slice on the cached memory
 * path (I$/D$ line fills). The body is pulp-platform's axi_cut, which puts a
 * spill register on all five channels: one cycle of latency each way, full
 * throughput, and no combinational path from the slave port to the master
 * port or back.
 *
 * Why it is here at all: CVA5's AXI adapter computes arvalid combinationally
 * out of its arbiter FIFO, and the crossbar grants in the same cycle. Without
 * a break that path misses 100 MHz on the xc7z020. One extra cycle on a line
 * fill is irrelevant next to the BRAM access itself.
 *
 * Note on reset: pulp's common_cells reset asynchronously (`always_ff @(posedge
 * clk_i or negedge rst_ni)`), while the rest of this SoC resets synchronously.
 * That is safe here for the same reason it already is in the debug subsystem,
 * which is pulp code too: the net driven in is proc_sys_reset's
 * peripheral_aresetn, which is itself synchronised to this clock and released
 * synchronously, so the spill registers all leave reset in the same cycle.
 *
 * The ports are flat (no SystemVerilog structs or interfaces) so that Vivado's
 * IP packager infers an AXI4 slave and an AXI4 master from the names, and they
 * mirror cva5_wrapper's m_axi_mem signal-for-signal: the signals AXI4 defines
 * but CVA5 does not drive (prot, lock, qos, region, user) are absent here too,
 * and Vivado ties them to their defaults at the block-design connection.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_axi_cut #(
    // AXI transaction ID width. CVA5's cached master uses 6 bits.
    parameter int unsigned ID_WIDTH = 6
    ) (
        input logic clk,
        input logic rstn, //Synchronous active low

        //----------------------------------------------------------------
        // Slave port: from the CPU's cached memory master
        //----------------------------------------------------------------
        output logic s_axi_arready,
        input logic s_axi_arvalid,
        input logic [31:0] s_axi_araddr,
        input logic [7:0] s_axi_arlen,
        input logic [2:0] s_axi_arsize,
        input logic [1:0] s_axi_arburst,
        input logic [3:0] s_axi_arcache,
        input logic [ID_WIDTH-1:0] s_axi_arid,

        input logic s_axi_rready,
        output logic s_axi_rvalid,
        output logic [31:0] s_axi_rdata,
        output logic [1:0] s_axi_rresp,
        output logic s_axi_rlast,
        output logic [ID_WIDTH-1:0] s_axi_rid,

        output logic s_axi_awready,
        input logic s_axi_awvalid,
        input logic [31:0] s_axi_awaddr,
        input logic [7:0] s_axi_awlen,
        input logic [2:0] s_axi_awsize,
        input logic [1:0] s_axi_awburst,
        input logic [3:0] s_axi_awcache,
        input logic [ID_WIDTH-1:0] s_axi_awid,

        output logic s_axi_wready,
        input logic s_axi_wvalid,
        input logic [31:0] s_axi_wdata,
        input logic [3:0] s_axi_wstrb,
        input logic s_axi_wlast,

        input logic s_axi_bready,
        output logic s_axi_bvalid,
        output logic [1:0] s_axi_bresp,
        output logic [ID_WIDTH-1:0] s_axi_bid,

        //----------------------------------------------------------------
        // Master port: on towards the memory
        //----------------------------------------------------------------
        input logic m_axi_arready,
        output logic m_axi_arvalid,
        output logic [31:0] m_axi_araddr,
        output logic [7:0] m_axi_arlen,
        output logic [2:0] m_axi_arsize,
        output logic [1:0] m_axi_arburst,
        output logic [3:0] m_axi_arcache,
        output logic [2:0] m_axi_arprot,
        output logic m_axi_arlock,
        output logic [3:0] m_axi_arqos,
        output logic [ID_WIDTH-1:0] m_axi_arid,

        output logic m_axi_rready,
        input logic m_axi_rvalid,
        input logic [31:0] m_axi_rdata,
        input logic [1:0] m_axi_rresp,
        input logic m_axi_rlast,
        input logic [ID_WIDTH-1:0] m_axi_rid,

        input logic m_axi_awready,
        output logic m_axi_awvalid,
        output logic [31:0] m_axi_awaddr,
        output logic [7:0] m_axi_awlen,
        output logic [2:0] m_axi_awsize,
        output logic [1:0] m_axi_awburst,
        output logic [3:0] m_axi_awcache,
        output logic [2:0] m_axi_awprot,
        output logic m_axi_awlock,
        output logic [3:0] m_axi_awqos,
        output logic [ID_WIDTH-1:0] m_axi_awid,

        input logic m_axi_wready,
        output logic m_axi_wvalid,
        output logic [31:0] m_axi_wdata,
        output logic [3:0] m_axi_wstrb,
        output logic m_axi_wlast,

        output logic m_axi_bready,
        input logic m_axi_bvalid,
        input logic [1:0] m_axi_bresp,
        input logic [ID_WIDTH-1:0] m_axi_bid
    );

    //------------------------------------------------------------------
    // Channel and request/response types.
    //
    // Field order and names match axi/typedef.svh (AXI_TYPEDEF_*_CHAN_T),
    // which is what axi_cut's spill registers expect. The widths are spelled
    // out instead of taken from axi_pkg so that this IP carries no package:
    // two packaged IPs in one block design must not both define axi_pkg.
    //------------------------------------------------------------------
    typedef logic [ID_WIDTH-1:0] id_t;

    typedef struct packed {
        id_t         id;
        logic [31:0] addr;
        logic [7:0]  len;     // axi_pkg::len_t
        logic [2:0]  size;    // axi_pkg::size_t
        logic [1:0]  burst;   // axi_pkg::burst_t
        logic        lock;
        logic [3:0]  cache;   // axi_pkg::cache_t
        logic [2:0]  prot;    // axi_pkg::prot_t
        logic [3:0]  qos;     // axi_pkg::qos_t
        logic [3:0]  region;  // axi_pkg::region_t
        logic [5:0]  atop;    // axi_pkg::atop_t
        logic        user;
    } aw_chan_t;

    typedef struct packed {
        logic [31:0] data;
        logic [3:0]  strb;
        logic        last;
        logic        user;
    } w_chan_t;

    typedef struct packed {
        id_t        id;
        logic [1:0] resp;     // axi_pkg::resp_t
        logic       user;
    } b_chan_t;

    typedef struct packed {
        id_t         id;
        logic [31:0] addr;
        logic [7:0]  len;
        logic [2:0]  size;
        logic [1:0]  burst;
        logic        lock;
        logic [3:0]  cache;
        logic [2:0]  prot;
        logic [3:0]  qos;
        logic [3:0]  region;
        logic        user;
    } ar_chan_t;

    typedef struct packed {
        id_t         id;
        logic [31:0] data;
        logic [1:0]  resp;
        logic        last;
        logic        user;
    } r_chan_t;

    typedef struct packed {
        aw_chan_t aw;
        logic     aw_valid;
        w_chan_t  w;
        logic     w_valid;
        logic     b_ready;
        ar_chan_t ar;
        logic     ar_valid;
        logic     r_ready;
    } axi_req_t;

    typedef struct packed {
        logic     aw_ready;
        logic     ar_ready;
        logic     w_ready;
        logic     b_valid;
        b_chan_t  b;
        logic     r_valid;
        r_chan_t  r;
    } axi_resp_t;

    axi_req_t  slv_req, mst_req;
    axi_resp_t slv_resp, mst_resp;

    //------------------------------------------------------------------
    // Slave port -> request struct. The signals CVA5 does not drive take
    // their AXI defaults: non-exclusive access, no QoS, no regions, and
    // a plain read/write rather than an atomic.
    //------------------------------------------------------------------
    always_comb begin
        slv_req = '0;

        slv_req.aw.id     = s_axi_awid;
        slv_req.aw.addr   = s_axi_awaddr;
        slv_req.aw.len    = s_axi_awlen;
        slv_req.aw.size   = s_axi_awsize;
        slv_req.aw.burst  = s_axi_awburst;
        slv_req.aw.cache  = s_axi_awcache;
        slv_req.aw_valid  = s_axi_awvalid;

        slv_req.w.data    = s_axi_wdata;
        slv_req.w.strb    = s_axi_wstrb;
        slv_req.w.last    = s_axi_wlast;
        slv_req.w_valid   = s_axi_wvalid;

        slv_req.b_ready   = s_axi_bready;

        slv_req.ar.id     = s_axi_arid;
        slv_req.ar.addr   = s_axi_araddr;
        slv_req.ar.len    = s_axi_arlen;
        slv_req.ar.size   = s_axi_arsize;
        slv_req.ar.burst  = s_axi_arburst;
        slv_req.ar.cache  = s_axi_arcache;
        slv_req.ar_valid  = s_axi_arvalid;

        slv_req.r_ready   = s_axi_rready;
    end

    assign s_axi_awready = slv_resp.aw_ready;
    assign s_axi_wready  = slv_resp.w_ready;
    assign s_axi_bvalid  = slv_resp.b_valid;
    assign s_axi_bresp   = slv_resp.b.resp;
    assign s_axi_bid     = slv_resp.b.id;
    assign s_axi_arready = slv_resp.ar_ready;
    assign s_axi_rvalid  = slv_resp.r_valid;
    assign s_axi_rdata   = slv_resp.r.data;
    assign s_axi_rresp   = slv_resp.r.resp;
    assign s_axi_rlast   = slv_resp.r.last;
    assign s_axi_rid     = slv_resp.r.id;

    //------------------------------------------------------------------
    // Request struct -> master port
    //------------------------------------------------------------------
    assign m_axi_awid    = mst_req.aw.id;
    assign m_axi_awaddr  = mst_req.aw.addr;
    assign m_axi_awlen   = mst_req.aw.len;
    assign m_axi_awsize  = mst_req.aw.size;
    assign m_axi_awburst = mst_req.aw.burst;
    assign m_axi_awcache = mst_req.aw.cache;
    assign m_axi_awprot  = mst_req.aw.prot;
    assign m_axi_awlock  = mst_req.aw.lock;
    assign m_axi_awqos   = mst_req.aw.qos;
    assign m_axi_awvalid = mst_req.aw_valid;

    assign m_axi_wdata   = mst_req.w.data;
    assign m_axi_wstrb   = mst_req.w.strb;
    assign m_axi_wlast   = mst_req.w.last;
    assign m_axi_wvalid  = mst_req.w_valid;

    assign m_axi_bready  = mst_req.b_ready;

    assign m_axi_arid    = mst_req.ar.id;
    assign m_axi_araddr  = mst_req.ar.addr;
    assign m_axi_arlen   = mst_req.ar.len;
    assign m_axi_arsize  = mst_req.ar.size;
    assign m_axi_arburst = mst_req.ar.burst;
    assign m_axi_arcache = mst_req.ar.cache;
    assign m_axi_arprot  = mst_req.ar.prot;
    assign m_axi_arlock  = mst_req.ar.lock;
    assign m_axi_arqos   = mst_req.ar.qos;
    assign m_axi_arvalid = mst_req.ar_valid;

    assign m_axi_rready  = mst_req.r_ready;

    always_comb begin
        mst_resp = '0;

        mst_resp.aw_ready = m_axi_awready;
        mst_resp.w_ready  = m_axi_wready;

        mst_resp.b_valid  = m_axi_bvalid;
        mst_resp.b.id     = m_axi_bid;
        mst_resp.b.resp   = m_axi_bresp;

        mst_resp.ar_ready = m_axi_arready;

        mst_resp.r_valid  = m_axi_rvalid;
        mst_resp.r.id     = m_axi_rid;
        mst_resp.r.data   = m_axi_rdata;
        mst_resp.r.resp   = m_axi_rresp;
        mst_resp.r.last   = m_axi_rlast;
    end

    axi_cut #(
        .Bypass     (1'b0),
        .aw_chan_t  (aw_chan_t),
        .w_chan_t   (w_chan_t),
        .b_chan_t   (b_chan_t),
        .ar_chan_t  (ar_chan_t),
        .r_chan_t   (r_chan_t),
        .axi_req_t  (axi_req_t),
        .axi_resp_t (axi_resp_t)
    ) cut_inst (
        .clk_i      (clk),
        .rst_ni     (rstn),
        .slv_req_i  (slv_req),
        .slv_resp_o (slv_resp),
        .mst_req_o  (mst_req),
        .mst_resp_i (mst_resp)
    );

endmodule
