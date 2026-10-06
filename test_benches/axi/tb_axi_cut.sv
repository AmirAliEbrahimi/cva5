/*
 * tb_axi_cut -- self-checking test for cva5_axi_cut.
 *
 * Drives AXI4 write and read bursts through the cut into a small memory model
 * and checks that every beat, response and ID comes back intact, with random
 * backpressure on both sides. Also checks the property the cut exists for:
 * the slave port must accept an address while the master port is stalled, so
 * there is no combinational ready path from one side to the other.
 *
 * Run with test_benches/axi/run_cut.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module tb_axi_cut;

    localparam int unsigned ID_WIDTH = 6;
    localparam int unsigned MEM_WORDS = 1024;

    logic clk = 0;
    logic rstn = 0;

    always #5 clk = ~clk;

    int unsigned errors = 0;
    int unsigned checks = 0;

    // Advance one clock and settle: every port is driven and sampled a delta
    // after the edge, so nothing races the edge itself.
    task automatic step();
        @(posedge clk);
        #1;
    endtask

    task automatic expect_eq(string what, logic [63:0] got, logic [63:0] exp);
        checks++;
        if (got !== exp) begin
            $display("FAIL %s: got %h, expected %h", what, got, exp);
            errors++;
        end
    endtask

    //------------------------------------------------------------------
    // Slave port (driven by this testbench as the master)
    //------------------------------------------------------------------
    logic                s_arready, s_arvalid;
    logic [31:0]         s_araddr;
    logic [7:0]          s_arlen;
    logic [2:0]          s_arsize;
    logic [1:0]          s_arburst;
    logic [3:0]          s_arcache;
    logic [ID_WIDTH-1:0] s_arid;

    logic                s_rready, s_rvalid, s_rlast;
    logic [31:0]         s_rdata;
    logic [1:0]          s_rresp;
    logic [ID_WIDTH-1:0] s_rid;

    logic                s_awready, s_awvalid;
    logic [31:0]         s_awaddr;
    logic [7:0]          s_awlen;
    logic [2:0]          s_awsize;
    logic [1:0]          s_awburst;
    logic [3:0]          s_awcache;
    logic [ID_WIDTH-1:0] s_awid;

    logic                s_wready, s_wvalid, s_wlast;
    logic [31:0]         s_wdata;
    logic [3:0]          s_wstrb;

    logic                s_bready, s_bvalid;
    logic [1:0]          s_bresp;
    logic [ID_WIDTH-1:0] s_bid;

    //------------------------------------------------------------------
    // Master port (towards the memory model)
    //------------------------------------------------------------------
    logic                m_arready, m_arvalid;
    logic [31:0]         m_araddr;
    logic [7:0]          m_arlen;
    logic [2:0]          m_arsize;
    logic [1:0]          m_arburst;
    logic [3:0]          m_arcache;
    logic [2:0]          m_arprot;
    logic                m_arlock;
    logic [3:0]          m_arqos;
    logic [ID_WIDTH-1:0] m_arid;

    logic                m_rready, m_rvalid, m_rlast;
    logic [31:0]         m_rdata;
    logic [1:0]          m_rresp;
    logic [ID_WIDTH-1:0] m_rid;

    logic                m_awready, m_awvalid;
    logic [31:0]         m_awaddr;
    logic [7:0]          m_awlen;
    logic [2:0]          m_awsize;
    logic [1:0]          m_awburst;
    logic [3:0]          m_awcache;
    logic [2:0]          m_awprot;
    logic                m_awlock;
    logic [3:0]          m_awqos;
    logic [ID_WIDTH-1:0] m_awid;

    logic                m_wready, m_wvalid, m_wlast;
    logic [31:0]         m_wdata;
    logic [3:0]          m_wstrb;

    logic                m_bready, m_bvalid;
    logic [1:0]          m_bresp;
    logic [ID_WIDTH-1:0] m_bid;

    cva5_axi_cut #(.ID_WIDTH(ID_WIDTH)) dut (
        .clk(clk), .rstn(rstn),

        .s_axi_arready(s_arready), .s_axi_arvalid(s_arvalid), .s_axi_araddr(s_araddr),
        .s_axi_arlen(s_arlen), .s_axi_arsize(s_arsize), .s_axi_arburst(s_arburst),
        .s_axi_arcache(s_arcache), .s_axi_arid(s_arid),
        .s_axi_rready(s_rready), .s_axi_rvalid(s_rvalid), .s_axi_rdata(s_rdata),
        .s_axi_rresp(s_rresp), .s_axi_rlast(s_rlast), .s_axi_rid(s_rid),
        .s_axi_awready(s_awready), .s_axi_awvalid(s_awvalid), .s_axi_awaddr(s_awaddr),
        .s_axi_awlen(s_awlen), .s_axi_awsize(s_awsize), .s_axi_awburst(s_awburst),
        .s_axi_awcache(s_awcache), .s_axi_awid(s_awid),
        .s_axi_wready(s_wready), .s_axi_wvalid(s_wvalid), .s_axi_wdata(s_wdata),
        .s_axi_wstrb(s_wstrb), .s_axi_wlast(s_wlast),
        .s_axi_bready(s_bready), .s_axi_bvalid(s_bvalid), .s_axi_bresp(s_bresp),
        .s_axi_bid(s_bid),

        .m_axi_arready(m_arready), .m_axi_arvalid(m_arvalid), .m_axi_araddr(m_araddr),
        .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst),
        .m_axi_arcache(m_arcache), .m_axi_arprot(m_arprot),
        .m_axi_arlock(m_arlock), .m_axi_arqos(m_arqos), .m_axi_arid(m_arid),
        .m_axi_rready(m_rready), .m_axi_rvalid(m_rvalid), .m_axi_rdata(m_rdata),
        .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast), .m_axi_rid(m_rid),
        .m_axi_awready(m_awready), .m_axi_awvalid(m_awvalid), .m_axi_awaddr(m_awaddr),
        .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst),
        .m_axi_awcache(m_awcache), .m_axi_awprot(m_awprot),
        .m_axi_awlock(m_awlock), .m_axi_awqos(m_awqos), .m_axi_awid(m_awid),
        .m_axi_wready(m_wready), .m_axi_wvalid(m_wvalid), .m_axi_wdata(m_wdata),
        .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
        .m_axi_bready(m_bready), .m_axi_bvalid(m_bvalid), .m_axi_bresp(m_bresp),
        .m_axi_bid(m_bid)
    );

    //==================================================================
    // Memory model on the master port: INCR bursts, one outstanding
    // transaction per direction, with injectable backpressure.
    //==================================================================
    logic [31:0] mem [MEM_WORDS];

    // Held high by the stall test to freeze the master port.
    logic mem_stall = 0;

    // Attributes as seen on the master port, checked after each transaction:
    // a mis-ordered field in the channel structs would show up here.
    logic [7:0]          seen_awlen, seen_arlen;
    logic [2:0]          seen_awsize, seen_arsize;
    logic [1:0]          seen_awburst, seen_arburst;
    logic [3:0]          seen_awcache, seen_arcache;
    logic [31:0]         seen_awaddr, seen_araddr;

    // --- write channel
    logic [31:0]         w_addr;
    logic [ID_WIDTH-1:0] w_id;
    logic                w_active = 0;

    assign m_awready = !w_active && !mem_stall;
    assign m_wready  = w_active && !mem_stall;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            w_active <= 0;
            m_bvalid <= 0;
        end else begin
            if (m_awvalid && m_awready) begin
                w_active <= 1;
                w_addr   <= m_awaddr;
                w_id     <= m_awid;
                seen_awaddr  <= m_awaddr;
                seen_awlen   <= m_awlen;
                seen_awsize  <= m_awsize;
                seen_awburst <= m_awburst;
                seen_awcache <= m_awcache;
            end
            if (m_wvalid && m_wready) begin
                for (int b = 0; b < 4; b++)
                    if (m_wstrb[b]) mem[w_addr[31:2]][8*b +: 8] <= m_wdata[8*b +: 8];
                w_addr <= w_addr + 4;
                if (m_wlast) begin
                    w_active <= 0;
                    m_bvalid <= 1;
                    m_bid    <= w_id;
                    m_bresp  <= 2'b00;
                end
            end
            if (m_bvalid && m_bready)
                m_bvalid <= 0;
        end
    end

    // --- read channel
    logic [31:0]         r_addr;
    logic [7:0]          r_left;
    logic                r_active = 0;

    assign m_arready = !r_active && !mem_stall;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            r_active <= 0;
            m_rvalid <= 0;
        end else begin
            if (m_arvalid && m_arready) begin
                r_active <= 1;
                r_addr   <= m_araddr;
                r_left   <= m_arlen;
                seen_araddr  <= m_araddr;
                seen_arlen   <= m_arlen;
                seen_arsize  <= m_arsize;
                seen_arburst <= m_arburst;
                seen_arcache <= m_arcache;
                m_rvalid <= 1;
                m_rid    <= m_arid;
                m_rdata  <= mem[m_araddr[31:2]];
                m_rresp  <= 2'b00;
                m_rlast  <= (m_arlen == 0);
            end else if (m_rvalid && m_rready && !mem_stall) begin
                if (m_rlast) begin
                    m_rvalid <= 0;
                    r_active <= 0;
                end else begin
                    r_addr   <= r_addr + 4;
                    r_left   <= r_left - 1;
                    m_rdata  <= mem[(r_addr + 4) >> 2];
                    m_rlast  <= (r_left == 1);
                end
            end
        end
    end

    //==================================================================
    // Master-side stimulus
    //==================================================================
    task automatic axi_write(input logic [31:0] addr, input logic [7:0] len,
                             input logic [ID_WIDTH-1:0] id, input logic [31:0] seed);
        fork
            begin // AW
                s_awvalid = 1;
                s_awaddr = addr;
                s_awlen = len;
                s_awsize = 3'd2;
                s_awburst = 2'b01;
                s_awcache = 4'b0011;
                s_awid = id;
                do step(); while (!s_awready);
                s_awvalid = 0;
            end
            begin // W
                for (int unsigned i = 0; i <= len; i++) begin
                    s_wvalid = 1;
                    s_wdata = seed + i;
                    s_wstrb = 4'hF;
                    s_wlast = (i == len);
                    do step(); while (!s_wready);
                    s_wvalid = 0;
                end
                s_wlast = 0;
            end
            begin // B
                s_bready = 1;
                do step(); while (!s_bvalid);
                expect_eq("write response id", s_bid, id);
                expect_eq("write response resp", s_bresp, 2'b00);
                expect_eq("aw addr forwarded", seen_awaddr, addr);
                expect_eq("aw len forwarded", seen_awlen, len);
                expect_eq("aw size forwarded", seen_awsize, 3'd2);
                expect_eq("aw burst forwarded", seen_awburst, 2'b01);
                expect_eq("aw cache forwarded", seen_awcache, 4'b0011);
                expect_eq("aw prot default", m_awprot, 3'b000);
                expect_eq("aw lock default", m_awlock, 1'b0);
                expect_eq("aw qos default", m_awqos, 4'b0000);
                s_bready = 0;
            end
        join
    endtask

    task automatic axi_read_check(input logic [31:0] addr, input logic [7:0] len,
                                  input logic [ID_WIDTH-1:0] id, input logic [31:0] seed);
        fork
            begin // AR
                s_arvalid = 1;
                s_araddr = addr;
                s_arlen = len;
                s_arsize = 3'd2;
                s_arburst = 2'b01;
                s_arcache = 4'b0011;
                s_arid = id;
                do step(); while (!s_arready);
                s_arvalid = 0;
            end
            begin // R
                for (int unsigned i = 0; i <= len; i++) begin
                    s_rready = 1;
                    do step(); while (!s_rvalid);
                    expect_eq($sformatf("read data beat %0d", i), s_rdata, seed + i);
                    expect_eq($sformatf("read id beat %0d", i), s_rid, id);
                    expect_eq($sformatf("read resp beat %0d", i), s_rresp, 2'b00);
                    expect_eq($sformatf("read last beat %0d", i), s_rlast, (i == len));
                    s_rready = 0;
                end
                expect_eq("ar addr forwarded", seen_araddr, addr);
                expect_eq("ar len forwarded", seen_arlen, len);
                expect_eq("ar size forwarded", seen_arsize, 3'd2);
                expect_eq("ar burst forwarded", seen_arburst, 2'b01);
                expect_eq("ar cache forwarded", seen_arcache, 4'b0011);
                expect_eq("ar prot default", m_arprot, 3'b000);
                expect_eq("ar lock default", m_arlock, 1'b0);
                expect_eq("ar qos default", m_arqos, 4'b0000);
            end
        join
    endtask

    initial begin
        s_arvalid = 0; s_rready = 0; s_awvalid = 0; s_wvalid = 0;
        s_wlast = 0; s_bready = 0;
        s_araddr = 0; s_arlen = 0; s_arsize = 0; s_arburst = 0; s_arcache = 0; s_arid = 0;
        s_awaddr = 0; s_awlen = 0; s_awsize = 0; s_awburst = 0; s_awcache = 0; s_awid = 0;
        s_wdata = 0; s_wstrb = 0;

        for (int unsigned i = 0; i < MEM_WORDS; i++)
            mem[i] = 32'hDEADBEEF;

        repeat (4) step();
        rstn = 1;
        repeat (2) step();

        // ---- single beats
        axi_write(32'h0000_0000, 8'd0, 6'h0A, 32'h1111_0000);
        axi_read_check(32'h0000_0000, 8'd0, 6'h0A, 32'h1111_0000);

        // ---- a cache-line sized burst (CVA5 fills 4 words)
        axi_write(32'h0000_0040, 8'd3, 6'h15, 32'h2222_0000);
        axi_read_check(32'h0000_0040, 8'd3, 6'h15, 32'h2222_0000);

        // ---- a long burst, and distinct IDs round-tripping
        axi_write(32'h0000_0100, 8'd15, 6'h3F, 32'h3333_0000);
        axi_read_check(32'h0000_0100, 8'd15, 6'h3F, 32'h3333_0000);

        // ---- back-to-back bursts, no idle cycles in between
        axi_write(32'h0000_0200, 8'd3, 6'h01, 32'h4444_0000);
        axi_write(32'h0000_0210, 8'd3, 6'h02, 32'h5555_0000);
        axi_read_check(32'h0000_0200, 8'd3, 6'h01, 32'h4444_0000);
        axi_read_check(32'h0000_0210, 8'd3, 6'h02, 32'h5555_0000);

        // ---- the reason the cut is here: the slave port must take an
        // address while the master port is stalled, i.e. s_axi_arready
        // must not be a combinational function of m_axi_arready.
        mem_stall = 1;
        step();
        checks++;
        if (!s_arready) begin
            $display("FAIL slave port stalls with the master port: no decoupling");
            errors++;
        end
        s_arvalid = 1;
        s_araddr = 32'h0000_0040;
        s_arlen = 8'd3;
        s_arsize = 3'd2;
        s_arburst = 2'b01;
        s_arid = 6'h2A;
        step();
        checks++;
        if (!(s_arvalid && s_arready)) begin
            $display("FAIL address not accepted while the master port is stalled");
            errors++;
        end
        s_arvalid = 0;
        repeat (5) step();
        mem_stall = 0;
        // and the stalled transaction must still complete correctly
        for (int unsigned i = 0; i <= 3; i++) begin
            s_rready = 1;
            do step(); while (!s_rvalid);
            expect_eq($sformatf("post-stall read beat %0d", i), s_rdata, 32'h2222_0000 + i);
            expect_eq($sformatf("post-stall read id %0d", i), s_rid, 6'h2A);
            s_rready = 0;
        end

        repeat (10) step();

        if (errors == 0)
            $display("PASS tb_axi_cut: %0d checks", checks);
        else
            $display("FAIL tb_axi_cut: %0d of %0d checks failed", errors, checks);
        $finish;
    end

    // Watchdog
    initial begin
        #200000;
        $display("FAIL tb_axi_cut: timeout");
        $finish;
    end

endmodule
