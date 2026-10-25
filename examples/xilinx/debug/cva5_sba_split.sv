/*
 * cva5_sba_split -- route the Debug Module's system bus by address: main RAM
 * one way, everything else off-chip.
 *
 * The debugger's system bus master used to leave cva5_top through m_axi_dbg,
 * cross the crossbar, and come back in through an s_axi_ram slave to reach a
 * RAM inside the very module it started from. That loop existed because the
 * crossbar's RAM master was built for the cached master, whose bursts needed a
 * full AXI4 path. The caches are gone and the debugger -- AXI4-Lite, one
 * outstanding transaction, single beats -- was its only remaining client, so
 * the loop was a crossbar port, a protocol conversion and an IP boundary spent
 * carrying single words a few hundred micrometres.
 *
 * This splits that bus where it starts instead. An address inside the RAM
 * window goes to the RAM port's AXI4 slave; everything else -- the UART, the
 * CLINT, whatever is added next -- leaves through m_axi_dbg and is decoded by
 * the crossbar as before. Nothing outside the RAM window is claimed here, so
 * an unmapped address still gets its DECERR from the crossbar's error slave.
 *
 * The RAM port's slave is AXI4, so the Lite transactions are presented to it
 * as the single-beat AXI4 they are: AWLEN 0, AWSIZE 4 bytes, INCR, WLAST.
 *
 * Two things this relies on, both true of dm_sba_axil and of AXI4-Lite in
 * general:
 *
 *   - One transaction outstanding. There is no reordering to do and a write
 *     and a read can never be in flight to different destinations at once.
 *   - The address is held for the whole transaction (dm_sba_axil drives it
 *     from addr_q, which changes only on the next request). The W channel is
 *     therefore routed by the write address directly, which is what lets a
 *     write whose W arrives before its AW still reach the right slave.
 *
 * The response-phase select is registered at the address handshake anyway, so
 * B and R do not depend on that second property.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_sba_split #(
    parameter logic [31:0] RAM_BASE   = 32'h8000_0000,

    //log2 of the RAM in words: the window is 4 << RAM_ADDR_W bytes, and the
    //RAM port's address bus is RAM_ADDR_W+2 bits of byte address.
    parameter int unsigned RAM_ADDR_W = 15,

    //cva5_ram_port's AXI ID width. Nothing here issues an ID; the port needs
    //the bits to echo.
    parameter int unsigned ID_WIDTH   = 8
) (
    input logic clk,

    //Synchronous, active low. This must be the reset the RAM port uses, which
    //is rstn alone and never ndmreset: OpenOCD's cpu_hold asserts ndmreset and
    //holds it while it loads a program over this very bus. A select register
    //held in reset through that would route every response to the wrong side
    //and the load would hang. See README.pynq_z2.md.
    input logic rstn,

    //AXI4-Lite slave: the Debug Module's system bus, through dm_sba_axil.
    input  logic [31:0] s_axi_awaddr,
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
    input  logic [31:0] s_axi_araddr,
    input  logic [2:0]  s_axi_arprot,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,

    //AXI4 master: cva5_ram_port's slave, inside the same module.
    output logic [ID_WIDTH-1:0]   m_axi_ram_awid,
    output logic [RAM_ADDR_W+1:0] m_axi_ram_awaddr,
    output logic [7:0]            m_axi_ram_awlen,
    output logic [2:0]            m_axi_ram_awsize,
    output logic [1:0]            m_axi_ram_awburst,
    output logic                  m_axi_ram_awvalid,
    input  logic                  m_axi_ram_awready,
    output logic [31:0]           m_axi_ram_wdata,
    output logic [3:0]            m_axi_ram_wstrb,
    output logic                  m_axi_ram_wlast,
    output logic                  m_axi_ram_wvalid,
    input  logic                  m_axi_ram_wready,
    input  logic [ID_WIDTH-1:0]   m_axi_ram_bid,
    input  logic [1:0]            m_axi_ram_bresp,
    input  logic                  m_axi_ram_bvalid,
    output logic                  m_axi_ram_bready,
    output logic [ID_WIDTH-1:0]   m_axi_ram_arid,
    output logic [RAM_ADDR_W+1:0] m_axi_ram_araddr,
    output logic [7:0]            m_axi_ram_arlen,
    output logic [2:0]            m_axi_ram_arsize,
    output logic [1:0]            m_axi_ram_arburst,
    output logic                  m_axi_ram_arvalid,
    input  logic                  m_axi_ram_arready,
    input  logic [ID_WIDTH-1:0]   m_axi_ram_rid,
    input  logic [31:0]           m_axi_ram_rdata,
    input  logic [1:0]            m_axi_ram_rresp,
    input  logic                  m_axi_ram_rlast,
    input  logic                  m_axi_ram_rvalid,
    output logic                  m_axi_ram_rready,

    //AXI4-Lite master: out of the module, to the crossbar.
    output logic [31:0] m_axi_dbg_awaddr,
    output logic [2:0]  m_axi_dbg_awprot,
    output logic        m_axi_dbg_awvalid,
    input  logic        m_axi_dbg_awready,
    output logic [31:0] m_axi_dbg_wdata,
    output logic [3:0]  m_axi_dbg_wstrb,
    output logic        m_axi_dbg_wvalid,
    input  logic        m_axi_dbg_wready,
    input  logic [1:0]  m_axi_dbg_bresp,
    input  logic        m_axi_dbg_bvalid,
    output logic        m_axi_dbg_bready,
    output logic [31:0] m_axi_dbg_araddr,
    output logic [2:0]  m_axi_dbg_arprot,
    output logic        m_axi_dbg_arvalid,
    input  logic        m_axi_dbg_arready,
    input  logic [31:0] m_axi_dbg_rdata,
    input  logic [1:0]  m_axi_dbg_rresp,
    input  logic        m_axi_dbg_rvalid,
    output logic        m_axi_dbg_rready
);

    logic wr_ram, rd_ram;          //the address currently presented
    logic wr_ram_q, rd_ram_q;      //what the response phase belongs to

    assign wr_ram = (s_axi_awaddr[31:RAM_ADDR_W+2] == RAM_BASE[31:RAM_ADDR_W+2]);
    assign rd_ram = (s_axi_araddr[31:RAM_ADDR_W+2] == RAM_BASE[31:RAM_ADDR_W+2]);

    always_ff @(posedge clk) begin
        if (!rstn) begin
            wr_ram_q <= 1'b0;
            rd_ram_q <= 1'b0;
        end
        else begin
            if (s_axi_awvalid & s_axi_awready) wr_ram_q <= wr_ram;
            if (s_axi_arvalid & s_axi_arready) rd_ram_q <= rd_ram;
        end
    end

    //---- out of the module: everything the RAM window does not claim
    assign m_axi_dbg_awaddr  = s_axi_awaddr;
    assign m_axi_dbg_awprot  = s_axi_awprot;
    assign m_axi_dbg_awvalid = s_axi_awvalid & ~wr_ram;
    assign m_axi_dbg_wdata   = s_axi_wdata;
    assign m_axi_dbg_wstrb   = s_axi_wstrb;
    assign m_axi_dbg_wvalid  = s_axi_wvalid & ~wr_ram;
    assign m_axi_dbg_bready  = s_axi_bready;
    assign m_axi_dbg_araddr  = s_axi_araddr;
    assign m_axi_dbg_arprot  = s_axi_arprot;
    assign m_axi_dbg_arvalid = s_axi_arvalid & ~rd_ram;
    assign m_axi_dbg_rready  = s_axi_rready;

    //---- to the RAM port: a Lite transaction is a single-beat AXI4 one
    assign m_axi_ram_awid    = '0;
    assign m_axi_ram_awaddr  = s_axi_awaddr[RAM_ADDR_W+1:0];
    assign m_axi_ram_awlen   = 8'd0;
    assign m_axi_ram_awsize  = 3'b010;        //4 bytes
    assign m_axi_ram_awburst = 2'b01;         //INCR
    assign m_axi_ram_awvalid = s_axi_awvalid & wr_ram;
    assign m_axi_ram_wdata   = s_axi_wdata;
    assign m_axi_ram_wstrb   = s_axi_wstrb;
    assign m_axi_ram_wlast   = 1'b1;
    assign m_axi_ram_wvalid  = s_axi_wvalid & wr_ram;
    assign m_axi_ram_bready  = s_axi_bready;
    assign m_axi_ram_arid    = '0;
    assign m_axi_ram_araddr  = s_axi_araddr[RAM_ADDR_W+1:0];
    assign m_axi_ram_arlen   = 8'd0;
    assign m_axi_ram_arsize  = 3'b010;
    assign m_axi_ram_arburst = 2'b01;
    assign m_axi_ram_arvalid = s_axi_arvalid & rd_ram;
    assign m_axi_ram_rready  = s_axi_rready;

    //---- back to the master: address readies follow the address presented,
    //data-phase responses follow the registered select.
    assign s_axi_awready = wr_ram ? m_axi_ram_awready : m_axi_dbg_awready;
    assign s_axi_wready  = wr_ram ? m_axi_ram_wready  : m_axi_dbg_wready;
    assign s_axi_bvalid  = wr_ram_q ? m_axi_ram_bvalid : m_axi_dbg_bvalid;
    assign s_axi_bresp   = wr_ram_q ? m_axi_ram_bresp  : m_axi_dbg_bresp;
    assign s_axi_arready = rd_ram ? m_axi_ram_arready : m_axi_dbg_arready;
    assign s_axi_rvalid  = rd_ram_q ? m_axi_ram_rvalid : m_axi_dbg_rvalid;
    assign s_axi_rdata   = rd_ram_q ? m_axi_ram_rdata  : m_axi_dbg_rdata;
    assign s_axi_rresp   = rd_ram_q ? m_axi_ram_rresp  : m_axi_dbg_rresp;

    //The RAM port echoes an ID and raises RLAST on its single beat; neither
    //has anywhere to go on a Lite master.
    logic _unused;
    assign _unused = &{1'b0, m_axi_ram_bid, m_axi_ram_rid, m_axi_ram_rlast};

endmodule
