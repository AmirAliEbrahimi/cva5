/*
 * tb_irq_concat -- cva5_irq_concat driving a real cva5_plic_axi.
 *
 * cva5_irq_concat is one assignment, so a bench for it in isolation would
 * restate that assignment and prove nothing. What is worth proving is the
 * composition the block design builds, and the two claims made about it that
 * are not obvious from either file alone:
 *
 *   - which port lands on which PLIC source. src1 is source 1, which is
 *     irq_srcs[0], because RISC-V reserves source 0. Swapping two sources
 *     costs nothing in area or timing, passes synthesis, passes lint, and
 *     shows up only as a device whose interrupt is attributed to another one.
 *     So each source is raised alone and claimed by number.
 *
 *   - that a pulse is caught with the source left level sensitive. The SPI's
 *     irq is end-of-transfer, one cycle, and the block design does not set its
 *     EDGE_SENSITIVE bit, on the grounds that the PLIC's gateway latches:
 *     `ip <= (ip | raise) & ~in_progress & ~claim`. That is a claim about
 *     vendored upstream code, so it is checked here rather than asserted in a
 *     comment -- and checked at one cycle wide, which is the width that would
 *     fail if the gateway did not latch.
 *
 * Run from the repo root:  bash test_benches/axi/run_irq_concat.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module tb_irq_concat;

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
    // The design under test: the concat wired to the PLIC exactly as
    // examples/xilinx/pynq_z2_sys.tcl wires them.
    //==================================================================
    logic uart_irq = 0;      //what cva5_uart's irq does: a level
    logic spi_irq  = 0;      //what cva5_spi_axi's irq does: a pulse
    logic [1:0] irq_srcs;
    logic eip;

    cva5_irq_concat concat_inst (
        .src1 (uart_irq),
        .src2 (spi_irq),
        .irq_srcs (irq_srcs)
    );

    logic [25:0] awaddr, araddr;
    logic [31:0] wdata, rdata;
    logic        awvalid, awready, wvalid, wready;
    logic        bvalid, bready, arvalid, arready, rvalid, rready;
    logic [1:0]  bresp, rresp;

    //NUM_SOURCES 2 and EDGE_SENSITIVE 0, which is the board's configuration.
    cva5_plic_axi #(
        .NUM_SOURCES (2),
        .PRIORITY_W (4),
        .REG_STAGE (1),
        .EDGE_SENSITIVE (32'h0),
        .ADDR_WIDTH (26)
    ) plic (
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
        .irq_srcs (irq_srcs),
        .eip (eip)
    );

    //==================================================================
    // AXI4-Lite master. Both write channels are driven together, which is what
    // cva5_plic_wrapper's state machine waits for and what the Lite crossbar
    // does.
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

    //Claim, then complete what was claimed, so the next section starts clean.
    task automatic claim_and_complete(output logic [31:0] id);
        reg_read(CLAIM, id);
        if (id != 0)
            reg_write(CLAIM, id);
        settle();
    endtask

    //==================================================================
    logic [31:0] v;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0;

        repeat (4) @(negedge clk);
        rstn = 1;
        settle();

        //---- the wiring at rest
        $display("-- at rest");
        expect_eq("both lines low gives an empty vector", 32'(irq_srcs), 32'd0);
        reg_read(PENDING, v);
        expect_eq("nothing pending", v, 32'd0);

        reg_write(ENABLE, 32'h6);          //sources 1 and 2
        reg_write(PRIO(1), 32'd3);
        reg_write(PRIO(2), 32'd3);
        reg_write(THRESHOLD, 32'd0);
        settle();
        expect_eq("eip still low with nothing raised", 32'(eip), 32'd0);

        //---- source 1 alone. The UART's port, and the UART's shape: a level.
        $display("-- src1 is PLIC source 1");
        uart_irq = 1'b1;
        settle();
        expect_eq("src1 drives bit 0 only", 32'(irq_srcs), 32'd1);
        reg_read(PENDING, v);
        expect_eq("and source 1 alone is pending", v, 32'h2);
        expect_eq("eip is up", 32'(eip), 32'd1);
        claim_and_complete(v);
        expect_eq("the claim names source 1", v, 32'd1);

        //A level that is still asserted comes straight back after a complete,
        //which is the UART with a byte still in its FIFO.
        reg_read(PENDING, v);
        expect_eq("a level source re-raises after complete", v, 32'h2);
        uart_irq = 1'b0;
        settle();
        claim_and_complete(v);
        reg_read(PENDING, v);
        expect_eq("and stays down once the device is quiet", v, 32'd0);

        //---- source 2 alone. The SPI's port.
        $display("-- src2 is PLIC source 2");
        spi_irq = 1'b1;
        settle();
        expect_eq("src2 drives bit 1 only", 32'(irq_srcs), 32'd2);
        reg_read(PENDING, v);
        expect_eq("and source 2 alone is pending", v, 32'h4);
        spi_irq = 1'b0;
        settle();
        claim_and_complete(v);
        expect_eq("the claim names source 2", v, 32'd2);
        reg_read(PENDING, v);
        expect_eq("nothing left pending", v, 32'd0);

        //---- the pulse, one cycle wide, with the source level sensitive
        $display("-- a one-cycle pulse on src2");
        @(negedge clk);
        spi_irq = 1'b1;
        @(negedge clk);
        spi_irq = 1'b0;
        settle();

        reg_read(PENDING, v);
        expect_eq("one cycle high latches in the gateway", v, 32'h4);
        expect_eq("and eip stays up after the pulse is gone",
                  32'(eip), 32'd1);
        claim_and_complete(v);
        expect_eq("the pulse claims as source 2", v, 32'd2);
        reg_read(PENDING, v);
        expect_eq("and a pulse does not re-raise on complete", v, 32'd0);
        expect_eq("eip back down", 32'(eip), 32'd0);

        //---- both at once, which is the case the source numbers decide
        $display("-- both, and priority picks between them");
        reg_write(PRIO(1), 32'd2);
        reg_write(PRIO(2), 32'd5);
        uart_irq = 1'b1;
        spi_irq  = 1'b1;
        settle();
        expect_eq("both lines give both bits", 32'(irq_srcs), 32'd3);
        reg_read(PENDING, v);
        expect_eq("both pending", v, 32'h6);
        reg_read(CLAIM, v);
        expect_eq("the higher priority wins and it is source 2", v, 32'd2);
        reg_write(CLAIM, v);

        //Now the other way round, so the result follows the priority rather
        //than the source number, and a swapped concat would show up here as
        //the wrong device being named.
        spi_irq = 1'b0;
        settle();
        claim_and_complete(v);          //drain source 1
        reg_write(PRIO(1), 32'd5);
        reg_write(PRIO(2), 32'd2);
        uart_irq = 1'b1;
        spi_irq  = 1'b1;
        settle();
        reg_read(CLAIM, v);
        expect_eq("with the priorities swapped it is source 1", v, 32'd1);
        reg_write(CLAIM, v);

        //---- and only the enabled source reaches eip
        $display("-- enable picks per source");
        uart_irq = 1'b0;
        spi_irq  = 1'b0;
        settle();
        claim_and_complete(v);
        reg_write(ENABLE, 32'h2);        //source 1 only
        settle();

        spi_irq = 1'b1;
        settle();
        reg_read(PENDING, v);
        expect_eq("source 2 is pending with only source 1 enabled", v, 32'h4);
        expect_eq("but eip stays down", 32'(eip), 32'd0);

        uart_irq = 1'b1;
        settle();
        expect_eq("source 1 brings eip up", 32'(eip), 32'd1);
        reg_read(CLAIM, v);
        expect_eq("and the claim can only be source 1", v, 32'd1);

        if (errors == 0)
            $display("PASS tb_irq_concat: %0d checks", checks);
        else
            $display("FAIL tb_irq_concat: %0d of %0d checks failed",
                     errors, checks);
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL tb_irq_concat (timeout)");
        $finish;
    end

endmodule
