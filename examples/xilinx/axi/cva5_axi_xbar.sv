/*
 * cva5_axi_xbar -- the SoC's peripheral interconnect.
 *
 *   S0  s_axi_cpu    CPU peripheral bus     AXI4-Lite
 *   S1  s_axi_dbg    debugger (SBA)         AXI4-Lite
 *
 *   M0  m_axi_uart   UART at PERIPH_BASE    AXI4-Lite
 *   M1  m_axi_clint  CLINT at CLINT_BASE     AXI4-Lite
 *   M2  m_axi_plic   PLIC at PLIC_BASE       AXI4-Lite
 *   M3  m_axi_spi    SPI at SPI_BASE         AXI4-Lite
 *   M4  m_axi_i2c    I2C at I2C_BASE         AXI4-Lite
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
 * axi_id_prepend, and ZipCPU's axi2axilite with its sfifo,
 * skidbuffer and axi_addr. The decode is one axi_lite_xbar.
 *
 * The address map is a parameter here rather than something the Vivado address
 * editor decides, so examples/sw/soc.h is the single source of truth for the
 * decode. An address no rule claims gets a DECERR from the Lite crossbar's own
 * error slave, rather than landing somewhere unexpected or hanging.
 *
 * Adding a peripheral is a rule, a port and a line in the block design -- the
 * PLIC, the SPI and the I2C all arrived that way. It is not free: a port costs
 * around 190 LUTs and 110 flops here, measured when the PLIC's was added,
 * which is nearly three times what the PLIC itself costs at one source. The
 * cost is on the master side and it is the cheap side: the measured split puts
 * the two slave-port demuxes at 264 and 354 LUTs against 71/67/77 for the
 * master-port muxes, so ports scale cheaply and masters do not.
 *
 * A timer window is reserved at 0x1800_0000 and unused, since the CLINT
 * provides the timer this core needs.
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
    parameter logic [31:0] PLIC_BASE   = 32'h0C00_0000,
    parameter logic [31:0] PLIC_SIZE   = 32'h0400_0000,  // 64 MB, CVA6's window
    parameter logic [31:0] SPI_BASE    = 32'h2000_0000,
    parameter logic [31:0] SPI_SIZE    = 32'h0080_0000,  // 8 MB, CVA6's window
    // CVA6 reserves no I2C window, so this one is ours: the next 4 KB-aligned
    // address clear of the SPI's 8 MB and well short of the 0x3000_0000
    // Ethernet window the map reserves.
    parameter logic [31:0] I2C_BASE    = 32'h2800_0000,
    parameter logic [31:0] I2C_SIZE    = 32'h0000_1000,  // 4 KB

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
    parameter int unsigned M_PLIC_ADDR_WIDTH  = 32,
    parameter int unsigned M_SPI_ADDR_WIDTH   = 32,
    parameter int unsigned M_I2C_ADDR_WIDTH   = 32,

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
        output logic m_axi_clint_rready,

        //----------------------------------------------------------------
        // M2: PLIC (AXI4-Lite)
        //----------------------------------------------------------------
        output logic [M_PLIC_ADDR_WIDTH-1:0] m_axi_plic_awaddr,
        output logic [2:0] m_axi_plic_awprot,
        output logic m_axi_plic_awvalid,
        input logic m_axi_plic_awready,
        output logic [31:0] m_axi_plic_wdata,
        output logic [3:0] m_axi_plic_wstrb,
        output logic m_axi_plic_wvalid,
        input logic m_axi_plic_wready,
        input logic [1:0] m_axi_plic_bresp,
        input logic m_axi_plic_bvalid,
        output logic m_axi_plic_bready,
        output logic [M_PLIC_ADDR_WIDTH-1:0] m_axi_plic_araddr,
        output logic [2:0] m_axi_plic_arprot,
        output logic m_axi_plic_arvalid,
        input logic m_axi_plic_arready,
        input logic [31:0] m_axi_plic_rdata,
        input logic [1:0] m_axi_plic_rresp,
        input logic m_axi_plic_rvalid,
        output logic m_axi_plic_rready,

        //----------------------------------------------------------------
        // M3: SPI (AXI4-Lite)
        //----------------------------------------------------------------
        output logic [M_SPI_ADDR_WIDTH-1:0] m_axi_spi_awaddr,
        output logic [2:0] m_axi_spi_awprot,
        output logic m_axi_spi_awvalid,
        input logic m_axi_spi_awready,
        output logic [31:0] m_axi_spi_wdata,
        output logic [3:0] m_axi_spi_wstrb,
        output logic m_axi_spi_wvalid,
        input logic m_axi_spi_wready,
        input logic [1:0] m_axi_spi_bresp,
        input logic m_axi_spi_bvalid,
        output logic m_axi_spi_bready,
        output logic [M_SPI_ADDR_WIDTH-1:0] m_axi_spi_araddr,
        output logic [2:0] m_axi_spi_arprot,
        output logic m_axi_spi_arvalid,
        input logic m_axi_spi_arready,
        input logic [31:0] m_axi_spi_rdata,
        input logic [1:0] m_axi_spi_rresp,
        input logic m_axi_spi_rvalid,
        output logic m_axi_spi_rready,

        output logic [M_I2C_ADDR_WIDTH-1:0] m_axi_i2c_awaddr,
        output logic [2:0] m_axi_i2c_awprot,
        output logic m_axi_i2c_awvalid,
        input logic m_axi_i2c_awready,
        output logic [31:0] m_axi_i2c_wdata,
        output logic [3:0] m_axi_i2c_wstrb,
        output logic m_axi_i2c_wvalid,
        input logic m_axi_i2c_wready,
        input logic [1:0] m_axi_i2c_bresp,
        input logic m_axi_i2c_bvalid,
        output logic m_axi_i2c_bready,
        output logic [M_I2C_ADDR_WIDTH-1:0] m_axi_i2c_araddr,
        output logic [2:0] m_axi_i2c_arprot,
        output logic m_axi_i2c_arvalid,
        input logic m_axi_i2c_arready,
        input logic [31:0] m_axi_i2c_rdata,
        input logic [1:0] m_axi_i2c_rresp,
        input logic m_axi_i2c_rvalid,
        output logic m_axi_i2c_rready
    );

    localparam int unsigned NUM_SLV = 32'd2;
    localparam int unsigned NUM_MST = 32'd5;

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
    // LatencyMode cuts the address channels on the demultiplexer side, which
    // is where the long combinational run is -- address decode into the
    // arbiter -- plus the demultiplexer's R channel.
    //
    // That last cut was added because the critical path moved in here, which
    // the previous version of this comment predicted it might. On the board it
    // reported as
    //
    //   from  axi_xbar_0/.../gen_slv_port_demux[1]/gen_demux.i_r_fifo/mem_q_reg
    //   to    cva5_top_0/.../gen_ls_pbus.gen_axi.axi_bus/ls.data_out_reg[16]
    //   11 levels, 9.775 ns, 79% routing, WNS +0.076
    //
    // -- the debugger port's R-channel FIFO, through the response arbitration,
    // all the way into the core's AXI sub-unit read-data register, with no
    // register in between. DemuxR puts one there.
    //
    // The cost is a cycle on peripheral responses, and it is close to free:
    // main memory is answered inside cva5_top on the local memory interface
    // and never crosses this crossbar, so nothing on the load-to-use path
    // pays. What pays is a UART status poll, a CLINT read, a PLIC claim --
    // accesses that are already several cycles and are not in any inner loop.
    //
    // It is deliberately DemuxR and not CUT_SLV_PORTS, which would also
    // register W and B. Those are not on a critical path, and the flops this
    // crossbar spends show up as congestion next to the core: the fifth master
    // port cost 192 LUTs, most of it widening these same demuxes, and the
    // build that added it lost 0.26 ns. Spend registers where the measurement
    // points, not by the preset.
    //
    // axi_pkg::CUT_ALL_AX and then CUT_ALL_PORTS remain the steps back up.
    //------------------------------------------------------------------
    localparam axi_pkg::xbar_cfg_t XbarCfg = '{
        NoSlvPorts:         32'(NUM_SLV),
        NoMstPorts:         32'(NUM_MST),
        MaxMstTrans:        32'(MAX_TRANS),
        MaxSlvTrans:        32'(MAX_TRANS),
        FallThrough:        1'b0,
        LatencyMode:        axi_pkg::xbar_latency_e'(axi_pkg::CUT_SLV_AX |
                                                    axi_pkg::DemuxR),
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
        addr_map[2] = '{idx: 32'd2,
                        start_addr: PLIC_BASE,
                        end_addr:   PLIC_BASE + PLIC_SIZE};
        addr_map[3] = '{idx: 32'd3,
                        start_addr: SPI_BASE,
                        end_addr:   SPI_BASE + SPI_SIZE};
        addr_map[4] = '{idx: 32'd4,
                        start_addr: I2C_BASE,
                        end_addr:   I2C_BASE + I2C_SIZE};
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

    //------------------------------------------------------------------
    // M2: PLIC
    //------------------------------------------------------------------
    assign m_axi_plic_awaddr  = mst_req[2].aw.addr[M_PLIC_ADDR_WIDTH-1:0];
    assign m_axi_plic_awprot  = mst_req[2].aw.prot;
    assign m_axi_plic_awvalid = mst_req[2].aw_valid;
    assign m_axi_plic_wdata   = mst_req[2].w.data;
    assign m_axi_plic_wstrb   = mst_req[2].w.strb;
    assign m_axi_plic_wvalid  = mst_req[2].w_valid;
    assign m_axi_plic_bready  = mst_req[2].b_ready;
    assign m_axi_plic_araddr  = mst_req[2].ar.addr[M_PLIC_ADDR_WIDTH-1:0];
    assign m_axi_plic_arprot  = mst_req[2].ar.prot;
    assign m_axi_plic_arvalid = mst_req[2].ar_valid;
    assign m_axi_plic_rready  = mst_req[2].r_ready;

    always_comb begin
        mst_resp[2] = '0;
        mst_resp[2].aw_ready = m_axi_plic_awready;
        mst_resp[2].w_ready  = m_axi_plic_wready;
        mst_resp[2].b.resp   = m_axi_plic_bresp;
        mst_resp[2].b_valid  = m_axi_plic_bvalid;
        mst_resp[2].ar_ready = m_axi_plic_arready;
        mst_resp[2].r.data   = m_axi_plic_rdata;
        mst_resp[2].r.resp   = m_axi_plic_rresp;
        mst_resp[2].r_valid  = m_axi_plic_rvalid;
    end

    //------------------------------------------------------------------
    // M3: SPI
    //------------------------------------------------------------------
    assign m_axi_spi_awaddr  = mst_req[3].aw.addr[M_SPI_ADDR_WIDTH-1:0];
    assign m_axi_spi_awprot  = mst_req[3].aw.prot;
    assign m_axi_spi_awvalid = mst_req[3].aw_valid;
    assign m_axi_spi_wdata   = mst_req[3].w.data;
    assign m_axi_spi_wstrb   = mst_req[3].w.strb;
    assign m_axi_spi_wvalid  = mst_req[3].w_valid;
    assign m_axi_spi_bready  = mst_req[3].b_ready;
    assign m_axi_spi_araddr  = mst_req[3].ar.addr[M_SPI_ADDR_WIDTH-1:0];
    assign m_axi_spi_arprot  = mst_req[3].ar.prot;
    assign m_axi_spi_arvalid = mst_req[3].ar_valid;
    assign m_axi_spi_rready  = mst_req[3].r_ready;

    always_comb begin
        mst_resp[3] = '0;
        mst_resp[3].aw_ready = m_axi_spi_awready;
        mst_resp[3].w_ready  = m_axi_spi_wready;
        mst_resp[3].b.resp   = m_axi_spi_bresp;
        mst_resp[3].b_valid  = m_axi_spi_bvalid;
        mst_resp[3].ar_ready = m_axi_spi_arready;
        mst_resp[3].r.data   = m_axi_spi_rdata;
        mst_resp[3].r.resp   = m_axi_spi_rresp;
        mst_resp[3].r_valid  = m_axi_spi_rvalid;
    end

    //------------------------------------------------------------------
    // M4: I2C
    //------------------------------------------------------------------
    assign m_axi_i2c_awaddr  = mst_req[4].aw.addr[M_I2C_ADDR_WIDTH-1:0];
    assign m_axi_i2c_awprot  = mst_req[4].aw.prot;
    assign m_axi_i2c_awvalid = mst_req[4].aw_valid;
    assign m_axi_i2c_wdata   = mst_req[4].w.data;
    assign m_axi_i2c_wstrb   = mst_req[4].w.strb;
    assign m_axi_i2c_wvalid  = mst_req[4].w_valid;
    assign m_axi_i2c_bready  = mst_req[4].b_ready;
    assign m_axi_i2c_araddr  = mst_req[4].ar.addr[M_I2C_ADDR_WIDTH-1:0];
    assign m_axi_i2c_arprot  = mst_req[4].ar.prot;
    assign m_axi_i2c_arvalid = mst_req[4].ar_valid;
    assign m_axi_i2c_rready  = mst_req[4].r_ready;

    always_comb begin
        mst_resp[4] = '0;
        mst_resp[4].aw_ready = m_axi_i2c_awready;
        mst_resp[4].w_ready  = m_axi_i2c_wready;
        mst_resp[4].b.resp   = m_axi_i2c_bresp;
        mst_resp[4].b_valid  = m_axi_i2c_bvalid;
        mst_resp[4].ar_ready = m_axi_i2c_arready;
        mst_resp[4].r.data   = m_axi_i2c_rdata;
        mst_resp[4].r.resp   = m_axi_i2c_rresp;
        mst_resp[4].r_valid  = m_axi_i2c_rvalid;
    end

endmodule
