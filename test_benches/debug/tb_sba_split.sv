/*
 * tb_sba_split -- the debugger's system bus, split by address, against the
 * real things on both sides of the split.
 *
 * The chain under test is the one the board has: riscv-dbg's SBA protocol into
 * dm_sba_axil, its AXI4-Lite master into cva5_sba_split, and from there either
 * cva5_ram_port driving a real tdp_ram, or out to a Lite peripheral. Only the
 * peripheral is a model; everything else is the RTL that ships.
 *
 * What this has to prove, because a wrong answer here breaks every program
 * load rather than one feature:
 *
 *   - a write inside the RAM window lands in the RAM, and nothing reaches the
 *     peripheral;
 *   - a write outside it reaches the peripheral, and the RAM is untouched;
 *   - reads come back from whichever side was addressed, with the right data;
 *   - a peripheral error response reaches the debugger as r_err, so OpenOCD
 *     sets sberror instead of reporting a successful write that vanished;
 *   - the core's load-store port, which cannot be stalled, still wins every
 *     collision, and the debugger's beat lands anyway once it gets a turn;
 *   - the registered response-phase select survives the core holding the RAM
 *     port off for many cycles, and alternating RAM and peripheral accesses do
 *     not leave it pointing at the previous destination.
 *
 * The addresses here are the board's: 0x8000_0000 for RAM (shrunk to 256 words
 * so the test runs quickly) and 0x1000_0000 for the peripheral.
 *
 * Run from the repo root:  sh test_benches/debug/run_sba_split.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps

module tb_sba_split;

    localparam int unsigned RAM_ADDR_W = 8;             //256 words
    localparam logic [31:0] RAM_BASE   = 32'h8000_0000;
    localparam logic [31:0] PERIPH     = 32'h1000_0000;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rstn = 0;

    int errors = 0;
    int checks = 0;

    task automatic expect_eq(input string what, input logic [31:0] got,
                             input logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            $error("%s: got 0x%08x expected 0x%08x", what, got, exp);
            errors++;
        end
    endtask

    //================================================================
    // SBA master side: the riscv-dbg request interface dm_sba drives
    //================================================================
    logic        sba_req = 0, sba_we = 0;
    logic [31:0] sba_addr = 0, sba_wdata = 0;
    logic [3:0]  sba_be = 4'hF;
    logic        sba_gnt, sba_rvalid, sba_rerr;
    logic [31:0] sba_rdata;

    // One transaction, the way dm_sba issues it: hold req until gnt, then wait
    // for the single r_valid.
    task automatic sba_xfer(input logic we, input logic [31:0] addr,
                            input logic [31:0] wdata, input logic [3:0] be = 4'hF);
        sba_we = we; sba_addr = addr; sba_wdata = wdata; sba_be = be;
        sba_req = 1;
        do @(negedge clk); while (!sba_gnt);
        sba_req = 0;
        while (!sba_rvalid) @(negedge clk);
        @(negedge clk);
    endtask

    logic [31:0] l_awaddr, l_wdata, l_araddr, l_rdata;
    logic [2:0]  l_awprot, l_arprot;
    logic [3:0]  l_wstrb;
    logic        l_awvalid, l_awready, l_wvalid, l_wready;
    logic [1:0]  l_bresp, l_rresp;
    logic        l_bvalid, l_bready, l_arvalid, l_arready, l_rvalid, l_rready;

    dm_sba_axil bridge (
        .clk (clk), .rst_n (rstn),
        .req_i (sba_req), .addr_i (sba_addr), .we_i (sba_we),
        .wdata_i (sba_wdata), .be_i (sba_be),
        .gnt_o (sba_gnt), .r_valid_o (sba_rvalid), .r_err_o (sba_rerr),
        .r_rdata_o (sba_rdata),
        .m_axi_awaddr (l_awaddr), .m_axi_awprot (l_awprot),
        .m_axi_awvalid (l_awvalid), .m_axi_awready (l_awready),
        .m_axi_wdata (l_wdata), .m_axi_wstrb (l_wstrb),
        .m_axi_wvalid (l_wvalid), .m_axi_wready (l_wready),
        .m_axi_bresp (l_bresp), .m_axi_bvalid (l_bvalid), .m_axi_bready (l_bready),
        .m_axi_araddr (l_araddr), .m_axi_arprot (l_arprot),
        .m_axi_arvalid (l_arvalid), .m_axi_arready (l_arready),
        .m_axi_rdata (l_rdata), .m_axi_rresp (l_rresp),
        .m_axi_rvalid (l_rvalid), .m_axi_rready (l_rready)
    );

    //================================================================
    // DUT
    //================================================================
    logic [7:0]            rp_awid, rp_arid, rp_bid, rp_rid;
    logic [RAM_ADDR_W+1:0] rp_awaddr, rp_araddr;
    logic [7:0]            rp_awlen, rp_arlen;
    logic [2:0]            rp_awsize, rp_arsize;
    logic [1:0]            rp_awburst, rp_arburst, rp_bresp, rp_rresp;
    logic                  rp_awvalid, rp_awready, rp_wvalid, rp_wready, rp_wlast;
    logic [31:0]           rp_wdata, rp_rdata;
    logic [3:0]            rp_wstrb;
    logic                  rp_bvalid, rp_bready, rp_arvalid, rp_arready;
    logic                  rp_rvalid, rp_rready, rp_rlast;

    logic [31:0] p_awaddr, p_wdata, p_araddr, p_rdata;
    logic [2:0]  p_awprot, p_arprot;
    logic [3:0]  p_wstrb;
    logic        p_awvalid, p_awready, p_wvalid, p_wready;
    logic [1:0]  p_bresp, p_rresp;
    logic        p_bvalid, p_bready, p_arvalid, p_arready, p_rvalid, p_rready;

    cva5_sba_split #(
        .RAM_BASE (RAM_BASE),
        .RAM_ADDR_W (RAM_ADDR_W),
        .ID_WIDTH (8)
    ) dut (
        .clk (clk), .rstn (rstn),

        .s_axi_awaddr (l_awaddr), .s_axi_awprot (l_awprot),
        .s_axi_awvalid (l_awvalid), .s_axi_awready (l_awready),
        .s_axi_wdata (l_wdata), .s_axi_wstrb (l_wstrb),
        .s_axi_wvalid (l_wvalid), .s_axi_wready (l_wready),
        .s_axi_bresp (l_bresp), .s_axi_bvalid (l_bvalid), .s_axi_bready (l_bready),
        .s_axi_araddr (l_araddr), .s_axi_arprot (l_arprot),
        .s_axi_arvalid (l_arvalid), .s_axi_arready (l_arready),
        .s_axi_rdata (l_rdata), .s_axi_rresp (l_rresp),
        .s_axi_rvalid (l_rvalid), .s_axi_rready (l_rready),

        .m_axi_ram_awid (rp_awid), .m_axi_ram_awaddr (rp_awaddr),
        .m_axi_ram_awlen (rp_awlen), .m_axi_ram_awsize (rp_awsize),
        .m_axi_ram_awburst (rp_awburst), .m_axi_ram_awvalid (rp_awvalid),
        .m_axi_ram_awready (rp_awready),
        .m_axi_ram_wdata (rp_wdata), .m_axi_ram_wstrb (rp_wstrb),
        .m_axi_ram_wlast (rp_wlast), .m_axi_ram_wvalid (rp_wvalid),
        .m_axi_ram_wready (rp_wready),
        .m_axi_ram_bid (rp_bid), .m_axi_ram_bresp (rp_bresp),
        .m_axi_ram_bvalid (rp_bvalid), .m_axi_ram_bready (rp_bready),
        .m_axi_ram_arid (rp_arid), .m_axi_ram_araddr (rp_araddr),
        .m_axi_ram_arlen (rp_arlen), .m_axi_ram_arsize (rp_arsize),
        .m_axi_ram_arburst (rp_arburst), .m_axi_ram_arvalid (rp_arvalid),
        .m_axi_ram_arready (rp_arready),
        .m_axi_ram_rid (rp_rid), .m_axi_ram_rdata (rp_rdata),
        .m_axi_ram_rresp (rp_rresp), .m_axi_ram_rlast (rp_rlast),
        .m_axi_ram_rvalid (rp_rvalid), .m_axi_ram_rready (rp_rready),

        .m_axi_dbg_awaddr (p_awaddr), .m_axi_dbg_awprot (p_awprot),
        .m_axi_dbg_awvalid (p_awvalid), .m_axi_dbg_awready (p_awready),
        .m_axi_dbg_wdata (p_wdata), .m_axi_dbg_wstrb (p_wstrb),
        .m_axi_dbg_wvalid (p_wvalid), .m_axi_dbg_wready (p_wready),
        .m_axi_dbg_bresp (p_bresp), .m_axi_dbg_bvalid (p_bvalid),
        .m_axi_dbg_bready (p_bready),
        .m_axi_dbg_araddr (p_araddr), .m_axi_dbg_arprot (p_arprot),
        .m_axi_dbg_arvalid (p_arvalid), .m_axi_dbg_arready (p_arready),
        .m_axi_dbg_rdata (p_rdata), .m_axi_dbg_rresp (p_rresp),
        .m_axi_dbg_rvalid (p_rvalid), .m_axi_dbg_rready (p_rready)
    );

    //================================================================
    // RAM side: the real port and the real memory
    //================================================================
    logic        core_en = 0;
    logic [3:0]  core_be = 4'hF;
    logic [RAM_ADDR_W-1:0] core_addr = 0;
    logic [31:0] core_wdata = 0, core_rdata;

    logic                  ram_en;
    logic [3:0]            ram_wbe;
    logic [RAM_ADDR_W-1:0] ram_addr;
    logic [31:0]           ram_wdata, ram_rdata;

    cva5_ram_port #(.ADDR_WIDTH (RAM_ADDR_W)) ram_port (
        .clk (clk), .rstn (rstn),
        .core_en (core_en), .core_be (core_be), .core_addr (core_addr),
        .core_wdata (core_wdata), .core_rdata (core_rdata),
        .ram_en (ram_en), .ram_wbe (ram_wbe), .ram_addr (ram_addr),
        .ram_wdata (ram_wdata), .ram_rdata (ram_rdata),
        .s_axi_awid (rp_awid), .s_axi_awaddr (rp_awaddr),
        .s_axi_awlen (rp_awlen), .s_axi_awsize (rp_awsize),
        .s_axi_awburst (rp_awburst), .s_axi_awvalid (rp_awvalid),
        .s_axi_awready (rp_awready),
        .s_axi_wdata (rp_wdata), .s_axi_wstrb (rp_wstrb),
        .s_axi_wlast (rp_wlast), .s_axi_wvalid (rp_wvalid),
        .s_axi_wready (rp_wready),
        .s_axi_bid (rp_bid), .s_axi_bresp (rp_bresp),
        .s_axi_bvalid (rp_bvalid), .s_axi_bready (rp_bready),
        .s_axi_arid (rp_arid), .s_axi_araddr (rp_araddr),
        .s_axi_arlen (rp_arlen), .s_axi_arsize (rp_arsize),
        .s_axi_arburst (rp_arburst), .s_axi_arvalid (rp_arvalid),
        .s_axi_arready (rp_arready),
        .s_axi_rid (rp_rid), .s_axi_rdata (rp_rdata),
        .s_axi_rresp (rp_rresp), .s_axi_rlast (rp_rlast),
        .s_axi_rvalid (rp_rvalid), .s_axi_rready (rp_rready)
    );

    // tdp_ram with the parameters cva5_wrapper uses. Port A is instruction
    // fetch on the board and is idle here.
    tdp_ram #(
        .ADDR_WIDTH (RAM_ADDR_W), .NUM_COL (4), .COL_WIDTH (8),
        .PIPELINE_DEPTH (0), .CASCADE_DEPTH (8), .USE_PRELOAD (0)
    ) mem (
        .clk (clk),
        .a_en (1'b0), .a_wbe ('0), .a_wdata ('0), .a_addr ('0), .a_rdata (),
        .b_en (ram_en), .b_wbe (ram_wbe), .b_wdata (ram_wdata),
        .b_addr (ram_addr), .b_rdata (ram_rdata)
    );

    //================================================================
    // Peripheral side: a one-register Lite slave that SLVERRs off its address
    //================================================================
    logic [31:0] periph_reg = 32'hFFFF_FFFF;
    int unsigned periph_writes = 0, periph_reads = 0;
    logic [31:0] aw_q, w_q;
    logic        aw_got = 0, w_got = 0;

    // Backpressure, so the peripheral is not always faster than the RAM.
    logic [3:0] lfsr = 4'hB;
    always_ff @(posedge clk) lfsr <= {lfsr[2:0], lfsr[3] ^ lfsr[2]};

    assign p_awready = ~aw_got & lfsr[0];
    assign p_wready  = ~w_got  & lfsr[1];
    assign p_arready = ~p_rvalid & lfsr[2];

    function automatic bit periph_hit(input logic [31:0] a);
        return a[31:12] == PERIPH[31:12];
    endfunction

    always_ff @(posedge clk) begin
        if (!rstn) begin
            aw_got <= 0; w_got <= 0; p_bvalid <= 0;
        end
        else begin
            if (p_awvalid & p_awready) begin aw_got <= 1; aw_q <= p_awaddr; end
            if (p_wvalid  & p_wready)  begin w_got  <= 1; w_q  <= p_wdata; end
            if (aw_got & w_got & ~p_bvalid) begin
                p_bvalid <= 1;
                p_bresp  <= periph_hit(aw_q) ? 2'b00 : 2'b10;   //SLVERR
                if (periph_hit(aw_q)) begin
                    periph_reg <= w_q;
                    periph_writes <= periph_writes + 1;
                end
                aw_got <= 0; w_got <= 0;
            end
            if (p_bvalid & p_bready) p_bvalid <= 0;
        end
    end

    always_ff @(posedge clk) begin
        if (!rstn) p_rvalid <= 0;
        else begin
            if (p_arvalid & p_arready) begin
                p_rvalid <= 1;
                p_rdata  <= periph_hit(p_araddr) ? periph_reg : 32'hDEAD_DEAD;
                p_rresp  <= periph_hit(p_araddr) ? 2'b00 : 2'b10;
                if (periph_hit(p_araddr)) periph_reads <= periph_reads + 1;
            end
            else if (p_rvalid & p_rready) p_rvalid <= 0;
        end
    end

    //================================================================
    // A reference copy of the RAM, updated from what was asked for rather
    // than from what the port did, so a misrouted beat fails instead of
    // being mirrored.
    //================================================================
    logic [31:0] ref_ram [1 << RAM_ADDR_W];

    task automatic ram_expect(input logic [31:0] addr, input logic [31:0] exp);
        // Read it back the way the debugger would.
        sba_xfer(1'b0, addr, 32'h0);
        expect_eq($sformatf("RAM 0x%08x reads back", addr), sba_rdata, exp);
        expect_eq($sformatf("RAM 0x%08x read had no error", addr),
                  32'(sba_rerr), 32'd0);
    endtask

    //================================================================
    initial begin
        for (int unsigned i = 0; i < (1 << RAM_ADDR_W); i++) ref_ram[i] = 32'h0;

        repeat (4) @(negedge clk);
        rstn = 1;
        repeat (4) @(negedge clk);

        //---- RAM window
        $display("-- the RAM window");
        sba_xfer(1'b1, RAM_BASE + 32'h10, 32'hA5A5_1234);
        expect_eq("a RAM write reports no error", 32'(sba_rerr), 32'd0);
        expect_eq("a RAM write does not reach the peripheral",
                  32'(periph_writes), 32'd0);
        ram_expect(RAM_BASE + 32'h10, 32'hA5A5_1234);

        // The last word of the window, which is where an off-by-one in the
        // decode or the address slice shows up.
        sba_xfer(1'b1, RAM_BASE + ((1 << RAM_ADDR_W) - 1) * 4, 32'h0F0F_0F0F);
        ram_expect(RAM_BASE + ((1 << RAM_ADDR_W) - 1) * 4, 32'h0F0F_0F0F);
        expect_eq("the last RAM word did not reach the peripheral",
                  32'(periph_writes), 32'd0);

        //---- peripheral
        $display("-- the peripheral");
        sba_xfer(1'b1, PERIPH + 32'h4, 32'hCAFE_0001);
        expect_eq("a peripheral write reports no error", 32'(sba_rerr), 32'd0);
        expect_eq("a peripheral write reached the peripheral",
                  32'(periph_writes), 32'd1);
        expect_eq("...with the right data", periph_reg, 32'hCAFE_0001);
        sba_xfer(1'b0, PERIPH + 32'h4, 32'h0);
        expect_eq("a peripheral read came from the peripheral",
                  sba_rdata, 32'hCAFE_0001);

        // The RAM is untouched by all of that.
        ram_expect(RAM_BASE + 32'h10, 32'hA5A5_1234);

        //---- alternating, so a stuck response-phase select shows up
        $display("-- alternating sides");
        for (int unsigned i = 0; i < 8; i++) begin
            sba_xfer(1'b1, RAM_BASE + 32'h40 + i * 4, 32'h1000_0000 + i);
            ref_ram[16 + i] = 32'h1000_0000 + i;
            sba_xfer(1'b1, PERIPH + 32'h8, 32'h2000_0000 + i);
            expect_eq("the peripheral took the interleaved write",
                      periph_reg, 32'h2000_0000 + i);
            sba_xfer(1'b0, RAM_BASE + 32'h40 + i * 4, 32'h0);
            expect_eq("the interleaved RAM word reads back",
                      sba_rdata, ref_ram[16 + i]);
            sba_xfer(1'b0, PERIPH + 32'h8, 32'h0);
            expect_eq("the interleaved peripheral read came back",
                      sba_rdata, 32'h2000_0000 + i);
        end

        //---- an error from the peripheral side reaches the debugger
        $display("-- error propagation");
        sba_xfer(1'b1, 32'h3000_0000, 32'hBAD0_0001);
        expect_eq("a write the peripheral rejects sets r_err",
                  32'(sba_rerr), 32'd1);
        sba_xfer(1'b0, 32'h3000_0000, 32'h0);
        expect_eq("a read the peripheral rejects sets r_err",
                  32'(sba_rerr), 32'd1);
        // And the bus still works afterwards.
        ram_expect(RAM_BASE + 32'h10, 32'hA5A5_1234);

        //---- byte strobes, which only the RAM side can show
        $display("-- byte strobes");
        sba_xfer(1'b1, RAM_BASE + 32'h20, 32'hFFFF_FFFF);
        sba_xfer(1'b1, RAM_BASE + 32'h20, 32'h0000_0042, 4'b0001);
        ram_expect(RAM_BASE + 32'h20, 32'hFFFF_FF42);

        //---- the core wins every collision, and the debugger still lands
        $display("-- collision with the core");
        fork
            begin
                // The core hammers the port for the whole burst of debugger
                // traffic, which is what a running CPU does during a halt
                // request.
                for (int unsigned i = 0; i < 400; i++) begin
                    @(negedge clk);
                    core_en = 1; core_be = 4'hF;
                    core_addr = RAM_ADDR_W'(200 + (i % 8));
                    core_wdata = 32'h7000_0000 + i;
                end
                @(negedge clk);
                core_en = 0;
            end
            begin
                for (int unsigned i = 0; i < 6; i++) begin
                    sba_xfer(1'b1, RAM_BASE + 32'h80 + i * 4, 32'h3000_0000 + i);
                    ref_ram[32 + i] = 32'h3000_0000 + i;
                end
            end
        join
        core_en = 0;
        repeat (4) @(negedge clk);
        for (int unsigned i = 0; i < 6; i++)
            ram_expect(RAM_BASE + 32'h80 + i * 4, ref_ram[32 + i]);

        // Everything written before the collision is still there.
        ram_expect(RAM_BASE + 32'h10, 32'hA5A5_1234);
        for (int unsigned i = 0; i < 8; i++)
            ram_expect(RAM_BASE + 32'h40 + i * 4, ref_ram[16 + i]);

        if (errors == 0)
            $display("PASS tb_sba_split: %0d checks", checks);
        else
            $display("FAIL tb_sba_split: %0d of %0d checks failed", errors, checks);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL tb_sba_split (timeout)");
        $finish;
    end

endmodule
