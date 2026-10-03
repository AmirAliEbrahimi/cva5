`timescale 1ns/1ps
module tb_sba;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  dm::dmi_req_t req; dm::dmi_resp_t resp;
  logic req_valid = 0, req_ready, resp_valid, resp_ready = 1;
  logic ndmreset;

  logic sba_req, sba_we, sba_gnt, sba_rvalid, sba_rerr;
  logic [31:0] sba_addr, sba_wdata, sba_rdata; logic [3:0] sba_be;

  dm_top #(.NrHarts(1), .BusWidth(32), .DmBaseAddress(32'h5000_0000)) dut (
    .clk_i(clk), .rst_ni(rst_n), .next_dm_addr_i('0), .testmode_i(1'b0),
    .ndmreset_o(ndmreset), .ndmreset_ack_i(1'b0), .dmactive_o(), .debug_req_o(),
    .unavailable_i(1'b1), .hartinfo_i('0),
    .slave_req_i(1'b0), .slave_we_i(1'b0), .slave_addr_i('0), .slave_be_i('0), .slave_wdata_i('0), .slave_rdata_o(),
    .master_req_o(sba_req), .master_add_o(sba_addr), .master_we_o(sba_we), .master_wdata_o(sba_wdata),
    .master_be_o(sba_be), .master_gnt_i(sba_gnt), .master_r_valid_i(sba_rvalid), .master_r_err_i(sba_rerr),
    .master_r_other_err_i(1'b0), .master_r_rdata_i(sba_rdata),
    .dmi_rst_ni(1'b1), .dmi_req_valid_i(req_valid), .dmi_req_ready_o(req_ready), .dmi_req_i(req),
    .dmi_resp_valid_o(resp_valid), .dmi_resp_ready_i(resp_ready), .dmi_resp_o(resp));

  logic [31:0] awaddr, wdata, araddr, rdata; logic [3:0] wstrb; logic [2:0] awprot, arprot;
  logic awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [1:0] bresp, rresp;
  dm_sba_axil bridge (.clk, .rst_n, .req_i(sba_req), .addr_i(sba_addr), .we_i(sba_we), .wdata_i(sba_wdata),
    .be_i(sba_be), .gnt_o(sba_gnt), .r_valid_o(sba_rvalid), .r_err_o(sba_rerr), .r_rdata_o(sba_rdata),
    .m_axi_awaddr(awaddr), .m_axi_awprot(awprot), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_araddr(araddr), .m_axi_arprot(arprot), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rvalid(rvalid), .m_axi_rready(rready));

  // AXI4-Lite slave model: 1 KB RAM at 0x4000_0000, random-ish backpressure, SLVERR elsewhere
  logic [31:0] mem [256];
  logic [7:0] lfsr = 8'h5a; always_ff @(posedge clk) lfsr <= {lfsr[6:0], lfsr[7]^lfsr[5]^lfsr[4]^lfsr[3]};
  logic aw_got, w_got; logic [31:0] aw_q, w_q; logic [3:0] s_q;
  assign awready = ~aw_got & lfsr[0];
  assign wready  = ~w_got & lfsr[1];
  assign arready = ~rvalid & lfsr[2];
  function automatic bit hit(input logic [31:0] a); return a[31:10] == 22'h100000; endfunction
  always_ff @(posedge clk) begin
    if (!rst_n) begin aw_got<=0; w_got<=0; bvalid<=0; rvalid<=0; end else begin
      if (awvalid & awready) begin aw_got<=1; aw_q<=awaddr; end
      if (wvalid & wready) begin w_got<=1; w_q<=wdata; s_q<=wstrb; end
      if (aw_got & w_got & ~bvalid) begin
        bvalid<=1; bresp <= hit(aw_q) ? 2'b00 : 2'b10;
        if (hit(aw_q)) for (int b=0;b<4;b++) if (s_q[b]) mem[aw_q[9:2]][8*b+:8] <= w_q[8*b+:8];
      end
      if (bvalid & bready) begin bvalid<=0; aw_got<=0; w_got<=0; end
      if (arvalid & arready) begin rvalid<=1; rdata<=mem[araddr[9:2]]; rresp <= hit(araddr)?2'b00:2'b10; end
      if (rvalid & rready) rvalid<=0;
    end
  end

  task automatic dmi(input logic [6:0] a, input dm::dtm_op_e op, input logic [31:0] d, output logic [31:0] q);
    @(posedge clk); req <= '{addr:a, op:op, data:d}; req_valid <= 1;
    do @(posedge clk); while (!req_ready); req_valid <= 0;
    while (!resp_valid) @(posedge clk); q = resp.data;
  endtask
  task automatic wr(input logic [6:0] a, input logic [31:0] d); logic [31:0] q; dmi(a, dm::DTM_WRITE, d, q); endtask
  task automatic rd(input logic [6:0] a, output logic [31:0] q); dmi(a, dm::DTM_READ, 0, q); endtask
  task automatic wait_idle(output logic [31:0] sbcs); do rd(7'h38, sbcs); while (sbcs[21]); endtask

  int errors = 0;
  logic [31:0] q, sbcs;
  logic [31:0] pat [4] = '{32'hdeadbeef, 32'h12345678, 32'hcafef00d, 32'h0badc0de};
  initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    wr(7'h10, 32'h1);                         // dmcontrol.dmactive
    wr(7'h10, 32'h3);                         // + ndmreset
    if (!ndmreset) begin $display("FAIL ndmreset not asserted"); errors++; end
    wr(7'h10, 32'h1);
    if (ndmreset) begin $display("FAIL ndmreset stuck"); errors++; end
    rd(7'h38, sbcs); $display("sbcs=%h (sbversion=%0d sbasize=%0d access32=%0d)", sbcs, sbcs[31:29], sbcs[11:5], sbcs[2]);

    // 32-bit burst write with autoincrement
    wr(7'h38, (2<<17) | (1<<16));
    wr(7'h39, 32'h4000_0010);
    foreach (pat[i]) begin wr(7'h3c, pat[i]); wait_idle(sbcs); end
    // byte write into word 1
    wr(7'h38, (0<<17));
    wr(7'h39, 32'h4000_0016); wr(7'h3c, 32'h000000AA); wait_idle(sbcs);
    // read back with readonaddr + readondata + autoincrement
    wr(7'h38, (1<<20) | (2<<17) | (1<<16) | (1<<15));
    wr(7'h39, 32'h4000_0010); wait_idle(sbcs);
    foreach (pat[i]) begin
      logic [31:0] exp = (i==1) ? 32'h12AA5678 : pat[i];
      rd(7'h3c, q); wait_idle(sbcs);
      if (q !== exp) begin $display("FAIL word %0d: got %h exp %h", i, q, exp); errors++; end
      else $display("ok   word %0d = %h", i, q);
    end
    if (sbcs[14:12] != 0) begin $display("FAIL unexpected sberror %0d", sbcs[14:12]); errors++; end
    // bus error on unmapped address
    wr(7'h38, (1<<20) | (2<<17));
    wr(7'h39, 32'h7000_0000); wait_idle(sbcs);
    if (sbcs[14:12] != 2) begin $display("FAIL expected sberror=2, got %0d", sbcs[14:12]); errors++; end
    else $display("ok   unmapped read -> sberror=2");
    if (errors) $display("TEST FAILED (%0d errors)", errors); else $display("TEST PASSED");
    $finish;
  end
  initial begin #2ms $display("TIMEOUT"); $finish; end
endmodule
