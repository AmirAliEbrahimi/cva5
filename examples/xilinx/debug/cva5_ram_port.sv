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
 * The two sides are kept apart in both directions, and both separations are
 * here for timing. The RAM sits behind a 128 KB array of 32 cascaded RAMB36s
 * whose enable and byte-write pins take a decode LUT and a net with eight
 * loads to reach -- about 3 ns before anything of ours is counted -- so what
 * drives them has to be as shallow as a mux can be.
 *
 * Going in, nothing on the bus side reaches the RAM combinationally: an access
 * waits in a one-deep buffer and `bus_pend` is the whole of the bus's request.
 * Driving the RAM straight from `s_axi_wvalid` and `s_axi_wstrb` instead put
 * the crossbar's AW/W arbitration -- demux select register, in-flight counter,
 * W arbiter, eight levels of logic -- in front of that fanout, and made the
 * worst path in the SoC a debugger write at 8.831 ns.
 *
 * Coming out, no AXI signal here is a function of `core_en`. That is why
 * `s_axi_wready` depends on the buffer alone and a burst therefore moves a
 * beat every other cycle rather than every cycle. Accepting the next beat in
 * the cycle the buffered one is served is the obvious optimisation and it cost
 * 0.42 ns of the whole design: with `core_en` in the W handshake, Vivado
 * factors the two cones together and the LUTs that compute `s_axi_wready` land
 * in the middle of the core's own path from the load-store unit to the RAM's
 * enable, which report_timing then shows by name. Half rate on a JTAG-paced
 * interface is not worth a nanosecond of the core's path to memory.
 *
 * What is left in the core's way is a two-input OR to the enable and a
 * three-input mux per bit to the address, data and byte enables. The core
 * cannot be given less than that while anything else reaches this RAM.
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

    //The one buffered access. `bus_pend` is the whole of the bus's request to
    //the RAM: one register, so that the core's enable reaches the RAM through a
    //two-input OR and nothing else. `cur_addr` is its address, and advances
    //when the access is served rather than when it is accepted, so it names
    //what the RAM is being given this cycle for both reads and writes.
    //`wr_strb` is zero unless the pending access is a write, which keeps the
    //write-enable mux down to one select and two data bits per byte lane.
    logic bus_pend;
    logic wr_last;
    logic [3:0] wr_strb;
    logic [31:0] wr_data;

    // The core takes the port whenever it asks for it; the bus gets what is
    // left. This is the whole arbitration policy.
    logic port_free, bus_served;
    assign port_free = ~core_en;
    assign bus_served = bus_pend & port_free;

    assign s_axi_awready = (state == IDLE) & s_axi_awvalid;
    assign s_axi_arready = (state == IDLE) & s_axi_arvalid & ~s_axi_awvalid;

    //Room for a beat means the buffer is empty, and nothing more. No AXI
    //output here is a function of `core_en`.
    //
    //It is tempting to also accept a beat in the cycle the buffered one is
    //being served, which keeps a burst running at a beat per cycle. That is
    //what `port_free` in this expression bought, and it cost 0.42 ns: the
    //core's enable then appears in the W handshake, Vivado factors the two
    //cones together, and the LUTs that compute `s_axi_wready` end up in the
    //middle of the core's own path from the load-store unit to the RAM's
    //enable pin -- where they are visible in report_timing by name. One beat
    //every other cycle is not a cost worth a nanosecond of the core's path to
    //memory, on an interface clocked by a JTAG scan.
    assign s_axi_wready = (state == WRITE) & ~bus_pend;

    assign s_axi_bresp = 2'b00;   //the RAM always answers
    assign s_axi_rresp = 2'b00;
    assign s_axi_bid = cur_id;
    assign s_axi_rid = cur_id;

    //Everything the bus contributes here is a register, and `core_en` is the
    //only late signal: a two-input OR to the enable, a three-input mux per bit
    //to the rest. There is nothing else in the way of the core.
    assign ram_en = core_en | bus_pend;
    assign ram_addr = core_en ? core_addr : cur_addr;
    assign ram_wdata = core_en ? core_wdata : wr_data;
    assign ram_wbe = core_en ? core_be : wr_strb;

    // Only ever sampled by the core in a cycle it held the port.
    assign core_rdata = ram_rdata;

    // Only the things that must come up idle are reset: the state, the two
    // response valids, which are outputs that may not assert on their own, and
    // the two things that drive the RAM directly -- a stale bus_pend or
    // wr_strb out of reset would put a word into the RAM nobody asked for.
    // Everything else here is datapath -- the address, the beat count, the ID,
    // the buffered write data and the read data are all loaded from a request
    // before anything reads them, so their value out of reset is never
    // observed. wr_last is loaded with the beat it describes.
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
            bus_pend <= 0;
            wr_strb <= 0;
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
                        bus_pend <= 1;   //the read is asked for on arrival
                        state <= READ;
                    end
                end

                //A beat is accepted into the buffer, and served to the RAM in
                //some later cycle the core leaves idle. The two cannot happen
                //at once -- wready is closed while bus_pend is set -- so the
                //branches here are exclusive and need no ordering.
                WRITE : begin
                    if (bus_served) begin
                        bus_pend <= 0;
                        wr_strb <= 0;
                        cur_addr <= cur_addr + 1;
                        if (wr_last) begin
                            s_axi_bvalid <= 1;
                            state <= WRESP;
                        end
                    end
                    else if (s_axi_wvalid & s_axi_wready) begin
                        bus_pend <= 1;
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

                READ : if (bus_served) begin
                    bus_pend <= 0;
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
                            bus_pend <= 1;   //ask for the next word
                            state <= READ;
                        end
                    end
                end

                default : begin
                    bus_pend <= 0;
                    wr_strb <= 0;
                    state <= IDLE;
                end
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
