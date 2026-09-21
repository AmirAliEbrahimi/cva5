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
        parameter LOCAL_MEM = "boot.mif", //Boot ROM image; jumps to main RAM
        parameter WORDS = 256      //Boot ROM size in words
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

        //Cached memory (I$/D$ fills), AXI4 master with bursts
        input m_axi_mem_arready,
        output m_axi_mem_arvalid,
        output [31:0] m_axi_mem_araddr,
        output [7:0] m_axi_mem_arlen,
        output [2:0] m_axi_mem_arsize,
        output [1:0] m_axi_mem_arburst,
        output [3:0] m_axi_mem_arcache,
        output [5:0] m_axi_mem_arid,
        output m_axi_mem_rready,
        input m_axi_mem_rvalid,
        input [31:0] m_axi_mem_rdata,
        input [1:0] m_axi_mem_rresp,
        input m_axi_mem_rlast,
        input [5:0] m_axi_mem_rid,
        input m_axi_mem_awready,
        output m_axi_mem_awvalid,
        output [31:0] m_axi_mem_awaddr,
        output [7:0] m_axi_mem_awlen,
        output [2:0] m_axi_mem_awsize,
        output [1:0] m_axi_mem_awburst,
        output [3:0] m_axi_mem_awcache,
        output [5:0] m_axi_mem_awid,
        input m_axi_mem_wready,
        output m_axi_mem_wvalid,
        output [31:0] m_axi_mem_wdata,
        output [3:0] m_axi_mem_wstrb,
        output m_axi_mem_wlast,
        output m_axi_mem_bready,
        input m_axi_mem_bvalid,
        input [1:0] m_axi_mem_bresp,
        input [5:0] m_axi_mem_bid,

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

    cva5_wrapper #(.LOCAL_MEM(LOCAL_MEM), .WORDS(WORDS)) cva5_inst(
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
        .m_axi_mem_arready(m_axi_mem_arready),
        .m_axi_mem_arvalid(m_axi_mem_arvalid),
        .m_axi_mem_araddr(m_axi_mem_araddr),
        .m_axi_mem_arlen(m_axi_mem_arlen),
        .m_axi_mem_arsize(m_axi_mem_arsize),
        .m_axi_mem_arburst(m_axi_mem_arburst),
        .m_axi_mem_arcache(m_axi_mem_arcache),
        .m_axi_mem_arid(m_axi_mem_arid),
        .m_axi_mem_rready(m_axi_mem_rready),
        .m_axi_mem_rvalid(m_axi_mem_rvalid),
        .m_axi_mem_rdata(m_axi_mem_rdata),
        .m_axi_mem_rresp(m_axi_mem_rresp),
        .m_axi_mem_rlast(m_axi_mem_rlast),
        .m_axi_mem_rid(m_axi_mem_rid),
        .m_axi_mem_awready(m_axi_mem_awready),
        .m_axi_mem_awvalid(m_axi_mem_awvalid),
        .m_axi_mem_awaddr(m_axi_mem_awaddr),
        .m_axi_mem_awlen(m_axi_mem_awlen),
        .m_axi_mem_awsize(m_axi_mem_awsize),
        .m_axi_mem_awburst(m_axi_mem_awburst),
        .m_axi_mem_awcache(m_axi_mem_awcache),
        .m_axi_mem_awid(m_axi_mem_awid),
        .m_axi_mem_wready(m_axi_mem_wready),
        .m_axi_mem_wvalid(m_axi_mem_wvalid),
        .m_axi_mem_wdata(m_axi_mem_wdata),
        .m_axi_mem_wstrb(m_axi_mem_wstrb),
        .m_axi_mem_wlast(m_axi_mem_wlast),
        .m_axi_mem_bready(m_axi_mem_bready),
        .m_axi_mem_bvalid(m_axi_mem_bvalid),
        .m_axi_mem_bresp(m_axi_mem_bresp),
        .m_axi_mem_bid(m_axi_mem_bid),
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
