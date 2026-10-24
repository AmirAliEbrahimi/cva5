/*
 * tb_i2c -- cva5_i2c_axi against a behavioural I2C slave on the same two
 * wires.
 *
 * The master is upstream's and well tested there, so what this proves is the
 * wrapper and the programming model: that the register map is where soc.h says
 * it is, that the open-drain tie-off actually drives and releases the lines,
 * that a write reaches a slave at the right address with the right byte, that
 * a read brings a byte back, and that a transfer to an address nothing answers
 * is reported as a missed ACK rather than hanging.
 *
 * The slave model is deliberately not Forencich's i2c_slave: that one has AXI
 * stream control interfaces, so driving it would mean more testbench than
 * writing the protocol out by hand, and a second copy of the same author's
 * assumptions proves less than an independent one.
 *
 * Run from the repo root:  bash test_benches/axi/run_i2c.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module tb_i2c;

    //Byte offsets, four words.
    localparam int unsigned REG_STATUS   = 32'h0;
    localparam int unsigned REG_COMMAND  = 32'h4;
    localparam int unsigned REG_DATA     = 32'h8;
    localparam int unsigned REG_PRESCALE = 32'hC;

    //STATUS bits
    localparam int unsigned ST_BUSY        = 32'h1;
    localparam int unsigned ST_BUS_ACTIVE  = 32'h4;
    localparam int unsigned ST_MISSED_ACK  = 32'h8;
    localparam int unsigned ST_RD_FIFO_EMPTY = 32'h4000;

    //COMMAND bits
    localparam int unsigned CMD_START    = 32'h100;
    localparam int unsigned CMD_READ     = 32'h200;
    localparam int unsigned CMD_WRITE    = 32'h400;
    localparam int unsigned CMD_WR_MULTI = 32'h800;
    localparam int unsigned CMD_STOP     = 32'h1000;

    localparam logic [6:0] SLAVE_ADDR = 7'h50;   //the model answers here
    localparam logic [6:0] NOBODY     = 7'h23;   //nothing answers here

    logic clk = 0;
    always #5 clk = ~clk;              //100 MHz
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

    //==================================================================
    // The bus: open drain with pull-ups, which is what the real one is
    //==================================================================
    wire scl, sda;
    pullup pu_scl (scl);
    pullup pu_sda (sda);

    //==================================================================
    // DUT
    //==================================================================
    logic [11:0] awaddr, araddr;
    logic [31:0] wdata, rdata;
    logic        awvalid, awready, wvalid, wready;
    logic        bvalid, bready, arvalid, arready, rvalid, rready;
    logic [1:0]  bresp, rresp;

    //A prescale of 4 keeps SCL fast enough for a short simulation; the board
    //uses 250 for 100 kHz.
    //The DUT instantiates IOBUFs, which test_benches/axi/IOBUF_stub.v models
    //for Verilator -- so the open-drain behaviour checked below goes through
    //the same structure synthesis builds, rather than a second expression of
    //it written for simulation.
    cva5_i2c_axi #(
        .ADDR_WIDTH (12),
        .DEFAULT_PRESCALE (4),
        .FIFO_DEPTH (32)
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
        .scl (scl), .sda (sda)
    );

    //==================================================================
    // AXI4-Lite master
    //==================================================================
    task automatic reg_write(input logic [11:0] addr, input logic [31:0] data);
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

    task automatic reg_read(input logic [11:0] addr, output logic [31:0] data);
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
    // I2C slave model: one 7-bit address, one byte of storage.
    //
    // Written out rather than reused so that it is an independent reading of
    // the protocol: sample SDA on the rising edge of SCL, change it on the
    // falling edge, ACK by pulling SDA low for the ninth clock.
    //==================================================================
    logic sda_drive_low = 0;           //the model's open-drain output
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    logic [7:0] slave_mem = 8'h00;     //what was written to the model
    logic [7:0] slave_next_read = 8'hA7;  //what it will hand back
    int unsigned slave_writes = 0, slave_reads = 0;
    logic slave_saw_addr = 0;

    initial begin : slave
        logic [7:0] shifted;
        logic       is_read;
        forever begin
            //--- wait for a start: SDA falling while SCL is high
            @(negedge sda);
            if (scl !== 1'b1) continue;

            //--- address byte, MSB first
            shifted = 8'h0;
            for (int i = 0; i < 8; i++) begin
                @(posedge scl);
                shifted = {shifted[6:0], sda};
            end
            is_read = shifted[0];

            if (shifted[7:1] !== SLAVE_ADDR) begin
                //not for us: stay off the bus entirely
                continue;
            end
            slave_saw_addr <= 1'b1;

            //--- ACK the address
            @(negedge scl);
            sda_drive_low <= 1'b1;
            @(negedge scl);
            sda_drive_low <= 1'b0;

            if (is_read) begin
                //--- hand back one byte, then let the master NACK it
                for (int i = 7; i >= 0; i--) begin
                    sda_drive_low <= ~slave_next_read[i];
                    @(negedge scl);
                end
                sda_drive_low <= 1'b0;
                slave_reads <= slave_reads + 1;
                @(posedge scl);          //the master's ack/nack bit
            end
            else begin
                //--- take one byte and ACK it
                shifted = 8'h0;
                for (int i = 0; i < 8; i++) begin
                    @(posedge scl);
                    shifted = {shifted[6:0], sda};
                end
                slave_mem <= shifted;
                slave_writes <= slave_writes + 1;
                @(negedge scl);
                sda_drive_low <= 1'b1;
                @(negedge scl);
                sda_drive_low <= 1'b0;
            end
        end
    end

    //==================================================================
    task automatic await_idle(input int unsigned limit = 200000);
        int unsigned guard;
        logic [31:0] st;
        guard = 0;
        //let the command reach the core first
        repeat (20) @(negedge clk);
        forever begin
            reg_read(REG_STATUS, st);
            if (!(st & (ST_BUSY | ST_BUS_ACTIVE)))
                return;
            guard++;
            if (guard > limit) begin
                $error("bus never went idle, status 0x%08x", st);
                errors++;
                return;
            end
            repeat (20) @(negedge clk);
        end
    endtask

    logic [31:0] v;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0;

        repeat (4) @(negedge clk);
        rstn = 1;
        repeat (8) @(negedge clk);

        //---- the register file
        $display("-- registers");
        reg_read(REG_PRESCALE, v);
        expect_eq("prescale comes up at its default", v, 32'd4);
        reg_write(REG_PRESCALE, 32'd9);
        reg_read(REG_PRESCALE, v);
        expect_eq("prescale reads back", v, 32'd9);
        reg_write(REG_PRESCALE, 32'd4);

        reg_read(REG_STATUS, v);
        expect_eq("idle out of reset", v & (ST_BUSY | ST_BUS_ACTIVE), 32'd0);
        expect_eq("no missed ack yet", v & ST_MISSED_ACK, 32'd0);
        expect_eq("the read FIFO is empty", v & ST_RD_FIFO_EMPTY,
                  ST_RD_FIFO_EMPTY);

        expect_eq("both lines are released at rest",
                  {31'b0, scl & sda}, 32'd1);

        //---- a write to the slave
        $display("-- write a byte");
        reg_write(REG_DATA, 32'h5A);
        reg_write(REG_COMMAND, 32'(SLAVE_ADDR) | CMD_START | CMD_WRITE | CMD_STOP);
        await_idle();

        expect_eq("the slave was addressed", 32'(slave_saw_addr), 32'd1);
        expect_eq("the slave took one write", 32'(slave_writes), 32'd1);
        expect_eq("and got the byte", 32'(slave_mem), 32'h5A);
        reg_read(REG_STATUS, v);
        expect_eq("the address was acked", v & ST_MISSED_ACK, 32'd0);

        //---- a read from the slave
        $display("-- read a byte");
        slave_next_read = 8'hA7;
        reg_write(REG_COMMAND, 32'(SLAVE_ADDR) | CMD_START | CMD_READ | CMD_STOP);
        await_idle();

        expect_eq("the slave served one read", 32'(slave_reads), 32'd1);
        reg_read(REG_STATUS, v);
        expect_eq("a byte is waiting", v & ST_RD_FIFO_EMPTY, 32'd0);
        reg_read(REG_DATA, v);
        expect_eq("and it is the byte the slave sent", v & 32'hFF, 32'hA7);
        expect_eq("marked valid", v & 32'h100, 32'h100);
        reg_read(REG_STATUS, v);
        expect_eq("reading it emptied the FIFO", v & ST_RD_FIFO_EMPTY,
                  ST_RD_FIFO_EMPTY);

        //---- a second byte, so a stuck value cannot pass twice
        slave_next_read = 8'h3C;
        reg_write(REG_COMMAND, 32'(SLAVE_ADDR) | CMD_START | CMD_READ | CMD_STOP);
        await_idle();
        reg_read(REG_DATA, v);
        expect_eq("a differently shaped byte also comes back",
                  v & 32'hFF, 32'h3C);

        //---- an address nobody answers
        $display("-- missed ack");
        reg_write(REG_DATA, 32'hFF);
        reg_write(REG_COMMAND, 32'(NOBODY) | CMD_START | CMD_WRITE | CMD_STOP);
        await_idle();

        reg_read(REG_STATUS, v);
        expect_eq("an unanswered address is reported, not hung",
                  v & ST_MISSED_ACK, ST_MISSED_ACK);
        expect_eq("the slave did not take it", 32'(slave_writes), 32'd1);

        //missed_ack is sticky and write-1-to-clear
        reg_write(REG_STATUS, ST_MISSED_ACK);
        reg_read(REG_STATUS, v);
        expect_eq("and the flag clears when written", v & ST_MISSED_ACK, 32'd0);

        //---- and the bus still works afterwards
        $display("-- recovery");
        reg_write(REG_DATA, 32'h77);
        reg_write(REG_COMMAND, 32'(SLAVE_ADDR) | CMD_START | CMD_WRITE | CMD_STOP);
        await_idle();
        expect_eq("a good transfer follows a missed ack",
                  32'(slave_mem), 32'h77);
        expect_eq("the slave counted it", 32'(slave_writes), 32'd2);

        if (errors == 0)
            $display("PASS tb_i2c: %0d checks", checks);
        else
            $display("FAIL tb_i2c: %0d of %0d checks failed", errors, checks);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL tb_i2c (timeout)");
        $finish;
    end

endmodule
