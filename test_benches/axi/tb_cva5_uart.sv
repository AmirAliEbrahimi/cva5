/*
 * tb_cva5_uart -- the lowRISC UART behind its AXI4-Lite adapter.
 *
 * tx is tied back to rx, so a byte written to the TX register is transmitted,
 * received and read back out of the RX register: one test covers the adapter,
 * both FIFOs and both state machines. The bench also decodes the serial line
 * directly, so a byte that round-trips through a malformed frame cannot pass.
 *
 * The DUT runs at 8 clocks per bit (1 MHz / 125 kbaud) to keep the simulation
 * short. The divider is ClockFrequency / BaudRate inside the UART, so the
 * measured bit period checking out at 8 is what validates the arithmetic that
 * gives 10416 clocks on the board.
 *
 * The adapter's ready signals are combinational and last exactly one cycle, so
 * the master tasks drive on the falling edge, let the combinational path
 * settle, and sample in the same half cycle -- sampling a cycle later would
 * miss every handshake.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
module tb_cva5_uart;

    localparam int unsigned CLK_HZ = 1_000_000;
    localparam int unsigned BAUD   = 125_000;
    localparam int unsigned CPB    = CLK_HZ / BAUD;   //8 clocks per bit
    localparam int unsigned DEPTH  = 4;

    //Register offsets -- axi_uartlite's, which is the point of the divergence
    localparam logic [11:0] RX_OFF   = 12'h0;
    localparam logic [11:0] TX_OFF   = 12'h4;
    localparam logic [11:0] STAT_OFF = 12'h8;

    localparam int STAT_RX_DATA  = 0;
    localparam int STAT_RX_FULL  = 1;
    localparam int STAT_TX_EMPTY = 2;
    localparam int STAT_TX_FULL  = 3;

    logic clk = 0;
    logic rstn = 0;
    always #5 clk = ~clk;

    //Free-running cycle count, so bit periods are measured in clocks rather
    //than in whatever time unit the simulator picked.
    int unsigned cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    int errors = 0;

    task automatic chk(input logic cond, input string what);
        if (!cond) begin
            $error("%s", what);
            errors++;
        end
    endtask

    //------------------------------------------------------------------
    //DUT, in loopback
    //------------------------------------------------------------------
    //The address ports are as narrow as the IP's, so the testbench drives the
    //same widths synthesis sees.
    localparam int unsigned AW = 12;
    logic [AW-1:0] awaddr, araddr;
    logic [31:0] wdata, rdata;
    logic [3:0]  wstrb;
    logic awvalid, awready, wvalid, wready, bvalid, bready;
    logic arvalid, arready, rvalid, rready;
    logic [1:0] bresp, rresp;
    logic serial, irq;

    cva5_uart #(
        .CLOCK_FREQUENCY (CLK_HZ),
        .BAUD_RATE (BAUD),
        .RX_FIFO_DEPTH (DEPTH),
        .TX_FIFO_DEPTH (DEPTH)
    ) dut (
        .clk (clk),
        .rstn (rstn),
        .s_axi_awaddr (awaddr),
        .s_axi_awprot (3'b000),
        .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata (wdata),
        .s_axi_wstrb (wstrb),
        .s_axi_wvalid (wvalid),
        .s_axi_wready (wready),
        .s_axi_bresp (bresp),
        .s_axi_bvalid (bvalid),
        .s_axi_bready (bready),
        .s_axi_araddr (araddr),
        .s_axi_arprot (3'b000),
        .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rdata (rdata),
        .s_axi_rresp (rresp),
        .s_axi_rvalid (rvalid),
        .s_axi_rready (rready),
        .rx (serial),           //loopback: the UART hears itself
        .tx (serial),
        .irq (irq)
    );

    //------------------------------------------------------------------
    //AXI4-Lite master
    //------------------------------------------------------------------
    task automatic axi_write(input logic [11:0] addr, input logic [31:0] data,
                             input logic [3:0] strb = 4'hF);
        @(negedge clk);
        awaddr = addr; wdata = data; wstrb = strb;
        awvalid = 1'b1; wvalid = 1'b1; bready = 1'b1;
        #1;                                  //let the ready cone settle
        while (!(awready && wready)) begin
            @(negedge clk);
            #1;
        end
        @(negedge clk);                      //the posedge between took the beat
        awvalid = 1'b0; wvalid = 1'b0;
        #1;
        while (!bvalid) begin
            @(negedge clk);
            #1;
        end
        chk(bresp === 2'b00, $sformatf("write 0x%08x: BRESP = %0d", addr, bresp));
        @(negedge clk);
        bready = 1'b0;
    endtask

    task automatic axi_read(input logic [11:0] addr, output logic [31:0] data);
        @(negedge clk);
        araddr = addr; arvalid = 1'b1; rready = 1'b1;
        #1;
        while (!arready) begin
            @(negedge clk);
            #1;
        end
        @(negedge clk);
        arvalid = 1'b0;
        #1;
        while (!rvalid) begin
            @(negedge clk);
            #1;
        end
        data = rdata;
        chk(rresp === 2'b00, $sformatf("read 0x%08x: RRESP = %0d", addr, rresp));
        @(negedge clk);
        rready = 1'b0;
    endtask

    //Poll STAT until a bit is set, or give up.
    task automatic wait_stat(input int bitno, input int limit,
                             output logic [31:0] v);
        v = '0;
        for (int i = 0; i < limit; i++) begin
            axi_read(STAT_OFF, v);
            if (v[bitno]) return;
        end
    endtask

    //------------------------------------------------------------------
    //Independent decoder: one frame off the serial line, checking the start
    //bit, the data bits LSB-first and the stop bit.
    //------------------------------------------------------------------
    task automatic decode_frame(output logic [7:0] byte_out);
        logic [7:0] b;
        @(negedge serial);                        //start bit
        //to the middle of bit 0
        repeat (CPB + CPB/2) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            b[i] = serial;                        //LSB first
            if (i < 7) repeat (CPB) @(posedge clk);
        end
        repeat (CPB) @(posedge clk);              //into the stop bit
        chk(serial === 1'b1, "stop bit is not high");
        byte_out = b;
    endtask

    //Bit period, measured between consecutive edges while 0x55 is on the wire:
    //alternating data means every bit boundary is an edge.
    task automatic measure_bit_period(output int period);
        int t0;
        @(negedge serial);                        //start bit (0), then bit0 = 1
        t0 = cyc;
        @(posedge serial);                        //start -> bit0 boundary
        period = cyc - t0;
    endtask

    //------------------------------------------------------------------
    logic [31:0] v;
    logic [7:0]  seen;
    int          period;
    logic [7:0]  pattern [4];

    initial begin
        pattern = '{8'h00, 8'hFF, 8'h55, 8'hAA};

        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0; wstrb = 4'hF;

        repeat (4) @(negedge clk);
        rstn = 1'b1;
        repeat (4) @(negedge clk);

        //--- status after reset
        axi_read(STAT_OFF, v);
        chk(v[STAT_RX_DATA]  === 1'b0, "after reset: RX reports data");
        chk(v[STAT_RX_FULL]  === 1'b0, "after reset: RX reports full");
        chk(v[STAT_TX_EMPTY] === 1'b1, "after reset: TX is not empty");
        chk(v[STAT_TX_FULL]  === 1'b0, "after reset: TX reports full");
        chk(irq === 1'b0, "after reset: irq asserted with an empty RX FIFO");
        chk(serial === 1'b1, "after reset: the line is not idle high");
        $display("  status after reset       ok (0x%08x)", v);

        //--- one byte: decoded off the wire, then read back through loopback
        fork
            axi_write(TX_OFF, 32'h41);
            decode_frame(seen);
        join
        chk(seen === 8'h41, $sformatf("wire carried 0x%02x, expected 0x41", seen));
        $display("  frame on the wire        ok (0x%02x)", seen);

        wait_stat(STAT_RX_DATA, 40, v);
        chk(v[STAT_RX_DATA] === 1'b1, "loopback byte never reached the RX FIFO");
        chk(irq === 1'b1, "irq not asserted with a byte in the RX FIFO");
        axi_read(RX_OFF, v);
        chk(v[7:0] === 8'h41, $sformatf("RX read 0x%02x, expected 0x41", v[7:0]));
        $display("  loopback round trip     ok (0x%02x)", v[7:0]);

        //the read drained it
        axi_read(STAT_OFF, v);
        chk(v[STAT_RX_DATA] === 1'b0, "RX still reports data after being drained");
        chk(irq === 1'b0, "irq still asserted after the RX FIFO was drained");

        //--- bit period, off the wire
        fork
            axi_write(TX_OFF, 32'h55);
            measure_bit_period(period);
        join
        chk(period == CPB,
            $sformatf("bit period %0d clocks, expected %0d", period, CPB));
        $display("  bit period              ok (%0d clocks)", period);
        wait_stat(STAT_RX_DATA, 40, v);
        axi_read(RX_OFF, v);
        chk(v[7:0] === 8'h55, $sformatf("0x55 round trip gave 0x%02x", v[7:0]));

        //--- the awkward values
        foreach (pattern[i]) begin
            axi_write(TX_OFF, 32'(pattern[i]));
            wait_stat(STAT_RX_DATA, 60, v);
            chk(v[STAT_RX_DATA] === 1'b1,
                $sformatf("0x%02x never arrived", pattern[i]));
            axi_read(RX_OFF, v);
            chk(v[7:0] === pattern[i],
                $sformatf("round trip gave 0x%02x, sent 0x%02x", v[7:0], pattern[i]));
        end
        $display("  0x00 0xFF 0x55 0xAA     ok");

        //--- TX full: the FIFO is DEPTH deep, plus one byte in the shifter
        for (int i = 0; i < DEPTH + 2; i++)
            axi_write(TX_OFF, 32'h30 + 32'(i));
        axi_read(STAT_OFF, v);
        chk(v[STAT_TX_FULL] === 1'b1,
            $sformatf("TX not full after %0d writes into a %0d-deep FIFO",
                      DEPTH + 2, DEPTH));
        chk(v[STAT_TX_EMPTY] === 1'b0, "TX reports empty while full");
        $display("  TX full flag            ok");

        //--- and it drains
        for (int k = 0; k < 400; k++) begin
            axi_read(STAT_OFF, v);
            if (v[STAT_TX_EMPTY] && !v[STAT_TX_FULL]) break;
        end
        chk(v[STAT_TX_EMPTY] === 1'b1, "TX FIFO never drained");
        $display("  TX drains               ok");

        //--- RX full, from everything that came back
        axi_read(STAT_OFF, v);
        chk(v[STAT_RX_FULL] === 1'b1,
            "RX not full after more bytes looped back than it can hold");
        $display("  RX full flag            ok");

        //--- a write whose byte-lane-0 strobe is clear must be dropped
        //
        //Quiesce first. The TX-drain phase above left bytes in flight on the
        //wire, and a single drain pass empties the RX FIFO only to have the
        //next frame land in it a few hundred cycles later -- which looks
        //exactly like the failure this check is looking for. Drain, wait out
        //more than a frame, and repeat until a pass starts with RX already
        //empty and nothing more arrives.
        begin
            logic quiet;
            quiet = 1'b0;
            for (int t = 0; t < 40 && !quiet; t++) begin
                axi_read(STAT_OFF, v);
                quiet = ~v[STAT_RX_DATA];
                while (v[STAT_RX_DATA]) begin
                    axi_read(RX_OFF, v);
                    axi_read(STAT_OFF, v);
                end
                repeat (15 * CPB) @(negedge clk);
                axi_read(STAT_OFF, v);
                if (v[STAT_RX_DATA]) quiet = 1'b0;
            end
            chk(quiet, "the receive path never went quiet");
            chk(serial === 1'b1, "the line is not idle before the wstrb check");
        end

        axi_write(TX_OFF, 32'h7A, 4'b1110);
        repeat (30 * CPB) @(negedge clk);
        axi_read(STAT_OFF, v);
        chk(v[STAT_RX_DATA] === 1'b0,
            "a write with wstrb[0] clear still transmitted a byte");
        $display("  wstrb[0] clear dropped  ok");

        //--- a read and a write arriving together. The adapter grants writes
        //first, so a program spinning on STAT cannot starve its own output;
        //both transactions must still complete, and neither may be lost.
        begin
            logic [31:0] rv;
            fork
                axi_write(TX_OFF, 32'h5A);
                axi_read(STAT_OFF, rv);
            join
            wait_stat(STAT_RX_DATA, 60, v);
            chk(v[STAT_RX_DATA] === 1'b1,
                "a write issued alongside a read was lost");
            axi_read(RX_OFF, v);
            chk(v[7:0] === 8'h5A,
                $sformatf("concurrent write sent 0x%02x, expected 0x5A", v[7:0]));
            $display("  concurrent read+write   ok");
        end

        //--- offsets the UART does not decode read as zero, and do not error
        axi_read(12'h0C, v);
        chk(v === 32'h0, $sformatf("undecoded offset 0x0C read 0x%08x", v));
        axi_read(12'h10, v);
        chk(v === 32'h0, $sformatf("undecoded offset 0x10 read 0x%08x", v));
        $display("  undecoded offsets       ok");

        if (errors == 0)
            $display("PASS tb_cva5_uart");
        else
            $display("FAIL tb_cva5_uart (%0d errors)", errors);
        $finish;
    end

    //watchdog
    initial begin
        #20_000_000;
        $display("FAIL tb_cva5_uart (timeout)");
        $finish;
    end

endmodule
