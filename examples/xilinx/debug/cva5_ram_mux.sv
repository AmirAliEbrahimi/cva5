/*
 * cva5_ram_mux -- two AXI4 masters onto the one RAM port.
 *
 * cva5_ram_port hands main memory to the bus in the cycles the core leaves
 * idle, and it serves one transaction at a time. Until now its only client was
 * the Debug Module's system bus, routed to it by cva5_sba_split. This puts a
 * second client beside it, so that something outside cva5_top -- the PS, or a
 * DMA feeding an accelerator -- can read and write main memory too.
 *
 *   S0   the debugger, from cva5_sba_split's RAM leg
 *   S1   external, from cva5_top's new AXI4 slave port
 *
 * Why this is written out by hand rather than being pulp's axi_mux: only one
 * packaged IP in this design may carry axi_pkg, and the crossbar is it -- two
 * IPs defining the same package collide in one block design. A second IP
 * wanting pulp AXI types has to spell its channel structs out, so for a 2:1
 * mux in front of a port that serialises everything anyway, flat signals and
 * an explicit state bit are less code than the typedefs would be. The same
 * reasoning produced cva5_sba_split.
 *
 * ARBITRATION. One owner at a time, held from the grant until the response
 * completes -- B for a write, R with RLAST for a read. Priority alternates
 * between the ports, and the decision is made at the port level rather than
 * the channel level: whichever port wins, its write goes before its read,
 * which is the order the downstream port imposes anyway. Deciding
 * write-before-read across ports instead would let a master that writes
 * continuously starve the other master's reads, which is exactly the shape of
 * a DMA streaming against a debugger trying to read one word.
 *
 * There is one dead cycle between transactions: the owner clears on the
 * response and the next grant lands the cycle after. It is not worth removing.
 * SBA is JTAG-paced, and a burst holds the grant to RLAST, so for a DMA the
 * cycle is paid once per burst rather than once per beat.
 *
 * IDs pass through untouched and no width is added. An AXI mux normally
 * prepends the port index to the ID so responses can be routed back, and
 * pulp's does; here only one transaction is ever in flight, the owner is
 * already a register, and the response goes to whoever holds the port. That
 * keeps cva5_ram_port's ID_WIDTH as it is -- a Zynq GP master's 12-bit IDs
 * would otherwise have forced it wider.
 *
 * A HELD GRANT IS HELD UNTIL THE RESPONSE IS TAKEN, and that is worth saying
 * out loud because of who is behind this mux. A master that has its AR
 * accepted and then stops asserting RREADY keeps the port indefinitely: the
 * owner only clears on the response handshake, so the other master -- which
 * may be the debugger, the thing you would reach for to find out what went
 * wrong -- is locked out until reset. AXI forbids that master behaviour, a
 * master must eventually accept read data, and recovery is the shared rstn.
 * The alternative would be a watchdog that forces the port back, and it was
 * left out deliberately: a timeout long enough never to fire on a legitimately
 * slow master is too long to be a useful recovery, and a short one breaks the
 * slow master. If an external master that can hang is ever put on S1, give it
 * its own reset rather than putting a timer in here.
 *
 * RESET. rstn alone, never ndmreset, for the same reason cva5_sba_split and
 * cva5_ram_port take it: OpenOCD's cpu_hold asserts ndmreset and THEN loads a
 * program over this very path. An owner register held in reset through that
 * would route the response to the wrong master and the load would hang.
 *
 * Note that a request standing when reset releases is granted on that edge.
 * That is correct -- the request is still being made -- but it means an
 * aborted transaction has to have its valids withdrawn before reset is
 * released, not after, or the mux grants a master that has already gone.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_ram_mux #(
    //Word address into the RAM; the AXI address buses are ADDR_WIDTH+2 bits of
    //byte address, matching cva5_ram_port.
    parameter int unsigned ADDR_WIDTH = 15,

    //Echoed, not decoded. Both ports and the master port share it.
    parameter int unsigned ID_WIDTH   = 8
) (
    input logic clk,

    //Synchronous, active low, and from rstn alone -- see the header.
    input logic rstn,

    //---- S0: the debugger, from cva5_sba_split --------------------------
    input  logic [ID_WIDTH-1:0]    s0_awid,
    input  logic [ADDR_WIDTH+1:0]  s0_awaddr,
    input  logic [7:0]             s0_awlen,
    input  logic [2:0]             s0_awsize,
    input  logic [1:0]             s0_awburst,
    input  logic                   s0_awvalid,
    output logic                   s0_awready,
    input  logic [31:0]            s0_wdata,
    input  logic [3:0]             s0_wstrb,
    input  logic                   s0_wlast,
    input  logic                   s0_wvalid,
    output logic                   s0_wready,
    output logic [ID_WIDTH-1:0]    s0_bid,
    output logic [1:0]             s0_bresp,
    output logic                   s0_bvalid,
    input  logic                   s0_bready,
    input  logic [ID_WIDTH-1:0]    s0_arid,
    input  logic [ADDR_WIDTH+1:0]  s0_araddr,
    input  logic [7:0]             s0_arlen,
    input  logic [2:0]             s0_arsize,
    input  logic [1:0]             s0_arburst,
    input  logic                   s0_arvalid,
    output logic                   s0_arready,
    output logic [ID_WIDTH-1:0]    s0_rid,
    output logic [31:0]            s0_rdata,
    output logic [1:0]             s0_rresp,
    output logic                   s0_rlast,
    output logic                   s0_rvalid,
    input  logic                   s0_rready,

    //---- S1: external, from cva5_top's slave port -----------------------
    input  logic [ID_WIDTH-1:0]    s1_awid,
    input  logic [ADDR_WIDTH+1:0]  s1_awaddr,
    input  logic [7:0]             s1_awlen,
    input  logic [2:0]             s1_awsize,
    input  logic [1:0]             s1_awburst,
    input  logic                   s1_awvalid,
    output logic                   s1_awready,
    input  logic [31:0]            s1_wdata,
    input  logic [3:0]             s1_wstrb,
    input  logic                   s1_wlast,
    input  logic                   s1_wvalid,
    output logic                   s1_wready,
    output logic [ID_WIDTH-1:0]    s1_bid,
    output logic [1:0]             s1_bresp,
    output logic                   s1_bvalid,
    input  logic                   s1_bready,
    input  logic [ID_WIDTH-1:0]    s1_arid,
    input  logic [ADDR_WIDTH+1:0]  s1_araddr,
    input  logic [7:0]             s1_arlen,
    input  logic [2:0]             s1_arsize,
    input  logic [1:0]             s1_arburst,
    input  logic                   s1_arvalid,
    output logic                   s1_arready,
    output logic [ID_WIDTH-1:0]    s1_rid,
    output logic [31:0]            s1_rdata,
    output logic [1:0]             s1_rresp,
    output logic                   s1_rlast,
    output logic                   s1_rvalid,
    input  logic                   s1_rready,

    //---- M: cva5_ram_port's AXI4 slave ----------------------------------
    output logic [ID_WIDTH-1:0]    m_awid,
    output logic [ADDR_WIDTH+1:0]  m_awaddr,
    output logic [7:0]             m_awlen,
    output logic [2:0]             m_awsize,
    output logic [1:0]             m_awburst,
    output logic                   m_awvalid,
    input  logic                   m_awready,
    output logic [31:0]            m_wdata,
    output logic [3:0]             m_wstrb,
    output logic                   m_wlast,
    output logic                   m_wvalid,
    input  logic                   m_wready,
    input  logic [ID_WIDTH-1:0]    m_bid,
    input  logic [1:0]             m_bresp,
    input  logic                   m_bvalid,
    output logic                   m_bready,
    output logic [ID_WIDTH-1:0]    m_arid,
    output logic [ADDR_WIDTH+1:0]  m_araddr,
    output logic [7:0]             m_arlen,
    output logic [2:0]             m_arsize,
    output logic [1:0]             m_arburst,
    output logic                   m_arvalid,
    input  logic                   m_arready,
    input  logic [ID_WIDTH-1:0]    m_rid,
    input  logic [31:0]            m_rdata,
    input  logic [1:0]             m_rresp,
    input  logic                   m_rlast,
    input  logic                   m_rvalid,
    output logic                   m_rready
);

    //---- Arbitration ----------------------------------------------------
    logic busy;        //an owner holds the port
    logic owner;       //which one: 0 = debugger, 1 = external
    logic is_write;    //what it is doing
    logic prio;        //who wins the next tie

    logic s0_req;       //port level, not channel level: see the header on why
    logic s1_req;       //deciding write-before-read across ports starves reads
    logic grant;        //somebody is asking and the port is free to give
    logic grant_owner;
    logic grant_write;

    //One block, because splitting it is a trap. With s0_req and s1_req driven
    //by their own continuous assigns and read here, Verilator evaluated this
    //block against their previous values: grant stayed low while grant_write,
    //reading s0_awvalid directly, went high. Nothing warned -- not -Wall, not
    //UNOPTFLAT -- and the mux simply never granted. Keep the request terms and
    //the decision in the same always_comb.
    always_comb begin
        s0_req = s0_awvalid | s0_arvalid;
        s1_req = s1_awvalid | s1_arvalid;

        grant       = s0_req | s1_req;
        //A tie goes to whoever did not go last; otherwise to whoever asked.
        grant_owner = (s0_req & s1_req) ? prio : s1_req;
        //Within the winning port, its write goes first -- the order the
        //downstream port imposes anyway.
        grant_write = grant_owner ? s1_awvalid : s0_awvalid;
    end

    //The selection used this cycle. Taking the grant combinationally when the
    //port is free costs the requester no latency: its AW or AR reaches
    //cva5_ram_port in the cycle it was raised.
    logic sel, active, write_phase;
    assign sel         = busy ? owner    : grant_owner;
    assign active      = busy | grant;
    assign write_phase = busy ? is_write : grant_write;

    //A transaction ends on its response: B for a write, R with RLAST for a
    //read. Nothing else releases the port.
    logic done;
    assign done = is_write ? (m_bvalid & m_bready)
                           : (m_rvalid & m_rready & m_rlast);

    always_ff @(posedge clk) begin
        if (~rstn) begin
            busy     <= 1'b0;
            owner    <= 1'b0;
            is_write <= 1'b0;
            prio     <= 1'b0;
        end
        else if (~busy) begin
            if (grant) begin
                busy     <= 1'b1;
                owner    <= grant_owner;
                is_write <= grant_write;
            end
        end
        else if (done) begin
            busy <= 1'b0;
            prio <= ~owner;
        end
    end

    //---- Requests, towards the RAM port ---------------------------------
    always_comb begin
        m_awid    = sel ? s1_awid    : s0_awid;
        m_awaddr  = sel ? s1_awaddr  : s0_awaddr;
        m_awlen   = sel ? s1_awlen   : s0_awlen;
        m_awsize  = sel ? s1_awsize  : s0_awsize;
        m_awburst = sel ? s1_awburst : s0_awburst;

        m_wdata   = sel ? s1_wdata   : s0_wdata;
        m_wstrb   = sel ? s1_wstrb   : s0_wstrb;
        m_wlast   = sel ? s1_wlast   : s0_wlast;

        m_arid    = sel ? s1_arid    : s0_arid;
        m_araddr  = sel ? s1_araddr  : s0_araddr;
        m_arlen   = sel ? s1_arlen   : s0_arlen;
        m_arsize  = sel ? s1_arsize  : s0_arsize;
        m_arburst = sel ? s1_arburst : s0_arburst;
    end

    //Valids are gated on there being an owner and on the phase, so a read
    //raised while a write holds the port is simply not presented yet.
    assign m_awvalid = active &  write_phase & (sel ? s1_awvalid : s0_awvalid);
    assign m_wvalid  = active &  write_phase & (sel ? s1_wvalid  : s0_wvalid);
    assign m_arvalid = active & ~write_phase & (sel ? s1_arvalid : s0_arvalid);
    assign m_bready  = active &  write_phase & (sel ? s1_bready  : s0_bready);
    assign m_rready  = active & ~write_phase & (sel ? s1_rready  : s0_rready);

    //---- Responses, back to the owner -----------------------------------
    //Every ready and valid here carries the selection, so the port that does
    //not hold the mux sees no handshake at all rather than a stale one.
    assign s0_awready = m_awready & active &  write_phase & (sel == 1'b0);
    assign s1_awready = m_awready & active &  write_phase & (sel == 1'b1);
    assign s0_wready  = m_wready  & active &  write_phase & (sel == 1'b0);
    assign s1_wready  = m_wready  & active &  write_phase & (sel == 1'b1);
    assign s0_arready = m_arready & active & ~write_phase & (sel == 1'b0);
    assign s1_arready = m_arready & active & ~write_phase & (sel == 1'b1);

    assign s0_bvalid  = m_bvalid  & active &  write_phase & (sel == 1'b0);
    assign s1_bvalid  = m_bvalid  & active &  write_phase & (sel == 1'b1);
    assign s0_rvalid  = m_rvalid  & active & ~write_phase & (sel == 1'b0);
    assign s1_rvalid  = m_rvalid  & active & ~write_phase & (sel == 1'b1);

    //Payloads are broadcast; the valids above decide who is listening.
    assign s0_bid   = m_bid;
    assign s1_bid   = m_bid;
    assign s0_bresp = m_bresp;
    assign s1_bresp = m_bresp;

    assign s0_rid   = m_rid;
    assign s1_rid   = m_rid;
    assign s0_rdata = m_rdata;
    assign s1_rdata = m_rdata;
    assign s0_rresp = m_rresp;
    assign s1_rresp = m_rresp;
    assign s0_rlast = m_rlast;
    assign s1_rlast = m_rlast;

endmodule
