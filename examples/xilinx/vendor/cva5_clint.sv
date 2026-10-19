/*
 * Copyright © 2024 Chris Keilbart, Mohammad Shahidzadeh
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Initial code developed under the supervision of Dr. Lesley Shannon,
 * Reconfigurable Computing Lab, Simon Fraser University.
 *
 * Author(s):
 *             Chris Keilbart <ckeilbar@sfu.ca>
 *             Mohammad Shahidzadeh <mohammad_shahidzadeh_asadi@sfu.ca>
 */

//----------------------------------------------------------------------------
// Vendored by hand from apu/clint/clint.sv. Two changes: mtime increments on a
// prescaled tick rather than every clock, and the module is renamed.
//
// The rename is not cosmetic. tools/compile_order lists apu/clint/clint.sv for
// the Verilator simulation, so a vendored copy keeping the name `clint` would
// put two different modules with one name into the same compilation. cva5_*
// is also what this tree calls its own blocks -- cva5_axi_xbar, cva5_uart,
// cva5_ram_port -- so the name says where it came from.
//
// Upstream increments unconditionally, which on this board would run mtime at
// 100 MHz. The privileged spec only asks for a constant frequency, so that is
// legal, but every RISC-V system puts mtime at 1 MHz -- CVA6, OpenTitan,
// SiFive, QEMU's virt -- and software ported from any of them carries 1 MHz in
// its delay constants. A 100 MHz mtime would also make every one of those
// delays a hundred times too short.
//
// TICKS_PER_USEC is the divider, so mtime counts microseconds and one tick is
// 1 us at any core frequency. It also costs less than upstream: the 64-bit
// increment chain is enabled one cycle in a hundred rather than every cycle.
//
// Writes to mtime still take effect immediately, whatever the prescaler is
// doing, and the prescaler is reset with them so a write does not land
// mid-microsecond.
//
// Nothing else is changed: mtimecmp, msip, mtip and the comparison are
// upstream's.
//----------------------------------------------------------------------------

module cva5_clint

    #(
        parameter int unsigned NUM_CORES = 1,
        //Core clocks per microsecond: 100 at 100 MHz. 1 restores upstream's
        //behaviour of incrementing every clock.
        parameter int unsigned TICKS_PER_USEC = 100
    ) (
        input logic clk,
        input logic rst,

        input logic write_mtime,
        input logic write_mtimecmp,
        input logic write_msip,
        input logic write_upper, //Else lower; mtime and mtimecmp only
        input logic [(NUM_CORES == 1) ? 0 : ($clog2(NUM_CORES)-1) : 0] write_msip_core,
        input logic [(NUM_CORES == 1) ? 0 : ($clog2(NUM_CORES)-1) : 0] write_mtimecmp_core,
        input logic[31:0] write_data,

        output logic[1:0][31:0] mtime,
        output logic[NUM_CORES-1:0][1:0][31:0] mtimecmp,
        output logic[NUM_CORES-1:0] msip,
        output logic[NUM_CORES-1:0] mtip
    );

    ////////////////////////////////////////////////////
    //Core Local INTerrupt unit (CLINT)
    //Implements mtime, mtimecmp, mtip, and msip from the RISC-V privileged specification
    //mtime increments at a constant frequency
    //mtip is set when mtime >= mtimecmp
    //mtimecmp and msip are registers
    logic[63:0] mtime_p_1;
    assign mtime_p_1 = {mtime[1], mtime[0]} + 1;

    //Prescaler: one tick per microsecond. A write to mtime restarts it, so the
    //first tick after a write is a full microsecond later rather than whatever
    //was left of the one in progress.
    localparam int unsigned PRESCALE_W = TICKS_PER_USEC > 1 ? $clog2(TICKS_PER_USEC) : 1;
    logic[PRESCALE_W-1:0] prescale;
    logic tick;

    assign tick = TICKS_PER_USEC == 1 ? 1'b1 : (prescale == PRESCALE_W'(TICKS_PER_USEC - 1));

    always_ff @(posedge clk) begin
        if (rst)
            prescale <= '0;
        else if (write_mtime | tick)
            prescale <= '0;
        else
            prescale <= prescale + 1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            mtime <= '0;
            mtimecmp <= '1; //Reset to max to prevent interrupts
            msip <= '0;
        end
        else begin
            for (int i = 0; i < NUM_CORES; i++)
                mtip[i] <= {mtime[1], mtime[0]} >= {mtimecmp[i][1], mtimecmp[i][0]};
            
            //Writes always land; otherwise mtime only moves on a tick.
            mtime[1] <= write_mtime & write_upper  ? write_data :
                        tick                       ? mtime_p_1[63:32] : mtime[1];
            mtime[0] <= write_mtime & ~write_upper ? write_data :
                        tick                       ? mtime_p_1[31:0]  : mtime[0];
            
            for (int i = 0; i < NUM_CORES; i++) begin     
                mtimecmp[i][1] <= write_mtimecmp & write_upper & i == int'(write_mtimecmp_core) ? write_data : mtimecmp[i][1];           
                mtimecmp[i][0] <= write_mtimecmp & ~write_upper & i == int'(write_mtimecmp_core) ? write_data : mtimecmp[i][0];
            end

            if (write_msip)
                msip[write_msip_core] <= write_data[0]; //LSB
        end
    end

endmodule
