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

module cva5_wrapper

    import cva5_config::*;
    import cva5_types::*;

    #(
        parameter string LOCAL_MEM = "boot.mif", //Boot ROM image
        parameter int unsigned WORDS = 256       //Boot ROM size in words
    )
    (
        input logic clk,
        input logic rstn, //Synchronous active low. Board reset (SW0); does NOT include ndmreset

        //Peripheral AXI bus
        //AR
        input logic m_axi_arready,
        output logic m_axi_arvalid,
        output logic [31:0] m_axi_araddr,

        //R
        output logic m_axi_rready,
        input logic m_axi_rvalid,
        input logic [31:0] m_axi_rdata,
        input logic [1:0] m_axi_rresp,

        //AW
        input logic m_axi_awready,
        output logic m_axi_awvalid,
        output logic [31:0] m_axi_awaddr,

        //W
        input logic m_axi_wready,
        output logic m_axi_wvalid,
        output logic [31:0] m_axi_wdata,
        output logic [3:0] m_axi_wstrb,

        //B
        output logic m_axi_bready,
        input logic m_axi_bvalid,
        input logic [1:0] m_axi_bresp,

        //Cached memory (I$/D$ fills), AXI4 master with bursts
        input logic m_axi_mem_arready,
        output logic m_axi_mem_arvalid,
        output logic [31:0] m_axi_mem_araddr,
        output logic [7:0] m_axi_mem_arlen,
        output logic [2:0] m_axi_mem_arsize,
        output logic [1:0] m_axi_mem_arburst,
        output logic [3:0] m_axi_mem_arcache,
        output logic [5:0] m_axi_mem_arid,

        output logic m_axi_mem_rready,
        input logic m_axi_mem_rvalid,
        input logic [31:0] m_axi_mem_rdata,
        input logic [1:0] m_axi_mem_rresp,
        input logic m_axi_mem_rlast,
        input logic [5:0] m_axi_mem_rid,

        input logic m_axi_mem_awready,
        output logic m_axi_mem_awvalid,
        output logic [31:0] m_axi_mem_awaddr,
        output logic [7:0] m_axi_mem_awlen,
        output logic [2:0] m_axi_mem_awsize,
        output logic [1:0] m_axi_mem_awburst,
        output logic [3:0] m_axi_mem_awcache,
        output logic [5:0] m_axi_mem_awid,

        input logic m_axi_mem_wready,
        output logic m_axi_mem_wvalid,
        output logic [31:0] m_axi_mem_wdata,
        output logic [3:0] m_axi_mem_wstrb,
        output logic m_axi_mem_wlast,

        output logic m_axi_mem_bready,
        input logic m_axi_mem_bvalid,
        input logic [1:0] m_axi_mem_bresp,
        input logic [5:0] m_axi_mem_bid,

        //Debug System Bus Access, AXI4-Lite master
        output logic [31:0] m_axi_dbg_awaddr,
        output logic [2:0] m_axi_dbg_awprot,
        output logic m_axi_dbg_awvalid,
        input logic m_axi_dbg_awready,
        output logic [31:0] m_axi_dbg_wdata,
        output logic [3:0] m_axi_dbg_wstrb,
        output logic m_axi_dbg_wvalid,
        input logic m_axi_dbg_wready,
        input logic [1:0] m_axi_dbg_bresp,
        input logic m_axi_dbg_bvalid,
        output logic m_axi_dbg_bready,
        output logic [31:0] m_axi_dbg_araddr,
        output logic [2:0] m_axi_dbg_arprot,
        output logic m_axi_dbg_arvalid,
        input logic m_axi_dbg_arready,
        input logic [31:0] m_axi_dbg_rdata,
        input logic [1:0] m_axi_dbg_rresp,
        input logic m_axi_dbg_rvalid,
        output logic m_axi_dbg_rready,

        //Non-debug-module reset, for peripherals that should reset with the CPU
        output logic ndmreset //Debugger reset request (active high). Resets the CPU only, as in Ibex.
    );

    //CPU connections
    local_memory_interface data_bram();
    local_memory_interface instruction_bram();
    axi_interface m_axi();
    avalon_interface m_avalon(); //Unused
    wishbone_interface dwishbone(); //Unused
    wishbone_interface iwishbone(); //Unused
    mem_interface mem[1]();
    logic[63:0] mtime;
    interrupt_t s_interrupt; //Unused
    interrupt_t m_interrupt; //Unused

    ////////////////////////////////////////////////////
    //Implementation
    //Instantiates a CVA5 processor using local memory
    //Program start address 0x8000_0000
    //Local memory space from 0x8000_0000 through 0x80FF_FFFF
    //Peripheral bus from 0x6000_0000 through 0x6FFF_FFFF

    localparam wb_group_config_t WB_CPU_CONFIG = '{
        0 : '{0: ALU_ID, default : NON_WRITEBACK_ID},
        1 : '{0: LS_ID, default : NON_WRITEBACK_ID},
        2 : '{0: MUL_ID, 1: DIV_ID, 2: CSR_ID, 3: FPU_ID, 4: CUSTOM_ID, default : NON_WRITEBACK_ID},
        default : '{default : NON_WRITEBACK_ID}
    };

    localparam cpu_config_t CPU_CONFIG = '{
        //ISA options
        MODES : M,
        INCLUDE_UNIT : '{
            MUL : 1,
            DIV : 1,
            CSR : 1,
            FPU : 0,
            CUSTOM : 0,
            default: '0
        },
        INCLUDE_IFENCE : 0,
        INCLUDE_AMO : 0,
        INCLUDE_CBO : 0,
        //CSR constants
        CSRS : '{
            MACHINE_IMPLEMENTATION_ID : 0,
            CPU_ID : 0,
            RESET_VEC : 32'h80000000,
            RESET_TVEC : 32'h00000000,
            MCONFIGPTR : '0,
            INCLUDE_ZICNTR : 1,
            INCLUDE_ZIHPM : 0,
            INCLUDE_SSTC : 0,
            INCLUDE_SMSTATEEN : 0
        },
        //Memory Options
        SQ_DEPTH : 4,
        INCLUDE_FORWARDING_TO_STORES : 1,
        AMO_UNIT : '{
            LR_WAIT : 32,
            RESERVATION_WORDS : 8
        },
        INCLUDE_ICACHE : 1,
        ICACHE_ADDR : '{
            L: 32'h40000000,
            H: 32'h4FFFFFFF
        },
        ICACHE : '{
            LINES : 512,
            LINE_W : 4,
            WAYS : 1,
            USE_EXTERNAL_INVALIDATIONS : 0,
            USE_NON_CACHEABLE : 0,
            NON_CACHEABLE : '{
                L: 32'h70000000,
                H: 32'h7FFFFFFF
            }
        },
        ITLB : '{
            WAYS : 2,
            DEPTH : 64
        },
        INCLUDE_DCACHE : 1,
        DCACHE_ADDR : '{
            L: 32'h40000000,
            H: 32'h4FFFFFFF
        },
        DCACHE : '{
            LINES : 512,
            LINE_W : 4,
            WAYS : 1,
            USE_EXTERNAL_INVALIDATIONS : 0,
            USE_NON_CACHEABLE : 0,
            NON_CACHEABLE : '{
                L: 32'h70000000,
                H: 32'h7FFFFFFF
            }
        },
        DTLB : '{
            WAYS : 2,
            DEPTH : 64
        },
        INCLUDE_ILOCAL_MEM : 1,
        ILOCAL_MEM_ADDR : '{
            L : 32'h80000000, 
            H : 32'h80FFFFFF
        },
        INCLUDE_DLOCAL_MEM : 1, //Boot ROM is readable as data too; nothing writes it
        DLOCAL_MEM_ADDR : '{
            L : 32'h80000000,
            H : 32'h80FFFFFF
        },
        INCLUDE_IBUS : 0,
        IBUS_ADDR : '{
            L : 32'h60000000, 
            H : 32'h6FFFFFFF
        },
        INCLUDE_PERIPHERAL_BUS : 1,
        PERIPHERAL_BUS_ADDR : '{
            L : 32'h60000000,
            H : 32'h6FFFFFFF
        },
        PERIPHERAL_BUS_TYPE : AXI_BUS,
        //Branch Predictor Options
        INCLUDE_BRANCH_PREDICTOR : 1,
        BP : '{
            WAYS : 2,
            ENTRIES : 512,
            RAS_ENTRIES : 8
        },
        //Writeback Options
        NUM_WB_GROUPS : 3,
        WB_GROUP : WB_CPU_CONFIG
    };

    ////////////////////////////////////////////////////
    //Cached memory path: I$/D$ line fills and writebacks over AXI4
    axi_interface m_axi_mem();

    axi_adapter #(.NUM_CORES(1)) mem_axi_adapter (
        .clk (clk),
        .rst (rst),
        .mems (mem),
        .axi (m_axi_mem)
    );

    assign m_axi_mem.arready = m_axi_mem_arready;
    assign m_axi_mem_arvalid = m_axi_mem.arvalid;
    assign m_axi_mem_araddr = m_axi_mem.araddr;
    assign m_axi_mem_arlen = m_axi_mem.arlen;
    assign m_axi_mem_arsize = m_axi_mem.arsize;
    assign m_axi_mem_arburst = m_axi_mem.arburst;
    assign m_axi_mem_arcache = m_axi_mem.arcache;
    assign m_axi_mem_arid = m_axi_mem.arid;

    assign m_axi_mem_rready = m_axi_mem.rready;
    assign m_axi_mem.rvalid = m_axi_mem_rvalid;
    assign m_axi_mem.rdata = m_axi_mem_rdata;
    assign m_axi_mem.rresp = m_axi_mem_rresp;
    assign m_axi_mem.rlast = m_axi_mem_rlast;
    assign m_axi_mem.rid = m_axi_mem_rid;

    assign m_axi_mem.awready = m_axi_mem_awready;
    assign m_axi_mem_awvalid = m_axi_mem.awvalid;
    assign m_axi_mem_awaddr = m_axi_mem.awaddr;
    assign m_axi_mem_awlen = m_axi_mem.awlen;
    assign m_axi_mem_awsize = m_axi_mem.awsize;
    assign m_axi_mem_awburst = m_axi_mem.awburst;
    assign m_axi_mem_awcache = m_axi_mem.awcache;
    assign m_axi_mem_awid = m_axi_mem.awid;

    assign m_axi_mem.wready = m_axi_mem_wready;
    assign m_axi_mem_wvalid = m_axi_mem.wvalid;
    assign m_axi_mem_wdata = m_axi_mem.wdata;
    assign m_axi_mem_wstrb = m_axi_mem.wstrb;
    assign m_axi_mem_wlast = m_axi_mem.wlast;

    assign m_axi_mem_bready = m_axi_mem.bready;
    assign m_axi_mem.bvalid = m_axi_mem_bvalid;
    assign m_axi_mem.bresp = m_axi_mem_bresp;
    assign m_axi_mem.bid = m_axi_mem_bid;

    ////////////////////////////////////////////////////
    //Debug subsystem (riscv-dbg over BSCANE2)
    //The DM is reset only by rstn, so ndmreset never resets the debugger.
    logic debug_req; //Unused until the core is debug-capable (P2)

    cva5_debug_subsys #(.DM_BASE_ADDR(32'h5000_0000), .HART_AVAILABLE(1'b0)) debug (
        .clk (clk),
        .rst_n (rstn),
        .ndmreset (ndmreset),
        .debug_req (debug_req),
        .dm_req (1'b0),
        .dm_we (1'b0),
        .dm_addr (32'h0),
        .dm_be (4'h0),
        .dm_wdata (32'h0),
        .dm_rdata (),
        .m_axi_awaddr (m_axi_dbg_awaddr),
        .m_axi_awprot (m_axi_dbg_awprot),
        .m_axi_awvalid (m_axi_dbg_awvalid),
        .m_axi_awready (m_axi_dbg_awready),
        .m_axi_wdata (m_axi_dbg_wdata),
        .m_axi_wstrb (m_axi_dbg_wstrb),
        .m_axi_wvalid (m_axi_dbg_wvalid),
        .m_axi_wready (m_axi_dbg_wready),
        .m_axi_bresp (m_axi_dbg_bresp),
        .m_axi_bvalid (m_axi_dbg_bvalid),
        .m_axi_bready (m_axi_dbg_bready),
        .m_axi_araddr (m_axi_dbg_araddr),
        .m_axi_arprot (m_axi_dbg_arprot),
        .m_axi_arvalid (m_axi_dbg_arvalid),
        .m_axi_arready (m_axi_dbg_arready),
        .m_axi_rdata (m_axi_dbg_rdata),
        .m_axi_rresp (m_axi_dbg_rresp),
        .m_axi_rvalid (m_axi_dbg_rvalid),
        .m_axi_rready (m_axi_dbg_rready)
    );

    logic rst = 1'b1; //Held in reset at configuration
    always_ff @(posedge clk) rst <= ~rstn | ndmreset; //Registered: ndmreset comes from DM logic


    cva5 #(.CONFIG(CPU_CONFIG)) cpu(.mem(mem[0]), .*);

    always_ff @(posedge clk) begin
        if (rst)
            mtime <= '0;
        else
            mtime <= mtime + 1;
    end

    assign s_interrupt = '{default: '0};
    assign m_interrupt = '{default: '0};

    //AXI peripheral mapping; ID widths are missmatched but unused
    assign m_axi.arready = m_axi_arready;
    assign m_axi_arvalid = m_axi.arvalid;
    assign m_axi_araddr = m_axi.araddr;

    assign m_axi_rready = m_axi.rready;
    assign m_axi.rvalid = m_axi_rvalid;
    assign m_axi.rdata = m_axi_rdata;
    assign m_axi.rresp = m_axi_rresp;
    assign m_axi.rid = 6'b0;

    assign m_axi.awready = m_axi_awready;
    assign m_axi_awvalid = m_axi.awvalid;
    assign m_axi_awaddr = m_axi.awaddr;

    assign m_axi.wready = m_axi_wready;
    assign m_axi_wvalid = m_axi.wvalid;
    assign m_axi_wdata = m_axi.wdata;
    assign m_axi_wstrb = m_axi.wstrb;

    assign m_axi_bready = m_axi.bready;
    assign m_axi.bvalid = m_axi_bvalid;
    assign m_axi.bresp = m_axi_bresp;
    assign m_axi.bid = 6'b0;

    //Block memory
    localparam BRAM_ADDR_W = $clog2(WORDS);
    tdp_ram #(
        .ADDR_WIDTH(BRAM_ADDR_W),
        .NUM_COL(4),
        .COL_WIDTH(8),
        .PIPELINE_DEPTH(0),
        .CASCADE_DEPTH(8),
        .USE_PRELOAD(1),
        .PRELOAD_FILE(LOCAL_MEM)
    ) local_mem (
        .a_en(instruction_bram.en),
        .a_wbe(instruction_bram.be),
        .a_wdata(instruction_bram.data_in),
        .a_addr(instruction_bram.addr[BRAM_ADDR_W-1:0]),
        .a_rdata(instruction_bram.data_out),
        .b_en(data_bram.en),
        .b_wbe(data_bram.be),
        .b_wdata(data_bram.data_in),
        .b_addr(data_bram.addr[BRAM_ADDR_W-1:0]),
        .b_rdata(data_bram.data_out),
    .*);

endmodule
