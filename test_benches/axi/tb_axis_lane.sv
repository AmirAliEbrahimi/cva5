// cva5_axis_lane: the low lanes of a 32-bit stream reaching a 24-bit port.
//
// Small module, so the bench is about the two things that would be silent on
// hardware: a beat whose lanes come out rotated or sign-extended rather than
// truncated, and back-pressure that is not passed straight through. Neither
// shows up as a failure downstream -- the accelerator would just classify
// slightly worse, which looks like a precision problem.
//
// Run: sh test_benches/axi/run_axis_lane.sh
//
// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module tb_axis_lane;
    localparam int unsigned SW = 32, MW = 24;

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

    logic [SW-1:0] s_tdata = 0;
    logic          s_tvalid = 0, s_tready, s_tlast = 0;
    logic [MW-1:0] m_tdata;
    logic          m_tvalid, m_tready = 0, m_tlast;
    logic [15:0]   pad_seen;

    cva5_axis_lane #(.S_WIDTH(SW), .M_WIDTH(MW)) dut (
        .clk(clk), .rstn(rstn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .pad_seen(pad_seen)
    );

    //One beat, driven on the negedge and handshaked on the posedge.
    task automatic beat(input logic [SW-1:0] d, input logic last = 0);
        @(negedge clk);
        s_tdata = d; s_tvalid = 1; s_tlast = last; m_tready = 1;
        forever begin @(posedge clk); if (s_tready) break; end
        @(negedge clk);
        s_tvalid = 0; s_tlast = 0; m_tready = 0;
    endtask

    initial begin
        repeat (4) @(negedge clk); rstn = 1; repeat (2) @(negedge clk);

        //A pixel: R=0x11, G=0x22, B=0x33, pad 0. Little-endian word.
        @(negedge clk);
        s_tdata = 32'h00_33_22_11; s_tvalid = 1; m_tready = 1;
        @(posedge clk);
        ck_eq("RGB comes through in the low lanes", m_tdata, 24'h33_22_11);
        ck("tvalid passes through", m_tvalid === 1'b1);
        ck("tready passes back", s_tready === 1'b1);
        @(negedge clk); s_tvalid = 0; m_tready = 0;

        //The pad byte is dropped, not shifted in anywhere.
        @(negedge clk);
        s_tdata = 32'hFF_33_22_11; s_tvalid = 1; m_tready = 1;
        @(posedge clk);
        ck_eq("a non-zero pad byte changes nothing downstream",
              m_tdata, 24'h33_22_11);
        @(negedge clk); s_tvalid = 0; m_tready = 0;

        //Back-pressure: with the sink not ready, the source must not be.
        @(negedge clk);
        s_tdata = 32'h0000_0001; s_tvalid = 1; m_tready = 0;
        @(posedge clk);
        ck("tready is low while the sink is not ready", s_tready === 1'b0);
        ck("tvalid is still presented", m_tvalid === 1'b1);
        ck_eq("and the data is stable", m_tdata, 24'h000001);
        @(negedge clk); m_tready = 1;
        @(posedge clk);
        ck("tready follows the sink the cycle it goes ready",
           s_tready === 1'b1);
        @(negedge clk); s_tvalid = 0; m_tready = 0;

        //tlast passes through.
        @(negedge clk);
        s_tdata = 32'h0000_00AA; s_tvalid = 1; s_tlast = 1; m_tready = 1;
        @(posedge clk);
        ck("tlast passes through", m_tlast === 1'b1);
        @(negedge clk); s_tvalid = 0; s_tlast = 0; m_tready = 0;

        //The pad counter: three clean beats then two dirty ones.
        ck_eq("pad_seen counted the one dirty beat so far", pad_seen, 16'd1);
        beat(32'h00_01_02_03);
        beat(32'h00_04_05_06);
        ck_eq("clean beats do not move the counter", pad_seen, 16'd1);
        beat(32'h01_01_02_03);
        beat(32'h80_04_05_06);
        ck_eq("dirty beats do", pad_seen, 16'd3);

        //A whole 1024-pixel image, the real traffic shape.
        begin
            automatic logic [15:0] pad_before = pad_seen;
            for (int i = 0; i < 1024; i++)
                beat({8'h00, 8'(i), 8'(i >> 2), 8'(i >> 4)}, i == 1023);
            ck_eq("a full image of clean pixels leaves the counter alone",
                  pad_seen, pad_before);
        end

        $display("%s tb_axis_lane: %0d checks%s",
                 failures ? "FAIL" : "PASS", checks,
                 failures ? $sformatf(", %0d failed", failures) : "");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL tb_axis_lane: timed out");
        $finish;
    end
endmodule
