// tb_ram_mux -- two AXI4 masters sharing the RAM port through cva5_ram_mux.
//
// The mux sits in front of the real cva5_ram_port, with a memory model behind
// it that behaves the way tdp_ram does: enable now, data next cycle, no
// handshake. So what is under test is the whole path a PS or a DMA would take
// into main memory, not the mux alone.
//
// What it checks:
//   - each port on its own, write then read back
//   - the two ports see the same memory
//   - both asking at once: both complete, neither loses data
//   - priority alternates, so neither port can be starved
//   - a continuous writer on one port does not starve a read on the other
//   - a read burst holds the port to RLAST
//   - the port that does not hold the mux sees no handshake
//   - IDs come back to the right master
//   - the core keeps the RAM port when it wants it, and the bus still
//     completes afterwards
//   - reset releases the port
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_ram_mux;

    localparam int unsigned AW = 10;          //1024 words, enough for this
    localparam int unsigned IDW = 8;

    logic clk = 0;
    logic rstn = 0;
    always #5 clk = ~clk;

    int checks = 0;
    int fails  = 0;

    task automatic ck(input string what, input logic cond);
        checks++;
        if (!cond) begin
            fails++;
            $error("FAIL %s", what);
        end
    endtask

    task automatic ck_eq(input string what, input logic [31:0] got,
                                            input logic [31:0] want);
        checks++;
        if (got !== want) begin
            fails++;
            $error("FAIL %s: got 0x%08x expected 0x%08x", what, got, want);
        end
    endtask

    //================================================================
    // Two master-side port bundles, as arrays so the tasks can take an index
    //================================================================
    logic [IDW-1:0]  awid   [2];
    logic [AW+1:0]   awaddr [2];
    logic [7:0]      awlen  [2];
    logic [2:0]      awsize [2];
    logic [1:0]      awburst[2];
    logic            awvalid[2];
    logic            awready[2];
    logic [31:0]     wdata  [2];
    logic [3:0]      wstrb  [2];
    logic            wlast  [2];
    logic            wvalid [2];
    logic            wready [2];
    logic [IDW-1:0]  bid    [2];
    logic [1:0]      bresp  [2];
    logic            bvalid [2];
    logic            bready [2];
    logic [IDW-1:0]  arid   [2];
    logic [AW+1:0]   araddr [2];
    logic [7:0]      arlen  [2];
    logic [2:0]      arsize [2];
    logic [1:0]      arburst[2];
    logic            arvalid[2];
    logic            arready[2];
    logic [IDW-1:0]  rid    [2];
    logic [31:0]     rdata  [2];
    logic [1:0]      rresp  [2];
    logic            rlast  [2];
    logic            rvalid [2];
    logic            rready [2];

    //---- mux -> ram port -------------------------------------------------
    logic [IDW-1:0] m_awid, m_bid, m_arid, m_rid;
    logic [AW+1:0]  m_awaddr, m_araddr;
    logic [7:0]     m_awlen, m_arlen;
    logic [2:0]     m_awsize, m_arsize;
    logic [1:0]     m_awburst, m_arburst, m_bresp, m_rresp;
    logic           m_awvalid, m_awready, m_wvalid, m_wready, m_wlast;
    logic           m_bvalid, m_bready, m_arvalid, m_arready;
    logic           m_rvalid, m_rready, m_rlast;
    logic [31:0]    m_wdata, m_rdata;
    logic [3:0]     m_wstrb;

    cva5_ram_mux #(.ADDR_WIDTH(AW), .ID_WIDTH(IDW)) dut (
        .clk (clk), .rstn (rstn),

        .s0_awid(awid[0]), .s0_awaddr(awaddr[0]), .s0_awlen(awlen[0]),
        .s0_awsize(awsize[0]), .s0_awburst(awburst[0]),
        .s0_awvalid(awvalid[0]), .s0_awready(awready[0]),
        .s0_wdata(wdata[0]), .s0_wstrb(wstrb[0]), .s0_wlast(wlast[0]),
        .s0_wvalid(wvalid[0]), .s0_wready(wready[0]),
        .s0_bid(bid[0]), .s0_bresp(bresp[0]), .s0_bvalid(bvalid[0]),
        .s0_bready(bready[0]),
        .s0_arid(arid[0]), .s0_araddr(araddr[0]), .s0_arlen(arlen[0]),
        .s0_arsize(arsize[0]), .s0_arburst(arburst[0]),
        .s0_arvalid(arvalid[0]), .s0_arready(arready[0]),
        .s0_rid(rid[0]), .s0_rdata(rdata[0]), .s0_rresp(rresp[0]),
        .s0_rlast(rlast[0]), .s0_rvalid(rvalid[0]), .s0_rready(rready[0]),

        .s1_awid(awid[1]), .s1_awaddr(awaddr[1]), .s1_awlen(awlen[1]),
        .s1_awsize(awsize[1]), .s1_awburst(awburst[1]),
        .s1_awvalid(awvalid[1]), .s1_awready(awready[1]),
        .s1_wdata(wdata[1]), .s1_wstrb(wstrb[1]), .s1_wlast(wlast[1]),
        .s1_wvalid(wvalid[1]), .s1_wready(wready[1]),
        .s1_bid(bid[1]), .s1_bresp(bresp[1]), .s1_bvalid(bvalid[1]),
        .s1_bready(bready[1]),
        .s1_arid(arid[1]), .s1_araddr(araddr[1]), .s1_arlen(arlen[1]),
        .s1_arsize(arsize[1]), .s1_arburst(arburst[1]),
        .s1_arvalid(arvalid[1]), .s1_arready(arready[1]),
        .s1_rid(rid[1]), .s1_rdata(rdata[1]), .s1_rresp(rresp[1]),
        .s1_rlast(rlast[1]), .s1_rvalid(rvalid[1]), .s1_rready(rready[1]),

        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen),
        .m_awsize(m_awsize), .m_awburst(m_awburst),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
        .m_bready(m_bready),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen),
        .m_arsize(m_arsize), .m_arburst(m_arburst),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp),
        .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready)
    );

    //---- the real RAM port, and the core side of it -----------------------
    logic            core_en = 0;
    logic [3:0]      core_be = 4'hF;
    logic [AW-1:0]   core_addr = 0;
    logic [31:0]     core_wdata = 0;
    logic [31:0]     core_rdata;

    logic            ram_en;
    logic [3:0]      ram_wbe;
    logic [AW-1:0]   ram_addr;
    logic [31:0]     ram_wdata;
    logic [31:0]     ram_rdata;

    cva5_ram_port #(.ADDR_WIDTH(AW), .ID_WIDTH(IDW)) rp (
        .clk (clk), .rstn (rstn),
        .core_en (core_en), .core_be (core_be), .core_addr (core_addr),
        .core_wdata (core_wdata), .core_rdata (core_rdata),
        .s_axi_awid(m_awid), .s_axi_awaddr(m_awaddr), .s_axi_awlen(m_awlen),
        .s_axi_awsize(m_awsize), .s_axi_awburst(m_awburst),
        .s_axi_awvalid(m_awvalid), .s_axi_awready(m_awready),
        .s_axi_wdata(m_wdata), .s_axi_wstrb(m_wstrb), .s_axi_wlast(m_wlast),
        .s_axi_wvalid(m_wvalid), .s_axi_wready(m_wready),
        .s_axi_bid(m_bid), .s_axi_bresp(m_bresp), .s_axi_bvalid(m_bvalid),
        .s_axi_bready(m_bready),
        .s_axi_arid(m_arid), .s_axi_araddr(m_araddr), .s_axi_arlen(m_arlen),
        .s_axi_arsize(m_arsize), .s_axi_arburst(m_arburst),
        .s_axi_arvalid(m_arvalid), .s_axi_arready(m_arready),
        .s_axi_rid(m_rid), .s_axi_rdata(m_rdata), .s_axi_rresp(m_rresp),
        .s_axi_rlast(m_rlast), .s_axi_rvalid(m_rvalid), .s_axi_rready(m_rready),
        .ram_en (ram_en), .ram_wbe (ram_wbe), .ram_addr (ram_addr),
        .ram_wdata (ram_wdata), .ram_rdata (ram_rdata)
    );

    //Behaves like tdp_ram's port: enable now, data next cycle.
    logic [31:0] mem [(1<<AW)-1:0];
    always_ff @(posedge clk) begin
        if (ram_en) begin
            for (int b = 0; b < 4; b++)
                if (ram_wbe[b]) mem[ram_addr][b*8 +: 8] <= ram_wdata[b*8 +: 8];
            ram_rdata <= mem[ram_addr];
        end
    end

    //================================================================
    // Master drivers
    //================================================================
    task automatic idle_port(input int p);
        awvalid[p] = 0; wvalid[p] = 0; bready[p] = 0;
        arvalid[p] = 0; rready[p] = 0;
        awid[p] = 0; awaddr[p] = 0; awlen[p] = 0; awsize[p] = 3'd2;
        awburst[p] = 2'b01; wdata[p] = 0; wstrb[p] = 4'hF; wlast[p] = 1;
        arid[p] = 0; araddr[p] = 0; arlen[p] = 0; arsize[p] = 3'd2;
        arburst[p] = 2'b01;
    endtask

    //Driven on the negedge, handshakes sampled on the posedge, which is the
    //discipline tb_ram_port established against this same RAM port: its
    //readys are combinational in the valids, so a bench that drives and
    //samples on the same edge races them and hangs.
    task automatic wr(input int p, input logic [AW+1:0] a,
                      input logic [31:0] d, input logic [IDW-1:0] id = 0);
        @(negedge clk);
        awid[p] = id; awaddr[p] = a; awlen[p] = 0; awsize[p] = 3'd2;
        awburst[p] = 2'b01; awvalid[p] = 1;
        forever begin @(posedge clk); if (awready[p]) break; end
        @(negedge clk);
        awvalid[p] = 0;

        wdata[p] = d; wstrb[p] = 4'hF; wlast[p] = 1; wvalid[p] = 1;
        forever begin @(posedge clk); if (wready[p]) break; end
        @(negedge clk);
        wvalid[p] = 0; wlast[p] = 0;

        bready[p] = 1;
        forever begin @(posedge clk); if (bvalid[p]) break; end
        ck_eq($sformatf("port %0d write 0x%0h: BID", p, a), bid[p], id);
        ck_eq($sformatf("port %0d write 0x%0h: BRESP", p, a), bresp[p], 2'b00);
        @(negedge clk);
        bready[p] = 0;
    endtask

    task automatic rd(input int p, input logic [AW+1:0] a,
                      output logic [31:0] d, input logic [IDW-1:0] id = 0);
        @(negedge clk);
        arid[p] = id; araddr[p] = a; arlen[p] = 0; arsize[p] = 3'd2;
        arburst[p] = 2'b01; arvalid[p] = 1;
        forever begin @(posedge clk); if (arready[p]) break; end
        @(negedge clk);
        arvalid[p] = 0;

        rready[p] = 1;
        forever begin @(posedge clk); if (rvalid[p]) break; end
        d = rdata[p];
        ck_eq($sformatf("port %0d read 0x%0h: RID", p, a), rid[p], id);
        ck_eq($sformatf("port %0d read 0x%0h: RRESP", p, a), rresp[p], 2'b00);
        ck($sformatf("port %0d read 0x%0h: RLAST on a single beat", p, a),
           rlast[p] === 1'b1);
        @(negedge clk);
        rready[p] = 0;
    endtask

    task automatic rd_burst(input int p, input logic [AW+1:0] a,
                            input int n, input logic [IDW-1:0] id = 0);
        int beats;
        @(negedge clk);
        arid[p] = id; araddr[p] = a; arlen[p] = n - 1; arsize[p] = 3'd2;
        arburst[p] = 2'b01; arvalid[p] = 1;
        forever begin @(posedge clk); if (arready[p]) break; end
        @(negedge clk);
        arvalid[p] = 0;

        rready[p] = 1;
        for (beats = 0; beats < n; beats++) begin
            forever begin @(posedge clk); if (rvalid[p]) break; end
            ck_eq($sformatf("port %0d burst beat %0d", p, beats),
                  rdata[p], 32'hB000_0000 + beats);
            ck($sformatf("port %0d burst beat %0d: RLAST only on the last",
                         p, beats),
               rlast[p] === (beats == n - 1));
            //The other port must see no handshake while this burst holds the
            //mux: that is the grant being held to RLAST rather than released
            //between beats.
            ck($sformatf("port %0d burst beat %0d: other port not served",
                         p, beats),
               (rvalid[1-p] === 1'b0) && (awready[1-p] === 1'b0) &&
               (arready[1-p] === 1'b0));
            @(negedge clk);
        end
        rready[p] = 0;
    endtask

    //================================================================
    // Stimulus
    //================================================================
    logic [31:0] d0, d1;
    int           n0, n1;

    initial begin
        idle_port(0);
        idle_port(1);
        repeat (4) @(posedge clk);
        rstn = 1;
        repeat (2) @(posedge clk);

        //---- each port alone ---------------------------------------
        $display("-- port 0 alone");
        wr(0, 'h010, 32'hDEAD_0001, 8'h11);
        rd(0, 'h010, d0, 8'h11);
        ck_eq("port 0 read back its own write", d0, 32'hDEAD_0001);

        $display("-- port 1 alone");
        wr(1, 'h020, 32'hBEEF_0002, 8'h22);
        rd(1, 'h020, d1, 8'h22);
        ck_eq("port 1 read back its own write", d1, 32'hBEEF_0002);

        //---- one memory, seen by both ------------------------------
        $display("-- shared memory");
        wr(0, 'h030, 32'h5A5A_0003, 8'h33);
        rd(1, 'h030, d1, 8'h44);
        ck_eq("port 1 sees port 0's write", d1, 32'h5A5A_0003);
        wr(1, 'h034, 32'hA5A5_0004, 8'h55);
        rd(0, 'h034, d0, 8'h66);
        ck_eq("port 0 sees port 1's write", d0, 32'hA5A5_0004);

        //---- both at once ------------------------------------------
        $display("-- simultaneous writes");
        fork
            wr(0, 'h040, 32'h0000_AAAA, 8'h01);
            wr(1, 'h044, 32'h0000_BBBB, 8'h02);
        join
        rd(0, 'h040, d0);
        ck_eq("port 0's write survived the collision", d0, 32'h0000_AAAA);
        rd(0, 'h044, d0);
        ck_eq("port 1's write survived the collision", d0, 32'h0000_BBBB);

        $display("-- simultaneous reads");
        fork
            rd(0, 'h040, d0, 8'h0A);
            rd(1, 'h044, d1, 8'h0B);
        join
        ck_eq("port 0 got its own read back", d0, 32'h0000_AAAA);
        ck_eq("port 1 got its own read back", d1, 32'h0000_BBBB);

        $display("-- a write against a read");
        fork
            wr(0, 'h048, 32'h0000_CCCC, 8'h0C);
            rd(1, 'h040, d1, 8'h0D);
        join
        ck_eq("the read was not corrupted by the write", d1, 32'h0000_AAAA);
        rd(0, 'h048, d0);
        ck_eq("the write landed", d0, 32'h0000_CCCC);

        //---- both ports contending, repeatedly ---------------------
        //The alternation itself is checked by the monitor at the bottom of
        //this file, on every transaction. This is here to give that monitor
        //ties to look at: without contention the priority never has to
        //decide anything.
        $display("-- repeated contention");
        for (int r = 0; r < 6; r++) begin
            fork
                wr(0, 'h060, 32'h1111_0000 + r, 8'h71);
                wr(1, 'h064, 32'h2222_0000 + r, 8'h72);
            join
        end
        rd(0, 'h060, d0);
        ck_eq("port 0's last contended write", d0, 32'h1111_0005);
        rd(1, 'h064, d1);
        ck_eq("port 1's last contended write", d1, 32'h2222_0005);

        //---- no starvation -----------------------------------------
        //Port 1 writes without pause; port 0 must still get its read in.
        //Without port-level alternation this never completes.
        $display("-- a continuous writer must not starve the other port");
        n1 = 0;
        fork
            begin
                for (int i = 0; i < 40; i++) begin
                    wr(1, 'h100 + (i*4), 32'hC000_0000 + i);
                    n1++;
                end
            end
            begin
                rd(0, 'h040, d0, 8'h7E);
                ck_eq("the starved read completed", d0, 32'h0000_AAAA);
            end
        join
        ck("the writer kept going too", n1 == 40);

        //---- bursts hold the port ----------------------------------
        $display("-- a read burst holds the port to RLAST");
        for (int i = 0; i < 8; i++)
            wr(0, 'h200 + (i*4), 32'hB000_0000 + i);
        fork
            rd_burst(1, 'h200, 8, 8'h5B);
            begin
                //Ask from the other port in the middle of the burst.
                repeat (3) @(posedge clk);
                rd(0, 'h040, d0, 8'h5C);
                ck_eq("the port that waited still got its data",
                      d0, 32'h0000_AAAA);
            end
        join

        //---- the core wins ------------------------------------------
        //cva5_ram_port gives the bus only the cycles the core leaves idle.
        //Hold the core on the port and the bus transaction must still finish
        //once it lets go.
        $display("-- the core keeps the port while it wants it");
        fork
            begin
                core_en = 1;
                core_addr = 'h080 >> 2;
                repeat (20) @(posedge clk);
                core_en = 0;
            end
            begin
                wr(1, 'h050, 32'h0000_EEEE, 8'h0E);
                rd(1, 'h050, d1, 8'h0F);
                ck_eq("the bus completed after the core let go",
                      d1, 32'h0000_EEEE);
            end
        join

        //---- reset releases the port --------------------------------
        //Park a read on port 1 that is never accepted, abort it with reset,
        //and check both ports work afterwards. The stimulus is withdrawn
        //while reset is still asserted and given a clock to settle: release
        //reset with a request still standing and the mux grants it on that
        //very edge, which is correct and is also how this bench deadlocked
        //itself while being written -- the master it granted had already been
        //idled and never took the data. See the note on held grants in
        //cva5_ram_mux.sv.
        $display("-- reset releases the port");
        @(negedge clk);
        arvalid[1] = 1; araddr[1] = 'h010; rready[1] = 0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rstn = 0;
        idle_port(0);
        idle_port(1);
        repeat (4) @(posedge clk);
        @(negedge clk);
        rstn = 1;
        repeat (2) @(posedge clk);
        //Both ports work again, and port 0 is served, which it would not be
        //if the owner register had come out of reset pointing at port 1.
        rd(0, 'h010, d0, 8'h99);
        ck_eq("port 0 works after reset", d0, 32'hDEAD_0001);
        rd(1, 'h020, d1, 8'h98);
        ck_eq("port 1 works after reset", d1, 32'hBEEF_0002);

        repeat (4) @(posedge clk);
        if (fails == 0) $display("PASS tb_ram_mux: %0d checks", checks);
        else            $display("FAIL tb_ram_mux: %0d of %0d checks failed",
                                 fails, checks);
        $finish;
    end

    //================================================================
    // Alternation, as an invariant rather than a scenario
    //================================================================
    // Every completed transaction must leave the priority pointing at the
    // other port. Checked here, on all of them, rather than by inferring the
    // grant order from written data: a round of two simultaneous writes
    // contains two transactions, so the priority flips twice and comes back
    // to where it started, and a data-based test sees the same winner each
    // round whether the design alternates or not. That is a test that passes
    // on a stuck priority, which is worse than no test.
    //
    // The starvation scenario above does not cover this either: whichever
    // port a stuck priority favours, the other is still served in the gaps
    // between the favoured port's transactions.
    logic pending = 0;
    logic exp_prio = 0;

    always @(posedge clk) begin
        if (!rstn) begin
            pending <= 0;
        end
        else begin
            if (pending) begin
                ck("the priority alternates after a completed transaction",
                   dut.prio === exp_prio);
                pending <= 0;
            end
            if (dut.busy && dut.done) begin
                exp_prio <= ~dut.owner;
                pending  <= 1;
            end
        end
    end

    //A hung handshake should not hang the run.
    initial begin
        #2_000_000;
        $display("FAIL tb_ram_mux (timeout)");
        $finish;
    end

endmodule
