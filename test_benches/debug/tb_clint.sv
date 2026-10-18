/*
 * tb_clint -- cva5_clint's prescaled mtime (the vendored CLINT).
 *
 * The divergence from apu/clint/clint.sv is that mtime increments on a
 * prescaled tick instead of every clock, so that is what this measures: the
 * tick interval, that writes still land immediately and restart the prescaler,
 * and that TICKS_PER_USEC = 1 restores upstream's behaviour exactly.
 *
 * mtimecmp, msip and mtip are upstream's and are checked here only to the
 * extent that the prescaler must not have broken them.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
module tb_clint;

    localparam int unsigned TPU = 4;    //clocks per tick, small for simulation

    logic clk = 0;
    logic rst = 1;
    always #5 clk = ~clk;

    int errors = 0;

    task automatic chk(input logic cond, input string what);
        if (!cond) begin
            $error("%s", what);
            errors++;
        end
    endtask

    //------------------------------------------------------------------
    //Two instances: the prescaled one, and TICKS_PER_USEC = 1, which must
    //behave exactly as upstream did.
    //------------------------------------------------------------------
    logic write_mtime, write_mtimecmp, write_msip, write_upper;
    logic [31:0] write_data;

    logic [1:0][31:0] mtime_p, mtime_1;
    logic [0:0][1:0][31:0] mtimecmp_p, mtimecmp_1;
    logic [0:0] msip_p, msip_1, mtip_p, mtip_1;

    cva5_clint #(.NUM_CORES(1), .TICKS_PER_USEC(TPU)) dut_p (
        .clk, .rst,
        .write_mtime, .write_mtimecmp, .write_msip, .write_upper,
        .write_msip_core ('0), .write_mtimecmp_core ('0), .write_data,
        .mtime (mtime_p), .mtimecmp (mtimecmp_p), .msip (msip_p), .mtip (mtip_p)
    );

    cva5_clint #(.NUM_CORES(1), .TICKS_PER_USEC(1)) dut_1 (
        .clk, .rst,
        .write_mtime, .write_mtimecmp, .write_msip, .write_upper,
        .write_msip_core ('0), .write_mtimecmp_core ('0), .write_data,
        .mtime (mtime_1), .mtimecmp (mtimecmp_1), .msip (msip_1), .mtip (mtip_1)
    );

    function automatic logic [63:0] t_p();
        return {mtime_p[1], mtime_p[0]};
    endfunction
    function automatic logic [63:0] t_1();
        return {mtime_1[1], mtime_1[0]};
    endfunction

    task automatic idle(input int n);
        repeat (n) @(negedge clk);
    endtask

    task automatic wr(input logic mt, input logic mtc, input logic ms,
                      input logic upper, input logic [31:0] d);
        @(negedge clk);
        write_mtime = mt; write_mtimecmp = mtc; write_msip = ms;
        write_upper = upper; write_data = d;
        @(negedge clk);
        write_mtime = 0; write_mtimecmp = 0; write_msip = 0;
    endtask

    logic [63:0] t0;
    int          seen;

    initial begin
        write_mtime = 0; write_mtimecmp = 0; write_msip = 0;
        write_upper = 0; write_data = 0;

        idle(3);
        rst = 0;
        idle(2);

        //--- reset values
        chk(t_p() == 64'd0, $sformatf("mtime after reset is %0d", t_p()));
        chk(mtimecmp_p[0] == '1, "mtimecmp did not reset to all ones");
        chk(mtip_p == 1'b0, "mtip asserted after reset");
        chk(msip_p == 1'b0, "msip asserted after reset");
        $display("  reset values            ok");

        //--- the tick interval: TPU clocks per increment
        t0 = t_p();
        idle(TPU * 10);
        seen = int'(t_p() - t0);
        chk(seen == 10, $sformatf("mtime advanced %0d in %0d clocks, expected 10",
                                  seen, TPU * 10));
        $display("  tick interval           ok (%0d clocks per tick)", TPU);

        //--- TICKS_PER_USEC = 1 is upstream: one increment per clock
        t0 = t_1();
        idle(10);
        seen = int'(t_1() - t0);
        chk(seen == 10,
            $sformatf("TICKS_PER_USEC=1 advanced %0d in 10 clocks, expected 10", seen));
        $display("  TICKS_PER_USEC=1        ok (upstream behaviour)");

        //--- a write lands immediately, whatever the prescaler is doing
        wr(1'b1, 1'b0, 1'b0, 1'b0, 32'h0000_1000);   //low half
        chk(mtime_p[0] == 32'h0000_1000,
            $sformatf("mtime low is 0x%08x after a write of 0x1000", mtime_p[0]));
        wr(1'b1, 1'b0, 1'b0, 1'b1, 32'h0000_0007);   //high half
        chk(mtime_p[1] == 32'h0000_0007,
            $sformatf("mtime high is 0x%08x after a write of 0x7", mtime_p[1]));
        $display("  writes land             ok");

        //--- and the write restarted the prescaler: a full interval must pass
        //    before the next increment. Sample just before and just after.
        wr(1'b1, 1'b0, 1'b0, 1'b0, 32'h0000_2000);
        t0 = t_p();
        idle(TPU - 2);
        chk(t_p() == t0,
            $sformatf("mtime moved %0d clocks after a write, before a full tick",
                      TPU - 2));
        idle(3);
        chk(t_p() == t0 + 1,
            $sformatf("mtime is %0d one tick after the write, expected %0d",
                      t_p(), t0 + 1));
        $display("  write restarts tick     ok");

        //--- mtimecmp and mtip, which the prescaler must not have disturbed
        wr(1'b1, 1'b0, 1'b0, 1'b0, 32'h0000_0000);
        wr(1'b1, 1'b0, 1'b0, 1'b1, 32'h0000_0000);   //mtime = 0
        wr(1'b0, 1'b1, 1'b0, 1'b1, 32'h0000_0000);   //mtimecmp high = 0
        wr(1'b0, 1'b1, 1'b0, 1'b0, 32'd20);          //mtimecmp low = 20
        idle(2);
        chk(mtip_p == 1'b0,
            $sformatf("mtip set early: mtime=%0d mtimecmp=20", t_p()));

        //20 ticks is 20*TPU clocks, plus slack for the comparison register
        idle(20 * TPU + 4);
        chk(mtip_p == 1'b1,
            $sformatf("mtip not set: mtime=%0d mtimecmp=20", t_p()));
        chk(t_p() >= 64'd20, $sformatf("mtime only reached %0d", t_p()));
        $display("  mtimecmp -> mtip        ok (at mtime=%0d)", t_p());

        //--- the boundary. mtip is "mtime >= mtimecmp", so it must set on the
        //    tick that makes them equal, not the one after. Park mtime one
        //    short of mtimecmp and watch the single tick that crosses it.
        //    mtimecmp is written first so that the mtime write is the last
        //    event: each wr() costs two clocks, and with the writes the other
        //    way round a tick fires between them.
        wr(1'b0, 1'b1, 1'b0, 1'b1, 32'h0000_0000);   //mtimecmp high = 0
        wr(1'b0, 1'b1, 1'b0, 1'b0, 32'd20);          //mtimecmp low = 20
        wr(1'b1, 1'b0, 1'b0, 1'b1, 32'h0000_0000);   //mtime high = 0
        wr(1'b1, 1'b0, 1'b0, 1'b0, 32'd19);          //mtime low = 19, restarts

        //The write reset the prescaler, so the tick that takes mtime to 20 is
        //TPU posedges away. Short of it, nothing has moved.
        idle(TPU - 1);
        chk(t_p() == 64'd19,
            $sformatf("mtime is %0d before the crossing tick, expected 19", t_p()));
        chk(mtip_p == 1'b0, "mtip set with mtime=19 mtimecmp=20");

        //Across it: mtime reaches exactly 20, and mtip follows a clock later
        //because it is registered off the comparison.
        idle(3);
        chk(t_p() == 64'd20,
            $sformatf("mtime is %0d after the crossing tick, expected 20", t_p()));
        chk(mtip_p == 1'b1,
            $sformatf("mtip not set at mtime == mtimecmp == 20 (mtime=%0d)", t_p()));
        $display("  mtip at mtime==cmp      ok");

        //--- raising mtimecmp clears it again
        wr(1'b0, 1'b1, 1'b0, 1'b0, 32'hFFFF_FFFF);
        idle(2);
        chk(mtip_p == 1'b0, "mtip still set after mtimecmp was raised");
        $display("  mtip clears             ok");

        //--- msip is a plain register
        wr(1'b0, 1'b0, 1'b1, 1'b0, 32'h1);
        idle(1);
        chk(msip_p == 1'b1, "msip did not set");
        wr(1'b0, 1'b0, 1'b1, 1'b0, 32'h0);
        idle(1);
        chk(msip_p == 1'b0, "msip did not clear");
        $display("  msip                    ok");

        if (errors == 0)
            $display("PASS tb_clint");
        else
            $display("FAIL tb_clint (%0d errors)", errors);
        $finish;
    end

    initial begin
        #200_000;
        $display("FAIL tb_clint (timeout)");
        $finish;
    end

endmodule
