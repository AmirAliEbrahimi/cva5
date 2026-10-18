// Copyright 2020 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Robert Balas <balasr@iis.ee.ethz.ch>
// Description: Bootrom for firmware booting
//
// SPDX-License-Identifier: SHL-0.51
//
//----------------------------------------------------------------------------
// Vendored by hand from third_party/riscv-dbg/tb/boot_rom.sv. That copy lives
// in riscv-dbg's testbench directory, which is not part of the vendored source
// set, so it is copied here rather than referenced. Four changes:
//
//   1. dm_tb_pkg::lui and dm_tb_pkg::jalr are inlined. They are testbench
//      helpers and pulling in that package for two instruction encodings would
//      drag the whole DM testbench into synthesis.
//
//   2. ENTRY_ADDR is a parameter instead of a hardcoded 32'h1c00_0080. The
//      wrapper passes the application entry point, so the ROM and the linker
//      script cannot disagree about where the program starts.
//
//   3. The lui/jalr pair is built as a proper %hi/%lo pair. Upstream splits
//      the entry address as {addr[31:12], addr[11:0]}, which is wrong whenever
//      bit 11 is set: jalr sign-extends its 12-bit immediate, so a low half of
//      0x800..0xFFF subtracts from the upper half instead of adding. ENTRY_HI
//      below adds 0x800 before shifting, which is the carry correction every
//      assembler applies for %hi. For an entry address with bit 11 clear the
//      two forms agree, so this is latent upstream rather than broken.
//
//   4. The address slice is narrowed to the bits it actually uses. Upstream's
//      addr_i[$clog2(RomSize)-1+3:2] is one bit wider than addr_q, the +3
//      being the 64-bit-word form, and the assignment truncates to the low
//      bits -- which leaves exactly addr_i[$clog2(RomSize)+1:2]. So the two
//      forms are equivalent for any RomSize and this changes no behaviour;
//      it is written to be correct rather than correct by truncation. A
//      mutation test confirms it: substituting upstream's slice back in leaves
//      the testbench passing, as it should.
//
// The bounds check on rdata_o is also dropped: addr_q is exactly
// $clog2(RomSize) bits and RomSize is a power of two, so it cannot be out of
// range and the comparison is a tautology.
//
// addr_q has no reset, as upstream. It is only written when req_i is high and
// only read when the fetch bus acknowledges, and the wrapper's acknowledge is
// the reset-bearing register, so the value is never consumed before it is
// written.
//----------------------------------------------------------------------------

module boot_rom #(
    // Where the ROM jumps. The two instructions below are
    //     lui  x1, %hi(ENTRY_ADDR)
    //     jalr x0, %lo(ENTRY_ADDR)(x1)
    // so any 32-bit address is reachable and x1 is the only register touched.
    parameter logic [31:0] ENTRY_ADDR = 32'h8000_0000
) (
    input  logic        clk_i,
    input  logic        req_i,
    input  logic [31:0] addr_i,   // byte address
    output logic [31:0] rdata_o
);
    localparam int unsigned RomSize = 2;

    localparam logic [31:0] ENTRY_HI = (ENTRY_ADDR + 32'h800) >> 12;
    localparam logic [11:0] ENTRY_LO = ENTRY_ADDR[11:0];

    //              imm[31:12]      rd        opcode
    localparam logic [31:0] INSN_LUI  = {ENTRY_HI[19:0], 5'h1, 7'b0110111};
    //              imm[11:0] rs1      f3     rd      opcode
    localparam logic [31:0] INSN_JALR = {ENTRY_LO, 5'h1, 3'b000, 5'h0, 7'b1100111};

    logic [RomSize-1:0][31:0] mem;
    assign mem = {INSN_JALR, INSN_LUI};

    logic [$clog2(RomSize)-1:0] addr_q;

    assign rdata_o = mem[addr_q];

    always_ff @(posedge clk_i) begin
        if (req_i) begin
            addr_q <= addr_i[$clog2(RomSize)+1:2];
        end
    end

endmodule
