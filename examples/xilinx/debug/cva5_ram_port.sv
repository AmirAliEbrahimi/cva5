/*
 * cva5_ram_port -- lets the bus into the core's local memory.
 *
 * Main memory is a true dual-port block RAM inside cva5_wrapper: port A is
 * instruction fetch, port B is load/store. Both are CVA5's local memory
 * interface, which has no handshake at all -- the core raises `en` and expects
 * its data on the next cycle, every time, with no way to be told to wait.
 *
 * Programs are loaded over the Debug Module's System Bus Access, so something
 * has to reach that RAM from the bus. This module sits in front of port B and
 * hands it to the core whenever the core wants it, giving the bus only the
 * cycles the core leaves idle. The core therefore cannot be stalled by it,
 * which is what makes it safe to put a second master on an interface that
 * cannot express backpressure. The bus can wait: SBA is a JTAG-paced register
 * interface and a held-off cycle is invisible next to the scan.
 *
 * During `make load` the core is in reset and every cycle is idle, so a block
 * write runs at full rate. With the core running -- a GDB memory read at a
 * breakpoint, say -- the bus takes whatever the load-store unit is not using,
 * which on any real program is most cycles.
 *
 * Full AXI4 rather than AXI4-Lite, because the crossbar's RAM port is AXI4 and
 * a block design will not join the two protocols. Bursts are handled a beat at
 * a time, incrementing; SBA only ever issues single beats, but a burst-capable
 * master here costs little and is what a future one (the PS, say) would want.
 * WRAP is treated as INCR, which is exact for the single-beat case and is all
 * that can reach this port now that there is no cache to issue wrapping line
 * fills.
 *
 * One transaction at a time, writes before reads. `core_rdata` is wired
 * straight through from the RAM's own output register, so the core sees no
 * added latency: in the cycle it reads, it is the one that held the port.
 *
 * Write data is buffered one beat before it reaches the RAM, and nothing on
 * the bus side drives the RAM combinationally. That costs the bus a cycle of
 * latency and is the only thing here that exists for timing rather than for
 * function. The enable and byte-write pins of a 128 KB inferred RAM are a
 * 32-deep array of RAMB36s: wbe arrives at eight of them through a net with
 * eight loads. Letting `wvalid` and `wstrb` reach that fanout directly put the
 * crossbar's AW/W arbitration -- the demux select register, the in-flight
 * counter, the mux's W arbiter, eight levels of logic in all -- in front of
 * it, and made the worst path in the SoC a debugger write: 8.831 ns, 81% of
 * it routing. Latching the beat here cuts the array's fanout off that chain
 * and leaves the bus side one flop away from the RAM.
 *
 * The cycle it costs buys nothing back for the core and cannot be noticed by
 * the bus. The port still takes a beat per cycle at full rate, because a
 * pending beat retires in the same cycle the next one is accepted; only the
 * first beat and the B response move one cycle later.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module cva5_ram_port #(
        parameter int unsigned ADDR_WIDTH = 15,  //word address into the RAM
        parameter int unsigned ID_WIDTH = 8      //must match the crossbar's master port
    ) (
        input logic clk,
        //Synchronous active low. Must be the board reset only: a reset that
        //includes ndmreset would hold this port down for the whole of a
        //debugger load, since the debugger asserts ndmreset first.
        input logic rstn,

        //----------------------------------------------------------------
        // The core's load/store side of the local memory interface
        //----------------------------------------------------------------
        input logic core_en,
        input logic [3:0] core_be,
        input logic [ADDR_WIDTH-1:0] core_addr,
        input logic [31:0] core_wdata,
        output logic [31:0] core_rdata,

        //----------------------------------------------------------------
        // AXI4 slave, from the crossbar: the debugger's way in
        //----------------------------------------------------------------
        input logic [ID_WIDTH-1:0] s_axi_awid,
        input logic [ADDR_WIDTH+1:0] s_axi_awaddr, //byte address
        input logic [7:0] s_axi_awlen,
        input logic [2:0] s_axi_awsize,
        input logic [1:0] s_axi_awburst,
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
        input logic [ADDR_WIDTH+1:0] s_axi_araddr,
        input logic [7:0] s_axi_arlen,
        input logic [2:0] s_axi_arsize,
        input logic [1:0] s_axi_arburst,
        input logic s_axi_arvalid,
        output logic s_axi_arready,
        output logic [ID_WIDTH-1:0] s_axi_rid,
        output logic [31:0] s_axi_rdata,
        output logic [1:0] s_axi_rresp,
        output logic s_axi_rlast,
        output logic s_axi_rvalid,
        input logic s_axi_rready,

        //----------------------------------------------------------------
        // Port B of the RAM
        //----------------------------------------------------------------
        output logic ram_en,
        output logic [3:0] ram_wbe,
        output logic [ADDR_WIDTH-1:0] ram_addr,
        output logic [31:0] ram_wdata,
        input logic [31:0] ram_rdata
    );

    typedef enum logic [2:0] {IDLE, WRITE, WRESP, READ, RDATA} state_t;
    state_t state;

    logic [ADDR_WIDTH-1:0] cur_addr;
    logic [7:0] beats_left;
    logic [ID_WIDTH-1:0] cur_id;

    //The one buffered write beat. `cur_addr` is its address: it advances when
    //the beat retires into the RAM, not when it is accepted, so it names the
    //access the RAM is being given this cycle in both directions.
    logic wr_pend;
    logic wr_last;
    logic [3:0] wr_strb;
    logic [31:0] wr_data;

    // The core takes the port whenever it asks for it; the bus gets what is
    // left. This is the whole arbitration policy.
    logic port_free;
    assign port_free = ~core_en;

    assign s_axi_awready = (state == IDLE) & s_axi_awvalid;
    assign s_axi_arready = (state == IDLE) & s_axi_arvalid & ~s_axi_awvalid;

    //Room for a beat: either the buffer is empty, or the beat in it is going
    //into the RAM this cycle. Closed after the last beat of the burst, so a
    //master that leaves wvalid high cannot be given a beat the burst did not
    //ask for.
    assign s_axi_wready = (state == WRITE) & ~wr_last & (~wr_pend | port_free);

    assign s_axi_bresp = 2'b00;   //the RAM always answers
    assign s_axi_rresp = 2'b00;
    assign s_axi_bid = cur_id;
    assign s_axi_rid = cur_id;

    //Both of these are registers and `port_free` -- no bus signal reaches the
    //RAM's pins. That is the point of the buffer.
    logic bus_writes, bus_reads;
    assign bus_writes = wr_pend & port_free;
    assign bus_reads = (state == READ) & port_free;

    assign ram_en = core_en | bus_writes | bus_reads;
    assign ram_addr = core_en ? core_addr : cur_addr;
    assign ram_wdata = core_en ? core_wdata : wr_data;
    assign ram_wbe = core_en ? core_be : (bus_writes ? wr_strb : 4'h0);

    // Only ever sampled by the core in a cycle it held the port.
    assign core_rdata = ram_rdata;

    // Only the things that must come up idle are reset: the state, the two
    // response valids, which are outputs that may not assert on their own, and
    // the write buffer's two control bits -- a stale wr_pend out of reset
    // would write a word into the RAM nobody asked for. Everything else here
    // is datapath -- the address, the beat count, the ID, the buffered write
    // data and the read data are all loaded from a request before anything
    // reads them, so their value out of reset is never observed.
    //
    // That is not tidiness. On a 7-series part the reset is part of a slice's
    // control set, and flops that carry one cannot share a slice with flops
    // that do not. Resetting ~100 registers that did not need it made a
    // control set of its own for this port; leaving them free lets the placer
    // pack them wherever there is room.
    always_ff @(posedge clk) begin
        if (!rstn) begin
            state <= IDLE;
            s_axi_bvalid <= 0;
            s_axi_rvalid <= 0;
            wr_pend <= 0;
            wr_last <= 0;
        end
        else begin
            case (state)
                IDLE : begin
                    if (s_axi_awvalid) begin
                        cur_addr <= s_axi_awaddr[ADDR_WIDTH+1:2];
                        beats_left <= s_axi_awlen;
                        cur_id <= s_axi_awid;
                        state <= WRITE;
                    end
                    else if (s_axi_arvalid) begin
                        cur_addr <= s_axi_araddr[ADDR_WIDTH+1:2];
                        beats_left <= s_axi_arlen;
                        cur_id <= s_axi_arid;
                        state <= READ;
                    end
                end

                //One beat per cycle the core leaves idle: the buffered beat
                //goes into the RAM and the next is accepted in its place. The
                //two branches are written as separate ifs and in this order
                //on purpose -- an accept in the same cycle as a retire must
                //leave wr_pend set, which the later assignment does. They can
                //never disagree about wr_last: a retire only looks at it when
                //it is set, and an accept is only offered when it is clear.
                WRITE : begin
                    if (wr_pend & port_free) begin
                        wr_pend <= 0;
                        cur_addr <= cur_addr + 1;
                        if (wr_last) begin
                            wr_last <= 0;
                            s_axi_bvalid <= 1;
                            state <= WRESP;
                        end
                    end
                    if (s_axi_wvalid & s_axi_wready) begin
                        wr_pend <= 1;
                        wr_last <= s_axi_wlast;
                        wr_data <= s_axi_wdata;
                        wr_strb <= s_axi_wstrb;
                        beats_left <= beats_left - 1;
                    end
                end

                WRESP : if (s_axi_bready) begin
                    s_axi_bvalid <= 0;
                    state <= IDLE;
                end

                READ : if (port_free) begin
                    cur_addr <= cur_addr + 1;
                    state <= RDATA;
                end

                //The RAM's output register holds this beat's data now.
                RDATA : begin
                    if (!s_axi_rvalid) begin
                        s_axi_rdata <= ram_rdata;
                        s_axi_rvalid <= 1;
                        s_axi_rlast <= (beats_left == 0);
                    end
                    else if (s_axi_rready) begin
                        s_axi_rvalid <= 0;
                        s_axi_rlast <= 0;
                        if (beats_left == 0)
                            state <= IDLE;
                        else begin
                            beats_left <= beats_left - 1;
                            state <= READ;
                        end
                    end
                end

                default : state <= IDLE;
            endcase
        end
    end

    // Burst type and size are not used: every access is a 32-bit word and the
    // address simply increments, which is exact for INCR and for the single
    // beats SBA issues. Naming them keeps the IP at -Wall.
    // The byte bits of the address go with them: every access is a 32-bit word.
    logic unused_axi;
    assign unused_axi = &{1'b0, s_axi_awsize, s_axi_awburst, s_axi_arsize,
                          s_axi_arburst, s_axi_awaddr[1:0], s_axi_araddr[1:0]};

endmodule
