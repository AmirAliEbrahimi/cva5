/*
 * Copyright © 2024 Chris Keilbart
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
 */

module cva5_top

    #(
        parameter LOCAL_MEM = "ram.mif", //Preload for main memory
        parameter WORDS = 32768,         //Main memory size in words (128 KB)

        //AXI ID width on the external slave port and the RAM path behind it.
        //12 is what a Zynq-7000 PS master carries on M_AXI_GP. A parameter
        //rather than a localparam because the port list needs it, and unlike
        //RAM_ADDR_W it depends on nothing, so the packager has no dependency
        //attribute to drop and 19-818 does not apply.
        parameter RAM_ID_W = 12
    )
    (
        input clk,
        input rstn, //Synchronous active low. Board reset (SW0)

        //Peripheral AXI4-Lite bus
        //AR
        input m_axi_arready,
        output m_axi_arvalid,
        output [31:0] m_axi_araddr,

        //R
        output m_axi_rready,
        input m_axi_rvalid,
        input [31:0] m_axi_rdata,
        input [1:0] m_axi_rresp,

        //AW
        input m_axi_awready,
        output m_axi_awvalid,
        output [31:0] m_axi_awaddr,

        //W
        input m_axi_wready,
        output m_axi_wvalid,
        output [31:0] m_axi_wdata,
        output [3:0] m_axi_wstrb,

        //B
        output m_axi_bready,
        input m_axi_bvalid,
        input [1:0] m_axi_bresp,

        //From cva5_clint_axi: the timer and software interrupts. These two are
        //all that enters this module from the interrupt controller, and the
        //PLIC's external will make three -- see cva5_wrapper.sv.
        input mtip,
        input msip,

        //From cva5_plic_axi: the external interrupt. Three interrupt inputs in
        //total now, which is the whole of what RISC-V gives a hart -- however
        //many peripherals the bus grows, they arrive through this one.
        input external,

        //Debug System Bus Access, AXI4-Lite master
        output [31:0] m_axi_dbg_awaddr,
        output [2:0] m_axi_dbg_awprot,
        output m_axi_dbg_awvalid,
        input m_axi_dbg_awready,
        output [31:0] m_axi_dbg_wdata,
        output [3:0] m_axi_dbg_wstrb,
        output m_axi_dbg_wvalid,
        input m_axi_dbg_wready,
        input [1:0] m_axi_dbg_bresp,
        input m_axi_dbg_bvalid,
        output m_axi_dbg_bready,
        output [31:0] m_axi_dbg_araddr,
        output [2:0] m_axi_dbg_arprot,
        output m_axi_dbg_arvalid,
        input m_axi_dbg_arready,
        input [31:0] m_axi_dbg_rdata,
        input [1:0] m_axi_dbg_rresp,
        input m_axi_dbg_rvalid,
        output m_axi_dbg_rready,

        output ndmreset,

        //Hold the CPU, from outside. Active high, and it resets the CPU only:
        //whoever asserts it can still write main memory through the slave
        //port below, which is the point of having both. Tie low if unused.
        input cpu_halt,

        //External AXI4 slave into main memory, shared with the debugger by
        //cva5_ram_mux. The address bus is $clog2(WORDS)+2 bits so the
        //packaged IP offers exactly the 128 KB the RAM is -- see
        //README.pynq_z2.md on why a slave port is narrow and a master port is
        //not. It is written from WORDS rather than from the RAM_ADDR_W
        //localparam below because a port list cannot reference one, and
        //RAM_ADDR_W must not go back in the parameter list: as a parameter
        //with a dependency on WORDS it trips IP_Flow 19-818, which is the
        //whole reason it was moved into the body.
        input [RAM_ID_W-1:0] s_axi_ext_awid,
        input [$clog2(WORDS)+1:0] s_axi_ext_awaddr,
        input [7:0] s_axi_ext_awlen,
        input [2:0] s_axi_ext_awsize,
        input [1:0] s_axi_ext_awburst,
        input s_axi_ext_awvalid,
        output s_axi_ext_awready,
        input [31:0] s_axi_ext_wdata,
        input [3:0] s_axi_ext_wstrb,
        input s_axi_ext_wlast,
        input s_axi_ext_wvalid,
        output s_axi_ext_wready,
        output [RAM_ID_W-1:0] s_axi_ext_bid,
        output [1:0] s_axi_ext_bresp,
        output s_axi_ext_bvalid,
        input s_axi_ext_bready,
        input [RAM_ID_W-1:0] s_axi_ext_arid,
        input [$clog2(WORDS)+1:0] s_axi_ext_araddr,
        input [7:0] s_axi_ext_arlen,
        input [2:0] s_axi_ext_arsize,
        input [1:0] s_axi_ext_arburst,
        input s_axi_ext_arvalid,
        output s_axi_ext_arready,
        output [RAM_ID_W-1:0] s_axi_ext_rid,
        output [31:0] s_axi_ext_rdata,
        output [1:0] s_axi_ext_rresp,
        output s_axi_ext_rlast,
        output s_axi_ext_rvalid,
        input s_axi_ext_rready
    );

    //Derived, and deliberately not a parameter. As a parameter with a default
    //expression it became a user parameter of the packaged IP whose dependency
    //on WORDS the packager drops:
    //
    //  INFO: [IP_Flow 19-818] Not transferring value dependency attribute
    //        "spirit:ceil(spirit:log(2,spirit:decode(id('MODELPARAM_VALUE.WORDS'))))"
    //        into user parameter "RAM_ADDR_W".
    //
    //which left the IP GUI offering an address width that would not follow a
    //changed WORDS -- and the RAM window cva5_sba_split decodes is cut from it,
    //so a stale value aims the debugger's writes at the wrong side of the split.
    //A localparam cannot be overridden, so there is nothing to get out of step.
    localparam RAM_ADDR_W = $clog2(WORDS);

    cva5_wrapper #(.LOCAL_MEM(LOCAL_MEM), .WORDS(WORDS), .RAM_ADDR_W(RAM_ADDR_W),
                   .RAM_ID_W(RAM_ID_W)) cva5_inst(
        .clk(clk),
        .rstn(rstn),
        .m_axi_arready(m_axi_arready),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_rready(m_axi_rready),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_awready(m_axi_awready),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_wready(m_axi_wready),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_bready(m_axi_bready),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bresp(m_axi_bresp),
        .mtip(mtip),
        .msip(msip),
        .external(external),
        .m_axi_dbg_awaddr(m_axi_dbg_awaddr),
        .m_axi_dbg_awprot(m_axi_dbg_awprot),
        .m_axi_dbg_awvalid(m_axi_dbg_awvalid),
        .m_axi_dbg_awready(m_axi_dbg_awready),
        .m_axi_dbg_wdata(m_axi_dbg_wdata),
        .m_axi_dbg_wstrb(m_axi_dbg_wstrb),
        .m_axi_dbg_wvalid(m_axi_dbg_wvalid),
        .m_axi_dbg_wready(m_axi_dbg_wready),
        .m_axi_dbg_bresp(m_axi_dbg_bresp),
        .m_axi_dbg_bvalid(m_axi_dbg_bvalid),
        .m_axi_dbg_bready(m_axi_dbg_bready),
        .m_axi_dbg_araddr(m_axi_dbg_araddr),
        .m_axi_dbg_arprot(m_axi_dbg_arprot),
        .m_axi_dbg_arvalid(m_axi_dbg_arvalid),
        .m_axi_dbg_arready(m_axi_dbg_arready),
        .m_axi_dbg_rdata(m_axi_dbg_rdata),
        .m_axi_dbg_rresp(m_axi_dbg_rresp),
        .m_axi_dbg_rvalid(m_axi_dbg_rvalid),
        .m_axi_dbg_rready(m_axi_dbg_rready),
        .ndmreset(ndmreset),
        .cpu_halt(cpu_halt),
        .s_axi_ext_awid(s_axi_ext_awid),
        .s_axi_ext_awaddr(s_axi_ext_awaddr),
        .s_axi_ext_awlen(s_axi_ext_awlen),
        .s_axi_ext_awsize(s_axi_ext_awsize),
        .s_axi_ext_awburst(s_axi_ext_awburst),
        .s_axi_ext_awvalid(s_axi_ext_awvalid),
        .s_axi_ext_awready(s_axi_ext_awready),
        .s_axi_ext_wdata(s_axi_ext_wdata),
        .s_axi_ext_wstrb(s_axi_ext_wstrb),
        .s_axi_ext_wlast(s_axi_ext_wlast),
        .s_axi_ext_wvalid(s_axi_ext_wvalid),
        .s_axi_ext_wready(s_axi_ext_wready),
        .s_axi_ext_bid(s_axi_ext_bid),
        .s_axi_ext_bresp(s_axi_ext_bresp),
        .s_axi_ext_bvalid(s_axi_ext_bvalid),
        .s_axi_ext_bready(s_axi_ext_bready),
        .s_axi_ext_arid(s_axi_ext_arid),
        .s_axi_ext_araddr(s_axi_ext_araddr),
        .s_axi_ext_arlen(s_axi_ext_arlen),
        .s_axi_ext_arsize(s_axi_ext_arsize),
        .s_axi_ext_arburst(s_axi_ext_arburst),
        .s_axi_ext_arvalid(s_axi_ext_arvalid),
        .s_axi_ext_arready(s_axi_ext_arready),
        .s_axi_ext_rid(s_axi_ext_rid),
        .s_axi_ext_rdata(s_axi_ext_rdata),
        .s_axi_ext_rresp(s_axi_ext_rresp),
        .s_axi_ext_rlast(s_axi_ext_rlast),
        .s_axi_ext_rvalid(s_axi_ext_rvalid),
        .s_axi_ext_rready(s_axi_ext_rready),
        //External JTAG unused on the board: the DTM sits on the FPGA's own TAP
        .jtag_tck(1'b0),
        .jtag_tms(1'b0),
        .jtag_trst_n(1'b1),
        .jtag_tdi(1'b0),
        .jtag_tdo()
    );

endmodule
