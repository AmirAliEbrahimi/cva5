`timescale 1ns/1ps
//=============================================================================
// tb_sys -- does CVA5 restart after a synchronous reset applied mid-execution
// with the clock still running (what ndmreset now does), as opposed to SW0,
// which also stops and restarts the clock?
//
// Runs the real cva5_wrapper with examples/sw/mem.mif and an AXI slave model
// that is NOT reset along with the CPU, matching the board. The model adds
// interconnect-like latency so that reads are in flight when the reset lands.
//
// Build and run from the repo root with the command given alongside this file
// (--binary --timing; the run directory must contain mem.mif).
//
// Cases: reset during usleep, reset during a UART write, and reset with a read
// outstanding. All three should pass with the branch predictor enabled once
// branch_predictor.sv invalidates its tag banks after reset.
//
// The program is loaded here, from the testbench, straight into the local
// memory array. The RTL's own preload does not work under Verilator: tdp_ram
// declares PRELOAD_FILE as an untyped parameter defaulting to "", so a string
// passed down from the wrapper arrives empty and $readmemh finds no file.
// Vivado handles that fine; this is a simulation-only workaround.
//=============================================================================
module tb_sys;
    logic clk = 0; always #5 clk = ~clk;      // 100 MHz
    logic rstn = 0;                            // system reset (SW0 or ndmreset)
    logic por_n = 0;                           // testbench-only: UART model reset

    logic arready, arvalid, rready, rvalid, awready, awvalid, wready, wvalid, bready, bvalid;
    logic [31:0] araddr, rdata, awaddr, wdata;
    logic [3:0] wstrb; logic [1:0] rresp, bresp;

    cva5_wrapper #(.LOCAL_MEM("mem.mif")) dut (
        .clk (clk), .rstn (rstn),
        .m_axi_arready(arready), .m_axi_arvalid(arvalid), .m_axi_araddr(araddr),
        .m_axi_rready(rready), .m_axi_rvalid(rvalid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_awready(awready), .m_axi_awvalid(awvalid), .m_axi_awaddr(awaddr),
        .m_axi_wready(wready), .m_axi_wvalid(wvalid), .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_bready(bready), .m_axi_bvalid(bvalid), .m_axi_bresp(bresp),
        .m_axi_dbg_awready(1'b0), .m_axi_dbg_wready(1'b0), .m_axi_dbg_bresp(2'b0),
        .m_axi_dbg_bvalid(1'b0), .m_axi_dbg_arready(1'b0), .m_axi_dbg_rdata(32'b0),
        .m_axi_dbg_rresp(2'b0), .m_axi_dbg_rvalid(1'b0),
        .m_axi_dbg_awaddr(), .m_axi_dbg_awprot(), .m_axi_dbg_awvalid(), .m_axi_dbg_wdata(),
        .m_axi_dbg_wstrb(), .m_axi_dbg_wvalid(), .m_axi_dbg_bready(), .m_axi_dbg_araddr(),
        .m_axi_dbg_arprot(), .m_axi_dbg_arvalid(), .m_axi_dbg_rready(), .ndmreset(), .led());

    // ---- AXI slave model with interconnect-like latency (reset only by por_n) ----
    // AXI4-Lite UART behind an interconnect: several cycles of latency each way,
    // which is what makes a read likely to be in flight when the reset lands.
    localparam int LAT = 12;
    int ar_timer = 0, aw_timer = 0;
    logic rd_outstanding;          // AR accepted, R not yet returned
    assign awready = awvalid & wvalid & ~bvalid & (aw_timer == 0);
    assign wready  = awvalid & wvalid & ~bvalid & (aw_timer == 0);
    assign arready = ~rvalid & ~rd_outstanding & (ar_timer == 0);
    assign rresp = 2'b00;
    assign bresp = 2'b00;
    int nlines = 0;
    always_ff @(posedge clk) begin
        if (!por_n) begin
            bvalid <= 1'b0; rvalid <= 1'b0; rd_outstanding <= 1'b0;
            ar_timer <= 0; aw_timer <= 0;
        end else begin
            // write path
            if (awvalid & awready) begin
                aw_timer <= LAT;
                if (awaddr[3:0] == 4'h4) begin
                    $write("%c", wdata[7:0]);
                    if (wdata[7:0] == 8'h0a) nlines++;
                end
            end else if (aw_timer > 1) aw_timer <= aw_timer - 1;
            else if (aw_timer == 1) begin aw_timer <= 0; bvalid <= 1'b1; end
            else if (bvalid & bready) bvalid <= 1'b0;

            // read path: response returns LAT cycles after the address is accepted
            if (arvalid & arready) begin ar_timer <= LAT; rd_outstanding <= 1'b1; end
            else if (ar_timer > 1) ar_timer <= ar_timer - 1;
            else if (ar_timer == 1) begin ar_timer <= 0; rvalid <= 1'b1; rdata <= 32'h0; end
            else if (rvalid & rready) begin rvalid <= 1'b0; rd_outstanding <= 1'b0; end
        end
    end

    longint cyc = 0; always_ff @(posedge clk) cyc++;

    task automatic wait_lines(input int n, input int limit, output bit ok);
        longint t0 = cyc;
        while (nlines < n && (cyc - t0) < limit) @(posedge clk);
        ok = (nlines >= n);
    endtask

    // Reset the CPU only (the clock keeps running), like ndmreset on the board.
    task automatic cpu_reset_pulse(input int hold_cycles);
        rstn = 1'b0;
        repeat (hold_cycles) @(posedge clk);
        rstn = 1'b1;
    endtask

    int errs = 0;
    bit ok;
    initial begin
        $readmemh("mem.mif", dut.local_mem.mem, 0);
        repeat (10) @(posedge clk);
        por_n = 1'b1; rstn = 1'b1;

        wait_lines(1, 100000, ok);
        if (!ok) begin $display("\n[tb] FAIL: no output at all -- check that mem.mif loaded"); $finish; end
        $display("\n[tb] line 1 at cycle %0d", cyc);

        // --- Case 1: reset while the CPU is in usleep ---
        repeat (5000) @(posedge clk);
        $display("[tb] case 1: reset during usleep at cycle %0d", cyc);
        cpu_reset_pulse(2000);
        wait_lines(2, 300000, ok);
        if (ok) $display("[tb] case 1 PASS: restarted, line 2 at cycle %0d", cyc);
        else  begin $display("[tb] case 1 FAIL: silent for 300k cycles after release"); errs++; end

        // --- Case 2: reset in the middle of a UART write ---
        if (ok) begin
            longint t0;
            while (!(awvalid && awaddr[3:0] == 4'h4)) @(posedge clk);
            repeat (3) @(posedge clk);
            $display("\n[tb] case 2: reset during a UART write at cycle %0d", cyc);
            t0 = nlines;
            cpu_reset_pulse(2000);
            wait_lines(int'(t0) + 1, 300000, ok);
            if (ok) $display("[tb] case 2 PASS: restarted, line %0d at cycle %0d", nlines, cyc);
            else  begin $display("[tb] case 2 FAIL: silent for 300k cycles after release"); errs++; end
        end

        // --- Case 3: reset while a read is outstanding, at four offsets ---
        for (int rep = 0; rep < 4 && ok; rep++) begin
            longint t0;
            while (!(arvalid && arready)) @(posedge clk);
            repeat (rep + 1) @(posedge clk);
            $display("\n[tb] case 3.%0d: reset with a read outstanding at cycle %0d", rep, cyc);
            t0 = nlines;
            cpu_reset_pulse(2000);
            wait_lines(int'(t0) + 1, 300000, ok);
            if (ok) $display("[tb] case 3.%0d PASS: restarted, line %0d", rep, nlines);
            else  begin $display("[tb] case 3.%0d FAIL: silent for 300k cycles after release", rep); errs++; end
        end

        if (errs) $display("\n[tb] RESULT: %0d case(s) FAILED", errs);
        else      $display("\n[tb] RESULT: PASS -- CVA5 restarts from a mid-run reset in every case");
        $finish;
    end
endmodule
