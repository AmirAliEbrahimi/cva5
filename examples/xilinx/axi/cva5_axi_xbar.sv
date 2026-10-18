/*
 * cva5_axi_xbar -- the CVA5 SoC's AXI crossbar.
 *
 * Replaces the Xilinx AXI Interconnect. The body is pulp-platform's axi_xbar,
 * which is a fully-connected crossbar with a per-master address decoder.
 *
 * Three masters, two slaves:
 *
 *   S0  s_axi_cpu      CPU peripheral bus     AXI4-Lite  -> peripherals only
 *   S1  s_axi_mem      CPU cached memory      AXI4, 6-bit IDs, bursts -> RAM only
 *   S2  s_axi_dbg      debugger (SBA)         AXI4-Lite  -> both
 *
 *   M0  m_axi_ram      main RAM at RAM_BASE        AXI4, 8-bit IDs
 *   M1  everything below RAM, converted once to AXI4-Lite and then fanned
 *       out by an internal Lite crossbar:
 *         m_axi_uart   UART at PERIPH_BASE         AXI4-Lite
 *         m_axi_clint  CLINT at CLINT_BASE         AXI4-Lite
 *
 * The address map is a parameter here rather than something the Vivado address
 * editor decides, so examples/sw/soc.h is the single source of truth for the
 * decode. Anything outside the windows, or a master reaching for a slave
 * it is not connected to, comes back as a DECERR rather than being silently
 * misrouted: axi_xbar instantiates an axi_err_slv on every unconnected pair.
 *
 * Connectivity is restricted on purpose. The cached path only ever issues
 * addresses in CVA5's cache range and the peripheral bus only decodes its own
 * window, so wiring each to one slave costs nothing and turns a stray access
 * into a bus error instead of a confusing peripheral write.
 *
 * The master ports carry the full 32-bit address by default, and each slave
 * takes the low bits of it at the block-design connection -- which is what
 * the Xilinx interconnect did into the UART's 4-bit port. Narrowing a master
 * port here is possible (M_*_ADDR_WIDTH) but rarely wanted: the width also
 * caps the window that port's address space can describe, so a 17-bit port
 * cannot hold a 128 KB segment in Vivado's address editor.
 *
 * Reset: pulp's cells reset asynchronously and ZipCPU's synchronously, and
 * here they share one net. That is safe because the net is proc_sys_reset's
 * peripheral_aresetn, already synchronised to this clock and released
 * synchronously, so both kinds of flop leave reset on the same edge.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_axi_xbar #(
    // Address map. Defaults match examples/sw/soc.h; each base must be
    // aligned to its size.
    parameter logic [31:0] RAM_BASE    = 32'h8000_0000,
    parameter logic [31:0] RAM_SIZE    = 32'h0002_0000,  // 128 KB
    parameter logic [31:0] PERIPH_BASE = 32'h1000_0000,
    parameter logic [31:0] PERIPH_SIZE = 32'h0001_0000,  // 64 KB, the UART
    parameter logic [31:0] CLINT_BASE  = 32'h0200_0000,
    parameter logic [31:0] CLINT_SIZE  = 32'h0001_0000,  // 64 KB

    // Width of each AXI4-Lite peripheral port's address bus.
    //
    // Leave these at 32. A MASTER port's address width is the size of the
    // address space Vivado believes that port can reach, and a port that
    // cannot emit 0x1000_0000 cannot have a slave placed there -- the address
    // editor refuses the offset with BD 41-70 and reports the only valid
    // aperture as <0x0000_0000 [ 4K ]>. M_RAM_ADDR_WIDTH is 32 for the same
    // reason.
    //
    // This is the opposite of the rule for a SLAVE port, where the width sizes
    // the address BLOCK the slave offers and must be narrow: cva5_uart's own
    // s_axi is 12 bits so that it offers 4 KB rather than 4 GB, and
    // cva5_top's s_axi_clint is 16 bits for its 64 KB. Narrow slaves, wide
    // masters. Connecting a 32-bit master to a narrower slave is what
    // m_axi_ram already does.
    //
    // The parameters exist so run_xbar.sh can sweep the truncation path, not
    // because the block design should narrow them.
    parameter int unsigned M_UART_ADDR_WIDTH  = 32,
    parameter int unsigned M_CLINT_ADDR_WIDTH = 32,

    // Width of each master port's address bus. Leave at 32 unless a slave
    // genuinely needs a narrow port: Vivado truncates a wide master into a
    // narrow slave on its own, and narrowing here also caps the address range
    // the block design can assign behind that port.
    parameter int unsigned M_RAM_ADDR_WIDTH    = 32,
    parameter int unsigned M_PERIPH_ADDR_WIDTH = 32,

    // Transaction ID width on the slave ports. CVA5's cached master uses 6.
    parameter int unsigned ID_WIDTH = 32'd6,

    // The crossbar's multiplexer prefixes each slave port's ID with the port
    // index, so the master side is wider by $clog2(3) = 2 bits. Not meant to
    // be overridden; it is here so the master ports can use it.
    parameter int unsigned MST_ID_WIDTH = ID_WIDTH + 2,

    // How many of those ID bits the crossbar tracks per slave port. Fewer bits
    // means two IDs can alias onto one counter, which only ever over-constrains
    // ordering, never breaks it, and costs far less area: the demultiplexer
    // builds 2**this many counters per slave port. One bit is enough here --
    // the lite masters all use ID zero, and the cached master issues one line
    // fill at a time.
    parameter int unsigned ID_BITS_USED = 32'd1,

    // Outstanding transactions allowed per port. Two: the peripheral window is
    // single register accesses and the cached path does not pipeline fills.
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
        // S1: CPU cached memory (AXI4)
        //----------------------------------------------------------------
        output logic s_axi_mem_arready,
        input logic s_axi_mem_arvalid,
        input logic [31:0] s_axi_mem_araddr,
        input logic [7:0] s_axi_mem_arlen,
        input logic [2:0] s_axi_mem_arsize,
        input logic [1:0] s_axi_mem_arburst,
        input logic [3:0] s_axi_mem_arcache,
        input logic [2:0] s_axi_mem_arprot,
        input logic s_axi_mem_arlock,
        input logic [3:0] s_axi_mem_arqos,
        input logic [ID_WIDTH-1:0] s_axi_mem_arid,

        input logic s_axi_mem_rready,
        output logic s_axi_mem_rvalid,
        output logic [31:0] s_axi_mem_rdata,
        output logic [1:0] s_axi_mem_rresp,
        output logic s_axi_mem_rlast,
        output logic [ID_WIDTH-1:0] s_axi_mem_rid,

        output logic s_axi_mem_awready,
        input logic s_axi_mem_awvalid,
        input logic [31:0] s_axi_mem_awaddr,
        input logic [7:0] s_axi_mem_awlen,
        input logic [2:0] s_axi_mem_awsize,
        input logic [1:0] s_axi_mem_awburst,
        input logic [3:0] s_axi_mem_awcache,
        input logic [2:0] s_axi_mem_awprot,
        input logic s_axi_mem_awlock,
        input logic [3:0] s_axi_mem_awqos,
        input logic [ID_WIDTH-1:0] s_axi_mem_awid,

        output logic s_axi_mem_wready,
        input logic s_axi_mem_wvalid,
        input logic [31:0] s_axi_mem_wdata,
        input logic [3:0] s_axi_mem_wstrb,
        input logic s_axi_mem_wlast,

        input logic s_axi_mem_bready,
        output logic s_axi_mem_bvalid,
        output logic [1:0] s_axi_mem_bresp,
        output logic [ID_WIDTH-1:0] s_axi_mem_bid,

        //----------------------------------------------------------------
        // S2: debugger System Bus Access (AXI4-Lite)
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
        // M0: main RAM (AXI4)
        //----------------------------------------------------------------
        input logic m_axi_ram_arready,
        output logic m_axi_ram_arvalid,
        output logic [M_RAM_ADDR_WIDTH-1:0] m_axi_ram_araddr,
        output logic [7:0] m_axi_ram_arlen,
        output logic [2:0] m_axi_ram_arsize,
        output logic [1:0] m_axi_ram_arburst,
        output logic [3:0] m_axi_ram_arcache,
        output logic [2:0] m_axi_ram_arprot,
        output logic m_axi_ram_arlock,
        output logic [3:0] m_axi_ram_arqos,
        output logic [MST_ID_WIDTH-1:0] m_axi_ram_arid,

        output logic m_axi_ram_rready,
        input logic m_axi_ram_rvalid,
        input logic [31:0] m_axi_ram_rdata,
        input logic [1:0] m_axi_ram_rresp,
        input logic m_axi_ram_rlast,
        input logic [MST_ID_WIDTH-1:0] m_axi_ram_rid,

        input logic m_axi_ram_awready,
        output logic m_axi_ram_awvalid,
        output logic [M_RAM_ADDR_WIDTH-1:0] m_axi_ram_awaddr,
        output logic [7:0] m_axi_ram_awlen,
        output logic [2:0] m_axi_ram_awsize,
        output logic [1:0] m_axi_ram_awburst,
        output logic [3:0] m_axi_ram_awcache,
        output logic [2:0] m_axi_ram_awprot,
        output logic m_axi_ram_awlock,
        output logic [3:0] m_axi_ram_awqos,
        output logic [MST_ID_WIDTH-1:0] m_axi_ram_awid,

        input logic m_axi_ram_wready,
        output logic m_axi_ram_wvalid,
        output logic [31:0] m_axi_ram_wdata,
        output logic [3:0] m_axi_ram_wstrb,
        output logic m_axi_ram_wlast,

        output logic m_axi_ram_bready,
        input logic m_axi_ram_bvalid,
        input logic [1:0] m_axi_ram_bresp,
        input logic [MST_ID_WIDTH-1:0] m_axi_ram_bid,

        //----------------------------------------------------------------
        // M1: the peripheral window, fanned out by an AXI4-Lite crossbar
        //
        // One AXI4-to-Lite conversion feeds a Lite crossbar that decodes to
        // these ports. Giving each peripheral its own AXI4 master port on the
        // main crossbar would mean one axi2axilite per peripheral and a wider
        // axi_demux arbitration; the Lite stage costs one decode and a mux leg
        // per peripheral instead, which is what makes room for the timer, the
        // SPI and the PLIC without touching this crossbar again.
        //----------------------------------------------------------------
        // M1.0: UART (AXI4-Lite)
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
        // M1.1: CLINT (AXI4-Lite)
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

    localparam int unsigned NUM_SLV = 32'd3;
    localparam int unsigned NUM_MST = 32'd2;

    //------------------------------------------------------------------
    // Channel and request/response types, slave side (ID_WIDTH) and master
    // side (MST_ID_WIDTH). Field order and names match axi/typedef.svh,
    // which is what axi_xbar's internals expect. Written out in full rather
    // than generated by a macro: a `define inside a module is still global
    // preprocessor state, and this file is packaged as Vivado IP alongside
    // others.
    //------------------------------------------------------------------
    typedef logic [31:0] addr_t;
    typedef logic [31:0] data_t;
    typedef logic [3:0]  strb_t;
    typedef logic        user_t;

    typedef struct packed {
        logic [ID_WIDTH-1:0] id;
        addr_t               addr;
        axi_pkg::len_t       len;
        axi_pkg::size_t      size;
        axi_pkg::burst_t     burst;
        logic                lock;
        axi_pkg::cache_t     cache;
        axi_pkg::prot_t      prot;
        axi_pkg::qos_t       qos;
        axi_pkg::region_t    region;
        axi_pkg::atop_t      atop;
        user_t               user;
    } slv_aw_chan_t;

    typedef struct packed {
        logic [MST_ID_WIDTH-1:0] id;
        addr_t                   addr;
        axi_pkg::len_t           len;
        axi_pkg::size_t          size;
        axi_pkg::burst_t         burst;
        logic                    lock;
        axi_pkg::cache_t         cache;
        axi_pkg::prot_t          prot;
        axi_pkg::qos_t           qos;
        axi_pkg::region_t        region;
        axi_pkg::atop_t          atop;
        user_t                   user;
    } mst_aw_chan_t;

    typedef struct packed {
        logic [ID_WIDTH-1:0] id;
        addr_t               addr;
        axi_pkg::len_t       len;
        axi_pkg::size_t      size;
        axi_pkg::burst_t     burst;
        logic                lock;
        axi_pkg::cache_t     cache;
        axi_pkg::prot_t      prot;
        axi_pkg::qos_t       qos;
        axi_pkg::region_t    region;
        user_t               user;
    } slv_ar_chan_t;

    typedef struct packed {
        logic [MST_ID_WIDTH-1:0] id;
        addr_t                   addr;
        axi_pkg::len_t           len;
        axi_pkg::size_t          size;
        axi_pkg::burst_t         burst;
        logic                    lock;
        axi_pkg::cache_t         cache;
        axi_pkg::prot_t          prot;
        axi_pkg::qos_t           qos;
        axi_pkg::region_t        region;
        user_t                   user;
    } mst_ar_chan_t;

    typedef struct packed {
        logic [ID_WIDTH-1:0] id;
        axi_pkg::resp_t      resp;
        user_t               user;
    } slv_b_chan_t;

    typedef struct packed {
        logic [MST_ID_WIDTH-1:0] id;
        axi_pkg::resp_t          resp;
        user_t                   user;
    } mst_b_chan_t;

    typedef struct packed {
        logic [ID_WIDTH-1:0] id;
        data_t               data;
        axi_pkg::resp_t      resp;
        logic                last;
        user_t               user;
    } slv_r_chan_t;

    typedef struct packed {
        logic [MST_ID_WIDTH-1:0] id;
        data_t                   data;
        axi_pkg::resp_t          resp;
        logic                    last;
        user_t                   user;
    } mst_r_chan_t;

    typedef struct packed {
        data_t data;
        strb_t strb;
        logic  last;
        user_t user;
    } w_chan_t;

    typedef struct packed {
        slv_aw_chan_t aw;
        logic         aw_valid;
        w_chan_t      w;
        logic         w_valid;
        logic         b_ready;
        slv_ar_chan_t ar;
        logic         ar_valid;
        logic         r_ready;
    } slv_req_t;

    typedef struct packed {
        logic        aw_ready;
        logic        ar_ready;
        logic        w_ready;
        logic        b_valid;
        slv_b_chan_t b;
        logic        r_valid;
        slv_r_chan_t r;
    } slv_resp_t;

    typedef struct packed {
        mst_aw_chan_t aw;
        logic         aw_valid;
        w_chan_t      w;
        logic         w_valid;
        logic         b_ready;
        mst_ar_chan_t ar;
        logic         ar_valid;
        logic         r_ready;
    } mst_req_t;

    typedef struct packed {
        logic        aw_ready;
        logic        ar_ready;
        logic        w_ready;
        logic        b_valid;
        mst_b_chan_t b;
        logic        r_valid;
        mst_r_chan_t r;
    } mst_resp_t;

    // AXI4-Lite channel structs, for the two lite slave ports and the lite
    // master port.
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

    //------------------------------------------------------------------
    // Crossbar configuration
    //------------------------------------------------------------------
    // LatencyMode cuts the address channels on the demultiplexer side only.
    // That is where the long combinational run is -- address decode into the
    // arbiter -- and it registers 3 ports rather than the 3x2 crossings
    // CUT_ALL_AX registers, which matters: this crossbar shares the die with
    // CVA5, and the flops it spends show up as congestion on the core's
    // fetch-to-predictor path, not as a timing problem inside the fabric.
    // axi_pkg::CUT_ALL_AX and then CUT_ALL_PORTS are the steps back up if the
    // critical path ever moves in here.
    localparam axi_pkg::xbar_cfg_t XbarCfg = '{
        NoSlvPorts:         32'(NUM_SLV),
        NoMstPorts:         32'(NUM_MST),
        MaxMstTrans:        32'(MAX_TRANS),
        MaxSlvTrans:        32'(MAX_TRANS),
        FallThrough:        1'b0,
        LatencyMode:        axi_pkg::CUT_SLV_AX,
        PipelineStages:     32'd0,
        AxiIdWidthSlvPorts: 32'(ID_WIDTH),
        AxiIdUsedSlvPorts:  32'(ID_BITS_USED),
        UniqueIds:          1'b0,
        AxiAddrWidth:       32'd32,
        AxiDataWidth:       32'd32,
        NoAddrRules:        32'd2
    };

    // Master port 0 is the RAM, master port 1 the peripheral window.
    //   S0 (CPU peripherals) -> peripherals only
    //   S1 (cached memory)   -> RAM only
    //   S2 (debugger)        -> both
    // Bit j of entry i is slave port i's access to master port j.
    localparam bit [NUM_SLV-1:0][NUM_MST-1:0] XbarConnectivity = {
        2'b11,  // S2 debugger
        2'b01,  // S1 cached memory
        2'b10   // S0 CPU peripherals
    };

    axi_pkg::xbar_rule_32_t [1:0] addr_map;
    always_comb begin
        addr_map[0] = '{idx: 32'd0,
                        start_addr: RAM_BASE,
                        end_addr:   RAM_BASE + RAM_SIZE};
        //Everything below RAM reaches the Lite stage, which does the fine
        //decode and answers an unclaimed address with a DECERR of its own.
        //A narrow rule here would need widening for every peripheral added.
        addr_map[1] = '{idx: 32'd1,
                        start_addr: 32'h0000_0000,
                        end_addr:   RAM_BASE};
    end

    slv_req_t  [NUM_SLV-1:0] slv_req;
    slv_resp_t [NUM_SLV-1:0] slv_resp;
    mst_req_t  [NUM_MST-1:0] mst_req;
    mst_resp_t [NUM_MST-1:0] mst_resp;

    //------------------------------------------------------------------
    // S0: CPU peripheral bus, AXI4-Lite widened to AXI4
    //------------------------------------------------------------------
    lite_req_t  cpu_lite_req;
    lite_resp_t cpu_lite_resp;

    always_comb begin
        cpu_lite_req = '0;
        cpu_lite_req.aw.addr  = s_axi_cpu_awaddr;
        cpu_lite_req.aw.prot  = s_axi_cpu_awprot;
        cpu_lite_req.aw_valid = s_axi_cpu_awvalid;
        cpu_lite_req.w.data   = s_axi_cpu_wdata;
        cpu_lite_req.w.strb   = s_axi_cpu_wstrb;
        cpu_lite_req.w_valid  = s_axi_cpu_wvalid;
        cpu_lite_req.b_ready  = s_axi_cpu_bready;
        cpu_lite_req.ar.addr  = s_axi_cpu_araddr;
        cpu_lite_req.ar.prot  = s_axi_cpu_arprot;
        cpu_lite_req.ar_valid = s_axi_cpu_arvalid;
        cpu_lite_req.r_ready  = s_axi_cpu_rready;
    end

    assign s_axi_cpu_awready = cpu_lite_resp.aw_ready;
    assign s_axi_cpu_wready  = cpu_lite_resp.w_ready;
    assign s_axi_cpu_bresp   = cpu_lite_resp.b.resp;
    assign s_axi_cpu_bvalid  = cpu_lite_resp.b_valid;
    assign s_axi_cpu_arready = cpu_lite_resp.ar_ready;
    assign s_axi_cpu_rdata   = cpu_lite_resp.r.data;
    assign s_axi_cpu_rresp   = cpu_lite_resp.r.resp;
    assign s_axi_cpu_rvalid  = cpu_lite_resp.r_valid;

    axi_lite_to_axi #(
        .AxiDataWidth (32),
        .req_lite_t   (lite_req_t),
        .resp_lite_t  (lite_resp_t),
        .axi_req_t    (slv_req_t),
        .axi_resp_t   (slv_resp_t)
    ) cpu_lite_to_axi (
        .slv_req_lite_i  (cpu_lite_req),
        .slv_resp_lite_o (cpu_lite_resp),
        .slv_aw_cache_i  (4'b0011),  // modifiable, bufferable
        .slv_ar_cache_i  (4'b0011),
        .mst_req_o       (slv_req[0]),
        .mst_resp_i      (slv_resp[0])
    );

    //------------------------------------------------------------------
    // S1: CPU cached memory, already AXI4
    //------------------------------------------------------------------
    always_comb begin
        slv_req[1] = '0;

        slv_req[1].aw.id     = s_axi_mem_awid;
        slv_req[1].aw.addr   = s_axi_mem_awaddr;
        slv_req[1].aw.len    = s_axi_mem_awlen;
        slv_req[1].aw.size   = s_axi_mem_awsize;
        slv_req[1].aw.burst  = s_axi_mem_awburst;
        slv_req[1].aw.lock   = s_axi_mem_awlock;
        slv_req[1].aw.cache  = s_axi_mem_awcache;
        slv_req[1].aw.prot   = s_axi_mem_awprot;
        slv_req[1].aw.qos    = s_axi_mem_awqos;
        slv_req[1].aw_valid  = s_axi_mem_awvalid;

        slv_req[1].w.data    = s_axi_mem_wdata;
        slv_req[1].w.strb    = s_axi_mem_wstrb;
        slv_req[1].w.last    = s_axi_mem_wlast;
        slv_req[1].w_valid   = s_axi_mem_wvalid;

        slv_req[1].b_ready   = s_axi_mem_bready;

        slv_req[1].ar.id     = s_axi_mem_arid;
        slv_req[1].ar.addr   = s_axi_mem_araddr;
        slv_req[1].ar.len    = s_axi_mem_arlen;
        slv_req[1].ar.size   = s_axi_mem_arsize;
        slv_req[1].ar.burst  = s_axi_mem_arburst;
        slv_req[1].ar.lock   = s_axi_mem_arlock;
        slv_req[1].ar.cache  = s_axi_mem_arcache;
        slv_req[1].ar.prot   = s_axi_mem_arprot;
        slv_req[1].ar.qos    = s_axi_mem_arqos;
        slv_req[1].ar_valid  = s_axi_mem_arvalid;

        slv_req[1].r_ready   = s_axi_mem_rready;
    end

    assign s_axi_mem_awready = slv_resp[1].aw_ready;
    assign s_axi_mem_wready  = slv_resp[1].w_ready;
    assign s_axi_mem_bvalid  = slv_resp[1].b_valid;
    assign s_axi_mem_bresp   = slv_resp[1].b.resp;
    assign s_axi_mem_bid     = slv_resp[1].b.id;
    assign s_axi_mem_arready = slv_resp[1].ar_ready;
    assign s_axi_mem_rvalid  = slv_resp[1].r_valid;
    assign s_axi_mem_rdata   = slv_resp[1].r.data;
    assign s_axi_mem_rresp   = slv_resp[1].r.resp;
    assign s_axi_mem_rlast   = slv_resp[1].r.last;
    assign s_axi_mem_rid     = slv_resp[1].r.id;

    //------------------------------------------------------------------
    // S2: debugger System Bus Access, AXI4-Lite widened to AXI4
    //------------------------------------------------------------------
    lite_req_t  dbg_lite_req;
    lite_resp_t dbg_lite_resp;

    always_comb begin
        dbg_lite_req = '0;
        dbg_lite_req.aw.addr  = s_axi_dbg_awaddr;
        dbg_lite_req.aw.prot  = s_axi_dbg_awprot;
        dbg_lite_req.aw_valid = s_axi_dbg_awvalid;
        dbg_lite_req.w.data   = s_axi_dbg_wdata;
        dbg_lite_req.w.strb   = s_axi_dbg_wstrb;
        dbg_lite_req.w_valid  = s_axi_dbg_wvalid;
        dbg_lite_req.b_ready  = s_axi_dbg_bready;
        dbg_lite_req.ar.addr  = s_axi_dbg_araddr;
        dbg_lite_req.ar.prot  = s_axi_dbg_arprot;
        dbg_lite_req.ar_valid = s_axi_dbg_arvalid;
        dbg_lite_req.r_ready  = s_axi_dbg_rready;
    end

    assign s_axi_dbg_awready = dbg_lite_resp.aw_ready;
    assign s_axi_dbg_wready  = dbg_lite_resp.w_ready;
    assign s_axi_dbg_bresp   = dbg_lite_resp.b.resp;
    assign s_axi_dbg_bvalid  = dbg_lite_resp.b_valid;
    assign s_axi_dbg_arready = dbg_lite_resp.ar_ready;
    assign s_axi_dbg_rdata   = dbg_lite_resp.r.data;
    assign s_axi_dbg_rresp   = dbg_lite_resp.r.resp;
    assign s_axi_dbg_rvalid  = dbg_lite_resp.r_valid;

    axi_lite_to_axi #(
        .AxiDataWidth (32),
        .req_lite_t   (lite_req_t),
        .resp_lite_t  (lite_resp_t),
        .axi_req_t    (slv_req_t),
        .axi_resp_t   (slv_resp_t)
    ) dbg_lite_to_axi (
        .slv_req_lite_i  (dbg_lite_req),
        .slv_resp_lite_o (dbg_lite_resp),
        .slv_aw_cache_i  (4'b0011),
        .slv_ar_cache_i  (4'b0011),
        .mst_req_o       (slv_req[2]),
        .mst_resp_i      (slv_resp[2])
    );

    //------------------------------------------------------------------
    // The crossbar
    //------------------------------------------------------------------
    // ATOPs are off: CVA5's AXI masters never issue atomic operations, and
    // leaving them on would build an axi_atop_filter on every master port.
    axi_xbar #(
        .Cfg           (XbarCfg),
        .ATOPs         (1'b0),
        .Connectivity  (XbarConnectivity),
        .slv_aw_chan_t (slv_aw_chan_t),
        .mst_aw_chan_t (mst_aw_chan_t),
        .w_chan_t      (w_chan_t),
        .slv_b_chan_t  (slv_b_chan_t),
        .mst_b_chan_t  (mst_b_chan_t),
        .slv_ar_chan_t (slv_ar_chan_t),
        .mst_ar_chan_t (mst_ar_chan_t),
        .slv_r_chan_t  (slv_r_chan_t),
        .mst_r_chan_t  (mst_r_chan_t),
        .slv_req_t     (slv_req_t),
        .slv_resp_t    (slv_resp_t),
        .mst_req_t     (mst_req_t),
        .mst_resp_t    (mst_resp_t),
        .rule_t        (axi_pkg::xbar_rule_32_t)
    ) xbar_inst (
        .clk_i                 (clk),
        .rst_ni                (rstn),
        .test_i                (1'b0),
        .slv_ports_req_i       (slv_req),
        .slv_ports_resp_o      (slv_resp),
        .mst_ports_req_o       (mst_req),
        .mst_ports_resp_i      (mst_resp),
        .addr_map_i            (addr_map),
        .en_default_mst_port_i ('0),
        .default_mst_port_i    ('0)
    );

    //------------------------------------------------------------------
    // M0: main RAM, AXI4
    //------------------------------------------------------------------
    assign m_axi_ram_awid    = mst_req[0].aw.id;
    assign m_axi_ram_awaddr  = mst_req[0].aw.addr[M_RAM_ADDR_WIDTH-1:0];
    assign m_axi_ram_awlen   = mst_req[0].aw.len;
    assign m_axi_ram_awsize  = mst_req[0].aw.size;
    assign m_axi_ram_awburst = mst_req[0].aw.burst;
    assign m_axi_ram_awcache = mst_req[0].aw.cache;
    assign m_axi_ram_awprot  = mst_req[0].aw.prot;
    assign m_axi_ram_awlock  = mst_req[0].aw.lock;
    assign m_axi_ram_awqos   = mst_req[0].aw.qos;
    assign m_axi_ram_awvalid = mst_req[0].aw_valid;

    assign m_axi_ram_wdata   = mst_req[0].w.data;
    assign m_axi_ram_wstrb   = mst_req[0].w.strb;
    assign m_axi_ram_wlast   = mst_req[0].w.last;
    assign m_axi_ram_wvalid  = mst_req[0].w_valid;

    assign m_axi_ram_bready  = mst_req[0].b_ready;

    assign m_axi_ram_arid    = mst_req[0].ar.id;
    assign m_axi_ram_araddr  = mst_req[0].ar.addr[M_RAM_ADDR_WIDTH-1:0];
    assign m_axi_ram_arlen   = mst_req[0].ar.len;
    assign m_axi_ram_arsize  = mst_req[0].ar.size;
    assign m_axi_ram_arburst = mst_req[0].ar.burst;
    assign m_axi_ram_arcache = mst_req[0].ar.cache;
    assign m_axi_ram_arprot  = mst_req[0].ar.prot;
    assign m_axi_ram_arlock  = mst_req[0].ar.lock;
    assign m_axi_ram_arqos   = mst_req[0].ar.qos;
    assign m_axi_ram_arvalid = mst_req[0].ar_valid;

    assign m_axi_ram_rready  = mst_req[0].r_ready;

    always_comb begin
        mst_resp[0] = '0;
        mst_resp[0].aw_ready = m_axi_ram_awready;
        mst_resp[0].w_ready  = m_axi_ram_wready;
        mst_resp[0].b_valid  = m_axi_ram_bvalid;
        mst_resp[0].b.id     = m_axi_ram_bid;
        mst_resp[0].b.resp   = m_axi_ram_bresp;
        mst_resp[0].ar_ready = m_axi_ram_arready;
        mst_resp[0].r_valid  = m_axi_ram_rvalid;
        mst_resp[0].r.id     = m_axi_ram_rid;
        mst_resp[0].r.data   = m_axi_ram_rdata;
        mst_resp[0].r.resp   = m_axi_ram_rresp;
        mst_resp[0].r.last   = m_axi_ram_rlast;
    end

    //------------------------------------------------------------------
    // M1: peripheral window, AXI4 narrowed to AXI4-Lite
    //
    // ZipCPU's axi2axilite (WB2AXIP, Apache 2.0): a formally verified
    // converter built for one clock per transaction. pulp's axi_to_axi_lite
    // was tried here first and missed 100 MHz by 3.2 ns on the xc7z020 -- its
    // burst splitter, ID queue and atomic filter put 16 levels of logic
    // between a counter and the ID-reflect FIFO.
    //
    // Its ports are flat, so the crossbar's master-side struct is unpacked
    // here.
    //------------------------------------------------------------------
    // Flat signals for the converter's slave-port outputs, packed into the
    // crossbar's response struct below: a module output cannot drive a member
    // of a struct that another process also writes.
    logic                    p2l_awready, p2l_wready;
    logic                    p2l_bvalid;
    logic [MST_ID_WIDTH-1:0] p2l_bid;
    logic [1:0]              p2l_bresp;
    logic                    p2l_arready;
    logic                    p2l_rvalid, p2l_rlast;
    logic [MST_ID_WIDTH-1:0] p2l_rid;
    logic [31:0]             p2l_rdata;
    logic [1:0]              p2l_rresp;

    always_comb begin
        mst_resp[1]          = '0;
        mst_resp[1].aw_ready = p2l_awready;
        mst_resp[1].w_ready  = p2l_wready;
        mst_resp[1].b_valid  = p2l_bvalid;
        mst_resp[1].b.id     = p2l_bid;
        mst_resp[1].b.resp   = p2l_bresp;
        mst_resp[1].ar_ready = p2l_arready;
        mst_resp[1].r_valid  = p2l_rvalid;
        mst_resp[1].r.id     = p2l_rid;
        mst_resp[1].r.data   = p2l_rdata;
        mst_resp[1].r.resp   = p2l_rresp;
        mst_resp[1].r.last   = p2l_rlast;
    end

    axi2axilite #(
        .C_AXI_ID_WIDTH   (MST_ID_WIDTH),
        .C_AXI_DATA_WIDTH (32),
        .C_AXI_ADDR_WIDTH (32),
        .OPT_WRITES       (1'b1),
        .OPT_READS        (1'b1),
        .LGFIFO           (2)   // 4-deep ID FIFOs; at most 2 outstanding
    ) periph_to_lite (
        .S_AXI_ACLK    (clk),
        .S_AXI_ARESETN (rstn),

        .S_AXI_AWVALID (mst_req[1].aw_valid),
        .S_AXI_AWREADY (p2l_awready),
        .S_AXI_AWID    (mst_req[1].aw.id),
        .S_AXI_AWADDR  (mst_req[1].aw.addr),
        .S_AXI_AWLEN   (mst_req[1].aw.len),
        .S_AXI_AWSIZE  (mst_req[1].aw.size),
        .S_AXI_AWBURST (mst_req[1].aw.burst),
        .S_AXI_AWLOCK  (mst_req[1].aw.lock),
        .S_AXI_AWCACHE (mst_req[1].aw.cache),
        .S_AXI_AWPROT  (mst_req[1].aw.prot),
        .S_AXI_AWQOS   (mst_req[1].aw.qos),

        .S_AXI_WVALID  (mst_req[1].w_valid),
        .S_AXI_WREADY  (p2l_wready),
        .S_AXI_WDATA   (mst_req[1].w.data),
        .S_AXI_WSTRB   (mst_req[1].w.strb),
        .S_AXI_WLAST   (mst_req[1].w.last),

        .S_AXI_BVALID  (p2l_bvalid),
        .S_AXI_BREADY  (mst_req[1].b_ready),
        .S_AXI_BID     (p2l_bid),
        .S_AXI_BRESP   (p2l_bresp),

        .S_AXI_ARVALID (mst_req[1].ar_valid),
        .S_AXI_ARREADY (p2l_arready),
        .S_AXI_ARID    (mst_req[1].ar.id),
        .S_AXI_ARADDR  (mst_req[1].ar.addr),
        .S_AXI_ARLEN   (mst_req[1].ar.len),
        .S_AXI_ARSIZE  (mst_req[1].ar.size),
        .S_AXI_ARBURST (mst_req[1].ar.burst),
        .S_AXI_ARLOCK  (mst_req[1].ar.lock),
        .S_AXI_ARCACHE (mst_req[1].ar.cache),
        .S_AXI_ARPROT  (mst_req[1].ar.prot),
        .S_AXI_ARQOS   (mst_req[1].ar.qos),

        .S_AXI_RVALID  (p2l_rvalid),
        .S_AXI_RREADY  (mst_req[1].r_ready),
        .S_AXI_RID     (p2l_rid),
        .S_AXI_RDATA   (p2l_rdata),
        .S_AXI_RRESP   (p2l_rresp),
        .S_AXI_RLAST   (p2l_rlast),

        .M_AXI_AWADDR  (l2x_req.aw.addr),
        .M_AXI_AWPROT  (l2x_req.aw.prot),
        .M_AXI_AWVALID (l2x_req.aw_valid),
        .M_AXI_AWREADY (l2x_resp.aw_ready),
        .M_AXI_WDATA   (l2x_req.w.data),
        .M_AXI_WSTRB   (l2x_req.w.strb),
        .M_AXI_WVALID  (l2x_req.w_valid),
        .M_AXI_WREADY  (l2x_resp.w_ready),
        .M_AXI_BRESP   (l2x_resp.b.resp),
        .M_AXI_BVALID  (l2x_resp.b_valid),
        .M_AXI_BREADY  (l2x_req.b_ready),
        .M_AXI_ARADDR  (l2x_req.ar.addr),
        .M_AXI_ARPROT  (l2x_req.ar.prot),
        .M_AXI_ARVALID (l2x_req.ar_valid),
        .M_AXI_ARREADY (l2x_resp.ar_ready),
        .M_AXI_RDATA   (l2x_resp.r.data),
        .M_AXI_RRESP   (l2x_resp.r.resp),
        .M_AXI_RVALID  (l2x_resp.r_valid),
        .M_AXI_RREADY  (l2x_req.r_ready)
    );

    //------------------------------------------------------------------
    // The AXI4-Lite fan-out
    //
    // One slave port, one per peripheral out. With a single slave port the
    // per-port arbitration inside collapses, so what is left is an address
    // decode, a demultiplexer and an error slave for an address no rule
    // claims. Adding a peripheral is a rule and a port, not another
    // axi2axilite and another leg of the main crossbar's arbitration.
    //------------------------------------------------------------------
    localparam int unsigned NUM_LITE_MST = 32'd2;

    lite_req_t  [0:0] l2x_req_a;
    lite_resp_t [0:0] l2x_resp_a;
    lite_req_t  l2x_req;
    lite_resp_t l2x_resp;

    assign l2x_req_a[0] = l2x_req;
    assign l2x_resp = l2x_resp_a[0];

    lite_req_t  [NUM_LITE_MST-1:0] lite_mst_req;
    lite_resp_t [NUM_LITE_MST-1:0] lite_mst_resp;

    // AXI4-Lite carries no IDs, so the ID widths here are the minimum the
    // configuration struct will accept rather than anything meaningful.
    localparam axi_pkg::xbar_cfg_t LiteCfg = '{
        NoSlvPorts:         32'd1,
        NoMstPorts:         32'(NUM_LITE_MST),
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
        NoAddrRules:        32'(NUM_LITE_MST)
    };

    axi_pkg::xbar_rule_32_t [NUM_LITE_MST-1:0] lite_addr_map;
    always_comb begin
        lite_addr_map[0] = '{idx: 32'd0,
                             start_addr: PERIPH_BASE,
                             end_addr:   PERIPH_BASE + PERIPH_SIZE};
        lite_addr_map[1] = '{idx: 32'd1,
                             start_addr: CLINT_BASE,
                             end_addr:   CLINT_BASE + CLINT_SIZE};
    end

    axi_lite_xbar #(
        .Cfg (LiteCfg),
        .aw_chan_t (lite_aw_chan_t),
        .w_chan_t (lite_w_chan_t),
        .b_chan_t (lite_b_chan_t),
        .ar_chan_t (lite_ar_chan_t),
        .r_chan_t (lite_r_chan_t),
        .axi_req_t (lite_req_t),
        .axi_resp_t (lite_resp_t),
        .rule_t (axi_pkg::xbar_rule_32_t)
    ) lite_xbar (
        .clk_i (clk),
        .rst_ni (rstn),
        .test_i (1'b0),
        .slv_ports_req_i (l2x_req_a),
        .slv_ports_resp_o (l2x_resp_a),
        .mst_ports_req_o (lite_mst_req),
        .mst_ports_resp_i (lite_mst_resp),
        .addr_map_i (lite_addr_map),
        .en_default_mst_port_i ('0),
        .default_mst_port_i ('0)
    );

    //------------------------------------------------------------------
    // M1.0: UART
    //------------------------------------------------------------------
    assign m_axi_uart_awaddr  = lite_mst_req[0].aw.addr[M_UART_ADDR_WIDTH-1:0];
    assign m_axi_uart_awprot  = lite_mst_req[0].aw.prot;
    assign m_axi_uart_awvalid = lite_mst_req[0].aw_valid;
    assign m_axi_uart_wdata   = lite_mst_req[0].w.data;
    assign m_axi_uart_wstrb   = lite_mst_req[0].w.strb;
    assign m_axi_uart_wvalid  = lite_mst_req[0].w_valid;
    assign m_axi_uart_bready  = lite_mst_req[0].b_ready;
    assign m_axi_uart_araddr  = lite_mst_req[0].ar.addr[M_UART_ADDR_WIDTH-1:0];
    assign m_axi_uart_arprot  = lite_mst_req[0].ar.prot;
    assign m_axi_uart_arvalid = lite_mst_req[0].ar_valid;
    assign m_axi_uart_rready  = lite_mst_req[0].r_ready;

    always_comb begin
        lite_mst_resp[0] = '0;
        lite_mst_resp[0].aw_ready = m_axi_uart_awready;
        lite_mst_resp[0].w_ready  = m_axi_uart_wready;
        lite_mst_resp[0].b.resp   = m_axi_uart_bresp;
        lite_mst_resp[0].b_valid  = m_axi_uart_bvalid;
        lite_mst_resp[0].ar_ready = m_axi_uart_arready;
        lite_mst_resp[0].r.data   = m_axi_uart_rdata;
        lite_mst_resp[0].r.resp   = m_axi_uart_rresp;
        lite_mst_resp[0].r_valid  = m_axi_uart_rvalid;
    end

    //------------------------------------------------------------------
    // M1.1: CLINT
    //------------------------------------------------------------------
    assign m_axi_clint_awaddr  = lite_mst_req[1].aw.addr[M_CLINT_ADDR_WIDTH-1:0];
    assign m_axi_clint_awprot  = lite_mst_req[1].aw.prot;
    assign m_axi_clint_awvalid = lite_mst_req[1].aw_valid;
    assign m_axi_clint_wdata   = lite_mst_req[1].w.data;
    assign m_axi_clint_wstrb   = lite_mst_req[1].w.strb;
    assign m_axi_clint_wvalid  = lite_mst_req[1].w_valid;
    assign m_axi_clint_bready  = lite_mst_req[1].b_ready;
    assign m_axi_clint_araddr  = lite_mst_req[1].ar.addr[M_CLINT_ADDR_WIDTH-1:0];
    assign m_axi_clint_arprot  = lite_mst_req[1].ar.prot;
    assign m_axi_clint_arvalid = lite_mst_req[1].ar_valid;
    assign m_axi_clint_rready  = lite_mst_req[1].r_ready;

    always_comb begin
        lite_mst_resp[1] = '0;
        lite_mst_resp[1].aw_ready = m_axi_clint_awready;
        lite_mst_resp[1].w_ready  = m_axi_clint_wready;
        lite_mst_resp[1].b.resp   = m_axi_clint_bresp;
        lite_mst_resp[1].b_valid  = m_axi_clint_bvalid;
        lite_mst_resp[1].ar_ready = m_axi_clint_arready;
        lite_mst_resp[1].r.data   = m_axi_clint_rdata;
        lite_mst_resp[1].r.resp   = m_axi_clint_rresp;
        lite_mst_resp[1].r_valid  = m_axi_clint_rvalid;
    end

endmodule
