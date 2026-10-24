/*
 * tb_axi_xbar -- cva5_axi_xbar, now an AXI4-Lite crossbar end to end.
 *
 * Two masters (the CPU's peripheral bus and the debugger's system bus) and two
 * slaves (the UART and the CLINT). What this has to get right is the decode,
 * that each master reaches each slave, that the two do not interfere, that an
 * unclaimed address DECERRs rather than hanging, and that each master port
 * presents its slave only the address bits that port carries.
 *
 * The bursting AXI4 path this file used to test is gone with the RAM master
 * port -- main memory is answered inside cva5_top now, so nothing on this bus
 * issues a burst.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
module tb_axi_xbar #(
    parameter int unsigned UART_AW  = 32'd12,
    parameter int unsigned CLINT_AW = 32'd16,
    parameter int unsigned PLIC_AW  = 32'd26,
    parameter int unsigned SPI_AW   = 32'd12,
    parameter int unsigned I2C_AW   = 32'd12
);

    localparam logic [31:0] PERIPH_BASE = 32'h1000_0000;
    localparam logic [31:0] CLINT_BASE  = 32'h0200_0000;
    localparam logic [31:0] PLIC_BASE   = 32'h0C00_0000;
    localparam logic [31:0] SPI_BASE    = 32'h2000_0000;
    localparam logic [31:0] I2C_BASE    = 32'h2800_0000;
    localparam logic [1:0]  RESP_OKAY   = 2'b00;
    localparam logic [1:0]  RESP_DECERR = 2'b11;

    logic clk = 0;
    logic rstn = 0;
    always #5 clk = ~clk;

    int unsigned checks = 0;
    int unsigned errors = 0;

    task automatic expect_eq(input string what, input logic [31:0] got,
                             input logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            $error("%s: got 0x%08x expected 0x%08x", what, got, exp);
            errors++;
        end
    endtask

    task automatic step();
        @(negedge clk);
    endtask

    //==================================================================
    // DUT
    //==================================================================
    logic [31:0] cpu_awaddr, cpu_wdata, cpu_araddr, cpu_rdata;
    logic [3:0]  cpu_wstrb;
    logic        cpu_awvalid, cpu_awready, cpu_wvalid, cpu_wready;
    logic        cpu_bvalid, cpu_bready, cpu_arvalid, cpu_arready;
    logic        cpu_rvalid, cpu_rready;
    logic [1:0]  cpu_bresp, cpu_rresp;

    logic [31:0] dbg_awaddr, dbg_wdata, dbg_araddr, dbg_rdata;
    logic [3:0]  dbg_wstrb;
    logic        dbg_awvalid, dbg_awready, dbg_wvalid, dbg_wready;
    logic        dbg_bvalid, dbg_bready, dbg_arvalid, dbg_arready;
    logic        dbg_rvalid, dbg_rready;
    logic [1:0]  dbg_bresp, dbg_rresp;

    logic [UART_AW-1:0] uart_awaddr, uart_araddr;
    logic [2:0]  uart_awprot, uart_arprot;
    logic        uart_awvalid, uart_awready, uart_wvalid, uart_wready;
    logic [31:0] uart_wdata, uart_rdata;
    logic [3:0]  uart_wstrb;
    logic        uart_bvalid, uart_bready, uart_arvalid, uart_arready;
    logic        uart_rvalid, uart_rready;
    logic [1:0]  uart_bresp, uart_rresp;

    logic [CLINT_AW-1:0] clint_awaddr, clint_araddr;
    logic [2:0]  clint_awprot, clint_arprot;
    logic        clint_awvalid, clint_awready, clint_wvalid, clint_wready;
    logic [31:0] clint_wdata, clint_rdata;
    logic [3:0]  clint_wstrb;
    logic        clint_bvalid, clint_bready, clint_arvalid, clint_arready;
    logic        clint_rvalid, clint_rready;
    logic [1:0]  clint_bresp, clint_rresp;

    logic [PLIC_AW-1:0] plic_awaddr, plic_araddr;
    logic [2:0]  plic_awprot, plic_arprot;
    logic        plic_awvalid, plic_awready, plic_wvalid, plic_wready;
    logic [31:0] plic_wdata, plic_rdata;
    logic [3:0]  plic_wstrb;
    logic        plic_bvalid, plic_bready, plic_arvalid, plic_arready;
    logic        plic_rvalid, plic_rready;
    logic [1:0]  plic_bresp, plic_rresp;

    logic [SPI_AW-1:0] spi_awaddr, spi_araddr;
    logic [2:0]  spi_awprot, spi_arprot;
    logic        spi_awvalid, spi_awready, spi_wvalid, spi_wready;
    logic [31:0] spi_wdata, spi_rdata;
    logic [3:0]  spi_wstrb;
    logic        spi_bvalid, spi_bready, spi_arvalid, spi_arready;
    logic        spi_rvalid, spi_rready;
    logic [1:0]  spi_bresp, spi_rresp;

    logic [I2C_AW-1:0] i2c_awaddr, i2c_araddr;
    logic [2:0]  i2c_awprot, i2c_arprot;
    logic        i2c_awvalid, i2c_awready, i2c_wvalid, i2c_wready;
    logic [31:0] i2c_wdata, i2c_rdata;
    logic [3:0]  i2c_wstrb;
    logic        i2c_bvalid, i2c_bready, i2c_arvalid, i2c_arready;
    logic        i2c_rvalid, i2c_rready;
    logic [1:0]  i2c_bresp, i2c_rresp;

    cva5_axi_xbar #(
        .PERIPH_BASE         (PERIPH_BASE),
        .PERIPH_SIZE         (32'h0001_0000),
        .CLINT_BASE          (CLINT_BASE),
        .CLINT_SIZE          (32'h0001_0000),
        .M_UART_ADDR_WIDTH   (UART_AW),
        .M_CLINT_ADDR_WIDTH  (CLINT_AW),
        .PLIC_BASE           (PLIC_BASE),
        .PLIC_SIZE           (32'h0400_0000),
        .M_PLIC_ADDR_WIDTH   (PLIC_AW),
        .SPI_BASE            (SPI_BASE),
        .SPI_SIZE            (32'h0080_0000),
        .M_SPI_ADDR_WIDTH    (SPI_AW),
        .I2C_BASE            (I2C_BASE),
        .I2C_SIZE            (32'h0000_1000),
        .M_I2C_ADDR_WIDTH    (I2C_AW)
    ) dut (
        .clk(clk), .rstn(rstn),

        .s_axi_cpu_awaddr(cpu_awaddr), .s_axi_cpu_awprot(3'b000),
        .s_axi_cpu_awvalid(cpu_awvalid), .s_axi_cpu_awready(cpu_awready),
        .s_axi_cpu_wdata(cpu_wdata), .s_axi_cpu_wstrb(cpu_wstrb),
        .s_axi_cpu_wvalid(cpu_wvalid), .s_axi_cpu_wready(cpu_wready),
        .s_axi_cpu_bresp(cpu_bresp), .s_axi_cpu_bvalid(cpu_bvalid),
        .s_axi_cpu_bready(cpu_bready),
        .s_axi_cpu_araddr(cpu_araddr), .s_axi_cpu_arprot(3'b000),
        .s_axi_cpu_arvalid(cpu_arvalid), .s_axi_cpu_arready(cpu_arready),
        .s_axi_cpu_rdata(cpu_rdata), .s_axi_cpu_rresp(cpu_rresp),
        .s_axi_cpu_rvalid(cpu_rvalid), .s_axi_cpu_rready(cpu_rready),

        .s_axi_dbg_awaddr(dbg_awaddr), .s_axi_dbg_awprot(3'b000),
        .s_axi_dbg_awvalid(dbg_awvalid), .s_axi_dbg_awready(dbg_awready),
        .s_axi_dbg_wdata(dbg_wdata), .s_axi_dbg_wstrb(dbg_wstrb),
        .s_axi_dbg_wvalid(dbg_wvalid), .s_axi_dbg_wready(dbg_wready),
        .s_axi_dbg_bresp(dbg_bresp), .s_axi_dbg_bvalid(dbg_bvalid),
        .s_axi_dbg_bready(dbg_bready),
        .s_axi_dbg_araddr(dbg_araddr), .s_axi_dbg_arprot(3'b000),
        .s_axi_dbg_arvalid(dbg_arvalid), .s_axi_dbg_arready(dbg_arready),
        .s_axi_dbg_rdata(dbg_rdata), .s_axi_dbg_rresp(dbg_rresp),
        .s_axi_dbg_rvalid(dbg_rvalid), .s_axi_dbg_rready(dbg_rready),

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
        .m_axi_clint_rvalid(clint_rvalid), .m_axi_clint_rready(clint_rready),

        .m_axi_plic_awaddr(plic_awaddr), .m_axi_plic_awprot(plic_awprot),
        .m_axi_plic_awvalid(plic_awvalid), .m_axi_plic_awready(plic_awready),
        .m_axi_plic_wdata(plic_wdata), .m_axi_plic_wstrb(plic_wstrb),
        .m_axi_plic_wvalid(plic_wvalid), .m_axi_plic_wready(plic_wready),
        .m_axi_plic_bresp(plic_bresp), .m_axi_plic_bvalid(plic_bvalid),
        .m_axi_plic_bready(plic_bready),
        .m_axi_plic_araddr(plic_araddr), .m_axi_plic_arprot(plic_arprot),
        .m_axi_plic_arvalid(plic_arvalid), .m_axi_plic_arready(plic_arready),
        .m_axi_plic_rdata(plic_rdata), .m_axi_plic_rresp(plic_rresp),
        .m_axi_plic_rvalid(plic_rvalid), .m_axi_plic_rready(plic_rready),

        .m_axi_spi_awaddr(spi_awaddr), .m_axi_spi_awprot(spi_awprot),
        .m_axi_spi_awvalid(spi_awvalid), .m_axi_spi_awready(spi_awready),
        .m_axi_spi_wdata(spi_wdata), .m_axi_spi_wstrb(spi_wstrb),
        .m_axi_spi_wvalid(spi_wvalid), .m_axi_spi_wready(spi_wready),
        .m_axi_spi_bresp(spi_bresp), .m_axi_spi_bvalid(spi_bvalid),
        .m_axi_spi_bready(spi_bready),
        .m_axi_spi_araddr(spi_araddr), .m_axi_spi_arprot(spi_arprot),
        .m_axi_spi_arvalid(spi_arvalid), .m_axi_spi_arready(spi_arready),
        .m_axi_spi_rdata(spi_rdata), .m_axi_spi_rresp(spi_rresp),
        .m_axi_spi_rvalid(spi_rvalid), .m_axi_spi_rready(spi_rready),

        .m_axi_i2c_awaddr(i2c_awaddr), .m_axi_i2c_awprot(i2c_awprot),
        .m_axi_i2c_awvalid(i2c_awvalid), .m_axi_i2c_awready(i2c_awready),
        .m_axi_i2c_wdata(i2c_wdata), .m_axi_i2c_wstrb(i2c_wstrb),
        .m_axi_i2c_wvalid(i2c_wvalid), .m_axi_i2c_wready(i2c_wready),
        .m_axi_i2c_bresp(i2c_bresp), .m_axi_i2c_bvalid(i2c_bvalid),
        .m_axi_i2c_bready(i2c_bready),
        .m_axi_i2c_araddr(i2c_araddr), .m_axi_i2c_arprot(i2c_arprot),
        .m_axi_i2c_arvalid(i2c_arvalid), .m_axi_i2c_arready(i2c_arready),
        .m_axi_i2c_rdata(i2c_rdata), .m_axi_i2c_rresp(i2c_rresp),
        .m_axi_i2c_rvalid(i2c_rvalid), .m_axi_i2c_rready(i2c_rready)
    );

    //==================================================================
    // Two identical four-register AXI4-Lite slaves
    //==================================================================
    logic [31:0] uart_regs [4];
    logic [UART_AW-1:0] uw_addr;
    logic uw_have_addr = 0, uw_have_data = 0;
    logic [31:0] uw_data;

    assign uart_awready = !uw_have_addr;
    assign uart_wready  = !uw_have_data;
    assign uart_arready = !uart_rvalid;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            uw_have_addr <= 0; uw_have_data <= 0; uart_bvalid <= 0;
        end else begin
            if (uart_awvalid && uart_awready) begin
                uw_addr <= uart_awaddr; uw_have_addr <= 1;
            end
            if (uart_wvalid && uart_wready) begin
                uw_data <= uart_wdata; uw_have_data <= 1;
            end
            if (uw_have_addr && uw_have_data && !uart_bvalid) begin
                uart_regs[uw_addr[3:2]] <= uw_data;
                uw_have_addr <= 0; uw_have_data <= 0;
                uart_bvalid <= 1; uart_bresp <= RESP_OKAY;
            end
            if (uart_bvalid && uart_bready) uart_bvalid <= 0;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) uart_rvalid <= 0;
        else begin
            if (uart_arvalid && uart_arready) begin
                uart_rvalid <= 1;
                uart_rdata  <= uart_regs[uart_araddr[3:2]];
                uart_rresp  <= RESP_OKAY;
            end else if (uart_rvalid && uart_rready) uart_rvalid <= 0;
        end
    end

    logic [31:0] clint_regs [4];
    logic [CLINT_AW-1:0] cw_addr;
    logic cw_have_addr = 0, cw_have_data = 0;
    logic [31:0] cw_data;

    assign clint_awready = !cw_have_addr;
    assign clint_wready  = !cw_have_data;
    assign clint_arready = !clint_rvalid;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            cw_have_addr <= 0; cw_have_data <= 0; clint_bvalid <= 0;
        end else begin
            if (clint_awvalid && clint_awready) begin
                cw_addr <= clint_awaddr; cw_have_addr <= 1;
            end
            if (clint_wvalid && clint_wready) begin
                cw_data <= clint_wdata; cw_have_data <= 1;
            end
            if (cw_have_addr && cw_have_data && !clint_bvalid) begin
                clint_regs[cw_addr[3:2]] <= cw_data;
                cw_have_addr <= 0; cw_have_data <= 0;
                clint_bvalid <= 1; clint_bresp <= RESP_OKAY;
            end
            if (clint_bvalid && clint_bready) clint_bvalid <= 0;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) clint_rvalid <= 0;
        else begin
            if (clint_arvalid && clint_arready) begin
                clint_rvalid <= 1;
                clint_rdata  <= clint_regs[clint_araddr[3:2]];
                clint_rresp  <= RESP_OKAY;
            end else if (clint_rvalid && clint_rready) clint_rvalid <= 0;
        end
    end

    logic [31:0] plic_regs [4];
    logic [PLIC_AW-1:0] pw_addr;
    logic pw_have_addr = 0, pw_have_data = 0;
    logic [31:0] pw_data;

    assign plic_awready = !pw_have_addr;
    assign plic_wready  = !pw_have_data;
    assign plic_arready = !plic_rvalid;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            pw_have_addr <= 0; pw_have_data <= 0; plic_bvalid <= 0;
        end else begin
            if (plic_awvalid && plic_awready) begin
                pw_addr <= plic_awaddr; pw_have_addr <= 1;
            end
            if (plic_wvalid && plic_wready) begin
                pw_data <= plic_wdata; pw_have_data <= 1;
            end
            if (pw_have_addr && pw_have_data && !plic_bvalid) begin
                plic_regs[pw_addr[3:2]] <= pw_data;
                pw_have_addr <= 0; pw_have_data <= 0;
                plic_bvalid <= 1; plic_bresp <= RESP_OKAY;
            end
            if (plic_bvalid && plic_bready) plic_bvalid <= 0;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) plic_rvalid <= 0;
        else begin
            if (plic_arvalid && plic_arready) begin
                plic_rvalid <= 1;
                plic_rdata  <= plic_regs[plic_araddr[3:2]];
                plic_rresp  <= RESP_OKAY;
            end else if (plic_rvalid && plic_rready) plic_rvalid <= 0;
        end
    end

    logic [31:0] spi_regs [4];
    logic [SPI_AW-1:0] sw_addr;
    logic sw_have_addr = 0, sw_have_data = 0;
    logic [31:0] sw_data;

    assign spi_awready = !sw_have_addr;
    assign spi_wready  = !sw_have_data;
    assign spi_arready = !spi_rvalid;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            sw_have_addr <= 0; sw_have_data <= 0; spi_bvalid <= 0;
        end else begin
            if (spi_awvalid && spi_awready) begin
                sw_addr <= spi_awaddr; sw_have_addr <= 1;
            end
            if (spi_wvalid && spi_wready) begin
                sw_data <= spi_wdata; sw_have_data <= 1;
            end
            if (sw_have_addr && sw_have_data && !spi_bvalid) begin
                spi_regs[sw_addr[3:2]] <= sw_data;
                sw_have_addr <= 0; sw_have_data <= 0;
                spi_bvalid <= 1; spi_bresp <= RESP_OKAY;
            end
            if (spi_bvalid && spi_bready) spi_bvalid <= 0;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) spi_rvalid <= 0;
        else begin
            if (spi_arvalid && spi_arready) begin
                spi_rvalid <= 1;
                spi_rdata  <= spi_regs[spi_araddr[3:2]];
                spi_rresp  <= RESP_OKAY;
            end else if (spi_rvalid && spi_rready) spi_rvalid <= 0;
        end
    end

    logic [31:0] i2c_regs [4];
    logic [I2C_AW-1:0] iw_addr;
    logic iw_have_addr = 0, iw_have_data = 0;
    logic [31:0] iw_data;

    assign i2c_awready = !iw_have_addr;
    assign i2c_wready  = !iw_have_data;
    assign i2c_arready = !i2c_rvalid;

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            iw_have_addr <= 0; iw_have_data <= 0; i2c_bvalid <= 0;
        end else begin
            if (i2c_awvalid && i2c_awready) begin
                iw_addr <= i2c_awaddr; iw_have_addr <= 1;
            end
            if (i2c_wvalid && i2c_wready) begin
                iw_data <= i2c_wdata; iw_have_data <= 1;
            end
            if (iw_have_addr && iw_have_data && !i2c_bvalid) begin
                i2c_regs[iw_addr[3:2]] <= iw_data;
                iw_have_addr <= 0; iw_have_data <= 0;
                i2c_bvalid <= 1; i2c_bresp <= RESP_OKAY;
            end
            if (i2c_bvalid && i2c_bready) i2c_bvalid <= 0;
        end
    end

    always_ff @(posedge clk or negedge rstn) begin
        if (!rstn) i2c_rvalid <= 0;
        else begin
            if (i2c_arvalid && i2c_arready) begin
                i2c_rvalid <= 1;
                i2c_rdata  <= i2c_regs[i2c_araddr[3:2]];
                i2c_rresp  <= RESP_OKAY;
            end else if (i2c_rvalid && i2c_rready) i2c_rvalid <= 0;
        end
    end

    // What each master port last presented, latched at the handshake rather
    // than sampled afterwards: once the transaction has completed the port's
    // address and strobes are whatever the crossbar happens to leave driven.
    logic [UART_AW-1:0]  seen_uart_awaddr, seen_uart_araddr;
    logic [CLINT_AW-1:0] seen_clint_awaddr, seen_clint_araddr;
    logic [PLIC_AW-1:0]  seen_plic_araddr;
    logic [SPI_AW-1:0]   seen_spi_araddr;
    logic [I2C_AW-1:0]   seen_i2c_araddr;
    logic [3:0]          seen_uart_wstrb;
    always_ff @(posedge clk) begin
        if (uart_awvalid && uart_awready)   seen_uart_awaddr  <= uart_awaddr;
        if (uart_arvalid && uart_arready)   seen_uart_araddr  <= uart_araddr;
        if (uart_wvalid  && uart_wready)    seen_uart_wstrb   <= uart_wstrb;
        if (clint_awvalid && clint_awready) seen_clint_awaddr <= clint_awaddr;
        if (clint_arvalid && clint_arready) seen_clint_araddr <= clint_araddr;
        if (plic_arvalid  && plic_arready)  seen_plic_araddr  <= plic_araddr;
        if (spi_arvalid   && spi_arready)   seen_spi_araddr   <= spi_araddr;
        if (i2c_arvalid   && i2c_arready)   seen_i2c_araddr   <= i2c_araddr;
    end

    //==================================================================
    // Masters
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
                    step(); cpu_awvalid = 0;
                end else begin
                    dbg_awaddr = addr; dbg_awvalid = 1;
                    while (!dbg_awready) step();
                    step(); dbg_awvalid = 0;
                end
            end
            begin
                if (port == PORT_CPU) begin
                    cpu_wdata = data; cpu_wstrb = strb; cpu_wvalid = 1;
                    while (!cpu_wready) step();
                    step(); cpu_wvalid = 0;
                end else begin
                    dbg_wdata = data; dbg_wstrb = strb; dbg_wvalid = 1;
                    while (!dbg_wready) step();
                    step(); dbg_wvalid = 0;
                end
            end
        join
        if (port == PORT_CPU) begin
            cpu_bready = 1;
            while (!cpu_bvalid) step();
            resp = cpu_bresp; step(); cpu_bready = 0;
        end else begin
            dbg_bready = 1;
            while (!dbg_bvalid) step();
            resp = dbg_bresp; step(); dbg_bready = 0;
        end
    endtask

    task automatic lite_read(input lite_port_e port, input logic [31:0] addr,
                             output logic [31:0] data, output logic [1:0] resp);
        if (port == PORT_CPU) begin
            cpu_araddr = addr; cpu_arvalid = 1;
            while (!cpu_arready) step();
            step(); cpu_arvalid = 0;
            cpu_rready = 1;
            while (!cpu_rvalid) step();
            data = cpu_rdata; resp = cpu_rresp; step(); cpu_rready = 0;
        end else begin
            dbg_araddr = addr; dbg_arvalid = 1;
            while (!dbg_arready) step();
            step(); dbg_arvalid = 0;
            dbg_rready = 1;
            while (!dbg_rvalid) step();
            data = dbg_rdata; resp = dbg_rresp; step(); dbg_rready = 0;
        end
    endtask

    //==================================================================
    logic [31:0] rdata;
    logic [1:0]  resp;

    initial begin
        cpu_awvalid = 0; cpu_wvalid = 0; cpu_bready = 0;
        cpu_arvalid = 0; cpu_rready = 0; cpu_wstrb = 4'hF;
        cpu_awaddr = 0; cpu_araddr = 0; cpu_wdata = 0;
        dbg_awvalid = 0; dbg_wvalid = 0; dbg_bready = 0;
        dbg_arvalid = 0; dbg_rready = 0; dbg_wstrb = 4'hF;
        dbg_awaddr = 0; dbg_araddr = 0; dbg_wdata = 0;
        for (int unsigned i = 0; i < 4; i++) begin
            uart_regs[i] = 32'h0;
            clint_regs[i] = 32'h0;
            plic_regs[i] = 32'h0;
            spi_regs[i] = 32'h0;
            i2c_regs[i] = 32'h0;
        end

        repeat (4) step();
        rstn = 1;
        repeat (4) step();

        //--- the CPU reaches both slaves
        $display("-- CPU port");
        lite_write(PORT_CPU, PERIPH_BASE + 32'h4, 32'h1357_9BDF, resp);
        expect_eq("cpu write to the UART resp", 32'(resp), 32'(RESP_OKAY));
        expect_eq("cpu write landed in the UART", uart_regs[1], 32'h1357_9BDF);
        lite_read(PORT_CPU, PERIPH_BASE + 32'h4, rdata, resp);
        expect_eq("cpu read from the UART resp", 32'(resp), 32'(RESP_OKAY));
        expect_eq("cpu read from the UART", rdata, 32'h1357_9BDF);

        lite_write(PORT_CPU, CLINT_BASE + 32'h8, 32'h0BAD_C0DE, resp);
        expect_eq("cpu write to the CLINT resp", 32'(resp), 32'(RESP_OKAY));
        expect_eq("cpu write landed in the CLINT", clint_regs[2], 32'h0BAD_C0DE);
        expect_eq("...and not in the UART", uart_regs[2], 32'h0);
        lite_read(PORT_CPU, CLINT_BASE + 32'h8, rdata, resp);
        expect_eq("cpu read from the CLINT", rdata, 32'h0BAD_C0DE);

        lite_write(PORT_CPU, PLIC_BASE + 32'h4, 32'h0F1C_0001, resp);
        expect_eq("cpu write to the PLIC resp", 32'(resp), 32'(RESP_OKAY));
        expect_eq("cpu write landed in the PLIC", plic_regs[1], 32'h0F1C_0001);
        expect_eq("...and not in the UART", uart_regs[1], 32'h1357_9BDF);
        expect_eq("...and not in the CLINT", clint_regs[1], 32'h0);
        lite_read(PORT_CPU, PLIC_BASE + 32'h4, rdata, resp);
        expect_eq("cpu read from the PLIC", rdata, 32'h0F1C_0001);

        lite_write(PORT_CPU, SPI_BASE + 32'h8, 32'h5010_0001, resp);
        expect_eq("cpu write to the SPI resp", 32'(resp), 32'(RESP_OKAY));
        expect_eq("cpu write landed in the SPI", spi_regs[2], 32'h5010_0001);
        expect_eq("...and not in the PLIC", plic_regs[2], 32'h0);
        lite_read(PORT_CPU, SPI_BASE + 32'h8, rdata, resp);
        expect_eq("cpu read from the SPI", rdata, 32'h5010_0001);

        lite_write(PORT_CPU, I2C_BASE + 32'h4, 32'h12C0_0001, resp);
        expect_eq("cpu write to the I2C resp", 32'(resp), 32'(RESP_OKAY));
        expect_eq("cpu write landed in the I2C", i2c_regs[1], 32'h12C0_0001);
        expect_eq("...and not in the SPI", spi_regs[1], 32'h0);
        lite_read(PORT_CPU, I2C_BASE + 32'h4, rdata, resp);
        expect_eq("cpu read from the I2C", rdata, 32'h12C0_0001);

        //--- the debugger reaches both slaves
        $display("-- debugger port");
        lite_write(PORT_DBG, PERIPH_BASE + 32'hC, 32'hCAFE_0001, resp);
        expect_eq("dbg write to the UART resp", 32'(resp), 32'(RESP_OKAY));
        expect_eq("dbg write landed in the UART", uart_regs[3], 32'hCAFE_0001);
        lite_read(PORT_DBG, PERIPH_BASE + 32'hC, rdata, resp);
        expect_eq("dbg read from the UART", rdata, 32'hCAFE_0001);

        lite_write(PORT_DBG, CLINT_BASE + 32'h0, 32'h5EED_5EED, resp);
        expect_eq("dbg write to the CLINT resp", 32'(resp), 32'(RESP_OKAY));
        expect_eq("dbg write landed in the CLINT", clint_regs[0], 32'h5EED_5EED);
        lite_read(PORT_DBG, CLINT_BASE + 32'h0, rdata, resp);
        expect_eq("dbg read from the CLINT", rdata, 32'h5EED_5EED);

        lite_write(PORT_DBG, PLIC_BASE + 32'h200004, 32'h0000_0003, resp);
        expect_eq("dbg write to the PLIC's claim/complete resp",
                  32'(resp), 32'(RESP_OKAY));
        expect_eq("...landed in the PLIC", plic_regs[1], 32'h0000_0003);
        lite_read(PORT_DBG, PLIC_BASE + 32'h200004, rdata, resp);
        expect_eq("dbg read from the PLIC's claim/complete",
                  rdata, 32'h0000_0003);

        lite_write(PORT_DBG, I2C_BASE + 32'hC, 32'h0000_00FA, resp);
        expect_eq("dbg write to the I2C's prescale resp",
                  32'(resp), 32'(RESP_OKAY));
        expect_eq("...landed in the I2C", i2c_regs[3], 32'h0000_00FA);
        lite_read(PORT_DBG, I2C_BASE + 32'hC, rdata, resp);
        expect_eq("dbg read from the I2C's prescale", rdata, 32'h0000_00FA);

        //--- each master port sees only the bits it carries
        $display("-- address truncation");
        expect_eq("UART saw its offset, truncated",
                  32'(seen_uart_araddr),
                  (PERIPH_BASE + 32'hC) & ((32'd1 << UART_AW) - 1));
        expect_eq("CLINT saw its offset, truncated",
                  32'(seen_clint_araddr),
                  (CLINT_BASE + 32'h0) & ((32'd1 << CLINT_AW) - 1));
        expect_eq("SPI saw its offset, truncated",
                  32'(seen_spi_araddr),
                  (SPI_BASE + 32'h8) & ((32'd1 << SPI_AW) - 1));
        expect_eq("PLIC saw its offset, truncated",
                  32'(seen_plic_araddr),
                  (PLIC_BASE + 32'h200004) & ((32'd1 << PLIC_AW) - 1));
        expect_eq("I2C saw its offset, truncated",
                  32'(seen_i2c_araddr),
                  (I2C_BASE + 32'hC) & ((32'd1 << I2C_AW) - 1));

        //--- an address no rule claims
        $display("-- unclaimed addresses");
        lite_write(PORT_CPU, 32'h3000_0000, 32'hDEAD_0001, resp);
        expect_eq("cpu write to an unclaimed address DECERRs",
                  32'(resp), 32'(RESP_DECERR));
        lite_read(PORT_CPU, 32'h3000_0000, rdata, resp);
        expect_eq("cpu read from an unclaimed address DECERRs",
                  32'(resp), 32'(RESP_DECERR));
        lite_write(PORT_DBG, 32'h8000_0000, 32'hDEAD_0002, resp);
        expect_eq("dbg write to main RAM DECERRs here", 32'(resp), 32'(RESP_DECERR));
        expect_eq("the UART is untouched by those", uart_regs[0], 32'h0);
        expect_eq("the CLINT is untouched by those", clint_regs[1], 32'h0);
        expect_eq("the PLIC is untouched by those", plic_regs[0], 32'h0);
        expect_eq("the SPI is untouched by those", spi_regs[0], 32'h0);
        expect_eq("the I2C is untouched by those", i2c_regs[0], 32'h0);

        //--- just below and just above each window
        //The PLIC's 64 MB window ends exactly where the UART's begins --
        //0x0C00_0000 + 0x0400_0000 == 0x1000_0000 -- so the word below the
        //UART is the top of the PLIC's window, not a hole. Both of those
        //numbers are CVA6's; this asserts that they still abut, because if a
        //future window is inserted between them this is where it shows up.
        lite_read(PORT_CPU, PERIPH_BASE - 32'h4, rdata, resp);
        expect_eq("the word below the UART is the top of the PLIC window",
                  32'(resp), 32'(RESP_OKAY));
        expect_eq("and the PLIC saw it",
                  32'(seen_plic_araddr),
                  (PERIPH_BASE - 32'h4) & ((32'd1 << PLIC_AW) - 1));

        //Between the CLINT's 64 KB and the PLIC's window, nothing is claimed.
        lite_read(PORT_CPU, 32'h0800_0000, rdata, resp);
        expect_eq("the gap between the CLINT and the PLIC DECERRs",
                  32'(resp), 32'(RESP_DECERR));
        lite_read(PORT_CPU, PERIPH_BASE + 32'h0001_0000, rdata, resp);
        expect_eq("one word past the UART window DECERRs",
                  32'(resp), 32'(RESP_DECERR));
        lite_read(PORT_CPU, CLINT_BASE + 32'h0001_0000, rdata, resp);
        expect_eq("one word past the CLINT window DECERRs",
                  32'(resp), 32'(RESP_DECERR));
        lite_read(PORT_CPU, PLIC_BASE - 32'h4, rdata, resp);
        expect_eq("one word below the PLIC window DECERRs",
                  32'(resp), 32'(RESP_DECERR));
        lite_read(PORT_CPU, SPI_BASE - 32'h4, rdata, resp);
        expect_eq("one word below the SPI window DECERRs",
                  32'(resp), 32'(RESP_DECERR));
        lite_read(PORT_CPU, SPI_BASE + 32'h0080_0000, rdata, resp);
        expect_eq("one word past the SPI window DECERRs",
                  32'(resp), 32'(RESP_DECERR));
        //The I2C's 4 KB sits alone between the SPI's 8 MB and the Ethernet
        //window the map reserves at 0x3000_0000, so unlike the PLIC/UART pair
        //it has a hole on both sides and both are asserted.
        lite_read(PORT_CPU, I2C_BASE - 32'h4, rdata, resp);
        expect_eq("one word below the I2C window DECERRs",
                  32'(resp), 32'(RESP_DECERR));
        lite_read(PORT_CPU, I2C_BASE + 32'h0000_1000, rdata, resp);
        expect_eq("one word past the I2C window DECERRs",
                  32'(resp), 32'(RESP_DECERR));
        //The same abutment seen from the other side: the first word past the
        //PLIC's window is the UART's first register.
        lite_read(PORT_CPU, PLIC_BASE + 32'h0400_0000, rdata, resp);
        expect_eq("the word past the PLIC window is the UART's first register",
                  32'(resp), 32'(RESP_OKAY));
        expect_eq("and the UART saw it, truncated to its port",
                  32'(seen_uart_araddr),
                  (PLIC_BASE + 32'h0400_0000) & ((32'd1 << UART_AW) - 1));

        //--- both masters at once, to different slaves
        $display("-- both masters together");
        fork
            lite_write(PORT_CPU, PERIPH_BASE + 32'h0, 32'h1111_2222, resp);
            lite_write(PORT_DBG, CLINT_BASE + 32'h4, 32'h3333_4444, resp);
        join
        expect_eq("concurrent CPU write landed", uart_regs[0], 32'h1111_2222);
        expect_eq("concurrent debugger write landed", clint_regs[1], 32'h3333_4444);

        fork
            lite_write(PORT_CPU, PLIC_BASE + 32'h8, 32'h5555_6666, resp);
            lite_write(PORT_DBG, PERIPH_BASE + 32'h4, 32'h7777_8888, resp);
        join
        fork
            lite_write(PORT_CPU, SPI_BASE + 32'hC, 32'h9999_AAAA, resp);
            lite_write(PORT_DBG, CLINT_BASE + 32'h8, 32'hBBBB_CCCC, resp);
        join
        fork
            lite_write(PORT_CPU, I2C_BASE + 32'h0, 32'hEEEE_FFFF, resp);
            lite_write(PORT_DBG, SPI_BASE + 32'h4, 32'hDDDD_EEEE, resp);
        join
        expect_eq("concurrent CPU write to the I2C", i2c_regs[0], 32'hEEEE_FFFF);
        expect_eq("concurrent debugger write to the SPI", spi_regs[1], 32'hDDDD_EEEE);
        expect_eq("concurrent CPU write to the SPI", spi_regs[3], 32'h9999_AAAA);
        expect_eq("concurrent debugger write to the CLINT", clint_regs[2], 32'hBBBB_CCCC);
        expect_eq("concurrent CPU write to the PLIC", plic_regs[2], 32'h5555_6666);
        expect_eq("concurrent debugger write to the UART", uart_regs[1], 32'h7777_8888);

        //--- and both at once to the same slave
        fork
            lite_write(PORT_CPU, PERIPH_BASE + 32'h4, 32'hAAAA_0001, resp);
            lite_write(PORT_DBG, PERIPH_BASE + 32'h8, 32'hBBBB_0002, resp);
        join
        expect_eq("contended write from the CPU landed", uart_regs[1], 32'hAAAA_0001);
        expect_eq("contended write from the debugger landed", uart_regs[2], 32'hBBBB_0002);

        //--- byte strobes reach the slave
        lite_write(PORT_CPU, PERIPH_BASE + 32'h0, 32'h9999_8888, resp, 4'b0011);
        expect_eq("write strobes reached the UART", 32'(seen_uart_wstrb), 32'b0011);
        lite_write(PORT_DBG, CLINT_BASE + 32'h0, 32'h7777_6666, resp, 4'b1000);
        expect_eq("a strobed write still completes", 32'(resp), 32'(RESP_OKAY));

        if (errors == 0)
            $display("PASS tb_axi_xbar: %0d checks (UART_AW=%0d CLINT_AW=%0d PLIC_AW=%0d SPI_AW=%0d I2C_AW=%0d)",
                     checks, UART_AW, CLINT_AW, PLIC_AW, SPI_AW, I2C_AW);
        else
            $display("FAIL tb_axi_xbar: %0d of %0d checks failed", errors, checks);
        $finish;
    end

    initial begin
        #500_000;
        $display("FAIL tb_axi_xbar (timeout)");
        $finish;
    end

endmodule
