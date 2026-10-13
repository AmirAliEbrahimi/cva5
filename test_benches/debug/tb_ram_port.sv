/*
 * tb_ram_port -- cva5_ram_port against the real tdp_ram.
 *
 * The port arbitrates one true-dual-port RAM port between the core's
 * load/store interface, which cannot be stalled, and an AXI4 slave, which
 * can. The things worth proving are therefore not the AXI handshakes on their
 * own but what happens when the two collide:
 *
 *   - the core always wins, and its read data arrives the cycle after it asks,
 *     whatever the bus is doing;
 *   - a bus beat held off by the core lands exactly once, at the right
 *     address, with the right bytes, however many cycles it waited;
 *   - nothing writes a word neither master asked for, including out of reset.
 *
 * The memory is tdp_ram itself, with the same parameters cva5_wrapper uses
 * (PIPELINE_DEPTH 0, byte columns), because the port's read timing depends on
 * two details of it: data appears the cycle after the access, and a write
 * leaves the output register alone. A behavioural model would not have them.
 *
 * The reference memory is updated from what the stimulus asks for, never from
 * what the port does to the RAM, so a port that writes the wrong address or
 * the same beat twice fails rather than being mirrored.
 *
 * Run from the repo root:  sh test_benches/debug/run_ram_port.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps

module tb_ram_port;

    localparam AW = 8;   //256 words, enough for bursts and a full sweep
    localparam IDW = 8;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rstn = 0;

    int errors = 0;
    int checks = 0;

    //----------------------------------------------------------------
    // DUT and memory
    //----------------------------------------------------------------
    logic core_en = 0;
    logic [3:0] core_be = 0;
    logic [AW-1:0] core_addr = 0;
    logic [31:0] core_wdata = 0;
    logic [31:0] core_rdata;

    logic [IDW-1:0] awid = 0;
    logic [AW+1:0] awaddr = 0;
    logic [7:0] awlen = 0;
    logic awvalid = 0;
    logic awready;
    logic [31:0] wdata = 0;
    logic [3:0] wstrb = 0;
    logic wlast = 0;
    logic wvalid = 0;
    logic wready;
    logic [IDW-1:0] bid;
    logic bvalid;
    logic bready = 0;
    logic [IDW-1:0] arid = 0;
    logic [AW+1:0] araddr = 0;
    logic [7:0] arlen = 0;
    logic arvalid = 0;
    logic arready;
    logic [IDW-1:0] rid;
    logic [31:0] rdata;
    logic rlast;
    logic rvalid;
    logic rready = 0;

    logic ram_en;
    logic [3:0] ram_wbe;
    logic [AW-1:0] ram_addr;
    logic [31:0] ram_wdata;
    logic [31:0] ram_rdata;

    cva5_ram_port #(.ADDR_WIDTH(AW), .ID_WIDTH(IDW)) dut (
        .clk (clk), .rstn (rstn),
        .core_en (core_en), .core_be (core_be), .core_addr (core_addr),
        .core_wdata (core_wdata), .core_rdata (core_rdata),
        .s_axi_awid (awid), .s_axi_awaddr (awaddr), .s_axi_awlen (awlen),
        .s_axi_awsize (3'd2), .s_axi_awburst (2'b01), .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata (wdata), .s_axi_wstrb (wstrb), .s_axi_wlast (wlast),
        .s_axi_wvalid (wvalid), .s_axi_wready (wready),
        .s_axi_bid (bid), .s_axi_bresp (), .s_axi_bvalid (bvalid),
        .s_axi_bready (bready),
        .s_axi_arid (arid), .s_axi_araddr (araddr), .s_axi_arlen (arlen),
        .s_axi_arsize (3'd2), .s_axi_arburst (2'b01), .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rid (rid), .s_axi_rdata (rdata), .s_axi_rresp (),
        .s_axi_rlast (rlast), .s_axi_rvalid (rvalid), .s_axi_rready (rready),
        .ram_en (ram_en), .ram_wbe (ram_wbe), .ram_addr (ram_addr),
        .ram_wdata (ram_wdata), .ram_rdata (ram_rdata)
    );

    tdp_ram #(
        .ADDR_WIDTH(AW), .NUM_COL(4), .COL_WIDTH(8),
        .PIPELINE_DEPTH(0), .CASCADE_DEPTH(8), .USE_PRELOAD(0)
    ) ram (
        .clk (clk),
        .a_en (1'b0), .a_wbe (4'h0), .a_wdata (32'h0), .a_addr ({AW{1'b0}}),
        .a_rdata (),
        .b_en (ram_en), .b_wbe (ram_wbe), .b_wdata (ram_wdata),
        .b_addr (ram_addr), .b_rdata (ram_rdata)
    );

    //----------------------------------------------------------------
    // Reference memory, written only from what the stimulus asked for
    //----------------------------------------------------------------
    logic [31:0] ref_mem [0:(1<<AW)-1];
    bit ref_known [0:(1<<AW)-1];

    task automatic ref_write(input int unsigned a, input logic [31:0] d,
                             input logic [3:0] be);
        for (int b = 0; b < 4; b++)
            if (be[b]) ref_mem[a][8*b+:8] = d[8*b+:8];
        if (be != 0) ref_known[a] = 1;
    endtask

    task automatic expect32(input string what, input int unsigned a,
                            input logic [31:0] got);
        checks++;
        if (got !== ref_mem[a]) begin
            errors++;
            $display("FAIL %s @%0d: got %08x expected %08x", what, a, got,
                     ref_mem[a]);
        end
    endtask

    //----------------------------------------------------------------
    // The core side: issued on the negedge, data checked a cycle later.
    //
    // This runs as a monitor rather than inside the driving tasks so that it
    // covers the noise generator's accesses too -- the point is that every
    // core read is answered on time no matter what the bus was doing.
    //----------------------------------------------------------------
    logic core_rd_q = 0;
    logic [AW-1:0] core_addr_q = 0;
    logic [31:0] core_exp_q = 0;

    always_ff @(posedge clk) begin
        if (rstn & core_rd_q) begin
            checks++;
            if (core_rdata !== core_exp_q) begin
                errors++;
                $display("FAIL core read @%0d: got %08x expected %08x",
                         core_addr_q, core_rdata, core_exp_q);
            end
        end
        core_rd_q <= rstn & core_en & ~|core_be & ref_known[core_addr];
        core_addr_q <= core_addr;
        core_exp_q <= ref_mem[core_addr];
    end

    //----------------------------------------------------------------
    // Nothing may touch the RAM that neither master asked for
    //----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rstn & ram_en) begin
            errors++;
            $display("FAIL RAM accessed while in reset");
        end
    end

    //----------------------------------------------------------------
    // Core stimulus
    //----------------------------------------------------------------
    task automatic core_write(input int unsigned a, input logic [31:0] d,
                              input logic [3:0] be);
        @(negedge clk);
        core_en = 1; core_be = be; core_addr = a[AW-1:0]; core_wdata = d;
        ref_write(a, d, be);
        @(posedge clk);
        @(negedge clk);
        core_en = 0; core_be = 0;
    endtask

    task automatic core_read(input int unsigned a);
        @(negedge clk);
        core_en = 1; core_be = 0; core_addr = a[AW-1:0];
        @(posedge clk);
        @(negedge clk);
        core_en = 0;
        //the monitor above checks the data
    endtask

    //Steals cycles from the bus for `cycles` clocks: reads everywhere, writes
    //only in the upper half, which the bus tests leave alone.
    logic [15:0] lfsr = 16'hace1;
    bit noise_on = 0;

    task automatic noise(input int cycles);
        noise_on = 1;
        repeat (cycles) begin
            @(negedge clk);
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            if (lfsr[0]) begin
                core_en = 1;
                core_addr = {1'b1, lfsr[9:3]};
                if (lfsr[1] & lfsr[2]) begin
                    core_be = 4'hf;
                    core_wdata = {lfsr, ~lfsr};
                    ref_write({1'b1, lfsr[9:3]}, {lfsr, ~lfsr}, 4'hf);
                end
                else
                    core_be = 0;
            end
            else begin
                core_en = 0;
                core_be = 0;
            end
        end
        @(negedge clk);
        core_en = 0; core_be = 0;
        noise_on = 0;
    endtask

    //----------------------------------------------------------------
    // AXI stimulus. Driven on the negedge, handshakes sampled on the posedge,
    // so a ready that is combinational in the valid is never missed.
    //----------------------------------------------------------------
    task automatic axi_write(input int unsigned a, input int beats,
                             input logic [31:0] d0, input logic [3:0] be,
                             input int gap);
        logic [31:0] d;
        @(negedge clk);
        awvalid = 1; awaddr = a*4; awlen = beats-1; awid = 8'h5a;
        forever begin @(posedge clk); if (awready) break; end
        @(negedge clk);
        awvalid = 0;

        d = d0;
        for (int i = 0; i < beats; i++) begin
            if (gap > 0) begin
                //leave W idle for a while: the port must hold its place
                wvalid = 0;
                repeat (gap) @(negedge clk);
            end
            wvalid = 1; wdata = d; wstrb = be; wlast = (i == beats-1);
            forever begin @(posedge clk); if (wready) break; end
            ref_write(a+i, d, be);
            @(negedge clk);
            wvalid = 0; wlast = 0;
            d = d + 32'h1111_1111;
        end

        bready = 1;
        forever begin @(posedge clk); if (bvalid) break; end
        checks++;
        if (bid !== 8'h5a) begin
            errors++;
            $display("FAIL B id: got %02x expected 5a", bid);
        end
        @(negedge clk);
        bready = 0;
    endtask

    task automatic axi_read(input int unsigned a, input int beats,
                            input int gap);
        @(negedge clk);
        arvalid = 1; araddr = a*4; arlen = beats-1; arid = 8'h3c;
        forever begin @(posedge clk); if (arready) break; end
        @(negedge clk);
        arvalid = 0;

        for (int i = 0; i < beats; i++) begin
            if (gap > 0) begin
                rready = 0;
                repeat (gap) @(negedge clk);
            end
            rready = 1;
            forever begin @(posedge clk); if (rvalid) break; end
            expect32("bus read", a+i, rdata);
            checks++;
            if (rlast !== (i == beats-1)) begin
                errors++;
                $display("FAIL rlast on beat %0d of %0d: got %0b", i, beats,
                         rlast);
            end
            checks++;
            if (rid !== 8'h3c) begin
                errors++;
                $display("FAIL R id: got %02x expected 3c", rid);
            end
            @(negedge clk);
            rready = 0;
        end
    endtask

    //----------------------------------------------------------------
    // The run
    //----------------------------------------------------------------
    initial begin
        for (int i = 0; i < (1<<AW); i++) begin
            ref_mem[i] = 32'h0;
            ref_known[i] = 0;
        end

        repeat (4) @(negedge clk);
        rstn = 1;

        //Nothing asked for anything, so nothing may happen.
        repeat (8) begin
            @(posedge clk);
            if (ram_en) begin
                errors++;
                $display("FAIL RAM accessed with no request pending");
            end
        end

        //Known contents everywhere, so the final sweep can check the whole
        //memory rather than only the addresses a test wrote.
        for (int i = 0; i < (1<<AW); i += 16)
            axi_write(i, 16, 32'h1000_0000 + i, 4'hf, 0);

        $display("-- single beats");
        axi_write(3, 1, 32'hdead_beef, 4'hf, 0);
        axi_write(4, 1, 32'hcafe_f00d, 4'b0101, 0);  //partial strobes
        axi_write(5, 1, 32'h0bad_0bad, 4'b0000, 0);  //a beat that writes nothing
        axi_read(3, 1, 0);
        axi_read(4, 1, 0);
        axi_read(5, 1, 0);

        $display("-- bursts, back to back");
        axi_write(8, 8, 32'h0101_0101, 4'hf, 0);
        axi_read(8, 8, 0);

        $display("-- bursts with the master stalling mid-burst");
        axi_write(32, 8, 32'h2020_2020, 4'hf, 3);
        axi_read(32, 8, 2);

        $display("-- the core taking the port while the bus writes");
        fork
            axi_write(48, 16, 32'h3030_3030, 4'hf, 0);
            noise(120);
        join
        axi_read(48, 16, 0);

        $display("-- the core taking the port while the bus reads");
        fork
            axi_read(48, 16, 0);
            noise(160);
        join

        $display("-- a core access in the same cycle as every kind of beat");
        //Hold the port for one cycle out of two for a whole burst, so every
        //beat is offered a busy cycle and then a free one.
        fork
            axi_write(64, 8, 32'h4040_4040, 4'hf, 0);
            begin
                repeat (24) begin
                    @(negedge clk);
                    core_en = 1; core_be = 0; core_addr = 8'hc0;
                    @(negedge clk);
                    core_en = 0;
                end
            end
        join
        axi_read(64, 8, 0);

        $display("-- write then read the same word, no gap");
        axi_write(100, 1, 32'h5555_aaaa, 4'hf, 0);
        axi_read(100, 1, 0);

        $display("-- the core writing, read back by the bus");
        core_write(120, 32'h6060_6060, 4'hf);
        core_write(121, 32'h7070_7070, 4'b0011);
        core_read(120);
        axi_read(120, 2, 0);

        $display("-- full sweep");
        for (int i = 0; i < (1<<AW); i += 16)
            axi_read(i, 16, 0);

        if (errors == 0)
            $display("tb_ram_port: PASS (%0d checks)", checks);
        else
            $display("tb_ram_port: FAIL (%0d errors, %0d checks)", errors,
                     checks);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("tb_ram_port: FAIL (timeout -- a handshake never completed)");
        $finish;
    end

endmodule
