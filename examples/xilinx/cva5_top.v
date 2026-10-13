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
        parameter RAM_ADDR_W = $clog2(WORDS)
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

        //Main memory, AXI4-Lite slave: the debugger's way into the local
        //memory the program runs from. See cva5_wrapper.sv.
        input [7:0] s_axi_ram_awid,
        input [RAM_ADDR_W+1:0] s_axi_ram_awaddr,
        input [7:0] s_axi_ram_awlen,
        input [2:0] s_axi_ram_awsize,
        input [1:0] s_axi_ram_awburst,
        input s_axi_ram_awvalid,
        output s_axi_ram_awready,
        input [31:0] s_axi_ram_wdata,
        input [3:0] s_axi_ram_wstrb,
        input s_axi_ram_wlast,
        input s_axi_ram_wvalid,
        output s_axi_ram_wready,
        output [7:0] s_axi_ram_bid,
        output [1:0] s_axi_ram_bresp,
        output s_axi_ram_bvalid,
        input s_axi_ram_bready,
        input [7:0] s_axi_ram_arid,
        input [RAM_ADDR_W+1:0] s_axi_ram_araddr,
        input [7:0] s_axi_ram_arlen,
        input [2:0] s_axi_ram_arsize,
        input [1:0] s_axi_ram_arburst,
        input s_axi_ram_arvalid,
        output s_axi_ram_arready,
        output [7:0] s_axi_ram_rid,
        output [31:0] s_axi_ram_rdata,
        output [1:0] s_axi_ram_rresp,
        output s_axi_ram_rlast,
        output s_axi_ram_rvalid,
        input s_axi_ram_rready,

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

        output ndmreset
    );

    cva5_wrapper #(.LOCAL_MEM(LOCAL_MEM), .WORDS(WORDS), .RAM_ADDR_W(RAM_ADDR_W)) cva5_inst(
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
        .s_axi_ram_awid(s_axi_ram_awid),
        .s_axi_ram_awaddr(s_axi_ram_awaddr),
        .s_axi_ram_awlen(s_axi_ram_awlen),
        .s_axi_ram_awsize(s_axi_ram_awsize),
        .s_axi_ram_awburst(s_axi_ram_awburst),
        .s_axi_ram_awvalid(s_axi_ram_awvalid),
        .s_axi_ram_awready(s_axi_ram_awready),
        .s_axi_ram_wdata(s_axi_ram_wdata),
        .s_axi_ram_wstrb(s_axi_ram_wstrb),
        .s_axi_ram_wlast(s_axi_ram_wlast),
        .s_axi_ram_wvalid(s_axi_ram_wvalid),
        .s_axi_ram_wready(s_axi_ram_wready),
        .s_axi_ram_bid(s_axi_ram_bid),
        .s_axi_ram_bresp(s_axi_ram_bresp),
        .s_axi_ram_bvalid(s_axi_ram_bvalid),
        .s_axi_ram_bready(s_axi_ram_bready),
        .s_axi_ram_arid(s_axi_ram_arid),
        .s_axi_ram_araddr(s_axi_ram_araddr),
        .s_axi_ram_arlen(s_axi_ram_arlen),
        .s_axi_ram_arsize(s_axi_ram_arsize),
        .s_axi_ram_arburst(s_axi_ram_arburst),
        .s_axi_ram_arvalid(s_axi_ram_arvalid),
        .s_axi_ram_arready(s_axi_ram_arready),
        .s_axi_ram_rid(s_axi_ram_rid),
        .s_axi_ram_rdata(s_axi_ram_rdata),
        .s_axi_ram_rresp(s_axi_ram_rresp),
        .s_axi_ram_rlast(s_axi_ram_rlast),
        .s_axi_ram_rvalid(s_axi_ram_rvalid),
        .s_axi_ram_rready(s_axi_ram_rready),
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
        //External JTAG unused on the board: the DTM sits on the FPGA's own TAP
        .jtag_tck(1'b0),
        .jtag_tms(1'b0),
        .jtag_trst_n(1'b1),
        .jtag_tdi(1'b0),
        .jtag_tdo()
    );

endmodule
