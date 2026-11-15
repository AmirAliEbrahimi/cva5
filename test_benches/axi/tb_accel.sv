// cva5_accel_axi end to end: software programs a transfer, the DMA reads an
// image out of a RAM model, the lane select narrows it, a model accelerator
// consumes it and produces a result, and software reads the result back.
//
// This is the bench that matters for the accelerator patch. Everything in it
// is real except two models: the RAM behind the AXI master, and the
// accelerator itself. The DMA (ZipCPU's aximm2s), the lane select, the
// register block and the Lite address decode are the shipped modules.
//
// What it is really checking is the handshake nobody can see on hardware.
// The accelerator's result comes back as one 32-bit beat with no address and
// no acknowledgement; if it is captured at the wrong moment, or if a stale
// result is readable, the board returns a plausible number and the only
// symptom is a classifier that is slightly wrong. Same for the pixel lanes.
//
// Run: sh test_benches/axi/run_accel.sh
//
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

module tb_accel;
    localparam int unsigned AW  = 17;      //128 KB, as cva5_top presents it
    localparam int unsigned IDW = 12;
    localparam int unsigned SW  = 24;
    localparam int unsigned PIXELS = 256;  //a small image; the shape is what matters

    //Register offsets, which must match examples/sw/soc.h.
    localparam logic [11:0] DMA_CONTROL = 12'h000;
    localparam logic [11:0] DMA_ADDRLO  = 12'h008;
    localparam logic [11:0] DMA_LENLO   = 12'h018;
    localparam logic [11:0] ACC_CTRL    = 12'h020;
    localparam logic [11:0] ACC_STATUS  = 12'h024;
    localparam logic [11:0] ACC_RESULT  = 12'h028;
    localparam logic [11:0] ACC_PADSEEN = 12'h02C;

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

    //---- Lite master signals ---------------------------------------------
    logic [11:0] awaddr = 0, araddr = 0;
    logic        awvalid = 0, awready, wvalid = 0, wready;
    logic [31:0] wdata = 0;
    logic        bvalid, bready = 0;
    logic [1:0]  bresp, rresp;
    logic        arvalid = 0, arready, rvalid, rready = 0;
    logic [31:0] rdata;

    //---- AXI master towards the RAM model --------------------------------
    logic [IDW-1:0] m_arid, m_rid, m_awid, m_bid;
    logic [AW-1:0]  m_araddr, m_awaddr;
    logic [7:0]     m_arlen, m_awlen;
    logic [2:0]     m_arsize, m_awsize;
    logic [1:0]     m_arburst, m_awburst, m_rresp, m_bresp;
    logic           m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
    logic           m_awvalid, m_awready, m_wvalid, m_wready, m_wlast;
    logic           m_bvalid, m_bready;
    logic [31:0]    m_wdata, m_rdata;
    logic [3:0]     m_wstrb;

    //---- accelerator side -------------------------------------------------
    logic [SW-1:0] x_tdata;
    logic          x_tvalid, x_tready, x_tlast;
    logic [31:0]   y_tdata = 0;
    logic          y_tvalid = 0, y_tready;
    logic          ap_start, ap_done = 0, ap_idle = 1, ap_ready = 0, irq;

    cva5_accel_axi #(
        .ADDR_WIDTH(AW), .ID_WIDTH(IDW), .STREAM_WIDTH(SW), .LGFIFO(8)
    ) dut (
        .clk(clk), .rstn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready), .s_axi_wdata(wdata), .s_axi_wstrb(4'hF),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready), .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen),
        .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst),
        .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid),
        .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp),
        .m_axi_rlast(m_rlast), .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
        .m_axis_tdata(x_tdata), .m_axis_tvalid(x_tvalid),
        .m_axis_tready(x_tready), .m_axis_tlast(x_tlast),
        .s_axis_tdata(y_tdata), .s_axis_tvalid(y_tvalid),
        .s_axis_tready(y_tready),
        .ap_start(ap_start), .ap_done(ap_done), .ap_idle(ap_idle),
        .ap_ready(ap_ready), .irq(irq)
    );

    //---- a RAM model behind the AXI read channels -------------------------
    //Enough AXI4 to serve incrementing bursts, which is all aximm2s issues.
    logic [31:0] mem [0:(1<<(AW-2))-1];
    logic [AW-3:0]  burst_addr;
    logic [8:0]     burst_left;
    logic           burst_on = 0;
    logic [IDW-1:0] burst_id;

    assign m_awready = 1'b1;
    assign m_wready  = 1'b1;
    assign m_bvalid  = 1'b0;
    assign m_bid     = '0;
    assign m_bresp   = 2'b00;
    assign m_arready = ~burst_on;
    assign m_rvalid  = burst_on;
    assign m_rdata   = mem[burst_addr];
    assign m_rid     = burst_id;
    assign m_rresp   = 2'b00;
    assign m_rlast   = burst_on && (burst_left == 9'd1);

    always_ff @(posedge clk) begin
        if (~rstn)
            burst_on <= 1'b0;
        else if (~burst_on && m_arvalid) begin
            burst_on   <= 1'b1;
            burst_addr <= m_araddr[AW-1:2];
            burst_left <= {1'b0, m_arlen} + 9'd1;
            burst_id   <= m_arid;
        end else if (burst_on && m_rready) begin
            if (burst_left == 9'd1) burst_on <= 1'b0;
            else begin
                burst_left <= burst_left - 9'd1;
                burst_addr <= burst_addr + 1'b1;
            end
        end
    end

    //---- a model accelerator ---------------------------------------------
    //Consumes the stream once started, sums it, and produces one beat. The
    //ap_ctrl_hs handshake is modelled as the real IP uses it: ap_start taken
    //on ap_ready, ap_done pulsed when the result is presented.
    logic [31:0] acc_sum;
    int          acc_beats;
    typedef enum logic [1:0] {A_IDLE, A_RUN, A_OUT} acc_e;
    acc_e acc_st = A_IDLE;

    assign x_tready = (acc_st == A_RUN);

    always_ff @(posedge clk) begin
        ap_ready <= 1'b0;
        ap_done  <= 1'b0;
        if (~rstn) begin
            acc_st <= A_IDLE; acc_sum <= 0; acc_beats <= 0;
            ap_idle <= 1'b1; y_tvalid <= 1'b0;
        end else begin
            case (acc_st)
                A_IDLE: if (ap_start) begin
                    acc_st   <= A_RUN;
                    ap_ready <= 1'b1;
                    ap_idle  <= 1'b0;
                    acc_sum  <= 0;
                    acc_beats<= 0;
                end
                A_RUN: if (x_tvalid & x_tready) begin
                    acc_sum   <= acc_sum + {8'd0, x_tdata};
                    acc_beats <= acc_beats + 1;
                    if (x_tlast) begin
                        acc_st   <= A_OUT;
                        y_tdata  <= acc_sum + {8'd0, x_tdata};
                        y_tvalid <= 1'b1;
                    end
                end
                A_OUT: if (y_tready) begin
                    y_tvalid <= 1'b0;
                    ap_done  <= 1'b1;
                    ap_idle  <= 1'b1;
                    acc_st   <= A_IDLE;
                end
                default: acc_st <= A_IDLE;
            endcase
        end
    end

    //---- Lite driver ------------------------------------------------------
    task automatic lwr(input logic [11:0] a, input logic [31:0] d);
        @(negedge clk); awaddr = a; awvalid = 1; wdata = d; wvalid = 1;
        fork
            begin forever begin @(posedge clk); if (awready) break; end
                  @(negedge clk); awvalid = 0; end
            begin forever begin @(posedge clk); if (wready) break; end
                  @(negedge clk); wvalid = 0; end
        join
        bready = 1;
        forever begin @(posedge clk); if (bvalid) break; end
        @(negedge clk); bready = 0;
    endtask

    task automatic lrd(input logic [11:0] a, output logic [31:0] d);
        @(negedge clk); araddr = a; arvalid = 1;
        forever begin @(posedge clk); if (arready) break; end
        @(negedge clk); arvalid = 0; rready = 1;
        forever begin @(posedge clk); if (rvalid) break; end
        d = rdata;
        @(negedge clk); rready = 0;
    endtask

    //---- the run ----------------------------------------------------------
    logic [31:0] v, expect_sum;
    int guard;

    initial begin
        for (int i = 0; i < (1<<(AW-2)); i++) mem[i] = 0;
        repeat (4) @(negedge clk); rstn = 1; repeat (2) @(negedge clk);

        //An image: 4 bytes a pixel, R G B and a zero pad.
        expect_sum = 0;
        for (int i = 0; i < PIXELS; i++) begin
            automatic logic [31:0] px =
                {8'h00, 8'(i + 2), 8'(i + 1), 8'(i)};
            mem[(32'h100 >> 2) + i] = px;
            expect_sum = expect_sum + {8'd0, px[23:0]};
        end

        ck("the accelerator starts idle", ap_idle === 1'b1);
        lrd(ACC_STATUS, v);
        ck_eq("STATUS reports idle and no result", v & 32'hF, 32'h2);

        //Program the transfer, then start the accelerator, then the DMA.
        lwr(DMA_ADDRLO, 32'h100);
        lwr(DMA_LENLO,  PIXELS * 4);
        lrd(DMA_ADDRLO, v);
        ck_eq("the DMA kept the address it was given", v, 32'h100);
        lrd(DMA_LENLO, v);
        ck_eq("and the length", v, PIXELS * 4);

        //Writing CTRL starts it, and the model takes ap_start immediately,
        //so what is observable afterwards is that it left idle -- not that
        //the bit is still set. That is the ap_ctrl_hs handshake working.
        lwr(ACC_CTRL, 32'h1);
        lrd(ACC_STATUS, v);
        ck("writing CTRL started the accelerator", v[1] === 1'b0);

        //aximm2s starts on a CMD_CONTROL write with bit 31 (its busy bit)
        //set and byte strobe 3 asserted. Writing zero clears flags and does
        //nothing else, which is what this bench did at first and which looks
        //exactly like a DMA that is wired up wrong.
        lwr(DMA_CONTROL, 32'h8000_0000);

        //Wait for the result.
        guard = 0;
        forever begin
            lrd(ACC_STATUS, v);
            if (v[3]) break;
            guard++;
            if (guard > 2000) begin
                $display({"FAIL: no result after %0d polls (status 0x%08h, ",
                          "beats %0d of %0d)"}, guard, v, acc_beats, PIXELS);
                failures++;
                break;
            end
        end

        ck_eq("every pixel reached the accelerator", acc_beats, PIXELS);
        ck("ap_start was cleared when the accelerator took it",
           ap_start === 1'b0);
        ck("irq is raised while a result is waiting", irq === 1'b1);

        lrd(ACC_RESULT, v);
        ck_eq("the result is what the accelerator produced", v, expect_sum);

        lrd(ACC_STATUS, v);
        ck("reading the result clears result_valid", v[3] === 1'b0);
        ck("and drops irq", irq === 1'b0);

        lrd(ACC_PADSEEN, v);
        ck_eq("a clean image reports no bad pad bytes", v, 32'd0);

        //Now the mistake this is here to catch: 3-byte pixels, so the pad
        //lane carries image data. Nothing downstream can tell.
        for (int i = 0; i < PIXELS; i++)
            mem[(32'h100 >> 2) + i] = {8'(i + 3), 8'(i + 2), 8'(i + 1), 8'(i)};

        lwr(DMA_ADDRLO, 32'h100);
        lwr(DMA_LENLO,  PIXELS * 4);
        lwr(ACC_CTRL, 32'h1);
        lwr(DMA_CONTROL, 32'h8000_0000);

        guard = 0;
        forever begin
            lrd(ACC_STATUS, v);
            if (v[3]) break;
            guard++;
            if (guard > 2000) begin
                $display("FAIL: no result on the second run"); failures++;
                break;
            end
        end
        lrd(ACC_RESULT, v);

        lrd(ACC_PADSEEN, v);
        ck("a packed image is reported, not silently classified",
           v > 32'd0);

        $display("%s tb_accel: %0d checks%s",
                 failures ? "FAIL" : "PASS", checks,
                 failures ? $sformatf(", %0d failed", failures) : "");
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL tb_accel: timed out");
        $finish;
    end
endmodule
