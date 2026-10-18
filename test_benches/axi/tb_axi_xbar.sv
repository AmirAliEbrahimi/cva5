/*
 * tb_axi_xbar -- self-checking test for cva5_axi_xbar.
 *
 * Checks the things the crossbar is responsible for and nothing else:
 *
 *   - each master reaches the slaves it is meant to, with data intact
 *   - the address decode matches examples/sw/soc.h
 *   - an unmapped address returns DECERR rather than landing somewhere
 *   - a master reaching for a slave it is not connected to returns DECERR
 *   - the master-port address truncation drops only the constant window bits
 *   - transaction IDs survive the round trip through the mux
 *   - two masters can be in flight at once
 *
 * The master ports are configured as the block design wires them: 17 address
 * bits to the BRAM controller (128 KB) and 4 to the peripheral.
 *
 * Run with test_benches/axi/run_xbar.sh
 *
 * SPDX-License-Identifier: Apache-2.0
 */

module tb_axi_xbar #(
    // Master-port address widths, overridable with Verilator's -G so the run
    // script can cover both the deployed configuration (32, the full address
    // passed through for the slave to truncate) and a narrowed port.
    parameter int unsigned RAM_AW    = 32'd32,
    parameter int unsigned UART_AW = 32'd12,
    parameter int unsigned CLINT_AW = 32'd16
);

    localparam int unsigned ID_WIDTH     = 32'd6;
    localparam int unsigned MST_ID_WIDTH = ID_WIDTH + 2;

    // Mirrors cva5_axi_xbar's defaults, which follow CVA6's map.
    localparam logic [31:0] RAM_BASE    = 32'h8000_0000;
    localparam logic [31:0] PERIPH_BASE = 32'h1000_0000;
    localparam logic [31:0] CLINT_BASE  = 32'h0200_0000;
    // An address in neither window, to prove the decode returns DECERR rather
    // than landing somewhere. Not the Debug Module's window, which sits at
    // 0x0000_0000 now and never reaches this crossbar in any case -- the DM
    // hangs off the core inside cva5_top.
    localparam logic [31:0] UNMAPPED    = 32'h5000_0000;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_DECERR = 2'b11;

    logic clk = 0;
    logic rstn = 0;
    always #5 clk = ~clk;

    int unsigned errors = 0;
    int unsigned checks = 0;

    task automatic step();
        @(posedge clk);
        #1;
    endtask

    task automatic expect_eq(string what, logic [63:0] got, logic [63:0] exp);
        checks++;
        if (got !== exp) begin
            $display("FAIL %s: got %h, expected %h", what, got, exp);
            errors++;
        end
    endtask

    //==================================================================
    // Slave port 0: CPU peripheral bus (AXI4-Lite)
    //==================================================================
    logic [31:0] cpu_awaddr, cpu_wdata, cpu_araddr, cpu_rdata;
    logic [2:0]  cpu_awprot = 0, cpu_arprot = 0;
    logic [3:0]  cpu_wstrb;
    logic        cpu_awvalid, cpu_awready, cpu_wvalid, cpu_wready;
    logic        cpu_bvalid, cpu_bready, cpu_arvalid, cpu_arready;
    logic        cpu_rvalid, cpu_rready;
    logic [1:0]  cpu_bresp, cpu_rresp;

    //==================================================================
    // Slave port 1: CPU cached memory (AXI4)
    //==================================================================
    logic                mem_arready, mem_arvalid;
    logic [31:0]         mem_araddr;
    logic [7:0]          mem_arlen;
    logic [2:0]          mem_arsize, mem_arprot = 0;
    logic [1:0]          mem_arburst;
    logic [3:0]          mem_arcache, mem_arqos = 0;
    logic                mem_arlock = 0;
    logic [ID_WIDTH-1:0] mem_arid;
    logic                mem_rready, mem_rvalid, mem_rlast;
    logic [31:0]         mem_rdata;
    logic [1:0]          mem_rresp;
    logic [ID_WIDTH-1:0] mem_rid;
    logic                mem_awready, mem_awvalid;
    logic [31:0]         mem_awaddr;
    logic [7:0]          mem_awlen;
    logic [2:0]          mem_awsize, mem_awprot = 0;
    logic [1:0]          mem_awburst;
    logic [3:0]          mem_awcache, mem_awqos = 0;
    logic                mem_awlock = 0;
    logic [ID_WIDTH-1:0] mem_awid;
    logic                mem_wready, mem_wvalid, mem_wlast;
    logic [31:0]         mem_wdata;
    logic [3:0]          mem_wstrb;
    logic                mem_bready, mem_bvalid;
    logic [1:0]          mem_bresp;
    logic [ID_WIDTH-1:0] mem_bid;

    //==================================================================
    // Slave port 2: debugger (AXI4-Lite)
    //==================================================================
    logic [31:0] dbg_awaddr, dbg_wdata, dbg_araddr, dbg_rdata;
    logic [2:0]  dbg_awprot = 0, dbg_arprot = 0;
    logic [3:0]  dbg_wstrb;
    logic        dbg_awvalid, dbg_awready, dbg_wvalid, dbg_wready;
    logic        dbg_bvalid, dbg_bready, dbg_arvalid, dbg_arready;
    logic        dbg_rvalid, dbg_rready;
    logic [1:0]  dbg_bresp, dbg_rresp;

    //==================================================================
    // Master port 0: RAM (AXI4) / Master port 1: peripheral (AXI4-Lite)
    //==================================================================
    logic                    ram_arready, ram_arvalid;
    logic [RAM_AW-1:0]       ram_araddr;
    logic [7:0]              ram_arlen;
    logic [2:0]              ram_arsize, ram_arprot;
    logic [1:0]              ram_arburst;
    logic [3:0]              ram_arcache, ram_arqos;
    logic                    ram_arlock;
    logic [MST_ID_WIDTH-1:0] ram_arid;
    logic                    ram_rready, ram_rvalid, ram_rlast;
    logic [31:0]             ram_rdata;
    logic [1:0]              ram_rresp;
    logic [MST_ID_WIDTH-1:0] ram_rid;
    logic                    ram_awready, ram_awvalid;
    logic [RAM_AW-1:0]       ram_awaddr;
    logic [7:0]              ram_awlen;
    logic [2:0]              ram_awsize, ram_awprot;
    logic [1:0]              ram_awburst;
    logic [3:0]              ram_awcache, ram_awqos;
    logic                    ram_awlock;
    logic [MST_ID_WIDTH-1:0] ram_awid;
    logic                    ram_wready, ram_wvalid, ram_wlast;
    logic [31:0]             ram_wdata;
    logic [3:0]              ram_wstrb;
    logic                    ram_bready, ram_bvalid;
    logic [1:0]              ram_bresp;
    logic [MST_ID_WIDTH-1:0] ram_bid;

    logic [UART_AW-1:0] uart_awaddr, uart_araddr;
    logic [2:0]           uart_awprot, uart_arprot;
    logic                 uart_awvalid, uart_awready, uart_wvalid, uart_wready;
    logic [31:0]          uart_wdata, uart_rdata;
    logic [3:0]           uart_wstrb;
    logic                 uart_bvalid, uart_bready, uart_arvalid, uart_arready;
    logic                 uart_rvalid, uart_rready;
    logic [1:0]           uart_bresp, uart_rresp;

    logic [CLINT_AW-1:0] clint_awaddr, clint_araddr;
    logic [2:0]          clint_awprot, clint_arprot;
    logic                clint_awvalid, clint_awready, clint_wvalid, clint_wready;
    logic [31:0]         clint_wdata, clint_rdata;
    logic [3:0]          clint_wstrb;
    logic                clint_bvalid, clint_bready, clint_arvalid, clint_arready;
    logic                clint_rvalid, clint_rready;
    logic [1:0]          clint_bresp, clint_rresp;

    cva5_axi_xbar #(
        .RAM_BASE            (RAM_BASE),
        .RAM_SIZE            (32'h0002_0000),
        .PERIPH_BASE         (PERIPH_BASE),
        .PERIPH_SIZE         (32'h0001_0000),
        .M_RAM_ADDR_WIDTH    (RAM_AW),
        .M_UART_ADDR_WIDTH   (UART_AW),
        .M_CLINT_ADDR_WIDTH  (CLINT_AW),
        .CLINT_BASE          (CLINT_BASE),
        .CLINT_SIZE          (32'h0001_0000),
        .ID_WIDTH            (ID_WIDTH)
    ) dut (
        .clk(clk), .rstn(rstn),

        .s_axi_cpu_awaddr(cpu_awaddr), .s_axi_cpu_awprot(cpu_awprot),
        .s_axi_cpu_awvalid(cpu_awvalid), .s_axi_cpu_awready(cpu_awready),
        .s_axi_cpu_wdata(cpu_wdata), .s_axi_cpu_wstrb(cpu_wstrb),
        .s_axi_cpu_wvalid(cpu_wvalid), .s_axi_cpu_wready(cpu_wready),
        .s_axi_cpu_bresp(cpu_bresp), .s_axi_cpu_bvalid(cpu_bvalid),
        .s_axi_cpu_bready(cpu_bready),
        .s_axi_cpu_araddr(cpu_araddr), .s_axi_cpu_arprot(cpu_arprot),
        .s_axi_cpu_arvalid(cpu_arvalid), .s_axi_cpu_arready(cpu_arready),
        .s_axi_cpu_rdata(cpu_rdata), .s_axi_cpu_rresp(cpu_rresp),
        .s_axi_cpu_rvalid(cpu_rvalid), .s_axi_cpu_rready(cpu_rready),

        .s_axi_mem_arready(mem_arready), .s_axi_mem_arvalid(mem_arvalid),
        .s_axi_mem_araddr(mem_araddr), .s_axi_mem_arlen(mem_arlen),
        .s_axi_mem_arsize(mem_arsize), .s_axi_mem_arburst(mem_arburst),
        .s_axi_mem_arcache(mem_arcache), .s_axi_mem_arprot(mem_arprot),
        .s_axi_mem_arlock(mem_arlock), .s_axi_mem_arqos(mem_arqos),
        .s_axi_mem_arid(mem_arid),
        .s_axi_mem_rready(mem_rready), .s_axi_mem_rvalid(mem_rvalid),
        .s_axi_mem_rdata(mem_rdata), .s_axi_mem_rresp(mem_rresp),
        .s_axi_mem_rlast(mem_rlast), .s_axi_mem_rid(mem_rid),
        .s_axi_mem_awready(mem_awready), .s_axi_mem_awvalid(mem_awvalid),
        .s_axi_mem_awaddr(mem_awaddr), .s_axi_mem_awlen(mem_awlen),
        .s_axi_mem_awsize(mem_awsize), .s_axi_mem_awburst(mem_awburst),
        .s_axi_mem_awcache(mem_awcache), .s_axi_mem_awprot(mem_awprot),
        .s_axi_mem_awlock(mem_awlock), .s_axi_mem_awqos(mem_awqos),
        .s_axi_mem_awid(mem_awid),
        .s_axi_mem_wready(mem_wready), .s_axi_mem_wvalid(mem_wvalid),
        .s_axi_mem_wdata(mem_wdata), .s_axi_mem_wstrb(mem_wstrb),
        .s_axi_mem_wlast(mem_wlast),
        .s_axi_mem_bready(mem_bready), .s_axi_mem_bvalid(mem_bvalid),
        .s_axi_mem_bresp(mem_bresp), .s_axi_mem_bid(mem_bid),

        .s_axi_dbg_awaddr(dbg_awaddr), .s_axi_dbg_awprot(dbg_awprot),
        .s_axi_dbg_awvalid(dbg_awvalid), .s_axi_dbg_awready(dbg_awready),
        .s_axi_dbg_wdata(dbg_wdata), .s_axi_dbg_wstrb(dbg_wstrb),
        .s_axi_dbg_wvalid(dbg_wvalid), .s_axi_dbg_wready(dbg_wready),
        .s_axi_dbg_bresp(dbg_bresp), .s_axi_dbg_bvalid(dbg_bvalid),
        .s_axi_dbg_bready(dbg_bready),
        .s_axi_dbg_araddr(dbg_araddr), .s_axi_dbg_arprot(dbg_arprot),
        .s_axi_dbg_arvalid(dbg_arvalid), .s_axi_dbg_arready(dbg_arready),
        .s_axi_dbg_rdata(dbg_rdata), .s_axi_dbg_rresp(dbg_rresp),
        .s_axi_dbg_rvalid(dbg_rvalid), .s_axi_dbg_rready(dbg_rready),

        .m_axi_ram_arready(ram_arready), .m_axi_ram_arvalid(ram_arvalid),
        .m_axi_ram_araddr(ram_araddr), .m_axi_ram_arlen(ram_arlen),
        .m_axi_ram_arsize(ram_arsize), .m_axi_ram_arburst(ram_arburst),
        .m_axi_ram_arcache(ram_arcache), .m_axi_ram_arprot(ram_arprot),
        .m_axi_ram_arlock(ram_arlock), .m_axi_ram_arqos(ram_arqos),
        .m_axi_ram_arid(ram_arid),
        .m_axi_ram_rready(ram_rready), .m_axi_ram_rvalid(ram_rvalid),
        .m_axi_ram_rdata(ram_rdata), .m_axi_ram_rresp(ram_rresp),
        .m_axi_ram_rlast(ram_rlast), .m_axi_ram_rid(ram_rid),
        .m_axi_ram_awready(ram_awready), .m_axi_ram_awvalid(ram_awvalid),
        .m_axi_ram_awaddr(ram_awaddr), .m_axi_ram_awlen(ram_awlen),
        .m_axi_ram_awsize(ram_awsize), .m_axi_ram_awburst(ram_awburst),
        .m_axi_ram_awcache(ram_awcache), .m_axi_ram_awprot(ram_awprot),
        .m_axi_ram_awlock(ram_awlock), .m_axi_ram_awqos(ram_awqos),
        .m_axi_ram_awid(ram_awid),
        .m_axi_ram_wready(ram_wready), .m_axi_ram_wvalid(ram_wvalid),
        .m_axi_ram_wdata(ram_wdata), .m_axi_ram_wstrb(ram_wstrb),
        .m_axi_ram_wlast(ram_wlast),
        .m_axi_ram_bready(ram_bready), .m_axi_ram_bvalid(ram_bvalid),
        .m_axi_ram_bresp(ram_bresp), .m_axi_ram_bid(ram_bid),

        .m_axi_uart_awaddr(uart_awaddr), .m_axi_uart_awprot(uart_awprot),
        .m_axi_uart_awvalid(uart_awvalid), .m_axi_uart_awready(uart_awready),
        .m_axi_uart_wdata(uart_wdata), .m_axi_uart_wstrb(uart_wstrb),
        .m_axi_uart_wvalid(uart_wvalid), .m_axi_uart_wready(uart_wready),
        .m_axi_uart_bresp(uart_bresp), .m_axi_uart_bvalid(uart_bvalid),
        .m_axi_uart_bready(uart_bready),
        .m_axi_uart_araddr(uart_araddr), .m_axi_uart_arprot(uart_arprot),
        .m_axi_uart_arvalid(uart_arvalid), .m_axi_uart_arready(uart_arready),
        .m_axi_uart_rdata(uart_rdata), .m_axi_uart_rresp(uart_rresp),
        .m_axi_uart_rvalid(uart_rvalid), .m_axi_uart_rready(uart_rready),

        .m_axi_clint_awaddr(clint_awaddr), .m_axi_clint_awprot(clint_awprot),
        .m_axi_clint_awvalid(clint_awvalid), .m_axi_clint_awready(clint_awready),
        .m_axi_clint_wdata(clint_wdata), .m_axi_clint_wstrb(clint_wstrb),
        .m_axi_clint_wvalid(clint_wvalid), .m_axi_clint_wready(clint_wready),
        .m_axi_clint_bresp(clint_bresp), .m_axi_clint_bvalid(clint_bvalid),
        .m_axi_clint_bready(clint_bready),
        .m_axi_clint_araddr(clint_araddr), .m_axi_clint_arprot(clint_arprot),
        .m_axi_clint_arvalid(clint_arvalid), .m_axi_clint_arready(clint_arready),
        .m_axi_clint_rdata(clint_rdata), .m_axi_clint_rresp(clint_rresp),
        .m_axi_clint_rvalid(clint_rvalid), .m_axi_clint_rready(clint_rready)
    );

    //==================================================================
    // Main RAM on master port 0 -- the real IP, not a model, so these
    // checks cover the crossbar and the memory together.
    //
    // The address is truncated to the RAM's own width here exactly as the
    // block design truncates it at the interface net.
    //==================================================================
    localparam int unsigned RAM_SIZE_BYTES = 32'd131072;   // 128 KB
    localparam int unsigned RAM_SLV_AW     = 32'd17;

    cva5_axi_ram #(
        .SIZE_BYTES (RAM_SIZE_BYTES),
        .ID_WIDTH   (MST_ID_WIDTH),
        .ADDR_WIDTH (RAM_SLV_AW)
    ) ram_inst (
        .clk(clk), .rstn(rstn),
        .s_axi_awid(ram_awid), .s_axi_awaddr(ram_awaddr[RAM_SLV_AW-1:0]),
        .s_axi_awlen(ram_awlen), .s_axi_awsize(ram_awsize),
        .s_axi_awburst(ram_awburst), .s_axi_awlock(ram_awlock),
        .s_axi_awcache(ram_awcache), .s_axi_awprot(ram_awprot),
        .s_axi_awqos(ram_awqos), .s_axi_awvalid(ram_awvalid),
        .s_axi_awready(ram_awready),
        .s_axi_wdata(ram_wdata), .s_axi_wstrb(ram_wstrb),
        .s_axi_wlast(ram_wlast), .s_axi_wvalid(ram_wvalid),
        .s_axi_wready(ram_wready),
        .s_axi_bid(ram_bid), .s_axi_bresp(ram_bresp),
        .s_axi_bvalid(ram_bvalid), .s_axi_bready(ram_bready),
        .s_axi_arid(ram_arid), .s_axi_araddr(ram_araddr[RAM_SLV_AW-1:0]),
        .s_axi_arlen(ram_arlen), .s_axi_arsize(ram_arsize),
        .s_axi_arburst(ram_arburst), .s_axi_arlock(ram_arlock),
        .s_axi_arcache(ram_arcache), .s_axi_arprot(ram_arprot),
        .s_axi_arqos(ram_arqos), .s_axi_arvalid(ram_arvalid),
        .s_axi_arready(ram_arready),
        .s_axi_rid(ram_rid), .s_axi_rdata(ram_rdata), .s_axi_rresp(ram_rresp),
        .s_axi_rlast(ram_rlast), .s_axi_rvalid(ram_rvalid),
        .s_axi_rready(ram_rready)
    );

    //==================================================================
    // UART model behind the Lite fan-out (AXI4-Lite, 4 registers)
    //==================================================================
    logic [31:0] uart_regs [4];
    logic [UART_AW-1:0] uw_addr;
    logic                 uw_have_addr = 0, uw_have_data = 0;
    logic [31:0]          uw_data;

    assign uart_awready = !uw_have_addr;
    assign uart_wready  = !uw_have_data;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            uw_have_addr <= 0;
            uw_have_data <= 0;
            uart_bvalid   <= 0;
        end else begin
            if (uart_awvalid && uart_awready) begin
                uw_addr      <= uart_awaddr;
                uw_have_addr <= 1;
            end
            if (uart_wvalid && uart_wready) begin
                uw_data      <= uart_wdata;
                uw_have_data <= 1;
            end
            if (uw_have_addr && uw_have_data && !uart_bvalid) begin
                uart_regs[uw_addr[3:2]] <= uw_data;
                uw_have_addr <= 0;
                uw_have_data <= 0;
                uart_bvalid   <= 1;
                uart_bresp    <= RESP_OKAY;
            end
            if (uart_bvalid && uart_bready)
                uart_bvalid <= 0;
        end
    end

    assign uart_arready = !uart_rvalid;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            uart_rvalid <= 0;
        end else begin
            if (uart_arvalid && uart_arready) begin
                uart_rvalid <= 1;
                uart_rdata  <= uart_regs[uart_araddr[3:2]];
                uart_rresp  <= RESP_OKAY;
            end else if (uart_rvalid && uart_rready) begin
                uart_rvalid <= 0;
            end
        end
    end


    //==================================================================
    // CLINT model behind the Lite fan-out (AXI4-Lite, 4 registers)
    //==================================================================
    logic [31:0] clint_regs [4];
    logic [CLINT_AW-1:0] cw_addr;
    logic                cw_have_addr = 0, cw_have_data = 0;
    logic [31:0]         cw_data;

    assign clint_awready = !cw_have_addr;
    assign clint_wready  = !cw_have_data;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            cw_have_addr <= 0;
            cw_have_data <= 0;
            clint_bvalid <= 0;
        end else begin
            if (clint_awvalid && clint_awready) begin
                cw_addr      <= clint_awaddr;
                cw_have_addr <= 1;
            end
            if (clint_wvalid && clint_wready) begin
                cw_data      <= clint_wdata;
                cw_have_data <= 1;
            end
            if (cw_have_addr && cw_have_data && !clint_bvalid) begin
                clint_regs[cw_addr[3:2]] <= cw_data;
                cw_have_addr <= 0;
                cw_have_data <= 0;
                clint_bvalid <= 1;
                clint_bresp  <= RESP_OKAY;
            end
            if (clint_bvalid && clint_bready)
                clint_bvalid <= 0;
        end
    end

    assign clint_arready = !clint_rvalid;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            clint_rvalid <= 0;
        end else begin
            if (clint_arvalid && clint_arready) begin
                clint_rvalid <= 1;
                clint_rdata  <= clint_regs[clint_araddr[3:2]];
                clint_rresp  <= RESP_OKAY;
            end else if (clint_rvalid && clint_rready) begin
                clint_rvalid <= 0;
            end
        end
    end

    logic [CLINT_AW-1:0] seen_clint_awaddr, seen_clint_araddr;
    always_ff @(posedge clk) begin
        if (clint_awvalid && clint_awready) seen_clint_awaddr <= clint_awaddr;
        if (clint_arvalid && clint_arready) seen_clint_araddr <= clint_araddr;
    end

    // What the master ports last saw, so the address truncation can be checked.
    logic [RAM_AW-1:0]    seen_ram_awaddr, seen_ram_araddr;
    logic [UART_AW-1:0] seen_uart_awaddr, seen_uart_araddr;
    always_ff @(posedge clk) begin
        if (ram_awvalid && ram_awready) seen_ram_awaddr <= ram_awaddr;
        if (ram_arvalid && ram_arready) seen_ram_araddr <= ram_araddr;
        if (uart_awvalid && uart_awready) seen_uart_awaddr <= uart_awaddr;
        if (uart_arvalid && uart_arready) seen_uart_araddr <= uart_araddr;
    end

    //==================================================================
    // AXI4-Lite master tasks, parameterised by which port to drive
    //==================================================================
    typedef enum {PORT_CPU, PORT_DBG} lite_port_e;

    task automatic lite_write(input lite_port_e port, input logic [31:0] addr,
                              input logic [31:0] data, output logic [1:0] resp,
                              input logic [3:0] strb = 4'hF);
        fork
            begin
                if (port == PORT_CPU) begin
                    cpu_awaddr = addr; cpu_awvalid = 1;
                    while (!cpu_awready) step();
                    step();
                    cpu_awvalid = 0;
                end else begin
                    dbg_awaddr = addr; dbg_awvalid = 1;
                    while (!dbg_awready) step();
                    step();
                    dbg_awvalid = 0;
                end
            end
            begin
                if (port == PORT_CPU) begin
                    cpu_wdata = data; cpu_wstrb = strb; cpu_wvalid = 1;
                    while (!cpu_wready) step();
                    step();
                    cpu_wvalid = 0;
                end else begin
                    dbg_wdata = data; dbg_wstrb = strb; dbg_wvalid = 1;
                    while (!dbg_wready) step();
                    step();
                    dbg_wvalid = 0;
                end
            end
            begin
                if (port == PORT_CPU) begin
                    cpu_bready = 1;
                    while (!cpu_bvalid) step();
                    resp = cpu_bresp;
                    step();
                    cpu_bready = 0;
                end else begin
                    dbg_bready = 1;
                    while (!dbg_bvalid) step();
                    resp = dbg_bresp;
                    step();
                    dbg_bready = 0;
                end
            end
        join
    endtask

    task automatic lite_read(input lite_port_e port, input logic [31:0] addr,
                             output logic [31:0] data, output logic [1:0] resp);
        fork
            begin
                if (port == PORT_CPU) begin
                    cpu_araddr = addr; cpu_arvalid = 1;
                    while (!cpu_arready) step();
                    step();
                    cpu_arvalid = 0;
                end else begin
                    dbg_araddr = addr; dbg_arvalid = 1;
                    while (!dbg_arready) step();
                    step();
                    dbg_arvalid = 0;
                end
            end
            begin
                if (port == PORT_CPU) begin
                    cpu_rready = 1;
                    while (!cpu_rvalid) step();
                    data = cpu_rdata; resp = cpu_rresp;
                    step();
                    cpu_rready = 0;
                end else begin
                    dbg_rready = 1;
                    while (!dbg_rvalid) step();
                    data = dbg_rdata; resp = dbg_rresp;
                    step();
                    dbg_rready = 0;
                end
            end
        join
    endtask

    //==================================================================
    // AXI4 master tasks on the cached port
    //==================================================================
    task automatic mem_write(input logic [31:0] addr, input logic [7:0] len,
                             input logic [ID_WIDTH-1:0] id, input logic [31:0] seed,
                             output logic [1:0] resp);
        fork
            begin
                mem_awaddr = addr; mem_awlen = len; mem_awsize = 3'd2;
                mem_awburst = 2'b01; mem_awcache = 4'b0011; mem_awid = id;
                mem_awvalid = 1;
                while (!mem_awready) step();
                step();
                mem_awvalid = 0;
            end
            begin
                for (int unsigned i = 0; i <= len; i++) begin
                    mem_wdata = seed + i; mem_wstrb = 4'hF;
                    mem_wlast = (i == len); mem_wvalid = 1;
                    while (!mem_wready) step();
                    step();
                    mem_wvalid = 0;
                end
                mem_wlast = 0;
            end
            begin
                mem_bready = 1;
                while (!mem_bvalid) step();
                resp = mem_bresp;
                expect_eq("cached write response id", mem_bid, id);
                step();
                mem_bready = 0;
            end
        join
    endtask

    task automatic mem_read_check(input logic [31:0] addr, input logic [7:0] len,
                                  input logic [ID_WIDTH-1:0] id, input logic [31:0] seed,
                                  output logic [1:0] resp);
        fork
            begin
                mem_araddr = addr; mem_arlen = len; mem_arsize = 3'd2;
                mem_arburst = 2'b01; mem_arcache = 4'b0011; mem_arid = id;
                mem_arvalid = 1;
                while (!mem_arready) step();
                step();
                mem_arvalid = 0;
            end
            begin
                resp = RESP_OKAY;
                for (int unsigned i = 0; i <= len; i++) begin
                    mem_rready = 1;
                    while (!mem_rvalid) step();
                    if (mem_rresp != RESP_OKAY) resp = mem_rresp;
                    else expect_eq($sformatf("cached read beat %0d", i), mem_rdata, seed + i);
                    expect_eq($sformatf("cached read id beat %0d", i), mem_rid, id);
                    expect_eq($sformatf("cached read last beat %0d", i), mem_rlast, (i == len));
                    step();
                    mem_rready = 0;
                end
            end
        join
    endtask

    //==================================================================
    initial begin
        logic [31:0] rdata;
        logic [1:0]  resp;

        cpu_awvalid = 0; cpu_wvalid = 0; cpu_bready = 0;
        cpu_arvalid = 0; cpu_rready = 0;
        cpu_awaddr = 0; cpu_wdata = 0; cpu_wstrb = 0; cpu_araddr = 0;
        dbg_awvalid = 0; dbg_wvalid = 0; dbg_bready = 0;
        dbg_arvalid = 0; dbg_rready = 0;
        dbg_awaddr = 0; dbg_wdata = 0; dbg_wstrb = 0; dbg_araddr = 0;
        mem_awvalid = 0; mem_wvalid = 0; mem_bready = 0;
        mem_arvalid = 0; mem_rready = 0; mem_wlast = 0;
        mem_awaddr = 0; mem_awlen = 0; mem_awsize = 0; mem_awburst = 0;
        mem_awcache = 0; mem_awid = 0; mem_wdata = 0; mem_wstrb = 0;
        mem_araddr = 0; mem_arlen = 0; mem_arsize = 0; mem_arburst = 0;
        mem_arcache = 0; mem_arid = 0;

        for (int unsigned i = 0; i < 4; i++) uart_regs[i] = 32'h0;
        for (int unsigned i = 0; i < 4; i++) clint_regs[i] = 32'h0;

        repeat (4) step();
        rstn = 1;
        repeat (4) step();

        //--------------------------------------------------------------
        // The debugger reaches both slaves
        //--------------------------------------------------------------
        lite_write(PORT_DBG, RAM_BASE + 32'h100, 32'hA5A5_1234, resp);
        expect_eq("dbg write to RAM resp", resp, RESP_OKAY);
        expect_eq("RAM port address", seen_ram_awaddr,
                  (RAM_BASE + 32'h100) & ((32'd1 << RAM_AW) - 1));

        lite_read(PORT_DBG, RAM_BASE + 32'h100, rdata, resp);
        expect_eq("dbg read from RAM resp", resp, RESP_OKAY);
        expect_eq("dbg read from RAM data", rdata, 32'hA5A5_1234);

        lite_write(PORT_DBG, PERIPH_BASE + 32'h4, 32'hCAFE_0001, resp);
        expect_eq("dbg write to peripheral resp", resp, RESP_OKAY);
        expect_eq("dbg write landed in the UART", uart_regs[1], 32'hCAFE_0001);
        expect_eq("peripheral port address", seen_uart_awaddr,
                  (PERIPH_BASE + 32'h4) & ((32'd1 << UART_AW) - 1));

        lite_read(PORT_DBG, PERIPH_BASE + 32'h4, rdata, resp);
        expect_eq("dbg read from peripheral resp", resp, RESP_OKAY);
        expect_eq("dbg read from peripheral data", rdata, 32'hCAFE_0001);

        //--------------------------------------------------------------
        // The CPU's peripheral bus reaches the peripheral
        //--------------------------------------------------------------
        lite_write(PORT_CPU, PERIPH_BASE + 32'h8, 32'h1357_9BDF, resp);
        expect_eq("cpu write to peripheral resp", resp, RESP_OKAY);
        expect_eq("cpu write landed in the UART", uart_regs[2], 32'h1357_9BDF);

        //--------------------------------------------------------------
        // The AXI4-Lite fan-out: both peripherals are behind one AXI4
        // master port and one axi2axilite, so the decode that separates
        // them is the Lite crossbar's, not the main crossbar's.
        //--------------------------------------------------------------
        $display("-- the Lite peripheral fan-out");

        lite_write(PORT_CPU, CLINT_BASE + 32'h4, 32'h0BAD_C0DE, resp);
        expect_eq("cpu write to the CLINT resp", resp, RESP_OKAY);
        expect_eq("cpu write landed in the CLINT", clint_regs[1], 32'h0BAD_C0DE);
        expect_eq("...and not in the UART", uart_regs[1], 32'hCAFE_0001);

        lite_read(PORT_CPU, CLINT_BASE + 32'h4, rdata, resp);
        expect_eq("cpu read from the CLINT resp", resp, RESP_OKAY);
        expect_eq("cpu read from the CLINT", rdata, 32'h0BAD_C0DE);

        //The debugger reaches it too, which is the point of moving the CLINT
        //out of the wrapper's peripheral split and onto the bus.
        lite_write(PORT_DBG, CLINT_BASE + 32'h8, 32'h5EED_5EED, resp);
        expect_eq("dbg write to the CLINT resp", resp, RESP_OKAY);
        expect_eq("dbg write landed in the CLINT", clint_regs[2], 32'h5EED_5EED);
        lite_read(PORT_DBG, CLINT_BASE + 32'h8, rdata, resp);
        expect_eq("dbg read from the CLINT", rdata, 32'h5EED_5EED);

        //Each port sees only its own window's low bits.
        expect_eq("CLINT saw its offset, truncated",
                  32'(seen_clint_awaddr),
                  (CLINT_BASE + 32'h8) & ((32'd1 << CLINT_AW) - 1));

        //An address inside the main crossbar's peripheral rule but claimed by
        //no Lite rule is the Lite crossbar's error slave, not a hang.
        lite_write(PORT_CPU, 32'h3000_0000, 32'hDEAD_0001, resp);
        expect_eq("write to an unclaimed peripheral address DECERRs",
                  resp, RESP_DECERR);
        lite_read(PORT_CPU, 32'h3000_0000, rdata, resp);
        expect_eq("read from an unclaimed peripheral address DECERRs",
                  resp, RESP_DECERR);
        expect_eq("the UART is untouched by it", uart_regs[0], 32'h0);
        expect_eq("the CLINT is untouched by it", clint_regs[0], 32'h0);

        lite_read(PORT_CPU, PERIPH_BASE + 32'h8, rdata, resp);
        expect_eq("cpu read from peripheral resp", resp, RESP_OKAY);
        expect_eq("cpu read from peripheral data", rdata, 32'h1357_9BDF);

        //--------------------------------------------------------------
        // Byte enables. CVA5 issues sub-word stores (sb, sh), so a write
        // with a partial strobe must leave the other bytes alone.
        //--------------------------------------------------------------
        lite_write(PORT_DBG, RAM_BASE + 32'h80, 32'hAABB_CCDD, resp);
        expect_eq("byte-enable seed resp", resp, RESP_OKAY);

        lite_write(PORT_DBG, RAM_BASE + 32'h80, 32'h1122_3344, resp, 4'b0010);
        expect_eq("single byte write resp", resp, RESP_OKAY);
        lite_read(PORT_DBG, RAM_BASE + 32'h80, rdata, resp);
        expect_eq("only byte 1 changed", rdata, 32'hAABB_33DD);

        lite_write(PORT_DBG, RAM_BASE + 32'h80, 32'h5566_7788, resp, 4'b1000);
        lite_read(PORT_DBG, RAM_BASE + 32'h80, rdata, resp);
        expect_eq("only byte 3 changed", rdata, 32'h55BB_33DD);

        lite_write(PORT_DBG, RAM_BASE + 32'h80, 32'h99AA_BBCC, resp, 4'b0101);
        lite_read(PORT_DBG, RAM_BASE + 32'h80, rdata, resp);
        expect_eq("two non-adjacent bytes changed", rdata, 32'h55AA_33CC);

        lite_write(PORT_DBG, RAM_BASE + 32'h80, 32'hDEAD_BEEF, resp, 4'b0000);
        lite_read(PORT_DBG, RAM_BASE + 32'h80, rdata, resp);
        expect_eq("an empty strobe writes nothing", rdata, 32'h55AA_33CC);

        //--------------------------------------------------------------
        // The cached port reaches RAM, with bursts and IDs
        //--------------------------------------------------------------
        mem_write(RAM_BASE + 32'h200, 8'd3, 6'h15, 32'h2222_0000, resp);
        expect_eq("cached burst write resp", resp, RESP_OKAY);
        mem_read_check(RAM_BASE + 32'h200, 8'd3, 6'h15, 32'h2222_0000, resp);
        expect_eq("cached burst read resp", resp, RESP_OKAY);
        expect_eq("RAM port address (read)", seen_ram_araddr,
                  (RAM_BASE + 32'h200) & ((32'd1 << RAM_AW) - 1));

        mem_write(RAM_BASE + 32'h1000, 8'd15, 6'h3F, 32'h3333_0000, resp);
        expect_eq("cached long write resp", resp, RESP_OKAY);
        mem_read_check(RAM_BASE + 32'h1000, 8'd15, 6'h3F, 32'h3333_0000, resp);
        expect_eq("cached long read resp", resp, RESP_OKAY);

        // A different ID must come back as itself, not as the previous one.
        mem_write(RAM_BASE + 32'h300, 8'd0, 6'h01, 32'h4444_0000, resp);
        mem_read_check(RAM_BASE + 32'h300, 8'd0, 6'h2A, 32'h4444_0000, resp);
        expect_eq("distinct id round trip resp", resp, RESP_OKAY);

        //--------------------------------------------------------------
        // Unmapped addresses are refused, not misrouted
        //--------------------------------------------------------------
        lite_write(PORT_DBG, UNMAPPED, 32'hDEAD_DEAD, resp);
        expect_eq("write to unmapped address is DECERR", resp, RESP_DECERR);
        lite_read(PORT_DBG, UNMAPPED, rdata, resp);
        expect_eq("read from unmapped address is DECERR", resp, RESP_DECERR);

        // Just past the end of RAM.
        lite_write(PORT_DBG, RAM_BASE + 32'h0002_0000, 32'hDEAD_DEAD, resp);
        expect_eq("write just past RAM is DECERR", resp, RESP_DECERR);
        // ...and the last word inside it is still fine.
        lite_write(PORT_DBG, RAM_BASE + 32'h0001_FFFC, 32'hFEED_FACE, resp);
        expect_eq("write to the last RAM word is OKAY", resp, RESP_OKAY);

        //--------------------------------------------------------------
        // Connectivity: each CPU port is restricted to one slave
        //--------------------------------------------------------------
        // Seed through the debugger first, so the refused write is shown to
        // have left a known value alone.
        lite_write(PORT_DBG, RAM_BASE, 32'h600D_600D, resp);
        expect_eq("seed write resp", resp, RESP_OKAY);
        lite_write(PORT_CPU, RAM_BASE, 32'hBAAD_BAAD, resp);
        expect_eq("cpu peripheral bus cannot reach RAM", resp, RESP_DECERR);
        lite_read(PORT_DBG, RAM_BASE, rdata, resp);
        expect_eq("...and nothing was written", rdata, 32'h600D_600D);

        lite_read(PORT_CPU, RAM_BASE, rdata, resp);
        expect_eq("cpu peripheral bus cannot read RAM", resp, RESP_DECERR);

        mem_write(PERIPH_BASE, 8'd0, 6'h07, 32'hBAAD_BAAD, resp);
        expect_eq("cached port cannot reach the peripheral", resp, RESP_DECERR);
        expect_eq("...and the UART is untouched", uart_regs[0], 32'h0);

        //--------------------------------------------------------------
        // Two masters in flight at once
        //--------------------------------------------------------------
        fork
            begin
                logic [1:0] r;
                mem_write(RAM_BASE + 32'h400, 8'd7, 6'h11, 32'h5555_0000, r);
                expect_eq("concurrent cached write resp", r, RESP_OKAY);
            end
            begin
                logic [1:0] r;
                lite_write(PORT_CPU, PERIPH_BASE + 32'hC, 32'h9999_8888, r);
                expect_eq("concurrent peripheral write resp", r, RESP_OKAY);
            end
        join
        expect_eq("concurrent UART write landed", uart_regs[3], 32'h9999_8888);
        mem_read_check(RAM_BASE + 32'h400, 8'd7, 6'h11, 32'h5555_0000, resp);
        expect_eq("concurrent cached read back resp", resp, RESP_OKAY);

        repeat (10) step();

        if (errors == 0)
            $display("PASS tb_axi_xbar: %0d checks (RAM_AW=%0d UART_AW=%0d CLINT_AW=%0d)",
                     checks, RAM_AW, UART_AW, CLINT_AW);
        else
            $display("FAIL tb_axi_xbar: %0d of %0d checks failed", errors, checks);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL tb_axi_xbar: timeout");
        $finish;
    end

endmodule
