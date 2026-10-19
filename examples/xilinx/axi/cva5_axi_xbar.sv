/*
 * cva5_axi_xbar -- the SoC's peripheral interconnect.
 *
 *   S0  s_axi_cpu    CPU peripheral bus     AXI4-Lite
 *   S1  s_axi_dbg    debugger (SBA)         AXI4-Lite
 *
 *   M0  m_axi_uart   UART at PERIPH_BASE    AXI4-Lite
 *   M1  m_axi_clint  CLINT at CLINT_BASE    AXI4-Lite
 *
 * Every port is AXI4-Lite, which is the whole of what this SoC's bus carries.
 * It was not always: the crossbar used to be full AXI4 with a RAM master port,
 * because CVA5's cached master issued line-fill bursts. The caches came out,
 * main memory moved inside the core behind a local-memory interface, and the
 * only client left on the AXI4 path was the debugger -- which is AXI4-Lite and
 * does single beats. Its RAM accesses are now answered inside cva5_top rather
 * than looping out here and back, so nothing on this bus needs bursts, IDs or
 * a 4 KB-boundary-aware address incrementer.
 *
 * What that removed, all of it dead weight for Lite traffic: axi_xbar,
 * axi_demux, axi_demux_simple, axi_mux, axi_multicut, axi_lite_to_axi,
 * axi_id_prepend, axi_err_slv, and ZipCPU's axi2axilite with its sfifo,
 * skidbuffer and axi_addr. The decode is one axi_lite_xbar.
 *
 * The address map is a parameter here rather than something the Vivado address
 * editor decides, so examples/sw/soc.h is the single source of truth for the
 * decode. An address no rule claims gets a DECERR from the Lite crossbar's own
 * error slave, rather than landing somewhere unexpected or hanging.
 *
 * Adding a peripheral -- the timer at 0x1800_0000, the SPI at 0x2000_0000, the
 * PLIC at 0x0C00_0000 -- is a rule, a port and a line in the block design.
 *
 * Copyright © 2024 Chris Keilbart
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_axi_xbar #(
    // Address map. Defaults match examples/sw/soc.h; each base must be
    // aligned to its size.
    parameter logic [31:0] PERIPH_BASE = 32'h1000_0000,
    parameter logic [31:0] PERIPH_SIZE = 32'h0001_0000,  // 64 KB, the UART
    parameter logic [31:0] CLINT_BASE  = 32'h0200_0000,
    parameter logic [31:0] CLINT_SIZE  = 32'h0001_0000,  // 64 KB

    // Width of each master port's address bus.
    //
    // Leave these at 32. A MASTER port's address width is the size of the
    // address space Vivado believes that port can reach, and a port that
    // cannot emit 0x1000_0000 cannot have a slave placed there -- the address
    // editor refuses the offset with BD 41-70 and reports the only valid
    // aperture as <0x0000_0000 [ 4K ]>.
    //
    // This is the opposite of the rule for a SLAVE port, where the width sizes
    // the address BLOCK the slave offers and must be narrow: cva5_uart's own
    // s_axi is 12 bits so that it offers 4 KB rather than 4 GB, and
    // cva5_clint_axi's is 16 bits for its 64 KB. Narrow slaves, wide masters.
    //
    // The parameters exist so run_xbar.sh can sweep the truncation path, not
    // because the block design should narrow them.
    parameter int unsigned M_UART_ADDR_WIDTH  = 32,
    parameter int unsigned M_CLINT_ADDR_WIDTH = 32,

    // Outstanding transactions allowed per port. Two: every master here issues
    // single register accesses and none of them pipeline.
    parameter int unsigned MAX_TRANS = 32'd2
    ) (
        input logic clk,
        input logic rstn, //Synchronous active low

        //----------------------------------------------------------------
        // S0: CPU peripheral bus (AXI4-Lite)
        //----------------------------------------------------------------
        input logic [31:0] s_axi_cpu_awaddr,
        input logic [2:0] s_axi_cpu_awprot,
        input logic s_axi_cpu_awvalid,
        output logic s_axi_cpu_awready,
        input logic [31:0] s_axi_cpu_wdata,
        input logic [3:0] s_axi_cpu_wstrb,
        input logic s_axi_cpu_wvalid,
        output logic s_axi_cpu_wready,
        output logic [1:0] s_axi_cpu_bresp,
        output logic s_axi_cpu_bvalid,
        input logic s_axi_cpu_bready,
        input logic [31:0] s_axi_cpu_araddr,
        input logic [2:0] s_axi_cpu_arprot,
        input logic s_axi_cpu_arvalid,
        output logic s_axi_cpu_arready,
        output logic [31:0] s_axi_cpu_rdata,
        output logic [1:0] s_axi_cpu_rresp,
        output logic s_axi_cpu_rvalid,
        input logic s_axi_cpu_rready,

        //----------------------------------------------------------------
        // S1: debugger System Bus Access (AXI4-Lite)
        //----------------------------------------------------------------
        input logic [31:0] s_axi_dbg_awaddr,
        input logic [2:0] s_axi_dbg_awprot,
        input logic s_axi_dbg_awvalid,
        output logic s_axi_dbg_awready,
        input logic [31:0] s_axi_dbg_wdata,
        input logic [3:0] s_axi_dbg_wstrb,
        input logic s_axi_dbg_wvalid,
        output logic s_axi_dbg_wready,
        output logic [1:0] s_axi_dbg_bresp,
        output logic s_axi_dbg_bvalid,
        input logic s_axi_dbg_bready,
        input logic [31:0] s_axi_dbg_araddr,
        input logic [2:0] s_axi_dbg_arprot,
        input logic s_axi_dbg_arvalid,
        output logic s_axi_dbg_arready,
        output logic [31:0] s_axi_dbg_rdata,
        output logic [1:0] s_axi_dbg_rresp,
        output logic s_axi_dbg_rvalid,
        input logic s_axi_dbg_rready,

        //----------------------------------------------------------------
        // M0: UART (AXI4-Lite)
        //----------------------------------------------------------------
        output logic [M_UART_ADDR_WIDTH-1:0] m_axi_uart_awaddr,
        output logic [2:0] m_axi_uart_awprot,
        output logic m_axi_uart_awvalid,
        input logic m_axi_uart_awready,
        output logic [31:0] m_axi_uart_wdata,
        output logic [3:0] m_axi_uart_wstrb,
        output logic m_axi_uart_wvalid,
        input logic m_axi_uart_wready,
        input logic [1:0] m_axi_uart_bresp,
        input logic m_axi_uart_bvalid,
        output logic m_axi_uart_bready,
        output logic [M_UART_ADDR_WIDTH-1:0] m_axi_uart_araddr,
        output logic [2:0] m_axi_uart_arprot,
        output logic m_axi_uart_arvalid,
        input logic m_axi_uart_arready,
        input logic [31:0] m_axi_uart_rdata,
        input logic [1:0] m_axi_uart_rresp,
        input logic m_axi_uart_rvalid,
        output logic m_axi_uart_rready,

        //----------------------------------------------------------------
        // M1: CLINT (AXI4-Lite)
        //----------------------------------------------------------------
        output logic [M_CLINT_ADDR_WIDTH-1:0] m_axi_clint_awaddr,
        output logic [2:0] m_axi_clint_awprot,
        output logic m_axi_clint_awvalid,
        input logic m_axi_clint_awready,
        output logic [31:0] m_axi_clint_wdata,
        output logic [3:0] m_axi_clint_wstrb,
        output logic m_axi_clint_wvalid,
        input logic m_axi_clint_wready,
        input logic [1:0] m_axi_clint_bresp,
        input logic m_axi_clint_bvalid,
        output logic m_axi_clint_bready,
        output logic [M_CLINT_ADDR_WIDTH-1:0] m_axi_clint_araddr,
        output logic [2:0] m_axi_clint_arprot,
        output logic m_axi_clint_arvalid,
        input logic m_axi_clint_arready,
        input logic [31:0] m_axi_clint_rdata,
        input logic [1:0] m_axi_clint_rresp,
        input logic m_axi_clint_rvalid,
        output logic m_axi_clint_rready
    );

    localparam int unsigned NUM_SLV = 32'd2;
    localparam int unsigned NUM_MST = 32'd2;

    //------------------------------------------------------------------
    // AXI4-Lite channel and request/response types. Field order and names
    // match axi/typedef.svh, which is what axi_lite_xbar expects.
    //------------------------------------------------------------------
    typedef logic [31:0] addr_t;
    typedef logic [31:0] data_t;
    typedef logic [3:0]  strb_t;

    typedef struct packed {
        addr_t          addr;
        axi_pkg::prot_t prot;
    } lite_aw_chan_t;

    typedef struct packed {
        data_t data;
        strb_t strb;
    } lite_w_chan_t;

    typedef struct packed {
        axi_pkg::resp_t resp;
    } lite_b_chan_t;

    typedef struct packed {
        addr_t          addr;
        axi_pkg::prot_t prot;
    } lite_ar_chan_t;

    typedef struct packed {
        data_t          data;
        axi_pkg::resp_t resp;
    } lite_r_chan_t;

    typedef struct packed {
        lite_aw_chan_t aw;
        logic          aw_valid;
        lite_w_chan_t  w;
        logic          w_valid;
        logic          b_ready;
        lite_ar_chan_t ar;
        logic          ar_valid;
        logic          r_ready;
    } lite_req_t;

    typedef struct packed {
        logic         aw_ready;
        logic         w_ready;
        lite_b_chan_t b;
        logic         b_valid;
        logic         ar_ready;
        lite_r_chan_t r;
        logic         r_valid;
    } lite_resp_t;

    lite_req_t  [NUM_SLV-1:0] slv_req;
    lite_resp_t [NUM_SLV-1:0] slv_resp;
    lite_req_t  [NUM_MST-1:0] mst_req;
    lite_resp_t [NUM_MST-1:0] mst_resp;

    //------------------------------------------------------------------
    // Configuration
    //
    // AXI4-Lite carries no IDs, so the ID widths here are the minimum the
    // configuration struct accepts rather than anything meaningful.
    //
    // LatencyMode cuts the address channels on the demultiplexer side only.
    // That is where the long combinational run is -- address decode into the
    // arbiter -- and it registers fewer points than CUT_ALL_AX, which matters:
    // this crossbar shares the die with CVA5, and the flops it spends show up
    // as congestion on the core's fetch path, not as a timing problem inside
    // the fabric. axi_pkg::CUT_ALL_AX and then CUT_ALL_PORTS are the steps
    // back up if the critical path ever moves in here.
    //------------------------------------------------------------------
    localparam axi_pkg::xbar_cfg_t XbarCfg = '{
        NoSlvPorts:         32'(NUM_SLV),
        NoMstPorts:         32'(NUM_MST),
        MaxMstTrans:        32'(MAX_TRANS),
        MaxSlvTrans:        32'(MAX_TRANS),
        FallThrough:        1'b0,
        LatencyMode:        axi_pkg::CUT_SLV_AX,
        PipelineStages:     32'd0,
        AxiIdWidthSlvPorts: 32'd1,
        AxiIdUsedSlvPorts:  32'd1,
        UniqueIds:          1'b0,
        AxiAddrWidth:       32'd32,
        AxiDataWidth:       32'd32,
        NoAddrRules:        32'(NUM_MST)
    };

    axi_pkg::xbar_rule_32_t [NUM_MST-1:0] addr_map;
    always_comb begin
        addr_map[0] = '{idx: 32'd0,
                        start_addr: PERIPH_BASE,
                        end_addr:   PERIPH_BASE + PERIPH_SIZE};
        addr_map[1] = '{idx: 32'd1,
                        start_addr: CLINT_BASE,
                        end_addr:   CLINT_BASE + CLINT_SIZE};
    end

    //------------------------------------------------------------------
    // S0: CPU peripheral bus
    //------------------------------------------------------------------
    always_comb begin
        slv_req[0] = '0;
        slv_req[0].aw.addr  = s_axi_cpu_awaddr;
        slv_req[0].aw.prot  = s_axi_cpu_awprot;
        slv_req[0].aw_valid = s_axi_cpu_awvalid;
        slv_req[0].w.data   = s_axi_cpu_wdata;
        slv_req[0].w.strb   = s_axi_cpu_wstrb;
        slv_req[0].w_valid  = s_axi_cpu_wvalid;
        slv_req[0].b_ready  = s_axi_cpu_bready;
        slv_req[0].ar.addr  = s_axi_cpu_araddr;
        slv_req[0].ar.prot  = s_axi_cpu_arprot;
        slv_req[0].ar_valid = s_axi_cpu_arvalid;
        slv_req[0].r_ready  = s_axi_cpu_rready;
    end

    assign s_axi_cpu_awready = slv_resp[0].aw_ready;
    assign s_axi_cpu_wready  = slv_resp[0].w_ready;
    assign s_axi_cpu_bresp   = slv_resp[0].b.resp;
    assign s_axi_cpu_bvalid  = slv_resp[0].b_valid;
    assign s_axi_cpu_arready = slv_resp[0].ar_ready;
    assign s_axi_cpu_rdata   = slv_resp[0].r.data;
    assign s_axi_cpu_rresp   = slv_resp[0].r.resp;
    assign s_axi_cpu_rvalid  = slv_resp[0].r_valid;

    //------------------------------------------------------------------
    // S1: debugger System Bus Access
    //------------------------------------------------------------------
    always_comb begin
        slv_req[1] = '0;
        slv_req[1].aw.addr  = s_axi_dbg_awaddr;
        slv_req[1].aw.prot  = s_axi_dbg_awprot;
        slv_req[1].aw_valid = s_axi_dbg_awvalid;
        slv_req[1].w.data   = s_axi_dbg_wdata;
        slv_req[1].w.strb   = s_axi_dbg_wstrb;
        slv_req[1].w_valid  = s_axi_dbg_wvalid;
        slv_req[1].b_ready  = s_axi_dbg_bready;
        slv_req[1].ar.addr  = s_axi_dbg_araddr;
        slv_req[1].ar.prot  = s_axi_dbg_arprot;
        slv_req[1].ar_valid = s_axi_dbg_arvalid;
        slv_req[1].r_ready  = s_axi_dbg_rready;
    end

    assign s_axi_dbg_awready = slv_resp[1].aw_ready;
    assign s_axi_dbg_wready  = slv_resp[1].w_ready;
    assign s_axi_dbg_bresp   = slv_resp[1].b.resp;
    assign s_axi_dbg_bvalid  = slv_resp[1].b_valid;
    assign s_axi_dbg_arready = slv_resp[1].ar_ready;
    assign s_axi_dbg_rdata   = slv_resp[1].r.data;
    assign s_axi_dbg_rresp   = slv_resp[1].r.resp;
    assign s_axi_dbg_rvalid  = slv_resp[1].r_valid;

    //------------------------------------------------------------------
    // The crossbar
    //------------------------------------------------------------------
    axi_lite_xbar #(
        .Cfg (XbarCfg),
        .aw_chan_t (lite_aw_chan_t),
        .w_chan_t (lite_w_chan_t),
        .b_chan_t (lite_b_chan_t),
        .ar_chan_t (lite_ar_chan_t),
        .r_chan_t (lite_r_chan_t),
        .axi_req_t (lite_req_t),
        .axi_resp_t (lite_resp_t),
        .rule_t (axi_pkg::xbar_rule_32_t)
    ) xbar_inst (
        .clk_i (clk),
        .rst_ni (rstn),
        .test_i (1'b0),
        .slv_ports_req_i (slv_req),
        .slv_ports_resp_o (slv_resp),
        .mst_ports_req_o (mst_req),
        .mst_ports_resp_i (mst_resp),
        .addr_map_i (addr_map),
        .en_default_mst_port_i ('0),
        .default_mst_port_i ('0)
    );

    //------------------------------------------------------------------
    // M0: UART
    //------------------------------------------------------------------
    assign m_axi_uart_awaddr  = mst_req[0].aw.addr[M_UART_ADDR_WIDTH-1:0];
    assign m_axi_uart_awprot  = mst_req[0].aw.prot;
    assign m_axi_uart_awvalid = mst_req[0].aw_valid;
    assign m_axi_uart_wdata   = mst_req[0].w.data;
    assign m_axi_uart_wstrb   = mst_req[0].w.strb;
    assign m_axi_uart_wvalid  = mst_req[0].w_valid;
    assign m_axi_uart_bready  = mst_req[0].b_ready;
    assign m_axi_uart_araddr  = mst_req[0].ar.addr[M_UART_ADDR_WIDTH-1:0];
    assign m_axi_uart_arprot  = mst_req[0].ar.prot;
    assign m_axi_uart_arvalid = mst_req[0].ar_valid;
    assign m_axi_uart_rready  = mst_req[0].r_ready;

    always_comb begin
        mst_resp[0] = '0;
        mst_resp[0].aw_ready = m_axi_uart_awready;
        mst_resp[0].w_ready  = m_axi_uart_wready;
        mst_resp[0].b.resp   = m_axi_uart_bresp;
        mst_resp[0].b_valid  = m_axi_uart_bvalid;
        mst_resp[0].ar_ready = m_axi_uart_arready;
        mst_resp[0].r.data   = m_axi_uart_rdata;
        mst_resp[0].r.resp   = m_axi_uart_rresp;
        mst_resp[0].r_valid  = m_axi_uart_rvalid;
    end

    //------------------------------------------------------------------
    // M1: CLINT
    //------------------------------------------------------------------
    assign m_axi_clint_awaddr  = mst_req[1].aw.addr[M_CLINT_ADDR_WIDTH-1:0];
    assign m_axi_clint_awprot  = mst_req[1].aw.prot;
    assign m_axi_clint_awvalid = mst_req[1].aw_valid;
    assign m_axi_clint_wdata   = mst_req[1].w.data;
    assign m_axi_clint_wstrb   = mst_req[1].w.strb;
    assign m_axi_clint_wvalid  = mst_req[1].w_valid;
    assign m_axi_clint_bready  = mst_req[1].b_ready;
    assign m_axi_clint_araddr  = mst_req[1].ar.addr[M_CLINT_ADDR_WIDTH-1:0];
    assign m_axi_clint_arprot  = mst_req[1].ar.prot;
    assign m_axi_clint_arvalid = mst_req[1].ar_valid;
    assign m_axi_clint_rready  = mst_req[1].r_ready;

    always_comb begin
        mst_resp[1] = '0;
        mst_resp[1].aw_ready = m_axi_clint_awready;
        mst_resp[1].w_ready  = m_axi_clint_wready;
        mst_resp[1].b.resp   = m_axi_clint_bresp;
        mst_resp[1].b_valid  = m_axi_clint_bvalid;
        mst_resp[1].ar_ready = m_axi_clint_arready;
        mst_resp[1].r.data   = m_axi_clint_rdata;
        mst_resp[1].r.resp   = m_axi_clint_rresp;
        mst_resp[1].r_valid  = m_axi_clint_rvalid;
    end

endmodule
