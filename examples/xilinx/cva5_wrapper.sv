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
        //Main memory: a true dual-port block RAM, inferred, no Xilinx memory
        //IP involved. The preload is what a freshly programmed board runs
        //before anything is loaded over JTAG.
        parameter string LOCAL_MEM = "ram.mif",
        parameter int unsigned WORDS = 32768,
        parameter int unsigned RAM_ADDR_W = $clog2(WORDS)
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

        //From cva5_clint_axi, the CLINT peripheral on the bus: the timer and
        //software interrupts, which is all that enters this module from the
        //interrupt controller. RISC-V puts these on their own mip bits (MTIP,
        //cause 7, and MSIP, cause 3), so they come from the CLINT directly and
        //never through a PLIC -- a PLIC aggregates device interrupts into MEIP
        //alone. When the PLIC lands, external makes three, and three is the
        //whole of it however many peripherals the bus carries.
        input logic mtip,
        input logic msip,

        //From cva5_plic_axi: the external interrupt, mip.MEIP. One wire for
        //every device on the bus, which is the PLIC's whole purpose -- it
        //decides which device interrupt is the highest priority one pending,
        //and software asks it which by claiming.
        input logic external,

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
        output logic ndmreset, //Debugger reset request (active high). Resets the CPU only, as in Ibex.

        //External JTAG. Tied off on the board, where the DTM sits on the FPGA's
        //own TAP (BSCANE2) and ignores these; driven by the simulation harness,
        //which builds riscv-dbg's dmi_jtag_tap instead.
        input logic jtag_tck,
        input logic jtag_tms,
        input logic jtag_trst_n,
        input logic jtag_tdi,
        output logic jtag_tdo
    );

    //CPU connections
    local_memory_interface data_bram();
    local_memory_interface instruction_bram();
    axi_interface m_axi();
    avalon_interface m_avalon(); //Unused
    wishbone_interface dwishbone(); //Unused
    wishbone_interface iwishbone(); //Debug Module fetches
    mem_interface mem[1]();
    interrupt_t s_interrupt;    //Unused: no supervisor mode in this config
    interrupt_t m_interrupt;    //timer and software from the CLINT

    ////////////////////////////////////////////////////
    //Implementation
    //Instantiates a CVA5 processor using local memory.
    //
    //The address map follows CVA6's, so that the choices are a CORE-V
    //convention rather than ours. examples/sw/soc.h is the software copy and
    //carries the full table; the parts this wrapper decides are:
    //
    //  0x0000_0000   4 KB   Debug Module -- ROM, program buffer, data regs
    //  0x1000_0000   4 KB   UART, out through the peripheral bus
    //  0x8000_0000 128 KB   main RAM, instruction fetch and load/store
    //
    //Peripheral bus covers 0x0000_0000 through 0x7FFF_FFFF: everything that is
    //not RAM is a peripheral, which is the whole of the split now that RAM is
    //the only thing above 0x8000_0000. The crossbar decodes within it and
    //returns a DECERR for an address no slave claims, so the wide range costs
    //nothing and needs no edit when the CLINT and PLIC arrive at CVA6's
    //0x0200_0000 and 0x0C00_0000.

    localparam wb_group_config_t WB_CPU_CONFIG = '{
        0 : '{0: ALU_ID, default : NON_WRITEBACK_ID},
        1 : '{0: LS_ID, default : NON_WRITEBACK_ID},
        2 : '{0: MUL_ID, 1: DIV_ID, 2: CSR_ID, 3: FPU_ID, 4: CUSTOM_ID, default : NON_WRITEBACK_ID},
        default : '{default : NON_WRITEBACK_ID}
    };

    //Debug Module base address. Its 4 KB window holds the debug ROM
    //(halt at +0x800), program buffer and abstract data registers. At zero,
    //as in CVA6. Nothing outside the chip observes it -- OpenOCD reaches the
    //DM over DMI, not the system bus -- but it does mean a trap can no longer
    //be left to go to address zero, which is what TRAP_VEC below is for.
    localparam logic [31:0] DM_BASE = 32'h0000_0000;
    //CLINT, at CVA6's address. A 64 KB window: clint_wrapper decodes address
    //bits 15:2 and the standard layout puts mtime at +0xBFF8.
    localparam logic [31:0] CLINT_BASE = 32'h0200_0000;

    //Core clock in MHz. The CLINT's prescaler divides by this to get a
    //one-microsecond mtime tick, so a clock change here is the only edit
    //needed to keep mtime meaning microseconds. pynq_z2_sys.tcl's clk_wiz
    //produces 100 MHz; examples/sw/soc.h carries the same number as CLINT_HZ.
    localparam int unsigned CLOCK_MHZ = 100;
    //Boot ROM, at CVA6's address. Two instructions: the reset vector points
    //here and the ROM jumps to APP_ENTRY, so the core comes out of reset into
    //a genuinely read-only location rather than into writable RAM that the
    //debugger may not have loaded yet.
    localparam logic [31:0] ROM_BASE = 32'h0001_0000;
    localparam logic [31:0] RAM_BASE = 32'h8000_0000;

    //Where a trap goes, and where execution starts. Nothing in examples/sw
    //writes mtvec, so RESET_TVEC is the trap vector for the whole life of the
    //program and has to be a real address: with the Debug Module at zero, the
    //reset value of zero would send every trap into the debug ROM.
    //
    //crt0.S puts its handler at the base of RAM and _start 0x40 above it, and
    //examples/sw/fpga_link.ld asserts both. Change the 0x40 here and the link
    //fails rather than the board jumping into the middle of the handler.
    localparam logic [31:0] TRAP_VEC = RAM_BASE;
    localparam logic [31:0] APP_ENTRY = RAM_BASE + 32'h40;

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
        INCLUDE_IFENCE : 1, //fence.i: debuggers use it to make code writes visible to fetch
        INCLUDE_AMO : 0,
        INCLUDE_CBO : 0,
        //CSR constants
        CSRS : '{
            MACHINE_IMPLEMENTATION_ID : 0,
            CPU_ID : 0,
            RESET_VEC : ROM_BASE,
            RESET_TVEC : TRAP_VEC,
            MCONFIGPTR : '0,
            INCLUDE_ZICNTR : 1,  //cycle and instret, counted inside the core
            INCLUDE_TIME_CSR : 0, //time/timeh: the CLINT publishes it on the bus
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
        INCLUDE_ICACHE : 0,
        ICACHE_ADDR : '{
            L: RAM_BASE,
            H: RAM_BASE + 32'h0FFFFFFF
        },
        ICACHE : '{
            LINES : 512,
            LINE_W : 4,
            WAYS : 1,
            USE_EXTERNAL_INVALIDATIONS : 0,
            USE_NON_CACHEABLE : 0,
            NON_CACHEABLE : '{
                L: 32'h0000_0000,
                H: 32'h0000_0000
            }
        },
        ITLB : '{
            WAYS : 2,
            DEPTH : 64
        },
        INCLUDE_DCACHE : 0,
        DCACHE_ADDR : '{
            L: RAM_BASE,
            H: RAM_BASE + 32'h0FFFFFFF
        },
        DCACHE : '{
            LINES : 512,
            LINE_W : 4,
            WAYS : 1,
            USE_EXTERNAL_INVALIDATIONS : 0,
            USE_NON_CACHEABLE : 0,
            NON_CACHEABLE : '{
                L: 32'h0000_0000,
                H: 32'h0000_0000
            }
        },
        DTLB : '{
            WAYS : 2,
            DEPTH : 64
        },
        //Main memory. Instruction fetch takes one port of the RAM and
        //load/store the other, so both are a single cycle away and neither
        //needs a cache in front of it.
        INCLUDE_ILOCAL_MEM : 1,
        ILOCAL_MEM_ADDR : '{
            L : RAM_BASE,
            H : RAM_BASE + 32'(WORDS*4 - 1)
        },
        INCLUDE_DLOCAL_MEM : 1,
        DLOCAL_MEM_ADDR : '{
            L : RAM_BASE,
            H : RAM_BASE + 32'(WORDS*4 - 1)
        },
        //Instruction bus: fetches of the Debug Module's ROM and program
        //buffer, and of the boot ROM. One window has to span both, since the
        //core has a single instruction bus, and this wrapper splits it by
        //address below.
        //
        //The top is 0x0001_FFFF rather than ROM_BASE + 0xFFF so that the
        //window is a power of two: fetch range-checks every PC against it, and
        //"pc <= 0x0001_FFFF" is ~|pc[31:17] where "pc <= 0x0001_0FFF" is a
        //magnitude comparator. The fetch path is this design's critical path,
        //so the cheaper form is worth the window being larger than the two
        //things in it. Addresses in the gaps read as zero, which decodes as an
        //illegal instruction and traps.
        //
        //It also keeps the branch predictor's geometry unchanged: BUS_RANGE
        //becomes 0x20000, equal to SCRATCH_RANGE, and branch_predictor.sv's
        //get_memory_width() takes the SCRATCH branch unless BUS_RANGE is
        //strictly greater -- so BTAG_W stays 6 and the tag banks keep their
        //shape.
        INCLUDE_IBUS : 1,
        IBUS_ADDR : '{
            L : DM_BASE,
            H : 32'h0001_FFFF
        },
        //Peripheral bus: the UART, plus the Debug Module's data registers
        //(split off by address in this wrapper)
        INCLUDE_PERIPHERAL_BUS : 1,
        PERIPHERAL_BUS_ADDR : '{
            L : 32'h0000_0000,
            H : RAM_BASE - 1
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
    //No cached memory path. Main memory is local memory inside this wrapper,
    //so there is no line fill to issue and the core's mem interface is unused.

    ////////////////////////////////////////////////////
    //Debug subsystem (riscv-dbg over BSCANE2)
    //The DM is reset only by rstn, so ndmreset never resets the debugger.
    logic debug_req;
    logic dm_req, dm_we;
    logic [31:0] dm_addr, dm_wdata, dm_rdata;
    logic [3:0] dm_be;

    cva5_debug_subsys #(.DM_BASE_ADDR(DM_BASE), .HART_AVAILABLE(1'b1)) debug (
        .clk (clk),
        .rst_n (rstn),
        .ndmreset (ndmreset),
        .debug_req (debug_req),
        .jtag_tck (jtag_tck),
        .jtag_tms (jtag_tms),
        .jtag_trst_n (jtag_trst_n),
        .jtag_tdi (jtag_tdi),
        .jtag_tdo (jtag_tdo),
        .dm_req (dm_req),
        .dm_we (dm_we),
        .dm_addr (dm_addr),
        .dm_be (dm_be),
        .dm_wdata (dm_wdata),
        .dm_rdata (dm_rdata),
        .m_axi_awaddr (sba_awaddr),
        .m_axi_awprot (sba_awprot),
        .m_axi_awvalid (sba_awvalid),
        .m_axi_awready (sba_awready),
        .m_axi_wdata (sba_wdata),
        .m_axi_wstrb (sba_wstrb),
        .m_axi_wvalid (sba_wvalid),
        .m_axi_wready (sba_wready),
        .m_axi_bresp (sba_bresp),
        .m_axi_bvalid (sba_bvalid),
        .m_axi_bready (sba_bready),
        .m_axi_araddr (sba_araddr),
        .m_axi_arprot (sba_arprot),
        .m_axi_arvalid (sba_arvalid),
        .m_axi_arready (sba_arready),
        .m_axi_rdata (sba_rdata),
        .m_axi_rresp (sba_rresp),
        .m_axi_rvalid (sba_rvalid),
        .m_axi_rready (sba_rready)
    );

    logic rst = 1'b1; //Held in reset at configuration
    always_ff @(posedge clk) rst <= ~rstn | ndmreset; //Registered: ndmreset comes from DM logic


    cva5 #(.CONFIG(CPU_CONFIG), .INCLUDE_DEBUG(1), .DM_BASE(DM_BASE)) cpu(.mem(mem[0]), .*);

    //mtip and msip arrive from cva5_clint_axi. mtime was a counter in this
    //file once, incrementing every clock; then the CLINT owned it but sat
    //inside this module. It is a peripheral on the bus now, which is where a
    //timer belongs.
    //
    //Its 64-bit count does not come back in. Inside the core mtime feeds only
    //the time/timeh CSR read mux and the Sstc stip comparison, and Sstc is off
    //here (MODES : M, INCLUDE_SSTC : 0) -- so those 64 wires served rdtime and
    //nothing else.
    //
    //Zicntr stays on: cycle and instret come from counters inside the core and
    //cost no wires. INCLUDE_TIME_CSR : 0 takes time/timeh out of it, so a
    //rdtime raises an illegal instruction rather than reading a tied-off zero.
    //That is what CVA6 does -- RVZicntr serves CSR_CYCLE and CSR_INSTRET from
    //its own counters, there is no CSR_TIME case at all, and a read of it
    //falls through to read_access_exception -- and it is what lowRISC
    //documents for Ibex, whose time(h) "are not implemented" and where "any
    //access to these registers will trap".
    //
    //Software reads the time where the CLINT publishes it, at CLINT_BASE +
    //0xBFF8. examples/sw already does; on a system with S-mode it is M-mode
    //firmware that fills the gap, which is why OpenSBI trap-and-emulates the
    //TIME CSR for platforms that do not implement it.
    logic [63:0] mtime;
    assign mtime = '0;

    assign s_interrupt = '{default: '0};
    assign m_interrupt = '{
        software : msip,
        timer    : mtip,
        external : external
    };

    ////////////////////////////////////////////////////
    //Peripheral bus split
    //The core's AXI master has one transaction in flight and holds its address
    //until the response, and always accepts responses, so the target can be
    //chosen from the current address with no latching.
    //Two targets: the Debug Module's data registers, and everything else,
    //which leaves the chip through m_axi to the crossbar. The CLINT used to be
    //a third leg here; it is a crossbar peripheral now, so the debugger can
    //reach it over the system bus as well as the core.
    logic pb_rd_dm, pb_wr_dm;
    assign pb_rd_dm = (m_axi.araddr[31:12] == DM_BASE[31:12]);
    assign pb_wr_dm = (m_axi.awaddr[31:12] == DM_BASE[31:12]);

    logic dmp_ar_ready, dmp_r_valid, dmp_aw_ready, dmp_w_ready, dmp_b_valid;
    logic [31:0] dmp_r_data;

    //External peripherals; ID widths are mismatched but unused
    assign m_axi_arvalid = m_axi.arvalid & ~pb_rd_dm;
    assign m_axi_araddr = m_axi.araddr;
    assign m_axi_rready = m_axi.rready;
    assign m_axi_awvalid = m_axi.awvalid & ~pb_wr_dm;
    assign m_axi_awaddr = m_axi.awaddr;
    assign m_axi_wvalid = m_axi.wvalid & ~pb_wr_dm;
    assign m_axi_wdata = m_axi.wdata;
    assign m_axi_wstrb = m_axi.wstrb;
    assign m_axi_bready = m_axi.bready;

    assign m_axi.arready = pb_rd_dm ? dmp_ar_ready : m_axi_arready;
    assign m_axi.rvalid = pb_rd_dm ? dmp_r_valid : m_axi_rvalid;
    assign m_axi.rdata = pb_rd_dm ? dmp_r_data : m_axi_rdata;
    assign m_axi.rresp = pb_rd_dm ? 2'b00 : m_axi_rresp;
    assign m_axi.rid = 6'b0;
    assign m_axi.awready = pb_wr_dm ? dmp_aw_ready : m_axi_awready;
    assign m_axi.wready = pb_wr_dm ? dmp_w_ready : m_axi_wready;
    assign m_axi.bvalid = pb_wr_dm ? dmp_b_valid : m_axi_bvalid;
    assign m_axi.bresp = pb_wr_dm ? 2'b00 : m_axi_bresp;
    assign m_axi.bid = 6'b0;


    ////////////////////////////////////////////////////
    //Instruction bus split: the Debug Module's memory and the boot ROM
    //
    //iwishbone.adr is a word address, as the interface declares, so a 4 KB
    //window compares adr[29:10] where a byte address would compare [31:12].
    //dm_mem_port applies the same shift the other way when it drives the DM.
    logic ib_dm_sel, ib_rom_sel;
    assign ib_dm_sel = (iwishbone.adr[29:10] == DM_BASE[31:12]);
    assign ib_rom_sel = (iwishbone.adr[29:10] == ROM_BASE[31:12]);

    logic ib_dm_ack;
    logic [31:0] ib_dm_dat_r, ib_rom_dat_r;

    boot_rom #(.ENTRY_ADDR(APP_ENTRY)) boot_rom_inst (
        .clk_i (clk),
        .req_i (iwishbone.cyc & iwishbone.stb & ib_rom_sel),
        .addr_i ({iwishbone.adr, 2'b00}),
        .rdata_o (ib_rom_dat_r)
    );

    //Anything on the instruction bus that is not the Debug Module is answered
    //from here in one cycle: the ROM inside its window, zero everywhere else.
    //Zero matters -- it decodes as an illegal instruction and traps, where
    //withholding the acknowledge would hang fetch with no indication of why.
    //
    //The acknowledge is a single cycle (hence the ~ib_other_ack term) and
    //ib_rom_sel is registered alongside it, so the data mux selects the ROM in
    //the same cycle the ROM presents its word.
    logic ib_other_ack, ib_rom_sel_q;
    always_ff @(posedge clk) begin
        if (rst) begin
            ib_other_ack <= 1'b0;
            ib_rom_sel_q <= 1'b0;
        end
        else begin
            ib_other_ack <= iwishbone.cyc & iwishbone.stb & ~ib_dm_sel & ~ib_other_ack;
            ib_rom_sel_q <= ib_rom_sel;
        end
    end

    assign iwishbone.ack = ib_dm_sel ? ib_dm_ack : ib_other_ack;
    assign iwishbone.dat_r = ib_dm_sel ? ib_dm_dat_r :
                             ib_rom_sel_q ? ib_rom_dat_r : 32'h0;

    //Debug Module memory: instruction fetch and load/store share its one port
    dm_mem_port dm_port (
        .clk (clk),
        .rst (rst),
        .if_adr (iwishbone.adr),
        .if_cyc (iwishbone.cyc & ib_dm_sel),
        .if_stb (iwishbone.stb),
        .if_ack (ib_dm_ack),
        .if_dat_r (ib_dm_dat_r),
        .ar_valid (m_axi.arvalid & pb_rd_dm),
        .ar_addr (m_axi.araddr),
        .ar_ready (dmp_ar_ready),
        .r_valid (dmp_r_valid),
        .r_data (dmp_r_data),
        .aw_valid (m_axi.awvalid & pb_wr_dm),
        .aw_addr (m_axi.awaddr),
        .aw_ready (dmp_aw_ready),
        .w_valid (m_axi.wvalid & pb_wr_dm),
        .w_data (m_axi.wdata),
        .w_strb (m_axi.wstrb),
        .w_ready (dmp_w_ready),
        .b_valid (dmp_b_valid),
        .dm_req (dm_req),
        .dm_we (dm_we),
        .dm_addr (dm_addr),
        .dm_be (dm_be),
        .dm_wdata (dm_wdata),
        .dm_rdata (dm_rdata)
    );
    assign iwishbone.err = 1'b0;

    //Block memory

    logic ram_b_en;
    logic [3:0] ram_b_wbe;
    logic [RAM_ADDR_W-1:0] ram_b_addr;
    logic [31:0] ram_b_wdata, ram_b_rdata;

    //Reset by rstn alone, never by ndmreset -- the same rule the Debug Module
    //itself follows. cpu_hold asserts ndmreset and THEN loads a program, so a
    //port reset by it would be held down for exactly the transfer it exists to
    //serve: the system bus access never completes and the DMI reports busy
    //until the debugger gives up.
    //
    //Registered locally rather than taken straight from the port, for the same
    //reason rst is two lines below: peripheral_aresetn fans out across the
    //whole design, and hanging this port off it directly cost 0.25 ns.
    logic ram_rstn = 1'b0; //Held in reset at configuration
    always_ff @(posedge clk) ram_rstn <= rstn;

    //The debugger's system bus master, and the RAM port's AXI4 slave, both
    //internal now.
    logic [31:0] sba_awaddr, sba_araddr, sba_wdata, sba_rdata;
    logic [2:0]  sba_awprot, sba_arprot;
    logic [3:0]  sba_wstrb;
    logic        sba_awvalid, sba_awready, sba_wvalid, sba_wready;
    logic        sba_bvalid, sba_bready, sba_arvalid, sba_arready;
    logic        sba_rvalid, sba_rready;
    logic [1:0]  sba_bresp, sba_rresp;

    //Three AXI4 bundles now, where there used to be one. cva5_sba_split's RAM
    //leg (dbg_*) and an external master (ext_*) are cva5_ram_mux's two slave
    //ports; rp_* is the mux's master port and the only one cva5_ram_port sees.
    logic [7:0]  dbg_awid, dbg_arid, dbg_bid, dbg_rid;
    logic [RAM_ADDR_W+1:0] dbg_awaddr, dbg_araddr;
    logic [7:0]  dbg_awlen, dbg_arlen;
    logic [2:0]  dbg_awsize, dbg_arsize;
    logic [1:0]  dbg_awburst, dbg_arburst, dbg_bresp, dbg_rresp;
    logic        dbg_awvalid, dbg_awready, dbg_wvalid, dbg_wready, dbg_wlast;
    logic [31:0] dbg_wdata, dbg_rdata;
    logic [3:0]  dbg_wstrb;
    logic        dbg_bvalid, dbg_bready, dbg_arvalid, dbg_arready;
    logic        dbg_rvalid, dbg_rready, dbg_rlast;

    logic [7:0]  ext_awid, ext_arid, ext_bid, ext_rid;
    logic [RAM_ADDR_W+1:0] ext_awaddr, ext_araddr;
    logic [7:0]  ext_awlen, ext_arlen;
    logic [2:0]  ext_awsize, ext_arsize;
    logic [1:0]  ext_awburst, ext_arburst, ext_bresp, ext_rresp;
    logic        ext_awvalid, ext_awready, ext_wvalid, ext_wready, ext_wlast;
    logic [31:0] ext_wdata, ext_rdata;
    logic [3:0]  ext_wstrb;
    logic        ext_bvalid, ext_bready, ext_arvalid, ext_arready;
    logic        ext_rvalid, ext_rready, ext_rlast;

    logic [7:0]  rp_awid, rp_arid, rp_bid, rp_rid;  //ram_port defaults ID_WIDTH to 8
    logic [RAM_ADDR_W+1:0] rp_awaddr, rp_araddr;
    logic [7:0]  rp_awlen, rp_arlen;
    logic [2:0]  rp_awsize, rp_arsize;
    logic [1:0]  rp_awburst, rp_arburst, rp_bresp, rp_rresp;
    logic        rp_awvalid, rp_awready, rp_wvalid, rp_wready, rp_wlast;
    logic [31:0] rp_wdata, rp_rdata;
    logic [3:0]  rp_wstrb;
    logic        rp_bvalid, rp_bready, rp_arvalid, rp_arready;
    logic        rp_rvalid, rp_rready, rp_rlast;

    ////////////////////////////////////////////////////
    //Debugger system bus split
    //
    //The Debug Module's system bus master used to leave through m_axi_dbg,
    //cross the crossbar and come back in through s_axi_ram to reach a RAM in
    //this same module. RAM accesses are answered here instead; everything else
    //-- the UART, the CLINT, anything the crossbar decodes -- still leaves
    //through m_axi_dbg. See the header of cva5_sba_split.sv.
    //
    //ram_rstn, not rst: this must not reset on ndmreset, for the same reason
    //the RAM port must not.
    cva5_sba_split #(
        .RAM_BASE (RAM_BASE),
        .RAM_ADDR_W (RAM_ADDR_W),
        .ID_WIDTH (8)
    ) sba_split (
        .clk (clk),
        .rstn (ram_rstn),

        .s_axi_awaddr (sba_awaddr),
        .s_axi_awprot (sba_awprot),
        .s_axi_awvalid (sba_awvalid),
        .s_axi_awready (sba_awready),
        .s_axi_wdata (sba_wdata),
        .s_axi_wstrb (sba_wstrb),
        .s_axi_wvalid (sba_wvalid),
        .s_axi_wready (sba_wready),
        .s_axi_bresp (sba_bresp),
        .s_axi_bvalid (sba_bvalid),
        .s_axi_bready (sba_bready),
        .s_axi_araddr (sba_araddr),
        .s_axi_arprot (sba_arprot),
        .s_axi_arvalid (sba_arvalid),
        .s_axi_arready (sba_arready),
        .s_axi_rdata (sba_rdata),
        .s_axi_rresp (sba_rresp),
        .s_axi_rvalid (sba_rvalid),
        .s_axi_rready (sba_rready),

        .m_axi_ram_awid (dbg_awid),
        .m_axi_ram_awaddr (dbg_awaddr),
        .m_axi_ram_awlen (dbg_awlen),
        .m_axi_ram_awsize (dbg_awsize),
        .m_axi_ram_awburst (dbg_awburst),
        .m_axi_ram_awvalid (dbg_awvalid),
        .m_axi_ram_awready (dbg_awready),
        .m_axi_ram_wdata (dbg_wdata),
        .m_axi_ram_wstrb (dbg_wstrb),
        .m_axi_ram_wlast (dbg_wlast),
        .m_axi_ram_wvalid (dbg_wvalid),
        .m_axi_ram_wready (dbg_wready),
        .m_axi_ram_bid (dbg_bid),
        .m_axi_ram_bresp (dbg_bresp),
        .m_axi_ram_bvalid (dbg_bvalid),
        .m_axi_ram_bready (dbg_bready),
        .m_axi_ram_arid (dbg_arid),
        .m_axi_ram_araddr (dbg_araddr),
        .m_axi_ram_arlen (dbg_arlen),
        .m_axi_ram_arsize (dbg_arsize),
        .m_axi_ram_arburst (dbg_arburst),
        .m_axi_ram_arvalid (dbg_arvalid),
        .m_axi_ram_arready (dbg_arready),
        .m_axi_ram_rid (dbg_rid),
        .m_axi_ram_rdata (dbg_rdata),
        .m_axi_ram_rresp (dbg_rresp),
        .m_axi_ram_rlast (dbg_rlast),
        .m_axi_ram_rvalid (dbg_rvalid),
        .m_axi_ram_rready (dbg_rready),

        .m_axi_dbg_awaddr (m_axi_dbg_awaddr),
        .m_axi_dbg_awprot (m_axi_dbg_awprot),
        .m_axi_dbg_awvalid (m_axi_dbg_awvalid),
        .m_axi_dbg_awready (m_axi_dbg_awready),
        .m_axi_dbg_wdata (m_axi_dbg_wdata),
        .m_axi_dbg_wstrb (m_axi_dbg_wstrb),
        .m_axi_dbg_wvalid (m_axi_dbg_wvalid),
        .m_axi_dbg_wready (m_axi_dbg_wready),
        .m_axi_dbg_bresp (m_axi_dbg_bresp),
        .m_axi_dbg_bvalid (m_axi_dbg_bvalid),
        .m_axi_dbg_bready (m_axi_dbg_bready),
        .m_axi_dbg_araddr (m_axi_dbg_araddr),
        .m_axi_dbg_arprot (m_axi_dbg_arprot),
        .m_axi_dbg_arvalid (m_axi_dbg_arvalid),
        .m_axi_dbg_arready (m_axi_dbg_arready),
        .m_axi_dbg_rdata (m_axi_dbg_rdata),
        .m_axi_dbg_rresp (m_axi_dbg_rresp),
        .m_axi_dbg_rvalid (m_axi_dbg_rvalid),
        .m_axi_dbg_rready (m_axi_dbg_rready)
    );

    //Two masters on the one RAM port. S0 is the debugger, coming out of
    //cva5_sba_split above; S1 is for something outside this module -- the PS
    //programming the core, or a DMA feeding an accelerator.
    //
    //S1 is tied off here, and is the only part of this not yet wired out.
    //Exposing it means an AXI4 slave on cva5_wrapper and cva5_top and a port
    //on the packaged IP, which a block design has to connect to something:
    //there is no master to connect yet, and what Vivado does with an
    //unconnected AXI slave interface on an IP is not something to find out by
    //guessing. The mux, its arbitration and its reset behaviour are verified
    //in simulation now (test_benches/debug/run_ram_mux.sh, 315 checks);
    //routing S1 out is a change to these tie-offs and nothing else.
    //
    //ram_rstn, not rst: the owner register must not reset on ndmreset, for
    //the same reason cva5_sba_split's select register must not. See the header
    //of cva5_ram_mux.sv.
    assign ext_awid    = '0;
    assign ext_awaddr  = '0;
    assign ext_awlen   = '0;
    assign ext_awsize  = 3'd2;
    assign ext_awburst = 2'b01;
    assign ext_awvalid = 1'b0;
    assign ext_wdata   = '0;
    assign ext_wstrb   = '0;
    assign ext_wlast   = 1'b0;
    assign ext_wvalid  = 1'b0;
    assign ext_bready  = 1'b0;
    assign ext_arid    = '0;
    assign ext_araddr  = '0;
    assign ext_arlen   = '0;
    assign ext_arsize  = 3'd2;
    assign ext_arburst = 2'b01;
    assign ext_arvalid = 1'b0;
    assign ext_rready  = 1'b0;

    cva5_ram_mux #(
        .ADDR_WIDTH (RAM_ADDR_W),
        .ID_WIDTH (8)
    ) ram_mux (
        .clk (clk),
        .rstn (ram_rstn),

        .s0_awid (dbg_awid),
        .s0_awaddr (dbg_awaddr),
        .s0_awlen (dbg_awlen),
        .s0_awsize (dbg_awsize),
        .s0_awburst (dbg_awburst),
        .s0_awvalid (dbg_awvalid),
        .s0_awready (dbg_awready),
        .s0_wdata (dbg_wdata),
        .s0_wstrb (dbg_wstrb),
        .s0_wlast (dbg_wlast),
        .s0_wvalid (dbg_wvalid),
        .s0_wready (dbg_wready),
        .s0_bid (dbg_bid),
        .s0_bresp (dbg_bresp),
        .s0_bvalid (dbg_bvalid),
        .s0_bready (dbg_bready),
        .s0_arid (dbg_arid),
        .s0_araddr (dbg_araddr),
        .s0_arlen (dbg_arlen),
        .s0_arsize (dbg_arsize),
        .s0_arburst (dbg_arburst),
        .s0_arvalid (dbg_arvalid),
        .s0_arready (dbg_arready),
        .s0_rid (dbg_rid),
        .s0_rdata (dbg_rdata),
        .s0_rresp (dbg_rresp),
        .s0_rlast (dbg_rlast),
        .s0_rvalid (dbg_rvalid),
        .s0_rready (dbg_rready),

        .s1_awid (ext_awid),
        .s1_awaddr (ext_awaddr),
        .s1_awlen (ext_awlen),
        .s1_awsize (ext_awsize),
        .s1_awburst (ext_awburst),
        .s1_awvalid (ext_awvalid),
        .s1_awready (ext_awready),
        .s1_wdata (ext_wdata),
        .s1_wstrb (ext_wstrb),
        .s1_wlast (ext_wlast),
        .s1_wvalid (ext_wvalid),
        .s1_wready (ext_wready),
        .s1_bid (ext_bid),
        .s1_bresp (ext_bresp),
        .s1_bvalid (ext_bvalid),
        .s1_bready (ext_bready),
        .s1_arid (ext_arid),
        .s1_araddr (ext_araddr),
        .s1_arlen (ext_arlen),
        .s1_arsize (ext_arsize),
        .s1_arburst (ext_arburst),
        .s1_arvalid (ext_arvalid),
        .s1_arready (ext_arready),
        .s1_rid (ext_rid),
        .s1_rdata (ext_rdata),
        .s1_rresp (ext_rresp),
        .s1_rlast (ext_rlast),
        .s1_rvalid (ext_rvalid),
        .s1_rready (ext_rready),

        .m_awid (rp_awid),
        .m_awaddr (rp_awaddr),
        .m_awlen (rp_awlen),
        .m_awsize (rp_awsize),
        .m_awburst (rp_awburst),
        .m_awvalid (rp_awvalid),
        .m_awready (rp_awready),
        .m_wdata (rp_wdata),
        .m_wstrb (rp_wstrb),
        .m_wlast (rp_wlast),
        .m_wvalid (rp_wvalid),
        .m_wready (rp_wready),
        .m_bid (rp_bid),
        .m_bresp (rp_bresp),
        .m_bvalid (rp_bvalid),
        .m_bready (rp_bready),
        .m_arid (rp_arid),
        .m_araddr (rp_araddr),
        .m_arlen (rp_arlen),
        .m_arsize (rp_arsize),
        .m_arburst (rp_arburst),
        .m_arvalid (rp_arvalid),
        .m_arready (rp_arready),
        .m_rid (rp_rid),
        .m_rdata (rp_rdata),
        .m_rresp (rp_rresp),
        .m_rlast (rp_rlast),
        .m_rvalid (rp_rvalid),
        .m_rready (rp_rready)
    );

    cva5_ram_port #(.ADDR_WIDTH(RAM_ADDR_W)) ram_port (
        .clk (clk),
        .rstn (ram_rstn),
        .core_en (data_bram.en),
        .core_be (data_bram.be),
        .core_addr (data_bram.addr[RAM_ADDR_W-1:0]),
        .core_wdata (data_bram.data_in),
        .core_rdata (data_bram.data_out),
        .ram_en (ram_b_en),
        .ram_wbe (ram_b_wbe),
        .ram_addr (ram_b_addr),
        .ram_wdata (ram_b_wdata),
        .ram_rdata (ram_b_rdata),
        .s_axi_awid (rp_awid),
        .s_axi_awaddr (rp_awaddr),
        .s_axi_awlen (rp_awlen),
        .s_axi_awsize (rp_awsize),
        .s_axi_awburst (rp_awburst),
        .s_axi_awvalid (rp_awvalid),
        .s_axi_awready (rp_awready),
        .s_axi_wdata (rp_wdata),
        .s_axi_wstrb (rp_wstrb),
        .s_axi_wlast (rp_wlast),
        .s_axi_wvalid (rp_wvalid),
        .s_axi_wready (rp_wready),
        .s_axi_bid (rp_bid),
        .s_axi_bresp (rp_bresp),
        .s_axi_bvalid (rp_bvalid),
        .s_axi_bready (rp_bready),
        .s_axi_arid (rp_arid),
        .s_axi_araddr (rp_araddr),
        .s_axi_arlen (rp_arlen),
        .s_axi_arsize (rp_arsize),
        .s_axi_arburst (rp_arburst),
        .s_axi_arvalid (rp_arvalid),
        .s_axi_arready (rp_arready),
        .s_axi_rid (rp_rid),
        .s_axi_rdata (rp_rdata),
        .s_axi_rresp (rp_rresp),
        .s_axi_rlast (rp_rlast),
        .s_axi_rvalid (rp_rvalid),
        .s_axi_rready (rp_rready)
    );

    tdp_ram #(
        .ADDR_WIDTH(RAM_ADDR_W),
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
        .a_addr(instruction_bram.addr[RAM_ADDR_W-1:0]),
        .a_rdata(instruction_bram.data_out),
        .b_en(ram_b_en),
        .b_wbe(ram_b_wbe),
        .b_wdata(ram_b_wdata),
        .b_addr(ram_b_addr),
        .b_rdata(ram_b_rdata),
    .*);

endmodule
