/*
 * tb_boot_rom -- checks that the boot ROM encodes a correct jump.
 *
 * The ROM is two instructions and there is no way to run them here, so the
 * bench decodes what it reads back and recomputes the jump target the way the
 * hardware would: target = (sign_extend(jalr.imm) + lui.imm) with lui's
 * immediate shifted up by 12. If that equals ENTRY_ADDR the pair is right.
 *
 * The entry addresses cover the case the upstream encoding gets wrong: bit 11
 * of the low half set, so jalr's sign-extended immediate is negative and the
 * upper half needs the carry correction.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
module tb_boot_rom;

    logic clk = 0;
    always #5 clk = ~clk;

    int errors = 0;

    //Rebuild the jump target from the two instruction words, as a core would.
    function automatic logic [31:0] decode_target(logic [31:0] lui, logic [31:0] jalr);
        logic [31:0] upper;
        logic signed [31:0] lower;
        upper = {lui[31:12], 12'h000};
        lower = 32'(signed'(jalr[31:20]));   //jalr sign-extends imm[11:0]
        return upper + lower;
    endfunction

    function automatic void check_fields(logic [31:0] lui, logic [31:0] jalr, string what);
        if (lui[6:0] !== 7'b0110111) begin
            $error("%s: word 0 opcode 0x%02x is not LUI", what, lui[6:0]);
            errors++;
        end
        if (lui[11:7] !== 5'h1) begin
            $error("%s: LUI rd is x%0d, expected x1", what, lui[11:7]);
            errors++;
        end
        if (jalr[6:0] !== 7'b1100111 || jalr[14:12] !== 3'b000) begin
            $error("%s: word 1 is not JALR (opcode 0x%02x funct3 %0d)",
                   what, jalr[6:0], jalr[14:12]);
            errors++;
        end
        if (jalr[19:15] !== 5'h1) begin
            $error("%s: JALR rs1 is x%0d, expected x1 (LUI's rd)", what, jalr[19:15]);
            errors++;
        end
        if (jalr[11:7] !== 5'h0) begin
            $error("%s: JALR rd is x%0d, expected x0 -- the ROM must not link",
                   what, jalr[11:7]);
            errors++;
        end
    endfunction

    //----------------------------------------------------------------------
    //One instance per entry address under test. ENTRY_ADDR is a parameter, so
    //each case has to be its own instance.
    //----------------------------------------------------------------------
    localparam int N = 6;
    localparam logic [31:0] ENTRY [N] = '{
        32'h8000_0040,   //the real one: APP_ENTRY on this board
        32'h8000_0000,   //low half zero
        32'h0001_0000,   //low half zero, small upper
        32'h8000_0800,   //bit 11 set: needs the %hi carry
        32'h8000_0FFC,   //low half at its maximum
        32'h1C00_0080    //upstream's own entry address
    };

    logic        req   [N];
    logic [31:0] addr  [N];
    logic [31:0] rdata [N];

    generate
        for (genvar i = 0; i < N; i++) begin : g_rom
            boot_rom #(.ENTRY_ADDR(ENTRY[i])) dut (
                .clk_i   (clk),
                .req_i   (req[i]),
                .addr_i  (addr[i]),
                .rdata_o (rdata[i])
            );
        end
    endgenerate

    //Read one word out of instance i, driving the port as the fetch bus does.
    task automatic rom_read(int i, logic [31:0] byte_addr, output logic [31:0] data);
        @(negedge clk);
        req[i]  = 1'b1;
        addr[i] = byte_addr;
        @(negedge clk);          //req sampled on the posedge between these
        req[i]  = 1'b0;
        data    = rdata[i];      //valid the cycle after req
    endtask

    logic [31:0] w0, w1, target;

    initial begin
        for (int i = 0; i < N; i++) begin
            req[i]  = 1'b0;
            addr[i] = '0;
        end

        for (int i = 0; i < N; i++) begin
            string what;
            what = $sformatf("ENTRY_ADDR=0x%08x", ENTRY[i]);

            rom_read(i, 32'h0000_0000, w0);
            rom_read(i, 32'h0000_0004, w1);

            check_fields(w0, w1, what);

            target = decode_target(w0, w1);
            if (target !== ENTRY[i]) begin
                $error("%s: jump lands at 0x%08x (lui=0x%08x jalr=0x%08x)",
                       what, target, w0, w1);
                errors++;
            end
            else
                $display("  %s  lui=0x%08x jalr=0x%08x -> 0x%08x  ok",
                         what, w0, w1, target);

            //A byte offset inside a word must not change which word is read.
            rom_read(i, 32'h0000_0007, w1);
            rom_read(i, 32'h0000_0004, target);
            if (w1 !== target) begin
                $error("%s: byte offset changed the word read (0x%08x vs 0x%08x)",
                       what, w1, target);
                errors++;
            end

            //Addresses beyond the ROM alias back into it rather than reading
            //out of bounds; the wrapper is what keeps fetch inside the window.
            rom_read(i, 32'h0000_0008, w1);
            rom_read(i, 32'h0000_0000, target);
            if (w1 !== target) begin
                $error("%s: 0x8 did not alias to 0x0 (0x%08x vs 0x%08x)",
                       what, w1, target);
                errors++;
            end
        end

        //The two encodings this bench is pinned to, so a change to the
        //construction has to be deliberate.
        rom_read(0, 32'h0000_0000, w0);
        rom_read(0, 32'h0000_0004, w1);
        if (w0 !== 32'h8000_00b7) begin
            $error("APP_ENTRY lui is 0x%08x, expected 0x800000b7", w0);
            errors++;
        end
        if (w1 !== 32'h0400_8067) begin
            $error("APP_ENTRY jalr is 0x%08x, expected 0x04008067", w1);
            errors++;
        end

        if (errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
