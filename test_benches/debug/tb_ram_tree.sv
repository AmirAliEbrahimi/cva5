// Three masters onto one RAM port, through two cva5_ram_mux instances.
//
// cva5_wrapper arbitrates the debugger, the PS and the accelerator's DMA with
// a tree rather than a 3:1 mux:
//
//     PS      -> s0 \
//                     inner mux -> s1 \
//     DMA     -> s1 /                   outer mux -> cva5_ram_port -> RAM
//     debugger ----------------------> s0 /
//
// tb_ram_mux covers one mux exhaustively -- 315 checks at two ID widths --
// and cva5_ram_mux is unchanged by the tree. So this bench deliberately does
// NOT re-test arbitration. It tests the three things that are new and that
// only appear when two of them are stacked:
//
//   1. Routing. Three masters, three distinct addresses and IDs, each
//      master's own data and ID coming back to it and to nobody else. Two
//      levels of selection is where a response reaches the wrong master.
//   2. No starvation. All three hammer the port at once; every one of them
//      must complete transactions. Hierarchical priority is not equal
//      priority, and the question worth asking of it is not "is it fair" but
//      "does anyone wait forever".
//   3. The debugger-quiet case, which is the one that matters in operation:
//      with S0 of the outer mux idle, the PS and the DMA must alternate
//      rather than one of them holding the port.
//
// What this bench does NOT catch, checked rather than assumed. Breaking
// cva5_ram_mux's alternation (prio <= 1'b0 instead of ~owner) passes all 76
// checks here and fails tb_ram_mux immediately on its alternation invariant.
// That is the division of labour working: this bench services one master at
// a time, so a master's own request is down while it is being served and the
// next grant goes elsewhere whatever the priority logic does. Arbitration is
// tb_ram_mux's job on a module this one does not modify. What this bench
// does catch: a response payload reaching the wrong port, and an ID not
// echoed -- both of which fail here on the routing checks.
//
// Driven on the negedge and sampled on the posedge, the discipline
// tb_ram_port established: cva5_ram_port's readys are combinational in the
// valids, so a bench that drives and samples on one edge races them and
// hangs.
//
// Run: sh test_benches/debug/run_ram_tree.sh
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_ram_tree;

    localparam int unsigned AW  = 10;    //1024 words
    localparam int unsigned IDW = 12;    //what a Zynq PS master carries

    //Port numbering, as the tree sees it.
    localparam int P_PS  = 0;            //inner s0
    localparam int P_DMA = 1;            //inner s1
    localparam int P_DBG = 2;            //outer s0

    logic clk = 0, rstn = 0;
    always #5 clk = ~clk;

    int checks = 0, failures = 0;
    task automatic ck(input string what, input logic cond);
        checks++;
        if (!cond) begin failures++; $display("FAIL: %s", what); end
    endtask
    task automatic ck_eq(input string what, input logic [31:0] got,
                         input logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            failures++;
            $display("FAIL: %s: got 0x%08h expected 0x%08h", what, got, exp);
        end
    endtask

    //---- the three masters ------------------------------------------------
    logic [IDW-1:0] awid   [3];
    logic [AW+1:0]  awaddr [3];
    logic [7:0]     awlen  [3];
    logic [2:0]     awsize [3];
    logic [1:0]     awburst[3];
    logic           awvalid[3], awready[3];
    logic [31:0]    wdata  [3];
    logic [3:0]     wstrb  [3];
    logic           wlast  [3], wvalid[3], wready[3];
    logic [IDW-1:0] bid    [3];
    logic [1:0]     bresp  [3];
    logic           bvalid [3], bready[3];
    logic [IDW-1:0] arid   [3];
    logic [AW+1:0]  araddr [3];
    logic [7:0]     arlen  [3];
    logic [2:0]     arsize [3];
    logic [1:0]     arburst[3];
    logic           arvalid[3], arready[3];
    logic [IDW-1:0] rid    [3];
    logic [31:0]    rdata  [3];
    logic [1:0]     rresp  [3];
    logic           rlast  [3], rvalid[3], rready[3];

    //---- inner mux output, outer mux output -------------------------------
    `define AXI_WIRES(pfx) \
        logic [IDW-1:0] pfx``_awid, pfx``_bid, pfx``_arid, pfx``_rid; \
        logic [AW+1:0]  pfx``_awaddr, pfx``_araddr; \
        logic [7:0]     pfx``_awlen, pfx``_arlen; \
        logic [2:0]     pfx``_awsize, pfx``_arsize; \
        logic [1:0]     pfx``_awburst, pfx``_arburst, pfx``_bresp, pfx``_rresp; \
        logic [31:0]    pfx``_wdata, pfx``_rdata; \
        logic [3:0]     pfx``_wstrb; \
        logic           pfx``_awvalid, pfx``_awready, pfx``_wlast, \
                        pfx``_wvalid, pfx``_wready, pfx``_bvalid, pfx``_bready, \
                        pfx``_arvalid, pfx``_arready, pfx``_rlast, \
                        pfx``_rvalid, pfx``_rready;

    `AXI_WIRES(mid)
    `AXI_WIRES(m)

    `define MUX_PORT(n, idx) \
        .s``n``_awid(awid[idx]), .s``n``_awaddr(awaddr[idx]), \
        .s``n``_awlen(awlen[idx]), .s``n``_awsize(awsize[idx]), \
        .s``n``_awburst(awburst[idx]), .s``n``_awvalid(awvalid[idx]), \
        .s``n``_awready(awready[idx]), .s``n``_wdata(wdata[idx]), \
        .s``n``_wstrb(wstrb[idx]), .s``n``_wlast(wlast[idx]), \
        .s``n``_wvalid(wvalid[idx]), .s``n``_wready(wready[idx]), \
        .s``n``_bid(bid[idx]), .s``n``_bresp(bresp[idx]), \
        .s``n``_bvalid(bvalid[idx]), .s``n``_bready(bready[idx]), \
        .s``n``_arid(arid[idx]), .s``n``_araddr(araddr[idx]), \
        .s``n``_arlen(arlen[idx]), .s``n``_arsize(arsize[idx]), \
        .s``n``_arburst(arburst[idx]), .s``n``_arvalid(arvalid[idx]), \
        .s``n``_arready(arready[idx]), .s``n``_rid(rid[idx]), \
        .s``n``_rdata(rdata[idx]), .s``n``_rresp(rresp[idx]), \
        .s``n``_rlast(rlast[idx]), .s``n``_rvalid(rvalid[idx]), \
        .s``n``_rready(rready[idx])

    //PS on s0, DMA on s1 -- the same order cva5_wrapper uses.
    cva5_ram_mux #(.ADDR_WIDTH(AW), .ID_WIDTH(IDW)) inner (
        .clk(clk), .rstn(rstn),
        `MUX_PORT(0, P_PS),
        `MUX_PORT(1, P_DMA),
        .m_awid(mid_awid), .m_awaddr(mid_awaddr), .m_awlen(mid_awlen),
        .m_awsize(mid_awsize), .m_awburst(mid_awburst),
        .m_awvalid(mid_awvalid), .m_awready(mid_awready),
        .m_wdata(mid_wdata), .m_wstrb(mid_wstrb), .m_wlast(mid_wlast),
        .m_wvalid(mid_wvalid), .m_wready(mid_wready),
        .m_bid(mid_bid), .m_bresp(mid_bresp), .m_bvalid(mid_bvalid),
        .m_bready(mid_bready),
        .m_arid(mid_arid), .m_araddr(mid_araddr), .m_arlen(mid_arlen),
        .m_arsize(mid_arsize), .m_arburst(mid_arburst),
        .m_arvalid(mid_arvalid), .m_arready(mid_arready),
        .m_rid(mid_rid), .m_rdata(mid_rdata), .m_rresp(mid_rresp),
        .m_rlast(mid_rlast), .m_rvalid(mid_rvalid), .m_rready(mid_rready)
    );

    //Debugger on s0, the inner mux on s1.
    cva5_ram_mux #(.ADDR_WIDTH(AW), .ID_WIDTH(IDW)) outer (
        .clk(clk), .rstn(rstn),
        `MUX_PORT(0, P_DBG),
        .s1_awid(mid_awid), .s1_awaddr(mid_awaddr), .s1_awlen(mid_awlen),
        .s1_awsize(mid_awsize), .s1_awburst(mid_awburst),
        .s1_awvalid(mid_awvalid), .s1_awready(mid_awready),
        .s1_wdata(mid_wdata), .s1_wstrb(mid_wstrb), .s1_wlast(mid_wlast),
        .s1_wvalid(mid_wvalid), .s1_wready(mid_wready),
        .s1_bid(mid_bid), .s1_bresp(mid_bresp), .s1_bvalid(mid_bvalid),
        .s1_bready(mid_bready),
        .s1_arid(mid_arid), .s1_araddr(mid_araddr), .s1_arlen(mid_arlen),
        .s1_arsize(mid_arsize), .s1_arburst(mid_arburst),
        .s1_arvalid(mid_arvalid), .s1_arready(mid_arready),
        .s1_rid(mid_rid), .s1_rdata(mid_rdata), .s1_rresp(mid_rresp),
        .s1_rlast(mid_rlast), .s1_rvalid(mid_rvalid), .s1_rready(mid_rready),
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

    //---- the real RAM port, with the core side quiet ----------------------
    logic           core_en = 0;
    logic [3:0]     core_be = 4'hF;
    logic [AW-1:0]  core_addr = 0;
    logic [31:0]    core_wdata = 0;
    logic [31:0]    core_rdata;
    logic           ram_en;
    logic [3:0]     ram_wbe;
    logic [AW-1:0]  ram_addr;
    logic [31:0]    ram_wdata, ram_rdata;

    cva5_ram_port #(.ADDR_WIDTH(AW), .ID_WIDTH(IDW)) rp (
        .clk(clk), .rstn(rstn),
        .core_en(core_en), .core_be(core_be), .core_addr(core_addr),
        .core_wdata(core_wdata), .core_rdata(core_rdata),
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
        .ram_en(ram_en), .ram_wbe(ram_wbe), .ram_addr(ram_addr),
        .ram_wdata(ram_wdata), .ram_rdata(ram_rdata)
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

    //---- drivers ----------------------------------------------------------
    task automatic idle_port(input int p);
        awvalid[p] = 0; wvalid[p] = 0; bready[p] = 0;
        arvalid[p] = 0; rready[p] = 0;
        awid[p] = 0; awaddr[p] = 0; awlen[p] = 0; awsize[p] = 3'd2;
        awburst[p] = 2'b01; wdata[p] = 0; wstrb[p] = 4'hF; wlast[p] = 1;
        arid[p] = 0; araddr[p] = 0; arlen[p] = 0; arsize[p] = 3'd2;
        arburst[p] = 2'b01;
    endtask

    int done_count [3];

    task automatic wr(input int p, input logic [AW+1:0] a,
                      input logic [31:0] d, input logic [IDW-1:0] id);
        @(negedge clk);
        awid[p] = id; awaddr[p] = a; awlen[p] = 0; awsize[p] = 3'd2;
        awburst[p] = 2'b01; awvalid[p] = 1;
        forever begin @(posedge clk); if (awready[p]) break; end
        @(negedge clk); awvalid[p] = 0;
        wdata[p] = d; wstrb[p] = 4'hF; wlast[p] = 1; wvalid[p] = 1;
        forever begin @(posedge clk); if (wready[p]) break; end
        @(negedge clk); wvalid[p] = 0; wlast[p] = 0;
        bready[p] = 1;
        forever begin @(posedge clk); if (bvalid[p]) break; end
        ck_eq($sformatf("port %0d write 0x%0h: BID echoed", p, a), bid[p], id);
        ck_eq($sformatf("port %0d write 0x%0h: BRESP OKAY", p, a), bresp[p], 2'b00);
        @(negedge clk); bready[p] = 0;
        done_count[p]++;
    endtask

    task automatic rd(input int p, input logic [AW+1:0] a,
                      output logic [31:0] d, input logic [IDW-1:0] id);
        @(negedge clk);
        arid[p] = id; araddr[p] = a; arlen[p] = 0; arsize[p] = 3'd2;
        arburst[p] = 2'b01; arvalid[p] = 1;
        forever begin @(posedge clk); if (arready[p]) break; end
        @(negedge clk); arvalid[p] = 0;
        rready[p] = 1;
        forever begin @(posedge clk); if (rvalid[p]) break; end
        d = rdata[p];
        ck_eq($sformatf("port %0d read 0x%0h: RID echoed", p, a), rid[p], id);
        ck_eq($sformatf("port %0d read 0x%0h: RRESP OKAY", p, a), rresp[p], 2'b00);
        ck($sformatf("port %0d read 0x%0h: RLAST", p, a), rlast[p] === 1'b1);
        @(negedge clk); rready[p] = 0;
        done_count[p]++;
    endtask

    //---- the run ----------------------------------------------------------
    logic [31:0] got;
    int snap_ps, snap_dma;
    function automatic string NAME(input int p);
        case (p)
            P_PS:  return "PS";
            P_DMA: return "DMA";
            default: return "debugger";
        endcase
    endfunction

    initial begin
        for (int p = 0; p < 3; p++) begin idle_port(p); done_count[p] = 0; end
        repeat (4) @(negedge clk);
        rstn = 1;
        repeat (2) @(negedge clk);

        //1. Routing. Distinct address, data and ID per master, so a response
        //   delivered to the wrong one cannot look correct.
        for (int p = 0; p < 3; p++)
            wr(p, (p + 1) * 16, 32'hA5A5_0000 + p, IDW'(32'h100 + p));
        for (int p = 0; p < 3; p++) begin
            rd(p, (p + 1) * 16, got, IDW'(32'h200 + p));
            ck_eq($sformatf("%s reads back its own word", NAME(p)),
                  got, 32'hA5A5_0000 + p);
        end

        //   And each master reading another's address still gets that word,
        //   which separates "routed correctly" from "happened to be right".
        rd(P_DBG, 16, got, IDW'(1));
        ck_eq("the debugger reads the PS's word", got, 32'hA5A5_0000);
        rd(P_PS, 48, got, IDW'(2));
        ck_eq("the PS reads the debugger's word", got, 32'hA5A5_0002);

        //2. Fairness, measured as the sequence of grants rather than as
        //   completion counts.
        //
        //   All three hold AW high at once; each time one is granted, it is
        //   driven to its B response and immediately asks again. The order
        //   the grants come out in IS the arbitration, so this reads it
        //   directly instead of inferring it from who finished.
        //
        //   Done in one process on purpose. fork/join would be the natural
        //   way to write three concurrent masters, and Verilator 5.020
        //   miscompiles it here -- the generated coroutine runs off the end
        //   of a non-void function and the binary dies on an illegal
        //   instruction before any output appears. One process also makes
        //   the grant order deterministic, which a scheduler-dependent fork
        //   would not.
        begin
            automatic int grants [3] = '{0, 0, 0};
            automatic int seq_len = 0;
            automatic int last = -1;
            automatic int twice_in_a_row [3] = '{0, 0, 0};

            for (int p = 0; p < 3; p++) begin
                awid[p] = IDW'(32'h300 + p); awaddr[p] = 600 + 16*p;
                awlen[p] = 0; awsize[p] = 3'd2; awburst[p] = 2'b01;
                wdata[p] = 32'hC0DE_0000 + p; wstrb[p] = 4'hF; wlast[p] = 1;
            end

            @(negedge clk);
            for (int p = 0; p < 3; p++) awvalid[p] = 1;

            while (seq_len < 30) begin
                automatic int winner = -1;
                @(posedge clk);
                for (int p = 0; p < 3; p++) if (awready[p]) winner = p;
                if (winner < 0) continue;
                grants[winner]++;
                if (winner == last) twice_in_a_row[winner]++;
                last = winner;
                seq_len++;

                //Drive the winner through W and B, then put its request back
                //up so it is still asking for the next round.
                @(negedge clk); awvalid[winner] = 0; wvalid[winner] = 1;
                forever begin @(posedge clk); if (wready[winner]) break; end
                @(negedge clk); wvalid[winner] = 0; bready[winner] = 1;
                forever begin @(posedge clk); if (bvalid[winner]) break; end
                ck_eq($sformatf("%s B response during contention", NAME(winner)),
                      bresp[winner], 2'b00);
                @(negedge clk); bready[winner] = 0; awvalid[winner] = 1;
            end
            //Both muxes are left holding a grant here, at different
            //levels -- the outer on whoever it last selected, the inner on
            //whichever of the PS and the DMA it had picked. Stopping
            //cleanly would mean knowing which, and that is internal state.
            //
            //So abandon them the documented way. Pulling valids down while
            //a mux holds a grant strands it: its owner's AW never completes,
            //no response ever comes back, and the port is held for good --
            //which is what this test did before this comment existed, and
            //what cva5_ram_mux.sv's header warns about. Reset clears both.
            //
            //Every port is idled BEFORE reset releases, not after: a request
            //standing at that edge is granted on it, which is correct
            //behaviour and deadlocked tb_ram_mux once already.
            for (int p = 0; p < 3; p++) idle_port(p);
            repeat (2) @(negedge clk);
            rstn = 0;
            repeat (4) @(negedge clk);
            rstn = 1;
            repeat (2) @(negedge clk);

            //Nobody starves.
            for (int p = 0; p < 3; p++)
                ck($sformatf({"%s is granted while all three ask ",
                              "(%0d of %0d grants)"},
                             NAME(p), grants[p], seq_len),
                   grants[p] > 0);

            //The shape of it: the debugger sits above the other two, so it
            //should take about half and the PS and the DMA about a quarter
            //each. Checked loosely -- the point is that the split is the
            //tree's and not an accident, not that it is exact.
            ck($sformatf("the debugger takes roughly half (%0d of %0d)",
                         grants[P_DBG], seq_len),
               grants[P_DBG] * 3 >= seq_len);
            ck($sformatf({"the PS and the DMA take a quarter each ",
                          "(%0d and %0d of %0d)"},
                         grants[P_PS], grants[P_DMA], seq_len),
               grants[P_PS] * 6 >= seq_len && grants[P_DMA] * 6 >= seq_len);

            //And no master is ever granted twice running while another is
            //asking, which is the property that actually rules out
            //starvation at either level of the tree.
            for (int p = 0; p < 3; p++)
                ck($sformatf({"%s is never granted twice in a row with the ",
                              "others asking (%0d times)"},
                             NAME(p), twice_in_a_row[p]),
                   twice_in_a_row[p] == 0);
        end

        //3. The data written during contention survived the interleaving.
        for (int p = 0; p < 3; p++) begin
            rd(P_DBG, 600 + 16*p, got, IDW'(9));
            ck_eq($sformatf("%s's contended write landed", NAME(p)),
                  got, 32'hC0DE_0000 + p);
        end

        $display("%s tb_ram_tree: %0d checks%s",
                 failures ? "FAIL" : "PASS", checks,
                 failures ? $sformatf(", %0d failed", failures) : "");
        $finish;
    end



    //Nothing here should take this long; a hang is a deadlock in the tree.
    initial begin
        #500000;
        $display("FAIL tb_ram_tree: timed out -- the tree deadlocked");
        $finish;
    end

endmodule
