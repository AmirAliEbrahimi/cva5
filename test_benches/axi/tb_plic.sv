/*
 * tb_plic -- cva5_plic_axi: the PLIC through its AXI4-Lite port.
 *
 * The PLIC itself is upstream CVA5's, vendored under a new name, so what needs
 * proving is not the arbitration tree in isolation but that the whole block
 * behaves as the register map says when driven the way the crossbar drives it:
 *
 *   - the registers read back what was written, and the two the spec pins down
 *     stay pinned: source 0's priority and enable bit are always zero;
 *   - pending follows a level source, and eip needs enable AND a priority
 *     strictly above the threshold on top of that;
 *   - a claim returns the highest-priority pending source, suppresses it while
 *     it is in progress, and a complete releases it -- with a level source
 *     still asserted, pending comes straight back;
 *   - an edge source latches a one-cycle pulse and stays pending after it;
 *   - ties go to the lower source id, which is what the tree's
 *     `left_priority > right_priority` does and what the spec recommends;
 *   - a threshold above everything suppresses the lot, and a claim with
 *     nothing pending reads 0.
 *
 * Run from the repo root:  bash test_benches/axi/run_plic.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module tb_plic #(
    parameter int unsigned NUM_SOURCES = 8,
    parameter int unsigned PRIORITY_W  = 4
);

    //Standard RISC-V PLIC layout, as byte offsets into the window.
    localparam int unsigned PENDING   = 32'h0000_1000;
    localparam int unsigned ENABLE    = 32'h0000_2000;
    localparam int unsigned THRESHOLD = 32'h0020_0000;
    localparam int unsigned CLAIM     = 32'h0020_0004;

    function automatic int unsigned PRIO(input int unsigned src);
        return 4 * src;
    endfunction

    logic clk = 0;
    always #5 clk = ~clk;
    logic rstn = 0;

    int unsigned checks = 0;
    int unsigned errors = 0;

    task automatic expect_eq(input string what, input logic [31:0] got,
                             input logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            $error("%s: got 0x%08x expected 0x%08x", what, got, exp);
            errors++;
        end
    endtask

    //The gateway registers its inputs and the priority tree has a register
    //stage, so nothing is expected to be visible in the same cycle.
    task automatic settle();
        repeat (4) @(negedge clk);
    endtask

    //==================================================================
    // DUT
    //==================================================================
    logic [25:0] awaddr, araddr;
    logic [31:0] wdata, rdata;
    logic        awvalid, awready, wvalid, wready;
    logic        bvalid, bready, arvalid, arready, rvalid, rready;
    logic [1:0]  bresp, rresp;

    //Stimulus is always eight bits wide and only the low NUM_SOURCES of it
    //reach the DUT. The multi-source sections below are guarded by a runtime
    //`if`, not a generate, so a narrow build would otherwise see
    //out-of-range selects in code it never executes.
    logic [7:0] src = '0;
    logic       eip;

    //Source 3 is wired as edge sensitive, every other source as level --
    //sensitivity is a build-time parameter, so the bench instantiates the
    //configuration it tests rather than driving a port.
    cva5_plic_axi #(
        .NUM_SOURCES (NUM_SOURCES),
        .PRIORITY_W (PRIORITY_W),
        .REG_STAGE (1),
        .EDGE_SENSITIVE (32'h4),   //bit 2 is source 3
        .ADDR_WIDTH (26)
    ) dut (
        .clk (clk), .rstn (rstn),
        .s_axi_awaddr (awaddr), .s_axi_awprot (3'b000),
        .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (4'hF),
        .s_axi_wvalid (wvalid), .s_axi_wready (wready),
        .s_axi_bresp (bresp), .s_axi_bvalid (bvalid), .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arprot (3'b000),
        .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata (rdata), .s_axi_rresp (rresp),
        .s_axi_rvalid (rvalid), .s_axi_rready (rready),
        .irq_srcs (src[NUM_SOURCES-1:0]),
        .eip (eip)
    );

    //==================================================================
    // AXI4-Lite master
    //
    // cva5_plic_wrapper's state machine leaves IDLE for a write only when
    // awvalid and wvalid are both up, so both channels are driven together --
    // which is also what the Lite crossbar does.
    //==================================================================
    task automatic reg_write(input logic [25:0] addr, input logic [31:0] data);
        awaddr = addr; wdata = data;
        awvalid = 1; wvalid = 1;
        while (!(awready && wready)) @(negedge clk);
        @(negedge clk);
        awvalid = 0; wvalid = 0;
        bready = 1;
        while (!bvalid) @(negedge clk);
        expect_eq("write response is OKAY", 32'(bresp), 32'd0);
        @(negedge clk);
        bready = 0;
    endtask

    task automatic reg_read(input logic [25:0] addr, output logic [31:0] data);
        araddr = addr; arvalid = 1;
        while (!arready) @(negedge clk);
        @(negedge clk);
        arvalid = 0;
        rready = 1;
        while (!rvalid) @(negedge clk);
        data = rdata;
        expect_eq("read response is OKAY", 32'(rresp), 32'd0);
        @(negedge clk);
        rready = 0;
    endtask

    //==================================================================
    logic [31:0] v;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0;

        repeat (4) @(negedge clk);
        rstn = 1;
        settle();

        //---- out of reset
        $display("-- reset state");
        expect_eq("eip low out of reset", 32'(eip), 32'd0);
        reg_read(PENDING, v);
        expect_eq("nothing pending", v, 32'd0);
        reg_read(ENABLE, v);
        expect_eq("nothing enabled", v, 32'd0);
        reg_read(THRESHOLD, v);
        expect_eq("threshold zero", v, 32'd0);
        reg_read(CLAIM, v);
        expect_eq("claim with nothing pending reads 0", v, 32'd0);

        //---- the register file
        $display("-- registers");
        reg_write(PRIO(1), 32'd2);
        reg_read(PRIO(1), v);
        expect_eq("source 1 priority", v, 32'd2);

        if (NUM_SOURCES >= 3) begin
            reg_write(PRIO(3), 32'd7);
            reg_read(PRIO(3), v);
            expect_eq("source 3 priority", v, 32'd7);
            reg_read(PRIO(1), v);
            expect_eq("source 1 priority is untouched by source 3", v, 32'd2);
        end

        reg_write(PRIO(0), 32'd15);
        reg_read(PRIO(0), v);
        expect_eq("source 0 priority stays zero", v, 32'd0);

        reg_write(ENABLE, 32'hFFFF_FFFF);
        reg_read(ENABLE, v);
        expect_eq("enables, with bit 0 forced low",
                  v, 32'((1 << (NUM_SOURCES + 1)) - 2));

        reg_write(THRESHOLD, 32'd5);
        reg_read(THRESHOLD, v);
        expect_eq("threshold", v, 32'd5);
        reg_write(THRESHOLD, 32'd0);

        //---- a level source, and what eip needs on top of pending
        $display("-- level source, pending and eip");
        reg_write(ENABLE, 32'd0);
        reg_write(PRIO(1), 32'd0);
        src[0] = 1'b1;              //source 1
        settle();

        reg_read(PENDING, v);
        expect_eq("pending follows the source regardless of enable",
                  v, 32'd2);
        expect_eq("eip needs an enable", 32'(eip), 32'd0);

        reg_write(ENABLE, 32'd2);        //enable source 1
        settle();
        expect_eq("eip still needs priority above the threshold",
                  32'(eip), 32'd0);      //priority 0 is never above 0

        reg_write(PRIO(1), 32'd1);
        settle();
        expect_eq("enabled and above threshold: eip", 32'(eip), 32'd1);

        //---- claim and complete
        $display("-- claim and complete");
        reg_read(CLAIM, v);
        expect_eq("claim returns source 1", v, 32'd1);
        settle();
        expect_eq("eip drops while the claim is in progress", 32'(eip), 32'd0);
        reg_read(PENDING, v);
        expect_eq("and it is no longer pending", v, 32'd0);

        reg_write(CLAIM, 32'd1);         //complete
        settle();
        expect_eq("the still-asserted level source comes back after complete",
                  32'(eip), 32'd1);
        reg_read(PENDING, v);
        expect_eq("pending again", v, 32'd2);

        src[0] = 1'b0;              //drop the line, then clear it out
        reg_read(CLAIM, v);
        expect_eq("claim returns source 1 again", v, 32'd1);
        reg_write(CLAIM, 32'd1);
        settle();
        expect_eq("with the line low it stays clear", 32'(eip), 32'd0);
        reg_read(PENDING, v);
        expect_eq("nothing pending", v, 32'd0);

        //---- the rest needs more than one source. The block design deploys
        //NUM_SOURCES = 1 -- one UART -- and that configuration takes different
        //widths inside the PLIC (a 1-bit claim id, a 2-entry padded source
        //vector), so it is swept as its own run rather than assumed.
        if (NUM_SOURCES >= 3) begin

        //---- an edge source latches a pulse
        $display("-- edge source");
        reg_write(PRIO(3), 32'd3);       //source 3 is the edge-sensitive one
        reg_write(ENABLE, 32'd8);
        settle();

        src[2] = 1'b1;
        @(negedge clk);
        src[2] = 1'b0;              //one cycle, then gone
        settle();

        reg_read(PENDING, v);
        expect_eq("the pulse is still pending", v, 32'd8);
        expect_eq("and eip is up", 32'(eip), 32'd1);
        reg_read(CLAIM, v);
        expect_eq("claim returns source 3", v, 32'd3);
        reg_write(CLAIM, 32'd3);
        settle();
        expect_eq("a completed edge source does not come back",
                  32'(eip), 32'd0);
        reg_read(PENDING, v);
        expect_eq("and nothing is pending", v, 32'd0);

        //---- priority order, and ties
        //
        //Both sources are level sensitive and both lines stay up until the
        //handler quiets the device, so each one is dropped before its complete
        //-- which is the order real software has to use. Completing a source
        //whose line is still asserted puts it straight back into pending, and
        //if it is the highest priority one it wins the next claim as well.
        //That is not a quirk to work around; it is how a shared line gets
        //serviced to completion.
        $display("-- priority and ties");
        reg_write(PRIO(1), 32'd4);
        reg_write(PRIO(2), 32'd9);
        reg_write(ENABLE, 32'd6);        //sources 1 and 2
        src[0] = 1'b1;
        src[1] = 1'b1;
        settle();

        reg_read(CLAIM, v);
        expect_eq("the higher priority is claimed first", v, 32'd2);
        src[1] = 1'b0;              //the handler services the device
        reg_write(CLAIM, 32'd2);
        settle();
        reg_read(CLAIM, v);
        expect_eq("then the lower one", v, 32'd1);
        src[0] = 1'b0;
        reg_write(CLAIM, 32'd1);
        settle();
        expect_eq("and then nothing is left", 32'(eip), 32'd0);

        //A completed source whose line is still high comes back, even behind
        //a lower-priority one: raise both again, claim the high one, and
        //complete it without quieting it.
        reg_write(PRIO(1), 32'd4);
        reg_write(PRIO(2), 32'd9);
        src[0] = 1'b1;
        src[1] = 1'b1;
        settle();
        reg_read(CLAIM, v);
        expect_eq("the high one again", v, 32'd2);
        reg_write(CLAIM, 32'd2);         //not serviced: the line is still up
        settle();
        reg_read(CLAIM, v);
        expect_eq("an unserviced level source is re-claimed ahead of the rest",
                  v, 32'd2);
        src[1] = 1'b0;
        reg_write(CLAIM, 32'd2);
        settle();
        reg_read(CLAIM, v);
        expect_eq("and only then does the low one get its turn", v, 32'd1);
        src[0] = 1'b0;
        reg_write(CLAIM, 32'd1);
        settle();

        //Ties go to the lower id.
        reg_write(PRIO(1), 32'd6);
        reg_write(PRIO(2), 32'd6);       //equal
        src[0] = 1'b1;
        src[1] = 1'b1;
        settle();
        reg_read(CLAIM, v);
        expect_eq("a tie goes to the lower source id", v, 32'd1);
        src[0] = 1'b0;
        reg_write(CLAIM, 32'd1);
        settle();
        reg_read(CLAIM, v);
        expect_eq("and the other follows", v, 32'd2);
        reg_write(CLAIM, 32'd2);
        settle();

        end //NUM_SOURCES >= 3

        //Set up whatever this build has for the threshold checks: source 1
        //always, source 2 as well when it exists, both at priority 6.
        reg_write(PRIO(1), 32'd6);
        reg_write(ENABLE, NUM_SOURCES >= 3 ? 32'd6 : 32'd2);
        src[0] = 1'b1;
        if (NUM_SOURCES >= 3) begin
            reg_write(PRIO(2), 32'd6);
            src[1] = 1'b1;
        end
        settle();
        expect_eq("pending, eip up", 32'(eip), 32'd1);

        //---- the threshold suppresses what is pending, with whatever is
        //pending: both sources when there are three or more, otherwise the
        //one the single-source build has.
        $display("-- threshold");
        reg_write(THRESHOLD, 32'd15);
        settle();
        expect_eq("a threshold above every priority holds eip down",
                  32'(eip), 32'd0);
        reg_read(PENDING, v);
        expect_eq("the sources are still pending underneath",
                  v, NUM_SOURCES >= 3 ? 32'd6 : 32'd2);
        reg_read(CLAIM, v);
        expect_eq("and a claim reads 0", v, 32'd0);

        reg_write(THRESHOLD, 32'd5);
        settle();
        expect_eq("lowering it lets them through again", 32'(eip), 32'd1);

        src = '0;

        if (errors == 0)
            $display("PASS tb_plic: %0d checks (NUM_SOURCES=%0d PRIORITY_W=%0d)",
                     checks, NUM_SOURCES, PRIORITY_W);
        else
            $display("FAIL tb_plic: %0d of %0d checks failed", errors, checks);
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL tb_plic (timeout)");
        $finish;
    end

endmodule
