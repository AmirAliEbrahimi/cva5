/*
 * tb_spi -- cva5_spi_axi: pulp's SPI master through its AXI4-Lite wrapper,
 * against a SPI slave model in the testbench.
 *
 * The IP is upstream's, so what needs proving is the wrapper and the
 * programming model: that a Lite master can drive a full-AXI4 slave port
 * through the single-beat tie-offs, that the register map is where this tree
 * says it is, that the right chip select moves, and -- the part that cost a
 * read of the RTL -- that MISO is on the line the receiver actually samples.
 *
 * The slave model is mode 0, which is what the controller does: the clock
 * idles low, the transmitter shifts on `spi_fall` and the receiver samples on
 * `spi_rise` (spi_master_controller.sv wires tx_edge to the falling edge and
 * rx_edge to the rising one). So the model samples MOSI on the rising edge and
 * changes MISO on the falling edge, with the first MISO bit presented when CS
 * asserts.
 *
 * Run from the repo root:  bash test_benches/axi/run_spi.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module tb_spi;

    //Byte offsets into the window. Five bits of word address: the registers
    //are words 0..5, a write with word-address bit 3 set goes to the TX FIFO,
    //and a read with bit 4 set comes from the RX FIFO.
    localparam int unsigned REG_STATUS = 32'h00;
    localparam int unsigned REG_CLKDIV = 32'h04;
    localparam int unsigned REG_SPICMD = 32'h08;
    localparam int unsigned REG_SPIADR = 32'h0C;
    localparam int unsigned REG_SPILEN = 32'h10;
    localparam int unsigned REG_SPIDUM = 32'h14;
    localparam int unsigned TX_FIFO    = 32'h20;
    localparam int unsigned RX_FIFO    = 32'h40;

    //STATUS, on read: bit 0 is set in the IDLE state -- it is an idle flag,
    //not a busy one -- and the FIFO levels sit above the state bits:
    //  [6:0]   controller state, bit 0 = idle
    //  [20:16] words in the RX FIFO
    //  [28:24] words in the TX FIFO
    localparam int unsigned ST_IDLE = 32'h1;

    function automatic logic [4:0] tx_level(input logic [31:0] status);
        return status[28:24];
    endfunction
    function automatic logic [4:0] rx_level(input logic [31:0] status);
        return status[20:16];
    endfunction

    //STATUS write bits
    localparam int unsigned ST_RD   = 32'h1;
    localparam int unsigned ST_WR   = 32'h2;
    localparam int unsigned ST_RST  = 32'h10;
    //Chip select is one-hot in bits 11:8 (csn[i] = ~csreg[i] | cs_active)
    function automatic logic [31:0] cs_onehot(input int unsigned n);
        return 32'(1 << (8 + n));
    endfunction

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
    // DUT
    //==================================================================
    logic [11:0] awaddr, araddr;
    logic [31:0] wdata, rdata;
    logic        awvalid, awready, wvalid, wready;
    logic        bvalid, bready, arvalid, arready, rvalid, rready;
    logic [1:0]  bresp, rresp;

    logic        spi_sck;
    logic [3:0]  spi_csn;
    logic        spi_mosi, spi_miso;
    logic        miso_reg;
    logic        loopback_mode = 0;   //a wire from MOSI to MISO, as on the board
    logic        irq;

    cva5_spi_axi #(
        .ADDR_WIDTH (12),
        .BUFFER_DEPTH (8)
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
        .spi_sck (spi_sck), .spi_csn (spi_csn),
        .spi_mosi (spi_mosi), .spi_miso (spi_miso),
        .irq (irq)
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
    // SPI slave model, mode 0, MSB first
    //==================================================================
    logic cs_active;
    assign cs_active = ~&spi_csn;      //any chip select low

    logic [63:0] mosi_seen;            //what the model has received
    int unsigned mosi_bits;
    logic [63:0] miso_pattern;         //what the model will send, MSB first
    int unsigned miso_bits;

    assign spi_miso = loopback_mode ? spi_mosi : miso_reg;

    //One driver for the whole model, clocked on the core clock with edge
    //detection on spi_sck -- several always blocks writing the same signals
    //from different clocks is what Verilator's MULTIDRIVEN is for.
    logic spi_sck_q, cs_q;

    always_ff @(posedge clk) begin
        spi_sck_q <= spi_sck;
        cs_q <= cs_active;

        if (cs_active && !cs_q) begin
            //CS has just asserted: present the first MISO bit, as a mode-0
            //slave does, before the first clock edge.
            mosi_bits <= 0;
            miso_bits <= 0;
            miso_reg  <= miso_pattern[63];
        end
        else if (cs_active) begin
            if (spi_sck && !spi_sck_q) begin
                //rising edge: where the master guarantees MOSI
                mosi_seen <= {mosi_seen[62:0], spi_mosi};
                mosi_bits <= mosi_bits + 1;
            end
            if (!spi_sck && spi_sck_q) begin
                //falling edge: the slave moves MISO
                miso_reg  <= miso_pattern[62 - miso_bits];
                miso_bits <= miso_bits + 1;
            end
        end
        else if (!cs_active && cs_q) begin
            miso_reg <= 1'b0;   //idle, so a missing CS shows as a stuck value
        end
    end

    task automatic await_transfer(input int unsigned bits);
        int unsigned guard;
        guard = 0;
        while (!cs_active && guard < 10000) begin
            @(negedge clk);
            guard++;
        end
        while (cs_active && guard < 200000) begin
            @(negedge clk);
            guard++;
        end
        if (guard >= 200000)
            $error("transfer of %0d bits never finished", bits);
    endtask

    //==================================================================
    logic [31:0] v;
    int unsigned saw_irq;

    //irq is a pulse at end of transfer; latch it per transfer.
    always_ff @(posedge clk) if (irq) saw_irq <= saw_irq + 1;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        awaddr = 0; araddr = 0; wdata = 0;
        mosi_seen = '0; mosi_bits = 0; miso_bits = 0; saw_irq = 0;
        miso_pattern = '0;
        miso_reg = 0;

        repeat (4) @(negedge clk);
        rstn = 1;
        repeat (8) @(negedge clk);

        //---- the register file
        $display("-- registers");
        reg_write(REG_CLKDIV, 32'd4);
        reg_read(REG_CLKDIV, v);
        expect_eq("clkdiv reads back", v & 32'hFF, 32'd4);

        reg_write(REG_SPICMD, 32'hA5A5_0000);
        reg_read(REG_SPICMD, v);
        expect_eq("spicmd reads back", v, 32'hA5A5_0000);

        reg_write(REG_SPIADR, 32'h1234_5678);
        reg_read(REG_SPIADR, v);
        expect_eq("spiadr reads back", v, 32'h1234_5678);

        reg_write(REG_SPILEN, 32'h0020_0008);   //cmd 8 bits, data 32 bits
        reg_read(REG_SPILEN, v);
        expect_eq("spilen reads back", v, 32'h0020_0008);

        reg_write(REG_SPIDUM, 32'h0000_0000);
        reg_read(REG_SPIDUM, v);
        expect_eq("spidum reads back", v, 32'd0);

        reg_read(REG_STATUS, v);
        expect_eq("status reports idle out of reset", v & ST_IDLE, ST_IDLE);
        expect_eq("both FIFOs are empty", 32'(tx_level(v)) | 32'(rx_level(v)),
                  32'd0);

        expect_eq("every chip select is high at rest", 32'(spi_csn), 32'hF);

        //---- a write transfer: command then data, out on MOSI
        $display("-- write transfer");
        reg_write(REG_SPICMD, 32'hA5000000);     //8-bit command 0xA5, MSB first
        reg_write(REG_SPILEN, 32'h0020_0008);    //8 command bits, 32 data bits
        reg_write(TX_FIFO, 32'hDEAD_BEEF);
        reg_read(REG_STATUS, v);
        expect_eq("the word is in the TX FIFO", 32'(tx_level(v)), 32'd1);
        saw_irq = 0;
        reg_write(REG_STATUS, ST_WR | cs_onehot(0));

        await_transfer(40);
        expect_eq("the slave saw 40 bits", 32'(mosi_bits), 32'd40);
        expect_eq("the command went out first, MSB first",
                  32'(mosi_seen[39:32]), 32'hA5);
        expect_eq("then the data word", mosi_seen[31:0], 32'hDEAD_BEEF);
        expect_eq("chip selects are released", 32'(spi_csn), 32'hF);
        expect_eq("and the transfer raised an interrupt",
                  saw_irq != 0 ? 32'd1 : 32'd0, 32'd1);

        //---- the same, on a different chip select
        $display("-- chip select 2");
        reg_write(REG_SPICMD, 32'h5A000000);
        reg_write(REG_SPILEN, 32'h0000_0008);    //command only
        reg_write(REG_STATUS, ST_WR | cs_onehot(2));

        //CS 2 must be the one that moves
        while (!cs_active) @(negedge clk);
        expect_eq("only chip select 2 is low", 32'(spi_csn), 32'hB);
        await_transfer(8);
        expect_eq("the command went out", 32'(mosi_seen[7:0]), 32'h5A);

        //---- a read transfer: the model's bits come back in the RX FIFO
        $display("-- read transfer");
        //40 bits leave CS low: 8 command, then 32 of data. The model presents
        //bit 63 first, so the 32 bits the receiver captures are [55:24].
        miso_pattern = {8'h00, 32'h1234_5678, 24'h0};
        reg_write(REG_SPICMD, 32'h0B000000);     //a read command
        reg_write(REG_SPILEN, 32'h0020_0008);
        saw_irq = 0;
        reg_write(REG_STATUS, ST_RD | cs_onehot(0));

        await_transfer(40);
        reg_read(REG_STATUS, v);
        expect_eq("a word is waiting in the RX FIFO", 32'(rx_level(v)), 32'd1);
        reg_read(RX_FIFO, v);
        expect_eq("the word the slave sent arrives in the RX FIFO",
                  v, 32'h1234_5678);
        reg_read(REG_STATUS, v);
        expect_eq("and reading it empties the FIFO", 32'(rx_level(v)), 32'd0);
        expect_eq("the read raised an interrupt",
                  saw_irq != 0 ? 32'd1 : 32'd0, 32'd1);

        //---- the clock divider changes the SPI clock
        $display("-- clock divider");
        begin
            int unsigned t0, t1, period_div2, period_div8;

            reg_write(REG_CLKDIV, 32'd2);
            reg_write(REG_SPILEN, 32'h0000_0020);   //32 bits of command
            reg_write(REG_SPICMD, 32'hFFFF_FFFF);
            reg_write(REG_STATUS, ST_WR | cs_onehot(0));
            @(posedge spi_sck);
            t0 = 0;
            @(posedge clk);
            while (!(spi_sck == 1'b0)) begin @(posedge clk); t0++; end
            while (!(spi_sck == 1'b1)) begin @(posedge clk); t0++; end
            period_div2 = t0;
            await_transfer(32);

            reg_write(REG_CLKDIV, 32'd8);
            reg_write(REG_STATUS, ST_WR | cs_onehot(0));
            @(posedge spi_sck);
            t1 = 0;
            @(posedge clk);
            while (!(spi_sck == 1'b0)) begin @(posedge clk); t1++; end
            while (!(spi_sck == 1'b1)) begin @(posedge clk); t1++; end
            period_div8 = t1;
            await_transfer(32);

            checks++;
            if (!(period_div8 > period_div2)) begin
                $error("clkdiv 8 did not slow the clock: %0d vs %0d core clocks",
                       period_div8, period_div2);
                errors++;
            end
            $display("   spi_sck period: %0d core clocks at clkdiv 2, %0d at 8",
                     period_div2, period_div8);
        end

        //---- the soft reset returns it to idle
        $display("-- soft reset");
        reg_write(REG_STATUS, ST_RST);
        repeat (8) @(negedge clk);
        reg_read(REG_STATUS, v);
        expect_eq("idle after a soft reset", v & ST_IDLE, ST_IDLE);
        expect_eq("and the chip selects are high", 32'(spi_csn), 32'hF);

        //---- what a wire from MOSI to MISO actually returns.
        //
        //This controller is half duplex: a transfer is a command phase, then
        //data in one direction. So a loopback cannot hand back the word that
        //was sent -- during a read's data phase the transmitter is idle and
        //MOSI holds whatever it was left driving. What that level is decides
        //what examples/sw/spi.c can assert on the board, so it is measured
        //here rather than assumed.
        $display("-- loopback, measured");
        loopback_mode = 1;

        reg_write(REG_CLKDIV, 32'd2);
        reg_write(REG_SPIDUM, 32'd0);

        //After an 8-bit command, bit 23 of SPICMD is what the transmitter is
        //left holding, so this asks for a held 1 during the data phase.
        reg_write(REG_SPICMD, 32'h0080_0000);
        reg_write(REG_SPILEN, 32'h0020_0008);
        reg_write(REG_STATUS, ST_RD | cs_onehot(0));
        await_transfer(40);
        reg_read(RX_FIFO, v);
        $display("   cmd 0x00800000, 8 command bits, 32 read: 0x%08x", v);
        expect_eq("a held 1 on MOSI reads back as all ones", v, 32'hFFFF_FFFF);

        reg_write(REG_SPICMD, 32'h0000_0000);
        reg_write(REG_SPILEN, 32'h0020_0008);
        reg_write(REG_STATUS, ST_RD | cs_onehot(0));
        await_transfer(40);
        reg_read(RX_FIFO, v);
        $display("   cmd 0x00000000, 8 command bits, 32 read: 0x%08x", v);
        expect_eq("and a held 0 as all zeros", v, 32'h0);

        //And a 32-bit command with the data phase right behind it.
        reg_write(REG_SPICMD, 32'hA5A5_5A5A);
        reg_write(REG_SPILEN, 32'h0020_0020);
        reg_write(REG_STATUS, ST_RD | cs_onehot(0));
        await_transfer(64);
        reg_read(RX_FIFO, v);
        $display("   cmd 0xa5a55a5a, 32 command bits, 32 read: 0x%08x", v);
        expect_eq("a 32-bit command leaves the shifter empty, so zeros",
                  v, 32'h0);

        loopback_mode = 0;

        if (errors == 0)
            $display("PASS tb_spi: %0d checks", checks);
        else
            $display("FAIL tb_spi: %0d of %0d checks failed", errors, checks);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL tb_spi (timeout)");
        $finish;
    end

endmodule
